use super::*;

impl LoginConfigHandler {
    /// The controlled side ties its privacy screen to the connection that
    /// turned it on, so every new connection starts with it off. The stored
    /// per-peer flag only reflects the last notification received; after a
    /// session that ended abruptly it still says "on", which would show the
    /// screen as protected and skip the automatic request. Forget it before
    /// the first state is shown; only a confirmation from this connection may
    /// set it again.
    pub(crate) fn nikodesk_forget_privacy_mode(&mut self) {
        if !self.config.privacy_mode.v && !self.load_config().privacy_mode.v {
            return;
        }
        let mut config = self.load_config();
        config.privacy_mode.v = false;
        self.save_config(config);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_new_connection_does_not_inherit_a_stale_privacy_screen() {
        let mut handler = LoginConfigHandler::default();
        handler.id = "123456789".to_owned();
        handler.config.privacy_mode.v = true;
        assert!(handler.get_toggle_option("privacy-mode"));
        handler.nikodesk_forget_privacy_mode();
        assert!(!handler.get_toggle_option("privacy-mode"));
    }
}
