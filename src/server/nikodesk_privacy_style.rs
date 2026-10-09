//! Wallpaper updates stay on their authenticated desktop connection. A rejected
//! update never clears another owner's cover or replaces a running wallpaper.
use super::Connection;
use crate::{nikodesk::privacy_style, privacy_mode};
use base::{
    config::keys,
    message_proto::{BackNotification, Message, Misc, NikoPrivacyStyle, NikoPrivacyStyleResult},
};

impl Connection {
    pub(super) async fn apply_nikodesk_privacy_style(
        &mut self,
        impl_key: String,
        on: bool,
        style: NikoPrivacyStyle,
    ) {
        let request_id = style.request_id;
        let preset = style.preset.clone();
        let permitted = self.is_authed_remote_conn()
            && self.stream.is_secured()
            && self.privacy_mode
            && hbb_common::config::Config::get_option(keys::OPTION_ENABLE_PRIVACY_MODE) == "Y"
            && self.peer_keyboard_enabled()
            && impl_key == privacy_style::IMPL
            && on;
        let result = if !permitted {
            Err("privacy_permission_required".to_owned())
        } else if let Err(error) = privacy_style::validate(&style) {
            Err(error.to_string())
        } else if !privacy_style::native::supported() {
            Err("style_unsupported".to_owned())
        } else {
            let conn_id = self.inner.id;
            hbb_common::tokio::task::spawn_blocking(move || {
                if hbb_common::config::Config::get_option(keys::OPTION_ENABLE_PRIVACY_MODE) != "Y" {
                    hbb_common::bail!("privacy_permission_required");
                }
                let applied = privacy_mode::apply_nikodesk_style(conn_id, style)?;
                if hbb_common::config::Config::get_option(keys::OPTION_ENABLE_PRIVACY_MODE) != "Y" {
                    let _ = privacy_mode::turn_off_privacy(conn_id, None);
                    hbb_common::bail!("privacy_permission_required");
                }
                Ok(applied)
            })
            .await
            .map_err(|_| "privacy_worker_failed".to_owned())
            .and_then(|result| result.map_err(|error| error.to_string()))
        };
        let mut notice = BackNotification::new();
        notice.nikodesk_style = Some(NikoPrivacyStyleResult {
            request_id,
            preset,
            applied: matches!(result, Ok(true)),
            active: privacy_mode::get_privacy_mode_conn_id() == Some(self.inner.id),
            error: result.err().unwrap_or_default(),
            ..Default::default()
        })
        .into();
        let mut misc = Misc::new();
        misc.set_back_notification(notice);
        let mut message = Message::new();
        message.set_misc(misc);
        self.send(message).await;
    }
}
