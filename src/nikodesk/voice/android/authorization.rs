//! Explicit local Activity jobs. OS permission is a readonly fact, never a
//! capability ticket or an automatic call approval.
use super::super::{Binding, VoiceError};
use super::{
    device::{DeviceSnapshot, DeviceToken, FormatToken, LocalApprovalToken},
    jni, CallSpec,
};
use ::jni::objects::GlobalRef;

pub struct PermissionRequest {
    job: Option<GlobalRef>,
}
impl PermissionRequest {
    pub fn begin() -> Result<Self, VoiceError> {
        Ok(Self {
            job: Some(jni::permission_job()?),
        })
    }
    pub fn poll(&mut self) -> Result<Option<i32>, VoiceError> {
        let job = self.job.as_ref().ok_or(VoiceError::Closed)?;
        let code = jni::session_int(job, "pollCode")?;
        permission_result(code)
    }
    pub fn cancel(&mut self) -> Result<(), VoiceError> {
        if let Some(job) = self.job.as_ref() {
            jni::cancel_job(job)?;
        }
        self.job = None;
        Ok(())
    }
}
impl Drop for PermissionRequest {
    fn drop(&mut self) {
        // A pending framework dialog remains Java-owned until its exact callback.
        // JNI failure is not permission/cleanup ACK, and yields no Rust proof.
        if let Err(_not_acknowledged) = self.cancel() {}
    }
}

pub struct LocalApprovalRequest {
    job: Option<GlobalRef>,
}
impl LocalApprovalRequest {
    pub fn begin(
        snapshot: &DeviceSnapshot,
        capture: &DeviceToken,
        playback: &DeviceToken,
        format: &FormatToken,
        binding: Binding,
        native_lease: u64,
        allow_background: bool,
    ) -> Result<Self, VoiceError> {
        snapshot.validate(capture, playback, format)?;
        let call = CallSpec::new(binding, native_lease)?;
        Ok(Self {
            job: Some(jni::approval_job(
                snapshot.revision(),
                capture.opaque_token(),
                playback.opaque_token(),
                format.opaque_token(),
                call,
                allow_background,
            )?),
        })
    }
    pub fn poll(&mut self) -> Result<Option<LocalApprovalToken>, VoiceError> {
        let job = self.job.as_ref().ok_or(VoiceError::Closed)?;
        let proof = jni::job_string(job, "pollProof")?;
        if proof.is_empty() {
            return Ok(None);
        }
        if proof == "!notification_permission" {
            return Err(VoiceError::Device(
                "android_voice_notification_permission".into(),
            ));
        }
        if proof == "!cancelled" {
            return Err(VoiceError::Closed);
        }
        if proof == "!busy" {
            return Err(VoiceError::Busy);
        }
        if proof == "!devices_changed" {
            return Err(VoiceError::StaleBinding);
        }
        if proof == "!unavailable" {
            return Err(VoiceError::Unsupported);
        }
        if proof.starts_with('!') {
            return Err(VoiceError::PermissionDenied);
        }
        let job = self.job.take().ok_or(VoiceError::Closed)?;
        // Move (not clone) this native-held proof owner into the one-shot token.
        LocalApprovalToken::from_job(proof, Self { job: Some(job) }).map(Some)
    }
    pub fn cancel(&mut self) -> Result<(), VoiceError> {
        if let Some(job) = self.job.as_ref() {
            jni::cancel_job(job)?;
        }
        self.job = None;
        Ok(())
    }
}
impl Drop for LocalApprovalRequest {
    fn drop(&mut self) {
        if let Err(_not_acknowledged) = self.cancel() {}
    }
}
fn permission_result(code: i32) -> Result<Option<i32>, VoiceError> {
    match code {
        2 => Ok(None),
        1 | 0 | -1 | -3 | -4 => Ok(Some(code)),
        -6 => Err(VoiceError::Closed),
        _ => Err(VoiceError::Unsupported),
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn android_voice_permission_pending_and_cancel_are_not_grants() {
        assert_eq!(permission_result(2).unwrap(), None);
        for code in [0, -1, -3, -4] {
            assert_eq!(permission_result(code).unwrap(), Some(code));
        }
        assert!(matches!(permission_result(-6), Err(VoiceError::Closed)));
        for code in [3, -2, i32::MAX] {
            assert!(permission_result(code).is_err());
        }
        assert_eq!(permission_result(1).unwrap(), Some(1));
    }
}
