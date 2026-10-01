use super::*;
use crate::nikodesk::{
    connection_capabilities::Identity,
    tunnel_actor::{Actor, TaggedFrame},
    tunnel_flow::{AuthFacts, Command, Op, Phase, TrustedActor, WriterDrainAck},
    tunnel_transport::Limits,
    tunnel_wire::{self, CallerFacts, ProbeFacts, ServerProbeFence, TypedLogin},
};
use hbb_common::rand::{rngs::OsRng, RngCore};

pub(super) struct State {
    namespace: Option<String>,
    stream_nonce: Option<[u8; 16]>,
    connection_nonce: Option<String>,
    probe: ServerProbeFence,
    typed: Option<TypedLogin>,
    actor: Option<Actor>,
    frames: Option<mpsc::Receiver<TaggedFrame>>,
    last_revision: Option<String>,
    last_remote_revision: Option<String>,
    remote_query: bool,
    totp_required: bool,
    totp_verified: bool,
    retired: bool,
    retirement_sent: bool,
    writer_drained: bool,
}
impl State {
    pub(super) fn new(namespace: Option<String>, totp_required: bool) -> Self {
        let mut nonce = [0; 16];
        let stream_nonce = OsRng.try_fill_bytes(&mut nonce).ok()
            .and_then(|_| (nonce != [0; 16]).then_some(nonce));
        Self {
            namespace, stream_nonce, connection_nonce: crate::nikodesk::voice_call::nonce().ok(),
            probe: Default::default(), typed: None, actor: None, frames: None,
            last_revision: None, last_remote_revision: None, remote_query: false, totp_required, totp_verified: false,
            retired: false, retirement_sent: false, writer_drained: false,
        }
    }
    pub(super) fn typed(&self) -> bool { self.typed.is_some() }
    pub(super) fn needs_cleanup(&self) -> bool { self.retired && self.actor.is_some() }
    pub(super) fn totp_verified(&mut self) { self.totp_verified = true; }
    fn facts(&self, encrypted: bool, before_login: bool) -> ProbeFacts {
        ProbeFacts { encrypted, private_stream_bound: self.namespace.is_some()
            && !crate::nikodesk::background::is_system_worker(), before_login,
            stream_nonce: self.stream_nonce.unwrap_or([0; 16]) }
    }
    fn accept_login(&mut self, login: &LoginRequest, facts: ProbeFacts) -> Result<(), &'static str> {
        let Some(login_request::Union::PortForward(pf)) = login.union.as_ref() else {
            return if self.typed() { Err("tunnel_typed_login_required") } else { Ok(()) };
        };
        let peer = login.nikodesk_features.as_ref().ok_or("tunnel_protocol_unsupported")?;
        if let Some(original) = &self.typed {
            let retry = tunnel_wire::parse_login(pf).map_err(|error| error.code())?;
            if original.binding != retry.binding || original.target != retry.target
                || !peer.nikodesk_tunnel_v1 || !peer.port_forward_mux {
                return Err("tunnel_wire_binding_stale");
            }
            return Ok(());
        }
        self.typed = Some(self.probe.accept_login(pf, peer, facts).map_err(|error| error.code())?);
        Ok(())
    }
    fn drain_writer(&mut self) {
        if let Some(mut frames) = self.frames.take() {
            frames.close();
            while frames.try_recv().is_ok() {}
        }
    }
    fn acknowledge_writer(&mut self) {
        if self.writer_drained { return; }
        let Some(actor) = self.actor.as_ref() else { return; };
        let Ok(cutoff) = actor.cutoff_native() else { return; };
        // This function runs on the sole native Stream writer after its prior
        // send completed. Closed typed queues can never be sent again.
        self.drain_writer();
        let Some(actor) = self.actor.as_ref() else { return; };
        let Ok(barrier) = actor.writer_barrier() else { return; };
        let Ok(ack) = WriterDrainAck::from_completed_writer(barrier, cutoff.identity(),
            cutoff.owner_lease(), cutoff.stop_epoch()) else { return; };
        if actor.writer_ack(ack).is_ok() { self.writer_drained = true; }
    }
    fn publish_cm(&mut self, sender: &mpsc::UnboundedSender<Data>) {
        let Some(actor) = self.actor.as_ref() else { return; };
        let status = actor.status();
        if self.last_revision.as_ref() == Some(&status.revision) { return; }
        if self.retired && !status.cleanup_only { return; }
        let Ok(json) = serde_json::to_string(&status) else { return; };
        let data = if self.retired {
            if self.retirement_sent { Data::NikoTunnelCleanupStatus(json) }
            else { Data::NikoTunnelRetired(json) }
        } else { Data::NikoTunnelStatus(json) };
        if sender.send(data).is_ok() {
            self.last_revision = Some(status.revision);
            if self.retired { self.retirement_sent = true; }
        }
    }
    fn command(&self, command: Command) {
        let Some(actor) = self.actor.as_ref() else { return; };
        let identity = actor.status().identity;
        if command.identity != identity { return; }
        // Only the existing protected _cm IPC dispatcher calls this path.
        if let Ok(trusted) = TrustedActor::from_verified_cm(&identity) {
            let _ = actor.try_local(trusted, command);
        }
    }
    pub(super) fn take_cleanup(&mut self) -> Option<Self> {
        if !self.retired || self.actor.is_none() { return None; }
        let replacement = Self { namespace: None, stream_nonce: None, connection_nonce: None,
            probe: Default::default(), typed: None, actor: None, frames: None, last_revision: None, last_remote_revision: None, remote_query: false,
            totp_required: true, totp_verified: false, retired: false, retirement_sent: false,
            writer_drained: false };
        Some(std::mem::replace(self, replacement))
    }
}

impl Connection {
    pub(super) fn nikodesk_tunnel_target_label(&self) -> Option<String> {
        self.niko_tunnel.typed.as_ref().map(|typed| typed.target.label())
    }
    fn tunnel_caller(&self) -> CallerFacts {
        CallerFacts { encrypted: self.stream.is_secured(), authenticated: self.authorized,
            typed_tunnel_v1: self.is_nikodesk_tunnel(), ordinary_user: !crate::nikodesk::background::is_system_worker(),
            totp_required: self.niko_tunnel.totp_required, totp_verified_current: self.niko_tunnel.totp_verified }
    }
    pub(super) fn check_nikodesk_tunnel_login(&mut self, login: &LoginRequest) -> Result<(), &'static str> {
        let facts = self.niko_tunnel.facts(self.stream.is_secured(), !self.authorized && self.login_scope.is_none());
        self.niko_tunnel.accept_login(login, facts)
    }
    pub(super) async fn activate_nikodesk_tunnel(&mut self) -> Result<(), &'static str> {
        if !self.is_nikodesk_tunnel() { return Ok(()); }
        if self.niko_tunnel.actor.is_some() { return Err("tunnel_duplicate_activation"); }
        let peer = self.lr.nikodesk_features.as_ref().ok_or("tunnel_protocol_unsupported")?.clone();
        let typed = tunnel_wire::authenticated_login(&self.lr, &peer, self.tunnel_caller()).map_err(|error| error.code())?;
        let namespace = self.niko_tunnel.namespace.clone().ok_or("tunnel_context_changed")?;
        let identity = Identity { connection_id: self.inner.id(), namespace, peer_id: self.lr.my_id.clone(),
            connection_nonce: self.niko_tunnel.connection_nonce.clone().ok_or("tunnel_nonce_unavailable")?,
            request_nonce: crate::nikodesk::voice_call::nonce().map_err(|_| "tunnel_nonce_unavailable")?, epoch: "1".into() };
        let facts = self.tunnel_caller();
        let auth = AuthFacts { encrypted: facts.encrypted, authenticated: facts.authenticated,
            ordinary_tunnel_v1: facts.typed_tunnel_v1 && facts.ordinary_user,
            totp_required: facts.totp_required, totp_verified_current: facts.totp_verified_current };
        let mut actor = Actor::authenticated(tokio::runtime::Handle::current(), identity,
            typed.target, auth, typed.binding, peer, Limits::default()).await.map_err(|error| error.code())?;
        if let Some(audit) = self.niko_audit.as_ref() {
            actor.attach_audit(audit.capability_context()).map_err(|error| error.code())?;
        }
        super::nikodesk_tunnel_retired::register(actor.retired_observer(), tokio::runtime::Handle::current())?;
        self.niko_tunnel.frames = actor.take_frames();
        self.niko_tunnel.actor = Some(actor);
        crate::port_forward_mux::cap_packet_size(&mut self.stream);
        Ok(())
    }
    pub(super) fn nikodesk_tunnel_features(&self) -> Features {
        tunnel_wire::features(self.niko_tunnel.actor.is_some()
            && !self.niko_tunnel.retired && matches!(self.niko_tunnel.actor.as_ref().map(Actor::status).map(|s|s.phase),
                Some(Phase::Pending | Phase::Starting | Phase::Running)))
    }
    pub(super) async fn handle_nikodesk_tunnel_message(&mut self, msg: &Message) -> Option<bool> {
        if let Some(message::Union::NikodeskTunnelProbe(probe)) = msg.union.as_ref() {
            let facts = self.niko_tunnel.facts(self.stream.is_secured(), !self.authorized && self.login_scope.is_none());
            let allowed = if let Some(namespace) = self.niko_tunnel.namespace.clone() {
                matches!(tokio::task::spawn_blocking(move || crate::nikodesk::tunnel_flow::availability(&namespace)).await, Ok(Ok(())))
            } else { false };
            let Ok(reply) = self.niko_tunnel.probe.reply(probe, allowed, facts) else { return Some(false); };
            let mut msg = Message::new(); msg.set_nikodesk_tunnel_probe_reply(reply);
            return Some(matches!(tokio::time::timeout(Duration::from_secs(2), self.stream.send(&msg)).await, Ok(Ok(()))));
        }
        if !tunnel_wire::is_candidate(msg) { return None; }
        let Some(peer) = self.lr.nikodesk_features.as_ref() else { return Some(false); };
        let Some(actor) = self.niko_tunnel.actor.as_ref() else { return Some(false); };
        let facts = self.tunnel_caller();
        let binding = actor.binding();
        match msg.union.as_ref() {
            Some(message::Union::NikodeskTunnelControl(control)) => {
                let Ok(op) = tunnel_wire::validate_control(control, binding, peer, facts) else { return Some(false); };
                let accepted = actor.remote_control(binding, op).is_ok();
                if accepted && op == tunnel_wire::ControlOp::Query { self.niko_tunnel.remote_query = true; }
                Some(accepted)
            }
            Some(message::Union::PortForwardChannel(_)) => Some(actor.try_frame(binding, msg.clone()).is_ok()),
            _ => Some(false),
        }
    }
    pub(super) fn handle_nikodesk_tunnel_command(&mut self, command: Command) {
        if !self.authorized || self.closed || !self.stream.is_secured() || !self.is_nikodesk_tunnel() { return; }
        self.niko_tunnel.command(command);
    }
    pub(super) async fn poll_nikodesk_tunnel(&mut self) -> bool {
        let Some(actor) = self.niko_tunnel.actor.as_mut() else { return true; };
        let completion = actor.finished().await;
        let status = actor.status();
        if matches!(status.phase, Phase::Revoking | Phase::RecoveryRequired) {
            self.niko_tunnel.acknowledge_writer();
        }
        if status.phase == Phase::Stopped {
            let Some(actor) = self.niko_tunnel.actor.as_ref() else { return false; };
            if !matches!(completion, Ok(true)) { return true; }
            super::nikodesk_tunnel_retired::unregister(&actor.status().identity);
        }
        self.niko_tunnel.publish_cm(&self.tx_to_cm);
        if !self.authorized || self.closed { return true; }
        if let Some(actor) = self.niko_tunnel.actor.as_ref() {
            let status = actor.status();
            if self.niko_tunnel.remote_query || self.niko_tunnel.last_remote_revision.as_ref() != Some(&status.revision) {
                let Some(peer) = self.lr.nikodesk_features.as_ref() else { return false; };
                let Ok(envelope) = tunnel_wire::status(actor.binding(), &status, peer, self.tunnel_caller()) else { return false; };
                let mut msg = Message::new(); msg.set_nikodesk_tunnel_status(envelope);
                if !matches!(tokio::time::timeout(Duration::from_millis(500), self.stream.send(&msg)).await, Ok(Ok(()))) {
                    let _ = actor.cancel(); return false;
                }
                self.niko_tunnel.last_remote_revision = Some(status.revision);
                self.niko_tunnel.remote_query = false;
            }
        }
        let frame = self.niko_tunnel.frames.as_mut().and_then(|frames| frames.try_recv().ok());
        if let Some(frame) = frame {
            let Some(actor) = self.niko_tunnel.actor.as_ref() else { return false; };
            let caller = self.tunnel_caller();
            if actor.may_send(&frame) && caller.encrypted && caller.authenticated && caller.ordinary_user
                && caller.typed_tunnel_v1 && (!caller.totp_required || caller.totp_verified_current) {
                if !matches!(tokio::time::timeout(Duration::from_millis(500), self.stream.send(frame.message())).await, Ok(Ok(()))) {
                    let _ = actor.cancel(); return false;
                }
            }
        }
        true
    }
    pub(super) fn retire_nikodesk_tunnel(&mut self) {
        if let Some(actor) = self.niko_tunnel.actor.as_ref() {
            self.niko_tunnel.retired = true;
            let _ = actor.parent_closed();
        }
    }
}

pub(super) async fn retired_cleanup(mut state: State, mut receiver: mpsc::UnboundedReceiver<Data>, sender: mpsc::UnboundedSender<Data>) {
    // The caller dropped the entire original Connection/Stream before spawning.
    state.drain_writer();
    let mut timer = time::interval(Duration::from_millis(50));
    let mut channel_open = true;
    loop {
        tokio::select! {
            command = receiver.recv(), if channel_open => match command {
                Some(Data::NikoTunnelCommand(command)) if matches!(command.op, Op::Query | Op::RetryCleanup) => state.command(command),
                Some(_) => {}, None => channel_open = false,
            },
            _ = timer.tick() => {
                state.acknowledge_writer();
                let completion = match state.actor.as_mut() {
                    Some(actor) => actor.finished().await,
                    None => Ok(false),
                };
                let stopped = state.actor.as_ref().is_some_and(|actor| actor.status().phase == Phase::Stopped);
                // A failed join updates the original Flow to RecoveryRequired;
                // only a true final join can expose Stopped or remove its owner.
                if !stopped || matches!(completion, Ok(true)) { state.publish_cm(&sender); }
                if stopped && matches!(completion, Ok(true)) {
                    if let Some(actor) = state.actor.as_ref() {
                        super::nikodesk_tunnel_retired::unregister(&actor.status().identity);
                        let _ = sender.send(Data::Close); break;
                    }
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::nikodesk::{tunnel_endpoint::Target, tunnel_wire::{Binding, ProbeFence}};

    fn negotiated(state: &mut State) -> LoginRequest {
        let facts = state.facts(true, true);
        let now = std::time::Instant::now();
        let mut controller = ProbeFence::new([7; 16], facts, now).unwrap();
        let probe = controller.request(facts, now).unwrap();
        let reply = state.probe.reply(&probe, true, facts).unwrap();
        let receipt = controller.accept(&reply, facts, now).unwrap();
        let peer = tunnel_wire::features(true);
        let target = Target::parse("LOCALHOST", 23456).unwrap();
        let pf = tunnel_wire::typed_login(&target, Binding::new([8; 16], 1).unwrap(), receipt, &peer, facts, now).unwrap();
        let mut login = LoginRequest::new();
        login.nikodesk_features = Some(peer).into();
        login.set_port_forward(pf);
        login
    }

    #[test]
    fn tunnel_native_probe_and_retry_keep_original_stream_target_and_binding() {
        let mut state = State::new(Some("a".repeat(64)), true);
        let mut login = negotiated(&mut state);
        let facts = state.facts(true, true);
        state.accept_login(&login, facts).unwrap();
        assert!(state.typed());
        assert_eq!(state.typed.as_ref().unwrap().target.host(), "localhost");
        login.password = vec![1, 2, 3].into();
        state.accept_login(&login, state.facts(true, false)).unwrap();
        let mut replaced = login.clone();
        if let Some(login_request::Union::PortForward(pf)) = replaced.union.as_mut() { pf.host = "other.local".into(); }
        assert_eq!(state.accept_login(&replaced, facts), Err("tunnel_wire_binding_stale"));
        let mut replaced = login.clone();
        if let Some(login_request::Union::PortForward(pf)) = replaced.union.as_mut() { pf.nikodesk_binding.as_mut().unwrap().epoch = 2; }
        assert_eq!(state.accept_login(&replaced, facts), Err("tunnel_wire_binding_stale"));
        assert_eq!(state.accept_login(&LoginRequest::new(), facts), Err("tunnel_typed_login_required"));
        assert!(!state.totp_verified);
        state.totp_verified();
        assert!(state.totp_verified);
        assert!(!state.needs_cleanup());
    }

    #[test]
    fn tunnel_native_login_without_same_private_encrypted_probe_is_rejected() {
        let mut source = State::new(Some("a".repeat(64)), false);
        let login = negotiated(&mut source);
        let mut unrelated = State::new(Some("a".repeat(64)), false);
        assert!(unrelated.accept_login(&login, unrelated.facts(true, true)).is_err());
        assert!(source.accept_login(&login, source.facts(false, true)).is_err());
        let mut missing_private = State::new(None, false);
        assert!(missing_private.accept_login(&login, missing_private.facts(true, true)).is_err());
        let mut legacy = LoginRequest::new();
        legacy.set_port_forward(PortForward { host: "127.0.0.1".into(), port: 23456, multiplex: true, ..Default::default() });
        legacy.nikodesk_features = Some(tunnel_wire::features(true)).into();
        assert!(source.accept_login(&legacy, source.facts(true, true)).is_err());
    }
}
