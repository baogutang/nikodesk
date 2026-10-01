//! Dedicated-worker voice approval and cleanup ownership. Not yet wired into
//! Connection/Session or CM; callers must supply current encrypted-login facts
//! and keep their actual UUID/stream route bound to this immutable identity.
use super::{
    capability_state::{
        Binding as CapabilityBinding, Capabilities, Kind, NormalUser, Scope, StopTicket, Ticket,
    },
    voice::{self, EncodedPacket, MediaIo, VoiceError, VoiceOwner},
    voice_flow::{
        self as dto, Catalog, Command, Device, Format, Identity, Operation, Permission, Phase,
        Reply, Selection, Status, Wire,
    },
};
use sha2::{Digest, Sha256};
use std::{
    sync::{
        atomic::{AtomicBool, AtomicU64, Ordering},
        mpsc::{self, Receiver, SyncSender, TrySendError},
        Arc, Mutex,
    },
    thread::{self, JoinHandle},
    time::{Duration, Instant},
};

#[derive(Clone, Debug, PartialEq, Eq)]
struct Context {
    namespace: String,
    generation: u64,
    user: NormalUser,
}
impl Context {
    fn capture(provider: &dyn Provider) -> Result<Self, &'static str> {
        std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            Self::with_current(provider, Ok)
        }))
        .unwrap_or(Err("worker_failed"))
    }

    fn with_current<T>(
        provider: &dyn Provider,
        run: impl FnOnce(Self) -> Result<T, &'static str>,
    ) -> Result<T, &'static str> {
        if super::background::is_system_worker() {
            return Err("ordinary_user_required");
        }
        provider.available()?;
        super::server_settings::with_verified_options(|options| {
            let namespace = super::server_scope::namespace_from_options(options)
                .ok_or_else(|| hbb_common::anyhow::anyhow!("namespace_changed"))?;
            let user = provider
                .normal_user()
                .map_err(|reason| hbb_common::anyhow::anyhow!(reason))?;
            if !ordinary(&user) {
                return Err(hbb_common::anyhow::anyhow!("ordinary_user_required").into());
            }
            let policy =
                super::capability_policy::Repository::new(super::favorites::application_root()?)
                    .get(&namespace)?;
            if !policy.allow_requests.allows_requests(Kind::Voice) {
                return Err(hbb_common::anyhow::anyhow!("policy_disabled").into());
            }
            run(Self {
                namespace,
                generation: policy.generation,
                user,
            })
            .map_err(|reason| hbb_common::anyhow::anyhow!(reason).into())
        })
        .map_err(|error| match error.to_string().as_str() {
            "policy_disabled" => "policy_disabled",
            "namespace_changed" => "namespace_changed",
            "ordinary_user_required"
            | "ordinary_terminal_user_required"
            | "interactive_terminal_user_required" => "ordinary_user_required",
            "stale_command" => "stale_command",
            "busy" => "busy",
            "worker_failed" => "worker_failed",
            _ => "permission_unavailable",
        })
    }
}
fn ordinary(user: &NormalUser) -> bool {
    match user {
        NormalUser::Unix(uid) => *uid != 0,
        NormalUser::Windows {
            sid,
            interactive,
            elevated,
        } => {
            *interactive
                && !*elevated
                && sid.starts_with("S-1-")
                && sid.len() <= 184
                && sid[4..]
                    .split('-')
                    .all(|part| !part.is_empty() && part.bytes().all(|byte| byte.is_ascii_digit()))
                && !["S-1-5-18", "S-1-5-19", "S-1-5-20"].contains(&sid.as_str())
        }
    }
}
#[derive(Clone, Copy)]
pub(crate) struct AuthFacts {
    pub encrypted: bool,
    pub peer_authenticated: bool,
    pub totp_required: bool,
    pub totp_verified_current: bool,
}
impl AuthFacts {
    fn valid(&self) -> bool {
        self.encrypted
            && self.peer_authenticated
            && (!self.totp_required || self.totp_verified_current)
    }
}
fn bytes(hex: &str) -> Result<[u8; 16], &'static str> {
    if !dto::hex(hex, 32, true) {
        return Err("invalid_command");
    }
    let mut result = [0; 16];
    for (index, slot) in result.iter_mut().enumerate() {
        *slot = u8::from_str_radix(&hex[index * 2..index * 2 + 2], 16)
            .map_err(|_| "invalid_command")?;
    }
    Ok(result)
}
fn hash(parts: &[&[u8]]) -> String {
    let mut digest = Sha256::new();
    digest.update(b"nikodesk-voice-devices-v1");
    for part in parts {
        digest.update((part.len() as u64).to_le_bytes());
        digest.update(part);
    }
    digest
        .finalize()
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}
fn failure(error: &VoiceError) -> &'static str {
    match error {
        VoiceError::PermissionDenied => "microphone_denied",
        VoiceError::Busy => "busy",
        VoiceError::Unsupported => "unsupported",
        VoiceError::StaleBinding => "devices_changed",
        VoiceError::Closed => "cancelled",
        VoiceError::Timeout => "start_timeout",
        VoiceError::WorkerFailed => "worker_failed",
        _ => "cleanup_failed",
    }
}
#[cfg(any(target_os = "macos", target_os = "windows"))]
fn permission() -> Permission {
    #[cfg(target_os = "macos")]
    {
        match voice::macos::authorization_status() {
            1 => Permission::Authorized,
            0 => Permission::NotDetermined,
            -1 => Permission::Denied,
            -3 => Permission::Restricted,
            _ => Permission::Unavailable,
        }
    }
    #[cfg(target_os = "windows")]
    {
        match voice::windows::authorization_status_code() {
            Ok(1) => Permission::Authorized,
            Ok(-1) => Permission::Denied,
            Ok(-3) => Permission::Restricted,
            _ => Permission::Unavailable,
        }
    }
}
#[cfg(target_os = "macos")]
type Snapshot = voice::macos::DeviceSnapshot;
#[cfg(target_os = "windows")]
type Snapshot = voice::windows::DeviceSnapshot;
#[cfg(target_os = "macos")]
type Token = voice::macos::DeviceToken;
#[cfg(target_os = "windows")]
type Token = voice::windows::DeviceToken;
#[cfg(target_os = "macos")]
type Backend = voice::macos::MacBackend;
#[cfg(target_os = "windows")]
type Backend = voice::windows::WindowsBackend;
#[cfg(any(target_os = "macos", target_os = "windows"))]
struct Choice {
    device: String,
    format: String,
    token: Token,
    capture: bool,
    channels: u16,
}
#[cfg(any(target_os = "macos", target_os = "windows"))]
struct Devices {
    snapshot: Snapshot,
    catalog: Catalog,
    choices: Vec<Choice>,
}
#[cfg(any(target_os = "macos", target_os = "windows"))]
impl Devices {
    fn enumerate(status: &Status, roster: u64) -> Result<Self, &'static str> {
        let snapshot = Snapshot::enumerate().map_err(|error| failure(&error))?;
        let mut catalog = Catalog {
            identity: status.identity.clone(),
            revision: status.revision.clone(),
            roster_revision: roster.to_string(),
            microphone_permission: permission(),
            reason: "pending_local_approval".into(),
            devices: vec![],
        };
        let mut choices = vec![];
        for info in snapshot.devices() {
            #[cfg(target_os = "macos")]
            let directions = [
                (true, info.capture_channels),
                (false, info.playback_channels),
            ]
            .into_iter()
            .filter(|(_, channels)| *channels != 0)
            .collect::<Vec<_>>();
            #[cfg(target_os = "windows")]
            let directions = vec![(info.direction == voice::windows::Direction::Capture, 0)];
            for (capture, actual_channels) in directions {
                let direction = if capture { "capture" } else { "playback" };
                #[cfg(target_os = "macos")]
                let (uid, label, schema) = (&info.uid, info.label.as_str(), "coreaudio-client-v1");
                #[cfg(target_os = "windows")]
                let (uid, label, schema) = (&info.endpoint_id, "", "wasapi-shared-client-v1");
                let token = hash(&[
                    status.identity.request_nonce.as_bytes(),
                    catalog.roster_revision.as_bytes(),
                    uid.as_bytes(),
                    direction.as_bytes(),
                ])[..32]
                    .to_owned();
                let mut device = Device {
                    device_token: token.clone(),
                    uid: uid.clone(),
                    label: label.into(),
                    direction: direction.into(),
                    formats: vec![],
                };
                #[cfg(target_os = "macos")]
                let channels = vec![actual_channels];
                #[cfg(target_os = "windows")]
                let channels = {
                    let _ = actual_channels;
                    vec![1, 2]
                };
                for channels in channels {
                    let format = hash(&[
                        token.as_bytes(),
                        schema.as_bytes(),
                        &48_000u32.to_le_bytes(),
                        &channels.to_le_bytes(),
                        b"f32",
                    ])[..32]
                        .to_owned();
                    device.formats.push(Format {
                        format_token: format.clone(),
                        sample_rate: 48_000,
                        sample_format: "f32".into(),
                        channels,
                        format_schema: schema.into(),
                    });
                    choices.push(Choice {
                        device: token.clone(),
                        format,
                        token: info.token,
                        capture,
                        channels,
                    });
                }
                catalog.devices.push(device);
            }
        }
        catalog.validate()?;
        Ok(Self {
            snapshot,
            catalog,
            choices,
        })
    }
    fn approve(&self, selection: &Selection) -> Result<Backend, &'static str> {
        if !selection.valid() || selection.roster_revision != self.catalog.roster_revision {
            return Err("devices_changed");
        }
        let capture = self
            .choices
            .iter()
            .find(|c| {
                c.capture
                    && c.device == selection.capture_token
                    && c.format == selection.capture_format_token
            })
            .ok_or("invalid_selection")?;
        let playback = self
            .choices
            .iter()
            .find(|c| {
                !c.capture
                    && c.device == selection.playback_token
                    && c.format == selection.playback_format_token
            })
            .ok_or("invalid_selection")?;
        self.snapshot
            .select(
                capture.token,
                playback.token,
                capture.channels,
                playback.channels,
            )
            .map_err(|error| failure(&error))
    }
}
/// Only native adapters implement this local metadata/ordinary-user boundary.
/// No Provider may derive consent from a device ID, permission bool or wire data.
pub(crate) trait Provider: Send + 'static {
    /// Only checks the compiled/native bridge is present. Never enumerate,
    /// request permission, construct a device, or infer local consent here.
    fn available(&self) -> Result<(), &'static str>;
    fn normal_user(&self) -> Result<NormalUser, &'static str>;
    fn permission(&self) -> Permission;
    fn enumerate(&mut self, status: &Status, roster: u64) -> Result<Box<dyn Roster>, &'static str>;
    fn request_permission(&mut self) -> Result<Box<dyn PermissionJob>, &'static str>;
}
pub(crate) trait PermissionJob: Send {
    fn poll(&mut self) -> Option<Permission>;
    fn cancel(&mut self);
}
pub(crate) trait Roster: Send {
    fn catalog(&self) -> &Catalog;
    fn select(
        &self,
        selection: &Selection,
        binding: voice::Binding,
        allow_background: bool,
    ) -> Result<Box<dyn SelectionJob>, &'static str>;
}
pub(crate) trait SelectionJob: Send {
    /// Android can wait for its explicit visible-Activity consent/proof job.
    /// Completing this metadata job does not start or grant native media.
    fn poll(&mut self) -> Result<Option<Prepared>, &'static str>;
    fn cancel(&mut self);
}
pub(crate) struct Prepared {
    native_lease: u64,
    exact: Vec<u8>,
    allow_background: bool,
    start:
        Box<dyn FnOnce(voice::Binding, Arc<AtomicBool>) -> Result<VoiceOwner, VoiceError> + Send>,
}
impl Prepared {
    pub(crate) fn for_backend<B: voice::VoiceBackend>(
        backend: B,
        binding: voice::Binding,
        native_lease: u64,
        exact: Vec<u8>,
        allow_background: bool,
    ) -> Result<Self, &'static str> {
        if native_lease == 0 || exact.is_empty() || exact.len() > 1024 * 1024 {
            return Err("invalid_selection");
        }
        Ok(Self {
            native_lease,
            exact,
            allow_background,
            start: Box::new(move |current, cancel| {
                if current != binding {
                    return Err(VoiceError::StaleBinding);
                }
                VoiceOwner::start_guarded(current, backend, cancel)
            }),
        })
    }
    fn fingerprint(
        &self,
        identity: &Identity,
        wire: &Wire,
        context: &Context,
        selection: &Selection,
    ) -> Result<String, &'static str> {
        let call =
            serde_json::to_vec(&(identity, wire, selection)).map_err(|_| "invalid_selection")?;
        let user = match &context.user {
            NormalUser::Unix(uid) => format!("unix:{uid}"),
            NormalUser::Windows {
                sid,
                interactive,
                elevated,
            } => format!("windows:{sid}:{interactive}:{elevated}"),
        };
        Ok(hash(&[
            &call,
            &self.exact,
            context.namespace.as_bytes(),
            &context.generation.to_le_bytes(),
            user.as_bytes(),
            &self.native_lease.to_le_bytes(),
            &[self.allow_background as u8],
        ]))
    }
}
#[cfg(any(target_os = "macos", target_os = "windows"))]
struct DesktopProvider;
#[cfg(any(target_os = "macos", target_os = "windows"))]
impl Provider for DesktopProvider {
    fn available(&self) -> Result<(), &'static str> {
        Ok(())
    }
    fn normal_user(&self) -> Result<NormalUser, &'static str> {
        super::connection_capabilities::normal_user().map_err(|_| "ordinary_user_required")
    }
    fn permission(&self) -> Permission {
        permission()
    }
    fn enumerate(&mut self, status: &Status, roster: u64) -> Result<Box<dyn Roster>, &'static str> {
        Ok(Box::new(Devices::enumerate(status, roster)?))
    }
    fn request_permission(&mut self) -> Result<Box<dyn PermissionJob>, &'static str> {
        #[cfg(target_os = "macos")]
        {
            Ok(Box::new(
                voice::macos::PermissionRequest::begin().map_err(|_| "permission_unavailable")?,
            ))
        }
        #[cfg(target_os = "windows")]
        {
            Err("unsupported")
        }
    }
}
#[cfg(target_os = "macos")]
impl PermissionJob for voice::macos::PermissionRequest {
    fn poll(&mut self) -> Option<Permission> {
        self.try_result().map(|status| match status {
            1 => Permission::Authorized,
            0 => Permission::NotDetermined,
            -1 => Permission::Denied,
            -3 => Permission::Restricted,
            _ => Permission::Unavailable,
        })
    }
    fn cancel(&mut self) {
        voice::macos::PermissionRequest::cancel(self);
    }
}
#[cfg(any(target_os = "macos", target_os = "windows"))]
struct ImmediateSelection(Option<Prepared>);
#[cfg(any(target_os = "macos", target_os = "windows"))]
impl SelectionJob for ImmediateSelection {
    fn poll(&mut self) -> Result<Option<Prepared>, &'static str> {
        Ok(self.0.take())
    }
    fn cancel(&mut self) {
        self.0 = None;
    }
}
#[cfg(any(target_os = "macos", target_os = "windows"))]
impl Roster for Devices {
    fn catalog(&self) -> &Catalog {
        &self.catalog
    }
    fn select(
        &self,
        selection: &Selection,
        binding: voice::Binding,
        allow_background: bool,
    ) -> Result<Box<dyn SelectionJob>, &'static str> {
        if allow_background {
            return Err("unsupported");
        }
        let backend = self.approve(selection)?;
        let lease = backend.native_lease();
        let selected = self
            .catalog
            .devices
            .iter()
            .filter(|device| {
                device.device_token == selection.capture_token
                    || device.device_token == selection.playback_token
            })
            .collect::<Vec<_>>();
        if selected.len() != 2 {
            return Err("invalid_selection");
        }
        let exact = serde_json::to_vec(&selected).map_err(|_| "invalid_selection")?;
        Ok(Box::new(ImmediateSelection(Some(Prepared::for_backend(
            backend, binding, lease, exact, false,
        )?))))
    }
}
struct Gate {
    state: Capabilities,
    ticket: Ticket,
    stop: Option<StopTicket>,
    scope: Scope,
    expires: Instant,
}
impl Gate {
    fn approved(identity: &Identity, fingerprint: String) -> Result<Self, &'static str> {
        let binding = CapabilityBinding::new(
            identity.namespace.clone(),
            identity.peer_id.clone(),
            bytes(&identity.connection_nonce)?,
        )
        .map_err(|_| "authentication_required")?;
        let mut state = Capabilities::new(binding, true, true);
        state
            .set_policy(Kind::Voice, true, true)
            .map_err(|_| "policy_disabled")?;
        let scope = Scope::VoiceDevices { fingerprint };
        let now = Instant::now();
        let request = state
            .request(scope.clone(), bytes(&identity.request_nonce)?, now)
            .map_err(|_| "busy")?;
        if request.epoch().to_string() != identity.epoch {
            return Err("stale_command");
        }
        let ticket = state
            .approve(&request, now, Duration::from_secs(60 * 60))
            .map_err(|_| "stale_command")?;
        let expires = now.checked_add(Duration::from_secs(60 * 60)).ok_or("worker_failed")?;
        Ok(Self {
            state,
            ticket,
            stop: None,
            scope,
            expires,
        })
    }
    fn live(&self) -> bool {
        let now = Instant::now();
        self.state.may_start(&self.ticket, now)
            || self.state.may_execute(&self.ticket, &self.scope, now)
    }
    fn revoke(&mut self) {
        if self.stop.is_none() {
            self.stop = self.state.revoke(Kind::Voice).ok().flatten();
        }
    }
}
struct Watchdog {
    origin: Instant,
    verified: AtomicU64,
    done: AtomicBool,
}
impl Watchdog {
    fn verified(&self) {
        self.verified.store(
            self.origin.elapsed().as_millis().min(u64::MAX as u128) as u64,
            Ordering::Release,
        );
    }
    fn expired(&self) -> bool {
        self.origin
            .elapsed()
            .as_millis()
            .saturating_sub(self.verified.load(Ordering::Acquire) as u128)
            > 1000
    }
}
struct Done(Arc<Watchdog>);
impl Drop for Done {
    fn drop(&mut self) {
        self.0.done.store(true, Ordering::Release);
    }
}
struct Shared {
    status: Status,
    catalog: Option<Catalog>,
    media: Option<MediaIo>,
    gate_live: bool,
    grant_expires: Option<Instant>,
    join_failed: bool,
    denied_locally: bool,
}
enum Message {
    Local(Command),
    Accepted(Wire),
}
type Observer = Arc<dyn Fn(Status) + Send + Sync>;
pub(crate) struct Flow {
    shared: Arc<Mutex<Shared>>,
    commands: SyncSender<Message>,
    cancel: Arc<AtomicBool>,
    retired: Arc<AtomicBool>,
    worker: Option<JoinHandle<()>>,
    watchdog: Option<JoinHandle<()>>,
    join_failed: bool,
    binding: voice::Binding,
    policy_clock: Arc<Watchdog>,
}
fn default_provider() -> Result<Box<dyn Provider>, &'static str> {
    #[cfg(any(target_os = "macos", target_os = "windows"))]
    {
        Ok(Box::new(DesktopProvider))
    }
    #[cfg(target_os = "android")]
    {
        Ok(voice::android::runtime_adapter::provider())
    }
    #[cfg(not(any(target_os = "macos", target_os = "windows", target_os = "android")))]
    {
        Err("unsupported")
    }
}
/// Blocking, read-only availability check. Session/Connection callers must
/// dispatch this to their existing blocking worker, never a UI/network loop.
/// Permission, a selected device and a per-call local grant are separate facts.
pub(crate) fn availability(namespace: &str) -> Result<(), &'static str> {
    if !dto::hex(namespace, 64, false) {
        return Err("namespace_changed");
    }
    let provider = default_provider()?;
    let context = Context::capture(provider.as_ref())?;
    if context.namespace != namespace {
        return Err("namespace_changed");
    }
    Ok(())
}
impl Flow {
    /// Root supplies these facts ONLY from the actual current login boundary;
    /// required TOTP cannot be satisfied by a remembered display/audit field.
    pub(crate) fn authenticated(
        identity: Identity,
        wire: Wire,
        facts: AuthFacts,
        observer: Observer,
    ) -> Result<Self, &'static str> {
        Self::authenticated_with_provider(identity, wire, facts, default_provider()?, observer)
    }
    pub(crate) fn authenticated_with_provider(
        identity: Identity,
        wire: Wire,
        facts: AuthFacts,
        provider: Box<dyn Provider>,
        observer: Observer,
    ) -> Result<Self, &'static str> {
        if !facts.valid() {
            return Err("authentication_required");
        }
        let binding = voice::Binding::new(
            bytes(&wire.call_nonce)?,
            wire.call_epoch.parse().map_err(|_| "invalid_command")?,
        )
        .map_err(|_| "invalid_command")?;
        let status = Status::pending(identity, wire)?;
        let shared = Arc::new(Mutex::new(Shared {
            status,
            catalog: None,
            media: None,
            gate_live: false,
            grant_expires: None,
            join_failed: false,
            denied_locally: false,
        }));
        let cancel = Arc::new(AtomicBool::new(false));
        let retired = Arc::new(AtomicBool::new(false));
        let (commands, receiver) = mpsc::sync_channel(8);
        let worker_shared = shared.clone();
        let worker_cancel = cancel.clone();
        let worker_retired = retired.clone();
        let clock = Arc::new(Watchdog {
            origin: Instant::now(),
            verified: AtomicU64::new(0),
            done: AtomicBool::new(false),
        });
        let monitor_clock = clock.clone();
        let failed_clock = clock.clone();
        let policy_clock = clock.clone();
        let monitor_cancel = cancel.clone();
        let watchdog = thread::Builder::new()
            .name("niko-voice-policy-watchdog".into())
            .spawn(move || {
                while !monitor_clock.done.load(Ordering::Acquire) {
                    if monitor_clock.expired() {
                        monitor_cancel.store(true, Ordering::Release);
                    }
                    thread::sleep(Duration::from_millis(25));
                }
            })
            .map_err(|_| "worker_failed")?;
        let worker = thread::Builder::new()
            .name("niko-voice-flow".into())
            .spawn(move || {
                let _done = Done(clock.clone());
                run(
                    worker_shared,
                    worker_cancel,
                    worker_retired,
                    receiver,
                    binding,
                    observer,
                    clock,
                    provider,
                )
            });
        let worker = match worker {
            Ok(worker) => worker,
            Err(_) => {
                cancel.store(true, Ordering::Release);
                failed_clock.done.store(true, Ordering::Release);
                let _ = watchdog.join();
                return Err("worker_failed");
            }
        };
        Ok(Self {
            shared,
            commands,
            cancel,
            retired,
            worker: Some(worker),
            watchdog: Some(watchdog),
            join_failed: false,
            binding,
            policy_clock,
        })
    }
    pub(crate) fn status(&self) -> Status {
        self.shared
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .status
            .clone()
    }
    pub(crate) fn take_catalog(&self) -> Option<Catalog> {
        self.shared
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .catalog
            .take()
    }
    pub(crate) fn command(&self, command: Command) -> Result<Reply, &'static str> {
        let mut state = self.shared.lock().map_err(|_| "worker_failed")?;
        let encoded = serde_json::to_string(&command).map_err(|_| "invalid_command")?;
        Command::parse(&encoded)?;
        if command.identity != state.status.identity || command.revision != state.status.revision {
            return Err("stale_command");
        }
        if self.retired.load(Ordering::Acquire)
            && !matches!(command.op, Operation::Query | Operation::RetryCleanup)
        {
            return Err("cleanup_pending");
        }
        if !matches!(
            command.op,
            Operation::Query | Operation::Revoke | Operation::RetryCleanup
        ) && !matches!(
            (state.status.phase, command.op),
            (
                Phase::Pending,
                Operation::Enumerate
                    | Operation::Approve
                    | Operation::Deny
                    | Operation::RequestPermission
            ) | (
                Phase::Starting | Phase::Running,
                Operation::Mute | Operation::Unmute
            )
        ) {
            return Err("invalid_command");
        }
        if matches!(
            command.op,
            Operation::Revoke | Operation::Deny | Operation::RetryCleanup
        ) {
            if command.op == Operation::Deny { state.denied_locally = true; }
            self.cancel.store(true, Ordering::Release);
        }
        let reply = Reply::queued(&command);
        self.commands
            .try_send(Message::Local(command))
            .map_err(|error| match error {
                TrySendError::Full(_) => "busy",
                TrySendError::Disconnected(_) => "worker_failed",
            })?;
        Ok(reply)
    }
    /// This is a peer fact from the existing secured call handshake, never a
    /// deserializable CM command and never local device authorization.
    pub(crate) fn peer_accepted(&self, wire: &Wire) -> Result<(), &'static str> {
        let status = self.status();
        if wire != &status.wire || self.retired.load(Ordering::Acquire) {
            return Err("stale_command");
        }
        if status.phase != Phase::Running
            || !status.local_ready
            || self.cancel.load(Ordering::Acquire)
        {
            return Err("not_ready");
        }
        self.commands
            .try_send(Message::Accepted(wire.clone()))
            .map_err(|_| "busy")
    }
    pub(crate) fn incoming(&self, packet: EncodedPacket) -> Result<(), VoiceError> {
        let state = self.shared.lock().map_err(|_| VoiceError::WorkerFailed)?;
        if self.cancel.load(Ordering::Acquire)
            || !state.gate_live
            || !state.status.peer_accepted
            || self.retired.load(Ordering::Acquire)
        {
            return Err(VoiceError::Closed);
        }
        state
            .media
            .as_ref()
            .ok_or(VoiceError::NotReady)?
            .enqueue_incoming(packet)
    }
    pub(crate) fn take_outgoing(&self) -> Result<Option<EncodedPacket>, VoiceError> {
        let state = self.shared.lock().map_err(|_| VoiceError::WorkerFailed)?;
        if self.cancel.load(Ordering::Acquire)
            || !state.gate_live
            || state.status.phase != Phase::Running
            || !state.status.peer_accepted
            || self.retired.load(Ordering::Acquire)
        {
            return Err(VoiceError::Closed);
        }
        state
            .media
            .as_ref()
            .ok_or(VoiceError::NotReady)?
            .take_outgoing(self.binding)
    }
    /// Check again at network execution, including the same verified-policy
    /// deadline used by the watchdog. Peer acceptance is deliberately absent
    /// here: the initial request/response/format establishes that handshake.
    pub(crate) fn may_negotiate(&self, wire: &Wire) -> bool {
        self.send_gate(wire, false)
    }
    fn send_gate(&self, wire: &Wire, media: bool) -> bool {
        self.shared.lock().map_or(false, |s| {
                s.gate_live
                    && s.status.phase == Phase::Running
                    && s.status.local_ready
                    && s.status.wire == *wire
                    && s.grant_expires.is_some_and(|expires| Instant::now() < expires)
                    && (!media || (s.status.peer_accepted && !s.status.muted))
                    && !self.cancel.load(Ordering::Acquire)
                    && !self.retired.load(Ordering::Acquire)
                    && !self.policy_clock.expired()
            })
    }
    pub(crate) fn may_send(&self, wire: &Wire) -> bool {
        self.send_gate(wire, true)
    }
    /// Hang up this current call immediately, even when its command queue is
    /// full. Cleanup/Stopped is still confirmed only by the owned worker.
    pub(crate) fn cancel(&self) {
        self.cancel.store(true, Ordering::Release);
    }
    pub(crate) fn retire(&mut self) -> bool {
        self.retired.store(true, Ordering::Release);
        self.cancel.store(true, Ordering::Release);
        let mut state = self
            .shared
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        state.gate_live = false;
        if state.status.cleanup_only { return false; }
        state.status.cleanup_only = true;
        state.catalog = None;
        state.status.local_ready = false;
        state.status.peer_accepted = false;
        state.status.call_running = false;
        let (phase, reason) = if state.join_failed || state.status.phase == Phase::RecoveryRequired {
            (Phase::RecoveryRequired, "worker_failed")
        } else { (Phase::Revoking, "cleanup_pending") };
        if state.status.advance(phase, reason).is_err() {
            state.status.phase = Phase::RecoveryRequired;
            state.status.reason = "worker_failed".into();
        }
        true
    }
    pub(crate) fn finished(&mut self) -> Result<bool, &'static str> {
        if self
            .watchdog
            .as_ref()
            .is_some_and(|worker| !worker.is_finished())
        {
            return if self.join_failed {
                Err("worker_failed")
            } else {
                Ok(false)
            };
        }
        if let Some(watchdog) = self.watchdog.take() {
            if watchdog.join().is_err() {
                self.mark_join_failure();
            }
        }
        if self
            .worker
            .as_ref()
            .is_some_and(|worker| !worker.is_finished())
        {
            return if self.join_failed {
                Err("worker_failed")
            } else {
                Ok(false)
            };
        }
        if let Some(worker) = self.worker.take() {
            if worker.join().is_err() {
                self.mark_join_failure();
            }
        }
        if self.join_failed {
            return Err("worker_failed");
        }
        Ok(self.status().phase == Phase::Stopped)
    }
    fn mark_join_failure(&mut self) {
        self.cancel.store(true, Ordering::Release);
        self.join_failed = true;
        let mut state = self
            .shared
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        if state.join_failed {
            return;
        }
        state.join_failed = true;
        state.catalog = None;
        state.gate_live = false;
        // Internal failure closes this resource, not its still-live desktop
        // parent. Only explicit parent retirement creates a cleanup-only row.
        state.status.cleanup_only = self.retired.load(Ordering::Acquire);
        state.status.local_ready = false;
        state.status.peer_accepted = false;
        state.status.call_running = false;
        if state
            .status
            .advance(Phase::RecoveryRequired, "worker_failed")
            .is_err()
        {
            state.status.phase = Phase::RecoveryRequired;
            state.status.reason = "worker_failed".into();
        }
    }
}
#[cfg(test)]
pub(crate) fn cleanup_test_flow(done: Receiver<()>) -> Flow {
    let (mut flow, _receiver) = tests::frontend();
    {
        let mut state = flow.shared.lock().unwrap();
        state.status.cleanup_only = true;
        state.status.advance(Phase::Revoking, "cleanup_pending").unwrap();
    }
    let shared = flow.shared.clone();
    flow.worker = Some(thread::spawn(move || {
        done.recv().unwrap();
        let observer: Observer = Arc::new(|_| {});
        publish(&shared, &observer, Phase::Stopped, "stopped");
    }));
    flow
}
#[cfg(test)]
pub(crate) fn send_test_flow(ready: bool, accepted: bool, expired: bool) -> Flow {
    let (mut flow, _receiver) = tests::frontend();
    {
        let mut state = flow.shared.lock().unwrap();
        state.gate_live = ready;
        state.grant_expires = ready.then(|| Instant::now() + Duration::from_secs(60));
        state.status.local_ready = ready;
        state.status.peer_accepted = accepted;
        if ready { state.status.advance(Phase::Running, "running").unwrap(); }
    }
    if expired {
        flow.policy_clock = Arc::new(Watchdog {
            origin: Instant::now() - Duration::from_secs(2),
            verified: AtomicU64::new(0),
            done: AtomicBool::new(false),
        });
    }
    flow
}
#[cfg(test)]
pub(crate) fn join_failure_test_flow() -> Flow {
    let (mut flow, _receiver) = tests::frontend();
    let worker = thread::spawn(|| panic!("synthetic call actor panic"));
    while !worker.is_finished() { thread::yield_now(); }
    flow.worker = Some(worker);
    flow
}
struct Orphan {
    shared: Arc<Mutex<Shared>>,
    worker: Option<JoinHandle<()>>,
    watchdog: Option<JoinHandle<()>>,
    failed: bool,
}
impl Orphan {
    fn reap(&mut self) -> bool {
        if self.failed
            || self
                .worker
                .as_ref()
                .is_some_and(|worker| !worker.is_finished())
            || self
                .watchdog
                .as_ref()
                .is_some_and(|worker| !worker.is_finished())
        {
            return false;
        }
        let worker_failed = self
            .worker
            .take()
            .is_some_and(|worker| worker.join().is_err());
        let watchdog_failed = self
            .watchdog
            .take()
            .is_some_and(|worker| worker.join().is_err());
        let mut state = self
            .shared
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        if state.join_failed {
            self.failed = true;
            return false;
        }
        if worker_failed || watchdog_failed || state.status.phase != Phase::Stopped {
            self.failed = true;
            state.gate_live = false;
            state.status.cleanup_only = true;
            let _ = state
                .status
                .advance(Phase::RecoveryRequired, "worker_failed");
            return false;
        }
        true
    }
}
static ORPHANS: Mutex<Vec<Orphan>> = Mutex::new(Vec::new());
impl Drop for Flow {
    fn drop(&mut self) {
        self.retire();
        if let Some(worker) = self.worker.take() {
            // Pure cleanup ownership only. No lost native worker/join, new
            // trust channel, reauthorization, or Drop-derived stop ACK.
            let mut orphans = ORPHANS.lock().unwrap_or_else(|error| error.into_inner());
            for index in (0..orphans.len()).rev() {
                if orphans[index].reap() {
                    orphans.remove(index);
                }
            }
            orphans.push(Orphan {
                shared: self.shared.clone(),
                worker: Some(worker),
                watchdog: self.watchdog.take(),
                failed: false,
            });
        }
    }
}
fn publish(shared: &Arc<Mutex<Shared>>, observer: &Observer, phase: Phase, reason: &'static str) {
    let status = {
        let mut state = shared.lock().unwrap_or_else(|error| error.into_inner());
        state.catalog = None;
        // A failed join cannot be undone by the surviving actor's late cleanup
        // publication. Keep this owner's final snapshot unconfirmed.
        if state.join_failed {
            state.gate_live = false;
            state.status.local_ready = false;
            state.status.peer_accepted = false;
            state.status.call_running = false;
            return;
        }
        let reason = if phase == Phase::Stopped && state.denied_locally { "denied" } else { reason };
        if state.status.advance(phase, reason).is_err() {
            state.status.phase = Phase::RecoveryRequired;
            state.status.reason = "worker_failed".into();
            state.gate_live = false;
        }
        state.status.clone()
    };
    let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| observer(status)));
}
fn run(
    shared: Arc<Mutex<Shared>>,
    cancel: Arc<AtomicBool>,
    retired: Arc<AtomicBool>,
    commands: Receiver<Message>,
    binding: voice::Binding,
    observer: Observer,
    clock: Arc<Watchdog>,
    mut provider: Box<dyn Provider>,
) {
    let context = match Context::capture(provider.as_ref()) {
        Ok(context)
            if context.namespace
                == shared
                    .lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .status
                    .identity
                    .namespace =>
        {
            context
        }
        Ok(_) => {
            publish(&shared, &observer, Phase::Stopped, "namespace_changed");
            return;
        }
        Err(reason) => {
            publish(&shared, &observer, Phase::Stopped, reason);
            return;
        }
    };
    clock.verified();
    let mut devices: Option<Box<dyn Roster>> = None;
    let mut owner: Option<VoiceOwner> = None;
    let mut gate: Option<Gate> = None;
    let mut permission_job: Option<(Box<dyn PermissionJob>, Instant)> = None;
    let mut approval_job: Option<(Box<dyn SelectionJob>, Selection, Instant)> = None;
    let mut roster = 0u64;
    let mut refresh = Instant::now();
    let mut started_at: Option<Instant> = None;
    loop {
        if retired.load(Ordering::Acquire) {
            let mut state = shared.lock().unwrap_or_else(|e| e.into_inner());
            if !state.status.cleanup_only {
                state.status.cleanup_only = true;
                let phase = state.status.phase;
                drop(state);
                publish(&shared, &observer, phase, "cleanup_pending");
            }
        }
        if let Some((job, selection, since)) = &mut approval_job {
            if cancel.load(Ordering::Acquire) || retired.load(Ordering::Acquire) {
                job.cancel();
                approval_job = None;
            } else if since.elapsed() > Duration::from_secs(30) {
                job.cancel();
                approval_job = None;
                publish(&shared, &observer, Phase::Pending, "start_timeout");
            } else {
                let prepared =
                    std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| job.poll()))
                        .unwrap_or(Err("worker_failed"));
                match prepared {
                    Ok(Some(prepared)) => {
                        let selection = selection.clone();
                        approval_job = None;
                        let status = shared
                            .lock()
                            .unwrap_or_else(|e| e.into_inner())
                            .status
                            .clone();
                        let result = (|| {
                            if provider.permission() != Permission::Authorized {
                                return Err("microphone_denied");
                            }
                            let fingerprint = prepared.fingerprint(
                                &status.identity,
                                &status.wire,
                                &context,
                                &selection,
                            )?;
                            Context::with_current(provider.as_ref(), |current| {
                                if current != context || cancel.load(Ordering::Acquire) {
                                    return Err("namespace_changed");
                                }
                                let approved = Gate::approved(&status.identity, fingerprint)?;
                                let resource = (prepared.start)(binding, cancel.clone())
                                    .map_err(|error| failure(&error))?;
                                Ok((approved, resource))
                            })
                        })();
                        match result {
                            Ok((approved, resource)) => {
                                {
                                    let mut state =
                                        shared.lock().unwrap_or_else(|e| e.into_inner());
                                    state.status.selection = Some(selection);
                                    state.media = Some(resource.media());
                                    state.gate_live = true;
                                    state.grant_expires = Some(approved.expires);
                                }
                                gate = Some(approved);
                                owner = Some(resource);
                                started_at = Some(Instant::now());
                                publish(&shared, &observer, Phase::Starting, "starting");
                            }
                            Err(reason) => publish(&shared, &observer, Phase::Pending, reason),
                        }
                    }
                    Ok(None) => (),
                    Err(reason) => {
                        job.cancel();
                        approval_job = None;
                        publish(&shared, &observer, Phase::Pending, reason)
                    }
                }
            }
        }
        if let Some((job, since)) = &mut permission_job {
            if cancel.load(Ordering::Acquire) || retired.load(Ordering::Acquire) {
                job.cancel();
                permission_job = None;
            } else if let Some(result) = job.poll() {
                permission_job = None;
                if Context::capture(provider.as_ref()).ok().as_ref() == Some(&context) {
                    let mut state = shared.lock().unwrap_or_else(|e| e.into_inner());
                    state.status.microphone_permission = result;
                    let phase = state.status.phase;
                    drop(state);
                    publish(&shared, &observer, phase, "pending_local_approval");
                } else {
                    cancel.store(true, Ordering::Release);
                }
            } else if since.elapsed() > Duration::from_secs(15) {
                job.cancel();
                permission_job = None;
                publish(&shared, &observer, Phase::Pending, "permission_unavailable");
            }
        }
        if cancel.load(Ordering::Acquire) {
            if let Some(gate) = &mut gate {
                gate.revoke();
                if let Some(stop) = &gate.stop {
                    shared
                        .lock()
                        .unwrap_or_else(|e| e.into_inner())
                        .status
                        .resource_epoch = stop.epoch().to_string();
                }
            }
            shared.lock().unwrap_or_else(|e| e.into_inner()).gate_live = false;
            if let Some(resource) = &mut owner {
                resource.cancel();
                let current = shared
                    .lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .status
                    .phase;
                if !matches!(current, Phase::Revoking | Phase::RecoveryRequired) {
                    publish(&shared, &observer, Phase::Revoking, "revoking");
                }
                match resource.try_stop() {
                    Ok(true) => {
                        if let Some(gate) = &mut gate {
                            if let Some(stop) = &gate.stop {
                                if gate.state.did_stop(stop, true).is_err() {
                                    publish(
                                        &shared,
                                        &observer,
                                        Phase::RecoveryRequired,
                                        "cleanup_failed",
                                    );
                                    continue;
                                }
                            } else {
                                publish(
                                    &shared,
                                    &observer,
                                    Phase::RecoveryRequired,
                                    "cleanup_failed",
                                );
                                continue;
                            }
                        }
                        shared.lock().unwrap_or_else(|e| e.into_inner()).media = None;
                        publish(&shared, &observer, Phase::Stopped, "stopped");
                        return;
                    }
                    Ok(false) => {
                        if current != Phase::RecoveryRequired {
                            publish(
                                &shared,
                                &observer,
                                Phase::RecoveryRequired,
                                "cleanup_pending",
                            );
                        }
                    }
                    Err(_) => {
                        if current != Phase::RecoveryRequired {
                            publish(
                                &shared,
                                &observer,
                                Phase::RecoveryRequired,
                                "cleanup_failed",
                            );
                        }
                    }
                }
            } else {
                publish(&shared, &observer, Phase::Stopped, "stopped");
                return;
            }
        }
        if !cancel.load(Ordering::Acquire) && refresh.elapsed() >= Duration::from_millis(250) {
            refresh = Instant::now();
            match Context::capture(provider.as_ref()) {
                Ok(current) if current == context => clock.verified(),
                _ => {
                    cancel.store(true, Ordering::Release);
                    continue;
                }
            }
            if gate.as_ref().is_some_and(|g| !g.live()) {
                cancel.store(true, Ordering::Release);
                continue;
            }
        }
        if !cancel.load(Ordering::Acquire) {
            if let Some(resource) = &owner {
                match resource.ready() {
                    Ok(true)
                        if shared
                            .lock()
                            .unwrap_or_else(|e| e.into_inner())
                            .status
                            .phase
                            == Phase::Starting =>
                    {
                        if let Some(g) = &mut gate {
                            if g.state.did_start(&g.ticket, Instant::now()).is_err() {
                                cancel.store(true, Ordering::Release);
                                continue;
                            }
                        }
                        {
                            let mut state = shared.lock().unwrap_or_else(|e| e.into_inner());
                            state.status.local_ready = true;
                            state.gate_live = true;
                        }
                        publish(&shared, &observer, Phase::Running, "running");
                    }
                    Err(_) => {
                        cancel.store(true, Ordering::Release);
                        continue;
                    }
                    _ => (),
                }
                if started_at.is_some_and(|time: Instant| time.elapsed() > Duration::from_secs(10))
                    && shared
                        .lock()
                        .unwrap_or_else(|e| e.into_inner())
                        .status
                        .phase
                        == Phase::Starting
                {
                    cancel.store(true, Ordering::Release);
                    publish(&shared, &observer, Phase::Revoking, "start_timeout");
                    continue;
                }
            }
        }
        let message = match commands.recv_timeout(Duration::from_millis(25)) {
            Ok(message) => message,
            Err(mpsc::RecvTimeoutError::Timeout) => continue,
            Err(mpsc::RecvTimeoutError::Disconnected) => {
                cancel.store(true, Ordering::Release);
                continue;
            }
        };
        if let Message::Accepted(wire) = &message {
            let mut state = shared.lock().unwrap_or_else(|e| e.into_inner());
            if !cancel.load(Ordering::Acquire)
                && !retired.load(Ordering::Acquire)
                && state.status.wire == *wire
            {
                state.status.peer_accepted = true;
                let phase = state.status.phase;
                drop(state);
                publish(
                    &shared,
                    &observer,
                    phase,
                    match phase {
                        Phase::Running => "running",
                        Phase::Starting => "starting",
                        _ => "pending_local_approval",
                    },
                );
            }
            continue;
        }
        let Message::Local(command) = message else {
            continue;
        };
        let status = shared
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .status
            .clone();
        if command.identity != status.identity || command.revision != status.revision {
            continue;
        }
        if matches!(command.op, Operation::Query | Operation::RetryCleanup) {
            let snapshot = shared
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .status
                .clone();
            let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| observer(snapshot)));
            if command.op == Operation::Query {
                continue;
            }
        }
        if cancel.load(Ordering::Acquire) || retired.load(Ordering::Acquire) {
            continue;
        }
        let fresh = match Context::capture(provider.as_ref()) {
            Ok(fresh) if fresh == context => fresh,
            _ => {
                cancel.store(true, Ordering::Release);
                continue;
            }
        };
        match command.op {
            Operation::Query => (),
            Operation::Enumerate if status.phase == Phase::Pending && approval_job.is_none() => {
                roster = match roster.checked_add(1) {
                    Some(n) => n,
                    None => {
                        cancel.store(true, Ordering::Release);
                        continue;
                    }
                };
                match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                    provider.enumerate(&status, roster)
                }))
                .unwrap_or(Err("worker_failed"))
                {
                    Ok(catalog) => {
                        if Context::capture(provider.as_ref()).ok().as_ref() != Some(&fresh)
                            || cancel.load(Ordering::Acquire)
                        {
                            cancel.store(true, Ordering::Release);
                            continue;
                        }
                        shared
                            .lock()
                            .unwrap_or_else(|e| e.into_inner())
                            .status
                            .microphone_permission = catalog.catalog().microphone_permission;
                        publish(&shared, &observer, Phase::Pending, "pending_local_approval");
                        let mut state = shared.lock().unwrap_or_else(|e| e.into_inner());
                        let mut dto = catalog.catalog().clone();
                        dto.revision = state.status.revision.clone();
                        state.catalog = Some(dto);
                        devices = Some(catalog);
                    }
                    Err(reason) => publish(&shared, &observer, Phase::Pending, reason),
                }
            }
            Operation::Approve if status.phase == Phase::Pending && approval_job.is_none() => {
                let selected = (|| {
                    if provider.permission() != Permission::Authorized {
                        return Err("microphone_denied");
                    }
                    let selection = command.selection()?;
                    let devices = devices.as_ref().ok_or("invalid_selection")?;
                    let job = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                        devices.select(
                            &selection,
                            binding,
                            command.allow_background.unwrap_or(false),
                        )
                    }))
                    .unwrap_or(Err("worker_failed"))?;
                    Ok((job, selection))
                })();
                match selected {
                    Ok((job, selection)) => approval_job = Some((job, selection, Instant::now())),
                    Err(reason) => publish(&shared, &observer, Phase::Pending, reason),
                }
            }
            Operation::Mute | Operation::Unmute
                if matches!(status.phase, Phase::Starting | Phase::Running) =>
            {
                let mut state = shared.lock().unwrap_or_else(|e| e.into_inner());
                state.status.muted = command.op == Operation::Mute;
                if let Some(io) = &state.media {
                    io.set_muted(state.status.muted);
                }
                let phase = state.status.phase;
                let muted = state.status.muted;
                drop(state);
                publish(
                    &shared,
                    &observer,
                    phase,
                    if muted { "muted" } else { "running" },
                );
            }
            Operation::Deny | Operation::Revoke | Operation::RetryCleanup => {
                cancel.store(true, Ordering::Release);
            }
            Operation::RequestPermission if status.phase == Phase::Pending => {
                let current = provider.permission();
                shared
                    .lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .status
                    .microphone_permission = current;
                if current == Permission::NotDetermined && permission_job.is_none() {
                    match provider.request_permission() {
                        Ok(job) => {
                            permission_job = Some((job, Instant::now()));
                            publish(
                                &shared,
                                &observer,
                                Phase::Pending,
                                "microphone_not_determined",
                            );
                        }
                        Err(reason) => publish(&shared, &observer, Phase::Pending, reason),
                    }
                } else {
                    publish(
                        &shared,
                        &observer,
                        Phase::Pending,
                        if permission_job.is_some() {
                            "busy"
                        } else {
                            "pending_local_approval"
                        },
                    );
                }
            }
            _ => publish(&shared, &observer, status.phase, "invalid_command"),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn status() -> Status {
        Status::pending(
            Identity {
                connection_id: 7,
                namespace: "a".repeat(64),
                peer_id: "123456789".into(),
                connection_nonce: "1".repeat(32),
                request_nonce: "2".repeat(32),
                epoch: "1".into(),
            },
            Wire {
                call_nonce: "3".repeat(32),
                call_epoch: "8".into(),
            },
        )
        .unwrap()
    }
    fn command(status: &Status, op: Operation) -> Command {
        Command::parse(
            &serde_json::json!({"identity":status.identity,"revision":status.revision,"op":op})
                .to_string(),
        )
        .unwrap()
    }
    pub(super) fn frontend() -> (Flow, Receiver<Message>) {
        let status = status();
        let binding = voice::Binding::new([3; 16], 8).unwrap();
        let (commands, receiver) = mpsc::sync_channel(8);
        (
            Flow {
                shared: Arc::new(Mutex::new(Shared {
                    status,
                    catalog: None,
                    media: None,
                    gate_live: false,
                    grant_expires: None,
                    join_failed: false,
                    denied_locally: false,
                })),
                commands,
                cancel: Arc::new(AtomicBool::new(false)),
                retired: Arc::new(AtomicBool::new(false)),
                worker: None,
                watchdog: None,
                join_failed: false,
                binding,
                policy_clock: Arc::new(Watchdog {
                    origin: Instant::now(),
                    verified: AtomicU64::new(0),
                    done: AtomicBool::new(false),
                }),
            },
            receiver,
        )
    }
    fn wait_finished(worker: &JoinHandle<()>) {
        let deadline = Instant::now() + Duration::from_secs(2);
        while !worker.is_finished() {
            assert!(Instant::now() < deadline, "synthetic worker did not finish");
            thread::yield_now();
        }
    }
    #[test]
    fn auth_requires_current_totp_not_a_historical_permission_fact() {
        assert!(!AuthFacts {
            encrypted: true,
            peer_authenticated: true,
            totp_required: true,
            totp_verified_current: false
        }
        .valid());
        assert!(AuthFacts {
            encrypted: true,
            peer_authenticated: true,
            totp_required: true,
            totp_verified_current: true
        }
        .valid());
        assert!(!AuthFacts {
            encrypted: false,
            peer_authenticated: true,
            totp_required: false,
            totp_verified_current: true
        }
        .valid());
    }
    #[test]
    fn cleanup_only_frontend_allows_query_retry_and_rejects_reauthorization() {
        let (mut flow, receiver) = frontend();
        flow.retire();
        let status = flow.status();
        flow.command(command(&status, Operation::Query)).unwrap();
        assert!(matches!(receiver.recv().unwrap(), Message::Local(_)));
        flow.command(command(&status, Operation::RetryCleanup))
            .unwrap();
        assert!(matches!(receiver.recv().unwrap(), Message::Local(_)));
        for op in [
            Operation::Enumerate,
            Operation::RequestPermission,
            Operation::Mute,
            Operation::Unmute,
            Operation::Deny,
        ] {
            assert_eq!(
                flow.command(command(&status, op)).unwrap_err(),
                "cleanup_pending"
            );
        }
        assert!(!flow.may_send(&status.wire));
    }
    #[test]
    fn reused_id_old_nonce_namespace_and_wire_cannot_address_current_frontend() {
        let (flow, _) = frontend();
        let status = flow.status();
        for mutate in 0..3 {
            let mut cmd = command(&status, Operation::Query);
            match mutate {
                0 => cmd.identity.request_nonce = "4".repeat(32),
                1 => cmd.identity.namespace = "b".repeat(64),
                _ => cmd.identity.connection_nonce = "5".repeat(32),
            };
            assert_eq!(flow.command(cmd).unwrap_err(), "stale_command");
        }
        let mut old = status.wire.clone();
        old.call_epoch = "7".into();
        assert_eq!(flow.peer_accepted(&old), Err("stale_command"));
    }
    #[test]
    fn explicit_denial_is_retained_without_claiming_cleanup_before_native_stop() {
        let (flow, _receiver)=frontend();
        let status=flow.status();
        let mut stale=command(&status,Operation::Deny);
        stale.identity.request_nonce="4".repeat(32);
        assert_eq!(flow.command(stale).unwrap_err(),"stale_command");
        assert!(!flow.shared.lock().unwrap().denied_locally);
        flow.command(command(&status,Operation::Deny)).unwrap();
        let observer:Observer=Arc::new(|_|{});
        publish(&flow.shared,&observer,Phase::RecoveryRequired,"cleanup_pending");
        assert_eq!(flow.status().phase,Phase::RecoveryRequired);
        assert_eq!(flow.status().reason,"cleanup_pending");
        publish(&flow.shared,&observer,Phase::Stopped,"stopped");
        assert_eq!(flow.status().reason,"denied");
    }
    #[test]
    fn bounded_command_queue_cannot_make_cancel_wait_behind_pending_messages() {
        let (flow, _receiver) = frontend();
        let status = flow.status();
        for _ in 0..8 {
            flow.command(command(&status, Operation::Query)).unwrap();
        }
        assert_eq!(
            flow.command(command(&status, Operation::Revoke))
                .unwrap_err(),
            "busy"
        );
        assert!(flow.cancel.load(Ordering::Acquire));
        assert!(!flow.may_send(&status.wire));
    }
    #[test]
    fn exact_device_scope_and_old_stop_ack_cannot_grant_new_wire_call() {
        let status = status();
        let mut gate = Gate::approved(&status.identity, "a".repeat(64)).unwrap();
        assert!(gate.live());
        let other = Scope::VoiceDevices {
            fingerprint: "b".repeat(64),
        };
        assert!(!gate.state.may_execute(&gate.ticket, &other, Instant::now()));
        gate.revoke();
        assert!(!gate.live());
        let stop = gate.stop.clone().unwrap();
        gate.state.did_stop(&stop, true).unwrap();
        let mut next = status.identity;
        next.request_nonce = "6".repeat(32);
        next.connection_nonce = "7".repeat(32);
        let mut next = Gate::approved(&next, "a".repeat(64)).unwrap();
        assert!(next.state.did_stop(&stop, true).is_err());
        assert!(next.live());
    }
    #[test]
    fn scope_hash_length_prefix_prevents_ambiguous_device_concatenation() {
        assert_ne!(hash(&[b"ab", b"c"]), hash(&[b"a", b"bc"]));
        assert_eq!(hash(&[b"same"]), hash(&[b"same"]));
    }
    #[test]
    fn permission_query_is_not_a_capability_ticket_or_local_start() {
        let mut status = status();
        status.microphone_permission = Permission::Authorized;
        assert_eq!(status.phase, Phase::Pending);
        assert!(!status.local_ready);
        assert!(!status.call_running);
        assert!(status.selection.is_none());
        let (flow, _) = frontend();
        assert!(!flow.may_send(&status.wire));
    }
    #[test]
    fn stalled_verified_policy_reader_expires_before_any_future_send() {
        let clock = Watchdog {
            origin: Instant::now() - Duration::from_secs(2),
            verified: AtomicU64::new(0),
            done: AtomicBool::new(false),
        };
        assert!(clock.expired());
        clock.verified();
        assert!(!clock.expired());
    }
    #[test]
    fn execution_checks_same_verified_deadline_without_waiting_for_watchdog_tick() {
        let flow = send_test_flow(true, true, true);
        assert!(!flow.cancel.load(Ordering::Acquire));
        assert!(!flow.may_negotiate(&flow.status().wire));
        assert!(!flow.may_send(&flow.status().wire));
    }
    #[test]
    fn mute_blocks_opus_without_deadlocking_initial_negotiation() {
        let flow = send_test_flow(true, true, false);
        flow.shared.lock().unwrap().status.muted = true;
        assert!(flow.may_negotiate(&flow.status().wire));
        assert!(!flow.may_send(&flow.status().wire));
    }
    #[test]
    fn exact_ticket_deadline_blocks_execution_before_actor_rechecks_it() {
        let flow = send_test_flow(true, true, false);
        flow.shared.lock().unwrap().grant_expires = Some(Instant::now() - Duration::from_secs(1));
        assert!(!flow.cancel.load(Ordering::Acquire));
        assert!(!flow.may_negotiate(&flow.status().wire));
        assert!(!flow.may_send(&flow.status().wire));
    }
    #[test]
    fn network_cancel_is_atomic_without_state_lock_queue_or_retirement() {
        let (flow, _receiver) = frontend();
        let status = flow.status();
        for _ in 0..8 {
            flow.command(command(&status, Operation::Query)).unwrap();
        }
        // This lock models a stalled status/metadata worker. Cancel must not
        // need it, nor the already full command queue, to close media.
        let _guard = flow.shared.lock().unwrap();
        flow.cancel();
        assert!(flow.cancel.load(Ordering::Acquire));
        assert!(!flow.retired.load(Ordering::Acquire));
    }
    #[test]
    fn peer_ack_and_outgoing_require_actual_local_running_not_pending_or_starting() {
        let (flow, _) = frontend();
        let status = flow.status();
        assert_eq!(flow.peer_accepted(&status.wire), Err("not_ready"));
        {
            let mut state = flow.shared.lock().unwrap();
            state.status.phase = Phase::Starting;
            state.status.peer_accepted = true;
            state.gate_live = true;
        }
        assert!(matches!(flow.take_outgoing(), Err(VoiceError::Closed)));
        assert!(!flow.may_send(&status.wire));
    }
    #[test]
    fn stopped_publication_does_not_ack_panicked_actor_join() {
        let (mut flow, _) = frontend();
        let shared = flow.shared.clone();
        {
            let mut state = shared.lock().unwrap();
            state.gate_live = true;
            state.status.local_ready = true;
            state.status.peer_accepted = true;
            state.status.call_running = true;
        }
        let worker = thread::spawn(move || {
            let observer: Observer = Arc::new(|_| {});
            publish(&shared, &observer, Phase::Stopped, "stopped");
            panic!("synthetic actor panic");
        });
        wait_finished(&worker);
        flow.worker = Some(worker);
        assert_eq!(flow.finished(), Err("worker_failed"));
        let failed = flow.status();
        assert_eq!(failed.phase, Phase::RecoveryRequired);
        assert_eq!(failed.reason, "worker_failed");
        assert!(!failed.cleanup_only);
        assert!(!failed.local_ready && !failed.peer_accepted && !failed.call_running);
        assert!(flow.cancel.load(Ordering::Acquire));
        assert!(!flow.retired.load(Ordering::Acquire));
        assert!(!flow.shared.lock().unwrap().gate_live);
        assert!(!flow.may_send(&failed.wire));
        assert!(matches!(flow.take_outgoing(), Err(VoiceError::Closed)));
        assert!(matches!(
            flow.command(command(&failed, Operation::Enumerate)),
            Err("invalid_command")
        ));
        assert_eq!(flow.finished(), Err("worker_failed"));
        assert_eq!(flow.status(), failed);
    }
    #[test]
    fn watchdog_join_failure_blocks_late_actor_stopped_and_reaps_its_join() {
        let (mut flow, _) = frontend();
        {
            let mut state = flow.shared.lock().unwrap();
            state.status.phase = Phase::Running;
            state.status.local_ready = true;
            state.status.peer_accepted = true;
            state.status.call_running = true;
            state.gate_live = true;
        }
        let shared = flow.shared.clone();
        let (resume, receiver) = mpsc::sync_channel(1);
        let publications = Arc::new(Mutex::new(Vec::new()));
        let observed = publications.clone();
        flow.worker = Some(thread::spawn(move || {
            receiver.recv_timeout(Duration::from_secs(2)).unwrap();
            let observer: Observer = Arc::new(move |status| observed.lock().unwrap().push(status));
            publish(&shared, &observer, Phase::Stopped, "stopped");
        }));
        let watchdog = thread::spawn(|| panic!("synthetic watchdog panic"));
        wait_finished(&watchdog);
        flow.watchdog = Some(watchdog);
        assert_eq!(flow.finished(), Err("worker_failed"));
        let failed = flow.status();
        assert_eq!(failed.phase, Phase::RecoveryRequired);
        assert_eq!(failed.reason, "worker_failed");
        assert!(!failed.cleanup_only);
        assert!(!failed.local_ready && !failed.peer_accepted && !failed.call_running);
        assert!(flow.cancel.load(Ordering::Acquire));
        assert!(!flow.retired.load(Ordering::Acquire));
        assert!(!flow.shared.lock().unwrap().gate_live);
        assert!(flow.worker.is_some());
        assert_eq!(flow.finished(), Err("worker_failed"));
        assert_eq!(flow.status(), failed);
        resume.send(()).unwrap();
        wait_finished(flow.worker.as_ref().unwrap());
        assert_eq!(flow.finished(), Err("worker_failed"));
        assert!(flow.worker.is_none());
        assert!(publications.lock().unwrap().is_empty());
        assert_eq!(flow.status(), failed);
        assert_eq!(flow.finished(), Err("worker_failed"));
        assert_eq!(flow.status(), failed);
    }
    #[test]
    fn stopped_is_confirmed_only_after_both_normal_joins() {
        let (mut flow, _) = frontend();
        let shared = flow.shared.clone();
        let (resume, receiver) = mpsc::sync_channel(1);
        flow.watchdog = Some(thread::spawn(move || {
            receiver.recv_timeout(Duration::from_secs(2)).unwrap();
        }));
        let actor = thread::spawn(move || {
            let observer: Observer = Arc::new(|_| {});
            publish(&shared, &observer, Phase::Stopped, "stopped");
        });
        wait_finished(&actor);
        flow.worker = Some(actor);
        assert_eq!(flow.finished(), Ok(false));
        resume.send(()).unwrap();
        wait_finished(flow.watchdog.as_ref().unwrap());
        assert_eq!(flow.finished(), Ok(true));
        assert!(flow.worker.is_none() && flow.watchdog.is_none());
        assert_eq!(flow.status().phase, Phase::Stopped);
        assert!(!flow.shared.lock().unwrap().join_failed);
    }
    #[test]
    fn ordinary_user_boundary_rejects_system_elevated_and_missing_sid() {
        assert!(!ordinary(&NormalUser::Unix(0)));
        assert!(ordinary(&NormalUser::Unix(1000)));
        for (sid, interactive, elevated) in [
            ("S-1-5-18", true, false),
            ("S-1-5-21-123-456-789-1000", true, true),
            ("S-1-5-21-123-456-789-1000", false, false),
            ("S-1--", true, false),
        ] {
            assert!(!ordinary(&NormalUser::Windows {
                sid: sid.into(),
                interactive,
                elevated
            }));
        }
    }
    #[test]
    fn fallback_cleanup_owner_preserves_unconfirmed_panicked_join() {
        let (flow, _) = frontend();
        flow.shared.lock().unwrap().status.phase = Phase::Stopped;
        let worker = thread::spawn(|| panic!("synthetic orphan panic"));
        while !worker.is_finished() {
            thread::yield_now();
        }
        let mut orphan = Orphan {
            shared: flow.shared.clone(),
            worker: Some(worker),
            watchdog: None,
            failed: false,
        };
        assert!(!orphan.reap());
        assert!(orphan.failed);
        assert_eq!(flow.status().phase, Phase::RecoveryRequired);
        assert!(flow.status().cleanup_only);
        assert!(!orphan.reap());
    }
}
