//! One actual secured connection's call negotiation and native cleanup owner.
use super::{
    voice::{Binding, EncodedPacket},
    voice_flow::{Catalog, Command, Identity, Phase, Reply, Status, Wire},
    voice_runtime::{AuthFacts, Flow},
    voice_wire::{self, WireError},
};
use base::message_proto::{message, misc, Features, Message, Misc, VoiceCallRequest};
use hbb_common::rand::{rngs::OsRng, RngCore};
use std::{
    collections::VecDeque,
    sync::{atomic::{AtomicI32, AtomicU64, Ordering}, Arc},
    time::{Duration, Instant},
};

static LOCAL_CONNECTION: AtomicI32 = AtomicI32::new(1);
static CALL_EPOCH: AtomicU64 = AtomicU64::new(1);

pub(crate) fn connection_id() -> Result<i32, &'static str> {
    LOCAL_CONNECTION.fetch_update(Ordering::AcqRel, Ordering::Acquire,
        |value| value.checked_add(1)).map_err(|_| "worker_failed")
}

pub(crate) fn nonce() -> Result<String, &'static str> {
    let mut bytes = [0u8; 16];
    OsRng.try_fill_bytes(&mut bytes).map_err(|_| "worker_failed")?;
    if bytes == [0; 16] { return Err("worker_failed"); }
    Ok(bytes.iter().map(|byte| format!("{byte:02x}")).collect())
}

pub(crate) fn binding(wire: &Wire) -> Result<Binding, &'static str> {
    if !wire.valid() { return Err("invalid_command"); }
    let mut bytes = [0u8; 16];
    for (index, byte) in bytes.iter_mut().enumerate() {
        *byte = u8::from_str_radix(&wire.call_nonce[index * 2..index * 2 + 2], 16)
            .map_err(|_| "invalid_command")?;
    }
    let epoch = wire.call_epoch.parse::<u64>().map_err(|_| "invalid_command")?;
    if epoch > i64::MAX as u64 { return Err("invalid_command"); }
    Binding::new(bytes, epoch).map_err(|_| "invalid_command")
}

pub(crate) fn wire(binding: Binding) -> Wire {
    Wire { call_nonce: binding.nonce().iter().map(|byte| format!("{byte:02x}")).collect(),
        call_epoch: binding.epoch().to_string() }
}

pub(crate) fn new_wire() -> Result<Wire, &'static str> {
    new_wire_after(0)
}
pub(crate) fn new_wire_after(previous: u64) -> Result<Wire, &'static str> {
    if previous >= i64::MAX as u64 { return Err("worker_failed"); }
    let minimum=previous.checked_add(1).ok_or("worker_failed")?;
    CALL_EPOCH.fetch_max(minimum,Ordering::AcqRel);
    let epoch = CALL_EPOCH.fetch_update(Ordering::AcqRel, Ordering::Acquire,
        |value| value.checked_add(1).filter(|next| *next <= i64::MAX as u64))
        .map_err(|_| "worker_failed")?;
    Ok(Wire { call_nonce: nonce()?, call_epoch: epoch.to_string() })
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Role { Initiator, Receiver }

struct Negotiation {
    peer: Features,
    binding: Binding,
    request: VoiceCallRequest,
    role: Role,
    request_sent: bool,
    response_sent: bool,
    peer_accepted: bool,
    format_sent: bool,
    format_received: bool,
    close_sent: bool,
    cancelled: bool,
    waiting_since: Option<Instant>,
}
impl Negotiation {
    fn outgoing(peer: Features, binding: Binding, timestamp: i64) -> Result<Self, WireError> {
        let request = voice_wire::request(&peer, binding, timestamp, true)?;
        Ok(Self::new(peer, binding, request, Role::Initiator))
    }
    fn incoming(peer: Features, binding: Binding, request: VoiceCallRequest) -> Result<Self, WireError> {
        if !request.is_connect || voice_wire::request_binding(&peer, &request)? != binding {
            return Err(WireError::InvalidRequest);
        }
        Ok(Self::new(peer, binding, request, Role::Receiver))
    }
    fn new(peer: Features, binding: Binding, request: VoiceCallRequest, role: Role) -> Self {
        Self { peer, binding, request, role, request_sent: false, response_sent: false,
            peer_accepted: false, format_sent: false, format_received: false, close_sent: false, cancelled:false,
            waiting_since: (role == Role::Receiver).then(Instant::now) }
    }
    fn poll(&mut self, local_ready: bool, stopping: bool) -> Result<Vec<Message>, WireError> {
        let mut output = Vec::with_capacity(2);
        if stopping || self.cancelled {
            if !self.close_sent {
                let mut message = Message::new();
                if self.role == Role::Receiver && !self.response_sent {
                    message.set_voice_call_response(voice_wire::response(&self.peer, self.binding,
                        &self.request, false, hbb_common::get_time())?);
                } else if self.request_sent || self.response_sent {
                    message.set_voice_call_request(voice_wire::request(&self.peer, self.binding,
                        self.request.req_timestamp, false)?);
                }
                self.close_sent = true;
                if message.union.is_some() { output.push(message); }
            }
            return Ok(output);
        }
        if !local_ready { return Ok(output); }
        match self.role {
            Role::Initiator if !self.request_sent => {
                let mut message = Message::new();
                message.set_voice_call_request(self.request.clone());
                output.push(message);
                self.request_sent = true;
                self.waiting_since = Some(Instant::now());
            }
            Role::Receiver if !self.response_sent => {
                let mut message = Message::new();
                message.set_voice_call_response(voice_wire::response(&self.peer, self.binding,
                    &self.request, true, hbb_common::get_time())?);
                output.push(message);
                self.response_sent = true;
                self.peer_accepted = true;
            }
            _ => {}
        }
        if !self.format_sent && self.peer_accepted {
            let mut misc = Misc::new();
            misc.set_audio_format(voice_wire::audio_format(&self.peer, self.binding)?);
            let mut message = Message::new();
            message.set_misc(misc);
            output.push(message);
            self.format_sent = true;
        }
        Ok(output)
    }
    fn incoming_message(&mut self, message: &Message) -> Result<Incoming, WireError> {
        match message.union.as_ref() {
            Some(message::Union::VoiceCallRequest(request)) => {
                if voice_wire::request_binding(&self.peer, request)? != self.binding {
                    return Err(WireError::StaleBinding);
                }
                if !request.is_connect && request.req_timestamp == self.request.req_timestamp {
                    Ok(Incoming::Close)
                } else { Err(WireError::InvalidRequest) }
            }
            Some(message::Union::VoiceCallResponse(response)) => {
                if self.role != Role::Initiator || !self.request_sent {
                    return Err(WireError::InvalidRequest);
                }
                let accepted = voice_wire::validate_response(&self.peer, self.binding,
                    self.request.req_timestamp, response)?;
                if !accepted { return Ok(Incoming::Close); }
                self.peer_accepted = true;
                Ok(Incoming::Metadata)
            }
            Some(message::Union::Misc(misc)) => match misc.union.as_ref() {
                Some(misc::Union::AudioFormat(format)) => {
                    voice_wire::validate_format(&self.peer, self.binding, format)?;
                    self.format_received = true;
                    Ok(Incoming::Metadata)
                }
                _ => Err(WireError::InvalidFormat),
            },
            Some(message::Union::AudioFrame(frame)) => {
                if !self.ready() { return Err(WireError::InvalidRequest); }
                Ok(Incoming::Packet(voice_wire::decode_frame(&self.peer, self.binding, frame)?))
            }
            _ => Err(WireError::InvalidRequest),
        }
    }
    fn ready(&self) -> bool {
        self.peer_accepted && self.format_sent && self.format_received && !self.close_sent && !self.cancelled
    }
    fn expired(&self) -> bool {
        !self.ready() && self.waiting_since.is_some_and(|start| start.elapsed() >= Duration::from_secs(120))
    }
}
enum Incoming { Metadata, Close, Packet(EncodedPacket) }

pub(crate) enum Event {
    Status(Status),
    Catalog(Catalog),
}
pub(crate) type Observer = Arc<dyn Fn(Event) + Send + Sync>;

pub(crate) struct Call {
    flow: Flow,
    negotiation: Negotiation,
    observer: Observer,
    accepted_queued: bool,
    stopped_published: bool,
    failed_published: bool,
}
impl Call {
    pub(crate) fn outgoing(identity: Identity, wire: Wire, peer: Features,
        facts: AuthFacts, observer: Observer) -> Result<Self, &'static str> {
        let negotiation = Negotiation::outgoing(peer, binding(&wire)?, hbb_common::get_time())
            .map_err(|_| "peer_policy_disabled")?;
        Self::start(identity, wire, facts, observer, negotiation)
    }
    pub(crate) fn incoming(identity: Identity, binding: Binding, peer: Features,
        request: VoiceCallRequest, facts: AuthFacts, observer: Observer) -> Result<Self, &'static str> {
        if binding.epoch() > i64::MAX as u64 { return Err("invalid_command"); }
        let negotiation = Negotiation::incoming(peer, binding, request).map_err(|_| "invalid_command")?;
        Self::start(identity, wire(binding), facts, observer, negotiation)
    }
    fn start(identity: Identity, wire: Wire, facts: AuthFacts, observer: Observer,
        negotiation: Negotiation) -> Result<Self, &'static str> {
        let report = observer.clone();
        let status_observer = Arc::new(move |status: Status| {
            // The actual actor/watchdog join is checked by poll, after this
            // worker callback returns. Its last status alone is not that ACK.
            if status.phase != Phase::Stopped { report(Event::Status(status)); }
        });
        #[cfg(any(target_os="macos",target_os="windows",target_os="android"))]
        let flow = Flow::authenticated(identity, wire, facts, status_observer)?;
        #[cfg(not(any(target_os="macos",target_os="windows",target_os="android")))]
        { let _=(identity,wire,facts,status_observer,negotiation,observer); return Err("unsupported"); }
        #[cfg(any(target_os="macos",target_os="windows",target_os="android"))]
        {
            let initial=flow.status();
            if initial.phase!=Phase::Stopped {(observer)(Event::Status(initial));}
            Ok(Self { flow, negotiation, observer, accepted_queued:false, stopped_published:false, failed_published:false })
        }
    }
    pub(crate) fn status(&self) -> Status { self.flow.status() }
    pub(crate) fn peer_requests_policy(&mut self, allowed:bool) {
        self.negotiation.peer.nikodesk_voice_requests_allowed=allowed;
    }
    pub(crate) fn command(&mut self, command: Command) -> Result<Reply, &'static str> {
        let closes=matches!(command.op,super::voice_flow::Operation::Deny|super::voice_flow::Operation::Revoke|super::voice_flow::Operation::RetryCleanup);
        let result=self.flow.command(command);
        if closes && (result.is_ok() || matches!(result,Err("busy"|"worker_failed"))) {self.negotiation.cancelled=true;}
        result
    }
    pub(crate) fn cancel(&mut self) { self.negotiation.cancelled=true;self.flow.cancel(); }
    pub(crate) fn retire(&mut self) {
        self.negotiation.cancelled=true;
        // The actual parent's verified channel is already marked retiring by
        // the caller. Publish even when the actor died and cannot do so itself.
        if self.flow.retire() { (self.observer)(Event::Status(self.flow.status())); }
    }
    /// A queued packet is not an execution grant. Both network dispatchers call
    /// this immediately before each send, after any preceding send has awaited.
    /// No state lock or gate guard survives the return into network I/O.
    pub(crate) fn next_send(&mut self, pending: &mut VecDeque<Message>) -> Option<Message> {
        let message = pending.pop_front()?;
        if self.may_send_message(&message) { return Some(message); }
        self.cancel();
        pending.clear();
        // Rejection/cancellation can close only this original wire owner. Never
        // retry the blocked handshake or the remaining media batch.
        let close = self.negotiation.poll(false, true).ok()?.pop()?;
        self.may_send_message(&close).then_some(close)
    }
    fn may_send_message(&self, message: &Message) -> bool {
        let negotiation = &self.negotiation;
        let wire = wire(negotiation.binding);
        match message.union.as_ref() {
            Some(message::Union::VoiceCallRequest(request)) => {
                if voice_wire::request_binding(&negotiation.peer, request).ok() != Some(negotiation.binding)
                    || request.req_timestamp != negotiation.request.req_timestamp { return false; }
                if !request.is_connect { return negotiation.request_sent || negotiation.response_sent; }
                negotiation.role == Role::Initiator && negotiation.request_sent
                    && negotiation.peer.nikodesk_voice_requests_allowed
                    && !negotiation.cancelled && !negotiation.close_sent
                    && self.flow.may_negotiate(&wire)
            }
            Some(message::Union::VoiceCallResponse(response)) => {
                if negotiation.role != Role::Receiver
                    || voice_wire::validate_response(&negotiation.peer, negotiation.binding,
                        negotiation.request.req_timestamp, response).is_err() { return false; }
                !response.accepted || (negotiation.response_sent && !negotiation.cancelled
                    && !negotiation.close_sent && self.flow.may_negotiate(&wire))
            }
            Some(message::Union::Misc(misc)) => match misc.union.as_ref() {
                Some(misc::Union::AudioFormat(format)) => negotiation.format_sent
                    && !negotiation.cancelled && !negotiation.close_sent
                    && voice_wire::validate_format(&negotiation.peer, negotiation.binding, format).is_ok()
                    && self.flow.may_negotiate(&wire),
                _ => false,
            },
            Some(message::Union::AudioFrame(frame)) => negotiation.ready()
                && !frame.data.is_empty() && frame.data.len() <= super::voice::MAX_OPUS_BYTES
                && frame.nikodesk_voice.as_ref().is_some_and(|tag|
                    tag.call_epoch == negotiation.binding.epoch()
                        && tag.call_nonce.as_ref() == negotiation.binding.nonce().as_slice())
                && self.flow.may_send(&wire),
            _ => false,
        }
    }
    pub(crate) fn finished(&mut self) -> Result<bool, &'static str> {
        let result=self.flow.finished();
        if matches!(result,Ok(true)) && !self.stopped_published {
            (self.observer)(Event::Status(self.flow.status()));
            self.stopped_published=true;
        } else if result.is_err() && !self.failed_published {
            let status=self.flow.status();
            if status.phase==Phase::RecoveryRequired {
                (self.observer)(Event::Status(status));
                self.failed_published=true;
            }
        }
        result
    }
    pub(crate) fn incoming_message(&mut self, message: &Message) {
        match self.negotiation.incoming_message(message) {
            Ok(Incoming::Close) => self.cancel(),
            Ok(Incoming::Packet(packet)) => { let _=self.flow.incoming(packet); }
            Ok(Incoming::Metadata) => {},
            // Late, malformed or unbound input cannot revoke another call.
            Err(_) => {},
        }
    }
    pub(crate) fn poll(&mut self) -> Result<Vec<Message>, &'static str> {
        let status = self.flow.status();
        if let Some(catalog) = self.flow.take_catalog() { (self.observer)(Event::Catalog(catalog)); }
        if self.negotiation.expired() { self.cancel(); }
        let stopping = matches!(status.phase, Phase::Revoking|Phase::RecoveryRequired|Phase::Stopped);
        let mut output = self.negotiation.poll(status.local_ready, stopping).map_err(|_| "invalid_command")?;
        if !stopping && status.phase==Phase::Running && status.local_ready && self.negotiation.ready() && !self.accepted_queued {
            match self.flow.peer_accepted(&status.wire) {
                Ok(())=>self.accepted_queued=true,
                Err("busy")=>{},
                Err(_)=>self.cancel(),
            }
        }
        if self.negotiation.ready() && self.flow.may_send(&status.wire) {
            for _ in 0..super::voice::QUEUE_FRAMES {
                let packet = self.flow.take_outgoing().map_err(|_| "cancelled")?;
                let Some(packet) = packet else { break; };
                let mut message=Message::new();
                message.set_audio_frame(voice_wire::audio_frame(&self.negotiation.peer,
                    self.negotiation.binding,&packet).map_err(|_| "invalid_command")?);
                output.push(message);
            }
        }
        self.finished()?;
        Ok(output)
    }
}
#[cfg(test)]
pub(crate) fn cleanup_test_call(done: std::sync::mpsc::Receiver<()>) -> Call {
    let flow = super::voice_runtime::cleanup_test_flow(done);
    let status = flow.status();
    let peer = Features { nikodesk_voice_v1: true, nikodesk_voice_requests_allowed: true, ..Default::default() };
    let negotiation = Negotiation::outgoing(peer, binding(&status.wire).unwrap(), 19).unwrap();
    Call { flow, negotiation, observer: Arc::new(|_| {}), accepted_queued: false,
        stopped_published: false, failed_published: false }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn reverse_calls_continue_after_the_previous_peers_counter() {
        let wire=new_wire_after(1_000_000).unwrap();
        assert!(wire.call_epoch.parse::<u64>().unwrap()>1_000_000);
        assert!(binding(&wire).is_ok());
        assert!(new_wire_after(i64::MAX as u64).is_err());
    }
    #[test]
    fn policy_revoked_after_queueing_prevents_the_actual_initial_request() {
        let mut call=send_call(Role::Initiator,true,false,false);
        let mut pending=call.negotiation.poll(true,false).unwrap().into();
        call.peer_requests_policy(false);
        let message=call.next_send(&mut pending).unwrap();
        assert!(!message.voice_call_request().is_connect);
        assert!(call.next_send(&mut pending).is_none());
    }
    fn peer() -> Features { Features { nikodesk_voice_v1:true, nikodesk_voice_requests_allowed:true, ..Default::default() } }
    fn media_binding() -> Binding { Binding::new([9;16],7).unwrap() }
    fn send_call(role: Role, ready: bool, accepted: bool, expired: bool) -> Call {
        let flow = super::super::voice_runtime::send_test_flow(ready, accepted, expired);
        let binding = binding(&flow.status().wire).unwrap();
        let negotiation = match role {
            Role::Initiator => Negotiation::outgoing(peer(), binding, 19).unwrap(),
            Role::Receiver => Negotiation::incoming(peer(), binding,
                voice_wire::request(&peer(), binding, 19, true).unwrap()).unwrap(),
        };
        Call { flow, negotiation, observer: Arc::new(|_| {}), accepted_queued: false,
            stopped_published: false, failed_published: false }
    }
    fn media_message(call: &Call) -> Message {
        let packet = EncodedPacket::new(call.negotiation.binding, vec![1, 2, 3]).unwrap();
        let mut message = Message::new();
        message.set_audio_frame(voice_wire::audio_frame(&peer(), call.negotiation.binding, &packet).unwrap());
        message
    }
    fn media_call() -> Call {
        let mut call = send_call(Role::Initiator, true, true, false);
        call.negotiation.request_sent = true;
        call.negotiation.peer_accepted = true;
        call.negotiation.format_sent = true;
        call.negotiation.format_received = true;
        call
    }
    #[test]
    fn actual_send_gate_requires_local_ready_but_not_peer_acceptance_for_initial_handshake() {
        let mut pending = send_call(Role::Initiator, false, false, false);
        let mut batch = pending.negotiation.poll(true, false).unwrap().into();
        let closed = pending.next_send(&mut batch).unwrap();
        assert!(!closed.voice_call_request().is_connect);
        assert!(pending.next_send(&mut batch).is_none());
        let mut caller = send_call(Role::Initiator, true, false, false);
        let mut batch = caller.negotiation.poll(true, false).unwrap().into();
        assert!(caller.next_send(&mut batch).unwrap().voice_call_request().is_connect);
        assert!(!caller.flow.may_send(&caller.status().wire));
        let mut receiver = send_call(Role::Receiver, true, false, false);
        let mut batch = receiver.negotiation.poll(true, false).unwrap().into();
        assert!(receiver.next_send(&mut batch).unwrap().voice_call_response().accepted);
        assert!(matches!(receiver.next_send(&mut batch).unwrap().misc().union,
            Some(misc::Union::AudioFormat(_))));
        assert!(!receiver.flow.may_send(&receiver.status().wire));
    }
    #[test]
    fn actual_batch_gate_discards_remaining_media_after_cancel_between_sends() {
        let mut call = media_call();
        let mut batch = VecDeque::from([media_message(&call), media_message(&call), media_message(&call)]);
        assert!(matches!(call.next_send(&mut batch).unwrap().union, Some(message::Union::AudioFrame(_))));
        // The first actual send may already be in flight. Its await completed,
        // then cancellation happened before executing the next batch packet.
        call.flow.cancel();
        let close = call.next_send(&mut batch).unwrap();
        assert!(!close.voice_call_request().is_connect);
        assert!(batch.is_empty());
        assert!(call.next_send(&mut batch).is_none());
    }
    #[test]
    fn cancelled_receiver_cannot_send_remaining_format_but_can_close_same_owner() {
        let mut call = send_call(Role::Receiver, true, false, false);
        let mut batch = call.negotiation.poll(true, false).unwrap().into();
        assert!(call.next_send(&mut batch).unwrap().voice_call_response().accepted);
        call.cancel();
        let close = call.next_send(&mut batch).unwrap();
        assert!(!close.voice_call_request().is_connect);
        assert!(call.next_send(&mut batch).is_none());
    }
    #[test]
    fn stale_policy_deadline_blocks_handshake_and_media_but_not_refusal_or_close() {
        let mut caller = send_call(Role::Initiator, true, true, true);
        let mut batch = caller.negotiation.poll(true, false).unwrap().into();
        assert!(!caller.next_send(&mut batch).unwrap().voice_call_request().is_connect);
        assert!(!caller.may_send_message(&media_message(&caller)));
        let mut receiver = send_call(Role::Receiver, false, false, true);
        receiver.retire();
        let refusal = receiver.negotiation.poll(false, true).unwrap().remove(0);
        assert!(!refusal.voice_call_response().accepted);
        assert!(receiver.may_send_message(&refusal));
    }
    #[test]
    fn mismatched_wire_or_timestamp_cannot_send_even_as_cleanup() {
        let mut call = media_call();
        let mut wrong_media = media_message(&call);
        wrong_media.mut_audio_frame().nikodesk_voice.as_mut().unwrap().call_epoch += 1;
        assert!(!call.may_send_message(&wrong_media));
        let mut wrong_close = Message::new();
        wrong_close.set_voice_call_request(voice_wire::request(&peer(),
            Binding::new([8;16], 9).unwrap(), 19, false).unwrap());
        assert!(!call.may_send_message(&wrong_close));
        wrong_close.set_voice_call_request(voice_wire::request(&peer(), call.negotiation.binding, 20, false).unwrap());
        assert!(!call.may_send_message(&wrong_close));
        let mut batch = VecDeque::from([wrong_media, media_message(&call)]);
        let close = call.next_send(&mut batch).unwrap();
        assert!(!close.voice_call_request().is_connect);
        assert_eq!(voice_wire::request_binding(&peer(), close.voice_call_request()).unwrap(), call.negotiation.binding);
        assert!(batch.is_empty());
    }
    #[test]
    fn active_join_failure_is_visible_then_parent_retirement_publishes_new_cleanup_identity_snapshot() {
        let mut call = send_call(Role::Initiator, false, false, false);
        call.flow = super::super::voice_runtime::join_failure_test_flow();
        let publications = Arc::new(std::sync::Mutex::new(Vec::new()));
        let observed = publications.clone();
        call.observer = Arc::new(move |event| {
            if let Event::Status(status) = event { observed.lock().unwrap().push(status); }
        });
        let original = call.status();
        assert_eq!(call.finished(), Err("worker_failed"));
        let active = call.status();
        assert_eq!(active.phase, Phase::RecoveryRequired);
        assert!(!active.cleanup_only);
        assert_eq!(publications.lock().unwrap().as_slice(), &[active.clone()]);
        call.retire();
        let retired = call.status();
        assert_eq!(retired.phase, Phase::RecoveryRequired);
        assert!(retired.cleanup_only);
        assert_eq!(retired.identity, original.identity);
        assert_eq!(retired.wire, original.wire);
        assert!(retired.revision.parse::<u64>().unwrap() > active.revision.parse::<u64>().unwrap());
        assert_eq!(publications.lock().unwrap().as_slice(), &[active, retired.clone()]);
        call.retire();
        assert_eq!(call.finished(), Err("worker_failed"));
        assert_eq!(call.status(), retired);
        assert_eq!(publications.lock().unwrap().len(), 2);
    }
    #[test]
    fn both_real_handshakes_and_tagged_formats_are_required_before_media() {
        let peer=peer();
        let binding=media_binding();
        let mut caller=Negotiation::outgoing(peer.clone(),binding,19).unwrap();
        assert!(caller.poll(false,false).unwrap().is_empty());
        let request=caller.poll(true,false).unwrap().remove(0).voice_call_request().clone();
        let mut receiver=Negotiation::incoming(peer,binding,request).unwrap();
        assert!(receiver.poll(false,false).unwrap().is_empty());
        assert!(!caller.ready() && !receiver.ready());
        let reply=receiver.poll(true,false).unwrap();
        assert_eq!(reply.len(),2);
        caller.incoming_message(&reply[0]).unwrap();
        assert!(!caller.ready());
        caller.incoming_message(&reply[1]).unwrap();
        assert!(!caller.ready());
        let format=caller.poll(true,false).unwrap();
        assert_eq!(format.len(),1);
        assert!(caller.ready());
        receiver.incoming_message(&format[0]).unwrap();
        assert!(receiver.ready());
    }
    #[test]
    fn a_refused_call_has_no_format_and_cannot_become_ready() {
        let peer=peer();
        let binding=media_binding();
        let mut caller=Negotiation::outgoing(peer.clone(),binding,19).unwrap();
        let request=caller.poll(true,false).unwrap().remove(0).voice_call_request().clone();
        let mut receiver=Negotiation::incoming(peer,binding,request).unwrap();
        let refusal=receiver.poll(false,true).unwrap();
        assert_eq!(refusal.len(),1);
        assert!(matches!(caller.incoming_message(&refusal[0]),Ok(Incoming::Close)));
        assert!(!caller.ready() && !receiver.ready());
        assert!(receiver.poll(false,true).unwrap().is_empty());
    }
    #[test]
    fn old_call_stop_and_system_audio_are_never_a_current_call_handshake() {
        let peer=peer();
        let binding=media_binding();
        let mut caller=Negotiation::outgoing(peer.clone(),binding,19).unwrap();
        caller.poll(true,false).unwrap();
        let mut old=Message::new();
        old.set_voice_call_request(voice_wire::request(&peer,Binding::new([8;16],6).unwrap(),19,false).unwrap());
        assert!(matches!(caller.incoming_message(&old),Err(WireError::StaleBinding)));
        let mut misc=Misc::new();
        misc.set_audio_format(base::message_proto::AudioFormat{sample_rate:48000,channels:1,..Default::default()});
        old.set_misc(misc);
        assert!(matches!(caller.incoming_message(&old),Err(WireError::InvalidBinding)));
        assert!(!caller.ready());
    }
    #[test]
    fn native_wire_is_bounded_to_android_long_and_exact_nonce() {
        assert_eq!(binding(&wire(media_binding())).unwrap(),media_binding());
        let invalid=Wire { call_nonce:"9".repeat(32),call_epoch:((i64::MAX as u64)+1).to_string() };
        assert_eq!(binding(&invalid),Err("invalid_command"));
    }
}
