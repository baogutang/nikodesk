//! macOS input is queued twice. Recheck each ticket on the OS dispatch queue and
//! retain only inputs actually dispatched while the session still owns permission.
use crate::{common::input::*, server::input_service};
use base::message_proto::{key_event, KeyEvent, MouseEvent, PointerDeviceEvent};
use std::{
    collections::HashMap,
    sync::{
        atomic::{AtomicU64, Ordering},
        Mutex, Once, OnceLock,
    },
};

#[derive(Clone, PartialEq)]
enum Held {
    Key(KeyEvent),
    Mouse(MouseEvent),
}

impl Held {
    fn same_key(&self, other: &Self) -> bool {
        match (self, other) {
            (Self::Key(a), Self::Key(b)) => a.mode == b.mode && a.union == b.union,
            (Self::Mouse(a), Self::Mouse(b)) => a.mask >> 3 == b.mask >> 3,
            _ => false,
        }
    }

    fn release(self) {
        input_service::nikodesk_reset_event_flags();
        match self {
            Self::Key(event) => {
                // Preserve hotkey classification, but do not resubmit its flags
                // or run upstream lock-state/modifier reconciliation on cleanup.
                input_service::nikodesk_release_key(&event);
            }
            Self::Mouse(event) => {
                input_service::nikodesk_release_mouse(event.mask >> 3);
            }
        }
        input_service::nikodesk_reset_event_flags();
    }
}

struct State<K> {
    generation: u64,
    enabled: bool,
    closed: bool,
    held: Vec<K>,
    pending: Vec<K>,
}

/// While keys/buttons are held, one remote session owns the shared OS input
/// state. This also prevents raw and Legacy encodings of the same physical key
/// in two sessions from releasing one another during revoke/close.
struct Registry<K> {
    sessions: HashMap<u64, State<K>>,
    owner: Option<u64>,
}

impl<K> Default for Registry<K> {
    fn default() -> Self {
        Self {
            sessions: HashMap::new(),
            owner: None,
        }
    }
}

impl<K> Registry<K> {
    fn add(&mut self, id: u64, enabled: bool) {
        self.sessions.insert(
            id,
            State {
                generation: 0,
                enabled,
                closed: false,
                held: vec![],
                pending: vec![],
            },
        );
    }

    fn ticket(&self, id: u64) -> Option<u64> {
        self.sessions
            .get(&id)
            .filter(|s| s.enabled && !s.closed)
            .map(|s| s.generation)
    }

    fn permission(&mut self, id: u64, enabled: bool, close: bool) {
        if let Some(state) = self.sessions.get_mut(&id) {
            if !enabled || close {
                state.generation = state.generation.wrapping_add(1);
                state.pending.append(&mut state.held);
            }
            state.closed |= close;
            state.enabled = enabled && !state.closed;
        }
    }

    fn cleanup(&mut self, id: u64) -> Vec<K> {
        let Some(state) = self.sessions.get_mut(&id) else {
            return vec![];
        };
        let pending = std::mem::take(&mut state.pending);
        if state.held.is_empty() && self.owner == Some(id) {
            self.owner = None;
        }
        if state.closed {
            self.sessions.remove(&id);
        }
        pending
    }

    fn accept(
        &mut self,
        id: u64,
        generation: u64,
        held: Option<(K, bool)>,
        same_key: impl Fn(&K, &K) -> bool,
    ) -> bool {
        if self.ticket(id) != Some(generation) || self.owner.is_some_and(|owner| owner != id) {
            return false;
        }
        if let Some((key, down)) = held {
            let state = self.sessions.get_mut(&id).unwrap();
            let found = state.held.iter().position(|old| same_key(old, &key));
            if down {
                if found.is_none() {
                    if state.held.len() >= 256 {
                        return false;
                    }
                    state.held.push(key);
                }
                self.owner = Some(id);
            } else if let Some(index) = found {
                state.held.remove(index);
                if state.held.is_empty() && state.pending.is_empty() {
                    self.owner = None;
                }
            } else {
                // A peer cannot release a key/button it never pressed here.
                return false;
            }
        }
        true
    }
}

fn registry() -> &'static Mutex<Registry<Held>> {
    static REGISTRY: OnceLock<Mutex<Registry<Held>>> = OnceLock::new();
    REGISTRY.get_or_init(|| Mutex::new(Registry::default()))
}

pub(crate) enum Input {
    Key(KeyEvent, bool),
    Mouse(MouseEvent, i32, String, u32, bool, bool),
    Pointer(PointerDeviceEvent, i32),
}

impl Input {
    fn held(&self) -> Option<(Held, bool)> {
        match self {
            Input::Key(event, _)
                if matches!(
                    event.union,
                    Some(key_event::Union::Chr(_)) | Some(key_event::Union::ControlKey(_))
                ) =>
            {
                let mut release = event.clone();
                release.special_fields = Default::default();
                release.modifiers.truncate(16);
                Some((Held::Key(release), event.down))
            }
            Input::Mouse(event, _, _, _, true, _)
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
                    Held::Mouse(MouseEvent {
                        mask: event.mask,
                        ..Default::default()
                    }),
                    event.mask & MOUSE_TYPE_MASK == MOUSE_TYPE_DOWN,
                ))
            }
            _ => None,
        }
    }
}

#[derive(Clone)]
pub(crate) struct Session {
    id: u64,
}

impl Session {
    pub fn new(enabled: bool) -> Self {
        static NEXT: AtomicU64 = AtomicU64::new(1);
        static INIT: Once = Once::new();
        // The upstream per-worker reset would discard another live session's
        // virtual keyboard. NikoDesk initializes the shared device only once.
        INIT.call_once(input_service::reset_input_ondisconn);
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
        states.permission(self.id, enabled, close);
        if !enabled || close {
            let this = self.clone();
            // Enqueue while holding the same lock as ticket issuance. Even an
            // immediate regrant cannot put new input ahead of this cleanup.
            dispatch::Queue::main().exec_async(move || {
                let mut states = registry().lock().unwrap();
                for key in states.cleanup(this.id) {
                    key.release();
                }
            });
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
                input_service::nikodesk_key_sleep();
                if press {
                    event.down = false;
                    self.dispatch_one(generation, Input::Key(event, false));
                    input_service::nikodesk_key_sleep();
                }
            }
            other => self.dispatch_one(generation, other),
        }
    }

    fn dispatch_one(&self, generation: u64, input: Input) {
        let this = self.clone();
        dispatch::Queue::main().exec_async(move || {
            let mut states = registry().lock().unwrap();
            for key in states.cleanup(this.id) {
                key.release();
            }
            let held = input.held();
            if !states.accept(this.id, generation, held, Held::same_key) {
                return;
            }
            // Hold the state lock through actual OS dispatch. Revoke is ordered
            // after an already executing event and before every queued event.
            input_service::nikodesk_reset_event_flags();
            match input {
                Input::Key(event, _) => input_service::handle_key_(&event),
                Input::Mouse(event, conn, user, argb, simulate, show) => {
                    input_service::handle_mouse_(&event, conn, user, argb, simulate, show)
                }
                Input::Pointer(event, conn) => input_service::handle_pointer_(&event, conn),
            }
            input_service::nikodesk_reset_event_flags();
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use base::message_proto::{ControlKey, KeyboardMode};

    fn send(
        registry: &mut Registry<&'static str>,
        id: u64,
        ticket: u64,
        key: Option<(&'static str, bool)>,
    ) -> bool {
        registry.accept(id, ticket, key, |a, b| a == b)
    }

    #[test]
    fn nikodesk_revoke_rejects_queued_input_and_releases_only_executed() {
        let mut states = Registry::default();
        states.add(1, true);
        assert!(send(&mut states, 1, 0, Some(("A", true))));
        assert!(send(&mut states, 1, 0, Some(("mouse-left", true))));
        states.permission(1, false, false);
        assert!(!send(&mut states, 1, 0, Some(("queued-B", true))));
        assert_eq!(states.cleanup(1), vec!["A", "mouse-left"]);
        assert!(states.cleanup(1).is_empty());
    }

    #[test]
    fn nikodesk_regrant_never_accepts_an_old_ticket() {
        let mut states = Registry::default();
        states.add(1, true);
        states.permission(1, false, false);
        states.permission(1, true, false);
        let ticket = states.ticket(1).unwrap();
        assert_ne!(ticket, 0);
        assert!(!send(&mut states, 1, 0, Some(("old", true))));
        assert!(send(&mut states, 1, ticket, Some(("new", true))));
        assert!(states.cleanup(1).is_empty());
        assert!(send(&mut states, 1, ticket, Some(("new", false))));
    }

    #[test]
    fn nikodesk_close_cannot_release_or_inject_into_another_session() {
        let mut states = Registry::default();
        states.add(1, true);
        states.add(2, true);
        assert!(send(&mut states, 1, 0, Some(("shift", true))));
        assert!(!send(&mut states, 2, 0, Some(("shift-legacy", true))));
        states.permission(1, false, true);
        assert_eq!(states.cleanup(1), vec!["shift"]);
        assert!(send(&mut states, 2, 0, Some(("shift-legacy", true))));
        assert!(states.cleanup(1).is_empty());
        assert!(!send(&mut states, 1, 0, None));
        states.permission(1, true, false);
        assert_eq!(states.ticket(1), None);
        assert!(send(&mut states, 2, 0, Some(("shift-legacy", false))));
    }

    #[test]
    fn nikodesk_repeat_and_unowned_release_preserve_input_ownership() {
        let mut states = Registry::default();
        states.add(1, true);
        assert!(!send(&mut states, 1, 0, Some(("unknown", false))));
        assert!(send(&mut states, 1, 0, Some(("A", true))));
        assert!(send(&mut states, 1, 0, Some(("A", true))));
        states.permission(1, false, false);
        assert_eq!(states.cleanup(1), vec!["A"]);
        assert_eq!(states.owner, None);
    }

    #[test]
    fn nikodesk_held_input_state_is_bounded() {
        let mut states = Registry::default();
        states.add(1, true);
        for key in 0..256 {
            assert!(states.accept(1, 0, Some((key, true)), |a, b| a == b));
        }
        assert!(!states.accept(1, 0, Some((256, true)), |a, b| a == b));
        states.permission(1, false, true);
        assert_eq!(states.cleanup(1).len(), 256);
    }

    #[test]
    fn nikodesk_real_key_events_track_explicit_modifiers_in_all_modes() {
        for mode in [
            KeyboardMode::Legacy,
            KeyboardMode::Map,
            KeyboardMode::Translate,
        ] {
            let mut event = KeyEvent::new();
            event.mode = mode.into();
            event.down = true;
            if mode == KeyboardMode::Legacy {
                event.set_control_key(ControlKey::Control);
            } else {
                event.set_chr(59); // macOS left Control virtual keycode.
            }
            let mut states = Registry::default();
            states.add(1, true);
            assert!(states.accept(
                1,
                0,
                Input::Key(event.clone(), false).held(),
                Held::same_key
            ));
            event.down = false;
            assert!(states.accept(1, 0, Input::Key(event, false).held(), Held::same_key));
            states.permission(1, false, true);
            assert!(states.cleanup(1).is_empty());
        }
    }

    #[test]
    fn nikodesk_real_legacy_hotkey_preserves_release_classification() {
        let mut event = KeyEvent::new();
        event.mode = KeyboardMode::Legacy.into();
        event.set_chr('c' as u32);
        event.down = true;
        event.modifiers.push(ControlKey::Control.into());
        let Some((Held::Key(release), true)) = Input::Key(event, false).held() else {
            panic!("Legacy hotkey must have a directed release");
        };
        assert_eq!(release.chr(), 'c' as u32);
        assert_eq!(release.modifiers, vec![ControlKey::Control.into()]);
    }

    #[test]
    fn nikodesk_real_mouse_release_has_no_inherited_modifier_flags() {
        let mut event = MouseEvent::new();
        event.mask = (MOUSE_BUTTON_LEFT << 3) | MOUSE_TYPE_DOWN;
        event.modifiers.push(ControlKey::Shift.into());
        let input = Input::Mouse(event.clone(), 7, String::new(), 0, true, false);
        let Some((Held::Mouse(release), true)) = input.held() else {
            panic!("Mouse down must have a directed release");
        };
        assert!(release.modifiers.is_empty());
        event.mask = MOUSE_TYPE_MOVE;
        assert!(Input::Mouse(event, 7, String::new(), 0, true, false)
            .held()
            .is_none());
    }
}
