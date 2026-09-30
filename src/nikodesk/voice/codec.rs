use super::{Binding, EncodedPacket, PcmFrame, VoiceError, FRAME_SAMPLES, MAX_OPUS_BYTES, SAMPLE_RATE};
use magnum_opus::{Application, Channels, Decoder, Encoder, SoftClip};

pub struct VoiceEncoder {
    binding: Binding,
    codec: Encoder,
}
impl VoiceEncoder {
    pub fn new(binding: Binding) -> Result<Self, VoiceError> {
        let codec = Encoder::new(SAMPLE_RATE, Channels::Mono, Application::Voip)
            .map_err(|e| VoiceError::Codec(e.to_string()))?;
        Ok(Self { binding, codec })
    }
    pub fn encode(&mut self, frame: &PcmFrame) -> Result<EncodedPacket, VoiceError> {
        if frame.binding != self.binding { return Err(VoiceError::StaleBinding); }
        if frame.samples.iter().any(|v| !v.is_finite() || v.abs() > 1.0) {
            return Err(VoiceError::InvalidPcm);
        }
        let bytes = self.codec.encode_vec_float(&frame.samples, MAX_OPUS_BYTES)
            .map_err(|e| VoiceError::Codec(e.to_string()))?;
        EncodedPacket::new(self.binding, bytes)
    }
}

pub struct VoiceDecoder {
    binding: Binding,
    codec: Decoder,
    clip: SoftClip,
}
impl VoiceDecoder {
    pub fn new(binding: Binding) -> Result<Self, VoiceError> {
        let codec = Decoder::new(SAMPLE_RATE, Channels::Mono)
            .map_err(|e| VoiceError::Codec(e.to_string()))?;
        Ok(Self { binding, codec, clip: SoftClip::new(Channels::Mono) })
    }
    pub fn decode(&mut self, packet: &EncodedPacket) -> Result<PcmFrame, VoiceError> {
        if packet.binding != self.binding { return Err(VoiceError::StaleBinding); }
        let mut samples = [0.; FRAME_SAMPLES];
        let count = self.codec.decode_float(&packet.bytes, &mut samples, false)
            .map_err(|e| VoiceError::Codec(e.to_string()))?;
        if count != FRAME_SAMPLES { return Err(VoiceError::InvalidPacket); }
        if samples.iter().any(|value| !value.is_finite()) { return Err(VoiceError::InvalidPcm); }
        self.clip.apply(&mut samples);
        PcmFrame::new(self.binding, samples)
    }
}
