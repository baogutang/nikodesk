//! Bounded client-only privacy wallpaper protocol. No file paths or URLs cross
//! the session. Capability advertisement and every request have separate checks.
use base::message_proto::{NikoPrivacyStyle, NikoPrivacyStyleResult};
use hbb_common::{anyhow::anyhow, bail, protobuf::Message, ResultType};
use serde::Deserialize;

pub(crate) const IMPL: &str = "nikodesk_privacy_style_v1";
pub(crate) const MAX_IMAGE_BYTES: usize = 4 * 1024 * 1024;
pub(crate) const MAX_FRAME_BYTES: usize = MAX_IMAGE_BYTES + 1024;

#[cfg(any(target_os = "macos", target_os = "windows"))]
pub(crate) fn native_helper_entry() -> Option<i32> {
    helper::helper_entry()
}

#[cfg(any(target_os = "macos", target_os = "windows"))]
#[path = "privacy_style/effects.rs"]
pub(crate) mod effects;
#[cfg(any(target_os = "macos", target_os = "windows"))]
#[path = "privacy_style/helper.rs"]
pub(crate) mod helper;
#[cfg(target_os = "macos")]
#[path = "privacy_style/macos.rs"]
pub(crate) mod macos;
#[cfg(any(target_os = "macos", target_os = "windows"))]
#[path = "privacy_style/native.rs"]
pub(crate) mod native;
#[cfg(windows)]
#[path = "privacy_style/windows.rs"]
pub(crate) mod windows;

pub(crate) fn validate(style: &NikoPrivacyStyle) -> ResultType<()> {
    if style.compute_size() > MAX_FRAME_BYTES as u64 {
        bail!("image_size_limit");
    }
    if style.request_id == 0
        || !(40..=100).contains(&style.brightness)
        || !(50..=200).contains(&style.intensity)
    {
        bail!("invalid_style_options");
    }
    let expected = match style.preset.as_str() {
        "snow" => "fog",
        "paper" => "light",
        "rain" => "rain",
        "custom" => style.effect.as_str(),
        _ => bail!("unknown_style"),
    };
    if style.effect != expected || !matches!(expected, "fog" | "light" | "rain" | "none") {
        bail!("unknown_effect");
    }
    if style.preset == "custom" {
        if style.image.is_empty() || style.image.len() > MAX_IMAGE_BYTES {
            bail!("image_size_limit");
        }
    } else if !style.image.is_empty() {
        bail!("preset_has_custom_image");
    }
    Ok(())
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Command {
    request_id: u32,
    preset: String,
    effect: String,
    motion: bool,
    brightness: u32,
    intensity: u32,
    hint: bool,
    clock: bool,
    #[serde(default)]
    image_base64: String,
}

pub(crate) fn parse(json: &str) -> ResultType<NikoPrivacyStyle> {
    if json.len() > MAX_IMAGE_BYTES * 4 / 3 + 2048 {
        bail!("image_size_limit");
    }
    let command: Command =
        serde_json::from_str(json).map_err(|_| anyhow!("invalid_style_options"))?;
    let image = if command.image_base64.is_empty() {
        Vec::new()
    } else {
        crate::decode64(&command.image_base64).map_err(|_| anyhow!("invalid_image"))?
    };
    let style = NikoPrivacyStyle {
        request_id: command.request_id,
        preset: command.preset,
        effect: command.effect,
        motion: command.motion,
        brightness: command.brightness,
        intensity: command.intensity,
        hint: command.hint,
        clock: command.clock,
        image: image.into(),
        ..Default::default()
    };
    validate(&style)?;
    Ok(style)
}

#[cfg(feature = "flutter")]
pub(crate) fn request(session_id: crate::flutter_ffi::SessionID, json: String) -> String {
    let result = (|| -> ResultType<u32> {
        use crate::client::Data;
        use base::message_proto::{Message, Misc, TogglePrivacyMode};
        let style = parse(&json)?;
        let id = style.request_id;
        let session = crate::flutter::sessions::get_session_by_session_id(&session_id)
            .ok_or_else(|| anyhow!("session_closed"))?;
        if !session.is_default() {
            bail!("context_unsupported");
        }
        {
            let lc = session.lc.read().map_err(|_| anyhow!("session_closed"))?;
            if !lc
                .peer_info
                .as_ref()
                .and_then(|pi| pi.features.as_ref())
                .is_some_and(|f| f.nikodesk_privacy_style_v1)
            {
                bail!("style_unsupported");
            }
            if lc.get_toggle_option("view-only")
                || !*session
                    .server_keyboard_enabled
                    .read()
                    .map_err(|_| anyhow!("session_closed"))?
            {
                bail!("input_permission_required");
            }
        }
        let mut misc = Misc::new();
        misc.set_toggle_privacy_mode(TogglePrivacyMode {
            impl_key: IMPL.into(),
            on: true,
            nikodesk_style: Some(style).into(),
            ..Default::default()
        });
        let mut message = Message::new();
        message.set_misc(misc);
        session
            .sender
            .read()
            .map_err(|_| anyhow!("session_closed"))?
            .as_ref()
            .ok_or_else(|| anyhow!("session_closed"))?
            .send(Data::Message(message))
            .map_err(|_| anyhow!("session_closed"))?;
        Ok(id)
    })();
    match result {
        Ok(id) => serde_json::json!({"ok":true,"status":"requested","request_id":id}).to_string(),
        Err(error) => serde_json::json!({"ok":false,"error":error.to_string()}).to_string(),
    }
}

#[cfg(feature = "flutter")]
pub(crate) fn complete(
    lc: &std::sync::Arc<std::sync::RwLock<crate::client::LoginConfigHandler>>,
    result: &NikoPrivacyStyleResult,
) {
    let payload = serde_json::json!({"request_id":result.request_id,"applied":result.applied,
        "active":result.active,"preset":result.preset,"error":result.error})
    .to_string();
    for session in crate::flutter::sessions::get_sessions() {
        if std::sync::Arc::ptr_eq(&session.lc, lc) {
            session
                .ui_handler
                .push_event("nikodesk_privacy_style", &[("payload", &payload)], &[]);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn style() -> NikoPrivacyStyle {
        NikoPrivacyStyle {
            request_id: 1,
            preset: "snow".into(),
            effect: "fog".into(),
            motion: true,
            brightness: 100,
            intensity: 120,
            hint: true,
            ..Default::default()
        }
    }
    #[test]
    fn accepts_only_selected_presets_and_custom() {
        let mut value = style();
        for (preset, effect) in [("snow", "fog"), ("paper", "light"), ("rain", "rain")] {
            value.preset = preset.into();
            value.effect = effect.into();
            assert!(validate(&value).is_ok());
        }
        for preset in ["ocean", "black", "https://host/image", "../image"] {
            value.preset = preset.into();
            assert!(validate(&value).is_err());
        }
        value.preset = "custom".into();
        value.effect = "none".into();
        value.image = vec![1].into();
        assert!(validate(&value).is_ok());
        value.image = vec![0; MAX_IMAGE_BYTES + 1].into();
        assert!(validate(&value).is_err());
    }
    #[test]
    fn frame_limit_includes_unknown_protocol_fields() {
        let mut value = style();
        value
            .special_fields
            .mut_unknown_fields()
            .add_length_delimited(100, vec![0; MAX_FRAME_BYTES]);
        assert!(validate(&value).is_err());
    }
    #[test]
    fn rejects_invalid_effects_ranges_and_unrequested_payloads() {
        let mut value = style();
        value.effect = "rain".into();
        assert!(validate(&value).is_err());
        value = style();
        value.brightness = 39;
        assert!(validate(&value).is_err());
        value = style();
        value.intensity = 201;
        assert!(validate(&value).is_err());
        value = style();
        value.request_id = 0;
        assert!(validate(&value).is_err());
        value = style();
        value.image = vec![1].into();
        assert!(validate(&value).is_err());
        assert!(parse(r#"{"path":"/private/file"}"#).is_err());
    }
}
