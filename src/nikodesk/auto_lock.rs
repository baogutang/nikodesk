//! Receiver-side lock policy; never tracks file, camera, terminal or tunnel sessions.
#[path = "auto_lock_state.rs"]
mod state;

use hbb_common::{config::Config, log, tokio};
use state::ControlSessions;
use std::{sync::Mutex, time::Duration};

pub(crate) const OPTION: &str = "nikodesk-lock-on-last-control";
const GRACE: Duration = Duration::from_secs(5);
lazy_static::lazy_static! {
    static ref SESSIONS: Mutex<ControlSessions> = Mutex::new(ControlSessions::default());
}

fn enabled() -> bool {
    Config::get_option(OPTION) == "Y"
}

pub(crate) fn register(id: i32, controls: bool) {
    if let Ok(mut sessions) = SESSIONS.lock() {
        sessions.register(id, controls);
    }
}

pub(crate) fn permission(id: i32, controls: bool) {
    if let Ok(mut sessions) = SESSIONS.lock() {
        sessions.permission(id, controls);
    }
}

pub(crate) fn forget(id: i32) {
    if let Ok(mut sessions) = SESSIONS.lock() {
        sessions.remove(id, false);
    }
}

pub(crate) fn cancel_pending() {
    if let Ok(mut sessions) = SESSIONS.lock() { sessions.cancel_pending(); }
}

pub(crate) fn disconnected(id: i32, orderly: bool, explicit_request: bool) {
    // A machine policy also covers an unexpected network disconnect. The
    // registry still requires a previously authenticated keyboard session.
    let requested = enabled() || orderly && explicit_request;
    let ticket = SESSIONS
        .lock()
        .ok()
        .and_then(|mut sessions| sessions.remove(id, requested));
    let (Some(ticket), Some(input)) = (ticket, InputSnapshot::read()) else {
        return;
    };
    tokio::spawn(async move {
        tokio::time::sleep(GRACE).await;
        if (!explicit_request && !enabled()) || !input.unchanged() {
            return;
        }
        let pending = SESSIONS
            .lock()
            .map(|sessions| sessions.pending(ticket))
            .unwrap_or(false);
        if pending {
            // The platform path targets the current interactive session. No lock or
            // settings guard is held across the native operation or the grace delay.
            log::info!("NikoDesk requesting screen lock after the last control session");
            crate::server::input_service::lock_screen().await;
        }
    });
}

#[cfg(target_os = "windows")]
struct InputSnapshot(u32);

#[cfg(target_os = "windows")]
impl InputSnapshot {
    fn read() -> Option<Self> {
        use winapi::um::winuser::{GetLastInputInfo, LASTINPUTINFO};
        let mut input = LASTINPUTINFO {
            cbSize: std::mem::size_of::<LASTINPUTINFO>() as u32,
            dwTime: 0,
        };
        (unsafe { GetLastInputInfo(&mut input) } != 0).then_some(Self(input.dwTime))
    }
    fn unchanged(&self) -> bool {
        Self::read().map_or(false, |latest| latest.0 == self.0)
    }
}

#[cfg(target_os = "macos")]
struct InputSnapshot {
    at: std::time::Instant,
    idle: f64,
}

#[cfg(target_os = "macos")]
impl InputSnapshot {
    fn read() -> Option<Self> {
        #[link(name = "CoreGraphics", kind = "framework")]
        extern "C" {
            fn CGEventSourceSecondsSinceLastEventType(state: i32, event_type: u32) -> f64;
        }
        let at = std::time::Instant::now();
        // Combined login-session input, including mouse, keyboard and tablet.
        let idle = unsafe { CGEventSourceSecondsSinceLastEventType(0, u32::MAX) };
        (idle.is_finite() && idle >= 0.0).then_some(Self { at, idle })
    }
    fn unchanged(&self) -> bool {
        Self::read().map_or(false, |latest| {
            state::idle_unchanged(
                self.idle,
                latest.idle,
                latest.at.duration_since(self.at).as_secs_f64(),
            )
        })
    }
}
