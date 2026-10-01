use super::super::{Binding, VoiceError};
use super::{driver::AndroidBackend, jni, CallSpec};
use serde::Deserialize;

#[derive(Clone, Copy, Debug, Eq, PartialEq, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Direction {
    Capture,
    Playback,
}
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DeviceToken {
    revision: i64,
    token: String,
    direction: Direction,
}
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct FormatToken {
    revision: i64,
    token: String,
}
impl DeviceToken {
    pub fn opaque_token(&self) -> &str {
        &self.token
    }
    pub fn roster_revision(&self) -> i64 {
        self.revision
    }
}
impl FormatToken {
    pub fn opaque_token(&self) -> &str {
        &self.token
    }
    pub fn roster_revision(&self) -> i64 {
        self.revision
    }
}
#[derive(Clone, Debug)]
pub struct DeviceInfo {
    pub uid: String,
    pub token: DeviceToken,
    pub label: String,
    pub direction: Direction,
}
#[derive(Clone, Debug)]
pub struct FormatInfo {
    pub token: FormatToken,
    pub sample_rate: u32,
    pub channels: u16,
}
/// Only constructed from the result of the actual explicit local Activity action.
/// This proof freezes local consent; the caller must still hold its capability ticket.
pub struct LocalApprovalToken {
    token: String,
    // Keeps the actual Java job until proof consumption/drop. Cancellation only
    // erases its matching unconsumed proof, never an active/prepared owner.
    _job: Option<super::authorization::LocalApprovalRequest>,
}
impl LocalApprovalToken {
    pub(super) fn from_job(
        token: String,
        job: super::authorization::LocalApprovalRequest,
    ) -> Result<Self, VoiceError> {
        if !valid_token(&token) {
            return Err(VoiceError::PermissionDenied);
        }
        Ok(Self {
            token,
            _job: Some(job),
        })
    }
    pub fn from_local_action(token: String) -> Result<Self, VoiceError> {
        if !valid_token(&token) {
            return Err(VoiceError::PermissionDenied);
        }
        Ok(Self { token, _job: None })
    }
}
#[derive(Clone)]
pub struct DeviceSnapshot {
    revision: i64,
    devices: Vec<DeviceInfo>,
    formats: Vec<FormatInfo>,
}
impl DeviceSnapshot {
    /// Calls getDevices metadata only. It never constructs a recorder/track,
    /// requests microphone permission, selects a route or acquires audio focus.
    pub fn enumerate() -> Result<Self, VoiceError> {
        Self::parse(&jni::snapshot_json()?)
    }
    pub fn devices(&self) -> &[DeviceInfo] {
        &self.devices
    }
    pub fn formats(&self) -> &[FormatInfo] {
        &self.formats
    }
    pub fn revision(&self) -> i64 {
        self.revision
    }
    pub fn select(
        &self,
        capture: DeviceToken,
        playback: DeviceToken,
        format: FormatToken,
        binding: Binding,
        native_lease: u64,
        local: LocalApprovalToken,
    ) -> Result<AndroidBackend, VoiceError> {
        self.validate(&capture, &playback, &format)?;
        let call = CallSpec::new(binding, native_lease)?;
        let session = jni::prepare(
            self.revision,
            &capture.token,
            &playback.token,
            &format.token,
            call,
            &local.token,
        )?;
        Ok(AndroidBackend::new(call, session))
    }
    pub(super) fn validate(
        &self,
        capture: &DeviceToken,
        playback: &DeviceToken,
        format: &FormatToken,
    ) -> Result<(), VoiceError> {
        if capture.revision != self.revision
            || playback.revision != self.revision
            || format.revision != self.revision
            || capture.direction != Direction::Capture
            || playback.direction != Direction::Playback
            || !self.devices.iter().any(|d| d.token == *capture)
            || !self.devices.iter().any(|d| d.token == *playback)
            || !self.formats.iter().any(|f| f.token == *format)
        {
            return Err(VoiceError::StaleBinding);
        }
        Ok(())
    }
    pub(super) fn parse(json: &str) -> Result<Self, VoiceError> {
        if json.len() > 32_768 {
            return Err(VoiceError::Unsupported);
        }
        let data: Roster = serde_json::from_str(json)
            .map_err(|_| VoiceError::Device("android_voice_roster".into()))?;
        if !data.ok {
            super::status(data.error.unwrap_or(-5))?;
            return Err(VoiceError::WorkerFailed);
        }
        if data.revision <= 0 || data.devices.len() > 64 || data.formats.len() != 1 {
            return Err(VoiceError::Unsupported);
        }
        let mut devices = Vec::with_capacity(data.devices.len());
        for info in data.devices {
            if !valid_token(&info.token)
                || info.id <= 0
                || info.label.chars().count() > 128
                || info.label.chars().any(char::is_control)
                || devices
                    .iter()
                    .any(|d: &DeviceInfo| d.token.token == info.token)
            {
                return Err(VoiceError::Unsupported);
            }
            let token = DeviceToken {
                revision: data.revision,
                token: info.token,
                direction: info.direction,
            };
            devices.push(DeviceInfo {
                uid: format!(
                    "android-audio-port:{}:{}",
                    info.id,
                    if info.direction == Direction::Capture {
                        "capture"
                    } else {
                        "playback"
                    }
                ),
                token,
                label: info.label,
                direction: info.direction,
            });
        }
        let mut formats = Vec::new();
        for info in data.formats {
            if !valid_token(&info.token)
                || info.sample_rate != 48_000
                || info.channels != 1
                || info.encoding != "f32"
                || info.support != "client_format_requires_start_readback"
            {
                return Err(VoiceError::Unsupported);
            }
            formats.push(FormatInfo {
                token: FormatToken {
                    revision: data.revision,
                    token: info.token,
                },
                sample_rate: info.sample_rate,
                channels: info.channels,
            });
        }
        Ok(Self {
            revision: data.revision,
            devices,
            formats,
        })
    }
}
fn valid_token(value: &str) -> bool {
    value.len() == 32
        && value
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
        && value.bytes().any(|b| b != b'0')
}
#[derive(Deserialize)]
struct Roster {
    ok: bool,
    #[serde(default)]
    error: Option<i32>,
    #[serde(default)]
    revision: i64,
    #[serde(default)]
    devices: Vec<JsonDevice>,
    #[serde(default)]
    formats: Vec<JsonFormat>,
}
#[derive(Deserialize)]
struct JsonDevice {
    id: i32,
    token: String,
    direction: Direction,
    label: String,
}
#[derive(Deserialize)]
struct JsonFormat {
    token: String,
    sample_rate: u32,
    channels: u16,
    encoding: String,
    support: String,
}

#[cfg(test)]
mod tests {
    use super::*;
    fn roster() -> String {
        serde_json::json!({"ok":true,"revision":9,"devices":[
        {"token":"11111111111111111111111111111111","direction":"capture","id":3,"label":"Mic"},
        {"token":"22222222222222222222222222222222","direction":"playback","id":4,"label":"Output"}],
        "formats":[{"token":"33333333333333333333333333333333","sample_rate":48000,"channels":1,"encoding":"f32","support":"client_format_requires_start_readback"}]}).to_string()
    }
    #[test]
    fn android_voice_snapshot_tokens_reject_wrong_revision_direction_and_membership() {
        let snapshot = DeviceSnapshot::parse(&roster()).unwrap();
        let capture = snapshot.devices[0].token.clone();
        let playback = snapshot.devices[1].token.clone();
        let format = snapshot.formats[0].token.clone();
        assert!(snapshot.validate(&capture, &playback, &format).is_ok());
        let mut old = capture.clone();
        old.revision = 8;
        assert!(matches!(
            snapshot.validate(&old, &playback, &format),
            Err(VoiceError::StaleBinding)
        ));
        assert!(snapshot.validate(&playback, &capture, &format).is_err());
        let mut forged = playback.clone();
        forged.token = "44444444444444444444444444444444".into();
        assert!(snapshot.validate(&capture, &forged, &format).is_err());
    }
    #[test]
    fn android_voice_roster_is_bounded_strict_and_permission_errors_stay_errors() {
        assert!(matches!(
            DeviceSnapshot::parse("{\"ok\":false,\"error\":-1}"),
            Err(VoiceError::PermissionDenied)
        ));
        for value in [
            roster().replace("48000", "44100"),
            roster().replace("capture", "unknown"),
            roster().replace(
                "22222222222222222222222222222222",
                "11111111111111111111111111111111",
            ),
            "x".repeat(32_769),
        ] {
            assert!(DeviceSnapshot::parse(&value).is_err());
        }
        assert!(LocalApprovalToken::from_local_action("default".into()).is_err());
    }
}
