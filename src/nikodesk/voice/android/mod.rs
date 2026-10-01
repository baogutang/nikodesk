//! Android 16 device-owned voice. Only explicit local UI jobs may request
//! permission/approval; device snapshots and context initialization are readonly.
mod authorization;
mod cancellation;
mod device;
mod driver;
mod jni;
mod pcm;

pub use authorization::{LocalApprovalRequest, PermissionRequest};
pub use device::{
    DeviceInfo, DeviceSnapshot, DeviceToken, Direction, FormatInfo, FormatToken, LocalApprovalToken,
};
pub use driver::AndroidBackend;
#[cfg(any(target_os = "android", test))]
pub(crate) mod runtime_adapter;

use super::{Binding, VoiceError};
use std::convert::TryFrom;

#[derive(Clone, Copy)]
pub(super) struct CallSpec {
    pub binding: Binding,
    pub lease: i64,
    pub epoch: i64,
}
impl CallSpec {
    fn new(binding: Binding, lease: u64) -> Result<Self, VoiceError> {
        let lease = i64::try_from(lease).map_err(|_| VoiceError::InvalidBinding)?;
        let epoch = i64::try_from(binding.epoch()).map_err(|_| VoiceError::InvalidBinding)?;
        if lease <= 0 {
            return Err(VoiceError::InvalidBinding);
        }
        Ok(Self {
            binding,
            lease,
            epoch,
        })
    }
}

pub fn authorization_status_code() -> Result<i32, VoiceError> {
    jni::authorization_code()
}
pub fn available() -> Result<bool, VoiceError> {
    jni::available()
}
pub fn normal_user_uid() -> Result<i32, VoiceError> {
    jni::normal_uid()
}

pub fn authorization_status() -> Result<bool, VoiceError> {
    jni::authorization_status()
}
/// Retries only the same call's retained Java/native resources. A successful
/// result does not replace VoiceOwner::stop's Rust worker join acknowledgement.
pub fn retry_retained_native_stop(binding: Binding, native_lease: u64) -> Result<(), VoiceError> {
    status(jni::retained_stop(CallSpec::new(binding, native_lease)?)?)
}

pub(super) fn status(code: i32) -> Result<(), VoiceError> {
    match code {
        0 => Ok(()),
        -1 => Err(VoiceError::PermissionDenied),
        -2 => Err(VoiceError::StaleBinding),
        -3 | -7 => Err(VoiceError::Busy),
        -4 => Err(VoiceError::Unsupported),
        -6 => Err(VoiceError::Closed),
        _ => Err(VoiceError::Device("android_voice_device".into())),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn android_voice_call_native_lease_is_distinct_bounded_and_nonzero() {
        let binding = Binding::new([7; 16], 2).unwrap();
        assert!(CallSpec::new(binding, 0).is_err());
        assert!(CallSpec::new(binding, u64::MAX).is_err());
        let call = CallSpec::new(binding, 99).unwrap();
        assert_eq!(call.epoch, 2);
        assert_eq!(call.lease, 99);
        assert!(CallSpec::new(Binding::new([7; 16], u64::MAX).unwrap(), 1).is_err());
    }
    #[test]
    fn android_voice_unknown_status_never_becomes_audio_or_stop_ack() {
        for value in [1, 2, 3, i32::MIN, i32::MAX, -5] {
            assert!(status(value).is_err());
        }
        assert!(matches!(status(-7), Err(VoiceError::Busy)));
        assert!(status(0).is_ok());
    }
}
