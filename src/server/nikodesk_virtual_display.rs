use super::*;
use crate::nikodesk::virtual_display::{self, Owner};

impl Connection {
    fn virtual_display_role(&self) -> bool {
        self.authorized && !self.closed && self.stream.is_secured()
            && self.authed_conn_type() == Some(AuthConnType::Remote) && self.peer_keyboard_enabled()
            && (!self.niko_voice_totp_required || self.niko_voice_totp_verified)
            && crate::nikodesk::background::worker_input_ready()
    }
    pub(super) async fn toggle_nikodesk_virtual_display(&mut self, request: ToggleVirtualDisplay) {
        let result = if request.on && (!self.virtual_display_role()
            || Config::get_option("nikodesk-allow-virtual-display") != "Y") {
            Err("virtual_display_not_allowed")
        } else if request.on && privacy_mode::get_privacy_mode_conn_id().is_some() {
            Err("privacy_mode_active")
        } else {
            if self.niko_virtual_owner.is_none() && request.on {
                self.niko_virtual_owner = self.niko_voice_namespace.clone().zip(self.niko_voice_nonce.clone())
                    .and_then(|(namespace, nonce)| Owner::new(self.inner.id(), namespace, nonce));
            }
            if let Some(owner) = self.niko_virtual_owner.clone() {
                tokio::task::spawn_blocking(move || virtual_display::toggle(&owner, request.display, request.on))
                    .await.unwrap_or(Err("worker_failed"))
            } else if request.on { Err("private_server_unavailable") } else { Ok(()) }
        };
        if let Err(reason) = result {
            let mut message = Message::new();
            message.set_message_box(MessageBox { msgtype: "nook-nocancel-hasclose".into(), title: "Virtual display".into(),
                text: match reason {
                    "background_service_required" => "Use the NikoDesk unattended service machine ID, or a client explicitly run with Administrator access locally, for Windows virtual displays.",
                    "virtual_display_driver_unavailable" => "The signed virtual-display driver is unavailable. Install it locally before creating a virtual display.",
                    "virtual_display_not_allowed" => "Allow virtual displays on the controlled computer and grant keyboard control first.",
                    "display_owned_by_another_connection" => "This virtual display belongs to another connection.",
                    "cleanup_pending" => "Virtual display removal is not confirmed. Retry removal before creating another display.",
                    "backend_unavailable" => "Virtual displays are unavailable on this operating system.",
                    _ => "Virtual display change was not confirmed."
                }.into(), ..Default::default() });
            self.send(message).await;
        }
    }
    pub(super) fn revoke_nikodesk_virtual_displays(&mut self) {
        if let Some(owner) = self.niko_virtual_owner.take() { virtual_display::release(owner); }
    }
    pub(super) fn check_nikodesk_virtual_display_permission(&mut self) {
        if self.niko_virtual_owner.is_some() && (!self.virtual_display_role()
            || Config::get_option("nikodesk-allow-virtual-display") != "Y") {
            self.revoke_nikodesk_virtual_displays();
        }
    }
}
