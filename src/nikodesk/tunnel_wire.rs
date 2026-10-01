//! Dedicated Niko typed tunnel metadata. No function here grants a target,
//! resolves DNS, opens a socket, or accepts a remote CM approval.
use super::{connection_capabilities::Identity, tunnel_endpoint::Target, tunnel_flow::Status};
use base::message_proto::{
    message, niko_tunnel_control, port_forward_channel, Features, LoginRequest, Message,
    NikoTunnelBinding, NikoTunnelControl, NikoTunnelProbe, NikoTunnelProbeReply, NikoTunnelStatus,
    PortForward, PortForwardChannel,
};
use serde::{Deserialize, Serialize};
use std::{
    net::SocketAddr,
    time::{Duration, Instant},
};

pub(crate) const PROTOCOL: u32 = 1;
pub(crate) const PROBE_BUDGET: Duration = Duration::from_secs(2);
pub(crate) const MAX_STATUS_BYTES: usize = 8192;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Error {
    Unsupported,
    RequestsDisabled,
    InvalidBinding,
    StaleBinding,
    InvalidProbe,
    ProbeExpired,
    ProbeReplayed,
    Unauthenticated,
    InvalidLogin,
    InvalidFrame,
    WrongDirection,
    InvalidStatus,
    StaleStatus,
    InvalidControl,
}
impl Error {
    pub(crate) fn code(self) -> &'static str {
        match self {
            Self::Unsupported => "tunnel_protocol_unsupported",
            Self::RequestsDisabled => "tunnel_requests_disabled_on_remote",
            Self::InvalidBinding => "tunnel_wire_binding_invalid",
            Self::StaleBinding => "tunnel_wire_binding_stale",
            Self::InvalidProbe => "tunnel_protocol_probe_invalid",
            Self::ProbeExpired => "tunnel_protocol_probe_expired",
            Self::ProbeReplayed => "tunnel_protocol_probe_replayed",
            Self::Unauthenticated => "tunnel_authenticated_v1_connection_required",
            Self::InvalidLogin => "tunnel_typed_login_required",
            Self::InvalidFrame => "tunnel_typed_frame_invalid",
            Self::WrongDirection => "tunnel_frame_direction_invalid",
            Self::InvalidStatus => "tunnel_status_invalid",
            Self::StaleStatus => "tunnel_status_stale",
            Self::InvalidControl => "tunnel_control_invalid",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct Binding {
    nonce: [u8; 16],
    epoch: u64,
}
impl Binding {
    pub(crate) fn new(nonce: [u8; 16], epoch: u64) -> Result<Self, Error> {
        if nonce == [0; 16] || epoch == 0 || epoch > i64::MAX as u64 {
            return Err(Error::InvalidBinding);
        }
        Ok(Self { nonce, epoch })
    }
    pub(crate) fn nonce(self) -> [u8; 16] {
        self.nonce
    }
    pub(crate) fn epoch(self) -> u64 {
        self.epoch
    }
    fn metadata(self) -> NikoTunnelBinding {
        NikoTunnelBinding {
            protocol: PROTOCOL,
            nonce: self.nonce.to_vec().into(),
            epoch: self.epoch,
            ..Default::default()
        }
    }
    fn parse(value: Option<&NikoTunnelBinding>) -> Result<Self, Error> {
        let value = value.ok_or(Error::InvalidBinding)?;
        if value.protocol != PROTOCOL || value.nonce.len() != 16 {
            return Err(Error::InvalidBinding);
        }
        let mut nonce = [0; 16];
        nonce.copy_from_slice(&value.nonce);
        Self::new(nonce, value.epoch)
    }
    fn expect(self, value: Option<&NikoTunnelBinding>) -> Result<(), Error> {
        if Self::parse(value)? != self {
            return Err(Error::StaleBinding);
        }
        Ok(())
    }
}

/// Native facts from this particular encrypted private stream before login.
/// A successful probe describes request support only, never authentication.
#[derive(Clone, Copy)]
pub(crate) struct ProbeFacts {
    pub(crate) encrypted: bool,
    pub(crate) private_stream_bound: bool,
    pub(crate) before_login: bool,
    pub(crate) stream_nonce: [u8; 16],
}
impl ProbeFacts {
    fn check(self) -> Result<(), Error> {
        if !self.encrypted
            || !self.private_stream_bound
            || !self.before_login
            || self.stream_nonce == [0; 16]
        {
            return Err(Error::InvalidProbe);
        }
        Ok(())
    }
}

/// These are actual current login/token/TOTP facts, not fields received on wire.
#[derive(Clone, Copy)]
pub(crate) struct CallerFacts {
    pub(crate) encrypted: bool,
    pub(crate) authenticated: bool,
    pub(crate) typed_tunnel_v1: bool,
    pub(crate) ordinary_user: bool,
    pub(crate) totp_required: bool,
    pub(crate) totp_verified_current: bool,
}
impl CallerFacts {
    fn route(self) -> Result<(), Error> {
        if !self.encrypted || !self.authenticated || !self.typed_tunnel_v1 || !self.ordinary_user {
            return Err(Error::Unauthenticated);
        }
        Ok(())
    }
    fn request(self) -> Result<(), Error> {
        self.route()?;
        if self.totp_required && !self.totp_verified_current {
            return Err(Error::Unauthenticated);
        }
        Ok(())
    }
}

pub(crate) fn features(requests_allowed: bool) -> Features {
    Features {
        port_forward_mux: true,
        nikodesk_tunnel_v1: true,
        nikodesk_tunnel_requests_allowed: requests_allowed,
        ..Default::default()
    }
}
fn require_peer(peer: &Features) -> Result<(), Error> {
    if !peer.port_forward_mux || !peer.nikodesk_tunnel_v1 {
        return Err(Error::Unsupported);
    }
    Ok(())
}
fn probe_nonce(protocol: u32, nonce: &[u8]) -> Result<[u8; 16], Error> {
    if protocol != PROTOCOL || nonce.len() != 16 || nonce == [0; 16] {
        return Err(Error::InvalidProbe);
    }
    let mut result = [0; 16];
    result.copy_from_slice(nonce);
    Ok(result)
}

/// Retain on the same stream that will send the login; never reuse across a
/// reconnect. The outer actor also bounds the real send/read by this deadline.
pub(crate) struct ProbeFence {
    nonce: [u8; 16],
    stream_nonce: [u8; 16],
    deadline: Instant,
    sent: bool,
    consumed: bool,
}
pub(crate) struct ProbeReceipt {
    nonce: [u8; 16],
    stream_nonce: [u8; 16],
    deadline: Instant,
}
impl ProbeFence {
    pub(crate) fn new(nonce: [u8; 16], facts: ProbeFacts, now: Instant) -> Result<Self, Error> {
        facts.check()?;
        probe_nonce(PROTOCOL, &nonce)?;
        let deadline = now.checked_add(PROBE_BUDGET).ok_or(Error::ProbeExpired)?;
        Ok(Self {
            nonce,
            stream_nonce: facts.stream_nonce,
            deadline,
            sent: false,
            consumed: false,
        })
    }
    pub(crate) fn request(
        &mut self,
        facts: ProbeFacts,
        now: Instant,
    ) -> Result<NikoTunnelProbe, Error> {
        facts.check()?;
        if facts.stream_nonce != self.stream_nonce {
            self.consumed = true;
            return Err(Error::InvalidProbe);
        }
        if self.sent || self.consumed {
            return Err(Error::ProbeReplayed);
        }
        if now >= self.deadline {
            self.consumed = true;
            return Err(Error::ProbeExpired);
        }
        self.sent = true;
        Ok(NikoTunnelProbe {
            protocol: PROTOCOL,
            nonce: self.nonce.to_vec().into(),
            ..Default::default()
        })
    }
    pub(crate) fn accept(
        &mut self,
        reply: &NikoTunnelProbeReply,
        facts: ProbeFacts,
        now: Instant,
    ) -> Result<ProbeReceipt, Error> {
        if !self.sent || self.consumed {
            return Err(Error::ProbeReplayed);
        }
        self.consumed = true;
        facts.check()?;
        if facts.stream_nonce != self.stream_nonce {
            return Err(Error::InvalidProbe);
        }
        if now >= self.deadline {
            return Err(Error::ProbeExpired);
        }
        if probe_nonce(reply.protocol, &reply.nonce)? != self.nonce {
            return Err(Error::InvalidProbe);
        }
        if !reply.requests_allowed {
            return Err(Error::RequestsDisabled);
        }
        Ok(ProbeReceipt {
            nonce: self.nonce,
            stream_nonce: self.stream_nonce,
            deadline: self.deadline,
        })
    }
}

#[derive(Default)]
pub(crate) struct ServerProbeFence {
    stream_nonce: Option<[u8; 16]>,
    allowed: bool,
    login_seen: bool,
}
impl ServerProbeFence {
    /// Supply only the fresh read-only policy result; do not enumerate or dial.
    /// Root sends this reply on this same secured stream with a bounded deadline.
    pub(crate) fn reply(
        &mut self,
        probe: &NikoTunnelProbe,
        requests_allowed: bool,
        facts: ProbeFacts,
    ) -> Result<NikoTunnelProbeReply, Error> {
        facts.check()?;
        if self.stream_nonce.is_some() {
            return Err(Error::ProbeReplayed);
        }
        let nonce = probe_nonce(probe.protocol, &probe.nonce)?;
        self.stream_nonce = Some(facts.stream_nonce);
        self.allowed = requests_allowed;
        Ok(NikoTunnelProbeReply {
            protocol: PROTOCOL,
            nonce: nonce.to_vec().into(),
            requests_allowed,
            ..Default::default()
        })
    }
    /// Syntax/negotiation only; the actual authentication and Flow approval must
    /// follow. An old peer cannot enter by setting only the legacy mux flag.
    pub(crate) fn accept_login(
        &mut self,
        login: &PortForward,
        controller: &Features,
        facts: ProbeFacts,
    ) -> Result<TypedLogin, Error> {
        facts.check()?;
        if self.stream_nonce != Some(facts.stream_nonce) || self.login_seen {
            return Err(Error::InvalidLogin);
        }
        self.login_seen = true;
        if !self.allowed {
            return Err(Error::RequestsDisabled);
        }
        require_peer(controller)?;
        parse_login(login)
    }
}

pub(crate) struct TypedLogin {
    pub(crate) target: Target,
    pub(crate) binding: Binding,
}
pub(crate) fn typed_login(
    target: &Target,
    binding: Binding,
    receipt: ProbeReceipt,
    controller: &Features,
    facts: ProbeFacts,
    now: Instant,
) -> Result<PortForward, Error> {
    facts.check()?;
    require_peer(controller)?;
    probe_nonce(PROTOCOL, &receipt.nonce)?;
    if receipt.stream_nonce != facts.stream_nonce {
        return Err(Error::InvalidProbe);
    }
    if now >= receipt.deadline {
        return Err(Error::ProbeExpired);
    }
    Ok(PortForward {
        host: target.host().into(),
        port: i32::from(target.port()),
        multiplex: true,
        nikodesk_protocol: PROTOCOL,
        nikodesk_binding: Some(binding.metadata()).into(),
        ..Default::default()
    })
}
pub(crate) fn parse_login(login: &PortForward) -> Result<TypedLogin, Error> {
    if !login.multiplex || login.nikodesk_protocol != PROTOCOL {
        return Err(Error::InvalidLogin);
    }
    let binding = Binding::parse(login.nikodesk_binding.as_ref())?;
    let target = Target::parse(&login.host, login.port).map_err(|_| Error::InvalidLogin)?;
    Ok(TypedLogin { target, binding })
}
pub(crate) fn authenticated_login(
    login: &LoginRequest,
    peer: &Features,
    facts: CallerFacts,
) -> Result<TypedLogin, Error> {
    facts.request()?;
    require_peer(peer)?;
    match login.union.as_ref() {
        Some(base::message_proto::login_request::Union::PortForward(value)) => parse_login(value),
        _ => Err(Error::InvalidLogin),
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Direction {
    ControllerToReceiver,
    ReceiverToController,
}
fn frame_payload(frame: &PortForwardChannel, direction: Direction) -> Result<(), Error> {
    use port_forward_channel::Union;
    let id = match frame.union.as_ref() {
        Some(Union::Open(value)) => {
            if direction != Direction::ControllerToReceiver {
                return Err(Error::WrongDirection);
            }
            if value.window == 0
                || value.window > crate::port_forward_mux::MAX_SEND_CREDIT
                || Target::parse(&value.host, value.port).is_err()
            {
                return Err(Error::InvalidFrame);
            }
            value.channel_id
        }
        Some(Union::Opened(value)) => {
            if direction != Direction::ReceiverToController {
                return Err(Error::WrongDirection);
            }
            if value.message.len() > 256
                || value.success
                    && (value.window == 0
                        || value.window > crate::port_forward_mux::MAX_SEND_CREDIT)
            {
                return Err(Error::InvalidFrame);
            }
            value.channel_id
        }
        Some(Union::Data(value)) => {
            if value.data.is_empty() || value.data.len() > crate::port_forward_mux::MAX_FRAME {
                return Err(Error::InvalidFrame);
            }
            value.channel_id
        }
        Some(Union::Close(value)) => value.channel_id,
        Some(Union::WindowUpdate(value)) => {
            if value.add == 0 || value.add > crate::port_forward_mux::MAX_SEND_CREDIT {
                return Err(Error::InvalidFrame);
            }
            value.channel_id
        }
        _ => return Err(Error::InvalidFrame),
    };
    if id <= 0 {
        return Err(Error::InvalidFrame);
    }
    Ok(())
}
pub(crate) fn tag_frame(
    mut frame: PortForwardChannel,
    binding: Binding,
    peer: &Features,
    facts: CallerFacts,
    direction: Direction,
) -> Result<PortForwardChannel, Error> {
    facts.request()?;
    require_peer(peer)?;
    if frame.nikodesk_binding.is_some() {
        binding.expect(frame.nikodesk_binding.as_ref())?;
    }
    frame_payload(&frame, direction)?;
    frame.nikodesk_binding = Some(binding.metadata()).into();
    Ok(frame)
}
pub(crate) fn validate_frame(
    frame: &PortForwardChannel,
    binding: Binding,
    peer: &Features,
    facts: CallerFacts,
    direction: Direction,
) -> Result<(), Error> {
    facts.request()?;
    require_peer(peer)?;
    binding.expect(frame.nikodesk_binding.as_ref())?;
    frame_payload(frame, direction)
}
pub(crate) fn tag_message(
    message: &mut Message,
    binding: Binding,
    peer: &Features,
    facts: CallerFacts,
    direction: Direction,
) -> Result<(), Error> {
    let frame = match message.union.as_mut() {
        Some(message::Union::PortForwardChannel(frame)) => frame,
        _ => return Err(Error::InvalidFrame),
    };
    facts.request()?;
    require_peer(peer)?;
    if frame.nikodesk_binding.is_some() {
        binding.expect(frame.nikodesk_binding.as_ref())?;
    }
    frame_payload(frame, direction)?;
    frame.nikodesk_binding = Some(binding.metadata()).into();
    Ok(())
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub(crate) enum ReadPhase {
    Pending,
    Starting,
    Running,
    Revoking,
    RecoveryRequired,
    Stopped,
}
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
struct ReadTarget {
    host: String,
    port: u16,
}
/// Read-only peer claims, never a native cleanup ACK or a CM decision.
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub(crate) struct ReadOnlyStatus {
    pub(crate) identity: Identity,
    kind: String,
    pub(crate) phase: ReadPhase,
    pub(crate) reason: String,
    pub(crate) revision: String,
    pub(crate) resource_epoch: String,
    target: ReadTarget,
    pub(crate) addresses: Vec<String>,
    pub(crate) selected_address: Option<String>,
    pub(crate) cleanup_only: bool,
}
fn decimal(value: &str) -> Option<u64> {
    value
        .parse::<u64>()
        .ok()
        .filter(|n| *n > 0 && n.to_string() == value)
}
impl ReadOnlyStatus {
    pub(crate) fn target_host(&self) -> &str {
        &self.target.host
    }
    pub(crate) fn target_port(&self) -> u16 {
        self.target.port
    }
    pub(crate) fn parse(json: &str) -> Result<Self, Error> {
        if json.is_empty() || json.len() > MAX_STATUS_BYTES {
            return Err(Error::InvalidStatus);
        }
        let value: Self = serde_json::from_str(json).map_err(|_| Error::InvalidStatus)?;
        if !value.identity.valid()
            || value.kind != "tunnel"
            || decimal(&value.revision).is_none()
            || decimal(&value.resource_epoch).is_none()
            || value.reason.is_empty()
            || value.reason.len() > 96
            || !value
                .reason
                .bytes()
                .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'_')
            || value.addresses.len() > 8
        {
            return Err(Error::InvalidStatus);
        }
        let target = Target::parse(&value.target.host, i32::from(value.target.port))
            .map_err(|_| Error::InvalidStatus)?;
        if target.host() != value.target.host {
            return Err(Error::InvalidStatus);
        }
        for (index, address) in value.addresses.iter().enumerate() {
            let parsed = address
                .parse::<SocketAddr>()
                .map_err(|_| Error::InvalidStatus)?;
            let normalized = Target::parse(&parsed.ip().to_string(), i32::from(parsed.port()))
                .map_err(|_| Error::InvalidStatus)?;
            if address.len() > 64
                || parsed.to_string() != *address
                || parsed.port() != target.port()
                || normalized.host() != parsed.ip().to_string()
                || value.addresses[..index].contains(address)
            {
                return Err(Error::InvalidStatus);
            }
        }
        if value
            .selected_address
            .as_ref()
            .map_or(false, |a| !value.addresses.contains(a))
            || matches!(value.phase, ReadPhase::Starting | ReadPhase::Running)
                && value.selected_address.is_none()
        {
            return Err(Error::InvalidStatus);
        }
        Ok(value)
    }
}
pub(crate) fn status(
    binding: Binding,
    actual_status: &Status,
    peer: &Features,
    facts: CallerFacts,
) -> Result<NikoTunnelStatus, Error> {
    facts.route()?;
    require_peer(peer)?;
    let json = serde_json::to_string(actual_status).map_err(|_| Error::InvalidStatus)?;
    ReadOnlyStatus::parse(&json)?;
    Ok(NikoTunnelStatus {
        binding: Some(binding.metadata()).into(),
        status_json: json,
        ..Default::default()
    })
}

pub(crate) struct StatusFence {
    binding: Binding,
    namespace: String,
    target: Target,
    last: Option<ReadOnlyStatus>,
}
impl StatusFence {
    pub(crate) fn new(binding: Binding, namespace: String, target: Target) -> Result<Self, Error> {
        if super::server_scope::ServerScope::from_namespace(&namespace).is_none() {
            return Err(Error::InvalidStatus);
        }
        Ok(Self {
            binding,
            namespace,
            target,
            last: None,
        })
    }
    pub(crate) fn accept(
        &mut self,
        envelope: &NikoTunnelStatus,
        peer: &Features,
        facts: CallerFacts,
    ) -> Result<ReadOnlyStatus, Error> {
        facts.route()?;
        require_peer(peer)?;
        self.binding.expect(envelope.binding.as_ref())?;
        let value = ReadOnlyStatus::parse(&envelope.status_json)?;
        if value.identity.namespace != self.namespace
            || value.target.host != self.target.host()
            || value.target.port != self.target.port()
        {
            return Err(Error::StaleStatus);
        }
        if let Some(old) = &self.last {
            if old.identity != value.identity
                || decimal(&value.revision) < decimal(&old.revision)
                || decimal(&value.resource_epoch) < decimal(&old.resource_epoch)
                || old.cleanup_only && !value.cleanup_only
                || value.revision == old.revision && value != *old
                || !phase_follows(old.phase, value.phase)
            {
                return Err(Error::StaleStatus);
            }
        }
        self.last = Some(value.clone());
        Ok(value)
    }
}
fn phase_follows(old: ReadPhase, new: ReadPhase) -> bool {
    use ReadPhase::*;
    match old {
        Pending => true,
        Starting => new != Pending,
        Running => !matches!(new, Pending | Starting),
        Revoking => matches!(new, Revoking | RecoveryRequired | Stopped),
        RecoveryRequired => matches!(new, RecoveryRequired | Stopped),
        Stopped => new == Stopped,
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum ControlOp {
    Query,
    Revoke,
}
pub(crate) fn control(
    binding: Binding,
    op: ControlOp,
    peer: &Features,
    facts: CallerFacts,
) -> Result<NikoTunnelControl, Error> {
    facts.route()?;
    require_peer(peer)?;
    let op = match op {
        ControlOp::Query => niko_tunnel_control::Op::QUERY,
        ControlOp::Revoke => niko_tunnel_control::Op::REVOKE,
    };
    Ok(NikoTunnelControl {
        binding: Some(binding.metadata()).into(),
        op: op.into(),
        ..Default::default()
    })
}
pub(crate) fn validate_control(
    value: &NikoTunnelControl,
    binding: Binding,
    peer: &Features,
    facts: CallerFacts,
) -> Result<ControlOp, Error> {
    facts.route()?;
    require_peer(peer)?;
    binding.expect(value.binding.as_ref())?;
    match value.op.enum_value() {
        Ok(niko_tunnel_control::Op::QUERY) => Ok(ControlOp::Query),
        Ok(niko_tunnel_control::Op::REVOKE) => Ok(ControlOp::Revoke),
        _ => Err(Error::InvalidControl),
    }
}

pub(crate) fn is_candidate(message: &Message) -> bool {
    matches!(
        message.union.as_ref(),
        Some(message::Union::PortForwardChannel(_))
            | Some(message::Union::NikodeskTunnelProbe(_))
            | Some(message::Union::NikodeskTunnelProbeReply(_))
            | Some(message::Union::NikodeskTunnelStatus(_))
            | Some(message::Union::NikodeskTunnelControl(_))
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use base::message_proto::{
        login_request, PortForwardClose, PortForwardData, PortForwardOpen, PortForwardOpened,
        PortForwardWindowUpdate,
    };
    use hbb_common::protobuf::{EnumOrUnknown, Message as _};

    fn binding() -> Binding {
        Binding::new([7; 16], 1).unwrap()
    }
    fn probe_facts() -> ProbeFacts {
        ProbeFacts {
            encrypted: true,
            private_stream_bound: true,
            before_login: true,
            stream_nonce: [11; 16],
        }
    }
    fn facts() -> CallerFacts {
        CallerFacts {
            encrypted: true,
            authenticated: true,
            typed_tunnel_v1: true,
            ordinary_user: true,
            totp_required: true,
            totp_verified_current: true,
        }
    }
    fn target() -> Target {
        Target::parse("127.0.0.1", 23456).unwrap()
    }
    fn receipt(now: Instant) -> ProbeReceipt {
        let mut fence = ProbeFence::new([5; 16], probe_facts(), now).unwrap();
        let request = fence.request(probe_facts(), now).unwrap();
        let reply = ServerProbeFence::default()
            .reply(&request, true, probe_facts())
            .unwrap();
        fence.accept(&reply, probe_facts(), now).unwrap()
    }
    fn login() -> PortForward {
        let now = Instant::now();
        typed_login(
            &target(),
            binding(),
            receipt(now),
            &features(true),
            probe_facts(),
            now,
        )
        .unwrap()
    }
    fn close() -> PortForwardChannel {
        PortForwardChannel {
            union: Some(port_forward_channel::Union::Close(PortForwardClose {
                channel_id: 1,
                ..Default::default()
            })),
            ..Default::default()
        }
    }
    fn status_fixture() -> Status {
        Status {
            identity: Identity {
                connection_id: 7,
                namespace: "a".repeat(64),
                peer_id: "123456789".into(),
                connection_nonce: "01".repeat(16),
                request_nonce: "02".repeat(16),
                epoch: "1".into(),
            },
            kind: "tunnel",
            phase: super::super::tunnel_flow::Phase::Pending,
            reason: "local_approval_required",
            revision: "1".into(),
            resource_epoch: "1".into(),
            target: super::super::tunnel_flow::TargetView {
                host: target().host().into(),
                port: target().port(),
            },
            addresses: vec![],
            selected_address: None,
            cleanup_only: false,
        }
    }
    fn envelope(status_value: &Status) -> NikoTunnelStatus {
        status(binding(), status_value, &features(true), facts()).unwrap()
    }
    fn status_fence() -> StatusFence {
        StatusFence::new(binding(), "a".repeat(64), target()).unwrap()
    }

    #[test]
    fn binding_requires_protocol_nonzero_nonce_and_bounded_epoch() {
        for epoch in [0, i64::MAX as u64 + 1, u64::MAX] {
            assert_eq!(Binding::new([7; 16], epoch), Err(Error::InvalidBinding));
        }
        assert_eq!(Binding::new([0; 16], 1), Err(Error::InvalidBinding));
        assert!(Binding::new([7; 16], i64::MAX as u64).is_ok());
        assert_eq!(Binding::parse(None), Err(Error::InvalidBinding));
        for value in [
            NikoTunnelBinding::default(),
            NikoTunnelBinding {
                protocol: 2,
                ..binding().metadata()
            },
            NikoTunnelBinding {
                nonce: vec![1; 15].into(),
                ..binding().metadata()
            },
            NikoTunnelBinding {
                nonce: vec![1; 17].into(),
                ..binding().metadata()
            },
        ] {
            assert_eq!(Binding::parse(Some(&value)), Err(Error::InvalidBinding));
        }
        let bytes = binding().metadata().write_to_bytes().unwrap();
        assert_eq!(
            Binding::parse(Some(&NikoTunnelBinding::parse_from_bytes(&bytes).unwrap())),
            Ok(binding())
        );
    }

    #[test]
    fn old_binary_fixtures_are_unchanged_and_are_not_typed_logins_or_frames() {
        let old_login = [
            0x0a, 9, b'l', b'o', b'c', b'a', b'l', b'h', b'o', b's', b't', 0x10, 0xbd, 0x1a, 0x18,
            1,
        ];
        let parsed = PortForward::parse_from_bytes(&old_login).unwrap();
        assert_eq!(parsed.write_to_bytes().unwrap(), old_login);
        assert_eq!(parsed.nikodesk_protocol, 0);
        assert!(parsed.nikodesk_binding.is_none());
        assert!(matches!(parse_login(&parsed), Err(Error::InvalidLogin)));
        let old_frame = [0x8a, 2, 4, 0x22, 2, 0x08, 7];
        let parsed = Message::parse_from_bytes(&old_frame).unwrap();
        assert_eq!(parsed.write_to_bytes().unwrap(), old_frame);
        assert!(is_candidate(&parsed));
        let Some(message::Union::PortForwardChannel(frame)) = parsed.union else {
            panic!("old fixture type")
        };
        assert_eq!(
            validate_frame(
                &frame,
                binding(),
                &features(true),
                facts(),
                Direction::ControllerToReceiver
            ),
            Err(Error::InvalidBinding)
        );
        let old_features = Features::parse_from_bytes(&[0x18, 1]).unwrap();
        assert_eq!(old_features.write_to_bytes().unwrap(), [0x18, 1]);
        assert_eq!(require_peer(&old_features), Err(Error::Unsupported));
    }

    #[test]
    fn typed_login_normalizes_target_and_survives_actual_protobuf_roundtrip() {
        let now = Instant::now();
        let target = Target::parse("Example.COM.", 443).unwrap();
        let login = typed_login(
            &target,
            binding(),
            receipt(now),
            &features(false),
            probe_facts(),
            now,
        )
        .unwrap();
        assert_eq!(login.host, "example.com");
        assert_eq!(login.nikodesk_protocol, 1);
        assert!(login.multiplex);
        let parsed = PortForward::parse_from_bytes(&login.write_to_bytes().unwrap()).unwrap();
        let typed = parse_login(&parsed).unwrap();
        assert_eq!(typed.target, target);
        assert_eq!(typed.binding, binding());
    }

    #[test]
    fn raw_legacy_and_missing_marker_binding_or_mux_never_downgrade() {
        for value in [
            PortForward {
                nikodesk_protocol: 0,
                ..login()
            },
            PortForward {
                nikodesk_protocol: 2,
                ..login()
            },
            PortForward {
                multiplex: false,
                ..login()
            },
            PortForward {
                nikodesk_binding: None.into(),
                ..login()
            },
            PortForward {
                host: "https://example.com".into(),
                ..login()
            },
            PortForward { port: 0, ..login() },
        ] {
            assert!(parse_login(&value).is_err());
        }
    }

    #[test]
    fn successful_probe_echo_is_single_use_and_carries_no_grant() {
        let now = Instant::now();
        let mut client = ProbeFence::new([3; 16], probe_facts(), now).unwrap();
        let mut server = ServerProbeFence::default();
        let request = client.request(probe_facts(), now).unwrap();
        assert!(matches!(
            client.request(probe_facts(), now),
            Err(Error::ProbeReplayed)
        ));
        let reply = server.reply(&request, true, probe_facts()).unwrap();
        assert!(matches!(
            server.reply(&request, true, probe_facts()),
            Err(Error::ProbeReplayed)
        ));
        let receipt = client.accept(&reply, probe_facts(), now).unwrap();
        assert!(matches!(
            client.accept(&reply, probe_facts(), now),
            Err(Error::ProbeReplayed)
        ));
        let login = typed_login(
            &target(),
            binding(),
            receipt,
            &features(true),
            probe_facts(),
            now,
        )
        .unwrap();
        assert_eq!(
            server
                .accept_login(&login, &features(true), probe_facts())
                .unwrap()
                .binding,
            binding()
        );
        assert!(server
            .accept_login(&login, &features(true), probe_facts())
            .is_err());
        assert_eq!(
            request.write_to_bytes().unwrap(),
            [8, 1, 18, 16]
                .into_iter()
                .chain([3; 16])
                .collect::<Vec<_>>()
        );
    }

    #[test]
    fn bad_reply_poisoned_fence_cannot_retry_into_a_later_login() {
        let now = Instant::now();
        for reply in [
            NikoTunnelProbeReply::default(),
            NikoTunnelProbeReply {
                protocol: 1,
                nonce: vec![4; 16].into(),
                requests_allowed: true,
                ..Default::default()
            },
            NikoTunnelProbeReply {
                protocol: 2,
                nonce: vec![3; 16].into(),
                requests_allowed: true,
                ..Default::default()
            },
            NikoTunnelProbeReply {
                protocol: 1,
                nonce: vec![3; 16].into(),
                requests_allowed: false,
                ..Default::default()
            },
        ] {
            let mut fence = ProbeFence::new([3; 16], probe_facts(), now).unwrap();
            fence.request(probe_facts(), now).unwrap();
            assert!(fence.accept(&reply, probe_facts(), now).is_err());
            assert!(matches!(
                fence.accept(
                    &NikoTunnelProbeReply {
                        protocol: 1,
                        nonce: vec![3; 16].into(),
                        requests_allowed: true,
                        ..Default::default()
                    },
                    probe_facts(),
                    now
                ),
                Err(Error::ProbeReplayed)
            ));
        }
    }

    #[test]
    fn probe_timeout_and_unauthenticated_private_stream_facts_fail_closed() {
        let now = Instant::now();
        for invalid in [
            ProbeFacts {
                encrypted: false,
                ..probe_facts()
            },
            ProbeFacts {
                private_stream_bound: false,
                ..probe_facts()
            },
            ProbeFacts {
                before_login: false,
                ..probe_facts()
            },
            ProbeFacts {
                stream_nonce: [0; 16],
                ..probe_facts()
            },
        ] {
            assert!(ProbeFence::new([3; 16], invalid, now).is_err());
            assert!(ServerProbeFence::default()
                .reply(
                    &NikoTunnelProbe {
                        protocol: 1,
                        nonce: vec![3; 16].into(),
                        ..Default::default()
                    },
                    true,
                    invalid
                )
                .is_err());
        }
        let mut fence = ProbeFence::new([3; 16], probe_facts(), now).unwrap();
        let request = fence.request(probe_facts(), now).unwrap();
        let reply = ServerProbeFence::default()
            .reply(&request, true, probe_facts())
            .unwrap();
        assert!(matches!(
            fence.accept(&reply, probe_facts(), now + PROBE_BUDGET),
            Err(Error::ProbeExpired)
        ));
        assert!(matches!(
            typed_login(
                &target(),
                binding(),
                receipt(now),
                &features(true),
                probe_facts(),
                now + PROBE_BUDGET
            ),
            Err(Error::ProbeExpired)
        ));
    }

    #[test]
    fn receipt_or_reply_from_another_native_stream_cannot_open_a_new_typed_login() {
        let now = Instant::now();
        let other = ProbeFacts {
            stream_nonce: [12; 16],
            ..probe_facts()
        };
        assert!(matches!(
            typed_login(
                &target(),
                binding(),
                receipt(now),
                &features(true),
                other,
                now
            ),
            Err(Error::InvalidProbe)
        ));
        let mut fence = ProbeFence::new([3; 16], probe_facts(), now).unwrap();
        let request = fence.request(probe_facts(), now).unwrap();
        let mut server = ServerProbeFence::default();
        let reply = server.reply(&request, true, probe_facts()).unwrap();
        assert!(matches!(
            fence.accept(&reply, other, now),
            Err(Error::InvalidProbe)
        ));
        assert!(server
            .accept_login(&login(), &features(true), other)
            .is_err());
    }

    #[test]
    fn server_login_requires_probe_and_explicit_v1_mux_features() {
        assert!(ServerProbeFence::default()
            .accept_login(&login(), &features(true), probe_facts())
            .is_err());
        for peer in [
            Features::default(),
            Features {
                port_forward_mux: false,
                ..features(true)
            },
            Features {
                nikodesk_tunnel_v1: false,
                ..features(true)
            },
        ] {
            let now = Instant::now();
            let mut fence = ProbeFence::new([3; 16], probe_facts(), now).unwrap();
            let request = fence.request(probe_facts(), now).unwrap();
            let mut server = ServerProbeFence::default();
            server.reply(&request, true, probe_facts()).unwrap();
            assert!(server.accept_login(&login(), &peer, probe_facts()).is_err());
        }
        let mut server = ServerProbeFence::default();
        server
            .reply(
                &NikoTunnelProbe {
                    protocol: 1,
                    nonce: vec![3; 16].into(),
                    ..Default::default()
                },
                false,
                probe_facts(),
            )
            .unwrap();
        assert!(matches!(
            server.accept_login(&login(), &features(true), probe_facts()),
            Err(Error::RequestsDisabled)
        ));
    }

    #[test]
    fn authenticated_login_is_only_a_current_ordinary_typed_tunnel_role() {
        let value = LoginRequest {
            union: Some(login_request::Union::PortForward(login())),
            ..Default::default()
        };
        assert!(authenticated_login(&value, &features(true), facts()).is_ok());
        for invalid in [
            CallerFacts {
                encrypted: false,
                ..facts()
            },
            CallerFacts {
                authenticated: false,
                ..facts()
            },
            CallerFacts {
                typed_tunnel_v1: false,
                ..facts()
            },
            CallerFacts {
                ordinary_user: false,
                ..facts()
            },
            CallerFacts {
                totp_verified_current: false,
                ..facts()
            },
        ] {
            assert!(matches!(
                authenticated_login(&value, &features(true), invalid),
                Err(Error::Unauthenticated)
            ));
        }
        assert!(authenticated_login(&LoginRequest::default(), &features(true), facts()).is_err());
        assert!(authenticated_login(
            &LoginRequest {
                union: Some(login_request::Union::ViewCamera(Default::default())),
                ..Default::default()
            },
            &features(true),
            facts()
        )
        .is_err());
        assert!(authenticated_login(
            &value,
            &features(false),
            CallerFacts {
                totp_required: false,
                totp_verified_current: false,
                ..facts()
            }
        )
        .is_ok());
    }

    #[test]
    fn each_channel_oneof_is_tagged_and_validated_by_actual_wire_codec() {
        let variants = [
            (
                port_forward_channel::Union::Open(PortForwardOpen {
                    channel_id: 1,
                    host: target().host().into(),
                    port: i32::from(target().port()),
                    window: crate::port_forward_mux::INITIAL_WINDOW,
                    ..Default::default()
                }),
                Direction::ControllerToReceiver,
            ),
            (
                port_forward_channel::Union::Opened(PortForwardOpened {
                    channel_id: 1,
                    success: true,
                    window: crate::port_forward_mux::INITIAL_WINDOW,
                    ..Default::default()
                }),
                Direction::ReceiverToController,
            ),
            (
                port_forward_channel::Union::Data(PortForwardData {
                    channel_id: 1,
                    data: b"synthetic".to_vec().into(),
                    ..Default::default()
                }),
                Direction::ControllerToReceiver,
            ),
            (
                port_forward_channel::Union::Close(PortForwardClose {
                    channel_id: 1,
                    ..Default::default()
                }),
                Direction::ReceiverToController,
            ),
            (
                port_forward_channel::Union::WindowUpdate(PortForwardWindowUpdate {
                    channel_id: 1,
                    add: 64,
                    ..Default::default()
                }),
                Direction::ControllerToReceiver,
            ),
        ];
        for (value, direction) in variants {
            let frame = tag_frame(
                PortForwardChannel {
                    union: Some(value),
                    ..Default::default()
                },
                binding(),
                &features(true),
                facts(),
                direction,
            )
            .unwrap();
            let decoded =
                PortForwardChannel::parse_from_bytes(&frame.write_to_bytes().unwrap()).unwrap();
            assert_eq!(
                validate_frame(&decoded, binding(), &features(true), facts(), direction),
                Ok(())
            );
            assert_eq!(
                validate_frame(
                    &decoded,
                    Binding::new([8; 16], 1).unwrap(),
                    &features(true),
                    facts(),
                    direction
                ),
                Err(Error::StaleBinding)
            );
            assert_eq!(
                validate_frame(
                    &decoded,
                    Binding::new([7; 16], 2).unwrap(),
                    &features(true),
                    facts(),
                    direction
                ),
                Err(Error::StaleBinding)
            );
        }
    }

    #[test]
    fn outbound_queue_message_cannot_retag_a_stale_binding() {
        let mut message = Message::new();
        message.set_port_forward_channel(close());
        tag_message(
            &mut message,
            binding(),
            &features(true),
            facts(),
            Direction::ControllerToReceiver,
        )
        .unwrap();
        assert_eq!(
            tag_message(
                &mut message,
                Binding::new([8; 16], 1).unwrap(),
                &features(true),
                facts(),
                Direction::ControllerToReceiver
            ),
            Err(Error::StaleBinding)
        );
        assert_eq!(
            tag_message(
                &mut Message::default(),
                binding(),
                &features(true),
                facts(),
                Direction::ControllerToReceiver
            ),
            Err(Error::InvalidFrame)
        );
    }

    #[test]
    fn wrong_direction_or_absent_unknown_and_bounded_payloads_never_fall_back() {
        let open = PortForwardChannel {
            union: Some(port_forward_channel::Union::Open(PortForwardOpen {
                channel_id: 1,
                host: "127.0.0.1".into(),
                port: 80,
                window: 65536,
                ..Default::default()
            })),
            ..Default::default()
        };
        assert_eq!(
            tag_frame(
                open,
                binding(),
                &features(true),
                facts(),
                Direction::ReceiverToController
            )
            .err(),
            Some(Error::WrongDirection)
        );
        for frame in [
            PortForwardChannel::default(),
            PortForwardChannel::parse_from_bytes(&[0x3a, 0]).unwrap(),
            PortForwardChannel {
                union: Some(port_forward_channel::Union::Close(PortForwardClose {
                    channel_id: 0,
                    ..Default::default()
                })),
                ..Default::default()
            },
            PortForwardChannel {
                union: Some(port_forward_channel::Union::Data(PortForwardData {
                    channel_id: 1,
                    data: vec![1; crate::port_forward_mux::MAX_FRAME + 1].into(),
                    ..Default::default()
                })),
                ..Default::default()
            },
            PortForwardChannel {
                union: Some(port_forward_channel::Union::WindowUpdate(
                    PortForwardWindowUpdate {
                        channel_id: 1,
                        add: 0,
                        ..Default::default()
                    },
                )),
                ..Default::default()
            },
        ] {
            assert_eq!(
                tag_frame(
                    frame,
                    binding(),
                    &features(true),
                    facts(),
                    Direction::ControllerToReceiver
                )
                .err(),
                Some(Error::InvalidFrame)
            );
        }
    }

    #[test]
    fn every_data_frame_still_needs_actual_authenticated_totp_role() {
        let frame = tag_frame(
            close(),
            binding(),
            &features(true),
            facts(),
            Direction::ControllerToReceiver,
        )
        .unwrap();
        for invalid in [
            CallerFacts {
                encrypted: false,
                ..facts()
            },
            CallerFacts {
                authenticated: false,
                ..facts()
            },
            CallerFacts {
                typed_tunnel_v1: false,
                ..facts()
            },
            CallerFacts {
                ordinary_user: false,
                ..facts()
            },
            CallerFacts {
                totp_verified_current: false,
                ..facts()
            },
        ] {
            assert_eq!(
                validate_frame(
                    &frame,
                    binding(),
                    &features(true),
                    invalid,
                    Direction::ControllerToReceiver
                ),
                Err(Error::Unauthenticated)
            );
        }
        assert_eq!(
            validate_frame(
                &frame,
                binding(),
                &Features::default(),
                facts(),
                Direction::ControllerToReceiver
            ),
            Err(Error::Unsupported)
        );
    }

    #[test]
    fn actual_flow_status_serializer_is_bounded_read_only_metadata() {
        let actual = status_fixture();
        let wire = envelope(&actual);
        assert_eq!(wire.status_json, serde_json::to_string(&actual).unwrap());
        let decoded = NikoTunnelStatus::parse_from_bytes(&wire.write_to_bytes().unwrap()).unwrap();
        let accepted = status_fence()
            .accept(&decoded, &features(true), facts())
            .unwrap();
        assert_eq!(serde_json::to_string(&accepted).unwrap(), wire.status_json);
        assert_eq!(accepted.target_host(), actual.target.host);
        assert_eq!(accepted.target_port(), actual.target.port);
        assert_eq!(accepted.phase, ReadPhase::Pending);
        assert!(accepted.selected_address.is_none());
        assert!(!accepted.cleanup_only);
        assert!(accepted.addresses.is_empty());
    }

    #[test]
    fn status_cannot_change_original_target_namespace_nonce_or_connection() {
        let actual = status_fixture();
        for mutate in [0, 1, 2, 3] {
            let mut fence = status_fence();
            fence
                .accept(&envelope(&actual), &features(true), facts())
                .unwrap();
            let mut wrong = actual.clone();
            wrong.revision = "2".into();
            match mutate {
                0 => wrong.target.port += 1,
                1 => wrong.identity.namespace = "b".repeat(64),
                2 => wrong.identity.request_nonce = "03".repeat(16),
                _ => wrong.identity.connection_id += 1,
            }
            assert_eq!(
                fence
                    .accept(&envelope(&wrong), &features(true), facts())
                    .err(),
                Some(Error::StaleStatus)
            );
        }
        let mut wrong = envelope(&actual);
        wrong.binding = Some(Binding::new([8; 16], 1).unwrap().metadata()).into();
        assert_eq!(
            status_fence()
                .accept(&wrong, &features(true), facts())
                .err(),
            Some(Error::StaleBinding)
        );
    }

    #[test]
    fn status_unknown_fields_invalid_counters_and_oversized_json_are_rejected() {
        let value = status_fixture();
        let mut malformed = serde_json::to_value(&value).unwrap();
        malformed["grant"] = true.into();
        assert_eq!(
            ReadOnlyStatus::parse(&malformed.to_string()).err(),
            Some(Error::InvalidStatus)
        );
        for count in ["0", "01", "18446744073709551616", "-1"] {
            let mut malformed = serde_json::to_value(&value).unwrap();
            malformed["revision"] = count.into();
            assert_eq!(
                ReadOnlyStatus::parse(&malformed.to_string()).err(),
                Some(Error::InvalidStatus)
            );
        }
        assert_eq!(
            ReadOnlyStatus::parse(&" ".repeat(MAX_STATUS_BYTES + 1)).err(),
            Some(Error::InvalidStatus)
        );
        let mut wrong = value.clone();
        wrong.addresses = vec!["127.0.0.1:23456".into(); 9];
        assert_eq!(
            status(binding(), &wrong, &features(true), facts()).err(),
            Some(Error::InvalidStatus)
        );
        wrong = value;
        wrong.phase = super::super::tunnel_flow::Phase::Running;
        assert_eq!(
            status(binding(), &wrong, &features(true), facts()).err(),
            Some(Error::InvalidStatus)
        );
    }

    #[test]
    fn status_revision_resource_epoch_and_cleanup_latch_never_go_back() {
        let mut actual = status_fixture();
        let mut fence = status_fence();
        fence
            .accept(&envelope(&actual), &features(true), facts())
            .unwrap();
        assert!(fence
            .accept(&envelope(&actual), &features(true), facts())
            .is_ok());
        actual.reason = "denied_locally";
        assert_eq!(
            fence
                .accept(&envelope(&actual), &features(true), facts())
                .err(),
            Some(Error::StaleStatus)
        );
        actual.revision = "2".into();
        actual.resource_epoch = "2".into();
        actual.cleanup_only = true;
        actual.phase = super::super::tunnel_flow::Phase::RecoveryRequired;
        assert!(fence
            .accept(&envelope(&actual), &features(true), facts())
            .is_ok());
        let original = actual.clone();
        actual.revision = "3".into();
        actual.cleanup_only = false;
        assert_eq!(
            fence
                .accept(&envelope(&actual), &features(true), facts())
                .err(),
            Some(Error::StaleStatus)
        );
        actual = original;
        actual.revision = "3".into();
        actual.resource_epoch = "1".into();
        assert_eq!(
            fence
                .accept(&envelope(&actual), &features(true), facts())
                .err(),
            Some(Error::StaleStatus)
        );
        actual.resource_epoch = "2".into();
        actual.phase = super::super::tunnel_flow::Phase::Pending;
        assert_eq!(
            fence
                .accept(&envelope(&actual), &features(true), facts())
                .err(),
            Some(Error::StaleStatus)
        );
    }

    #[test]
    fn read_only_query_revoke_and_status_do_not_depend_on_request_policy_advert() {
        let peer = features(false);
        let cleanup = CallerFacts {
            totp_verified_current: false,
            ..facts()
        };
        for op in [ControlOp::Query, ControlOp::Revoke] {
            let wire = control(binding(), op, &peer, cleanup).unwrap();
            assert_eq!(validate_control(&wire, binding(), &peer, cleanup), Ok(op));
        }
        assert!(status_fence()
            .accept(
                &status(binding(), &status_fixture(), &peer, cleanup).unwrap(),
                &peer,
                cleanup
            )
            .is_ok());
        assert_eq!(
            tag_frame(
                close(),
                binding(),
                &peer,
                cleanup,
                Direction::ControllerToReceiver
            )
            .err(),
            Some(Error::Unauthenticated)
        );
    }

    #[test]
    fn unspecified_unknown_remote_control_and_wrong_binding_are_not_approvals() {
        for op in [0, 3, -1, i32::MAX] {
            let wire = NikoTunnelControl {
                binding: Some(binding().metadata()).into(),
                op: EnumOrUnknown::from_i32(op),
                ..Default::default()
            };
            let decoded =
                NikoTunnelControl::parse_from_bytes(&wire.write_to_bytes().unwrap()).unwrap();
            assert_eq!(
                validate_control(&decoded, binding(), &features(true), facts()),
                Err(Error::InvalidControl)
            );
        }
        let wire = control(binding(), ControlOp::Revoke, &features(true), facts()).unwrap();
        assert_eq!(
            validate_control(
                &wire,
                Binding::new([8; 16], 1).unwrap(),
                &features(true),
                facts()
            ),
            Err(Error::StaleBinding)
        );
        assert_eq!(
            validate_control(
                &NikoTunnelControl::default(),
                binding(),
                &features(true),
                facts()
            ),
            Err(Error::InvalidBinding)
        );
        assert!(validate_control(
            &wire,
            binding(),
            &features(true),
            CallerFacts {
                authenticated: false,
                ..facts()
            }
        )
        .is_err());
    }

    #[test]
    fn new_message_numbers_roundtrip_and_classify_before_legacy_paths() {
        let now = Instant::now();
        let probe = ProbeFence::new([3; 16], probe_facts(), now)
            .unwrap()
            .request(probe_facts(), now)
            .unwrap();
        let reply = ServerProbeFence::default()
            .reply(&probe, true, probe_facts())
            .unwrap();
        let unions = [
            message::Union::NikodeskTunnelProbe(probe),
            message::Union::NikodeskTunnelProbeReply(reply),
            message::Union::NikodeskTunnelStatus(envelope(&status_fixture())),
            message::Union::NikodeskTunnelControl(
                control(binding(), ControlOp::Query, &features(true), facts()).unwrap(),
            ),
        ];
        for (index, value) in unions.into_iter().enumerate() {
            let message = Message {
                union: Some(value),
                ..Default::default()
            };
            let bytes = message.write_to_bytes().unwrap();
            let field_key = ((36 + index) << 3) | 2;
            assert_eq!(
                usize::from(bytes[0] & 0x7f) | (usize::from(bytes[1]) << 7),
                field_key
            );
            let parsed = Message::parse_from_bytes(&bytes).unwrap();
            assert!(is_candidate(&parsed));
            assert_eq!(parsed.write_to_bytes().unwrap(), bytes);
        }
    }

    #[test]
    fn actual_flow_serde_and_protocol_fixture_can_be_exported_without_a_resource() {
        let actual = status_fixture();
        let query = control(binding(), ControlOp::Query, &features(true), facts()).unwrap();
        let revoke = control(binding(), ControlOp::Revoke, &features(true), facts()).unwrap();
        let fixture = serde_json::json!({
            "pending": serde_json::to_value(&actual).unwrap(),
            "pending_status_wire_hex": hex(&envelope(&actual).write_to_bytes().unwrap()),
            "typed_login_wire_hex": hex(&login().write_to_bytes().unwrap()),
            "query_control_wire_hex": hex(&query.write_to_bytes().unwrap()),
            "revoke_control_wire_hex": hex(&revoke.write_to_bytes().unwrap()),
            "binding": { "protocol":1,"nonce_hex":hex(&binding().nonce()),"epoch":binding().epoch().to_string() }
        });
        println!(
            "NIKO_TUNNEL_WIRE_ACTUAL_FIXTURE={}",
            serde_json::to_string_pretty(&fixture).unwrap()
        );
    }
    fn hex(bytes: &[u8]) -> String {
        bytes.iter().map(|byte| format!("{byte:02x}")).collect()
    }
}
