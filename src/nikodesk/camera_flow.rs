//! Local-only camera catalog and one connection's explicit camera grant.
use super::connection_capabilities::Identity;
use hbb_common::{anyhow::anyhow, bail, ResultType};
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Command {
    pub identity: Identity,
    pub revision: String,
    pub op: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub uid: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub roster_revision: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub format_token: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fps: Option<u32>,
}
fn counter(value: &str) -> bool {
    value
        .parse::<u64>()
        .map_or(false, |n| n > 0 && n.to_string() == value)
}
impl Command {
    pub(crate) fn validate(&self) -> ResultType<()> {
        if !self.identity.valid() || !counter(&self.revision) {
            bail!("invalid_camera_command");
        }
        let no_selection =
            self.roster_revision.is_none() && self.format_token.is_none() && self.fps.is_none();
        match self.op.as_str() {
            "enumerate" | "request_permission" | "deny" | "revoke" | "retry_cleanup" | "query"
                if no_selection && self.uid.is_none() =>
            {
                Ok(())
            }
            "probe"
                if no_selection
                    && self.uid.as_ref().map_or(false, |id| {
                        !id.is_empty() && id.len() <= 1024 && !id.chars().any(char::is_control)
                    }) =>
            {
                Ok(())
            }
            "approve"
                if self.uid.as_ref().map_or(false, |id| {
                    !id.is_empty() && id.len() <= 1024 && !id.chars().any(char::is_control)
                }) && self.roster_revision.as_deref().map_or(false, counter)
                    && self.format_token.as_ref().map_or(false, |token| {
                        token.len() == 32
                            && token
                                .bytes()
                                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
                    })
                    && self.fps.map_or(true, |fps| (1..=60).contains(&fps)) =>
            {
                Ok(())
            }
            _ => Err(anyhow!("invalid_camera_command").into()),
        }
    }
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub(crate) struct FormatInfo {
    pub format_token: String,
    pub width: u32,
    pub height: u32,
    pub format_schema: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub min_fps_milli: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub max_fps_milli: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub fps_num: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub fps_den: Option<u32>,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub(crate) struct SelectionInfo {
    pub uid: String,
    pub format_token: String,
    pub width: u32,
    pub height: u32,
    pub fps_num: u32,
    pub fps_den: u32,
    pub format_schema: String,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Status {
    pub identity: Identity,
    pub kind: String,
    pub phase: String,
    pub reason: String,
    pub resource_epoch: String,
    pub revision: String,
    pub selection: Option<SelectionInfo>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct DeviceInfo {
    pub uid: String,
    pub name: String,
    pub formats: Vec<FormatInfo>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Catalog {
    pub identity: Identity,
    pub revision: String,
    pub roster_revision: String,
    pub authorization: String,
    pub devices: Vec<DeviceInfo>,
    pub reason: String,
}
pub(crate) fn supported() -> bool {
    cfg!(any(target_os = "macos", target_os = "windows"))
}

pub(crate) fn accepts_cm_status(
    connection_id: i32,
    peer: &str,
    authorized: bool,
    camera: bool,
    disconnected: bool,
    old: Option<&Status>,
    status: &Status,
) -> bool {
    authorized
        && camera
        && !disconnected
        && status.identity.connection_id == connection_id
        && status.identity.valid()
        && status.identity.peer_id == peer
        && status.kind == "camera"
        && counter(&status.revision)
        && counter(&status.resource_epoch)
        && old.map_or(true, |old| {
            old.identity == status.identity
                && old.revision.parse::<u64>().ok() <= status.revision.parse::<u64>().ok()
                && old.resource_epoch.parse::<u64>().ok()
                    <= status.resource_epoch.parse::<u64>().ok()
        })
}

pub(crate) fn approved_peer_info(
    authenticated: &base::message_proto::PeerInfo,
    selection: &SelectionInfo,
) -> ResultType<base::message_proto::PeerInfo> {
    if selection.width == 0
        || selection.height == 0
        || selection.width > 1920
        || selection.height > 1080
    {
        bail!("camera_approved_dimensions_invalid");
    }
    let mut info = authenticated.clone();
    let mut additions: serde_json::Map<String, serde_json::Value> =
        serde_json::from_str(&info.platform_additions)
            .map_err(|_| anyhow!("camera_authenticated_metadata_invalid"))?;
    additions.insert("nikodesk_camera_pending".into(), false.into());
    info.platform_additions = serde_json::to_string(&additions)?;
    info.displays = vec![base::message_proto::DisplayInfo {
        name: "Approved camera".into(),
        width: selection.width as i32,
        height: selection.height as i32,
        scale: 1.0,
        online: true,
        ..Default::default()
    }];
    info.current_display = 0;
    info.sas_enabled = false;
    Ok(info)
}

#[cfg(any(target_os = "macos", target_os = "windows"))]
#[path = "camera_runtime.rs"]
pub(crate) mod runtime;
#[cfg(any(target_os = "macos", target_os = "windows"))]
pub(crate) use runtime::Flow;

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn camera_cm_initial_anchor_requires_authenticated_current_connection_and_rejects_late_identity(
    ) {
        let status = Status {
            identity: command().identity,
            kind: "camera".into(),
            phase: "Pending".into(),
            reason: "local_approval_required".into(),
            resource_epoch: "1".into(),
            revision: "1".into(),
            selection: None,
        };
        assert!(accepts_cm_status(
            1,
            "123456789",
            true,
            true,
            false,
            None,
            &status
        ));
        assert!(!accepts_cm_status(
            1,
            "123456789",
            false,
            true,
            false,
            None,
            &status
        ));
        assert!(!accepts_cm_status(
            1,
            "123456789",
            true,
            false,
            false,
            None,
            &status
        ));
        assert!(!accepts_cm_status(
            1,
            "123456789",
            true,
            true,
            true,
            None,
            &status
        ));
        assert!(!accepts_cm_status(
            2,
            "123456789",
            true,
            true,
            false,
            None,
            &status
        ));
        let mut late = status.clone();
        late.identity.namespace = "e".repeat(64);
        assert!(!accepts_cm_status(
            1,
            "123456789",
            true,
            true,
            false,
            Some(&status),
            &late
        ));
        late = status.clone();
        late.identity.connection_nonce = "e".repeat(32);
        assert!(!accepts_cm_status(
            1,
            "123456789",
            true,
            true,
            false,
            Some(&status),
            &late
        ));
        let mut current = status.clone();
        current.revision = "3".into();
        current.resource_epoch = "2".into();
        assert!(!accepts_cm_status(
            1,
            "123456789",
            true,
            true,
            false,
            Some(&current),
            &status
        ));
    }
    #[test]
    fn camera_approved_metadata_preserves_authenticated_public_identity_without_device_roster() {
        let base = base::message_proto::PeerInfo {
            version: "1.0.0".into(), platform: "Mac OS".into(), username: "public-synthetic-user".into(),
            hostname: "public-synthetic-host".into(), sas_enabled: true,
            features: Some(base::message_proto::Features { terminal: true, ..Default::default() }).into(),
            platform_additions: serde_json::json!({"support_view_camera":true,"nikodesk_camera_protocol":1,"nikodesk_camera_pending":true,"has_file_clipboard":false}).to_string(),
            ..Default::default()
        };
        let selection = SelectionInfo {
            uid: "secret-local-uid".into(),
            format_token: "a".repeat(32),
            width: 640,
            height: 480,
            fps_num: 30,
            fps_den: 1,
            format_schema: "mac-fps-range-v1".into(),
        };
        let approved = approved_peer_info(&base, &selection).unwrap();
        assert_eq!(approved.version, base.version);
        assert_eq!(approved.platform, base.platform);
        assert_eq!(approved.username, base.username);
        assert_eq!(approved.hostname, base.hostname);
        assert_eq!(approved.features, base.features);
        assert!(!approved.sas_enabled);
        assert_eq!(approved.displays[0].name, "Approved camera");
        let additions: serde_json::Value =
            serde_json::from_str(&approved.platform_additions).unwrap();
        assert_eq!(additions["has_file_clipboard"], false);
        assert_eq!(additions["nikodesk_camera_pending"], false);
        assert!(!format!("{approved:?}").contains(&selection.uid));
        assert!(!format!("{approved:?}").contains(&selection.format_token));
        assert!(base.displays.is_empty());
    }
    fn command() -> Command {
        Command {
            identity: Identity {
                connection_id: 1,
                namespace: "a".repeat(64),
                peer_id: "123456789".into(),
                connection_nonce: "b".repeat(32),
                request_nonce: "c".repeat(32),
                epoch: "1".into(),
            },
            revision: "1".into(),
            op: "enumerate".into(),
            uid: None,
            roster_revision: None,
            format_token: None,
            fps: None,
        }
    }
    #[test]
    fn camera_commands_reject_unbound_or_ambiguous_local_selection() {
        let mut command = command();
        assert!(command.validate().is_ok());
        command.uid = Some("camera-uid".into());
        assert!(command.validate().is_err());
        command.op = "probe".into();
        assert!(command.validate().is_ok());
        command.op = "approve".into();
        assert!(command.validate().is_err());
        command.roster_revision = Some("1".into());
        command.format_token = Some("a".repeat(32));
        assert!(command.validate().is_ok());
        command.fps = Some(0);
        assert!(command.validate().is_err());
        command.fps = Some(30);
        command.revision = "01".into();
        assert!(command.validate().is_err());
    }
    #[test]
    fn camera_commands_are_bounded_and_reject_unknown_fields() {
        let command = command();
        let mut value = serde_json::to_value(&command).unwrap();
        value["privileged"] = serde_json::json!(true);
        assert!(
            super::super::connection_capabilities::parse::<Command>(&value.to_string()).is_err()
        );
        assert!(
            super::super::connection_capabilities::parse::<Command>(&"x".repeat(4097)).is_err()
        );
    }
    #[test]
    fn pending_camera_status_contains_no_device_roster() {
        let status = Status {
            identity: command().identity,
            kind: "camera".into(),
            phase: "Pending".into(),
            reason: "local_approval_required".into(),
            resource_epoch: "1".into(),
            revision: "1".into(),
            selection: None,
        };
        let json = serde_json::to_value(status).unwrap();
        assert!(json["selection"].is_null());
        assert!(json.get("devices").is_none());
        assert!(json.get("uid").is_none());
    }
}

/// Camera control cannot enter shared display, recording, clipboard or audio handlers.
pub(crate) fn allows_camera_message(message: &base::message_proto::Message) -> bool {
    use base::message_proto::{message, misc};
    match message.union.as_ref() {
        Some(message::Union::TestDelay(_)) => true,
        Some(message::Union::Misc(misc)) => matches!(
            misc.union.as_ref(),
            Some(
                misc::Union::CloseReason(_)
                    | misc::Union::VideoReceived(_)
                    | misc::Union::ChatMessage(_)
                    | misc::Union::Option(_)
                    | misc::Union::CaptureDisplays(_)
                    | misc::Union::RefreshVideo(_)
                    | misc::Union::RefreshVideoDisplay(_)
                    | misc::Union::SwitchDisplay(_)
            )
        ),
        _ => false,
    }
}
pub(crate) fn is_camera_noop(message: &base::message_proto::Message) -> bool {
    use base::message_proto::{message, misc};
    matches!(message.union.as_ref(),Some(message::Union::Misc(m)) if matches!(m.union.as_ref(),Some(misc::Union::VideoReceived(_)|misc::Union::Option(_)|misc::Union::CaptureDisplays(_)|misc::Union::RefreshVideo(_)|misc::Union::RefreshVideoDisplay(_)|misc::Union::SwitchDisplay(_))))
}

#[cfg(any(target_os = "macos", target_os = "windows"))]
pub(crate) async fn requests_allowed() -> bool {
    runtime::requests_allowed().await
}
#[cfg(not(any(target_os = "macos", target_os = "windows")))]
pub(crate) async fn requests_allowed() -> bool {
    false
}

#[cfg(test)]
mod schema_fixtures {
    use super::*;
    #[test]
    fn camera_actual_serde_fixtures_for_controller_and_cm_contract() {
        let identity = Identity {
            connection_id: 123,
            namespace: "a".repeat(64),
            peer_id: "123456789".into(),
            connection_nonce: "b".repeat(32),
            request_nonce: "c".repeat(32),
            epoch: "1".into(),
        };
        let pending = Status {
            identity: identity.clone(),
            kind: "camera".into(),
            phase: "Pending".into(),
            reason: "local_approval_required".into(),
            resource_epoch: "1".into(),
            revision: "1".into(),
            selection: None,
        };
        let mac = Catalog {
            identity: identity.clone(),
            revision: "1".into(),
            roster_revision: "1".into(),
            authorization: "not_determined".into(),
            devices: vec![DeviceInfo {
                uid: "synthetic-camera-uid".into(),
                name: "Public synthetic camera".into(),
                formats: vec![FormatInfo {
                    format_token: "d".repeat(32),
                    width: 640,
                    height: 480,
                    format_schema: "mac-fps-range-v1".into(),
                    min_fps_milli: Some(15000),
                    max_fps_milli: Some(30000),
                    fps_num: None,
                    fps_den: None,
                }],
            }],
            reason: "camera_catalog_ready".into(),
        };
        let windows = Catalog {
            identity: identity.clone(),
            revision: "1".into(),
            roster_revision: "1".into(),
            authorization: "authorized".into(),
            devices: vec![DeviceInfo {
                uid: "synthetic-mf-symbolic-link".into(),
                name: "Public synthetic camera".into(),
                formats: vec![FormatInfo {
                    format_token: "e".repeat(32),
                    width: 640,
                    height: 480,
                    format_schema: "windows-native-v1".into(),
                    min_fps_milli: None,
                    max_fps_milli: None,
                    fps_num: Some(30000),
                    fps_den: Some(1001),
                }],
            }],
            reason: "camera_formats_ready".into(),
        };
        let output = serde_json::json!({"pending":pending,"mac_catalog":mac,"windows_catalog":windows,"queued": {"ok":true,"status":"queued","identity":identity,"revision":"1","reason":"camera_command_queued"}});
        assert!(output["mac_catalog"]["devices"][0]["formats"][0]
            .get("fps_num")
            .is_none());
        assert!(output["windows_catalog"]["devices"][0]["formats"][0]
            .get("min_fps_milli")
            .is_none());
        println!(
            "NIKO_CAMERA_SCHEMA_FIXTURE:{}",
            serde_json::to_string(&output).unwrap()
        );
    }
    #[test]
    fn camera_messages_cannot_mutate_global_display_input_record_or_audio_state() {
        use base::message_proto::{message, misc, Message, Misc};
        let mut key = Message::new();
        key.set_key_event(Default::default());
        assert!(!allows_camera_message(&key));
        let mut shot = Message::new();
        shot.set_screenshot_request(Default::default());
        assert!(!allows_camera_message(&shot));
        for union in [
            misc::Union::TogglePrivacyMode(Default::default()),
            misc::Union::ToggleVirtualDisplay(Default::default()),
            misc::Union::ClientRecordStatus(true),
            misc::Union::AudioFormat(Default::default()),
        ] {
            let mut message = Message::new();
            let mut misc = Misc::new();
            misc.union = Some(union);
            message.union = Some(message::Union::Misc(misc));
            assert!(!allows_camera_message(&message));
        }
        let mut misc = Misc::new();
        misc.set_video_received(true);
        let mut ack = Message::new();
        ack.set_misc(misc);
        assert!(allows_camera_message(&ack));
        assert!(is_camera_noop(&ack));
    }
}
