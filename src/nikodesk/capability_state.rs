//! Per-connection authorization for Niko capabilities. This module starts no resources.
use std::{
    collections::BTreeMap,
    net::SocketAddr,
    time::{Duration, Instant},
};

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub(crate) enum Kind {
    Terminal,
    Tunnel,
    Camera,
    Voice,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum NormalUser {
    Unix(u32),
    Windows {
        sid: String,
        interactive: bool,
        elevated: bool,
    },
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum Scope {
    Terminal(NormalUser),
    Tunnel(SocketAddr),
    Camera(String),
    Voice { capture: bool, playback: bool },
    // A local voice approval freezes the exact devices, format and call binding.
    VoiceDevices { fingerprint: String },
}

impl Scope {
    fn kind(&self) -> Kind {
        match self {
            Self::Terminal(_) => Kind::Terminal,
            Self::Tunnel(_) => Kind::Tunnel,
            Self::Camera(_) => Kind::Camera,
            Self::Voice { .. } | Self::VoiceDevices { .. } => Kind::Voice,
        }
    }

    fn valid(&self) -> bool {
        match self {
            Self::Terminal(NormalUser::Unix(uid)) => *uid != 0,
            Self::Terminal(NormalUser::Windows {
                sid,
                interactive,
                elevated,
            }) => {
                *interactive
                    && !*elevated
                    && sid.starts_with("S-1-")
                    && sid.len() <= 184
                    && sid[4..].split('-').all(|part| {
                        !part.is_empty() && part.bytes().all(|byte| byte.is_ascii_digit())
                    })
                    && !matches!(sid.as_str(), "S-1-5-18" | "S-1-5-19" | "S-1-5-20")
            }
            Self::Tunnel(address) => {
                address.port() != 0
                    && !address.ip().is_unspecified()
                    && !address.ip().is_multicast()
                    && address.ip() != std::net::Ipv4Addr::BROADCAST
            }
            Self::Camera(device) => {
                !device.is_empty() && device.len() <= 256 && !device.chars().any(char::is_control)
            }
            Self::Voice { capture, playback } => *capture || *playback,
            Self::VoiceDevices { fingerprint } => {
                fingerprint.len() == 64
                    && fingerprint.bytes().all(|byte| {
                        byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte)
                    })
            }
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Binding {
    namespace: String,
    peer_id: String,
    connection_nonce: [u8; 16],
}

impl Binding {
    pub(crate) fn new(
        namespace: String,
        peer_id: String,
        connection_nonce: [u8; 16],
    ) -> Result<Self, Error> {
        if namespace.len() != 64
            || !namespace
                .bytes()
                .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
            || !(6..=16).contains(&peer_id.len())
            || !peer_id.bytes().all(|byte| byte.is_ascii_digit())
            || connection_nonce == [0; 16]
        {
            return Err(Error::InvalidBinding);
        }
        Ok(Self {
            namespace,
            peer_id,
            connection_nonce,
        })
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Phase {
    Stopped,
    Pending,
    Starting,
    Running,
    Revoking,
    RecoveryRequired,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Error {
    InvalidBinding,
    NotAuthenticated,
    Disabled,
    Unsupported,
    InvalidScope,
    InvalidNonce,
    InvalidLifetime,
    Busy,
    Stale,
    Expired,
    Exhausted,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Request {
    binding: Binding,
    scope: Scope,
    nonce: [u8; 16],
    epoch: u64,
}

impl Request {
    pub(crate) fn epoch(&self) -> u64 {
        self.epoch
    }

    pub(crate) fn nonce(&self) -> [u8; 16] {
        self.nonce
    }

    pub(crate) fn scope(&self) -> &Scope {
        &self.scope
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Ticket {
    request: Request,
}

impl Ticket {
    pub(crate) fn scope(&self) -> &Scope {
        &self.request.scope
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct StopTicket {
    binding: Binding,
    kind: Kind,
    epoch: u64,
}

impl StopTicket {
    pub(crate) fn epoch(&self) -> u64 {
        self.epoch
    }
}

struct Slot {
    supported: bool,
    enabled: bool,
    epoch: u64,
    phase: Phase,
    request: Option<Request>,
    deadline: Option<Instant>,
    last_nonce: Option<[u8; 16]>,
    exhausted: bool,
}

impl Default for Slot {
    fn default() -> Self {
        Self {
            supported: false,
            enabled: false,
            epoch: 0,
            phase: Phase::Stopped,
            request: None,
            deadline: None,
            last_nonce: None,
            exhausted: false,
        }
    }
}

impl Slot {
    fn advance(&mut self) -> Result<(), Error> {
        if let Some(epoch) = self.epoch.checked_add(1).filter(|_| !self.exhausted) {
            self.epoch = epoch;
            Ok(())
        } else {
            self.exhausted = true;
            self.enabled = false;
            self.phase = Phase::RecoveryRequired;
            self.request = None;
            self.deadline = None;
            Err(Error::Exhausted)
        }
    }
}

pub(crate) struct Capabilities {
    binding: Binding,
    authenticated: bool,
    slots: BTreeMap<Kind, Slot>,
    audit: Option<super::capability_audit::Context>,
}

impl Capabilities {
    /// Authentication here must be supplied by the existing encrypted login boundary.
    pub(crate) fn new(binding: Binding, secured: bool, authenticated: bool) -> Self {
        let slots = [Kind::Terminal, Kind::Tunnel, Kind::Camera, Kind::Voice]
            .into_iter()
            .map(|kind| (kind, Slot::default()))
            .collect();
        Self {
            binding,
            authenticated: secured && authenticated,
            slots,
            audit: None,
        }
    }

    pub(crate) fn attach_audit(&mut self, context: Option<super::capability_audit::Context>) {
        if self.audit.is_none() && self.authenticated {
            self.audit = context.filter(|context| context.matches(&self.binding.namespace,&self.binding.peer_id));
            for kind in [Kind::Terminal,Kind::Camera,Kind::Tunnel,Kind::Voice] {self.audit_phase(kind);}
        }
    }
    fn audit_phase(&self, kind: Kind) {
        let Some(context) = self.audit.as_ref() else {return;};
        let Some(nonce) = self.slots[&kind].last_nonce else {return;};
        let phase = self.slots[&kind].phase;
        let nonce = nonce.iter().map(|byte| format!("{byte:02x}")).collect::<String>();
        let kind = match kind {Kind::Terminal=>super::capability_audit::Kind::Terminal,Kind::Camera=>super::capability_audit::Kind::Camera,
            Kind::Tunnel=>super::capability_audit::Kind::Tunnel,Kind::Voice=>super::capability_audit::Kind::Voice};
        context.observe(kind,&self.binding.namespace,&self.binding.peer_id,&nonce,
            &format!("{phase:?}"),false,false);
    }

    pub(crate) fn phase(&self, kind: Kind) -> Phase {
        self.slots[&kind].phase
    }

    pub(crate) fn set_policy(
        &mut self,
        kind: Kind,
        supported: bool,
        enabled: bool,
    ) -> Result<Option<StopTicket>, Error> {
        if enabled && !supported {
            return Err(Error::Unsupported);
        }
        let slot = self.slots.get_mut(&kind).ok_or(Error::Unsupported)?;
        if slot.exhausted && enabled {
            return Err(Error::Exhausted);
        }
        slot.supported = supported;
        slot.enabled = enabled;
        if !enabled || !supported {
            self.revoke(kind)
        } else {
            Ok(None)
        }
    }

    pub(crate) fn request(
        &mut self,
        scope: Scope,
        nonce: [u8; 16],
        now: Instant,
    ) -> Result<Request, Error> {
        if !self.authenticated {
            return Err(Error::NotAuthenticated);
        }
        if !scope.valid() {
            return Err(Error::InvalidScope);
        }
        if nonce == [0; 16] {
            return Err(Error::InvalidNonce);
        }
        let slot = self
            .slots
            .get_mut(&scope.kind())
            .ok_or(Error::Unsupported)?;
        if slot.exhausted {
            return Err(Error::Exhausted);
        }
        if !slot.supported {
            return Err(Error::Unsupported);
        }
        if !slot.enabled {
            return Err(Error::Disabled);
        }
        if matches!(
            slot.phase,
            Phase::Starting | Phase::Running | Phase::Revoking | Phase::RecoveryRequired
        ) {
            return Err(Error::Busy);
        }
        if slot.last_nonce == Some(nonce) {
            return Err(Error::InvalidNonce);
        }
        slot.advance()?;
        let request = Request {
            binding: self.binding.clone(),
            scope,
            nonce,
            epoch: slot.epoch,
        };
        slot.phase = Phase::Pending;
        slot.deadline = now.checked_add(Duration::from_secs(120));
        if slot.deadline.is_none() {
            return Err(Error::InvalidLifetime);
        }
        slot.last_nonce = Some(nonce);
        slot.request = Some(request.clone());
        self.audit_phase(request.scope.kind());
        Ok(request)
    }

    pub(crate) fn approve(
        &mut self,
        request: &Request,
        now: Instant,
        lifetime: Duration,
    ) -> Result<Ticket, Error> {
        if request.binding != self.binding {
            return Err(Error::Stale);
        }
        if lifetime.is_zero() || lifetime > Duration::from_secs(24 * 60 * 60) {
            return Err(Error::InvalidLifetime);
        }
        let slot = self
            .slots
            .get_mut(&request.scope.kind())
            .ok_or(Error::Unsupported)?;
        if slot.phase != Phase::Pending || slot.request.as_ref() != Some(request) {
            return Err(Error::Stale);
        }
        if !slot.enabled || !slot.supported {
            return Err(Error::Disabled);
        }
        if slot.deadline.map_or(true, |deadline| now >= deadline) {
            self.revoke(request.scope.kind())?;
            return Err(Error::Expired);
        }
        let deadline = now.checked_add(lifetime).ok_or(Error::InvalidLifetime)?;
        slot.phase = Phase::Starting;
        slot.deadline = Some(deadline);
        self.audit_phase(request.scope.kind());
        Ok(Ticket {
            request: request.clone(),
        })
    }

    fn valid_ticket(&self, ticket: &Ticket, now: Instant, phase: Phase) -> bool {
        ticket.request.binding == self.binding
            && self.authenticated
            && self
                .slots
                .get(&ticket.request.scope.kind())
                .map_or(false, |slot| {
                    slot.enabled
                        && slot.supported
                        && !slot.exhausted
                        && slot.phase == phase
                        && slot.request.as_ref() == Some(&ticket.request)
                        && slot.deadline.map_or(false, |deadline| now < deadline)
                })
    }

    pub(crate) fn may_start(&self, ticket: &Ticket, now: Instant) -> bool {
        self.valid_ticket(ticket, now, Phase::Starting)
    }

    /// A late acknowledgement is rejected; the adapter must stop its late resource.
    pub(crate) fn did_start(&mut self, ticket: &Ticket, now: Instant) -> Result<(), Error> {
        if !self.may_start(ticket, now) {
            return Err(Error::Stale);
        }
        self.slots
            .get_mut(&ticket.request.scope.kind())
            .ok_or(Error::Unsupported)?
            .phase = Phase::Running;
        self.audit_phase(ticket.request.scope.kind());
        Ok(())
    }

    pub(crate) fn may_execute(&self, ticket: &Ticket, scope: &Scope, now: Instant) -> bool {
        &ticket.request.scope == scope && self.valid_ticket(ticket, now, Phase::Running)
    }

    pub(crate) fn revoke(&mut self, kind: Kind) -> Result<Option<StopTicket>, Error> {
        let result = self.revoke_inner(kind);
        self.audit_phase(kind);
        result
    }
    fn revoke_inner(&mut self, kind: Kind) -> Result<Option<StopTicket>, Error> {
        let slot = self.slots.get_mut(&kind).ok_or(Error::Unsupported)?;
        if slot.exhausted {
            return Ok(
                matches!(slot.phase, Phase::Revoking | Phase::RecoveryRequired).then(|| {
                    StopTicket {
                        binding: self.binding.clone(),
                        kind,
                        epoch: slot.epoch,
                    }
                }),
            );
        }
        if matches!(slot.phase, Phase::Revoking | Phase::RecoveryRequired) {
            return Ok(Some(StopTicket {
                binding: self.binding.clone(),
                kind,
                epoch: slot.epoch,
            }));
        }
        let needs_stop = matches!(slot.phase, Phase::Starting | Phase::Running);
        if slot.advance().is_err() {
            // Counter exhaustion permanently denies new grants, but must not
            // discard the owned-resource teardown or abort other disconnects.
            if !needs_stop {
                slot.phase = Phase::Stopped;
            }
            return Ok(needs_stop.then(|| StopTicket {
                binding: self.binding.clone(),
                kind,
                epoch: slot.epoch,
            }));
        }
        slot.request = None;
        slot.deadline = None;
        slot.phase = if needs_stop {
            Phase::Revoking
        } else {
            Phase::Stopped
        };
        Ok(needs_stop.then(|| StopTicket {
            binding: self.binding.clone(),
            kind,
            epoch: slot.epoch,
        }))
    }

    pub(crate) fn tick(&mut self, now: Instant) -> Result<Vec<StopTicket>, Error> {
        let expired: Vec<_> = self
            .slots
            .iter()
            .filter_map(|(kind, slot)| {
                slot.deadline
                    .filter(|deadline| now >= *deadline)
                    .map(|_| *kind)
            })
            .collect();
        let mut stopped = Vec::new();
        for kind in expired {
            if let Some(ticket) = self.revoke(kind)? {
                stopped.push(ticket);
            }
        }
        Ok(stopped)
    }

    pub(crate) fn did_stop(&mut self, ticket: &StopTicket, success: bool) -> Result<(), Error> {
        if ticket.binding != self.binding {
            return Err(Error::Stale);
        }
        let slot = self.slots.get_mut(&ticket.kind).ok_or(Error::Unsupported)?;
        if ticket.epoch != slot.epoch
            || !matches!(slot.phase, Phase::Revoking | Phase::RecoveryRequired)
        {
            return Err(Error::Stale);
        }
        slot.phase = if success {
            Phase::Stopped
        } else {
            Phase::RecoveryRequired
        };
        self.audit_phase(ticket.kind);
        Ok(())
    }

    pub(crate) fn disconnect(&mut self) -> Result<Vec<StopTicket>, Error> {
        self.authenticated = false;
        let mut stopped = Vec::new();
        for kind in [Kind::Terminal, Kind::Tunnel, Kind::Camera, Kind::Voice] {
            if let Some(ticket) = self.revoke(kind)? {
                stopped.push(ticket);
            }
        }
        Ok(stopped)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn binding(nonce: u8) -> Binding {
        Binding::new("a".repeat(64), "1000000001".into(), [nonce; 16]).unwrap()
    }
    fn camera() -> Scope {
        Scope::Camera("synthetic-camera".into())
    }
    fn ready() -> Capabilities {
        let mut state = Capabilities::new(binding(1), true, true);
        state.set_policy(Kind::Camera, true, true).unwrap();
        state
    }
    fn running(state: &mut Capabilities, now: Instant, nonce: u8) -> Ticket {
        let request = state.request(camera(), [nonce; 16], now).unwrap();
        let ticket = state
            .approve(&request, now, Duration::from_secs(60))
            .unwrap();
        state.did_start(&ticket, now).unwrap();
        ticket
    }

    #[test]
    fn exhausted_epoch_still_returns_cleanup_and_never_allows_new_grants() {
        let now = Instant::now();
        let mut state = ready();
        state.slots.get_mut(&Kind::Camera).unwrap().epoch = u64::MAX - 1;
        let ticket = running(&mut state, now, 1);
        let stop = state.revoke(Kind::Camera).unwrap().unwrap();
        assert_eq!(state.phase(Kind::Camera), Phase::RecoveryRequired);
        assert!(!state.may_execute(&ticket, &camera(), now));
        assert_eq!(state.request(camera(), [2; 16], now), Err(Error::Exhausted));
        state.did_stop(&stop, true).unwrap();
        assert_eq!(state.phase(Kind::Camera), Phase::Stopped);
        assert!(state
            .set_policy(Kind::Camera, true, false)
            .unwrap()
            .is_none());
        assert_eq!(
            state.set_policy(Kind::Camera, true, true),
            Err(Error::Exhausted)
        );
    }

    #[test]
    fn exhausted_slot_does_not_abort_other_resource_disconnect_cleanup() {
        let now = Instant::now();
        let mut state = ready();
        state.slots.get_mut(&Kind::Camera).unwrap().epoch = u64::MAX - 1;
        running(&mut state, now, 1);
        state.revoke(Kind::Camera).unwrap().unwrap();
        state.set_policy(Kind::Voice, true, true).unwrap();
        let voice = Scope::Voice {
            capture: true,
            playback: true,
        };
        let request = state.request(voice.clone(), [3; 16], now).unwrap();
        let ticket = state
            .approve(&request, now, Duration::from_secs(60))
            .unwrap();
        state.did_start(&ticket, now).unwrap();
        let stops = state.disconnect().unwrap();
        assert_eq!(stops.len(), 2);
        assert!(!state.may_execute(&ticket, &voice, now));
        for stop in stops {
            state.did_stop(&stop, true).unwrap();
        }
        assert_eq!(state.phase(Kind::Voice), Phase::Stopped);
        assert_eq!(state.phase(Kind::Camera), Phase::Stopped);
    }

    #[test]
    fn all_capabilities_start_unsupported_and_disabled() {
        let mut state = Capabilities::new(binding(1), true, true);
        for scope in [
            Scope::Terminal(NormalUser::Unix(501)),
            Scope::Tunnel("127.0.0.1:3000".parse().unwrap()),
            camera(),
            Scope::Voice {
                capture: true,
                playback: true,
            },
        ] {
            assert_eq!(state.phase(scope.kind()), Phase::Stopped);
            assert_eq!(
                state.request(scope, [1; 16], Instant::now()),
                Err(Error::Unsupported)
            );
        }
    }

    #[test]
    fn authentication_and_local_enable_are_both_required() {
        for (secured, authenticated) in [(false, true), (true, false), (false, false)] {
            let mut state = Capabilities::new(binding(1), secured, authenticated);
            state.set_policy(Kind::Camera, true, true).unwrap();
            assert_eq!(
                state.request(camera(), [1; 16], Instant::now()),
                Err(Error::NotAuthenticated)
            );
        }
        let mut state = ready();
        state.set_policy(Kind::Camera, true, false).unwrap();
        assert_eq!(
            state.request(camera(), [1; 16], Instant::now()),
            Err(Error::Disabled)
        );
    }

    #[test]
    fn resource_start_confirmation_precedes_execution() {
        let now = Instant::now();
        let mut state = ready();
        let request = state.request(camera(), [1; 16], now).unwrap();
        let ticket = state
            .approve(&request, now, Duration::from_secs(60))
            .unwrap();
        assert!(state.may_start(&ticket, now));
        assert!(!state.may_execute(&ticket, &camera(), now));
        state.did_start(&ticket, now).unwrap();
        assert!(state.may_execute(&ticket, &camera(), now));
    }

    #[test]
    fn late_start_must_be_disposed_after_revoke() {
        let now = Instant::now();
        let mut state = ready();
        let request = state.request(camera(), [1; 16], now).unwrap();
        let ticket = state
            .approve(&request, now, Duration::from_secs(60))
            .unwrap();
        let stop = state.revoke(Kind::Camera).unwrap().unwrap();
        assert!(!state.may_start(&ticket, now));
        assert_eq!(state.did_start(&ticket, now), Err(Error::Stale));
        assert_eq!(state.request(camera(), [2; 16], now), Err(Error::Busy));
        state.did_stop(&stop, true).unwrap();
        assert!(state.request(camera(), [2; 16], now).is_ok());
    }

    #[test]
    fn revoke_and_regrant_never_restore_an_old_ticket() {
        let now = Instant::now();
        let mut state = ready();
        let old = running(&mut state, now, 1);
        let stop = state.revoke(Kind::Camera).unwrap().unwrap();
        state.did_stop(&stop, true).unwrap();
        let current = running(&mut state, now, 2);
        assert!(!state.may_execute(&old, &camera(), now));
        assert!(state.may_execute(&current, &camera(), now));
        assert_eq!(state.did_stop(&stop, true), Err(Error::Stale));
        assert_eq!(state.phase(Kind::Camera), Phase::Running);
    }

    #[test]
    fn expired_grants_require_actual_stop_acknowledgement() {
        let now = Instant::now();
        let mut state = ready();
        let ticket = running(&mut state, now, 1);
        let later = now + Duration::from_secs(60);
        assert!(!state.may_execute(&ticket, &camera(), later));
        let stops = state.tick(later).unwrap();
        assert_eq!(stops.len(), 1);
        assert_eq!(state.phase(Kind::Camera), Phase::Revoking);
        state.did_stop(&stops[0], false).unwrap();
        assert_eq!(state.phase(Kind::Camera), Phase::RecoveryRequired);
        assert_eq!(state.request(camera(), [2; 16], later), Err(Error::Busy));
        state.did_stop(&stops[0], true).unwrap();
        assert_eq!(state.phase(Kind::Camera), Phase::Stopped);
    }

    #[test]
    fn ordinary_or_stale_local_approval_cannot_approve_another_scope() {
        let now = Instant::now();
        let mut state = ready();
        let old = state.request(camera(), [1; 16], now).unwrap();
        let request = state
            .request(Scope::Camera("other-camera".into()), [2; 16], now)
            .unwrap();
        assert_eq!(
            state.approve(&old, now, Duration::from_secs(30)),
            Err(Error::Stale)
        );
        let ticket = state
            .approve(&request, now, Duration::from_secs(30))
            .unwrap();
        state.did_start(&ticket, now).unwrap();
        assert!(!state.may_execute(&ticket, &camera(), now));
    }

    #[test]
    fn reconnect_and_other_server_connections_cannot_inherit_grants() {
        let now = Instant::now();
        let mut state = ready();
        let old = running(&mut state, now, 1);
        let mut reconnected = Capabilities::new(binding(2), true, true);
        reconnected.set_policy(Kind::Camera, true, true).unwrap();
        assert!(!reconnected.may_execute(&old, &camera(), now));
        let mut other = ready();
        other.binding.namespace = "b".repeat(64);
        assert_eq!(other.did_start(&old, now), Err(Error::Stale));
    }

    #[test]
    fn disabling_local_policy_revokes_running_resource() {
        let now = Instant::now();
        let mut state = ready();
        let ticket = running(&mut state, now, 1);
        let stop = state
            .set_policy(Kind::Camera, true, false)
            .unwrap()
            .unwrap();
        assert!(!state.may_execute(&ticket, &camera(), now));
        assert_eq!(state.revoke(Kind::Camera).unwrap(), Some(stop.clone()));
        state.did_stop(&stop, true).unwrap();
        assert_eq!(state.request(camera(), [2; 16], now), Err(Error::Disabled));
    }

    #[test]
    fn disconnect_revokes_all_running_capabilities() {
        let now = Instant::now();
        let mut state = ready();
        let camera_ticket = running(&mut state, now, 1);
        state.set_policy(Kind::Voice, true, true).unwrap();
        let voice = Scope::Voice {
            capture: true,
            playback: true,
        };
        let request = state.request(voice, [2; 16], now).unwrap();
        let voice_ticket = state
            .approve(&request, now, Duration::from_secs(60))
            .unwrap();
        state.did_start(&voice_ticket, now).unwrap();
        assert_eq!(state.disconnect().unwrap().len(), 2);
        assert!(!state.may_execute(&camera_ticket, &camera(), now));
        assert_eq!(
            state.request(camera(), [3; 16], now),
            Err(Error::NotAuthenticated)
        );
    }

    #[test]
    fn root_system_and_elevated_terminal_targets_are_rejected() {
        let now = Instant::now();
        let mut state = ready();
        state.set_policy(Kind::Terminal, true, true).unwrap();
        for user in [
            NormalUser::Unix(0),
            NormalUser::Windows {
                sid: "S-1-5-18".into(),
                interactive: true,
                elevated: false,
            },
            NormalUser::Windows {
                sid: "S-1-5-21-100".into(),
                interactive: true,
                elevated: true,
            },
            NormalUser::Windows {
                sid: "S-1-5-21-100".into(),
                interactive: false,
                elevated: false,
            },
        ] {
            assert_eq!(
                state.request(Scope::Terminal(user), [1; 16], now),
                Err(Error::InvalidScope)
            );
        }
        assert!(state
            .request(Scope::Terminal(NormalUser::Unix(501)), [2; 16], now)
            .is_ok());
    }

    #[test]
    fn pending_grant_expiry_and_zero_lifetimes_cannot_enable_resources() {
        let now = Instant::now();
        let mut state = ready();
        let request = state.request(camera(), [1; 16], now).unwrap();
        assert_eq!(
            state.approve(&request, now, Duration::ZERO),
            Err(Error::InvalidLifetime)
        );
        assert_eq!(
            state.approve(
                &request,
                now + Duration::from_secs(120),
                Duration::from_secs(1)
            ),
            Err(Error::Expired)
        );
        assert_eq!(state.phase(Kind::Camera), Phase::Stopped);
        assert_eq!(
            state.request(camera(), [1; 16], now),
            Err(Error::InvalidNonce)
        );
    }

    #[test]
    fn invalid_bindings_and_resource_targets_are_rejected() {
        assert_eq!(
            Binding::new("A".repeat(64), "1000000001".into(), [1; 16]),
            Err(Error::InvalidBinding)
        );
        assert_eq!(
            Binding::new("a".repeat(64), "invalid".into(), [1; 16]),
            Err(Error::InvalidBinding)
        );
        assert_eq!(
            Binding::new("a".repeat(64), "1000000001".into(), [0; 16]),
            Err(Error::InvalidBinding)
        );
        for scope in [
            Scope::Tunnel("0.0.0.0:80".parse().unwrap()),
            Scope::Tunnel("127.0.0.1:0".parse().unwrap()),
            Scope::Camera("\n".into()),
            Scope::Voice {
                capture: false,
                playback: false,
            },
        ] {
            assert!(!scope.valid());
        }
    }

    #[test]
    fn voice_device_scope_rejects_malformed_fingerprints_and_requires_policy() {
        let now = Instant::now();
        let mut state = ready();
        let scope = Scope::VoiceDevices { fingerprint: "a".repeat(64) };
        assert_eq!(state.request(scope.clone(), [4; 16], now), Err(Error::Unsupported));
        state.set_policy(Kind::Voice, true, false).unwrap();
        assert_eq!(state.request(scope, [4; 16], now), Err(Error::Disabled));
        state.set_policy(Kind::Voice, true, true).unwrap();
        for fingerprint in ["".into(), "a".repeat(63), "A".repeat(64), "g".repeat(64)] {
            assert_eq!(
                state.request(Scope::VoiceDevices { fingerprint }, [5; 16], now),
                Err(Error::InvalidScope)
            );
        }
    }

    #[test]
    fn voice_device_grant_cannot_cover_other_devices_or_survive_regrant() {
        let now = Instant::now();
        let mut state = ready();
        state.set_policy(Kind::Voice, true, true).unwrap();
        let first = Scope::VoiceDevices { fingerprint: "a".repeat(64) };
        let second = Scope::VoiceDevices { fingerprint: "b".repeat(64) };
        let request = state.request(first.clone(), [6; 16], now).unwrap();
        let old = state.approve(&request, now, Duration::from_secs(60)).unwrap();
        state.did_start(&old, now).unwrap();
        assert!(state.may_execute(&old, &first, now));
        assert!(!state.may_execute(&old, &second, now));
        assert!(!state.may_execute(&old, &Scope::Voice { capture: true, playback: true }, now));
        let stop = state.revoke(Kind::Voice).unwrap().unwrap();
        state.did_stop(&stop, true).unwrap();
        let request = state.request(second.clone(), [7; 16], now).unwrap();
        let current = state.approve(&request, now, Duration::from_secs(60)).unwrap();
        state.did_start(&current, now).unwrap();
        assert!(!state.may_execute(&old, &first, now));
        assert!(state.may_execute(&current, &second, now));
        assert_eq!(state.did_stop(&stop, true), Err(Error::Stale));
        assert_eq!(state.phase(Kind::Voice), Phase::Running);
    }

    #[test]
    fn epoch_exhaustion_is_permanent_and_fails_closed() {
        let mut state = ready();
        state.slots.get_mut(&Kind::Camera).unwrap().epoch = u64::MAX;
        assert_eq!(
            state.request(camera(), [1; 16], Instant::now()),
            Err(Error::Exhausted)
        );
        assert_eq!(
            state.set_policy(Kind::Camera, true, true),
            Err(Error::Exhausted)
        );
        assert_eq!(state.phase(Kind::Camera), Phase::RecoveryRequired);
    }
}
