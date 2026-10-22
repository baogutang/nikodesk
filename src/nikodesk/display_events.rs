//! Display reconfiguration and screen lock changes reported by macOS
//! (`macos_display_events.mm`). Without them the video service notices a new
//! resolution or arrangement only at its periodic display check, up to about
//! 1.3 s later (1 s in the video loop, behind a display list refreshed every
//! 300 ms). The periodic check always remains; the option
//! `nikodesk-display-events` = "N" turns the event path off.
use hbb_common::{config::Config, log};

const OPTION: &str = "nikodesk-display-events";

extern "C" {
    fn NikoDisplayEventsStart();
    fn NikoDisplayEventsRegistered() -> bool;
    fn NikoDisplayEventsGeneration() -> u64;
    fn NikoLockEventsGeneration() -> u64;
    fn NikoScreenLockedState() -> i32;
}

/// Follows one event counter and reports each change once.
pub(crate) struct Watch {
    source: fn() -> u64,
    seen: u64,
    enabled: bool,
}

impl Watch {
    fn new(source: fn() -> u64, enabled: bool) -> Self {
        Self {
            source,
            seen: source(),
            enabled,
        }
    }

    pub(crate) fn changed(&mut self) -> bool {
        if !self.enabled {
            return false;
        }
        let now = (self.source)();
        if now == self.seen {
            return false;
        }
        self.seen = now;
        true
    }
}

fn enabled() -> bool {
    let enabled = Config::get_option(OPTION) != "N";
    if enabled {
        unsafe { NikoDisplayEventsStart() };
    }
    enabled
}

pub(crate) fn display_watch() -> Watch {
    Watch::new(|| unsafe { NikoDisplayEventsGeneration() }, enabled())
}

pub(crate) fn lock_watch() -> Watch {
    Watch::new(|| unsafe { NikoLockEventsGeneration() }, enabled())
}

/// From the session dictionary when the observer started, then from lock
/// notifications; None before it started.
pub(crate) fn screen_locked() -> Option<bool> {
    match unsafe { NikoScreenLockedState() } {
        0 => Some(false),
        1 => Some(true),
        _ => None,
    }
}

pub(crate) fn log_lock_change() {
    log::info!(
        "Screen {} (display events registered: {})",
        match screen_locked() {
            Some(true) => "locked",
            Some(false) => "unlocked",
            None => "lock state unknown",
        },
        unsafe { NikoDisplayEventsRegistered() }
    );
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU64, Ordering};

    static COUNTER: AtomicU64 = AtomicU64::new(7);

    fn counter() -> u64 {
        COUNTER.load(Ordering::SeqCst)
    }

    #[test]
    fn each_change_is_reported_once_and_only_when_enabled() {
        let mut watch = Watch::new(counter, true);
        let mut off = Watch::new(counter, false);
        assert!(!watch.changed(), "the starting value is not a change");
        COUNTER.fetch_add(2, Ordering::SeqCst);
        assert!(watch.changed());
        assert!(!watch.changed());
        assert!(!off.changed());
    }

    #[test]
    fn the_lock_state_is_read_from_the_session() {
        unsafe { NikoDisplayEventsStart() };
        assert!(screen_locked().is_some());
    }
}
