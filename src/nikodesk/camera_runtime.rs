use super::{Catalog, Command, DeviceInfo, FormatInfo, Identity, SelectionInfo, Status};
use crate::nikodesk::{
    capability_state::{Binding, Capabilities, Kind, NormalUser, Phase, Scope, StopTicket, Ticket},
    owned_camera::Worker,
};
use hbb_common::{
    anyhow::anyhow,
    bail,
    sha2::{Digest, Sha256},
    tokio, ResultType,
};
use scrap::camera::{CameraAuthorization, CameraDevice, CameraFormat, Cameras, CaptureSelection};
use std::{
    sync::{
        atomic::{AtomicBool, AtomicU64, AtomicU8, Ordering},
        Arc, Mutex,
    },
    time::{Duration, Instant},
};

static NEXT_PROVIDER_LEASE: AtomicU64 = AtomicU64::new(1);
fn reserve_provider_lease(counter: &AtomicU64) -> ResultType<u64> {
    counter
        .fetch_update(Ordering::SeqCst, Ordering::SeqCst, |next| {
            next.checked_add(1).filter(|_| next != 0)
        })
        .map_err(|_| anyhow!("camera_native_lease_exhausted").into())
}

#[derive(Clone, PartialEq, Eq)]
struct Context {
    namespace: String,
    generation: u64,
    user: NormalUser,
}
impl Context {
    fn capture() -> ResultType<Self> {
        Self::with_current(Ok)
    }
    fn with_current<T>(run: impl FnOnce(Self) -> ResultType<T>) -> ResultType<T> {
        if crate::nikodesk::background::is_system_worker() {
            bail!("ordinary_camera_user_required");
        }
        crate::nikodesk::server_settings::with_verified_options(|options| {
            let namespace = crate::nikodesk::server_scope::namespace_from_options(options)
                .ok_or_else(|| anyhow!("camera_server_identity_unavailable"))?;
            let user = crate::nikodesk::connection_capabilities::normal_user()?;
            let policy = crate::nikodesk::capability_policy::Repository::new(
                crate::nikodesk::favorites::application_root()?,
            )
            .get(&namespace)?;
            if !policy.allow_requests.allows_requests(Kind::Camera) {
                bail!("camera_requests_disabled_locally");
            }
            run(Self {
                namespace,
                generation: policy.generation,
                user,
            })
        })
    }
}
struct GateState {
    capabilities: Capabilities,
    ticket: Ticket,
    stop: Option<StopTicket>,
}
pub(crate) struct Gate {
    state: Mutex<GateState>,
    pub(crate) cancelled: AtomicBool,
    phase: AtomicU8,
    epoch: AtomicU64,
    expires: Instant,
}
impl Gate {
    pub(crate) fn check(&self) -> ResultType<()> {
        if self.cancelled.load(Ordering::SeqCst)
            || Instant::now() >= self.expires
            || !matches!(self.phase(), Phase::Starting | Phase::Running)
        {
            bail!("camera_permission_revoked");
        }
        Ok(())
    }
    pub(crate) fn execute<T>(&self, run: impl FnOnce() -> ResultType<T>) -> ResultType<T> {
        if self.cancelled.load(Ordering::SeqCst) {
            bail!("camera_permission_revoked");
        }
        let state = self
            .state
            .lock()
            .map_err(|_| anyhow!("camera_state_unavailable"))?;
        if self.cancelled.load(Ordering::SeqCst)
            || !(state.capabilities.may_start(&state.ticket, Instant::now())
                || state.capabilities.may_execute(
                    &state.ticket,
                    state.ticket.scope(),
                    Instant::now(),
                ))
        {
            bail!("camera_permission_revoked");
        }
        let result = run();
        if self.cancelled.load(Ordering::SeqCst) {
            bail!("camera_permission_revoked");
        }
        result
    }
    fn started(&self) -> ResultType<()> {
        let mut state = self
            .state
            .lock()
            .map_err(|_| anyhow!("camera_state_unavailable"))?;
        let ticket = state.ticket.clone();
        if self.cancelled.load(Ordering::SeqCst) {
            bail!("camera_permission_revoked");
        }
        state
            .capabilities
            .did_start(&ticket, Instant::now())
            .map_err(|_| anyhow!("camera_start_ack_stale"))?;
        self.phase.store(2, Ordering::SeqCst);
        Ok(())
    }
    fn phase(&self) -> Phase {
        match self.phase.load(Ordering::SeqCst) {
            0 => Phase::Stopped,
            1 => Phase::Starting,
            2 => Phase::Running,
            3 => Phase::Revoking,
            _ => Phase::RecoveryRequired,
        }
    }
    fn revoke(&self) -> ResultType<()> {
        self.cancelled.store(true, Ordering::SeqCst);
        self.phase.store(3, Ordering::SeqCst);
        let mut state = self
            .state
            .try_lock()
            .map_err(|_| anyhow!("camera_state_unavailable"))?;
        state.stop = state
            .capabilities
            .revoke(Kind::Camera)
            .map_err(|_| anyhow!("camera_revoke_unconfirmed"))?;
        if let Some(stop) = state.stop.as_ref() {
            self.epoch.store(stop.epoch(), Ordering::SeqCst);
        }
        Ok(())
    }
    fn stopped(&self, confirmed: bool) -> ResultType<()> {
        let mut state = self
            .state
            .try_lock()
            .map_err(|_| anyhow!("camera_state_unavailable"))?;
        if let Some(stop) = state.stop.clone() {
            state
                .capabilities
                .did_stop(&stop, confirmed)
                .map_err(|_| anyhow!("camera_cleanup_ack_stale"))?;
        }
        self.phase
            .store(if confirmed { 0 } else { 4 }, Ordering::SeqCst);
        Ok(())
    }
    fn epoch(&self) -> String {
        self.epoch.load(Ordering::SeqCst).to_string()
    }
}
struct SavedFormat {
    uid: String,
    info: FormatInfo,
    native: CameraFormat,
}
struct PermissionJob {
    cancelled: Arc<AtomicBool>,
    result: Arc<Mutex<Option<ResultType<String>>>>,
    started: Instant,
}
impl Drop for PermissionJob {
    fn drop(&mut self) {
        self.cancelled.store(true, Ordering::SeqCst);
    }
}

pub(crate) struct Flow {
    context: Option<Context>,
    pub(crate) identity: Option<Identity>,
    connection_nonce: [u8; 16],
    request_nonce: [u8; 16],
    provider_lease: u64,
    required_2fa: bool,
    verified_totp: bool,
    requested: Instant,
    last_refresh: Instant,
    revision: u64,
    roster_revision: u64,
    devices: Vec<DeviceInfo>,
    formats: Vec<SavedFormat>,
    selection: Option<SelectionInfo>,
    gate: Option<Arc<Gate>>,
    worker: Option<Worker>,
    #[cfg(target_os = "windows")]
    probe: Option<crate::nikodesk::owned_camera::ProbeWorker>,
    permission: Option<PermissionJob>,
    stopped: bool,
    authenticated_peer_info: Option<base::message_proto::PeerInfo>,
    audit: Option<crate::nikodesk::capability_audit::Context>,
    denied_locally: bool,
}
impl Flow {
    pub(crate) fn new(required_2fa: bool) -> Self {
        Self {
            context: None,
            identity: None,
            connection_nonce: [0; 16],
            request_nonce: [0; 16],
            provider_lease: 0,
            required_2fa,
            verified_totp: false,
            requested: Instant::now(),
            last_refresh: Instant::now(),
            revision: 1,
            roster_revision: 0,
            devices: vec![],
            formats: vec![],
            selection: None,
            gate: None,
            worker: None,
            #[cfg(target_os = "windows")]
            probe: None,
            permission: None,
            stopped: false,
            authenticated_peer_info: None,
            audit: None,
            denied_locally: false,
        }
    }
    pub(crate) fn set_audit(&mut self, context: crate::nikodesk::capability_audit::Context) {self.audit=Some(context);}
    pub(crate) fn record_verified_totp(&mut self) {
        self.verified_totp = true;
    }
    pub(crate) fn capture_peer_info(&mut self, info: &base::message_proto::PeerInfo) {
        self.authenticated_peer_info = Some(info.clone());
    }
    pub(crate) fn approved_peer_info(&self) -> ResultType<base::message_proto::PeerInfo> {
        super::approved_peer_info(
            self.authenticated_peer_info
                .as_ref()
                .ok_or_else(|| anyhow!("camera_authenticated_metadata_missing"))?,
            self.selection
                .as_ref()
                .ok_or_else(|| anyhow!("camera_selection_missing"))?,
        )
    }
    pub(crate) async fn prepare(&mut self) -> ResultType<()> {
        let context = blocking(Context::capture).await?;
        if self.context.as_ref().map_or(false, |old| *old != context) {
            bail!("camera_request_scope_changed");
        }
        self.context = Some(context);
        Ok(())
    }
    pub(crate) async fn authenticated(
        &mut self,
        id: i32,
        peer: String,
        secured: bool,
        authed: bool,
    ) -> ResultType<Status> {
        if !secured || !authed || self.required_2fa && !self.verified_totp {
            bail!("camera_authentication_incomplete");
        }
        if self.identity.is_some() {
            bail!("camera_request_already_authenticated");
        }
        self.prepare().await?;
        let namespace = self
            .context
            .as_ref()
            .ok_or_else(|| anyhow!("camera_request_scope_missing"))?
            .namespace
            .clone();
        self.connection_nonce = *uuid::Uuid::new_v4().as_bytes();
        self.request_nonce = *uuid::Uuid::new_v4().as_bytes();
        Binding::new(namespace.clone(), peer.clone(), self.connection_nonce)
            .map_err(|_| anyhow!("invalid_camera_binding"))?;
        self.provider_lease = reserve_provider_lease(&NEXT_PROVIDER_LEASE)?;
        self.identity = Some(Identity {
            connection_id: id,
            namespace,
            peer_id: peer,
            connection_nonce: hex(&self.connection_nonce),
            request_nonce: hex(&self.request_nonce),
            epoch: "1".into(),
        });
        self.requested = Instant::now();
        Ok(self.status("local_approval_required")?)
    }
    pub(crate) fn rejected_status(&mut self) -> ResultType<Status> {
        self.bump()?;
        self.status("camera_command_rejected_stale_or_unavailable")
    }
    pub(crate) fn status(&self, reason: &str) -> ResultType<Status> {
        let status = Status {
            identity: self
                .identity
                .clone()
                .ok_or_else(|| anyhow!("camera_request_missing"))?,
            kind: "camera".into(),
            phase: format!("{:?}", self.phase()),
            reason: reason.into(),
            resource_epoch: self.gate.as_ref().map_or_else(|| "1".into(), |g| g.epoch()),
            revision: self.revision.to_string(),
            selection: self.selection.clone(),
        };
        if let Some(context) = &self.audit {
            context.observe(crate::nikodesk::capability_audit::Kind::Camera,
                &status.identity.namespace, &status.identity.peer_id, &status.identity.request_nonce,
                &status.phase, self.denied_locally && status.phase == "Stopped", false);
        }
        Ok(status)
    }
    fn bump(&mut self) -> ResultType<()> {
        self.revision = self
            .revision
            .checked_add(1)
            .ok_or_else(|| anyhow!("camera_revision_exhausted"))?;
        Ok(())
    }
    fn phase(&self) -> Phase {
        #[cfg(target_os = "windows")]
        if !self.stopped && self.probe.is_some() {
            return Phase::RecoveryRequired;
        }
        self.gate.as_ref().map_or(
            if self.stopped {
                Phase::Stopped
            } else {
                Phase::Pending
            },
            |g| g.phase(),
        )
    }
    fn validate(&self, command: &Command) -> ResultType<()> {
        command.validate()?;
        let revoke = matches!(command.op.as_str(), "deny" | "revoke" | "retry_cleanup");
        let revision = command
            .revision
            .parse::<u64>()
            .map_err(|_| anyhow!("camera_command_stale"))?;
        if self.identity.as_ref() != Some(&command.identity)
            || if revoke {
                revision > self.revision
            } else {
                revision != self.revision
            }
        {
            bail!("camera_command_stale");
        }
        Ok(())
    }
    async fn refresh(&self) -> ResultType<()> {
        let current = blocking(Context::capture).await?;
        if self.context.as_ref() != Some(&current) {
            bail!("camera_policy_or_identity_changed");
        }
        if self.phase() == Phase::Pending && self.requested.elapsed() >= Duration::from_secs(120) {
            bail!("camera_request_expired");
        }
        if let Some(gate) = self.gate.as_ref() {
            gate.check()?;
        }
        Ok(())
    }
    pub(crate) async fn command(
        &mut self,
        command: Command,
    ) -> ResultType<(Status, Option<Catalog>, bool)> {
        self.validate(&command)?;
        if matches!(command.op.as_str(), "deny" | "revoke" | "retry_cleanup") {
            if command.op == "deny" && self.gate.is_none() { self.denied_locally = true; }
            let status = self.revoke("revoked_locally").await?;
            return Ok((status, None, true));
        }
        if self.refresh().await.is_err() {
            let status = self.revoke("camera_policy_or_identity_changed").await?;
            return Ok((status, None, true));
        }
        if self.phase() != Phase::Pending {
            bail!("camera_pending_request_required");
        }
        let mut catalog = None;
        match command.op.as_str() {
            "enumerate" => {
                let devices = blocking(|| Cameras::devices())
                    .await
                    .map_err(|_| anyhow!("camera_catalog_unavailable"))?;
                self.replace_roster(devices)?;
                self.bump()?;
                catalog = Some(self.catalog("camera_catalog_ready")?);
            }
            "probe" => {
                let uid = command
                    .uid
                    .ok_or_else(|| anyhow!("camera_device_required"))?;
                if !self.devices.iter().any(|d| d.uid == uid) {
                    bail!("camera_device_not_in_roster");
                }
                #[cfg(target_os = "windows")]
                {
                    let mut probe = crate::nikodesk::owned_camera::ProbeWorker::start(
                        uid,
                        self.provider_lease,
                    )?;
                    let deadline = Instant::now() + Duration::from_secs(2);
                    let device = loop {
                        let result = match probe.result() {
                            Ok(result) => result,
                            Err(_) => {
                                self.probe = Some(probe);
                                bail!("camera_format_probe_unconfirmed");
                            }
                        };
                        match result {
                            Some(Ok(device)) => break device,
                            Some(Err(())) => {
                                self.probe = Some(probe);
                                bail!("camera_format_probe_unconfirmed");
                            }
                            None if Instant::now() >= deadline => {
                                self.probe = Some(probe);
                                bail!("camera_format_probe_unconfirmed");
                            }
                            None => tokio::time::sleep(Duration::from_millis(10)).await,
                        }
                    };
                    let mut devices = Vec::new();
                    for current in &self.devices {
                        if current.uid != device.unique_id {
                            devices.push(CameraDevice {
                                unique_id: current.uid.clone(),
                                name: current.name.clone(),
                                formats: vec![],
                            });
                        }
                    }
                    devices.push(device);
                    self.replace_roster(devices)?;
                }
                #[cfg(target_os = "macos")]
                {
                    let _ = uid;
                }
                self.bump()?;
                catalog = Some(self.catalog("camera_formats_ready")?);
            }
            "request_permission" => {
                if self.permission.is_some() {
                    bail!("camera_permission_request_pending");
                }
                #[cfg(target_os = "macos")]
                {
                    self.permission = Some(permission_job()?);
                }
                #[cfg(target_os = "windows")]
                {
                    self.bump()?;
                    return Ok((self.status("os_camera_settings_required")?, None, false));
                }
                #[cfg(target_os = "macos")]
                {
                    self.bump()?;
                    return Ok((self.status("os_permission_requested_locally")?, None, false));
                }
            }
            "approve" => {
                let selection = self.select(&command)?;
                let info = self
                    .selection
                    .as_ref()
                    .ok_or_else(|| anyhow!("camera_selection_missing"))?
                    .clone();
                let original = self
                    .context
                    .clone()
                    .ok_or_else(|| anyhow!("camera_request_scope_missing"))?;
                let identity = self
                    .identity
                    .clone()
                    .ok_or_else(|| anyhow!("camera_request_missing"))?;
                let cn = self.connection_nonce;
                let rn = self.request_nonce;
                let rr = self.roster_revision;
                // Grant creation happens under the fresh settings read, after no OS work.
                let native_identity = selection.format.identity_bytes();
                if native_identity.is_empty() || native_identity.len() > 4096 {
                    bail!("camera_native_format_identity_invalid");
                }
                let audit = self.audit.clone();
                let gate = blocking(move || {
                    Context::with_current(|current| {
                        if current != original {
                            bail!("camera_policy_or_identity_changed");
                        }
                        let binding = Binding::new(identity.namespace, identity.peer_id, cn)
                            .map_err(|_| anyhow!("invalid_camera_binding"))?;
                        let mut capabilities = Capabilities::new(binding, true, true);
                        capabilities.attach_audit(audit);
                        capabilities
                            .set_policy(Kind::Camera, true, true)
                            .map_err(|_| anyhow!("camera_policy_invalid"))?;
                        let request = capabilities
                            .request(
                                Scope::Camera(fingerprint(&info, rr, &native_identity)),
                                rn,
                                Instant::now(),
                            )
                            .map_err(|_| anyhow!("camera_request_invalid"))?;
                        let ticket = capabilities
                            .approve(&request, Instant::now(), Duration::from_secs(3600))
                            .map_err(|_| anyhow!("camera_grant_unavailable"))?;
                        Ok(Arc::new(Gate {
                            state: Mutex::new(GateState {
                                capabilities,
                                ticket,
                                stop: None,
                            }),
                            cancelled: AtomicBool::new(false),
                            phase: AtomicU8::new(1),
                            epoch: AtomicU64::new(1),
                            expires: Instant::now() + Duration::from_secs(3600),
                        }))
                    })
                })
                .await?;
                let worker = Worker::start(selection, gate.clone())?;
                self.gate = Some(gate);
                self.worker = Some(worker);
                self.bump()?;
            }
            _ => bail!("invalid_camera_command"),
        }
        Ok((
            self.status(if catalog.is_some() {
                "camera_catalog_updated"
            } else {
                "camera_preparing"
            })?,
            catalog,
            false,
        ))
    }
    fn replace_roster(&mut self, devices: Vec<CameraDevice>) -> ResultType<()> {
        if devices.len() > 64 {
            bail!("camera_catalog_invalid");
        }
        self.roster_revision = self
            .roster_revision
            .checked_add(1)
            .ok_or_else(|| anyhow!("camera_roster_revision_exhausted"))?;
        self.devices.clear();
        self.formats.clear();
        self.selection = None;
        if devices.iter().map(|d| d.formats.len()).sum::<usize>() > 4096 {
            bail!("camera_catalog_invalid");
        }
        for device in devices {
            if device.unique_id.is_empty()
                || device.unique_id.len() > 1024
                || device.unique_id.chars().any(char::is_control)
                || device.name.len() > 1024
                || device.name.chars().any(char::is_control)
                || device.formats.len() > 512
                || self.devices.iter().any(|d| d.uid == device.unique_id)
            {
                bail!("camera_catalog_invalid");
            }
            let mut formats = Vec::new();
            for native in device.formats {
                if native.width == 0
                    || native.height == 0
                    || native.width > 4096
                    || native.height > 4096
                    || native.width % 2 != 0
                    || native.height % 2 != 0
                {
                    continue;
                }
                let info = format_info(&native);
                formats.push(info.clone());
                self.formats.push(SavedFormat {
                    uid: device.unique_id.clone(),
                    info,
                    native,
                });
            }
            self.devices.push(DeviceInfo {
                uid: device.unique_id,
                name: device.name,
                formats,
            });
        }
        Ok(())
    }
    fn select(&mut self, command: &Command) -> ResultType<CaptureSelection> {
        if command.roster_revision.as_deref() != Some(&self.roster_revision.to_string()) {
            bail!("camera_roster_changed_reselect");
        }
        let saved = self
            .formats
            .iter()
            .find(|f| {
                Some(&f.uid) == command.uid.as_ref()
                    && Some(&f.info.format_token) == command.format_token.as_ref()
            })
            .ok_or_else(|| anyhow!("camera_exact_format_not_in_snapshot"))?;
        if saved.native.width > 1920 || saved.native.height > 1080 {
            bail!("camera_selected_format_exceeds_stream_limit");
        }
        #[cfg(target_os = "macos")]
        let (selection, num, den) = {
            let fps = command
                .fps
                .ok_or_else(|| anyhow!("camera_integer_fps_required"))?;
            let selection = CaptureSelection {
                unique_id: saved.uid.clone(),
                format: saved.native.clone(),
                fps,
                epoch: self.provider_lease,
            };
            selection.validate()?;
            (selection, fps, 1)
        };
        #[cfg(target_os = "windows")]
        let (selection, num, den) = {
            if command.fps.is_some() {
                bail!("camera_native_fractional_fps_required");
            }
            let num = saved.native.fps_num();
            let den = saved.native.fps_den();
            if den == 0 || num == 0 || u64::from(num) > 60 * u64::from(den) {
                bail!("camera_native_fps_invalid");
            }
            (
                CaptureSelection {
                    unique_id: saved.uid.clone(),
                    format: saved.native.clone(),
                    epoch: self.provider_lease,
                },
                num,
                den,
            )
        };
        self.selection = Some(SelectionInfo {
            uid: saved.uid.clone(),
            format_token: saved.info.format_token.clone(),
            width: saved.native.width,
            height: saved.native.height,
            fps_num: num,
            fps_den: den,
            format_schema: saved.info.format_schema.clone(),
        });
        Ok(selection)
    }
    fn catalog(&self, reason: &str) -> ResultType<Catalog> {
        let catalog = Catalog {
            identity: self
                .identity
                .clone()
                .ok_or_else(|| anyhow!("camera_request_missing"))?,
            revision: self.revision.to_string(),
            roster_revision: self.roster_revision.to_string(),
            authorization: authorization()?.into(),
            devices: self.devices.clone(),
            reason: reason.into(),
        };
        if serde_json::to_vec(&catalog)?.len() > 1024 * 1024 {
            bail!("camera_catalog_invalid");
        }
        Ok(catalog)
    }
    pub(crate) async fn poll(
        &mut self,
    ) -> ResultType<(
        Option<Status>,
        Option<Catalog>,
        Option<base::message_proto::Message>,
        bool,
    )> {
        if self.identity.is_none() || self.phase() == Phase::Stopped {
            return Ok((None, None, None, false));
        }
        #[cfg(target_os = "windows")]
        if self.probe.is_some() {
            return Ok((
                Some(self.revoke("camera_format_probe_unconfirmed").await?),
                None,
                None,
                true,
            ));
        }
        if self.last_refresh.elapsed() >= Duration::from_millis(250) {
            self.last_refresh = Instant::now();
            if self.refresh().await.is_err() {
                return Ok((
                    Some(self.revoke("camera_policy_or_identity_changed").await?),
                    None,
                    None,
                    true,
                ));
            }
        }
        if let Some(job) = self.permission.as_ref() {
            let result = job
                .result
                .lock()
                .map_err(|_| anyhow!("camera_permission_unconfirmed"))?
                .take();
            if let Some(result) = result {
                self.permission.take();
                self.bump()?;
                let reason = if result.is_ok() {
                    "os_permission_completed"
                } else {
                    "os_permission_unconfirmed"
                };
                return Ok((
                    Some(self.status(reason)?),
                    Some(self.catalog(reason)?),
                    None,
                    false,
                ));
            }
            if job.started.elapsed() > Duration::from_secs(30) {
                self.permission.take();
                self.bump()?;
                return Ok((
                    Some(self.status("os_permission_unconfirmed")?),
                    None,
                    None,
                    false,
                ));
            }
        }
        if let Some(worker) = self.worker.as_mut() {
            if let Some(error) = worker.error() {
                let _ = error;
                return Ok((
                    Some(self.revoke("camera_capture_or_encode_failed").await?),
                    None,
                    None,
                    true,
                ));
            }
            if let Some(message) = worker.packet()? {
                if let Some(gate) = self.gate.as_ref() {
                    gate.check()?;
                }
                return Ok((None, None, Some(message), false));
            }
        }
        Ok((None, None, None, false))
    }
    pub(crate) fn selection_info(&self) -> Option<&SelectionInfo> {
        self.selection.as_ref()
    }
    pub(crate) async fn packet_sent(&mut self) -> ResultType<Option<Status>> {
        let gate = self
            .gate
            .as_ref()
            .ok_or_else(|| anyhow!("camera_grant_missing"))?;
        gate.check()?;
        if gate.phase() == Phase::Starting {
            let g = gate.clone();
            blocking(move || g.started()).await?;
            self.bump()?;
            return Ok(Some(self.status("first_encoded_packet_sent")?));
        }
        Ok(None)
    }
    pub(crate) async fn revoke(&mut self, _reason: &str) -> ResultType<Status> {
        self.begin_cleanup()
    }
    fn cleanup_confirmed(&mut self) -> bool {
        if self.stopped {
            return true;
        }
        #[allow(unused_mut)]
        let mut confirmed = self.worker.as_mut().map_or(true, Worker::stop_ack);
        #[cfg(target_os = "windows")]
        if let Some(probe) = self.probe.as_mut() {
            confirmed &= probe.stop_ack();
        }
        if let Some(gate) = self.gate.as_ref() {
            if gate.revoke().and_then(|_| gate.stopped(confirmed)).is_err() {
                gate.phase.store(4, Ordering::SeqCst);
                confirmed = false;
            }
        }
        self.stopped = confirmed;
        confirmed
    }
    pub(crate) fn begin_cleanup(&mut self) -> ResultType<Status> {
        self.permission.take();
        self.formats.clear();
        self.devices.clear();
        if let Some(gate) = self.gate.as_ref() {
            gate.cancelled.store(true, Ordering::SeqCst);
        }
        if let Some(worker) = self.worker.as_mut() {
            worker.cancel();
        }
        let confirmed = self.cleanup_confirmed();
        self.bump()?;
        self.status(if confirmed {
            "camera_stopped"
        } else {
            "camera_cleanup_unconfirmed_owner_retained"
        })
    }
    pub(crate) fn take_cleanup(&mut self) -> Option<RetiredCleanup> {
        self.identity.as_ref()?;
        let flow = std::mem::replace(self, Self::new(false));
        Some(RetiredCleanup { flow })
    }
}

/// Holds the original joins and grant state after the remote stream has exited.
/// It never reads current settings or dispatches a capture/permission operation.
pub(crate) struct RetiredCleanup {
    flow: Flow,
}
impl RetiredCleanup {
    fn command(&mut self, command: &Command) -> ResultType<Status> {
        command.validate()?;
        if !matches!(command.op.as_str(), "query" | "retry_cleanup")
            || self.flow.identity.as_ref() != Some(&command.identity)
            || command
                .revision
                .parse::<u64>()
                .map_or(true, |v| v > self.flow.revision)
        {
            bail!("camera_cleanup_command_rejected");
        }
        if command.op == "retry_cleanup" && self.flow.phase() != Phase::Stopped {
            return self.flow.begin_cleanup();
        }
        self.snapshot()
    }
    fn snapshot(&self) -> ResultType<Status> {
        self.flow.status(if self.flow.phase() == Phase::Stopped {
            "camera_stopped"
        } else {
            "camera_cleanup_unconfirmed_owner_retained"
        })
    }
    pub(crate) async fn run(
        mut self,
        mut commands: tokio::sync::mpsc::UnboundedReceiver<crate::ipc::Data>,
        tx: tokio::sync::mpsc::UnboundedSender<crate::ipc::Data>,
    ) {
        let mut timer = tokio::time::interval(Duration::from_millis(100));
        let mut commands_open = true;
        if self.flow.stopped {
            let _ = tx.send(crate::ipc::Data::Disconnected);
            return;
        }
        loop {
            if self.flow.cleanup_confirmed() {
                if self.flow.bump().is_err() {
                    tokio::time::sleep(Duration::from_secs(1)).await;
                    continue;
                }
                if let Ok(status) = self.snapshot() {
                    let _ = tx.send(crate::ipc::Data::NikoCameraCleanupStatus(status));
                }
                let _ = tx.send(crate::ipc::Data::Disconnected);
                return;
            }
            tokio::select! {
                _ = timer.tick() => {},
                command = commands.recv(), if commands_open => {
                    match command {
                        Some(crate::ipc::Data::NikoCameraCommand(command)) => {
                            if let Ok(status) = self.command(&command) {
                                let stopped=status.phase=="Stopped";
                                let _ = tx.send(crate::ipc::Data::NikoCameraCleanupStatus(status));
                                if stopped {let _=tx.send(crate::ipc::Data::Disconnected);return;}
                            }
                        }
                        // Closing a CM window cannot discard the unfinished owner.
                        Some(_) => {},
                        None => { commands_open = false; }
                    }
                }
            }
        }
    }
}
impl Drop for Flow {
    fn drop(&mut self) {
        self.permission.take();
        if let Some(gate) = self.gate.as_ref() {
            gate.cancelled.store(true, Ordering::SeqCst);
        }
        if let Some(worker) = self.worker.as_mut() {
            worker.cancel();
        }
    }
}
fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}
fn fingerprint(info: &SelectionInfo, revision: u64, native_identity: &[u8]) -> String {
    let mut hash = Sha256::new();
    hash.update(b"NikoDesk camera selection v1\0");
    for value in [&info.uid, &info.format_token, &info.format_schema] {
        hash.update((value.len() as u64).to_be_bytes());
        hash.update(value.as_bytes());
    }
    for value in [info.width, info.height, info.fps_num, info.fps_den] {
        hash.update(value.to_be_bytes());
    }
    hash.update(revision.to_be_bytes());
    hash.update((native_identity.len() as u64).to_be_bytes());
    hash.update(native_identity);
    hex(&hash.finalize())
}
fn format_info(native: &CameraFormat) -> FormatInfo {
    FormatInfo {
        format_token: uuid::Uuid::new_v4().simple().to_string(),
        width: native.width,
        height: native.height,
        #[cfg(target_os = "macos")]
        format_schema: "mac-fps-range-v1".into(),
        #[cfg(target_os = "windows")]
        format_schema: "windows-native-v1".into(),
        #[cfg(target_os = "macos")]
        min_fps_milli: Some(native.min_fps_milli),
        #[cfg(target_os = "windows")]
        min_fps_milli: None,
        #[cfg(target_os = "macos")]
        max_fps_milli: Some(native.max_fps_milli),
        #[cfg(target_os = "windows")]
        max_fps_milli: None,
        #[cfg(target_os = "macos")]
        fps_num: None,
        #[cfg(target_os = "macos")]
        fps_den: None,
        #[cfg(target_os = "windows")]
        fps_num: Some(native.fps_num()),
        #[cfg(target_os = "windows")]
        fps_den: Some(native.fps_den()),
    }
}
fn authorization() -> ResultType<&'static str> {
    Ok(match scrap::camera::authorization_status()? {
        CameraAuthorization::Authorized => "authorized",
        CameraAuthorization::NotDetermined => "not_determined",
        CameraAuthorization::Denied => "denied",
        CameraAuthorization::Restricted => "restricted",
    })
}
#[cfg(target_os = "macos")]
fn permission_job() -> ResultType<PermissionJob> {
    let cancelled = Arc::new(AtomicBool::new(false));
    let result = Arc::new(Mutex::new(None));
    let c = cancelled.clone();
    let r = result.clone();
    std::thread::Builder::new()
        .name("niko-camera-permission".into())
        .spawn(move || {
            let outcome = (|| -> ResultType<String> {
                if c.load(Ordering::SeqCst) {
                    bail!("camera_permission_cancelled");
                }
                let mut request = scrap::camera::PermissionRequest::request_local(1)?;
                let start = Instant::now();
                loop {
                    if c.load(Ordering::SeqCst) || start.elapsed() > Duration::from_secs(30) {
                        request.cancel();
                        bail!("camera_permission_cancelled");
                    }
                    if let Some(status) = request.poll()? {
                        return Ok(format!("{status:?}"));
                    }
                    std::thread::sleep(Duration::from_millis(50));
                }
            })();
            if let Ok(mut result) = r.lock() {
                *result = Some(outcome);
            }
        })?;
    Ok(PermissionJob {
        cancelled,
        result,
        started: Instant::now(),
    })
}
async fn blocking<T: Send + 'static>(
    run: impl FnOnce() -> ResultType<T> + Send + 'static,
) -> ResultType<T> {
    match tokio::time::timeout(Duration::from_secs(2), tokio::task::spawn_blocking(run)).await {
        Ok(result) => result?,
        Err(_) => Err(anyhow!("camera_operation_unconfirmed").into()),
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn camera_scope_hash_binds_device_format_fractional_rate_and_roster_revision() {
        let original = SelectionInfo {
            uid: "fixture".into(),
            format_token: "a".repeat(32),
            width: 640,
            height: 480,
            fps_num: 30000,
            fps_den: 1001,
            format_schema: "windows-native-v1".into(),
        };
        let hash = fingerprint(&original, 1, b"native-fixture");
        assert_eq!(hash.len(), 64);
        for change in 0..6 {
            let mut info = original.clone();
            match change {
                0 => info.uid.push('a'),
                1 => info.format_token = "b".repeat(32),
                2 => info.width = 1280,
                3 => info.fps_num = 30,
                4 => info.fps_den = 1,
                _ => info.format_schema = "mac-fps-range-v1".into(),
            };
            assert_ne!(hash, fingerprint(&info, 1, b"native-fixture"));
        }
        assert_ne!(hash, fingerprint(&original, 2, b"native-fixture"));
        assert_ne!(
            hash,
            fingerprint(&original, 1, b"different-exact-native-key")
        );
    }
    #[test]
    fn camera_gate_rejects_late_first_packet_and_execution_after_revoke() {
        let mut caps = Capabilities::new(
            Binding::new("a".repeat(64), "123456789".into(), [1; 16]).unwrap(),
            true,
            true,
        );
        caps.set_policy(Kind::Camera, true, true).unwrap();
        let request = caps
            .request(Scope::Camera("a".repeat(64)), [2; 16], Instant::now())
            .unwrap();
        let ticket = caps
            .approve(&request, Instant::now(), Duration::from_secs(60))
            .unwrap();
        let gate = Gate {
            state: Mutex::new(GateState {
                capabilities: caps,
                ticket,
                stop: None,
            }),
            cancelled: AtomicBool::new(false),
            phase: AtomicU8::new(1),
            epoch: AtomicU64::new(1),
            expires: Instant::now() + Duration::from_secs(60),
        };
        assert_eq!(gate.phase(), Phase::Starting);
        assert!(gate.check().is_ok());
        gate.revoke().unwrap();
        assert!(gate.check().is_err());
        assert!(gate.started().is_err());
        gate.stopped(false).unwrap();
        assert_eq!(gate.phase(), Phase::RecoveryRequired);
        gate.stopped(true).unwrap();
        assert_eq!(gate.phase(), Phase::Stopped);
    }
}

pub(super) async fn requests_allowed() -> bool {
    blocking(Context::capture).await.is_ok()
}

#[cfg(test)]
mod boundary_tests {
    use super::*;
    #[test]
    fn camera_native_leases_are_process_unique_and_never_wrap_or_reuse() {
        let counter = Arc::new(AtomicU64::new(1));
        let threads = (0..8)
            .map(|_| {
                let counter = counter.clone();
                std::thread::spawn(move || {
                    (0..128)
                        .map(|_| reserve_provider_lease(&counter).unwrap())
                        .collect::<Vec<_>>()
                })
            })
            .collect::<Vec<_>>();
        let mut leases = threads
            .into_iter()
            .flat_map(|thread| thread.join().unwrap())
            .collect::<Vec<_>>();
        leases.sort_unstable();
        assert_eq!(leases, (1..=1024).collect::<Vec<_>>());
        let exhausted = AtomicU64::new(u64::MAX - 1);
        assert_eq!(reserve_provider_lease(&exhausted).unwrap(), u64::MAX - 1);
        assert!(reserve_provider_lease(&exhausted).is_err());
        assert_eq!(exhausted.load(Ordering::SeqCst), u64::MAX);
        assert!(reserve_provider_lease(&AtomicU64::new(0)).is_err());
    }
    fn gate() -> Arc<Gate> {
        let mut caps = Capabilities::new(
            Binding::new("a".repeat(64), "123456789".into(), [1; 16]).unwrap(),
            true,
            true,
        );
        caps.set_policy(Kind::Camera, true, true).unwrap();
        let req = caps
            .request(Scope::Camera("a".repeat(64)), [2; 16], Instant::now())
            .unwrap();
        let ticket = caps
            .approve(&req, Instant::now(), Duration::from_secs(60))
            .unwrap();
        Arc::new(Gate {
            state: Mutex::new(GateState {
                capabilities: caps,
                ticket,
                stop: None,
            }),
            cancelled: AtomicBool::new(false),
            phase: AtomicU8::new(1),
            epoch: AtomicU64::new(1),
            expires: Instant::now() + Duration::from_secs(60),
        })
    }
    fn cleanup_fixture(panic: bool) -> (Flow, std::sync::mpsc::Sender<()>) {
        let mut flow = Flow::new(false);
        flow.identity = Some(Identity {
            connection_id: 12,
            namespace: "a".repeat(64),
            peer_id: "123456789".into(),
            connection_nonce: "b".repeat(32),
            request_nonce: "c".repeat(32),
            epoch: "1".into(),
        });
        flow.provider_lease = 123;
        let gate = gate();
        let (release, wait) = std::sync::mpsc::channel();
        flow.worker = Some(Worker::cleanup_fixture(gate.clone(), wait, panic));
        flow.gate = Some(gate);
        (flow, release)
    }
    fn cleanup_command(status: &Status, op: &str) -> Command {
        Command {
            identity: status.identity.clone(),
            revision: status.revision.clone(),
            op: op.into(),
            uid: None,
            roster_revision: None,
            format_token: None,
            fps: None,
        }
    }
    #[tokio::test]
    async fn camera_retired_task_keeps_real_join_and_delivers_late_ack_after_remote_owner_dropped()
    {
        let (mut flow, release) = cleanup_fixture(false);
        let anchor = flow.status("first_encoded_packet_sent").unwrap();
        let mut cm = crate::ui_cm_interface::Client::camera_cleanup_fixture(anchor);
        let status = flow.begin_cleanup().unwrap();
        assert_eq!(status.phase, "RecoveryRequired");
        assert!(cm.apply_camera_cleanup(&status, true));
        let retired = flow.take_cleanup().unwrap();
        drop(flow);
        let (command_tx, command_rx) = tokio::sync::mpsc::unbounded_channel();
        let (status_tx, mut status_rx) = tokio::sync::mpsc::unbounded_channel();
        let task = tokio::spawn(retired.run(command_rx, status_tx));
        command_tx.send(crate::ipc::Data::Close).unwrap();
        command_tx
            .send(crate::ipc::Data::NikoCameraCommand(cleanup_command(
                &status, "query",
            )))
            .unwrap();
        let query = tokio::time::timeout(Duration::from_secs(1), status_rx.recv())
            .await
            .unwrap()
            .unwrap();
        assert!(
            matches!(query,crate::ipc::Data::NikoCameraCleanupStatus(ref s) if s.phase=="RecoveryRequired" && s.identity==status.identity)
        );
        assert!(!task.is_finished());
        release.send(()).unwrap();
        let stopped = tokio::time::timeout(Duration::from_secs(1), status_rx.recv())
            .await
            .unwrap()
            .unwrap();
        match stopped {
            crate::ipc::Data::NikoCameraCleanupStatus(s) => {
                assert_eq!(s.phase, "Stopped");
                assert_eq!(s.identity, status.identity);
                assert!(
                    s.revision.parse::<u64>().unwrap() > status.revision.parse::<u64>().unwrap()
                );
                assert!(cm.apply_camera_cleanup(&s, false));
                assert!(cm.disconnected && !cm.authorized && cm.niko_camera_cleanup);
                assert_eq!(cm.niko_camera.unwrap().phase, "Stopped");
            }
            _ => panic!("missing stopped"),
        }
        assert!(matches!(
            status_rx.recv().await,
            Some(crate::ipc::Data::Disconnected)
        ));
        task.await.unwrap();
        assert!(status_rx.recv().await.is_none());
    }
    #[tokio::test]
    async fn camera_retired_connection_rejects_grants_and_foreign_identity_without_reading_settings(
    ) {
        let (mut flow, release) = cleanup_fixture(false);
        let status = flow.begin_cleanup().unwrap();
        let mut retired = flow.take_cleanup().unwrap();
        for op in [
            "enumerate",
            "request_permission",
            "approve",
            "probe",
            "revoke",
            "deny",
        ] {
            let mut command = cleanup_command(&status, op);
            if op == "probe" || op == "approve" {
                command.uid = Some("synthetic-uid".into());
            }
            if op == "approve" {
                command.roster_revision = Some("1".into());
                command.format_token = Some("d".repeat(32));
            }
            assert!(command.validate().is_ok());
            assert!(retired.command(&command).is_err());
        }
        for field in [0, 1, 2] {
            let mut command = cleanup_command(&status, "retry_cleanup");
            match field {
                0 => command.identity.namespace = "f".repeat(64),
                1 => command.identity.connection_nonce = "f".repeat(32),
                _ => command.identity.request_nonce = "f".repeat(32),
            };
            assert!(retired.command(&command).is_err());
        }
        assert_eq!(
            retired
                .command(&cleanup_command(&status, "retry_cleanup"))
                .unwrap()
                .phase,
            "RecoveryRequired"
        );
        release.send(()).unwrap();
        while !retired.flow.cleanup_confirmed() {
            tokio::time::sleep(Duration::from_millis(1)).await;
        }
        assert_eq!(retired.snapshot().unwrap().phase, "Stopped");
    }
    #[test]
    fn camera_retired_worker_panic_after_ack_remains_owned_and_unconfirmed() {
        let (mut flow, release) = cleanup_fixture(true);
        assert_eq!(flow.begin_cleanup().unwrap().phase, "RecoveryRequired");
        release.send(()).unwrap();
        while flow.worker.as_ref().unwrap().join_for_fixture_pending() {
            std::thread::yield_now();
        }
        assert!(!flow.cleanup_confirmed());
        assert!(!flow.cleanup_confirmed());
        assert_eq!(flow.phase(), Phase::RecoveryRequired);
    }
    #[tokio::test]
    async fn camera_retired_owner_survives_cm_channel_loss_until_ack_and_join() {
        let (mut flow, release) = cleanup_fixture(false);
        flow.begin_cleanup().unwrap();
        let retired = flow.take_cleanup().unwrap();
        drop(flow);
        let (commands, rx) = tokio::sync::mpsc::unbounded_channel();
        let (tx, status) = tokio::sync::mpsc::unbounded_channel();
        drop(commands);
        drop(status);
        let task = tokio::spawn(retired.run(rx, tx));
        tokio::task::yield_now().await;
        assert!(!task.is_finished());
        release.send(()).unwrap();
        tokio::time::timeout(Duration::from_secs(1), task)
            .await
            .unwrap()
            .unwrap();
    }
    #[tokio::test]
    async fn camera_already_confirmed_retirement_does_not_emit_a_second_stopped() {
        let (mut flow, release) = cleanup_fixture(false);
        release.send(()).unwrap();
        while flow.worker.as_ref().unwrap().join_for_fixture_pending() {
            tokio::task::yield_now().await;
        }
        assert_eq!(flow.begin_cleanup().unwrap().phase, "Stopped");
        let retired = flow.take_cleanup().unwrap();
        let (_commands, rx) = tokio::sync::mpsc::unbounded_channel();
        let (tx, mut statuses) = tokio::sync::mpsc::unbounded_channel();
        retired.run(rx, tx).await;
        assert!(matches!(
            statuses.recv().await,
            Some(crate::ipc::Data::Disconnected)
        ));
        assert!(statuses.recv().await.is_none());
    }
    #[tokio::test]
    async fn camera_incomplete_authentication_and_current_totp_never_read_user_config() {
        for (secured, authenticated, required, verified) in [
            (false, true, false, false),
            (true, false, false, false),
            (true, true, true, false),
        ] {
            let mut flow = Flow::new(required);
            flow.verified_totp = verified;
            assert!(flow
                .authenticated(1, "123456789".into(), secured, authenticated)
                .await
                .is_err());
            assert!(flow.context.is_none());
            assert!(flow.identity.is_none());
        }
    }
    #[test]
    fn camera_default_off_and_unencrypted_facts_never_produce_a_grant() {
        for (secured, authed) in [(false, true), (true, false), (true, true)] {
            let mut caps = Capabilities::new(
                Binding::new("a".repeat(64), "123456789".into(), [1; 16]).unwrap(),
                secured,
                authed,
            );
            assert!(caps
                .request(
                    Scope::Camera("fixture-camera".into()),
                    [2; 16],
                    Instant::now()
                )
                .is_err());
        }
    }
    #[test]
    fn camera_revoke_blocks_queued_executor_without_holding_async_guard() {
        use std::sync::mpsc;
        let gate = gate();
        let worker = gate.clone();
        let (started, rx) = mpsc::channel();
        let (release, wait) = mpsc::channel();
        let thread = std::thread::spawn(move || {
            worker.execute(|| {
                started.send(()).unwrap();
                wait.recv().unwrap();
                Ok(())
            })
        });
        rx.recv().unwrap();
        let revoke = gate.clone();
        let cancel = std::thread::spawn(move || revoke.revoke());
        let deadline = Instant::now() + Duration::from_secs(1);
        while !gate.cancelled.load(Ordering::SeqCst) {
            assert!(Instant::now() < deadline);
            std::thread::yield_now();
        }
        assert!(gate.check().is_err());
        // A native operation may still own the execution lock; cancellation
        // must return an unconfirmed state rather than wait on that operation.
        assert!(cancel.join().unwrap().is_err());
        release.send(()).unwrap();
        assert!(thread.join().unwrap().is_err());
        gate.revoke().unwrap();
        let executed = AtomicBool::new(false);
        assert!(gate
            .execute(|| {
                executed.store(true, Ordering::SeqCst);
                Ok(())
            })
            .is_err());
        assert!(!executed.load(Ordering::SeqCst));
    }
    #[test]
    fn same_request_revocation_can_follow_queued_approval_but_approve_cannot_use_old_revision() {
        let mut flow = Flow::new(false);
        let identity = Identity {
            connection_id: 1,
            namespace: "a".repeat(64),
            peer_id: "123456789".into(),
            connection_nonce: "b".repeat(32),
            request_nonce: "c".repeat(32),
            epoch: "1".into(),
        };
        flow.identity = Some(identity.clone());
        flow.revision = 2;
        let mut command = Command {
            identity,
            revision: "1".into(),
            op: "revoke".into(),
            uid: None,
            roster_revision: None,
            format_token: None,
            fps: None,
        };
        assert!(flow.validate(&command).is_ok());
        command.revision = "3".into();
        assert!(flow.validate(&command).is_err());
        command.revision = "1".into();
        command.op = "enumerate".into();
        assert!(flow.validate(&command).is_err());
        command.op = "revoke".into();
        command.identity.namespace = "f".repeat(64);
        assert!(flow.validate(&command).is_err());
    }
}
