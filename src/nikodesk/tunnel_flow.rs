//! Local authorization for one connection-owned tunnel. No listener is created here.
//! Blocking settings/policy reads belong on the caller's existing blocking runner.
use super::{
    capability_state::{
        Binding, Capabilities, Kind, NormalUser, Phase as ResourcePhase, StopTicket, Ticket,
    },
    connection_capabilities::Identity,
    tunnel_endpoint::{LocalPolicy, PinnedEndpoint, Resolution, Target},
    tunnel_transport::{self, Limits, OwnedMux, Phase as TransportPhase},
};
use crate::port_forward_mux::FrameSink;
use base::message_proto::Message;
use hbb_common::tokio::sync::watch;
use serde::{Deserialize, Serialize};
use std::{
    net::SocketAddr,
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};

const POLICY_LEASE: Duration = Duration::from_secs(1);
const REQUEST_LIFETIME: Duration = Duration::from_secs(120);
const GRANT_LIFETIME: Duration = Duration::from_secs(60 * 60);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Error {
    InvalidCommand,
    Unauthenticated,
    Unsupported,
    OrdinaryUserRequired,
    PolicyUnavailable,
    PolicyDisabled,
    ContextChanged,
    Stale,
    Expired,
    NotApproved,
    WrongOwner,
    StateUnavailable,
    ResolveFailed,
    CleanupUnconfirmed,
    Exhausted,
    Transport(tunnel_transport::Error),
}
impl Error {
    pub(crate) fn code(self) -> &'static str {
        match self {
            Self::InvalidCommand => "tunnel_invalid_command",
            Self::Unauthenticated => "tunnel_authenticated_v1_connection_required",
            Self::Unsupported => "tunnel_backend_unsupported",
            Self::OrdinaryUserRequired => "tunnel_ordinary_user_required",
            Self::PolicyUnavailable => "tunnel_policy_unavailable",
            Self::PolicyDisabled => "tunnel_requests_disabled_locally",
            Self::ContextChanged => "tunnel_context_changed",
            Self::Stale => "tunnel_stale_request",
            Self::Expired => "tunnel_request_expired",
            Self::NotApproved => "tunnel_not_approved",
            Self::WrongOwner => "tunnel_owner_mismatch",
            Self::StateUnavailable => "tunnel_state_unavailable",
            Self::ResolveFailed => "tunnel_resolution_failed",
            Self::CleanupUnconfirmed => "tunnel_cleanup_unconfirmed",
            Self::Exhausted => "tunnel_revision_exhausted",
            Self::Transport(error) => error.code(),
        }
    }
}

/// Facts come from the actual encrypted Niko v1 typed-tunnel login/TOTP branch.
/// The ordinary-user role never accepts a legacy/raw or SYSTEM tunnel.
#[derive(Clone, Copy)]
pub(crate) struct AuthFacts {
    pub(crate) encrypted: bool,
    pub(crate) authenticated: bool,
    pub(crate) ordinary_tunnel_v1: bool,
    pub(crate) totp_required: bool,
    pub(crate) totp_verified_current: bool,
}
impl AuthFacts {
    fn valid(self) -> bool {
        self.encrypted
            && self.authenticated
            && self.ordinary_tunnel_v1
            && (!self.totp_required || self.totp_verified_current)
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct Context {
    namespace: String,
    generation: u64,
    user: NormalUser,
}
impl Context {
    // Same settings -> policy ordering as the native local policy setter. The
    // repository lock has been released before operation takes the state lock.
    fn with_current<T>(operation: impl FnOnce(Self) -> Result<T, Error>) -> Result<T, Error> {
        #[cfg(not(any(target_os = "macos", target_os = "windows")))]
        {
            let _ = operation;
            Err(Error::Unsupported)
        }
        #[cfg(any(target_os = "macos", target_os = "windows"))]
        {
            if super::background::is_system_worker() {
                return Err(Error::OrdinaryUserRequired);
            }
            let mut outcome = Err(Error::PolicyUnavailable);
            let read = super::server_settings::with_verified_options(|options| {
                outcome = (|| {
                    let namespace = super::server_scope::namespace_from_options(options)
                        .ok_or(Error::PolicyUnavailable)?;
                    let user = super::connection_capabilities::normal_user()
                        .map_err(|_| Error::OrdinaryUserRequired)?;
                    let root = super::favorites::application_root()
                        .map_err(|_| Error::PolicyUnavailable)?;
                    let policy = super::capability_policy::Repository::new(root)
                        .get(&namespace)
                        .map_err(|_| Error::PolicyUnavailable)?;
                    let context = Self::from_policy(user, policy)?;
                    operation(context)
                })();
                Ok(())
            });
            if read.is_err() {
                return Err(Error::PolicyUnavailable);
            }
            outcome
        }
    }
    fn from_policy(
        user: NormalUser,
        policy: super::capability_policy::Snapshot,
    ) -> Result<Self, Error> {
        let ordinary = match &user {
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
                        .all(|part| !part.is_empty() && part.bytes().all(|b| b.is_ascii_digit()))
                    && !["S-1-5-18", "S-1-5-19", "S-1-5-20"].contains(&sid.as_str())
            }
        };
        if !ordinary {
            return Err(Error::OrdinaryUserRequired);
        }
        if !policy.ok
            || super::server_scope::ServerScope::from_namespace(&policy.namespace).is_none()
        {
            return Err(Error::PolicyUnavailable);
        }
        if !policy.allow_requests.allows_requests(Kind::Tunnel) {
            return Err(Error::PolicyDisabled);
        }
        Ok(Self {
            namespace: policy.namespace,
            generation: policy.generation,
            user,
        })
    }
}

pub(crate) fn availability(namespace: &str) -> Result<(), Error> {
    Context::with_current(|context| {
        if context.namespace != namespace {
            return Err(Error::ContextChanged);
        }
        Ok(())
    })
}

/// Construct only after the existing _cm socket/pipe has verified its real
/// caller. An Identity received as JSON is not sufficient to create this actor.
pub(crate) struct TrustedActor {
    identity: Identity,
}
impl TrustedActor {
    pub(crate) fn from_verified_cm(identity: &Identity) -> Result<Self, Error> {
        if !identity.valid() {
            return Err(Error::InvalidCommand);
        }
        Ok(Self {
            identity: identity.clone(),
        })
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub(crate) enum Op {
    Resolve,
    Approve,
    Deny,
    Revoke,
    Query,
    RetryCleanup,
}
#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub(crate) enum Access {
    Loopback,
    NonLoopback,
}
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Command {
    pub(crate) identity: Identity,
    pub(crate) revision: String,
    pub(crate) op: Op,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) address: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) access: Option<Access>,
}
impl Command {
    pub(crate) fn parse(json: &str) -> Result<Self, Error> {
        if json.len() > 4096 {
            return Err(Error::InvalidCommand);
        }
        let command: Self = serde_json::from_str(json).map_err(|_| Error::InvalidCommand)?;
        command.validate()?;
        Ok(command)
    }
    fn validate(&self) -> Result<(), Error> {
        if !self.identity.valid() || decimal(&self.revision).is_none() {
            return Err(Error::InvalidCommand);
        }
        if self.op == Op::Approve {
            let address = self.address.as_ref().ok_or(Error::InvalidCommand)?;
            if address.len() > 64 || self.access.is_none() {
                return Err(Error::InvalidCommand);
            }
            let selected = address
                .parse::<SocketAddr>()
                .map_err(|_| Error::InvalidCommand)?;
            if selected.to_string() != *address {
                return Err(Error::InvalidCommand);
            }
        } else if self.address.is_some() || self.access.is_some() {
            return Err(Error::InvalidCommand);
        }
        Ok(())
    }
}
fn decimal(value: &str) -> Option<u64> {
    value
        .parse::<u64>()
        .ok()
        .filter(|n| *n > 0 && n.to_string() == value)
}
fn nonce(value: &str) -> Result<[u8; 16], Error> {
    let mut output = [0; 16];
    if value.len() != 32 {
        return Err(Error::InvalidCommand);
    }
    for (index, byte) in output.iter_mut().enumerate() {
        *byte = u8::from_str_radix(&value[index * 2..index * 2 + 2], 16)
            .map_err(|_| Error::InvalidCommand)?;
    }
    if output == [0; 16] {
        return Err(Error::InvalidCommand);
    }
    Ok(output)
}

#[derive(Clone, Copy, Debug, Serialize, PartialEq, Eq)]
pub(crate) enum Phase {
    Pending,
    Starting,
    Running,
    Revoking,
    RecoveryRequired,
    Stopped,
}
#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
pub(crate) struct TargetView {
    pub(crate) host: String,
    pub(crate) port: u16,
}
#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
pub(crate) struct Status {
    pub(crate) identity: Identity,
    pub(crate) kind: &'static str,
    pub(crate) phase: Phase,
    pub(crate) reason: &'static str,
    pub(crate) revision: String,
    pub(crate) resource_epoch: String,
    pub(crate) target: TargetView,
    pub(crate) addresses: Vec<String>,
    pub(crate) selected_address: Option<String>,
    pub(crate) cleanup_only: bool,
}
#[derive(Debug, Serialize)]
pub(crate) struct Reply {
    pub(crate) ok: bool,
    pub(crate) reason: &'static str,
    pub(crate) identity: Identity,
    pub(crate) revision: String,
}

/// Carries only this immutable target, not a reference to the network actor or
/// a lock. Completion must be checked against the original revision again.
pub(crate) struct ResolveJob {
    identity: Identity,
    revision: u64,
    target: Target,
}

/// Read only on the existing blocking runner. The result is bound to the
/// original native owner, and its lease begins before it enters that queue.
pub(crate) struct RefreshJob {
    identity: Identity,
    began: Instant,
}
pub(crate) struct RefreshCompletion {
    identity: Identity,
    began: Instant,
    context: Result<Context, Error>,
}
impl RefreshJob {
    pub(crate) fn run(self) -> RefreshCompletion {
        let context = if self.began.elapsed() >= POLICY_LEASE {
            Err(Error::Expired)
        } else {
            Context::with_current(Ok)
        };
        let context = if self.began.elapsed() >= POLICY_LEASE {
            Err(Error::Expired)
        } else {
            context
        };
        RefreshCompletion {
            identity: self.identity,
            began: self.began,
            context,
        }
    }
}
pub(crate) struct ResolveCompletion {
    job: ResolveJob,
    result: Result<Resolution, Error>,
}
impl ResolveJob {
    pub(crate) async fn run(self) -> ResolveCompletion {
        let result = self
            .target
            .resolve()
            .await
            .map_err(|_| Error::ResolveFailed);
        ResolveCompletion { job: self, result }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct WriterBarrier {
    identity: Identity,
    owner_lease: Option<u64>,
    stop_epoch: u64,
}
/// This is a native writer acknowledgement, never a CM/JSON DTO. The writer
/// creates it only after cutoff, its queued typed frames and real joins drain.
pub(crate) struct WriterDrainAck {
    barrier: WriterBarrier,
}

/// Keep this native cancellation handle with the parent connection so closing
/// a stream cannot wait behind a blocking settings read or a full CM queue.
#[derive(Clone)]
pub(crate) struct Cancellation {
    state: Arc<Mutex<Capabilities>>,
    cancel: watch::Sender<bool>,
}
impl Cancellation {
    pub(crate) fn cancel(&self) -> Result<(), Error> {
        self.cancel_with_epoch().map(|_| ())
    }
    pub(crate) fn cancel_with_epoch(&self) -> Result<Option<u64>, Error> {
        self.cancel.send_replace(true);
        let stop = self.state
            .lock()
            .map_err(|_| Error::StateUnavailable)?
            .revoke(Kind::Tunnel)
            .map_err(|_| Error::StateUnavailable)?;
        Ok(stop.map(|ticket| ticket.epoch()))
    }
}
impl WriterDrainAck {
    pub(crate) fn from_completed_writer(
        barrier: WriterBarrier,
        actual_identity: &Identity,
        actual_owner_lease: Option<u64>,
        actual_stop_epoch: u64,
    ) -> Result<Self, Error> {
        if barrier.identity != *actual_identity
            || barrier.owner_lease != actual_owner_lease
            || barrier.stop_epoch != actual_stop_epoch
            || actual_stop_epoch == 0
        {
            return Err(Error::Stale);
        }
        Ok(Self { barrier })
    }
}

pub(crate) struct Flow {
    identity: Identity,
    target: Target,
    auth: AuthFacts,
    context: Context,
    verified_at: Instant,
    requested_at: Instant,
    state: Arc<Mutex<Capabilities>>,
    ticket: Option<Ticket>,
    stop: Option<StopTicket>,
    cancel: watch::Sender<bool>,
    resolution: Option<Resolution>,
    resolving: bool,
    owner_lease: Option<u64>,
    transport_stopped: bool,
    writer_drained: bool,
    // A failed actor cannot reuse earlier resource ACKs as an actor join.
    actor_failed: bool,
    actor_join_pending: bool,
    cleanup_confirmed: bool,
    status: Status,
    revision: u64,
    audit: Option<super::capability_audit::Context>,
}
impl Flow {
    /// Blocking read-only entry; never call on a network/UI async thread.
    pub(crate) fn authenticated(
        identity: Identity,
        target: Target,
        auth: AuthFacts,
    ) -> Result<Self, Error> {
        if !auth.valid() {
            return Err(Error::Unauthenticated);
        }
        Context::with_current(|context| Self::new_verified(identity, target, auth, context))
    }
    fn new_verified(
        identity: Identity,
        target: Target,
        auth: AuthFacts,
        context: Context,
    ) -> Result<Self, Error> {
        if !identity.valid() || identity.epoch != "1" {
            return Err(Error::InvalidCommand);
        }
        if !auth.valid() {
            return Err(Error::Unauthenticated);
        }
        if context.namespace != identity.namespace {
            return Err(Error::ContextChanged);
        }
        let binding = Binding::new(
            identity.namespace.clone(),
            identity.peer_id.clone(),
            nonce(&identity.connection_nonce)?,
        )
        .map_err(|_| Error::InvalidCommand)?;
        let mut state = Capabilities::new(binding, auth.encrypted, auth.authenticated);
        state
            .set_policy(Kind::Tunnel, true, true)
            .map_err(|_| Error::StateUnavailable)?;
        let now = Instant::now();
        let status = Status {
            identity: identity.clone(),
            kind: "tunnel",
            phase: Phase::Pending,
            reason: "local_approval_required",
            revision: "1".into(),
            resource_epoch: identity.epoch.clone(),
            target: TargetView {
                host: target.host().into(),
                port: target.port(),
            },
            addresses: Vec::new(),
            selected_address: None,
            cleanup_only: false,
        };
        let (cancel, _) = watch::channel(false);
        Ok(Self {
            identity,
            target,
            auth,
            context,
            verified_at: now,
            requested_at: now,
            state: Arc::new(Mutex::new(state)),
            ticket: None,
            stop: None,
            cancel,
            resolution: None,
            resolving: false,
            owner_lease: None,
            transport_stopped: false,
            writer_drained: false,
            actor_failed: false,
            actor_join_pending: false,
            cleanup_confirmed: false,
            status,
            revision: 1,
            audit: None,
        })
    }
    pub(crate) fn status(&self) -> Status {
        self.status.clone()
    }
    pub(crate) fn attach_audit(&mut self, context: super::capability_audit::Context) {
        if self.audit.is_none() && context.matches(&self.identity.namespace, &self.identity.peer_id) {
            if let Ok(mut state) = self.state.lock() { state.attach_audit(Some(context.clone())); }
            else { super::session_audit::failed(); }
            self.audit = Some(context);
            self.audit_status();
        }
    }
    fn audit_status(&self) {
        if let Some(context) = &self.audit {
            context.observe(super::capability_audit::Kind::Tunnel, &self.identity.namespace,
                &self.identity.peer_id, &self.identity.request_nonce,
                &format!("{:?}", self.status.phase), self.status.reason == "denied_locally", false);
        }
    }
    pub(crate) fn cancellation(&self) -> Cancellation {
        Cancellation {
            state: self.state.clone(),
            cancel: self.cancel.clone(),
        }
    }
    pub(crate) fn reply(&self, result: Result<(), Error>) -> Reply {
        Reply {
            ok: result.is_ok(),
            reason: result.err().map_or("queued", Error::code),
            identity: self.identity.clone(),
            revision: self.revision.to_string(),
        }
    }
    fn publish(&mut self, phase: Phase, reason: &'static str) -> Result<(), Error> {
        if self.status.phase == phase && self.status.reason == reason {
            return Ok(());
        }
        self.bump()?;
        self.status.phase = phase;
        self.status.reason = reason;
        self.audit_status();
        Ok(())
    }
    fn bump(&mut self) -> Result<(), Error> {
        let Some(next) = self.revision.checked_add(1) else {
            self.cancel.send_replace(true);
            if let Ok(mut state) = self.state.lock() {
                if let Ok(stop) = state.revoke(Kind::Tunnel) {
                    self.stop = stop;
                }
            }
            return Err(Error::Exhausted);
        };
        self.revision = next;
        self.status.revision = next.to_string();
        Ok(())
    }
    fn check(&self, actor: &TrustedActor, command: &Command) -> Result<(), Error> {
        command.validate()?;
        if actor.identity != self.identity
            || command.identity != self.identity
            || decimal(&command.revision) != Some(self.revision)
        {
            return Err(Error::Stale);
        }
        if self.status.cleanup_only && !matches!(command.op, Op::Query | Op::RetryCleanup) {
            return Err(Error::NotApproved);
        }
        Ok(())
    }
    fn pending(&mut self) -> Result<(), Error> {
        if self.status.phase != Phase::Pending || *self.cancel.borrow() {
            return Err(Error::NotApproved);
        }
        if self.requested_at.elapsed() >= REQUEST_LIFETIME {
            self.invalidate(Error::Expired.code())?;
            return Err(Error::Expired);
        }
        Ok(())
    }
    fn verify(&mut self, context: Context) -> Result<(), Error> {
        if context != self.context || !self.auth.valid() {
            self.invalidate(Error::ContextChanged.code())?;
            return Err(Error::ContextChanged);
        }
        self.verified_at = Instant::now();
        Ok(())
    }
    /// Blocking fresh policy/namespace check. A read failure cuts the live gate.
    /// Query/retry cleanup deliberately do not need current settings or policy.
    pub(crate) fn refresh(&mut self) -> Result<(), Error> {
        if matches!(
            self.status.phase,
            Phase::Stopped | Phase::Revoking | Phase::RecoveryRequired
        ) {
            return Ok(());
        }
        let result = Context::with_current(|context| self.verify(context));
        if let Err(error) = result {
            self.invalidate(error.code())?;
            return Err(error);
        }
        Ok(())
    }
    pub(crate) fn prepare_refresh(&self) -> Result<RefreshJob, Error> {
        if self.status.cleanup_only
            || *self.cancel.borrow()
            || !matches!(
                self.status.phase,
                Phase::Pending | Phase::Starting | Phase::Running
            )
        {
            return Err(Error::Stale);
        }
        Ok(RefreshJob {
            identity: self.identity.clone(),
            began: Instant::now(),
        })
    }
    pub(crate) fn finish_refresh(&mut self, completion: RefreshCompletion) -> Result<(), Error> {
        if completion.identity != self.identity
            || self.status.cleanup_only
            || *self.cancel.borrow()
            || !matches!(
                self.status.phase,
                Phase::Pending | Phase::Starting | Phase::Running
            )
        {
            return Err(Error::Stale);
        }
        if completion.began.elapsed() >= POLICY_LEASE {
            self.invalidate(Error::Expired.code())?;
            return Err(Error::Expired);
        }
        match completion.context {
            Ok(context) => {
                self.verify(context)?;
                self.verified_at = completion.began;
                Ok(())
            }
            Err(error) => {
                self.invalidate(error.code())?;
                Err(error)
            }
        }
    }
    pub(crate) fn update_auth(&mut self, auth: AuthFacts) -> Result<(), Error> {
        self.auth = auth;
        if !auth.valid() {
            self.invalidate(Error::Unauthenticated.code())?;
        }
        Ok(())
    }
    /// The existing actor drives this even before activation. It performs no
    /// I/O. Refresh policy on its blocking runner; missed fresh checks cut off
    /// new dispatch/writes rather than extending a cached grant indefinitely.
    pub(crate) fn tick(&mut self) -> Result<(), Error> {
        if matches!(
            self.status.phase,
            Phase::Stopped | Phase::Revoking | Phase::RecoveryRequired
        ) {
            return Ok(());
        }
        if *self.cancel.borrow()
            || self.verified_at.elapsed() >= POLICY_LEASE
            || (self.status.phase == Phase::Pending
                && self.requested_at.elapsed() >= REQUEST_LIFETIME)
        {
            self.invalidate(Error::Expired.code())?;
        }
        Ok(())
    }
    pub(crate) fn prepare_resolve(
        &mut self,
        actor: &TrustedActor,
        command: &Command,
    ) -> Result<ResolveJob, Error> {
        self.check(actor, command)?;
        if command.op != Op::Resolve {
            return Err(Error::InvalidCommand);
        }
        self.pending()?;
        let result = Context::with_current(|context| self.prepare_resolve_verified(context));
        if let Err(
            error @ (Error::ContextChanged
            | Error::PolicyUnavailable
            | Error::PolicyDisabled
            | Error::OrdinaryUserRequired),
        ) = result
        {
            self.invalidate(error.code())?;
        }
        result
    }
    fn prepare_resolve_verified(&mut self, context: Context) -> Result<ResolveJob, Error> {
        self.pending()?;
        self.verify(context)?;
        if self.resolving {
            return Err(Error::NotApproved);
        }
        self.bump()?;
        self.resolving = true;
        self.resolution = None;
        self.status.addresses.clear();
        self.status.reason = "resolving";
        Ok(ResolveJob {
            identity: self.identity.clone(),
            revision: self.revision,
            target: self.target.clone(),
        })
    }
    pub(crate) fn finish_resolve(&mut self, completion: ResolveCompletion) -> Result<(), Error> {
        let result =
            Context::with_current(|context| self.finish_resolve_verified(completion, context));
        if let Err(
            error @ (Error::ContextChanged
            | Error::PolicyUnavailable
            | Error::PolicyDisabled
            | Error::OrdinaryUserRequired),
        ) = result
        {
            self.invalidate(error.code())?;
        }
        result
    }
    fn finish_resolve_verified(
        &mut self,
        completion: ResolveCompletion,
        context: Context,
    ) -> Result<(), Error> {
        let ResolveCompletion { job, result } = completion;
        if job.identity != self.identity || job.revision != self.revision || !self.resolving {
            return Err(Error::Stale);
        }
        self.pending()?;
        self.verify(context)?;
        self.resolving = false;
        let resolution = match result {
            Ok(resolution) => resolution,
            Err(error) => {
                self.publish(Phase::Pending, error.code())?;
                return Err(error);
            }
        };
        if resolution.addresses().len() > 8 || resolution.addresses().is_empty() {
            return Err(Error::ResolveFailed);
        }
        self.bump()?;
        self.status.addresses = resolution
            .addresses()
            .iter()
            .map(ToString::to_string)
            .collect();
        self.status.reason = "select_exact_address";
        self.resolution = Some(resolution);
        Ok(())
    }
    pub(crate) fn approve(&mut self, actor: &TrustedActor, command: &Command) -> Result<(), Error> {
        self.check(actor, command)?;
        if command.op != Op::Approve {
            return Err(Error::InvalidCommand);
        }
        self.pending()?;
        let result = Context::with_current(|context| self.approve_verified(command, context));
        if let Err(
            error @ (Error::ContextChanged
            | Error::PolicyUnavailable
            | Error::PolicyDisabled
            | Error::OrdinaryUserRequired),
        ) = result
        {
            self.invalidate(error.code())?;
        }
        result
    }
    fn approve_verified(&mut self, command: &Command, context: Context) -> Result<(), Error> {
        command.validate()?;
        self.pending()?;
        self.verify(context)?;
        if self.resolving {
            return Err(Error::NotApproved);
        }
        let selected = command
            .address
            .as_ref()
            .ok_or(Error::InvalidCommand)?
            .parse::<SocketAddr>()
            .map_err(|_| Error::InvalidCommand)?;
        let access = command.access.ok_or(Error::InvalidCommand)?;
        if selected.ip().is_loopback() != (access == Access::Loopback) {
            return Err(Error::InvalidCommand);
        }
        let policy = match access {
            Access::Loopback => LocalPolicy::LoopbackOnly,
            Access::NonLoopback => LocalPolicy::ExactAddress(selected),
        };
        let scope = self
            .resolution
            .as_ref()
            .ok_or(Error::NotApproved)?
            .select(selected, policy)
            .map_err(|_| Error::NotApproved)?;
        let now = Instant::now();
        self.bump()?;
        let ticket = {
            let mut state = self.state.lock().map_err(|_| Error::StateUnavailable)?;
            let request = state
                .request(scope, nonce(&self.identity.request_nonce)?, now)
                .map_err(|_| Error::NotApproved)?;
            if Some(request.epoch()) != decimal(&self.identity.epoch) {
                return Err(Error::Stale);
            }
            state
                .approve(&request, now, GRANT_LIFETIME)
                .map_err(|_| Error::NotApproved)?
        };
        self.ticket = Some(ticket);
        self.status.phase = Phase::Starting;
        self.status.reason = "awaiting_first_owned_socket";
        self.status.selected_address = Some(selected.to_string());
        Ok(())
    }
    fn live(&self) -> bool {
        if *self.cancel.borrow()
            || self.status.cleanup_only
            || self.verified_at.elapsed() >= POLICY_LEASE
        {
            return false;
        }
        let Some(ticket) = &self.ticket else {
            return false;
        };
        self.state.lock().map_or(false, |state| {
            state.may_start(ticket, Instant::now())
                || state.may_execute(ticket, ticket.scope(), Instant::now())
        })
    }
    /// Activation starts only a bounded mux/monitor, not a TCP connection. The
    /// same Arc, Ticket, cancellation receiver and real lease remain captured.
    pub(crate) fn activate(&mut self, sink: FrameSink, limits: Limits) -> Result<OwnedMux, Error> {
        if self.owner_lease.is_some() || self.status.phase != Phase::Starting || !self.live() {
            return Err(Error::NotApproved);
        }
        let ticket = self.ticket.clone().ok_or(Error::NotApproved)?;
        let endpoint: PinnedEndpoint = self
            .resolution
            .as_ref()
            .ok_or(Error::NotApproved)?
            .for_ticket(&ticket)
            .map_err(|_| Error::NotApproved)?;
        let owner = match OwnedMux::activate(
            endpoint,
            self.state.clone(),
            ticket,
            self.cancel.subscribe(),
            sink,
            limits,
        ) {
            Ok(owner) => owner,
            Err(error) => {
                self.invalidate(error.code())?;
                return Err(Error::Transport(error));
            }
        };
        self.owner_lease = Some(owner.owner_lease());
        Ok(owner)
    }
    pub(crate) fn dispatch(
        &mut self,
        owner: &mut OwnedMux,
        message: Message,
    ) -> Result<tunnel_transport::Dispatch, Error> {
        self.check_owner(owner)?;
        if !self.live() {
            self.invalidate(Error::Expired.code())?;
            owner.begin_stop();
            return Err(Error::NotApproved);
        }
        owner
            .handle_message(self.ticket.as_ref().ok_or(Error::NotApproved)?, message)
            .map_err(Error::Transport)
    }
    /// Outer typed writers must execute this immediately before each real send,
    /// including after a previous await. Already in-flight sends are not recalled.
    pub(crate) fn may_write(&self, owner_lease: u64, ticket: &Ticket) -> bool {
        self.owner_lease == Some(owner_lease) && self.ticket.as_ref() == Some(ticket) && self.live()
    }
    pub(crate) fn current_ticket(&self) -> Option<Ticket> {
        self.ticket.clone()
    }
    fn check_owner(&self, owner: &OwnedMux) -> Result<(), Error> {
        if self.owner_lease != Some(owner.owner_lease()) {
            return Err(Error::WrongOwner);
        }
        Ok(())
    }
    pub(crate) fn prepare_transport_poll(&mut self, owner_lease: u64) -> Result<bool, Error> {
        if self.owner_lease != Some(owner_lease) {
            return Err(Error::WrongOwner);
        }
        if !matches!(self.status.phase, Phase::Stopped | Phase::Revoking | Phase::RecoveryRequired)
            && !self.live()
        {
            self.invalidate(Error::Expired.code())?;
        }
        Ok(*self.cancel.borrow())
    }
    /// The owned mux has completed its actual poll outside the caller's lock.
    pub(crate) fn finish_transport_poll(
        &mut self,
        owner_lease: u64,
        report: tunnel_transport::Report,
    ) -> Result<bool, Error> {
        if self.owner_lease != Some(owner_lease) {
            return Err(Error::WrongOwner);
        }
        if *self.cancel.borrow() {
            self.transport_stopped = report.phase == TransportPhase::Stopped;
            if report.phase == TransportPhase::RecoveryRequired {
                self.recovery(Error::CleanupUnconfirmed.code())?;
            }
            self.finish_cleanup()?;
            return Ok(true);
        }
        if report.phase == TransportPhase::Running && report.first_socket_owned {
            let actual = self.state.lock().map_err(|_| Error::StateUnavailable)?.phase(Kind::Tunnel);
            if self.live() && actual == ResourcePhase::Running {
                self.publish(Phase::Running, "running")?;
            } else {
                self.invalidate(Error::Expired.code())?;
                return Ok(true);
            }
        } else if matches!(report.phase, TransportPhase::Stopping | TransportPhase::Stopped | TransportPhase::RecoveryRequired) {
            self.invalidate(report.reason.map_or(Error::CleanupUnconfirmed.code(), tunnel_transport::Error::code))?;
            return Ok(true);
        }
        Ok(false)
    }
    pub(crate) async fn poll(&mut self, owner: &mut OwnedMux) -> Result<(), Error> {
        self.check_owner(owner)?;
        if !matches!(
            self.status.phase,
            Phase::Stopped | Phase::Revoking | Phase::RecoveryRequired
        ) && !self.live()
        {
            self.invalidate(Error::Expired.code())?;
        }
        let stopping = *self.cancel.borrow();
        let report = if stopping {
            owner.stop_poll().await
        } else {
            owner.poll().await
        };
        if stopping {
            self.transport_stopped = report.phase == TransportPhase::Stopped;
            if report.phase == TransportPhase::RecoveryRequired {
                self.recovery(Error::CleanupUnconfirmed.code())?;
            }
            self.finish_cleanup()?;
        } else if report.phase == TransportPhase::Running && report.first_socket_owned {
            let actual = self
                .state
                .lock()
                .map_err(|_| Error::StateUnavailable)?
                .phase(Kind::Tunnel);
            if self.live() && actual == ResourcePhase::Running {
                self.publish(Phase::Running, "running")?;
            } else {
                self.invalidate(Error::Expired.code())?;
                owner.begin_stop();
            }
        } else if matches!(
            report.phase,
            TransportPhase::Stopping | TransportPhase::Stopped | TransportPhase::RecoveryRequired
        ) {
            self.invalidate(report.reason.map_or(
                Error::CleanupUnconfirmed.code(),
                tunnel_transport::Error::code,
            ))?;
            owner.begin_stop();
        }
        Ok(())
    }
    /// For an owner transferred by OwnedMux::Drop, only the actual registry's
    /// joined lease can provide the transport acknowledgement.
    pub(crate) fn observe_retired(
        &mut self,
        report: &tunnel_transport::RetiredReport,
    ) -> Result<(), Error> {
        if !*self.cancel.borrow() {
            return Err(Error::NotApproved);
        }
        if self
            .owner_lease
            .map_or(false, |lease| report.stopped_leases.contains(&lease))
        {
            self.transport_stopped = true;
        }
        if self
            .owner_lease
            .map_or(false, |lease| report.pending_leases.contains(&lease))
        {
            self.recovery(Error::CleanupUnconfirmed.code())?;
        }
        self.finish_cleanup()
    }
    pub(crate) fn local(
        &mut self,
        actor: &TrustedActor,
        command: &Command,
    ) -> Result<Status, Error> {
        self.check(actor, command)?;
        match command.op {
            Op::Query => {}
            Op::Deny => {
                self.pending()?;
                self.invalidate("denied_locally")?;
            }
            Op::Revoke => {
                self.invalidate("revoked_locally")?;
            }
            Op::RetryCleanup => {
                if !matches!(self.status.phase, Phase::Revoking | Phase::RecoveryRequired) {
                    return Err(Error::NotApproved);
                }
                self.cancel.send_replace(true);
                self.finish_cleanup()?;
            }
            _ => return Err(Error::InvalidCommand),
        }
        Ok(self.status())
    }
    pub(crate) fn invalidate(&mut self, reason: &'static str) -> Result<(), Error> {
        self.cancel.send_replace(true);
        self.resolving = false;
        if self.status.phase == Phase::Stopped {
            return Ok(());
        }
        if self.stop.is_none() {
            let stop = self
                .state
                .lock()
                .map_err(|_| Error::StateUnavailable)
                .and_then(|mut state| {
                    state
                        .revoke(Kind::Tunnel)
                        .map_err(|_| Error::StateUnavailable)
                });
            match stop {
                Ok(stop) => self.stop = stop,
                Err(error) => {
                    self.publish(Phase::RecoveryRequired, error.code())?;
                    return Err(error);
                }
            }
        }
        self.status.resource_epoch = self
            .stop
            .as_ref()
            .map_or_else(|| self.identity.epoch.clone(), |s| s.epoch().to_string());
        if self.ticket.is_none() && self.owner_lease.is_none() {
            self.transport_stopped = true;
            self.writer_drained = true;
            if self.actor_join_pending {
                self.publish(Phase::RecoveryRequired, "actor_worker_failed")
            } else {
                self.cleanup_confirmed = true;
                self.publish(Phase::Stopped, reason)
            }
        } else {
            if self.owner_lease.is_none() {
                self.transport_stopped = true;
            }
            let phase = if self.status.phase == Phase::RecoveryRequired {
                Phase::RecoveryRequired
            } else {
                Phase::Revoking
            };
            self.publish(phase, reason)
        }
    }
    pub(crate) fn retire(&mut self) -> Result<(), Error> {
        let result = self.invalidate("parent_disconnected");
        if !self.status.cleanup_only {
            self.bump()?;
            self.status.cleanup_only = true;
        }
        result
    }
    pub(crate) fn mark_actor_failed(&mut self) -> Result<(), Error> {
        if !self.actor_failed {
            self.actor_failed = true;
            self.actor_join_pending = true;
            self.invalidate("actor_worker_failed")?;
            self.publish(Phase::RecoveryRequired, "actor_worker_failed")?;
        }
        Ok(())
    }
    /// Pure readiness, not an ACK. Only the same actor's normal cleanup-task
    /// join may subsequently clear actor_join_pending.
    pub(crate) fn ready_for_actor_join(&self) -> bool {
        self.actor_failed
            && self.actor_join_pending
            && *self.cancel.borrow()
            && self.transport_stopped
            && self.writer_drained
            && !self.state.is_poisoned()
    }
    pub(crate) fn acknowledge_actor_join(
        &mut self,
        identity: &Identity,
        owner_lease: Option<u64>,
    ) -> Result<(), Error> {
        if *identity != self.identity
            || owner_lease != self.owner_lease
            || !self.ready_for_actor_join()
        {
            return Err(Error::Stale);
        }
        self.actor_join_pending = false;
        self.finish_cleanup()
    }
    pub(crate) fn writer_barrier(&self) -> Result<WriterBarrier, Error> {
        if !*self.cancel.borrow() {
            return Err(Error::NotApproved);
        }
        let stop = self.stop.as_ref().ok_or(Error::NotApproved)?;
        Ok(WriterBarrier {
            identity: self.identity.clone(),
            owner_lease: self.owner_lease,
            stop_epoch: stop.epoch(),
        })
    }
    pub(crate) fn writer_drained(&mut self, ack: WriterDrainAck) -> Result<(), Error> {
        if ack.barrier != self.writer_barrier()? {
            return Err(Error::Stale);
        }
        self.writer_drained = true;
        self.finish_cleanup()
    }
    fn finish_cleanup(&mut self) -> Result<(), Error> {
        if self.status.phase == Phase::Stopped {
            return Ok(());
        }
        if !*self.cancel.borrow() {
            return Err(Error::NotApproved);
        }
        if self.transport_stopped
            && self.writer_drained
            && self.ticket.is_none()
            && self.owner_lease.is_none()
        {
            return self.publish(
                if self.actor_join_pending {
                    Phase::RecoveryRequired
                } else {
                    Phase::Stopped
                },
                if self.actor_join_pending {
                    "actor_worker_failed"
                } else {
                    "cleanup_confirmed"
                },
            );
        }
        let Some(stop) = &self.stop else {
            return Err(Error::StateUnavailable);
        };
        if self.transport_stopped && self.writer_drained {
            if self.actor_join_pending {
                self.publish(Phase::RecoveryRequired, "actor_worker_failed")?;
                return Ok(());
            }
            // A previously confirmed resource stop remains valid, but cannot
            // substitute for the failed actor's independently joined cleanup.
            if !self.cleanup_confirmed {
                self.state
                    .lock()
                    .map_err(|_| Error::StateUnavailable)?
                    .did_stop(stop, true)
                    .map_err(|_| Error::StateUnavailable)?;
                self.cleanup_confirmed = true;
            }
            self.publish(Phase::Stopped, "cleanup_confirmed")?;
        } else if self.transport_stopped {
            self.recovery("writer_drain_unconfirmed")?;
        }
        Ok(())
    }
    fn recovery(&mut self, reason: &'static str) -> Result<(), Error> {
        if let Some(stop) = &self.stop {
            self.state
                .lock()
                .map_err(|_| Error::StateUnavailable)?
                .did_stop(stop, false)
                .map_err(|_| Error::StateUnavailable)?;
        }
        self.publish(Phase::RecoveryRequired, reason)
    }
}
impl Drop for Flow {
    fn drop(&mut self) {
        self.cancel.send_replace(true);
        if let Ok(mut state) = self.state.lock() {
            let _ = state.revoke(Kind::Tunnel);
        }
        // Drop cannot produce an acknowledgement. Parent retirement must retain
        // this Flow and its mux/lease until both real cleanup paths finish.
    }
}

#[cfg(test)]
mod tests {
    use super::super::{capability_policy::Repository, favorites::tests::Temp};
    use super::*;
    use crate::port_forward_mux::{open_msg, CHANNEL_WINDOW};
    use hbb_common::tokio::{self, io::AsyncReadExt, net::TcpListener, sync::mpsc};

    fn identity() -> Identity {
        Identity {
            connection_id: 7,
            namespace: "a".repeat(64),
            peer_id: "123456789".into(),
            connection_nonce: "01".repeat(16),
            request_nonce: "02".repeat(16),
            epoch: "1".into(),
        }
    }
    fn auth() -> AuthFacts {
        AuthFacts {
            encrypted: true,
            authenticated: true,
            ordinary_tunnel_v1: true,
            totp_required: true,
            totp_verified_current: true,
        }
    }
    struct Fixture {
        temp: Temp,
        flow: Flow,
        actor: TrustedActor,
    }
    impl Fixture {
        fn new(target: Target) -> Self {
            let temp = Temp::new();
            let repo = Repository::new(temp.0.clone());
            let initial = repo.get(&identity().namespace).unwrap();
            repo.set_allow_requests(&identity().namespace, &initial.revision, Kind::Tunnel, true)
                .unwrap();
            let context = Context::from_policy(
                NormalUser::Unix(1001),
                repo.get(&identity().namespace).unwrap(),
            )
            .unwrap();
            let flow = Flow::new_verified(identity(), target, auth(), context).unwrap();
            let actor = TrustedActor::from_verified_cm(&flow.identity).unwrap();
            Self { temp, flow, actor }
        }
        fn context(&self) -> Context {
            Context::from_policy(
                NormalUser::Unix(1001),
                Repository::new(self.temp.0.clone())
                    .get(&identity().namespace)
                    .unwrap(),
            )
            .unwrap()
        }
        fn command(&self, op: Op) -> Command {
            Command {
                identity: self.flow.identity.clone(),
                revision: self.flow.revision.to_string(),
                op,
                address: None,
                access: None,
            }
        }
        async fn resolved(&mut self) {
            let command = self.command(Op::Resolve);
            self.flow.check(&self.actor, &command).unwrap();
            let job = self.flow.prepare_resolve_verified(self.context()).unwrap();
            let completion = job.run().await;
            self.flow
                .finish_resolve_verified(completion, self.context())
                .unwrap();
        }
        fn approve(&mut self, selected: SocketAddr, access: Access) -> Result<(), Error> {
            let mut command = self.command(Op::Approve);
            command.address = Some(selected.to_string());
            command.access = Some(access);
            self.flow.check(&self.actor, &command)?;
            self.flow.approve_verified(&command, self.context())
        }
        fn owner(
            &mut self,
        ) -> (
            OwnedMux,
            mpsc::UnboundedReceiver<(tokio::time::Instant, Arc<Message>)>,
        ) {
            let (tx, rx) = mpsc::unbounded_channel();
            (
                self.flow
                    .activate(FrameSink::Direct(tx), Limits::default())
                    .unwrap(),
                rx,
            )
        }
        fn revoke(&mut self) {
            self.flow
                .local(&self.actor, &self.command(Op::Revoke))
                .unwrap();
        }
    }
    fn target() -> Target {
        Target::parse("127.0.0.1", 23456).unwrap()
    }
    async fn stopped(flow: &mut Flow, owner: &mut OwnedMux) {
        let deadline = Instant::now() + Duration::from_secs(2);
        while !flow.transport_stopped {
            flow.poll(owner).await.unwrap();
            assert!(Instant::now() < deadline, "real transport cleanup deadline");
            tokio::time::sleep(Duration::from_millis(1)).await;
        }
    }
    fn drain_ack(
        flow: &mut Flow,
        output: &mut mpsc::UnboundedReceiver<(tokio::time::Instant, Arc<Message>)>,
    ) {
        while output.try_recv().is_ok() {}
        assert!(flow.transport_stopped && output.is_empty());
        let barrier = flow.writer_barrier().unwrap();
        flow.writer_drained(writer_ack(flow, barrier)).unwrap();
    }

    fn writer_ack(flow: &Flow, barrier: WriterBarrier) -> WriterDrainAck {
        WriterDrainAck::from_completed_writer(
            barrier,
            &flow.identity,
            flow.owner_lease,
            flow.stop.as_ref().unwrap().epoch(),
        )
        .unwrap()
    }

    #[test]
    fn actual_private_repository_default_off_and_disk_error_are_not_grants() {
        let temp = Temp::new();
        let repo = Repository::new(temp.0.clone());
        let initial = repo.get(&identity().namespace).unwrap();
        assert!(matches!(
            Context::from_policy(NormalUser::Unix(1001), initial),
            Err(Error::PolicyDisabled)
        ));
        assert!(Repository::new(temp.0.join("absent"))
            .get(&identity().namespace)
            .is_err());
        let missing = temp.0.join("nikodesk-capability-policy-v1.json");
        assert!(!missing.exists());
    }
    #[test]
    fn ordinary_user_and_current_authenticated_totp_are_required() {
        let f = Fixture::new(target());
        for mut fact in [auth(); 5]
            .into_iter()
            .enumerate()
            .map(|(index, mut fact)| {
                match index {
                    0 => fact.encrypted = false,
                    1 => fact.authenticated = false,
                    2 => fact.ordinary_tunnel_v1 = false,
                    3 => fact.totp_verified_current = false,
                    _ => {}
                }
                (index, fact)
            })
        {
            if fact.0 == 4 {
                fact.1.totp_required = false;
                fact.1.totp_verified_current = false;
            }
            let result = Flow::new_verified(identity(), target(), fact.1, f.context());
            if fact.0 < 4 {
                assert!(matches!(result, Err(Error::Unauthenticated)));
            } else {
                assert!(result.is_ok());
            }
        }
        for user in [
            NormalUser::Unix(0),
            NormalUser::Windows {
                sid: "S-1-5-18".into(),
                interactive: true,
                elevated: false,
            },
            NormalUser::Windows {
                sid: "S-1-5-21-11".into(),
                interactive: true,
                elevated: true,
            },
            NormalUser::Windows {
                sid: "S-1-5-21-11".into(),
                interactive: false,
                elevated: false,
            },
        ] {
            assert!(matches!(
                Context::from_policy(
                    user,
                    Repository::new(f.temp.0.clone())
                        .get(&identity().namespace)
                        .unwrap()
                ),
                Err(Error::OrdinaryUserRequired)
            ));
        }
    }
    #[test]
    fn initial_pending_has_no_ticket_resolution_owner_or_transport_resource() {
        let f = Fixture::new(target());
        assert_eq!(f.flow.status.phase, Phase::Pending);
        assert!(f.flow.ticket.is_none());
        assert!(f.flow.resolution.is_none() && f.flow.owner_lease.is_none());
        assert_eq!(
            f.flow.state.lock().unwrap().phase(Kind::Tunnel),
            ResourcePhase::Stopped
        );
        assert!(!*f.flow.cancel.borrow());
        let json = serde_json::to_string(&f.flow.status()).unwrap();
        assert!(!json.contains("owner_lease") && !json.contains("ticket"));
    }
    #[test]
    fn strict_command_requires_original_identity_revision_and_explicit_access() {
        let f = Fixture::new(target());
        let mut approve = f.command(Op::Approve);
        approve.address = Some("127.0.0.1:23456".into());
        assert_eq!(approve.validate(), Err(Error::InvalidCommand));
        approve.access = Some(Access::Loopback);
        let mut value = serde_json::to_value(&approve).unwrap();
        value["unexpected"] = true.into();
        assert!(matches!(
            Command::parse(&value.to_string()),
            Err(Error::InvalidCommand)
        ));
        approve.revision = "01".into();
        assert_eq!(approve.validate(), Err(Error::InvalidCommand));
        approve.revision = "1".into();
        approve.identity.request_nonce = "03".repeat(16);
        assert_eq!(f.flow.check(&f.actor, &approve), Err(Error::Stale));
        let mut query = f.command(Op::Query);
        query.address = Some("127.0.0.1:23456".into());
        assert_eq!(query.validate(), Err(Error::InvalidCommand));
        query.address = None;
        query.identity.namespace = "b".repeat(64);
        assert_eq!(f.flow.check(&f.actor, &query), Err(Error::Stale));
        assert!(matches!(
            Command::parse(&" ".repeat(4097)),
            Err(Error::InvalidCommand)
        ));
    }
    #[test]
    fn new_flow_rejects_replayed_nonfirst_epoch_and_namespace() {
        let f = Fixture::new(target());
        let mut wrong = identity();
        wrong.epoch = "2".into();
        assert!(matches!(
            Flow::new_verified(wrong, target(), auth(), f.context()),
            Err(Error::InvalidCommand)
        ));
        let mut wrong = identity();
        wrong.namespace = "b".repeat(64);
        assert!(matches!(
            Flow::new_verified(wrong, target(), auth(), f.context()),
            Err(Error::ContextChanged)
        ));
    }
    #[tokio::test(flavor = "current_thread")]
    async fn explicit_resolve_returns_only_fixed_addresses_and_approval_never_runs() {
        let mut f = Fixture::new(target());
        f.resolved().await;
        assert_eq!(f.flow.status.addresses, vec!["127.0.0.1:23456"]);
        assert_eq!(
            f.approve("127.0.0.2:23456".parse().unwrap(), Access::Loopback),
            Err(Error::NotApproved)
        );
        f.approve("127.0.0.1:23456".parse().unwrap(), Access::Loopback)
            .unwrap();
        assert_eq!(f.flow.status.phase, Phase::Starting);
        assert_eq!(
            f.flow.state.lock().unwrap().phase(Kind::Tunnel),
            ResourcePhase::Starting
        );
    }
    #[tokio::test(flavor = "current_thread")]
    async fn nonloopback_needs_explicit_exact_address_and_not_loopback_approval() {
        let mut f = Fixture::new(Target::parse("192.0.2.1", 80).unwrap());
        f.resolved().await;
        assert_eq!(
            f.approve("192.0.2.1:80".parse().unwrap(), Access::Loopback),
            Err(Error::InvalidCommand)
        );
        f.approve("192.0.2.1:80".parse().unwrap(), Access::NonLoopback)
            .unwrap();
        assert_eq!(f.flow.status.phase, Phase::Starting);
        assert!(f.flow.owner_lease.is_none());
        f.revoke();
        let ack = writer_ack(&f.flow, f.flow.writer_barrier().unwrap());
        f.flow.writer_drained(ack).unwrap();
        assert_eq!(f.flow.status.phase, Phase::Stopped);
    }
    #[tokio::test(flavor = "current_thread")]
    async fn actual_policy_disable_reenable_aba_blocks_old_approval() {
        let mut f = Fixture::new(target());
        f.resolved().await;
        let repo = Repository::new(f.temp.0.clone());
        let a = repo.get(&identity().namespace).unwrap();
        let b = repo
            .set_allow_requests(&identity().namespace, &a.revision, Kind::Tunnel, false)
            .unwrap();
        repo.set_allow_requests(&identity().namespace, &b.revision, Kind::Tunnel, true)
            .unwrap();
        assert_eq!(
            f.approve("127.0.0.1:23456".parse().unwrap(), Access::Loopback),
            Err(Error::ContextChanged)
        );
        assert!(*f.flow.cancel.borrow());
        assert!(f.flow.ticket.is_none());
        assert_eq!(f.flow.status.phase, Phase::Stopped);
    }
    #[tokio::test(flavor = "current_thread")]
    async fn late_resolution_after_revoke_or_namespace_change_cannot_resurrect_request() {
        let mut f = Fixture::new(target());
        let job = f.flow.prepare_resolve_verified(f.context()).unwrap();
        f.revoke();
        let completion = job.run().await;
        assert_eq!(
            f.flow.finish_resolve_verified(completion, f.context()),
            Err(Error::Stale)
        );
        assert!(f.flow.resolution.is_none());
        assert_eq!(f.flow.status.phase, Phase::Stopped);
        let mut f = Fixture::new(target());
        let job = f.flow.prepare_resolve_verified(f.context()).unwrap();
        let completion = job.run().await;
        let mut changed = f.context();
        changed.namespace = "b".repeat(64);
        assert_eq!(
            f.flow.finish_resolve_verified(completion, changed),
            Err(Error::ContextChanged)
        );
        assert!(*f.flow.cancel.borrow());
        assert!(f.flow.resolution.is_none());
    }
    #[tokio::test(flavor = "current_thread")]
    async fn activation_remains_starting_and_second_activation_is_rejected_without_a_socket() {
        let target = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = target.local_addr().unwrap();
        let mut f = Fixture::new(Target::parse("127.0.0.1", i32::from(address.port())).unwrap());
        f.resolved().await;
        f.approve(address, Access::Loopback).unwrap();
        let (mut owner, mut output) = f.owner();
        f.flow.poll(&mut owner).await.unwrap();
        assert_eq!(f.flow.status.phase, Phase::Starting);
        assert!(
            tokio::time::timeout(Duration::from_millis(20), target.accept())
                .await
                .is_err()
        );
        let (tx, _) = mpsc::unbounded_channel();
        assert!(matches!(
            f.flow.activate(FrameSink::Direct(tx), Limits::default()),
            Err(Error::NotApproved)
        ));
        f.revoke();
        stopped(&mut f.flow, &mut owner).await;
        drain_ack(&mut f.flow, &mut output);
    }
    #[tokio::test(flavor = "current_thread")]
    async fn actual_first_socket_and_normal_join_plus_writer_drain_are_distinct_facts() {
        let target = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = target.local_addr().unwrap();
        let mut f = Fixture::new(Target::parse("127.0.0.1", i32::from(address.port())).unwrap());
        f.resolved().await;
        f.approve(address, Access::Loopback).unwrap();
        let (mut owner, mut output) = f.owner();
        let ticket = f.flow.current_ticket().unwrap();
        f.flow
            .dispatch(
                &mut owner,
                open_msg(1, "127.0.0.1", i32::from(address.port()), CHANNEL_WINDOW),
            )
            .unwrap();
        let (mut peer, _) = tokio::time::timeout(Duration::from_secs(2), target.accept())
            .await
            .unwrap()
            .unwrap();
        let deadline = Instant::now() + Duration::from_secs(2);
        while f.flow.status.phase != Phase::Running {
            f.flow.poll(&mut owner).await.unwrap();
            assert!(Instant::now() < deadline);
            tokio::time::sleep(Duration::from_millis(1)).await;
        }
        assert!(f.flow.may_write(owner.owner_lease(), &ticket));
        f.revoke();
        assert!(!f.flow.may_write(owner.owner_lease(), &ticket));
        stopped(&mut f.flow, &mut owner).await;
        assert_eq!(f.flow.status.phase, Phase::RecoveryRequired);
        assert_eq!(f.flow.status.reason, "writer_drain_unconfirmed");
        assert_eq!(
            f.flow.state.lock().unwrap().phase(Kind::Tunnel),
            ResourcePhase::RecoveryRequired
        );
        let mut remaining = Vec::new();
        tokio::time::timeout(Duration::from_secs(2), peer.read_to_end(&mut remaining))
            .await
            .unwrap()
            .unwrap();
        drain_ack(&mut f.flow, &mut output);
        assert_eq!(f.flow.status.phase, Phase::Stopped);
        assert_eq!(
            f.flow.state.lock().unwrap().phase(Kind::Tunnel),
            ResourcePhase::Stopped
        );
    }
    #[tokio::test(flavor = "current_thread")]
    async fn old_writer_ack_cannot_stop_another_identity_lease_or_stop_epoch() {
        let mut a = Fixture::new(target());
        a.resolved().await;
        a.approve("127.0.0.1:23456".parse().unwrap(), Access::Loopback)
            .unwrap();
        let (mut ao, mut ar) = a.owner();
        a.revoke();
        let barrier = a.flow.writer_barrier().unwrap();
        let mut b = Fixture::new(target());
        b.flow.identity.request_nonce = "04".repeat(16);
        b.actor = TrustedActor::from_verified_cm(&b.flow.identity).unwrap();
        b.resolved().await;
        b.approve("127.0.0.1:23456".parse().unwrap(), Access::Loopback)
            .unwrap();
        let (mut bo, mut br) = b.owner();
        b.revoke();
        assert_ne!(ao.owner_lease(), bo.owner_lease());
        assert_eq!(
            b.flow.writer_drained(writer_ack(&a.flow, barrier.clone())),
            Err(Error::Stale)
        );
        let mut wrong = b.flow.writer_barrier().unwrap();
        wrong.stop_epoch += 1;
        assert_eq!(
            WriterDrainAck::from_completed_writer(
                wrong,
                &b.flow.identity,
                b.flow.owner_lease,
                b.flow.stop.as_ref().unwrap().epoch()
            )
            .err(),
            Some(Error::Stale)
        );
        assert!(matches!(a.flow.poll(&mut bo).await, Err(Error::WrongOwner)));
        stopped(&mut a.flow, &mut ao).await;
        stopped(&mut b.flow, &mut bo).await;
        drain_ack(&mut a.flow, &mut ar);
        drain_ack(&mut b.flow, &mut br);
    }
    #[tokio::test(flavor = "current_thread")]
    async fn retirement_forbids_start_and_keeps_query_retry_after_policy_or_auth_revocation() {
        let mut f = Fixture::new(target());
        f.resolved().await;
        f.approve("127.0.0.1:23456".parse().unwrap(), Access::Loopback)
            .unwrap();
        let (mut owner, mut output) = f.owner();
        f.flow.retire().unwrap();
        let revision = f.flow.revision;
        f.flow
            .update_auth(AuthFacts {
                authenticated: false,
                ..auth()
            })
            .unwrap();
        assert_eq!(f.flow.status.phase, Phase::Revoking);
        assert!(f.flow.status.cleanup_only);
        assert!(f.flow.revision >= revision);
        assert!(f.flow.local(&f.actor, &f.command(Op::Query)).is_ok());
        assert!(f.flow.local(&f.actor, &f.command(Op::RetryCleanup)).is_ok());
        let mut approve = f.command(Op::Approve);
        approve.address = Some("127.0.0.1:23456".into());
        approve.access = Some(Access::Loopback);
        assert_eq!(f.flow.check(&f.actor, &approve), Err(Error::NotApproved));
        stopped(&mut f.flow, &mut owner).await;
        drain_ack(&mut f.flow, &mut output);
        assert_eq!(f.flow.status.phase, Phase::Stopped);
    }
    #[tokio::test(flavor = "current_thread")]
    async fn expired_policy_execution_lease_cuts_gate_before_open_and_outer_send() {
        let mut f = Fixture::new(target());
        f.resolved().await;
        f.approve("127.0.0.1:23456".parse().unwrap(), Access::Loopback)
            .unwrap();
        let (mut owner, mut output) = f.owner();
        let ticket = f.flow.current_ticket().unwrap();
        f.flow.verified_at = Instant::now() - Duration::from_secs(2);
        assert!(!f.flow.may_write(owner.owner_lease(), &ticket));
        assert_eq!(
            f.flow
                .dispatch(&mut owner, open_msg(1, "127.0.0.1", 23456, CHANNEL_WINDOW)),
            Err(Error::NotApproved)
        );
        assert!(*f.flow.cancel.borrow());
        stopped(&mut f.flow, &mut owner).await;
        drain_ack(&mut f.flow, &mut output);
    }
    #[tokio::test(flavor = "current_thread")]
    async fn single_retired_coordinator_report_is_distributed_to_each_original_lease() {
        let _serial = tunnel_transport::RETIRED_POLL_TEST.lock().await;
        let mut a = Fixture::new(target());
        a.resolved().await;
        a.approve("127.0.0.1:23456".parse().unwrap(), Access::Loopback)
            .unwrap();
        let (ao, mut ar) = a.owner();
        let mut b = Fixture::new(target());
        b.resolved().await;
        b.approve("127.0.0.1:23456".parse().unwrap(), Access::Loopback)
            .unwrap();
        let (bo, mut br) = b.owner();
        a.flow.retire().unwrap();
        b.flow.retire().unwrap();
        drop(ao);
        drop(bo);
        let deadline = Instant::now() + Duration::from_secs(2);
        while !a.flow.transport_stopped || !b.flow.transport_stopped {
            let report = tunnel_transport::poll_retired().await;
            a.flow.observe_retired(&report).unwrap();
            b.flow.observe_retired(&report).unwrap();
            assert!(Instant::now() < deadline);
            tokio::time::sleep(Duration::from_millis(1)).await;
        }
        assert_eq!(a.flow.status.phase, Phase::RecoveryRequired);
        assert_eq!(b.flow.status.phase, Phase::RecoveryRequired);
        drain_ack(&mut a.flow, &mut ar);
        drain_ack(&mut b.flow, &mut br);
        assert_eq!(a.flow.status.phase, Phase::Stopped);
        assert_eq!(b.flow.status.phase, Phase::Stopped);
    }
    #[test]
    fn revision_exhaustion_cancels_instead_of_issuing_a_hidden_grant() {
        let mut f = Fixture::new(target());
        f.flow.revision = u64::MAX;
        f.flow.status.revision = u64::MAX.to_string();
        assert_eq!(
            f.flow.prepare_resolve_verified(f.context()).err(),
            Some(Error::Exhausted)
        );
        assert!(*f.flow.cancel.borrow());
        assert!(f.flow.ticket.is_none());
    }
    #[test]
    fn pending_timeout_and_stale_cm_actor_never_authorize() {
        let mut f = Fixture::new(target());
        f.flow.requested_at = Instant::now() - Duration::from_secs(121);
        assert_eq!(
            f.flow.prepare_resolve_verified(f.context()).err(),
            Some(Error::Expired)
        );
        let mut other = identity();
        other.connection_nonce = "05".repeat(16);
        let actor = TrustedActor::from_verified_cm(&other).unwrap();
        assert_eq!(
            f.flow.check(&actor, &f.command(Op::Query)),
            Err(Error::Stale)
        );
    }

    #[test]
    fn actor_failure_after_no_resource_stop_requires_original_actor_cleanup_join() {
        let mut f = Fixture::new(target());
        f.flow.invalidate("denied_locally").unwrap();
        assert_eq!(f.flow.status().phase, Phase::Stopped);
        f.flow.mark_actor_failed().unwrap();
        let failed = f.flow.status();
        assert_eq!(failed.phase, Phase::RecoveryRequired);
        assert!(f.flow.ready_for_actor_join());
        f.flow.mark_actor_failed().unwrap();
        assert_eq!(f.flow.status(), failed);
        let actor = TrustedActor::from_verified_cm(&failed.identity).unwrap();
        f.flow.local(&actor, &f.command(Op::RetryCleanup)).unwrap();
        assert_eq!(f.flow.status().phase, Phase::RecoveryRequired);
        let mut foreign = failed.identity.clone();
        foreign.request_nonce = "ab".repeat(16);
        assert_eq!(
            f.flow.acknowledge_actor_join(&foreign, None),
            Err(Error::Stale)
        );
        assert_eq!(
            f.flow.acknowledge_actor_join(&failed.identity, Some(1)),
            Err(Error::Stale)
        );
        f.flow
            .acknowledge_actor_join(&failed.identity, None)
            .unwrap();
        assert_eq!(f.flow.status().phase, Phase::Stopped);
        let stopped = f.flow.status();
        f.flow.mark_actor_failed().unwrap();
        assert_eq!(f.flow.status(), stopped);
        assert!(f.flow.pending().is_err());
    }

    #[test]
    fn native_cancel_remains_reachable_while_flow_waits_on_a_blocking_worker() {
        let f = Fixture::new(target());
        let context = f.context();
        let mut flow = f.flow;
        let cancellation = flow.cancellation();
        let (ready_tx, ready_rx) = std::sync::mpsc::channel();
        let (resume_tx, resume_rx) = std::sync::mpsc::channel();
        let worker = std::thread::spawn(move || {
            ready_tx.send(()).unwrap();
            resume_rx.recv().unwrap();
            // A fresh read finishing later cannot defeat the original parent
            // connection's already cancelled watch/state, even with new policy.
            assert_eq!(
                flow.prepare_resolve_verified(context).err(),
                Some(Error::NotApproved)
            );
            flow.tick().unwrap();
            flow
        });
        ready_rx.recv_timeout(Duration::from_secs(2)).unwrap();
        cancellation.cancel().unwrap();
        resume_tx.send(()).unwrap();
        let flow = worker.join().unwrap();
        assert_eq!(flow.status.phase, Phase::Stopped);
        assert!(*flow.cancel.borrow());
        assert!(flow.ticket.is_none() && flow.owner_lease.is_none());
    }

    #[tokio::test(flavor = "current_thread")]
    async fn deadline_tick_before_activation_still_requires_the_actual_writer_barrier() {
        let mut f = Fixture::new(target());
        f.resolved().await;
        f.approve("127.0.0.1:23456".parse().unwrap(), Access::Loopback)
            .unwrap();
        f.flow.verified_at = Instant::now() - Duration::from_secs(2);
        f.flow.tick().unwrap();
        assert_eq!(f.flow.status.phase, Phase::Revoking);
        assert!(*f.flow.cancel.borrow() && f.flow.transport_stopped);
        assert!(!f.flow.writer_drained);
        let ack = writer_ack(&f.flow, f.flow.writer_barrier().unwrap());
        f.flow.writer_drained(ack).unwrap();
        assert_eq!(f.flow.status.phase, Phase::Stopped);
    }

    #[tokio::test(flavor = "current_thread")]
    async fn failed_mux_activation_revokes_its_ticket_without_claiming_writer_cleanup() {
        let mut f = Fixture::new(target());
        f.resolved().await;
        f.approve("127.0.0.1:23456".parse().unwrap(), Access::Loopback)
            .unwrap();
        let (tx, mut output) = mpsc::unbounded_channel();
        let result = f.flow.activate(
            FrameSink::Direct(tx),
            Limits {
                channels: 0,
                pending_dials: 1,
            },
        );
        assert!(matches!(
            result,
            Err(Error::Transport(tunnel_transport::Error::InvalidLimit))
        ));
        assert!(f.flow.owner_lease.is_none() && *f.flow.cancel.borrow());
        assert_eq!(f.flow.status.phase, Phase::Revoking);
        assert!(!f.flow.writer_drained && f.flow.transport_stopped);
        drain_ack(&mut f.flow, &mut output);
        assert_eq!(f.flow.status.phase, Phase::Stopped);
    }

    #[tokio::test(flavor = "current_thread")]
    async fn writer_ack_constructor_checks_actual_native_route_and_stop_epoch() {
        let mut f = Fixture::new(target());
        f.resolved().await;
        f.approve("127.0.0.1:23456".parse().unwrap(), Access::Loopback)
            .unwrap();
        f.revoke();
        let barrier = f.flow.writer_barrier().unwrap();
        let epoch = f.flow.stop.as_ref().unwrap().epoch();
        let mut wrong = f.flow.identity.clone();
        wrong.namespace = "b".repeat(64);
        assert_eq!(
            WriterDrainAck::from_completed_writer(barrier.clone(), &wrong, None, epoch).err(),
            Some(Error::Stale)
        );
        wrong = f.flow.identity.clone();
        wrong.connection_nonce = "09".repeat(16);
        assert_eq!(
            WriterDrainAck::from_completed_writer(barrier.clone(), &wrong, None, epoch).err(),
            Some(Error::Stale)
        );
        assert_eq!(
            WriterDrainAck::from_completed_writer(
                barrier.clone(),
                &f.flow.identity,
                Some(9),
                epoch
            )
            .err(),
            Some(Error::Stale)
        );
        assert_eq!(
            WriterDrainAck::from_completed_writer(barrier.clone(), &f.flow.identity, None, 0).err(),
            Some(Error::Stale)
        );
        assert_eq!(
            WriterDrainAck::from_completed_writer(
                barrier.clone(),
                &f.flow.identity,
                None,
                epoch + 1
            )
            .err(),
            Some(Error::Stale)
        );
        f.flow.writer_drained(writer_ack(&f.flow, barrier)).unwrap();
        assert_eq!(f.flow.status.phase, Phase::Stopped);
    }

    #[test]
    fn poisoned_native_state_cuts_gate_and_preserves_retired_recovery_observation() {
        let mut f = Fixture::new(target());
        let state = f.flow.state.clone();
        assert!(std::thread::spawn(move || {
            let _guard = state.lock().unwrap();
            panic!("synthetic owned state panic");
        })
        .join()
        .is_err());
        assert_eq!(f.flow.retire(), Err(Error::StateUnavailable));
        assert!(*f.flow.cancel.borrow());
        assert_eq!(f.flow.status.phase, Phase::RecoveryRequired);
        assert!(f.flow.status.cleanup_only);
        assert!(f.flow.local(&f.actor, &f.command(Op::Query)).is_ok());
        assert_eq!(
            f.flow.local(&f.actor, &f.command(Op::RetryCleanup)).err(),
            Some(Error::StateUnavailable)
        );
        assert_eq!(f.flow.status.phase, Phase::RecoveryRequired);
    }

    #[test]
    fn actual_serde_contract_fixture_contains_pending_and_queued_not_fake_running() {
        let f = Fixture::new(target());
        let mut approve = f.command(Op::Approve);
        approve.address = Some("127.0.0.1:23456".into());
        approve.access = Some(Access::Loopback);
        let fixture = serde_json::json!({
            "pending": f.flow.status(), "resolve": f.command(Op::Resolve),
            "approve": approve, "queued": f.flow.reply(Ok(())),
            "query": f.command(Op::Query), "retry_cleanup": f.command(Op::RetryCleanup)
        });
        assert_eq!(fixture["pending"]["phase"], "Pending");
        assert_eq!(fixture["queued"]["reason"], "queued");
        assert!(fixture["queued"].get("phase").is_none());
        assert!(fixture["pending"].get("owner_lease").is_none());
        println!(
            "NIKODESK_TUNNEL_ACTUAL_SERDE:{}",
            serde_json::to_string(&fixture).unwrap()
        );
    }

    #[test]
    fn a_queued_refresh_does_not_extend_the_native_policy_lease() {
        let mut f = Fixture::new(target());
        let mut job = f.flow.prepare_refresh().unwrap();
        job.began = Instant::now() - Duration::from_millis(900);
        let began = job.began;
        let context = f.context();
        f.flow
            .finish_refresh(RefreshCompletion {
                identity: job.identity,
                began,
                context: Ok(context),
            })
            .unwrap();
        assert_eq!(f.flow.verified_at, began);
        assert_eq!(f.flow.status.phase, Phase::Pending);
        let mut expired = f.flow.prepare_refresh().unwrap();
        expired.began = Instant::now() - POLICY_LEASE;
        assert_eq!(f.flow.finish_refresh(expired.run()), Err(Error::Expired));
        assert!(*f.flow.cancel.borrow());
        assert_eq!(f.flow.status.phase, Phase::Stopped);
        assert!(f.flow.ticket.is_none() && f.flow.owner_lease.is_none());
    }

    #[test]
    fn a_refresh_cannot_cross_native_owners_or_restore_a_retired_gate() {
        let mut f = Fixture::new(target());
        let job = f.flow.prepare_refresh().unwrap();
        let mut foreign = job.identity.clone();
        foreign.connection_nonce = "03".repeat(16);
        let verified_at = f.flow.verified_at;
        let context = f.context();
        assert_eq!(
            f.flow.finish_refresh(RefreshCompletion {
                identity: foreign,
                began: job.began,
                context: Ok(context),
            }),
            Err(Error::Stale)
        );
        assert_eq!(f.flow.verified_at, verified_at);
        f.flow.retire().unwrap();
        let status = f.flow.status();
        let context = f.context();
        assert_eq!(
            f.flow.finish_refresh(RefreshCompletion {
                identity: job.identity,
                began: job.began,
                context: Ok(context),
            }),
            Err(Error::Stale)
        );
        assert_eq!(f.flow.status(), status);
        assert!(f.flow.status.cleanup_only);
    }

    #[tokio::test]
    async fn a_failed_refresh_preserves_the_original_writer_cleanup_requirement() {
        let mut f = Fixture::new(target());
        f.resolved().await;
        f.approve("127.0.0.1:23456".parse().unwrap(), Access::Loopback)
            .unwrap();
        assert_eq!(f.flow.status.phase, Phase::Starting);
        let job = f.flow.prepare_refresh().unwrap();
        assert_eq!(
            f.flow.finish_refresh(RefreshCompletion {
                identity: job.identity,
                began: job.began,
                context: Err(Error::PolicyDisabled),
            }),
            Err(Error::PolicyDisabled)
        );
        assert!(*f.flow.cancel.borrow());
        assert_ne!(f.flow.status.phase, Phase::Stopped);
        assert!(!f.flow.writer_drained);
        assert!(f.flow.local(&f.actor, &f.command(Op::Query)).is_ok());
    }

    #[tokio::test]
    async fn cancellation_between_mux_poll_and_native_report_cannot_restore_running() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let mut f = Fixture::new(Target::parse("127.0.0.1", i32::from(address.port())).unwrap());
        f.resolved().await;
        f.approve(address, Access::Loopback).unwrap();
        let (mut owner, mut output) = f.owner();
        let lease = owner.owner_lease();
        assert!(!f.flow.prepare_transport_poll(lease).unwrap());
        let ticket = f.flow.current_ticket().unwrap();
        f.flow.dispatch(&mut owner, open_msg(1, "127.0.0.1", i32::from(address.port()), CHANNEL_WINDOW)).unwrap();
        let (mut peer, _) = tokio::time::timeout(Duration::from_secs(2), listener.accept()).await.unwrap().unwrap();
        let deadline = Instant::now() + Duration::from_secs(2);
        let report = loop {
            let report = owner.poll().await;
            if report.phase == TransportPhase::Running && report.first_socket_owned { break report; }
            assert!(Instant::now() < deadline);
            tokio::time::sleep(Duration::from_millis(1)).await;
        };
        let before = f.flow.status();
        assert_eq!(f.flow.finish_transport_poll(lease + 1, report), Err(Error::WrongOwner));
        assert_eq!(f.flow.status(), before);
        f.revoke();
        assert!(f.flow.finish_transport_poll(lease, report).unwrap());
        assert_ne!(f.flow.status().phase, Phase::Running);
        assert_ne!(f.flow.status().phase, Phase::Stopped);
        assert!(!f.flow.may_write(lease, &ticket));
        owner.begin_stop();
        loop {
            let report = owner.stop_poll().await;
            f.flow.finish_transport_poll(lease, report).unwrap();
            if report.phase == TransportPhase::Stopped { break; }
            assert!(Instant::now() < deadline);
            tokio::time::sleep(Duration::from_millis(1)).await;
        }
        assert_ne!(f.flow.status().phase, Phase::Stopped);
        while output.try_recv().is_ok() {}
        let mut bytes = Vec::new();
        assert!(tokio::time::timeout(Duration::from_secs(2), peer.read_to_end(&mut bytes)).await.unwrap().is_ok());
    }
}
