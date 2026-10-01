//! Actual Android SDK/JNI provider adapter. Enumeration is metadata-only;
//! selection waits for a one-shot visible Activity proof before preparation.
use super::super::super::{
    capability_state::NormalUser,
    voice_flow::{Catalog, Device, Format, Permission, Selection, Status},
    voice_runtime::{self, Prepared},
};
use super::super::{Binding, VoiceError};
use super::{
    DeviceSnapshot, DeviceToken, Direction, FormatToken, LocalApprovalRequest, PermissionRequest,
};
use sha2::{Digest, Sha256};

pub(crate) fn provider() -> Box<dyn voice_runtime::Provider> {
    Box::new(AndroidProvider)
}
struct AndroidProvider;
fn failure(error: VoiceError) -> &'static str {
    match error {
        VoiceError::PermissionDenied => "microphone_denied",
        VoiceError::Busy => "busy",
        VoiceError::Closed => "cancelled",
        VoiceError::StaleBinding => "devices_changed",
        VoiceError::Device(ref code) if code == "android_voice_notification_permission" => {
            "notification_permission_required"
        }
        VoiceError::Unsupported => "unsupported",
        _ => "permission_unavailable",
    }
}
fn permission(code: i32) -> Permission {
    match code {
        1 => Permission::Authorized,
        0 => Permission::NotDetermined,
        -1 => Permission::Denied,
        -3 => Permission::Restricted,
        _ => Permission::Unavailable,
    }
}
impl voice_runtime::Provider for AndroidProvider {
    fn available(&self) -> Result<(), &'static str> {
        if super::available().map_err(failure)? {
            Ok(())
        } else {
            Err("permission_unavailable")
        }
    }
    fn normal_user(&self) -> Result<NormalUser, &'static str> {
        let java_uid = super::normal_user_uid().map_err(failure)?;
        // Both native process UID and the SDK appUID/isolation proof must agree.
        let uid = unsafe { hbb_common::libc::getuid() };
        if java_uid <= 0
            || uid == 0
            || uid != unsafe { hbb_common::libc::geteuid() }
            || uid != java_uid as u32
        {
            Err("ordinary_user_required")
        } else {
            Ok(NormalUser::Unix(uid))
        }
    }
    fn permission(&self) -> Permission {
        super::authorization_status_code()
            .map(permission)
            .unwrap_or(Permission::Unavailable)
    }
    fn enumerate(
        &mut self,
        status: &Status,
        roster: u64,
    ) -> Result<Box<dyn voice_runtime::Roster>, &'static str> {
        Ok(Box::new(AndroidRoster::new(
            DeviceSnapshot::enumerate().map_err(failure)?,
            status,
            roster,
        )?))
    }
    fn request_permission(
        &mut self,
    ) -> Result<Box<dyn voice_runtime::PermissionJob>, &'static str> {
        Ok(Box::new(MicrophoneJob(
            PermissionRequest::begin().map_err(failure)?,
        )))
    }
}
struct MicrophoneJob(PermissionRequest);
impl voice_runtime::PermissionJob for MicrophoneJob {
    fn poll(&mut self) -> Option<Permission> {
        match self.0.poll() {
            Ok(value) => value.map(permission),
            Err(_) => Some(Permission::Unavailable),
        }
    }
    fn cancel(&mut self) {
        if let Err(_not_acknowledged) = self.0.cancel() {}
    }
}
#[derive(Clone)]
struct Choice {
    device: String,
    format: String,
    native: DeviceToken,
    capture: bool,
}
struct AndroidRoster {
    snapshot: DeviceSnapshot,
    catalog: Catalog,
    choices: Vec<Choice>,
}
fn token(parts: &[&[u8]]) -> String {
    let mut hash = Sha256::new();
    hash.update(b"nikodesk-android-voice-catalog-v1");
    for part in parts {
        hash.update((part.len() as u64).to_le_bytes());
        hash.update(part);
    }
    hash.finalize()[..16]
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}
impl AndroidRoster {
    fn new(snapshot: DeviceSnapshot, status: &Status, roster: u64) -> Result<Self, &'static str> {
        if roster == 0 {
            return Err("invalid_selection");
        }
        let mut catalog = Catalog {
            identity: status.identity.clone(),
            revision: status.revision.clone(),
            roster_revision: roster.to_string(),
            microphone_permission: super::authorization_status_code()
                .map(permission)
                .unwrap_or(Permission::Unavailable),
            reason: "client_format_requires_start_readback".into(),
            devices: vec![],
        };
        let native_format = snapshot.formats().first().ok_or("unsupported")?;
        let mut choices = vec![];
        for d in snapshot.devices() {
            let capture = d.direction == Direction::Capture;
            let direction = if capture { "capture" } else { "playback" };
            let device = token(&[
                status.identity.request_nonce.as_bytes(),
                catalog.roster_revision.as_bytes(),
                d.token.opaque_token().as_bytes(),
                d.uid.as_bytes(),
                direction.as_bytes(),
            ]);
            let format = token(&[
                device.as_bytes(),
                native_format.token.opaque_token().as_bytes(),
                b"android_client_pcm_f32_48k_mono_v1",
            ]);
            catalog.devices.push(Device {
                device_token: device.clone(),
                uid: d.uid.clone(),
                label: d.label.clone(),
                direction: direction.into(),
                formats: vec![Format {
                    format_token: format.clone(),
                    sample_rate: 48_000,
                    sample_format: "f32".into(),
                    channels: 1,
                    format_schema: "android_client_pcm_f32_48k_mono_v1".into(),
                }],
            });
            choices.push(Choice {
                device,
                format,
                native: d.token.clone(),
                capture,
            });
        }
        catalog.validate()?;
        Ok(Self {
            snapshot,
            catalog,
            choices,
        })
    }
}
impl voice_runtime::Roster for AndroidRoster {
    fn catalog(&self) -> &Catalog {
        &self.catalog
    }
    fn select(
        &self,
        s: &Selection,
        binding: Binding,
        background: bool,
    ) -> Result<Box<dyn voice_runtime::SelectionJob>, &'static str> {
        if !s.valid() || s.roster_revision != self.catalog.roster_revision {
            return Err("devices_changed");
        }
        let input = self
            .choices
            .iter()
            .find(|v| {
                v.capture && v.device == s.capture_token && v.format == s.capture_format_token
            })
            .ok_or("devices_changed")?;
        let output = self
            .choices
            .iter()
            .find(|v| {
                !v.capture && v.device == s.playback_token && v.format == s.playback_format_token
            })
            .ok_or("devices_changed")?;
        let format = self
            .snapshot
            .formats()
            .first()
            .ok_or("unsupported")?
            .token
            .clone();
        let lease = super::super::owner::reserve_native_lease().map_err(failure)?;
        let job = LocalApprovalRequest::begin(
            &self.snapshot,
            &input.native,
            &output.native,
            &format,
            binding,
            lease,
            background,
        )
        .map_err(failure)?;
        let exact = serde_json::to_vec(&(
            self.snapshot.revision(),
            self.catalog.roster_revision.clone(),
            input.native.opaque_token(),
            output.native.opaque_token(),
            format.opaque_token(),
            48_000u32,
            1u16,
            "f32",
        ))
        .map_err(|_| "invalid_selection")?;
        Ok(Box::new(ApprovalJob {
            snapshot: self.snapshot.clone(),
            input: input.native.clone(),
            output: output.native.clone(),
            format,
            binding,
            lease,
            background,
            exact,
            job,
            completed: false,
        }))
    }
}
struct ApprovalJob {
    snapshot: DeviceSnapshot,
    input: DeviceToken,
    output: DeviceToken,
    format: FormatToken,
    binding: Binding,
    lease: u64,
    background: bool,
    exact: Vec<u8>,
    job: LocalApprovalRequest,
    completed: bool,
}
impl voice_runtime::SelectionJob for ApprovalJob {
    fn poll(&mut self) -> Result<Option<Prepared>, &'static str> {
        if self.completed {
            return Err("cancelled");
        }
        let Some(proof) = self.job.poll().map_err(failure)? else {
            return Ok(None);
        };
        self.completed = true;
        let backend = self
            .snapshot
            .select(
                self.input.clone(),
                self.output.clone(),
                self.format.clone(),
                self.binding,
                self.lease,
                proof,
            )
            .map_err(failure)?;
        Prepared::for_backend(
            backend,
            self.binding,
            self.lease,
            self.exact.clone(),
            self.background,
        )
        .map(Some)
    }
    fn cancel(&mut self) {
        self.completed = true;
        if let Err(_not_acknowledged) = self.job.cancel() {}
    }
}

#[cfg(test)]
mod tests {
    use super::super::super::super::voice_flow::{Identity, Wire};
    use super::*;
    fn snapshot() -> DeviceSnapshot {
        DeviceSnapshot::parse(r#"{"ok":true,"revision":9,"devices":[{"token":"11111111111111111111111111111111","id":3,"direction":"capture","label":"Mic"},{"token":"22222222222222222222222222222222","id":4,"direction":"playback","label":"Output"}],"formats":[{"token":"33333333333333333333333333333333","sample_rate":48000,"channels":1,"encoding":"f32","support":"client_format_requires_start_readback"}]}"#).unwrap()
    }
    fn state() -> Status {
        Status::pending(
            Identity {
                connection_id: 7,
                namespace: "ab".repeat(32),
                peer_id: "123456789".into(),
                connection_nonce: "01".repeat(16),
                request_nonce: "02".repeat(16),
                epoch: "1".into(),
            },
            Wire {
                call_nonce: "03".repeat(16),
                call_epoch: "9".into(),
            },
        )
        .unwrap()
    }
    #[test]
    fn android_voice_actual_catalog_binds_tokens_to_request_and_roster() {
        let status = state();
        let first = AndroidRoster::new(snapshot(), &status, 1).unwrap();
        let second = AndroidRoster::new(snapshot(), &status, 2).unwrap();
        assert!(first.catalog.validate().is_ok());
        assert_ne!(
            first.catalog.devices[0].device_token,
            second.catalog.devices[0].device_token
        );
        let mut other = status.clone();
        other.identity.request_nonce = "04".repeat(16);
        let other = AndroidRoster::new(snapshot(), &other, 1).unwrap();
        assert_ne!(
            first.catalog.devices[0].device_token,
            other.catalog.devices[0].device_token
        );
        assert_eq!(first.catalog.devices[0].uid, "android-audio-port:3:capture");
        assert_ne!(
            first.catalog.devices[0].formats[0].format_token,
            first.catalog.devices[1].formats[0].format_token
        );
        assert_eq!(first.catalog.devices[0].formats[0].channels, 1);
        assert_eq!(
            first.catalog.reason,
            "client_format_requires_start_readback"
        );
        if let Ok(path) = std::env::var("NIKO_VOICE_CATALOG_FIXTURE_PATH") {
            std::fs::write(path, serde_json::to_vec_pretty(&first.catalog).unwrap()).unwrap();
        }
    }
    #[test]
    fn android_voice_adapter_rejects_foreign_direction_format_and_revision_before_jni() {
        use super::super::super::super::voice_runtime::Roster;
        let roster = AndroidRoster::new(snapshot(), &state(), 1).unwrap();
        let d = &roster.catalog.devices;
        let selected = Selection {
            roster_revision: "1".into(),
            capture_token: d[0].device_token.clone(),
            capture_format_token: d[0].formats[0].format_token.clone(),
            playback_token: d[1].device_token.clone(),
            playback_format_token: d[1].formats[0].format_token.clone(),
        };
        for changed in [
            Selection {
                roster_revision: "2".into(),
                ..selected.clone()
            },
            Selection {
                capture_format_token: selected.playback_format_token.clone(),
                ..selected.clone()
            },
            Selection {
                capture_token: selected.playback_token.clone(),
                ..selected.clone()
            },
        ] {
            assert_eq!(
                roster
                    .select(&changed, Binding::new([9; 16], 1).unwrap(), false)
                    .err(),
                Some("devices_changed")
            );
        }
        assert_eq!(
            roster
                .select(&selected, Binding::new([9; 16], 1).unwrap(), false)
                .err(),
            Some("unsupported")
        ); // Actual JNI runtime was never initialized; no device mock.
    }
    #[test]
    fn android_voice_android_permission_codes_never_infer_backend_or_grant() {
        assert_eq!(permission(0), Permission::NotDetermined);
        assert_eq!(permission(1), Permission::Authorized);
        assert_eq!(permission(-1), Permission::Denied);
        assert_eq!(permission(-3), Permission::Restricted);
        assert_eq!(permission(2), Permission::Unavailable);
        use super::super::super::super::voice_runtime::Provider;
        assert_eq!(AndroidProvider.available(), Err("unsupported"));
        assert_eq!(AndroidProvider.permission(), Permission::Unavailable);
    }
}
