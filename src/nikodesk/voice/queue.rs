use super::{Binding, VoiceError, FRAME_SAMPLES, MAX_OPUS_BYTES, QUEUE_FRAMES};
use std::collections::VecDeque;

#[derive(Clone)]
pub struct PcmFrame {
    pub(super) binding: Binding,
    pub(super) samples: [f32; FRAME_SAMPLES],
}
impl PcmFrame {
    pub fn new(binding: Binding, samples: [f32; FRAME_SAMPLES]) -> Result<Self, VoiceError> {
        if samples.iter().any(|v| !v.is_finite() || v.abs() > 1.0) { return Err(VoiceError::InvalidPcm); }
        Ok(Self { binding, samples })
    }
    pub fn binding(&self) -> Binding { self.binding }
    pub fn samples(&self) -> &[f32; FRAME_SAMPLES] { &self.samples }
}
#[derive(Clone)]
pub struct EncodedPacket {
    pub(super) binding: Binding,
    pub(super) bytes: Vec<u8>,
}
impl EncodedPacket {
    pub fn new(binding: Binding, bytes: Vec<u8>) -> Result<Self, VoiceError> {
        if bytes.is_empty() || bytes.len() > MAX_OPUS_BYTES { return Err(VoiceError::InvalidPacket); }
        // The queue budget includes retained allocation, not only payload len.
        let bytes = bytes.into_boxed_slice().into_vec();
        Ok(Self { binding, bytes })
    }
    pub fn binding(&self) -> Binding { self.binding }
    pub fn bytes(&self) -> &[u8] { &self.bytes }
}

pub(super) struct Queue<T> { items: VecDeque<T> }
impl<T> Queue<T> {
    pub fn new() -> Self { Self { items: VecDeque::with_capacity(QUEUE_FRAMES) } }
    pub fn push(&mut self, value: T) {
        if self.items.len() == QUEUE_FRAMES { self.items.pop_front(); }
        self.items.push_back(value);
    }
    pub fn pop(&mut self) -> Option<T> { self.items.pop_front() }
    pub fn clear(&mut self) { self.items.clear(); }
    #[cfg(test)]
    pub fn len(&self) -> usize { self.items.len() }
}
