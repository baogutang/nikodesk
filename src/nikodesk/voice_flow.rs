//! Typed local voice approval contract. Wire/media authorization lives in
//! voice_runtime, never in permission snapshots or deserialized UI booleans.
use serde::{Deserialize, Serialize};

pub(crate) const MAX_COMMAND: usize = 4096;
pub(crate) const MAX_CATALOG: usize = 1024 * 1024;
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Identity {
    pub connection_id: i32,
    pub namespace: String,
    pub peer_id: String,
    pub connection_nonce: String,
    pub request_nonce: String,
    pub epoch: String,
}
pub(crate) fn hex(value: &str, length: usize, nonzero: bool) -> bool {
    value.len() == length
        && value
            .bytes()
            .all(|n| n.is_ascii_digit() || (b'a'..=b'f').contains(&n))
        && (!nonzero || value.bytes().any(|n| n != b'0'))
}
pub(crate) fn counter(value: &str) -> bool {
    value
        .parse::<u64>()
        .is_ok_and(|n| n != 0 && n.to_string() == value)
}
impl Identity {
    pub(crate) fn valid(&self) -> bool {
        self.connection_id > 0
            && hex(&self.namespace, 64, false)
            && (6..=16).contains(&self.peer_id.len())
            && self.peer_id.bytes().all(|b| b.is_ascii_digit())
            && hex(&self.connection_nonce, 32, true)
            && hex(&self.request_nonce, 32, true)
            && counter(&self.epoch)
    }
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) enum Phase {
    Pending,
    Starting,
    Running,
    Revoking,
    RecoveryRequired,
    Stopped,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) enum Permission {
    Unknown,
    Authorized,
    NotDetermined,
    Denied,
    Restricted,
    Unavailable,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Wire {
    pub call_nonce: String,
    pub call_epoch: String,
}
impl Wire {
    pub(crate) fn valid(&self) -> bool {
        hex(&self.call_nonce, 32, true) && counter(&self.call_epoch)
    }
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Selection {
    pub roster_revision: String,
    pub capture_token: String,
    pub capture_format_token: String,
    pub playback_token: String,
    pub playback_format_token: String,
}
impl Selection {
    pub(crate) fn valid(&self) -> bool {
        counter(&self.roster_revision)
            && [
                &self.capture_token,
                &self.capture_format_token,
                &self.playback_token,
                &self.playback_format_token,
            ]
            .into_iter()
            .all(|value| hex(value, 32, true))
            && self.capture_token != self.playback_token
    }
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Status {
    pub identity: Identity,
    pub kind: String,
    pub revision: String,
    pub resource_epoch: String,
    pub phase: Phase,
    pub reason: String,
    pub muted: bool,
    pub local_ready: bool,
    pub peer_accepted: bool,
    pub call_running: bool,
    pub microphone_permission: Permission,
    pub wire: Wire,
    pub selection: Option<Selection>,
    pub cleanup_only: bool,
}
impl Status {
    pub(crate) fn pending(identity: Identity, wire: Wire) -> Result<Self, &'static str> {
        if !identity.valid() || !wire.valid() {
            return Err("invalid_command");
        }
        Ok(Self {
            resource_epoch: identity.epoch.clone(),
            identity,
            wire,
            kind: "voice".into(),
            revision: "1".into(),
            phase: Phase::Pending,
            reason: "pending_local_approval".into(),
            muted: false,
            local_ready: false,
            peer_accepted: false,
            call_running: false,
            microphone_permission: Permission::Unknown,
            selection: None,
            cleanup_only: false,
        })
    }
    pub(crate) fn advance(
        &mut self,
        phase: Phase,
        reason: &'static str,
    ) -> Result<(), &'static str> {
        let revision = self
            .revision
            .parse::<u64>()
            .ok()
            .and_then(|n| n.checked_add(1))
            .ok_or("worker_failed")?;
        self.revision = revision.to_string();
        self.phase = phase;
        self.reason = reason.into();
        self.call_running = phase == Phase::Running && self.local_ready && self.peer_accepted;
        if phase == Phase::Stopped {
            self.local_ready = false;
            self.call_running = false;
            self.selection = None;
        }
        Ok(())
    }
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Format {
    pub format_token: String,
    pub sample_rate: u32,
    pub sample_format: String,
    pub channels: u16,
    pub format_schema: String,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Device {
    pub device_token: String,
    pub uid: String,
    pub label: String,
    pub direction: String,
    pub formats: Vec<Format>,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Catalog {
    pub identity: Identity,
    pub revision: String,
    pub roster_revision: String,
    pub microphone_permission: Permission,
    pub reason: String,
    pub devices: Vec<Device>,
}
impl Catalog {
    pub(crate) fn validate(&self) -> Result<(), &'static str> {
        if !self.identity.valid()
            || !counter(&self.revision)
            || !counter(&self.roster_revision)
            || self.devices.len() > 256
        {
            return Err("invalid_selection");
        }
        let mut tokens = std::collections::HashSet::new();
        for device in &self.devices {
            if !hex(&device.device_token, 32, true)
                || !tokens.insert(&device.device_token)
                || device.uid.is_empty()
                || device.uid.len() > 8192
                || device.uid.contains('\0')
                || device.label.len() > 1024
                || !["capture", "playback"].contains(&device.direction.as_str())
                || device.formats.len() > 2
            {
                return Err("invalid_selection");
            }
            for format in &device.formats {
                if !hex(&format.format_token, 32, true)
                    || !tokens.insert(&format.format_token)
                    || format.sample_rate != 48_000
                    || format.sample_format != "f32"
                    || !(1..=2).contains(&format.channels)
                    || ![
                        "coreaudio-client-v1",
                        "wasapi-shared-client-v1",
                        "android_client_pcm_f32_48k_mono_v1",
                    ]
                    .contains(&format.format_schema.as_str())
                    || (format.format_schema == "android_client_pcm_f32_48k_mono_v1"
                        && format.channels != 1)
                {
                    return Err("invalid_selection");
                }
            }
        }
        if serde_json::to_vec(self)
            .map_err(|_| "invalid_selection")?
            .len()
            > MAX_CATALOG
        {
            return Err("invalid_selection");
        }
        Ok(())
    }
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum Operation {
    Query,
    Enumerate,
    RequestPermission,
    Approve,
    Deny,
    Revoke,
    RetryCleanup,
    Mute,
    Unmute,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Command {
    pub identity: Identity,
    pub revision: String,
    pub op: Operation,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub roster_revision: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub capture_token: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub capture_format_token: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub playback_token: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub playback_format_token: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub allow_background: Option<bool>,
}
impl Command {
    pub(crate) fn parse(json: &str) -> Result<Self, &'static str> {
        if json.len() > MAX_COMMAND {
            return Err("invalid_command");
        }
        let command: Self = serde_json::from_str(json).map_err(|_| "invalid_command")?;
        if !command.identity.valid() || !counter(&command.revision) {
            return Err("invalid_command");
        }
        if command.op == Operation::Approve {
            command.selection()?;
        } else if command.allow_background.is_some()
            || [
                &command.roster_revision,
                &command.capture_token,
                &command.capture_format_token,
                &command.playback_token,
                &command.playback_format_token,
            ]
            .into_iter()
            .any(Option::is_some)
        {
            return Err("invalid_command");
        }
        Ok(command)
    }
    pub(crate) fn selection(&self) -> Result<Selection, &'static str> {
        let selection = Selection {
            roster_revision: self.roster_revision.clone().ok_or("invalid_selection")?,
            capture_token: self.capture_token.clone().ok_or("invalid_selection")?,
            capture_format_token: self
                .capture_format_token
                .clone()
                .ok_or("invalid_selection")?,
            playback_token: self.playback_token.clone().ok_or("invalid_selection")?,
            playback_format_token: self
                .playback_format_token
                .clone()
                .ok_or("invalid_selection")?,
        };
        if !selection.valid() {
            return Err("invalid_selection");
        }
        Ok(selection)
    }
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Reply {
    pub ok: bool,
    pub status: String,
    pub identity: Identity,
    pub revision: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
}
impl Reply {
    pub(crate) fn queued(command: &Command) -> Self {
        Self {
            ok: true,
            status: "queued".into(),
            identity: command.identity.clone(),
            revision: command.revision.clone(),
            reason: None,
        }
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    pub(super) fn fixture() -> (Status, Catalog, Catalog, Reply) {
        let identity = Identity {
            connection_id: 7,
            namespace: "a".repeat(64),
            peer_id: "123456789".into(),
            connection_nonce: "1".repeat(32),
            request_nonce: "2".repeat(32),
            epoch: "1".into(),
        };
        let mut status = Status::pending(
            identity.clone(),
            Wire {
                call_nonce: "3".repeat(32),
                call_epoch: "9".into(),
            },
        )
        .unwrap();
        status.microphone_permission = Permission::NotDetermined;
        let mac = Catalog {
            identity,
            revision: "1".into(),
            roster_revision: "1".into(),
            microphone_permission: Permission::Authorized,
            reason: "pending_local_approval".into(),
            devices: ["capture", "playback"]
                .into_iter()
                .enumerate()
                .map(|(i, direction)| Device {
                    device_token: (4 + i).to_string().repeat(32),
                    uid: format!("synthetic-{direction}-uid"),
                    label: format!("Synthetic {direction}"),
                    direction: direction.into(),
                    formats: vec![Format {
                        format_token: (6 + i).to_string().repeat(32),
                        sample_rate: 48_000,
                        sample_format: "f32".into(),
                        channels: 2,
                        format_schema: "coreaudio-client-v1".into(),
                    }],
                })
                .collect(),
        };
        let mut win = mac.clone();
        for device in &mut win.devices {
            for format in &mut device.formats {
                format.format_schema = "wasapi-shared-client-v1".into();
            }
        }
        let command = Command::parse(
            &serde_json::json!({"identity":status.identity,"revision":"1","op":"enumerate"})
                .to_string(),
        )
        .unwrap();
        (status, mac, win, Reply::queued(&command))
    }
    #[test]
    fn actual_serde_fixture_has_no_pending_device_leak_and_exact_direction_formats() {
        let (status, mac, win, reply) = fixture();
        assert!(status.selection.is_none());
        assert_eq!(status.microphone_permission, Permission::NotDetermined);
        mac.validate().unwrap();
        win.validate().unwrap();
        assert!(reply.reason.is_none());
        if let Ok(path) = std::env::var("NIKODESK_VOICE_FIXTURE_OUTPUT") {
            // Test-only path explicitly supplied inside artifacts, never Config.
            std::fs::write(path, serde_json::to_vec_pretty(&serde_json::json!({"pending":status,"mac_catalog":mac,"windows_catalog":win,"queued":reply})).unwrap()).unwrap();
        }
    }
    #[test]
    fn command_rejects_extra_grant_permission_defaults_and_partial_selection() {
        let (status, _, _, _) = fixture();
        for value in [
            serde_json::json!({"identity":status.identity,"revision":"1","op":"approve"}),
            serde_json::json!({"identity":status.identity,"revision":"1","op":"request_permission","authorized":true}),
            serde_json::json!({"identity":status.identity,"revision":"1","op":"query","roster_revision":"1"}),
        ] {
            assert!(Command::parse(&value.to_string()).is_err());
        }
    }
    #[test]
    fn catalog_rejects_same_tokens_and_unsupported_format_instead_of_defaulting() {
        let (_, mut catalog, _, _) = fixture();
        catalog.devices[1].device_token = catalog.devices[0].device_token.clone();
        assert!(catalog.validate().is_err());
        let (_, mut catalog, _, _) = fixture();
        catalog.devices[0].formats[0].sample_rate = 44_100;
        assert!(catalog.validate().is_err());
    }
    #[test]
    fn background_consent_is_approve_only_and_android_format_is_mono_exact() {
        let (status, mut catalog, _, _) = fixture();
        let approval = serde_json::json!({"identity":status.identity,"revision":"1","op":"approve",
            "roster_revision":"1","capture_token":"4".repeat(32),"capture_format_token":"6".repeat(32),
            "playback_token":"5".repeat(32),"playback_format_token":"7".repeat(32),"allow_background":true});
        assert_eq!(
            Command::parse(&approval.to_string())
                .unwrap()
                .allow_background,
            Some(true)
        );
        for op in [
            "query",
            "enumerate",
            "request_permission",
            "revoke",
            "retry_cleanup",
            "mute",
        ] {
            assert!(Command::parse(&serde_json::json!({"identity":status.identity,"revision":"1","op":op,"allow_background":false}).to_string()).is_err());
        }
        for device in &mut catalog.devices {
            for format in &mut device.formats {
                format.format_schema = "android_client_pcm_f32_48k_mono_v1".into();
                format.channels = 1;
            }
        }
        catalog.validate().unwrap();
        catalog.devices[0].formats[0].channels = 2;
        assert!(catalog.validate().is_err());
    }
    #[test]
    fn actual_android_catalog_serializer_fixture_remains_separate_from_desktop_fixtures() {
        let (_, mut catalog, _, _) = fixture();
        for device in &mut catalog.devices {
            for format in &mut device.formats {
                format.format_schema = "android_client_pcm_f32_48k_mono_v1".into();
                format.channels = 1;
            }
        }
        catalog.validate().unwrap();
        if let Ok(path) = std::env::var("NIKODESK_VOICE_ANDROID_FIXTURE_OUTPUT") {
            std::fs::write(path, serde_json::to_vec_pretty(&catalog).unwrap()).unwrap();
        }
    }
}
