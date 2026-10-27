//! Locks this Mac for the controller's Lock Screen key and for the lock after
//! the last control session. Upstream presses Ctrl+Cmd+Q, which needs input
//! permission, a keyboard layout that maps the key, and the shortcut left
//! unchanged. This asks loginwindow directly, as the Apple menu's Lock Screen
//! does, then checks that the session really locked and presses the shortcut
//! only if it did not.
use base::message_proto::{ControlKey, KeyEvent, KeyboardMode};
use hbb_common::log;
use std::time::{Duration, Instant};

extern "C" {
    fn NikoLockScreenImmediate() -> i32;
    fn NikoScreenLockedNow() -> i32;
}

const POLLS: u32 = 20;
const PAUSE: Duration = Duration::from_millis(100);

#[derive(Debug, PartialEq)]
enum Outcome {
    Loginwindow,
    Shortcut,
    StillUnlocked,
}

fn locked() -> bool {
    unsafe { NikoScreenLockedNow() == 1 }
}

/// False leaves the request to upstream's shortcut.
pub(crate) fn lock() -> bool {
    if locked() {
        log::info!("Screen lock requested while already locked");
        return true;
    }
    let result = unsafe { NikoLockScreenImmediate() };
    if result == -1 {
        log::warn!("loginwindow lock unavailable; pressing Ctrl+Cmd+Q instead");
        return false;
    }
    let start = Instant::now();
    std::thread::spawn(move || match follow_up(locked, press_shortcut, POLLS, PAUSE) {
        Outcome::Loginwindow => log::info!(
            "Screen locked by loginwindow in {} ms (result {result})",
            start.elapsed().as_millis()
        ),
        Outcome::Shortcut => log::warn!(
            "loginwindow lock (result {result}) did not take within {} ms; Ctrl+Cmd+Q did",
            (POLLS * PAUSE).as_millis()
        ),
        Outcome::StillUnlocked => log::error!(
            "Screen still unlocked after the loginwindow lock (result {result}) and Ctrl+Cmd+Q"
        ),
    });
    true
}

fn follow_up(
    mut locked: impl FnMut() -> bool,
    shortcut: impl FnOnce(),
    polls: u32,
    pause: Duration,
) -> Outcome {
    let mut wait = || {
        (0..polls).any(|_| {
            let done = locked();
            if !done {
                std::thread::sleep(pause);
            }
            done
        })
    };
    if wait() {
        return Outcome::Loginwindow;
    }
    shortcut();
    if wait() {
        Outcome::Shortcut
    } else {
        Outcome::StillUnlocked
    }
}

// Upstream's shortcut, kept as the fallback.
fn press_shortcut() {
    let mut key_event = KeyEvent::new();
    key_event.set_chr('q' as _);
    key_event.modifiers.push(ControlKey::Meta.into());
    key_event.modifiers.push(ControlKey::Control.into());
    key_event.mode = KeyboardMode::Legacy.into();
    key_event.down = true;
    crate::server::input_service::handle_key(&key_event);
    key_event.down = false;
    crate::server::input_service::handle_key(&key_event);
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::Cell;

    #[test]
    fn the_shortcut_is_pressed_only_when_loginwindow_did_not_lock() {
        let polls = Cell::new(0);
        let pressed = Cell::new(false);
        let outcome = follow_up(
            || {
                polls.set(polls.get() + 1);
                polls.get() == 3
            },
            || pressed.set(true),
            5,
            Duration::ZERO,
        );
        assert_eq!(outcome, Outcome::Loginwindow);
        assert!(!pressed.get());

        let outcome = follow_up(|| pressed.get(), || pressed.set(true), 5, Duration::ZERO);
        assert_eq!(outcome, Outcome::Shortcut);

        let pressed = Cell::new(false);
        let outcome = follow_up(|| false, || pressed.set(true), 5, Duration::ZERO);
        assert_eq!(outcome, Outcome::StillUnlocked);
        assert!(pressed.get());
    }
}
