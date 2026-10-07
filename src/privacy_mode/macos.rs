use super::{PrivacyMode, PrivacyModeState};
use hbb_common::{anyhow::anyhow, ResultType};

extern "C" {
    fn MacSetPrivacyMode(on: bool) -> bool;
    #[cfg(feature="nikodesk")]
    fn NikoMacPrivacyModeActive() -> bool;
}

pub const PRIVACY_MODE_IMPL: &str = "privacy_mode_impl_macos";

pub struct PrivacyModeImpl {
    impl_key: String,
    conn_id: i32,
    #[cfg(feature = "nikodesk")]
    inactive_notified: bool,
}

impl PrivacyModeImpl {
    pub fn new(impl_key: &str) -> Self {
        Self {
            impl_key: impl_key.to_owned(),
            conn_id: 0,
            #[cfg(feature = "nikodesk")]
            inactive_notified: false,
        }
    }

    #[cfg(feature = "nikodesk")]
    fn heartbeat_with(
        &mut self,
        conn_id: i32,
        permitted: bool,
        active: impl FnOnce() -> bool,
        stop: impl FnOnce() -> bool,
    ) -> bool {
        if self.conn_id != conn_id || self.conn_id == 0 {
            return false;
        }
        if permitted && active() {
            return false;
        }
        // Protection has ended even if an unplugged display or external gamma
        // owner prevents full restoration. Notify once, retaining the owner and
        // saved native tables until cleanup actually succeeds.
        if stop() {
            self.conn_id = 0;
        }
        let notify = !self.inactive_notified;
        self.inactive_notified = true;
        notify
    }
}

impl PrivacyMode for PrivacyModeImpl {
    fn is_async_privacy_mode(&self) -> bool {
        false
    }

    fn init(&self) -> ResultType<()> {
        Ok(())
    }

    fn clear(&mut self) {
        unsafe {
            MacSetPrivacyMode(false);
        }
        self.conn_id = 0;
    }

    fn turn_on_privacy(&mut self, conn_id: i32) -> ResultType<bool> {
        if self.check_on_conn_id(conn_id)? {
            #[cfg(feature = "nikodesk")]
            if !unsafe { NikoMacPrivacyModeActive() } {
                return Err(anyhow!("Privacy mode is inactive; restoration is still pending"));
            }
            return Ok(true);
        }
        let success = unsafe { MacSetPrivacyMode(true) };
        if !success {
            return Err(anyhow!("Failed to turn on privacy mode"));
        }
        self.conn_id = conn_id;
        #[cfg(feature = "nikodesk")]
        { self.inactive_notified = false; }
        Ok(true)
    }

    fn turn_off_privacy(&mut self, conn_id: i32, _state: Option<PrivacyModeState>) -> ResultType<()> {
        // Note: The `_state` parameter is intentionally ignored on macOS.
        // On Windows, it's used to notify the connection manager about privacy mode state changes
        // (see win_topmost_window.rs). macOS currently has a simpler single-mode implementation
        // without the need for such cross-component state synchronization.
        self.check_off_conn_id(conn_id)?;
        let success = unsafe { MacSetPrivacyMode(false) };
        if !success {
            return Err(anyhow!("Failed to turn off privacy mode"));
        }
        self.conn_id = 0;
        Ok(())
    }

    fn pre_conn_id(&self) -> i32 {
        self.conn_id
    }

    fn get_impl_key(&self) -> &str {
        &self.impl_key
    }

    #[cfg(feature="nikodesk")]
    fn nikodesk_heartbeat(&mut self, conn_id:i32, permitted:bool)->bool {
        self.heartbeat_with(conn_id, permitted,
            || unsafe { NikoMacPrivacyModeActive() },
            || unsafe { MacSetPrivacyMode(false) })
    }
}

#[cfg(all(test, feature = "nikodesk"))]
mod tests {
    use super::*;
    use std::mem::ManuallyDrop;

    // Do not call the native Drop cleanup in pure state tests.
    fn owned() -> ManuallyDrop<PrivacyModeImpl> {
        let mut mode = ManuallyDrop::new(PrivacyModeImpl::new(PRIVACY_MODE_IMPL));
        mode.conn_id = 7;
        mode
    }

    #[test]
    fn loss_notifies_even_when_cleanup_fails_and_preserves_retry_owner() {
        let mut mode = owned();
        assert!(mode.heartbeat_with(7, true, || false, || false));
        assert_eq!(mode.pre_conn_id(), 7);
        assert!(mode.check_on_conn_id(8).is_err());
        assert!(!mode.heartbeat_with(7, true, || false, || false));
        assert_eq!(mode.pre_conn_id(), 7);
        assert!(!mode.heartbeat_with(7, true, || false, || true));
        assert_eq!(mode.pre_conn_id(), 0);
    }

    #[test]
    fn inactive_owner_cannot_be_cleaned_up_by_another_session() {
        let mut mode = owned();
        assert!(!mode.heartbeat_with(8, false, || panic!("must not read native state"),
            || panic!("must not stop another session")));
        assert_eq!(mode.pre_conn_id(), 7);
        assert!(!mode.inactive_notified);
    }

    #[test]
    fn permission_revocation_releases_without_claiming_active_protection() {
        let mut mode = owned();
        assert!(mode.heartbeat_with(7, false, || panic!("permission is already revoked"), || false));
        assert_eq!(mode.pre_conn_id(), 7);
        assert!(mode.inactive_notified);
    }

    #[test]
    fn active_mode_and_already_released_owner_do_not_notify() {
        let mut mode = owned();
        assert!(!mode.heartbeat_with(7, true, || true, || panic!("must remain active")));
        assert!(!mode.inactive_notified);
        assert!(mode.heartbeat_with(7, true, || false, || true));
        assert_eq!(mode.pre_conn_id(), 0);
        assert!(!mode.heartbeat_with(7, true, || panic!("no owner"), || panic!("no owner")));
    }
}

impl Drop for PrivacyModeImpl {
    fn drop(&mut self) {
        // Use the same cleanup logic as other code paths to keep conn_id consistent
        // and ensure all cleanup is centralized in one place.
        self.clear();
    }
}
