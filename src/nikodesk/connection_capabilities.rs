//! Connection-owned advanced resource authorization. Persisted policy permits
//! requests; only the current authenticated connection and local CM can grant.
use super::capability_state::{
    Binding, Capabilities, Kind, NormalUser, Phase, Request, Scope, StopTicket, Ticket,
};
use hbb_common::{anyhow::anyhow, bail, ResultType};
use serde::{Deserialize, Serialize};
use std::{
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex,
    },
    time::{Duration, Instant},
};

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub(crate) struct Identity {
    pub(crate) connection_id: i32,
    pub(crate) namespace: String,
    pub(crate) peer_id: String,
    pub(crate) connection_nonce: String,
    pub(crate) request_nonce: String,
    pub(crate) epoch: String,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Decision {
    pub(crate) identity: Identity,
    pub(crate) approve: bool,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Status {
    pub(crate) identity: Identity,
    pub(crate) kind: String,
    pub(crate) scope: String,
    pub(crate) phase: String,
    pub(crate) reason: String,
    pub(crate) resource_epoch: String,
}

pub(crate) fn parse<T: serde::de::DeserializeOwned>(json: &str) -> ResultType<T> {
    if json.len() > 4096 {
        bail!("invalid_capability_message");
    }
    serde_json::from_str(json).map_err(|_| anyhow!("invalid_capability_message").into())
}

impl Identity {
    pub(crate) fn valid(&self) -> bool {
        self.connection_id > 0
            && super::server_scope::ServerScope::from_namespace(&self.namespace).is_some()
            && super::validate_remote_id(&self.peer_id).is_ok()
            && [self.connection_nonce.as_str(), self.request_nonce.as_str()]
                .iter()
                .all(|n| {
                    n.len() == 32
                        && n.bytes()
                            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
                        && *n != "00000000000000000000000000000000"
                })
            && self
                .epoch
                .parse::<u64>()
                .map_or(false, |n| n > 0 && n.to_string() == self.epoch)
    }
}

#[cfg(not(any(target_os = "android", target_os = "ios")))]
pub(crate) struct Gate {
    state: Mutex<State>,
    cancelled: AtomicBool,
}
#[cfg(not(any(target_os = "android", target_os = "ios")))]
struct State {
    capabilities: Capabilities,
    request: Request,
    ticket: Option<Ticket>,
    stop: Option<StopTicket>,
    requested_at: Instant,
}

#[cfg(not(any(target_os = "android", target_os = "ios")))]
impl Gate {
    fn lock(&self) -> ResultType<std::sync::MutexGuard<'_, State>> {
        self.state
            .lock()
            .map_err(|_| anyhow!("capability_state_unavailable").into())
    }
    pub(crate) fn execute<T>(
        &self,
        starting: bool,
        run: impl FnOnce() -> ResultType<T>,
    ) -> ResultType<T> {
        if self.cancelled.load(Ordering::SeqCst) {
            bail!("terminal_permission_revoked");
        }
        let state = self.lock()?;
        let ticket = state
            .ticket
            .as_ref()
            .ok_or_else(|| anyhow!("terminal_local_approval_required"))?;
        if self.cancelled.load(Ordering::SeqCst)
            || !(if starting {
                state.capabilities.may_start(ticket, Instant::now())
            } else {
                state
                    .capabilities
                    .may_execute(ticket, ticket.scope(), Instant::now())
            })
        {
            bail!("terminal_permission_revoked");
        }
        run()
    }
    fn approve(&self) -> ResultType<()> {
        let mut state = self.lock()?;
        if self.cancelled.load(Ordering::SeqCst) {
            bail!("terminal_permission_revoked");
        }
        let request = state.request.clone();
        state.ticket = Some(
            state
                .capabilities
                .approve(&request, Instant::now(), Duration::from_secs(3600))
                .map_err(|_| anyhow!("capability_request_stale_or_expired"))?,
        );
        Ok(())
    }
    fn started(&self) -> ResultType<()> {
        let mut state = self.lock()?;
        let ticket = state
            .ticket
            .clone()
            .ok_or_else(|| anyhow!("missing_terminal_grant"))?;
        if self.cancelled.load(Ordering::SeqCst) {
            bail!("terminal_permission_revoked");
        }
        state
            .capabilities
            .did_start(&ticket, Instant::now())
            .map_err(|_| anyhow!("terminal_start_ack_stale").into())
    }
    pub(crate) fn revoke(&self) -> ResultType<Option<StopTicket>> {
        self.cancelled.store(true, Ordering::SeqCst);
        let mut state = self
            .state
            .try_lock()
            .map_err(|_| anyhow!("terminal_executor_cleanup_pending"))?;
        if state.stop.is_none() {
            state.stop = state
                .capabilities
                .revoke(Kind::Terminal)
                .map_err(|_| anyhow!("terminal_revoke_failed"))?;
        }
        Ok(state.stop.clone())
    }
    fn phase(&self) -> Phase {
        self.state
            .try_lock()
            .map(|s| s.capabilities.phase(Kind::Terminal))
            .unwrap_or(Phase::RecoveryRequired)
    }
    fn stopped(&self, ticket: &StopTicket, confirmed: bool) -> ResultType<()> {
        let mut state = self.lock()?;
        if confirmed && state.capabilities.phase(Kind::Terminal) == Phase::Stopped {
            return Ok(());
        }
        state
            .capabilities
            .did_stop(ticket, confirmed)
            .map_err(|_| anyhow!("terminal_stop_ack_stale").into())
    }
}

#[cfg(not(any(target_os = "android", target_os = "ios")))]
pub(crate) struct ConnectionCapabilities {
    pub(crate) gate: Arc<Gate>,
    identity: Identity,
    scope: Scope,
    generation: u64,
    pub(crate) terminal: Mutex<Option<crate::server::terminal_service::OwnedTerminalService>>,
}

#[cfg(not(any(target_os = "android", target_os = "ios")))]
impl ConnectionCapabilities {
    pub(crate) fn authenticated(
        connection_id: i32,
        namespace: String,
        peer_id: String,
        scope: Scope,
        generation: u64,
        secured: bool,
        authenticated: bool,
        required_2fa: bool,
        verified_totp: bool,
    ) -> ResultType<Arc<Self>> {
        if !secured || !authenticated || (required_2fa && !verified_totp) {
            bail!("terminal_authentication_incomplete");
        }
        let connection_nonce = *uuid::Uuid::new_v4().as_bytes();
        let request_nonce = *uuid::Uuid::new_v4().as_bytes();
        let binding = Binding::new(namespace.clone(), peer_id.clone(), connection_nonce)
            .map_err(|_| anyhow!("invalid_terminal_binding"))?;
        let mut capabilities = Capabilities::new(binding, secured, authenticated);
        capabilities
            .set_policy(Kind::Terminal, true, true)
            .map_err(|_| anyhow!("invalid_terminal_policy"))?;
        let request = capabilities
            .request(scope.clone(), request_nonce, Instant::now())
            .map_err(|_| anyhow!("terminal_request_failed"))?;
        let identity = Identity {
            connection_id,
            namespace,
            peer_id,
            connection_nonce: hex(&connection_nonce),
            request_nonce: hex(&request_nonce),
            epoch: request.epoch().to_string(),
        };
        Ok(Arc::new(Self {
            gate: Arc::new(Gate {
                state: Mutex::new(State {
                    capabilities,
                    request,
                    ticket: None,
                    stop: None,
                    requested_at: Instant::now(),
                }),
                cancelled: AtomicBool::new(false),
            }),
            identity,
            scope,
            generation,
            terminal: Mutex::new(None),
        }))
    }
    pub(crate) fn status(&self, reason: &str) -> Status {
        Status {
            identity: self.identity.clone(),
            kind: "terminal".into(),
            scope: match &self.scope {
                Scope::Terminal(NormalUser::Unix(uid)) => format!("Local user UID {}", uid),
                Scope::Terminal(NormalUser::Windows { sid, .. }) => format!("Local user {}", sid),
                _ => "unsupported".into(),
            },
            phase: format!("{:?}", self.gate.phase()),
            reason: reason.to_owned(),
            resource_epoch: self
                .gate
                .state
                .try_lock()
                .map(|state| {
                    state.stop.as_ref().map_or_else(
                        || state.request.epoch().to_string(),
                        |stop| stop.epoch().to_string(),
                    )
                })
                .unwrap_or_else(|_| self.identity.epoch.clone()),
        }
    }
    pub(crate) fn matches(&self, identity: &Identity) -> bool {
        identity.valid() && self.identity == *identity
    }
    pub(crate) fn approve(&self, decision: &Decision) -> ResultType<()> {
        if !self.matches(&decision.identity) || !decision.approve {
            bail!("capability_decision_stale");
        }
        Context::with_current(|current| {
            self.validate_context(&current)?;
            self.gate.approve()?;
            let terminal =
                crate::server::terminal_service::OwnedTerminalService::new(self.gate.clone());
            *self
                .terminal
                .lock()
                .map_err(|_| anyhow!("terminal_owner_unavailable"))? = Some(terminal);
            Ok(())
        })
    }
    pub(crate) fn refresh(&self) -> ResultType<()> {
        let current = Context::capture()?;
        self.validate_context(&current)
    }
    fn validate_context(&self, current: &Context) -> ResultType<()> {
        if current.namespace != self.identity.namespace
            || current.generation != self.generation
            || current.scope != self.scope
        {
            bail!("terminal_local_policy_or_identity_changed");
        }
        let state = self.gate.lock()?;
        if matches!(state.capabilities.phase(Kind::Terminal), Phase::Pending) {
            // Pending requests expire even before the local operator responds.
            if Instant::now()
                .checked_duration_since(state.requested_at)
                .unwrap_or_default()
                > Duration::from_secs(120)
            {
                bail!("terminal_request_expired");
            }
        }
        if let Some(ticket) = state.ticket.as_ref() {
            if !state.capabilities.may_start(ticket, Instant::now())
                && !state
                    .capabilities
                    .may_execute(ticket, ticket.scope(), Instant::now())
            {
                bail!("terminal_grant_expired");
            }
        }
        Ok(())
    }
    pub(crate) fn stop(&self) -> ResultType<bool> {
        self.gate.cancelled.store(true, Ordering::SeqCst);
        let initial = self.gate.revoke();
        let confirmed = self
            .terminal
            .lock()
            .map_err(|_| anyhow!("terminal_owner_unavailable"))?
            .as_mut()
            .map_or(true, |s| s.stop());
        let stop = initial.or_else(|_| self.gate.revoke())?;
        if let Some(ticket) = stop {
            self.gate.stopped(&ticket, confirmed)?;
        }
        Ok(confirmed)
    }
    pub(crate) fn phase(&self) -> Phase {
        self.gate.phase()
    }
    pub(crate) fn started(&self) -> ResultType<()> {
        self.gate.started()
    }
    pub(crate) fn dispatch_action(
        &self,
        action: &base::message_proto::TerminalAction,
        starting: bool,
    ) -> ResultType<Option<base::message_proto::TerminalResponse>> {
        use base::message_proto::terminal_action;
        let dispatch = || {
            self.terminal
                .lock()
                .map_err(|_| anyhow!("terminal_owner_unavailable"))?
                .as_mut()
                .ok_or_else(|| anyhow!("terminal_resource_not_started"))?
                .action_with_execution_guard(action, starting)
        };
        if matches!(
            action.union.as_ref(),
            Some(terminal_action::Union::Close(_))
        ) {
            self.gate.execute(false, || Ok(()))?;
            // Cleanup joins the writer, which may need the permission lock.
            dispatch()
        } else {
            self.gate.execute(starting, dispatch)
        }
    }
}

#[cfg(not(any(target_os = "android", target_os = "ios")))]
#[derive(Clone)]
pub(crate) struct Context {
    pub(crate) namespace: String,
    pub(crate) generation: u64,
    pub(crate) scope: Scope,
}
#[cfg(not(any(target_os = "android", target_os = "ios")))]
impl Context {
    pub(crate) fn capture() -> ResultType<Self> {
        Self::with_current(Ok)
    }
    fn with_current<T>(operation: impl FnOnce(Self) -> ResultType<T>) -> ResultType<T> {
        if crate::nikodesk::background::is_system_worker() {
            bail!("system_terminal_unsupported");
        }
        super::server_settings::with_verified_options(|options| {
            let namespace = super::server_scope::namespace_from_options(options)
                .ok_or_else(|| anyhow!("server_identity_unavailable"))?;
            let scope = Scope::Terminal(normal_user()?);
            // The same settings -> policy lock order as local policy CAS. Repository
            // releases its lock before the short in-memory request/grant operation.
            let policy =
                super::capability_policy::Repository::new(super::favorites::application_root()?)
                    .get(&namespace)?;
            if !policy.allow_requests.allows_requests(Kind::Terminal) {
                bail!("terminal_requests_disabled_locally");
            }
            operation(Self {
                namespace,
                generation: policy.generation,
                scope,
            })
        })
    }
}
#[cfg(not(any(target_os = "android", target_os = "ios")))]
fn normal_user() -> ResultType<NormalUser> {
    #[cfg(unix)]
    {
        let uid = unsafe { hbb_common::libc::geteuid() };
        if uid == 0 || uid != unsafe { hbb_common::libc::getuid() } {
            bail!("ordinary_terminal_user_required");
        }
        Ok(NormalUser::Unix(uid))
    }
    #[cfg(windows)]
    {
        let sid = crate::platform::windows::current_process_user_sid_string()?;
        let session = crate::platform::windows::get_current_process_session_id()
            .ok_or_else(|| anyhow!("interactive_terminal_user_required"))?;
        if session == 0
            || session
                != unsafe { windows::Win32::System::RemoteDesktop::WTSGetActiveConsoleSessionId() }
            || crate::platform::is_prelogin()
            || crate::platform::is_elevated(None)?
            || ["S-1-5-18", "S-1-5-19", "S-1-5-20"].contains(&sid.as_str())
        {
            bail!("ordinary_terminal_user_required");
        }
        Ok(NormalUser::Windows {
            sid,
            interactive: true,
            elevated: false,
        })
    }
}
fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{:02x}", b)).collect()
}

#[cfg(not(any(target_os = "android", target_os = "ios")))]
pub(crate) struct TerminalFlow {
    pub(crate) context: Option<Context>,
    pub(crate) adapter: Option<Arc<ConnectionCapabilities>>,
    pub(crate) pending_open: Option<base::message_proto::TerminalAction>,
    pub(crate) required_2fa: bool,
    verified_totp: bool,
    last_refresh: Instant,
}
#[cfg(not(any(target_os = "android", target_os = "ios")))]
impl TerminalFlow {
    pub(crate) fn new(required_2fa: bool) -> Self {
        Self {
            context: None,
            adapter: None,
            pending_open: None,
            required_2fa,
            verified_totp: false,
            last_refresh: Instant::now(),
        }
    }
    pub(crate) fn record_verified_totp(&mut self) {
        self.verified_totp = true;
    }
}
#[cfg(not(any(target_os = "android", target_os = "ios")))]
impl Drop for ConnectionCapabilities {
    fn drop(&mut self) {
        self.gate.cancelled.store(true, Ordering::SeqCst);
        // Moving ownership to one retry worker avoids dropping unfinished PTY
        // handles when the network connection goes away. No foreign PID is killed.
        let owned = match self.terminal.get_mut() {
            Ok(terminal) => terminal.take(),
            Err(poisoned) => poisoned.into_inner().take(),
        };
        if let Some(terminal) = owned {
            if terminal.active_count() > 0 {
                super::owned_terminal::retain_unconfirmed(terminal);
            }
        }
    }
}

#[cfg(not(any(target_os = "android", target_os = "ios")))]
impl TerminalFlow {
    pub(crate) async fn prepare(&mut self) -> ResultType<()> {
        let context = blocking(|| {
            let context = Context::capture()?;
            #[cfg(target_os = "windows")]
            super::windows_compatibility::check_terminal_support()?;
            Ok(context)
        })
        .await?;
        if self.context.as_ref().map_or(false, |original| {
            original.namespace != context.namespace
                || original.generation != context.generation
                || original.scope != context.scope
        }) {
            bail!("terminal_request_scope_changed");
        }
        self.context = Some(context);
        Ok(())
    }
    pub(crate) async fn authenticated(
        &mut self,
        connection_id: i32,
        peer_id: String,
        secured: bool,
        authenticated: bool,
    ) -> ResultType<Status> {
        self.prepare().await?;
        let context = self
            .context
            .as_ref()
            .ok_or_else(|| anyhow!("terminal_request_scope_missing"))?;
        let adapter = ConnectionCapabilities::authenticated(
            connection_id,
            context.namespace.clone(),
            peer_id,
            context.scope.clone(),
            context.generation,
            secured,
            authenticated,
            self.required_2fa,
            self.verified_totp,
        )?;
        let status = adapter.status("Waiting for local terminal approval (expires in 120 seconds)");
        self.adapter = Some(adapter);
        Ok(status)
    }
    pub(crate) async fn decision(
        &mut self,
        decision: Decision,
    ) -> ResultType<(Status, Vec<base::message_proto::TerminalResponse>)> {
        let adapter = self
            .adapter
            .clone()
            .ok_or_else(|| anyhow!("terminal_request_missing"))?;
        if !adapter.matches(&decision.identity) {
            bail!("capability_decision_stale");
        }
        if !decision.approve {
            return Ok((self.revoke(None, "Denied locally").await?, Vec::new()));
        }
        let approve = adapter.clone();
        if let Err(error) = blocking(move || approve.approve(&decision)).await {
            let _ = self
                .revoke(None, "Terminal decision was not confirmed")
                .await;
            return Err(error);
        }
        let mut responses = Vec::new();
        if let Some(open) = self.pending_open.take() {
            if let Some(response) = self.action(open).await? {
                responses.push(response);
            }
        }
        Ok((adapter.status("Local terminal grant applied"), responses))
    }
    pub(crate) async fn action(
        &mut self,
        action: base::message_proto::TerminalAction,
    ) -> ResultType<Option<base::message_proto::TerminalResponse>> {
        use base::message_proto::terminal_action;
        let adapter = self
            .adapter
            .clone()
            .ok_or_else(|| anyhow!("terminal_local_approval_required"))?;
        if adapter.phase() == Phase::Pending {
            if let Some(terminal_action::Union::Open(open)) = action.union.as_ref() {
                crate::server::terminal_service::OwnedTerminalService::validate_open(open)?;
                if self.pending_open.is_some() {
                    bail!("one_terminal_open_may_wait_for_approval");
                }
                self.pending_open = Some(action);
                return Ok(None);
            }
            bail!("terminal_local_approval_required");
        }
        let starting = adapter.phase() == Phase::Starting;
        let executor = adapter.clone();
        let result = blocking(move || {
            if starting {
                executor.refresh()?;
            }
            let response = executor.dispatch_action(&action, starting)?;
            if starting {
                executor.started()?;
            }
            let empty = executor
                .terminal
                .lock()
                .map_err(|_| anyhow!("terminal_owner_unavailable"))?
                .as_ref()
                .map_or(true, |terminal| terminal.active_count() == 0);
            if !starting && empty {
                executor.stop()?;
            }
            Ok(response)
        })
        .await;
        if result.is_err() {
            let _ = self
                .revoke(None, "Terminal execution or cleanup could not be confirmed")
                .await;
        }
        result
    }
    pub(crate) async fn poll(
        &mut self,
    ) -> ResultType<(Option<Status>, Vec<base::message_proto::TerminalResponse>)> {
        let Some(adapter) = self.adapter.clone() else {
            return Ok((None, Vec::new()));
        };
        if matches!(adapter.phase(), Phase::Stopped) {
            return Ok((None, Vec::new()));
        }
        if self.last_refresh.elapsed() >= Duration::from_millis(250) {
            self.last_refresh = Instant::now();
            let validate = adapter.clone();
            if blocking(move || validate.refresh()).await.is_err() {
                return Ok((
                    Some(
                        self.revoke(None, "Terminal policy, identity or grant changed")
                            .await?,
                    ),
                    Vec::new(),
                ));
            }
        }
        if adapter.phase() != Phase::Running {
            return Ok((None, Vec::new()));
        }
        let reader = adapter.clone();
        let (responses, empty) = blocking(move || {
            reader.gate.execute(false, || Ok(()))?;
            let mut terminal = reader
                .terminal
                .lock()
                .map_err(|_| anyhow!("terminal_owner_unavailable"))?;
            let responses = terminal.as_mut().map_or_else(Vec::new, |s| s.outputs());
            let empty = terminal.as_ref().map_or(true, |s| s.active_count() == 0);
            Ok((responses, empty))
        })
        .await?;
        if empty {
            return Ok((
                Some(self.revoke(None, "All owned terminals have closed").await?),
                responses,
            ));
        }
        Ok((None, responses))
    }
    pub(crate) async fn revoke(
        &mut self,
        identity: Option<&Identity>,
        reason: &str,
    ) -> ResultType<Status> {
        let adapter = self
            .adapter
            .clone()
            .ok_or_else(|| anyhow!("terminal_request_missing"))?;
        if identity.map_or(false, |identity| !adapter.matches(identity)) {
            bail!("capability_revoke_stale");
        }
        self.pending_open.take();
        adapter.gate.cancelled.store(true, Ordering::SeqCst);
        let cleanup = adapter.clone();
        let result = blocking(move || cleanup.stop()).await;
        Ok(adapter.status(if matches!(result, Ok(true)) {
            reason
        } else {
            "Terminal cleanup is unconfirmed; resource ownership is retained"
        }))
    }
}
#[cfg(not(any(target_os = "android", target_os = "ios")))]
async fn blocking<T: Send + 'static>(
    run: impl FnOnce() -> ResultType<T> + Send + 'static,
) -> ResultType<T> {
    match hbb_common::tokio::time::timeout(
        Duration::from_secs(2),
        hbb_common::tokio::task::spawn_blocking(run),
    )
    .await
    {
        Ok(result) => result?,
        Err(_) => Err(anyhow!("terminal_operation_unconfirmed").into()),
    }
}

#[cfg(all(test, not(any(target_os = "android", target_os = "ios"))))]
pub(crate) fn test_adapter() -> Arc<ConnectionCapabilities> {
    ConnectionCapabilities::authenticated(
        12,
        "a".repeat(64),
        "123456789".into(),
        Scope::Terminal(NormalUser::Unix(501)),
        1,
        true,
        true,
        false,
        false,
    )
    .unwrap()
}
#[cfg(all(test, not(any(target_os = "android", target_os = "ios"))))]
pub(crate) fn test_approve(adapter: &ConnectionCapabilities) {
    adapter.gate.approve().unwrap();
}
#[cfg(all(test, not(any(target_os = "android", target_os = "ios"))))]
mod tests {
    use super::*;
    use std::sync::mpsc;
    #[test]
    fn real_core_authentication_and_totp_evidence_are_required() {
        for (secured, authenticated, totp) in [
            (false, true, true),
            (true, false, true),
            (true, true, false),
        ] {
            assert!(ConnectionCapabilities::authenticated(
                12,
                "a".repeat(64),
                "123456789".into(),
                Scope::Terminal(NormalUser::Unix(501)),
                1,
                secured,
                authenticated,
                true,
                totp
            )
            .is_err());
        }
        assert_eq!(test_adapter().phase(), Phase::Pending);
    }
    #[test]
    fn click_authentication_with_this_connections_real_totp_check_can_request_terminal() {
        let totp = totp_rs::TOTP::new(
            totp_rs::Algorithm::SHA1,
            6,
            1,
            30,
            b"public-synthetic-niko-totp-fixture".to_vec(),
            Some("NikoDesk regression".into()),
            "synthetic-fixture".into(),
        )
        .unwrap();
        let code = totp.generate_current().unwrap();
        let mut flow = TerminalFlow::new(true);
        assert!(!flow.verified_totp);
        if totp.check_current(&code).unwrap() {
            flow.record_verified_totp();
        }
        assert!(flow.verified_totp);
        assert!(ConnectionCapabilities::authenticated(
            12,
            "a".repeat(64),
            "123456789".into(),
            Scope::Terminal(NormalUser::Unix(501)),
            1,
            true,
            true,
            true,
            flow.verified_totp,
        )
        .is_ok());
    }
    #[test]
    fn historical_totp_audit_does_not_satisfy_this_connections_factor_requirement() {
        // A remembered/audit Totp tag supplies no fact to TerminalFlow.
        let flow = TerminalFlow::new(true);
        assert!(ConnectionCapabilities::authenticated(
            12,
            "a".repeat(64),
            "123456789".into(),
            Scope::Terminal(NormalUser::Unix(501)),
            1,
            true,
            true,
            true,
            flow.verified_totp,
        )
        .is_err());
    }
    #[test]
    fn reconnect_discards_verified_factor_and_cannot_reuse_prior_grant() {
        let mut previous = TerminalFlow::new(true);
        previous.record_verified_totp();
        let next = TerminalFlow::new(true);
        assert!(previous.verified_totp);
        assert!(!next.verified_totp);
        assert!(ConnectionCapabilities::authenticated(
            12,
            "a".repeat(64),
            "123456789".into(),
            Scope::Terminal(NormalUser::Unix(501)),
            1,
            true,
            true,
            true,
            next.verified_totp,
        )
        .is_err());
    }
    #[test]
    fn approvals_cannot_be_replayed_between_connections_or_after_revoke() {
        let first = test_adapter();
        let second = test_adapter();
        assert!(!second.matches(&first.identity));
        test_approve(&first);
        assert_eq!(first.phase(), Phase::Starting);
        first.started().unwrap();
        assert_eq!(first.phase(), Phase::Running);
        assert!(first.stop().unwrap());
        assert_eq!(first.phase(), Phase::Stopped);
        assert!(first.gate.approve().is_err());
        assert!(first.gate.execute(false, || Ok(())).is_err());
    }
    #[test]
    fn typed_messages_refuse_unknown_fields_invalid_epoch_and_foreign_scope() {
        let adapter = test_adapter();
        let mut identity = adapter.identity.clone();
        assert!(identity.valid());
        identity.epoch = "01".into();
        assert!(!identity.valid());
        identity = adapter.identity.clone();
        identity.namespace = "b".repeat(64);
        assert!(!adapter.matches(&identity));
        let raw = serde_json::to_string(&Decision {
            identity: adapter.identity.clone(),
            approve: true,
        })
        .unwrap();
        assert!(parse::<Decision>(&raw).is_ok());
        assert!(parse::<Decision>(&raw.replace(
            "\"approve\":true",
            "\"approve\":true,\"command\":\"ignored\""
        ))
        .is_err());
        assert!(parse::<Decision>(&"x".repeat(4097)).is_err());
    }
    #[test]
    fn queued_writer_cannot_cross_cancel_even_when_executor_is_busy() {
        let adapter = test_adapter();
        test_approve(&adapter);
        adapter.started().unwrap();
        let (entered, receive) = mpsc::channel();
        let (release, wait) = mpsc::channel();
        let writer = adapter.clone();
        let thread = std::thread::spawn(move || {
            writer.gate.execute(false, || {
                entered.send(()).unwrap();
                wait.recv().unwrap();
                Ok(())
            })
        });
        receive.recv_timeout(Duration::from_secs(1)).unwrap();
        assert!(adapter.gate.revoke().is_err());
        assert!(adapter
            .gate
            .execute(false, || -> ResultType<()> {
                panic!("queued data executed after cancellation")
            })
            .is_err());
        release.send(()).unwrap();
        thread.join().unwrap().unwrap();
        assert!(adapter.stop().unwrap());
        assert_eq!(adapter.phase(), Phase::Stopped);
    }
    #[test]
    fn queued_dispatch_never_owns_the_child_mutex_while_waiting_for_a_busy_writer() {
        let adapter = test_adapter();
        test_approve(&adapter);
        adapter.started().unwrap();
        let (entered, receive) = mpsc::channel();
        let (release, wait) = mpsc::channel();
        let writer = adapter.clone();
        let writing = std::thread::spawn(move || {
            writer.gate.execute(false, || {
                entered.send(()).unwrap();
                wait.recv().unwrap();
                Ok(())
            })
        });
        receive.recv_timeout(Duration::from_secs(1)).unwrap();
        let (queued, seen) = mpsc::channel();
        let (completed, done) = mpsc::channel();
        let waiting = adapter.clone();
        let dispatch = std::thread::spawn(move || {
            queued.send(()).unwrap();
            let mut action = base::message_proto::TerminalAction::new();
            action.set_data(base::message_proto::TerminalData::new());
            completed
                .send(waiting.dispatch_action(&action, false))
                .unwrap();
        });
        seen.recv_timeout(Duration::from_secs(1)).unwrap();
        assert!(done.recv_timeout(Duration::from_millis(50)).is_err());
        // Even while a writer holds Gate, cancellation can access owned handles.
        assert!(adapter.terminal.try_lock().is_ok());
        assert!(adapter.gate.revoke().is_err());
        assert!(adapter.terminal.try_lock().is_ok());
        release.send(()).unwrap();
        writing.join().unwrap().unwrap();
        dispatch.join().unwrap();
        assert!(done.recv_timeout(Duration::from_secs(1)).unwrap().is_err());
        assert!(adapter.stop().unwrap());
    }
    #[test]
    fn cleanup_unknown_keeps_recovery_phase_until_real_ack() {
        let adapter = test_adapter();
        test_approve(&adapter);
        adapter.started().unwrap();
        let stop = adapter.gate.revoke().unwrap().unwrap();
        adapter.gate.stopped(&stop, false).unwrap();
        assert_eq!(adapter.phase(), Phase::RecoveryRequired);
        assert!(adapter.gate.execute(false, || Ok(())).is_err());
        adapter.gate.stopped(&stop, true).unwrap();
        assert_eq!(adapter.phase(), Phase::Stopped);
    }
    #[hbb_common::tokio::test]
    async fn one_pending_open_is_bounded_and_stale_revoke_cannot_consume_it() {
        let adapter = test_adapter();
        let mut flow = TerminalFlow::new(false);
        flow.adapter = Some(adapter.clone());
        let mut open = base::message_proto::OpenTerminal::new();
        open.terminal_id = 1;
        open.rows = 24;
        open.cols = 80;
        let mut action = base::message_proto::TerminalAction::new();
        action.set_open(open);
        assert!(flow.action(action.clone()).await.unwrap().is_none());
        assert!(flow.action(action).await.is_err());
        let mut foreign = adapter.identity.clone();
        foreign.connection_nonce = "b".repeat(32);
        assert!(flow.revoke(Some(&foreign), "stale").await.is_err());
        assert!(flow.pending_open.is_some());
        flow.revoke(Some(&adapter.identity), "cancel")
            .await
            .unwrap();
        assert!(flow.pending_open.is_none());
        assert_eq!(adapter.phase(), Phase::Stopped);
    }
    #[test]
    fn timed_out_or_cancelled_approval_cannot_become_a_late_grant() {
        let adapter = test_adapter();
        adapter.gate.cancelled.store(true, Ordering::SeqCst);
        assert!(adapter.gate.approve().is_err());
        assert!(adapter.gate.execute(true, || Ok(())).is_err());
    }
    #[test]
    fn pending_request_deadline_cannot_be_renewed_by_local_decision() {
        let adapter = test_adapter();
        {
            let mut state = adapter.gate.lock().unwrap();
            state.requested_at = Instant::now() - Duration::from_secs(121);
        }
        // Actual state-machine deadline is independent of UI/adapter display timestamps.
        let mut state = adapter.gate.lock().unwrap();
        let request = state.request.clone();
        assert!(state
            .capabilities
            .approve(
                &request,
                Instant::now() + Duration::from_secs(121),
                Duration::from_secs(1)
            )
            .is_err());
    }
}
