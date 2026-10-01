use super::*;

impl Connection {
    pub(super) fn nikodesk_restart_allowed(&self) -> bool {
        self.authorized && !self.closed && self.stream.is_secured()
            && self.peer_keyboard_enabled()
            && self.authed_conn_type() == Some(AuthConnType::Remote)
            && self.niko_voice_namespace.is_some()
            && crate::nikodesk::background::worker_input_ready()
            && (!self.niko_voice_totp_required || self.niko_voice_totp_verified)
    }
    pub(super) async fn restart_nikodesk_device(&mut self, requested: bool) {
        if !requested { return; }
        let failure = if !self.restart || !self.nikodesk_restart_allowed() {
            Some("Remote restart is not allowed for this connection")
        } else {
            #[cfg(target_os="windows")]
            let result = system_shutdown::force_reboot();
            #[cfg(target_os="macos")]
            let result = system_shutdown::reboot();
            match result {
                Ok(()) => {log::info!("NikoDesk remote restart request accepted by the operating system"); None},
                Err(_) => {log::warn!("NikoDesk remote restart request was declined by the operating system");
                    Some("The remote operating system did not accept the restart request")},
            }
        };
        if let Some(reason) = failure {
            let mut message = Message::new();
            message.set_message_box(MessageBox {msgtype:"nikodesk-restart-failed".into(),
                title:"Restart remote device".into(), text:reason.into(), ..Default::default()});
            self.send(message).await;
        }
    }
}
