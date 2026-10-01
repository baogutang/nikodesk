//! Optional voice metadata on the existing encrypted transport. A binding is
//! never a capability ticket: callers must verify the connection's live grant.
use super::voice::{Binding, EncodedPacket, MAX_OPUS_BYTES, SAMPLE_RATE};
use base::message_proto::{
    message, misc, AudioFormat, AudioFrame, Features, Message, NikoVoiceBinding,
    VoiceCallRequest, VoiceCallResponse,
};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum WireError {
    Unsupported,
    InvalidBinding,
    StaleBinding,
    InvalidRequest,
    InvalidFormat,
    InvalidPacket,
}

fn require_peer(features: &Features) -> Result<(), WireError> {
    if !features.nikodesk_voice_v1 {
        return Err(WireError::Unsupported);
    }
    Ok(())
}

fn metadata(binding: Binding) -> NikoVoiceBinding {
    NikoVoiceBinding {
        call_nonce: binding.nonce().to_vec().into(),
        call_epoch: binding.epoch(),
        ..Default::default()
    }
}

fn parse_metadata(value: Option<&NikoVoiceBinding>) -> Result<Binding, WireError> {
    let value = value.ok_or(WireError::InvalidBinding)?;
    if value.call_nonce.len() != 16 {
        return Err(WireError::InvalidBinding);
    }
    if value.call_epoch>i64::MAX as u64 {return Err(WireError::InvalidBinding);}
    let mut nonce = [0; 16];
    nonce.copy_from_slice(&value.call_nonce);
    Binding::new(nonce, value.call_epoch).map_err(|_| WireError::InvalidBinding)
}

fn expected_metadata(value: Option<&NikoVoiceBinding>, expected: Binding) -> Result<(), WireError> {
    if parse_metadata(value)? != expected {
        return Err(WireError::StaleBinding);
    }
    Ok(())
}

pub(crate) fn request(
    peer: &Features,
    binding: Binding,
    timestamp: i64,
    connect: bool,
) -> Result<VoiceCallRequest, WireError> {
    require_peer(peer)?;
    // The peer's policy snapshot allows asking, never opening its microphone.
    // Closing an existing call remains possible after that policy is disabled.
    if connect && !peer.nikodesk_voice_requests_allowed {
        return Err(WireError::Unsupported);
    }
    if timestamp <= 0 {
        return Err(WireError::InvalidRequest);
    }
    Ok(VoiceCallRequest {
        req_timestamp: timestamp,
        is_connect: connect,
        nikodesk_voice: Some(metadata(binding)).into(),
        ..Default::default()
    })
}

/// Identify voice candidates before the legacy system-audio dispatcher. A
/// tagged malformed frame must be rejected by the owned path, never played as
/// ordinary desktop sound. This classification grants no media access.
pub(crate) fn is_voice_candidate(message: &Message) -> bool {
    match message.union.as_ref() {
        Some(message::Union::VoiceCallRequest(_))
        | Some(message::Union::VoiceCallResponse(_)) => true,
        Some(message::Union::AudioFrame(frame)) => frame.nikodesk_voice.is_some(),
        Some(message::Union::Misc(value)) => match value.union.as_ref() {
            Some(misc::Union::AudioFormat(format)) => format.nikodesk_voice.is_some(),
            _ => false,
        },
        _ => false,
    }
}

/// One authenticated connection's incoming-call epochs. Retain this across
/// ended calls so a delayed/replayed request cannot create another approval
/// using the same media binding. No remote identifier is retained or logged.
#[derive(Default)]
pub(crate) struct IncomingCallFence {
    last_epoch: u64,
}

impl IncomingCallFence {
    pub(crate) fn accept(
        &mut self,
        peer: &Features,
        request: &VoiceCallRequest,
    ) -> Result<Binding, WireError> {
        let binding = request_binding(peer, request)?;
        if !request.is_connect {
            return Err(WireError::InvalidRequest);
        }
        if binding.epoch() > i64::MAX as u64 || binding.epoch() <= self.last_epoch {
            return Err(WireError::StaleBinding);
        }
        self.last_epoch = binding.epoch();
        Ok(binding)
    }
}

pub(crate) fn request_binding(
    peer: &Features,
    request: &VoiceCallRequest,
) -> Result<Binding, WireError> {
    require_peer(peer)?;
    if request.req_timestamp <= 0 {
        return Err(WireError::InvalidRequest);
    }
    parse_metadata(request.nikodesk_voice.as_ref())
}

pub(crate) fn response(
    peer: &Features,
    binding: Binding,
    request: &VoiceCallRequest,
    accepted: bool,
    timestamp: i64,
) -> Result<VoiceCallResponse, WireError> {
    if request_binding(peer, request)? != binding {
        return Err(WireError::StaleBinding);
    }
    if timestamp <= 0 {
        return Err(WireError::InvalidRequest);
    }
    Ok(VoiceCallResponse {
        accepted,
        req_timestamp: request.req_timestamp,
        ack_timestamp: timestamp,
        nikodesk_voice: Some(metadata(binding)).into(),
        ..Default::default()
    })
}

pub(crate) fn validate_response(
    peer: &Features,
    binding: Binding,
    request_timestamp: i64,
    response: &VoiceCallResponse,
) -> Result<bool, WireError> {
    require_peer(peer)?;
    expected_metadata(response.nikodesk_voice.as_ref(), binding)?;
    if request_timestamp <= 0
        || response.req_timestamp != request_timestamp
        || response.ack_timestamp <= 0
    {
        return Err(WireError::InvalidRequest);
    }
    Ok(response.accepted)
}

pub(crate) fn audio_format(peer: &Features, binding: Binding) -> Result<AudioFormat, WireError> {
    require_peer(peer)?;
    Ok(AudioFormat {
        sample_rate: SAMPLE_RATE,
        channels: 1,
        nikodesk_voice: Some(metadata(binding)).into(),
        ..Default::default()
    })
}

pub(crate) fn validate_format(
    peer: &Features,
    binding: Binding,
    format: &AudioFormat,
) -> Result<(), WireError> {
    require_peer(peer)?;
    expected_metadata(format.nikodesk_voice.as_ref(), binding)?;
    if format.sample_rate != SAMPLE_RATE || format.channels != 1 {
        return Err(WireError::InvalidFormat);
    }
    Ok(())
}

pub(crate) fn audio_frame(
    peer: &Features,
    binding: Binding,
    packet: &EncodedPacket,
) -> Result<AudioFrame, WireError> {
    require_peer(peer)?;
    if packet.binding() != binding {
        return Err(WireError::StaleBinding);
    }
    Ok(AudioFrame {
        data: packet.bytes().to_vec().into(),
        nikodesk_voice: Some(metadata(binding)).into(),
        ..Default::default()
    })
}

pub(crate) fn decode_frame(
    peer: &Features,
    binding: Binding,
    frame: &AudioFrame,
) -> Result<EncodedPacket, WireError> {
    require_peer(peer)?;
    expected_metadata(frame.nikodesk_voice.as_ref(), binding)?;
    // Bound before allocating an owned media packet. Legacy system audio and
    // malformed voice metadata must never be treated as another voice call.
    if frame.data.is_empty() || frame.data.len() > MAX_OPUS_BYTES {
        return Err(WireError::InvalidPacket);
    }
    EncodedPacket::new(binding, frame.data.to_vec()).map_err(|_| WireError::InvalidPacket)
}

#[cfg(test)]
mod tests {
    use super::super::voice::FRAME_SAMPLES;
    use super::*;
    use hbb_common::protobuf::Message as _;

    fn peer() -> Features {
        Features {
            nikodesk_voice_v1: true,
            nikodesk_voice_requests_allowed: true,
            ..Default::default()
        }
    }

    #[test]
    fn incoming_policy_is_required_for_a_new_request_but_not_teardown() {
        let mut peer = peer();
        peer.nikodesk_voice_requests_allowed = false;
        assert_eq!(request(&peer, binding(), 11, true), Err(WireError::Unsupported));
        let stop = request(&peer, binding(), 11, false).unwrap();
        assert!(!stop.is_connect);
        assert_eq!(request_binding(&peer, &stop).unwrap(), binding());
        peer.nikodesk_voice_v1 = false;
        assert_eq!(request(&peer, binding(), 11, false), Err(WireError::Unsupported));
    }

    #[test]
    fn voice_tags_never_fall_through_to_desktop_audio_even_when_malformed() {
        let mut frame = AudioFrame::new();
        frame.data = vec![1].into();
        let mut message = Message::new();
        message.set_audio_frame(frame.clone());
        assert!(!is_voice_candidate(&message));
        frame.nikodesk_voice = Some(NikoVoiceBinding::new()).into();
        message.set_audio_frame(frame);
        assert!(is_voice_candidate(&message));
        assert_eq!(decode_frame(&peer(), binding(), message.audio_frame()).err(), Some(WireError::InvalidBinding));

        let mut format = AudioFormat::new();
        let mut misc = base::message_proto::Misc::new();
        misc.set_audio_format(format.clone());
        message.set_misc(misc.clone());
        assert!(!is_voice_candidate(&message));
        format.nikodesk_voice = Some(NikoVoiceBinding::new()).into();
        misc.set_audio_format(format);
        message.set_misc(misc);
        assert!(is_voice_candidate(&message));

        message.set_voice_call_request(VoiceCallRequest::new());
        assert!(is_voice_candidate(&message));
        message.set_voice_call_response(VoiceCallResponse::new());
        assert!(is_voice_candidate(&message));
        message.set_test_delay(Default::default());
        assert!(!is_voice_candidate(&message));
    }

    #[test]
    fn replayed_or_invalid_call_cannot_reopen_an_old_binding_or_consume_new_epoch() {
        let mut fence = IncomingCallFence::default();
        let request_a = request(&peer(), binding(), 11, true).unwrap();
        assert_eq!(fence.accept(&peer(), &request_a).unwrap(), binding());
        assert_eq!(fence.accept(&peer(), &request_a), Err(WireError::StaleBinding));
        let mut malformed = request(&peer(), Binding::new([8; 16], 3).unwrap(), 12, true).unwrap();
        malformed.req_timestamp = 0;
        assert_eq!(fence.accept(&peer(), &malformed), Err(WireError::InvalidRequest));
        malformed.req_timestamp = 12;
        malformed.is_connect = false;
        assert_eq!(fence.accept(&peer(), &malformed), Err(WireError::InvalidRequest));
        malformed.is_connect = true;
        assert_eq!(fence.accept(&peer(), &malformed).unwrap().epoch(), 3);
        assert_eq!(fence.accept(&peer(), &request_a), Err(WireError::StaleBinding));
        assert_eq!(fence.accept(&Features::default(), &request_a), Err(WireError::Unsupported));
    }
    fn binding() -> Binding {
        Binding::new([4; 16], 2).unwrap()
    }

    #[test]
    fn out_of_range_android_epoch_cannot_consume_the_incoming_fence() {
        let mut fence = IncomingCallFence::default();
        let mut excessive = request(&peer(), binding(), 11, true).unwrap();
        excessive.nikodesk_voice.as_mut().unwrap().call_epoch = i64::MAX as u64 + 1;
        assert_eq!(fence.accept(&peer(), &excessive), Err(WireError::InvalidBinding));
        assert_eq!(fence.accept(&peer(), &request(&peer(), binding(), 12, true).unwrap()), Ok(binding()));
    }

    #[test]
    fn legacy_binary_fixtures_are_unchanged_and_support_is_absent_by_default() {
        assert_eq!(
            Features::default().write_to_bytes().unwrap(),
            Vec::<u8>::new()
        );
        let fixtures: &[&[u8]] = &[
            &[0x08, 0x80, 0xf7, 0x02, 0x10, 0x01],
            &[0x0a, 0x03, 0x01, 0x02, 0x03],
            &[0x08, 0x0b, 0x10, 0x01],
            &[0x08, 0x01, 0x10, 0x0b, 0x18, 0x0c],
            &[0x08, 0x01, 0x10, 0x01, 0x18, 0x01],
        ];
        let format = AudioFormat::parse_from_bytes(fixtures[0]).unwrap();
        assert_eq!(format.sample_rate, SAMPLE_RATE);
        assert!(format.nikodesk_voice.is_none());
        assert_eq!(format.write_to_bytes().unwrap(), fixtures[0]);
        let frame = AudioFrame::parse_from_bytes(fixtures[1]).unwrap();
        assert!(frame.nikodesk_voice.is_none());
        assert_eq!(frame.write_to_bytes().unwrap(), fixtures[1]);
        let request = VoiceCallRequest::parse_from_bytes(fixtures[2]).unwrap();
        assert!(request.nikodesk_voice.is_none());
        assert_eq!(request.write_to_bytes().unwrap(), fixtures[2]);
        let response = VoiceCallResponse::parse_from_bytes(fixtures[3]).unwrap();
        assert!(response.nikodesk_voice.is_none());
        assert_eq!(response.write_to_bytes().unwrap(), fixtures[3]);
        let features = Features::parse_from_bytes(fixtures[4]).unwrap();
        assert!(!features.nikodesk_voice_v1);
        assert_eq!(features.write_to_bytes().unwrap(), fixtures[4]);
        assert_eq!(
            request_binding(&features, &request),
            Err(WireError::Unsupported)
        );
    }

    #[test]
    fn request_response_roundtrip_uses_exact_nonce_epoch_and_request() {
        let outbound = request(&peer(), binding(), 11, true).unwrap();
        let outbound =
            VoiceCallRequest::parse_from_bytes(&outbound.write_to_bytes().unwrap()).unwrap();
        assert_eq!(request_binding(&peer(), &outbound).unwrap(), binding());
        for accepted in [true, false] {
            let response = response(&peer(), binding(), &outbound, accepted, 12).unwrap();
            let response =
                VoiceCallResponse::parse_from_bytes(&response.write_to_bytes().unwrap()).unwrap();
            assert_eq!(
                validate_response(&peer(), binding(), 11, &response).unwrap(),
                accepted
            );
            assert_eq!(
                validate_response(&peer(), binding(), 13, &response),
                Err(WireError::InvalidRequest)
            );
        }
        assert!(request(&peer(), binding(), 0, true).is_err());
    }

    #[test]
    fn malformed_or_unnegotiated_binding_is_never_a_legacy_fallback() {
        let mut request = request(&peer(), binding(), 11, true).unwrap();
        assert_eq!(
            request_binding(&Features::default(), &request),
            Err(WireError::Unsupported)
        );
        for len in [0, 15, 17, 128] {
            request.nikodesk_voice.as_mut().unwrap().call_nonce = vec![4; len].into();
            assert_eq!(
                request_binding(&peer(), &request),
                Err(WireError::InvalidBinding)
            );
        }
        request.nikodesk_voice.as_mut().unwrap().call_nonce = vec![0; 16].into();
        assert_eq!(
            request_binding(&peer(), &request),
            Err(WireError::InvalidBinding)
        );
        request.nikodesk_voice.as_mut().unwrap().call_nonce = vec![4; 16].into();
        request.nikodesk_voice.as_mut().unwrap().call_epoch = 0;
        assert_eq!(
            request_binding(&peer(), &request),
            Err(WireError::InvalidBinding)
        );
        request.nikodesk_voice = None.into();
        assert_eq!(
            request_binding(&peer(), &request),
            Err(WireError::InvalidBinding)
        );
    }

    #[test]
    fn format_is_exact_and_stale_media_is_refused_before_copy() {
        let mut format = audio_format(&peer(), binding()).unwrap();
        assert!(validate_format(&peer(), binding(), &format).is_ok());
        format.channels = 2;
        assert_eq!(
            validate_format(&peer(), binding(), &format),
            Err(WireError::InvalidFormat)
        );
        let packet = EncodedPacket::new(binding(), vec![1, 2, 3]).unwrap();
        let mut frame = audio_frame(&peer(), binding(), &packet).unwrap();
        let encoded = frame.write_to_bytes().unwrap();
        let decoded = AudioFrame::parse_from_bytes(&encoded).unwrap();
        assert_eq!(
            decode_frame(&peer(), binding(), &decoded).unwrap().bytes(),
            packet.bytes()
        );
        for next in [
            Binding::new([5; 16], 2).unwrap(),
            Binding::new([4; 16], 3).unwrap(),
        ] {
            assert!(matches!(
                decode_frame(&peer(), next, &frame),
                Err(WireError::StaleBinding)
            ));
        }
        frame.data = vec![0; MAX_OPUS_BYTES + 1].into();
        assert!(matches!(
            decode_frame(&peer(), binding(), &frame),
            Err(WireError::InvalidPacket)
        ));
        frame.data = Vec::new().into();
        assert!(matches!(
            decode_frame(&peer(), binding(), &frame),
            Err(WireError::InvalidPacket)
        ));
        frame.nikodesk_voice = None.into();
        assert!(matches!(
            decode_frame(&peer(), binding(), &frame),
            Err(WireError::InvalidBinding)
        ));
        assert_eq!(FRAME_SAMPLES * 100, SAMPLE_RATE as usize);
    }
}
