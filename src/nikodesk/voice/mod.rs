//! Connection-owned voice media. Authorization and negotiated wire binding live
//! at the caller; a Binding only identifies media and never grants permission.
mod codec;
mod owner;
mod queue;
mod sealed { pub trait Sealed {} }
#[cfg(target_os = "macos")]
pub mod macos;
#[cfg(target_os = "windows")]
pub mod windows;

pub use codec::{VoiceDecoder, VoiceEncoder};
pub use owner::{MediaIo, VoiceBackend, VoiceDriver, VoiceOwner};
pub use queue::{EncodedPacket, PcmFrame};

pub const SAMPLE_RATE: u32 = 48_000;
pub const FRAME_SAMPLES: usize = 480;
pub const QUEUE_FRAMES: usize = 10;
pub const MAX_OPUS_BYTES: usize = 1275;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Binding {
    nonce: [u8; 16],
    epoch: u64,
}
impl Binding {
    pub fn new(nonce: [u8; 16], epoch: u64) -> Result<Self, VoiceError> {
        if nonce == [0; 16] || epoch == 0 {
            return Err(VoiceError::InvalidBinding);
        }
        Ok(Self { nonce, epoch })
    }
    pub fn nonce(&self) -> &[u8; 16] { &self.nonce }
    pub fn epoch(&self) -> u64 { self.epoch }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum VoiceError {
    InvalidBinding,
    InvalidPcm,
    InvalidPacket,
    StaleBinding,
    Closed,
    Busy,
    NotReady,
    Timeout,
    PermissionDenied,
    Unsupported,
    Device(String),
    Codec(String),
    WorkerFailed,
}
impl std::fmt::Display for VoiceError {
    fn fmt(&self, out: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(out, "{self:?}")
    }
}
impl std::error::Error for VoiceError {}

#[cfg(test)]
mod tests;
