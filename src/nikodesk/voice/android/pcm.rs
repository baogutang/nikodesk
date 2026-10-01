use super::super::{VoiceError, FRAME_SAMPLES};

// Only one bounded frame may be pending; a short write cannot discard/repeat
// its unwritten tail or fetch a new frame before the old one was accepted.
pub(super) struct PendingPlayback {
    samples: [f32; FRAME_SAMPLES],
    offset: usize,
    valid: usize,
}
impl PendingPlayback {
    pub fn new() -> Self {
        Self {
            samples: [0.; FRAME_SAMPLES],
            offset: 0,
            valid: 0,
        }
    }
    pub fn empty(&self) -> bool {
        self.offset == self.valid
    }
    pub fn load(&mut self, samples: [f32; FRAME_SAMPLES]) -> Result<(), VoiceError> {
        if !self.empty() {
            return Err(VoiceError::Busy);
        }
        if samples.iter().any(|s| !s.is_finite() || s.abs() > 1.) {
            return Err(VoiceError::InvalidPcm);
        }
        self.samples = samples;
        self.offset = 0;
        self.valid = FRAME_SAMPLES;
        Ok(())
    }
    pub fn data(&self) -> &[f32; FRAME_SAMPLES] {
        &self.samples
    }
    pub fn offset(&self) -> usize {
        self.offset
    }
    pub fn remaining(&self) -> usize {
        self.valid - self.offset
    }
    pub fn accepted(&mut self, count: i32) -> Result<bool, VoiceError> {
        if count < 0 || count as usize > self.remaining() {
            return Err(VoiceError::InvalidPcm);
        }
        self.offset += count as usize;
        let complete = self.empty();
        if complete {
            self.clear();
        }
        Ok(complete)
    }
    pub fn clear(&mut self) {
        self.samples.fill(0.);
        self.offset = 0;
        self.valid = 0;
    }
}
pub(super) fn capture_count(count: i32) -> Result<usize, VoiceError> {
    if count < 0 || count as usize > FRAME_SAMPLES {
        return Err(VoiceError::InvalidPcm);
    }
    Ok(count as usize)
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn android_voice_partial_writes_preserve_exact_tail_and_no_replacement() {
        let mut pending = PendingPlayback::new();
        let pcm = std::array::from_fn(|i| i as f32 / 480.);
        pending.load(pcm).unwrap();
        pending.accepted(123).unwrap();
        assert_eq!(pending.offset(), 123);
        assert_eq!(pending.remaining(), 357);
        assert_eq!(pending.data()[123], pcm[123]);
        assert!(matches!(
            pending.load([0.; FRAME_SAMPLES]),
            Err(VoiceError::Busy)
        ));
        pending.accepted(0).unwrap();
        assert_eq!(pending.offset(), 123);
        assert!(pending.accepted(358).is_err());
        assert_eq!(pending.offset(), 123);
        pending.accepted(357).unwrap();
        assert!(pending.empty());
        assert!(pending.data().iter().all(|v| *v == 0.));
    }
    #[test]
    fn android_voice_nonblocking_capture_uses_only_real_return_count() {
        assert_eq!(capture_count(0).unwrap(), 0);
        assert_eq!(capture_count(17).unwrap(), 17);
        assert_eq!(capture_count(480).unwrap(), 480);
        for invalid in [-6, -3, -1, 481, i32::MAX] {
            assert!(capture_count(invalid).is_err());
        }
    }
    #[test]
    fn android_voice_pending_pcm_rejects_nan_and_revoke_zeroes_retained_tail() {
        let mut pending = PendingPlayback::new();
        let mut pcm = [0.; FRAME_SAMPLES];
        pcm[8] = f32::NAN;
        assert!(pending.load(pcm).is_err());
        pending.load([0.5; FRAME_SAMPLES]).unwrap();
        pending.accepted(10).unwrap();
        pending.clear();
        assert!(pending.empty());
        assert!(pending.data().iter().all(|v| *v == 0.));
    }
}
