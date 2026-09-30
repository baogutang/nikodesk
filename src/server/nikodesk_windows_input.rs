use super::{
    handle_mouse_, has_hotkey_modifiers, nikodesk_windows_dispatch_key,
    nikodesk_windows_dispatch_pointer, nikodesk_windows_release_key,
    nikodesk_windows_release_mouse,
};
use crate::common::input::*;
use base::message_proto::{key_event, ControlKey, KeyEvent, MouseEvent, PointerDeviceEvent};
use std::sync::{
    atomic::{AtomicU64, Ordering},
    Mutex, OnceLock,
};

#[path = "nikodesk_input_state.rs"]
mod state;
use state::Registry;

#[derive(Clone)]
enum Held {
    Key(KeyEvent, bool),
    Mouse(i32),
}

impl Held {
    fn same_key(&self, other: &Self) -> bool {
        match (self, other) {
            (Self::Key(a, _), Self::Key(b, _)) => a.mode == b.mode && a.union == b.union,
            (Self::Mouse(a), Self::Mouse(b)) => a == b,
            _ => false,
        }
    }

    fn release(self) {
        match self {
            Self::Key(event, hotkey) => nikodesk_windows_release_key(&event, hotkey),
            Self::Mouse(button) => nikodesk_windows_release_mouse(button),
        }
    }
}

pub(crate) enum Input {
    Key(KeyEvent, bool),
    Mouse(MouseEvent, i32, String, u32, bool, bool),
    Pointer(PointerDeviceEvent, i32),
}

impl Input {
    fn held(&self) -> Option<(Held, bool)> {
        match self {
            Self::Key(event, _)
                if matches!(event.union,
                Some(key_event::Union::ControlKey(key)) if matches!(key.enum_value(),
                    Ok(ControlKey::CtrlAltDel | ControlKey::LockScreen))) =>
            {
                None
            }
            Self::Key(event, _)
                if matches!(
                    event.union,
                    Some(key_event::Union::Chr(_))
                        | Some(key_event::Union::ControlKey(_))
                        | Some(key_event::Union::Win2winHotkey(_))
                ) =>
            {
                let mut release = event.clone();
                release.special_fields = Default::default();
                release.modifiers.clear();
                Some((Held::Key(release, has_hotkey_modifiers(event)), event.down))
            }
            Self::Mouse(event, _, _, _, true, _)
                if matches!(
                    event.mask & MOUSE_TYPE_MASK,
                    MOUSE_TYPE_DOWN | MOUSE_TYPE_UP
                ) && matches!(
                    event.mask >> 3,
                    MOUSE_BUTTON_LEFT
                        | MOUSE_BUTTON_RIGHT
                        | MOUSE_BUTTON_WHEEL
                        | MOUSE_BUTTON_BACK
                        | MOUSE_BUTTON_FORWARD
                ) =>
            {
                Some((
                    Held::Mouse(event.mask >> 3),
                    event.mask & MOUSE_TYPE_MASK == MOUSE_TYPE_DOWN,
                ))
            }
            _ => None,
        }
    }
}

fn registry() -> &'static Mutex<Registry<Held>> {
    static REGISTRY: OnceLock<Mutex<Registry<Held>>> = OnceLock::new();
    REGISTRY.get_or_init(|| Mutex::new(Registry::default()))
}

pub(crate) fn revoke_worker_inputs() {
    let mut states = registry().lock().unwrap();
    for held in states.close_all() {
        held.release();
    }
}

#[derive(Clone)]
pub(crate) struct Session {
    id: u64,
}

impl Session {
    pub fn new(enabled: bool) -> Self {
        static NEXT: AtomicU64 = AtomicU64::new(1);
        let id = NEXT.fetch_add(1, Ordering::Relaxed);
        registry().lock().unwrap().add(id, enabled);
        Self { id }
    }

    pub fn ticket(&self) -> Option<u64> {
        registry().lock().unwrap().ticket(self.id)
    }

    pub fn set_enabled(&self, enabled: bool) {
        self.permission(enabled, false);
    }

    pub fn close(&self) {
        self.permission(false, true);
    }

    fn permission(&self, enabled: bool, close: bool) {
        let mut states = registry().lock().unwrap();
        for held in states.permission(self.id, enabled, close) {
            // Keep ownership exclusive until OS key/button release has completed.
            held.release();
        }
    }

    pub fn dispatch(&self, generation: u64, input: Input) {
        match input {
            Input::Key(mut event, press) => {
                event.press = false;
                if press {
                    event.down = true;
                }
                self.dispatch_one(generation, Input::Key(event.clone(), false));
                if press {
                    event.down = false;
                    self.dispatch_one(generation, Input::Key(event, false));
                }
            }
            other => self.dispatch_one(generation, other),
        }
    }

    fn dispatch_one(&self, generation: u64, input: Input) {
        let mut states = registry().lock().unwrap();
        if !crate::nikodesk::background::worker_input_ready() {
            for held in states.permission(self.id, false, false) { held.release(); }
            return;
        }
        if !states.accept(self.id, generation, input.held(), Held::same_key) {
            return;
        }
        // Windows injection is synchronous here. Holding this lock orders revoke
        // after an already executing event and before every remaining queued event.
        match input {
            Input::Key(event, _) => nikodesk_windows_dispatch_key(&event),
            Input::Mouse(event, conn, user, argb, simulate, show) => {
                handle_mouse_(&event, conn, user, argb, simulate, show);
            }
            Input::Pointer(event, conn) => nikodesk_windows_dispatch_pointer(&event, conn),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use base::message_proto::{ControlKey, KeyboardMode};

    #[test]
    fn nikodesk_windows_real_key_events_keep_mode_and_clear_cleanup_modifiers() {
        for mode in [
            KeyboardMode::Legacy,
            KeyboardMode::Map,
            KeyboardMode::Translate,
        ] {
            let mut event = KeyEvent::new();
            event.mode = mode.into();
            event.down = true;
            event.modifiers.push(ControlKey::Control.into());
            event.set_chr(30);
            let (Held::Key(release, hotkey), down) =
                Input::Key(event.clone(), false).held().unwrap()
            else {
                panic!("key is not tracked");
            };
            assert!(down);
            assert!(hotkey);
            assert!(release.modifiers.is_empty());
            assert_eq!(release.mode, event.mode);
            assert_eq!(release.union, event.union);
            let mut up = event.clone();
            up.down = false;
            let (held, down) = Input::Key(up, false).held().unwrap();
            assert!(!down);
            assert!(Held::Key(release, hotkey).same_key(&held));
        }
    }

    #[test]
    fn nikodesk_windows_only_tracks_simulated_mouse_buttons() {
        for button in [
            MOUSE_BUTTON_LEFT,
            MOUSE_BUTTON_RIGHT,
            MOUSE_BUTTON_WHEEL,
            MOUSE_BUTTON_BACK,
            MOUSE_BUTTON_FORWARD,
        ] {
            let down = MouseEvent {
                mask: (button << 3) | MOUSE_TYPE_DOWN,
                ..Default::default()
            };
            assert!(
                matches!(Input::Mouse(down.clone(), 1, String::new(), 0, true, false).held(),
                Some((Held::Mouse(found), true)) if found == button)
            );
            assert!(Input::Mouse(down, 1, String::new(), 0, false, false)
                .held()
                .is_none());
            let up = MouseEvent {
                mask: (button << 3) | MOUSE_TYPE_UP,
                ..Default::default()
            };
            assert!(
                matches!(Input::Mouse(up, 1, String::new(), 0, true, false).held(),
                Some((Held::Mouse(found), false)) if found == button)
            );
        }
        let scroll = MouseEvent {
            mask: MOUSE_TYPE_WHEEL,
            ..Default::default()
        };
        assert!(Input::Mouse(scroll, 1, String::new(), 0, true, false)
            .held()
            .is_none());
    }

    #[test]
    fn nikodesk_windows_hotkey_message_is_owned_and_cleanup_retains_its_code() {
        let mut event = KeyEvent::new();
        event.mode = KeyboardMode::Translate.into();
        event.down = true;
        event.set_win2win_hotkey((0x41 << 16) | 0x61);
        let (Held::Key(release, _), down) = Input::Key(event.clone(), false).held().unwrap() else {
            panic!("Windows hotkey is not tracked");
        };
        assert!(down);
        assert_eq!(release.win2win_hotkey(), event.win2win_hotkey());
        let mut states = Registry::default();
        states.add(1, true);
        states.add(2, true);
        assert!(states.accept(
            1,
            0,
            Some((Held::Key(release.clone(), false), true)),
            Held::same_key
        ));
        assert!(!states.accept(
            2,
            0,
            Some((Held::Key(release, false), false)),
            Held::same_key
        ));
        assert_eq!(states.permission(1, false, true).len(), 1);
    }

    #[test]
    fn nikodesk_windows_one_shot_actions_never_reserve_held_input_ownership() {
        for key in [ControlKey::CtrlAltDel, ControlKey::LockScreen] {
            let mut event = KeyEvent::new();
            event.mode = KeyboardMode::Legacy.into();
            event.down = true;
            event.set_control_key(key);
            let input = Input::Key(event, false);
            assert!(input.held().is_none());
            let mut states = Registry::default();
            states.add(1, true);
            states.add(2, true);
            assert!(states.accept(1, 0, input.held(), Held::same_key));
            assert!(states.accept(2, 0, input.held(), Held::same_key));
            assert!(states.permission(1, false, true).is_empty());
        }
    }
}
