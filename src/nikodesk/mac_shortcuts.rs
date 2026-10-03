//! Selected Windows/Linux Control chords on a Mac peer, without remapping Spaces.
use crate::{
    client::{Data, Interface},
    ui_session_interface::{InvokeUiSession, Session},
};
use base::message_proto::{key_event, ControlKey, KeyEvent, KeyboardMode, Message};
use std::collections::{BTreeMap, BTreeSet};

pub(crate) const OPTION: &str = "nikodesk-mac-shortcuts";
pub(crate) const ACTION_PREFIX: &str = "NikoShortcut:";

#[derive(Clone, Copy, Debug, Eq, PartialEq, Ord, PartialOrd)]
struct KeyId(i32, u32, bool);

fn key_id(event: &KeyEvent) -> Option<KeyId> {
    match event.union.as_ref()? {
        key_event::Union::Chr(code) => Some(KeyId(
            event.mode.value(),
            if event.mode.enum_value() == Ok(KeyboardMode::Legacy) {
                char::from_u32(*code)
                    .map(|c| c.to_ascii_lowercase() as u32)
                    .unwrap_or(*code)
            } else {
                *code
            },
            false,
        )),
        key_event::Union::ControlKey(key) => {
            Some(KeyId(event.mode.value(), key.value() as u32, true))
        }
        _ => None,
    }
}

fn key(event: &KeyEvent) -> rdev::Key {
    use rdev::Key;
    match event.union.as_ref() {
        Some(key_event::Union::Chr(code)) if event.mode.enum_value() == Ok(KeyboardMode::Map) => {
            rdev::macos_key_from_code(*code as _)
        }
        Some(key_event::Union::Chr(code))
            if event.mode.enum_value() == Ok(KeyboardMode::Legacy) =>
        {
            match char::from_u32(*code).map(|c| c.to_ascii_lowercase()) {
                Some('c') => Key::KeyC,
                Some('v') => Key::KeyV,
                Some('x') => Key::KeyX,
                Some('a') => Key::KeyA,
                Some('z') => Key::KeyZ,
                Some('s') => Key::KeyS,
                Some('f') => Key::KeyF,
                Some('p') => Key::KeyP,
                Some('r') => Key::KeyR,
                _ => Key::Unknown(*code),
            }
        }
        Some(key_event::Union::ControlKey(code)) => match code.enum_value_or_default() {
            ControlKey::Control => Key::ControlLeft,
            ControlKey::RControl => Key::ControlRight,
            ControlKey::Meta => Key::MetaLeft,
            ControlKey::RWin => Key::MetaRight,
            ControlKey::Alt => Key::Alt,
            ControlKey::RAlt => Key::AltGr,
            ControlKey::Shift => Key::ShiftLeft,
            ControlKey::RShift => Key::ShiftRight,
            _ => Key::Unknown(code.value() as _),
        },
        _ => Key::Unknown(u32::MAX),
    }
}

fn control(key: rdev::Key) -> bool {
    matches!(key, rdev::Key::ControlLeft | rdev::Key::ControlRight)
}

fn blocking_modifier(key: rdev::Key) -> bool {
    matches!(
        key,
        rdev::Key::Alt
            | rdev::Key::AltGr
            | rdev::Key::MetaLeft
            | rdev::Key::MetaRight
            | rdev::Key::ShiftLeft
            | rdev::Key::ShiftRight
    )
}

fn selected(key: rdev::Key) -> bool {
    matches!(
        key,
        rdev::Key::KeyC
            | rdev::Key::KeyV
            | rdev::Key::KeyX
            | rdev::Key::KeyA
            | rdev::Key::KeyZ
            | rdev::Key::KeyS
            | rdev::Key::KeyF
            | rdev::Key::KeyP
            | rdev::Key::KeyR
    )
}

fn release(event: &KeyEvent) -> KeyEvent {
    let mut event = event.clone();
    event.down = false;
    event.press = false;
    event.modifiers.clear();
    event
}

fn command_event(mode: KeyboardMode, down: bool) -> Option<KeyEvent> {
    let mut event = KeyEvent::new();
    event.mode = mode.into();
    event.down = down;
    if mode == KeyboardMode::Map {
        event.set_chr(rdev::macos_keycode_from_key(rdev::Key::MetaLeft)? as _);
    } else {
        event.set_control_key(ControlKey::Meta);
    }
    if down {
        event.modifiers.push(ControlKey::Meta.into());
    }
    Some(event)
}

fn as_command(event: &KeyEvent) -> KeyEvent {
    let mut event = event.clone();
    event.modifiers.retain(|k| {
        !matches!(
            k.enum_value_or_default(),
            ControlKey::Control | ControlKey::RControl
        )
    });
    if !event.modifiers.contains(&ControlKey::Meta.into()) {
        event.modifiers.push(ControlKey::Meta.into());
    }
    event
}

#[derive(Default)]
pub(crate) struct MacShortcutState {
    controls: BTreeMap<KeyId, KeyEvent>,
    blockers: BTreeSet<KeyId>,
    active: BTreeMap<KeyId, KeyEvent>,
    suppressed: BTreeSet<KeyId>,
    command: Option<KeyEvent>,
    mode: Option<i32>,
}

impl MacShortcutState {
    fn finish(&mut self, restore_control: bool, output: &mut Vec<KeyEvent>) {
        for (id, event) in std::mem::take(&mut self.active) {
            output.push(release(&event));
            self.suppressed.insert(id);
        }
        if let Some(event) = self.command.take() {
            output.push(release(&event));
            if restore_control {
                output.extend(self.controls.values().cloned());
            }
        }
    }

    pub(crate) fn reset(&mut self) -> Vec<KeyEvent> {
        let mut output = Vec::new();
        self.finish(false, &mut output);
        output.extend(self.controls.values().map(release));
        *self = Self::default();
        output
    }

    pub(crate) fn process(&mut self, event: &KeyEvent, automatic: bool) -> Vec<KeyEvent> {
        let mut output = Vec::new();
        if self.mode.is_some_and(|mode| mode != event.mode.value()) {
            output.extend(self.reset());
        }
        self.mode = Some(event.mode.value());
        if !automatic
            || !matches!(
                event.mode.enum_value(),
                Ok(KeyboardMode::Map | KeyboardMode::Legacy)
            )
        {
            output.extend(self.reset());
            output.push(event.clone());
            return output;
        }
        let Some(id) = key_id(event) else {
            self.finish(true, &mut output);
            output.push(event.clone());
            return output;
        };
        let key = key(event);
        if control(key) {
            if event.down {
                self.controls.insert(id, event.clone());
            } else {
                self.controls.remove(&id);
            }
            if self.command.is_some() {
                if self.controls.is_empty() {
                    self.finish(false, &mut output);
                }
            } else {
                output.push(event.clone());
            }
            return output;
        }
        if blocking_modifier(key) {
            if event.down {
                self.finish(true, &mut output);
                self.blockers.insert(id);
            } else {
                self.blockers.remove(&id);
            }
            output.push(event.clone());
            return output;
        }
        if self.suppressed.contains(&id) {
            if !event.down && !event.press {
                self.suppressed.remove(&id);
            }
            return output;
        }
        if !event.down && !event.press {
            if let Some(active) = self.active.remove(&id) {
                let mut up = active;
                up.down = false;
                up.modifiers = as_command(event).modifiers;
                output.push(up);
                if self.active.is_empty() {
                    self.finish(true, &mut output);
                }
                return output;
            }
        }
        let modifier_control = event.modifiers.iter().any(|k| {
            matches!(
                k.enum_value_or_default(),
                ControlKey::Control | ControlKey::RControl
            )
        });
        let blocked = !self.blockers.is_empty()
            || event.modifiers.iter().any(|k| {
                matches!(
                    k.enum_value_or_default(),
                    ControlKey::Alt
                        | ControlKey::RAlt
                        | ControlKey::Meta
                        | ControlKey::RWin
                        | ControlKey::Shift
                        | ControlKey::RShift
                )
            });
        if (event.down || event.press)
            && selected(key)
            && (!self.controls.is_empty() || modifier_control)
            && !blocked
        {
            let mapped = as_command(event);
            if event.press {
                if !self.active.contains_key(&id) {
                    self.finish(true, &mut output);
                }
                output.push(mapped);
                return output;
            }
            if self.command.is_none() {
                let Some(command) = command_event(event.mode.enum_value_or_default(), true) else {
                    output.push(event.clone());
                    return output;
                };
                output.extend(self.controls.values().map(release));
                output.push(command.clone());
                self.command = Some(command);
            }
            self.active.insert(id, mapped.clone());
            output.push(mapped);
        } else {
            if event.down || event.press {
                self.finish(true, &mut output);
            }
            let mut original = event.clone();
            if event.mode.enum_value() == Ok(KeyboardMode::Legacy)
                && !self.controls.is_empty()
                && !event.modifiers.contains(&ControlKey::RAlt.into())
                && !self.blockers.contains(&KeyId(
                    event.mode.value(),
                    ControlKey::RAlt as u32,
                    true,
                ))
                && !original.modifiers.contains(&ControlKey::Control.into())
            {
                original.modifiers.push(ControlKey::Control.into());
            }
            output.push(original);
        }
        output
    }
}

impl<T: InvokeUiSession> Session<T> {
    fn niko_send_keys(&self, keys: Vec<KeyEvent>) {
        for key in keys {
            let mut message = Message::new();
            message.set_key_event(key);
            self.send(Data::Message(message));
        }
    }

    pub(crate) fn niko_release_mac_shortcuts(&self) {
        let mut state = self.niko_mac_shortcuts.lock().unwrap();
        self.niko_send_keys(state.reset());
    }

    pub(crate) fn niko_clear_mac_shortcuts(&self) {
        self.niko_mac_shortcuts.lock().unwrap().reset();
    }

    pub(crate) fn niko_dispatch_mac_key(&self, event: &KeyEvent) -> bool {
        self.niko_dispatch_mac_key_from_host(
            event,
            cfg!(any(target_os = "windows", target_os = "linux")),
        )
    }

    fn niko_dispatch_mac_key_from_host(&self, event: &KeyEvent, supported_host: bool) -> bool {
        if !supported_host || self.peer_platform() != "Mac OS" || !self.is_default() {
            return false;
        }
        let mut state = self.niko_mac_shortcuts.lock().unwrap();
        if !matches!(
            event.mode.enum_value(),
            Ok(KeyboardMode::Map | KeyboardMode::Legacy)
        ) {
            self.niko_send_keys(state.reset());
            return false;
        }
        let allowed = *self.server_keyboard_enabled.read().unwrap()
            && !self.lc.read().unwrap().view_only.v
            && self.connection_round_state.lock().unwrap().is_connected();
        let automatic = self.get_option(OPTION.to_string()) != "original";
        if allowed {
            self.niko_send_keys(state.process(event, automatic));
        } else {
            self.niko_send_keys(state.reset());
        }
        true
    }

    pub(crate) fn niko_input_shortcut(
        &self,
        name: &str,
        down: bool,
        press: bool,
        alt: bool,
        ctrl: bool,
        shift: bool,
        command: bool,
    ) -> bool {
        let Some(name) = name.strip_prefix(ACTION_PREFIX) else {
            return false;
        };
        if name == "RELEASE" {
            self.niko_release_mac_shortcuts();
            return true;
        }
        // Native press is already an atomic down/up. A delayed Flutter finally
        // must not release a new physical key or a reconnected session's state.
        if down || !press {
            return true;
        }
        let supported = matches!(
            name,
            "VK_C"
                | "VK_V"
                | "VK_X"
                | "VK_A"
                | "VK_Z"
                | "VK_S"
                | "VK_F"
                | "VK_P"
                | "VK_R"
                | "VK_TAB"
                | "VK_LEFT"
                | "VK_RIGHT"
                | "VK_UP"
                | "VK_DOWN"
        );
        if !supported
            || !self.is_default()
            || !matches!(
                self.peer_platform().as_str(),
                "Mac OS" | "Windows" | "Linux"
            )
        {
            return true;
        }
        let mut state = self.niko_mac_shortcuts.lock().unwrap();
        if !*self.server_keyboard_enabled.read().unwrap()
            || self.lc.read().unwrap().view_only.v
            || !self.connection_round_state.lock().unwrap().is_connected()
        {
            return true;
        }
        let Some(key) = crate::client::KEY_MAP.get(name) else {
            return true;
        };
        let mut event = KeyEvent::new();
        match key {
            crate::client::Key::Chr(code) => event.set_chr(*code),
            crate::client::Key::ControlKey(key) => event.set_control_key(*key),
            crate::client::Key::_Raw(code) => event.set_chr(*code),
        }
        event.mode = KeyboardMode::Legacy.into();
        event.down = down;
        event.press = press;
        for (enabled, modifier) in [
            (alt, ControlKey::Alt),
            (ctrl, ControlKey::Control),
            (shift, ControlKey::Shift),
            (command, ControlKey::Meta),
        ] {
            if enabled {
                event.modifiers.push(modifier.into());
            }
        }
        self.niko_send_keys(state.reset());
        self.niko_send_keys(vec![event]);
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn expected_command(mode: KeyboardMode, down: bool) -> KeyEvent {
        command_event(mode, down).unwrap()
    }

    fn event(mode: KeyboardMode, key: rdev::Key, down: bool) -> KeyEvent {
        let mut event = KeyEvent::new();
        event.mode = mode.into();
        event.down = down;
        if mode == KeyboardMode::Map {
            event.set_chr(rdev::macos_keycode_from_key(key).unwrap() as _);
        } else {
            match key {
                rdev::Key::ControlLeft => event.set_control_key(ControlKey::Control),
                rdev::Key::ControlRight => event.set_control_key(ControlKey::RControl),
                rdev::Key::MetaLeft => event.set_control_key(ControlKey::Meta),
                rdev::Key::ShiftLeft => event.set_control_key(ControlKey::Shift),
                rdev::Key::AltGr => event.set_control_key(ControlKey::RAlt),
                rdev::Key::LeftArrow => event.set_control_key(ControlKey::LeftArrow),
                key => event.set_chr(match key {
                    rdev::Key::KeyC => 'c',
                    rdev::Key::KeyV => 'v',
                    rdev::Key::KeyX => 'x',
                    rdev::Key::KeyA => 'a',
                    rdev::Key::KeyZ => 'z',
                    rdev::Key::KeyS => 's',
                    rdev::Key::KeyF => 'f',
                    rdev::Key::KeyP => 'p',
                    rdev::Key::KeyR => 'r',
                    _ => panic!("Unsupported fixture key"),
                } as _),
            }
        }
        event
    }

    fn ctrl_letter(mode: KeyboardMode, key: rdev::Key, down: bool) -> KeyEvent {
        let mut event = event(mode, key, down);
        if mode == KeyboardMode::Legacy {
            event.modifiers.push(ControlKey::Control.into());
        }
        event
    }

    #[test]
    fn common_chords_map_in_both_protocol_modes_and_release_before_restoring_control() {
        for mode in [KeyboardMode::Map, KeyboardMode::Legacy] {
            for letter in [
                rdev::Key::KeyC,
                rdev::Key::KeyV,
                rdev::Key::KeyX,
                rdev::Key::KeyA,
                rdev::Key::KeyZ,
                rdev::Key::KeyS,
                rdev::Key::KeyF,
                rdev::Key::KeyP,
                rdev::Key::KeyR,
            ] {
                let mut state = MacShortcutState::default();
                let ctrl = event(mode, rdev::Key::ControlLeft, true);
                assert_eq!(state.process(&ctrl, true), vec![ctrl.clone()]);
                let letter_down = ctrl_letter(mode, letter, true);
                let mapped = state.process(&letter_down, true);
                assert_eq!(
                    mapped,
                    vec![
                        release(&ctrl),
                        expected_command(mode, true),
                        as_command(&letter_down)
                    ]
                );
                assert_eq!(
                    state.process(&letter_down, true),
                    vec![as_command(&letter_down)],
                    "repeat must not add another Command down"
                );
                let letter_up = ctrl_letter(mode, letter, false);
                assert_eq!(
                    state.process(&letter_up, true),
                    vec![
                        as_command(&letter_up),
                        expected_command(mode, false),
                        ctrl.clone()
                    ]
                );
                let ctrl_up = event(mode, rdev::Key::ControlLeft, false);
                assert_eq!(state.process(&ctrl_up, true), vec![ctrl_up]);
                assert!(state.reset().is_empty());
            }
        }
    }

    #[test]
    fn control_arrows_cancel_a_held_semantic_letter_and_keep_spaces_control() {
        for mode in [KeyboardMode::Map, KeyboardMode::Legacy] {
            let mut state = MacShortcutState::default();
            let ctrl = event(mode, rdev::Key::ControlLeft, true);
            state.process(&ctrl, true);
            let c = ctrl_letter(mode, rdev::Key::KeyC, true);
            state.process(&c, true);
            let mut arrow = event(mode, rdev::Key::LeftArrow, true);
            if mode == KeyboardMode::Legacy {
                arrow.modifiers.push(ControlKey::Control.into());
            }
            assert_eq!(
                state.process(&arrow, true),
                vec![
                    release(&as_command(&c)),
                    expected_command(mode, false),
                    ctrl,
                    arrow
                ]
            );
            assert!(
                state.process(&c, true).is_empty(),
                "canceled held key repeat stays suppressed"
            );
            assert!(state
                .process(&ctrl_letter(mode, rdev::Key::KeyC, false), true)
                .is_empty());
        }
    }

    #[test]
    fn releasing_one_of_two_controls_keeps_the_chord_until_the_last_control_is_up() {
        for mode in [KeyboardMode::Map, KeyboardMode::Legacy] {
            let mut state = MacShortcutState::default();
            state.process(&event(mode, rdev::Key::ControlLeft, true), true);
            state.process(&event(mode, rdev::Key::ControlRight, true), true);
            let c = ctrl_letter(mode, rdev::Key::KeyC, true);
            state.process(&c, true);
            assert!(state
                .process(&event(mode, rdev::Key::ControlLeft, false), true)
                .is_empty());
            assert_eq!(
                state.process(&event(mode, rdev::Key::ControlRight, false), true),
                vec![release(&as_command(&c)), expected_command(mode, false)]
            );
            assert!(state
                .process(&ctrl_letter(mode, rdev::Key::KeyC, false), true)
                .is_empty());
            assert!(state.reset().is_empty());
        }
    }

    #[test]
    fn altgr_shift_and_meta_chords_are_not_semantically_remapped() {
        for mode in [KeyboardMode::Map, KeyboardMode::Legacy] {
            for modifier in [rdev::Key::AltGr, rdev::Key::ShiftLeft, rdev::Key::MetaLeft] {
                let mut state = MacShortcutState::default();
                state.process(&event(mode, rdev::Key::ControlLeft, true), true);
                let modifier_down = event(mode, modifier, true);
                assert_eq!(state.process(&modifier_down, true), vec![modifier_down]);
                let c = ctrl_letter(mode, rdev::Key::KeyC, true);
                assert_eq!(state.process(&c, true), vec![c]);
            }
        }
    }

    #[test]
    fn reset_or_original_mode_releases_old_keys_once_and_cannot_stick_command() {
        for mode in [KeyboardMode::Map, KeyboardMode::Legacy] {
            for switch_to_original in [false, true] {
                let mut state = MacShortcutState::default();
                let ctrl = event(mode, rdev::Key::ControlLeft, true);
                state.process(&ctrl, true);
                let c = ctrl_letter(mode, rdev::Key::KeyC, true);
                state.process(&c, true);
                let mut expected = vec![
                    release(&as_command(&c)),
                    expected_command(mode, false),
                    release(&ctrl),
                ];
                if switch_to_original {
                    expected.push(c.clone());
                    assert_eq!(state.process(&c, false), expected);
                } else {
                    assert_eq!(state.reset(), expected);
                }
                assert!(state.reset().is_empty());
            }
        }
    }

    #[test]
    fn mode_switch_releases_using_original_key_mode() {
        let mut state = MacShortcutState::default();
        let ctrl = event(KeyboardMode::Map, rdev::Key::ControlLeft, true);
        state.process(&ctrl, true);
        let c = ctrl_letter(KeyboardMode::Map, rdev::Key::KeyC, true);
        state.process(&c, true);
        let next = event(KeyboardMode::Legacy, rdev::Key::ControlLeft, true);
        assert_eq!(
            state.process(&next, true),
            vec![
                release(&as_command(&c)),
                expected_command(KeyboardMode::Map, false),
                release(&ctrl),
                next
            ]
        );
    }

    #[test]
    fn legacy_atomic_repeat_does_not_release_the_held_command_or_lose_later_key_up() {
        let mut state = MacShortcutState::default();
        let ctrl = event(KeyboardMode::Legacy, rdev::Key::ControlLeft, true);
        state.process(&ctrl, true);
        let c = ctrl_letter(KeyboardMode::Legacy, rdev::Key::KeyC, true);
        state.process(&c, true);
        let mut repeat = c.clone();
        repeat.down = false;
        repeat.press = true;
        assert_eq!(state.process(&repeat, true), vec![as_command(&repeat)]);
        let up = ctrl_letter(KeyboardMode::Legacy, rdev::Key::KeyC, false);
        assert_eq!(
            state.process(&up, true),
            vec![
                as_command(&up),
                expected_command(KeyboardMode::Legacy, false),
                ctrl
            ]
        );
    }

    #[test]
    fn legacy_key_up_uses_the_original_down_even_if_character_case_changes() {
        let mut state = MacShortcutState::default();
        state.process(
            &event(KeyboardMode::Legacy, rdev::Key::ControlLeft, true),
            true,
        );
        let mut c = ctrl_letter(KeyboardMode::Legacy, rdev::Key::KeyC, true);
        c.set_chr('C' as _);
        state.process(&c, true);
        let up = ctrl_letter(KeyboardMode::Legacy, rdev::Key::KeyC, false);
        let mut expected_up = as_command(&c);
        expected_up.down = false;
        assert_eq!(state.process(&up, true)[0], expected_up);
        assert!(state.command.is_none());
    }

    #[test]
    fn legacy_spaces_uses_the_other_held_control_even_if_flutter_cached_flag_was_cleared() {
        let mut state = MacShortcutState::default();
        state.process(
            &event(KeyboardMode::Legacy, rdev::Key::ControlLeft, true),
            true,
        );
        state.process(
            &event(KeyboardMode::Legacy, rdev::Key::ControlRight, true),
            true,
        );
        state.process(
            &event(KeyboardMode::Legacy, rdev::Key::ControlLeft, false),
            true,
        );
        let arrow = event(KeyboardMode::Legacy, rdev::Key::LeftArrow, true);
        let keys = state.process(&arrow, true);
        assert_eq!(keys[0].control_key(), ControlKey::LeftArrow);
        assert_eq!(keys[0].modifiers, vec![ControlKey::Control.into()]);
        state.process(
            &event(KeyboardMode::Legacy, rdev::Key::ControlRight, false),
            true,
        );
        assert!(state.reset().is_empty());
    }

    #[cfg(feature = "flutter")]
    fn create_session() -> (
        Session<crate::flutter::FlutterHandler>,
        hbb_common::tokio::sync::mpsc::UnboundedReceiver<Data>,
    ) {
        let session = Session::default();
        session.lc.write().unwrap().get_config().info.platform = "Mac OS".into();
        session.lc.write().unwrap().conn_type =
            hbb_common::rendezvous_proto::ConnType::DEFAULT_CONN;
        *session.server_keyboard_enabled.write().unwrap() = true;
        session
            .connection_round_state
            .lock()
            .unwrap()
            .set_connected();
        let (sender, receiver) = hbb_common::tokio::sync::mpsc::unbounded_channel();
        *session.sender.write().unwrap() = Some(sender);
        (session, receiver)
    }

    #[cfg(feature = "flutter")]
    fn drain(
        receiver: &mut hbb_common::tokio::sync::mpsc::UnboundedReceiver<Data>,
    ) -> Vec<KeyEvent> {
        let mut output = Vec::new();
        while let Ok(data) = receiver.try_recv() {
            if let Data::Message(message) = data {
                if let Some(base::message_proto::message::Union::KeyEvent(event)) = message.union {
                    output.push(event);
                }
            }
        }
        output
    }

    #[test]
    #[cfg(feature = "flutter")]
    fn real_session_dispatch_serializes_chord_and_revocation_cleanup_to_original_sender() {
        for mode in [KeyboardMode::Map, KeyboardMode::Legacy] {
            let (session, mut receiver) = create_session();
            let (other_session, mut other_receiver) = create_session();
            let ctrl = event(mode, rdev::Key::ControlLeft, true);
            let c = ctrl_letter(mode, rdev::Key::KeyC, true);
            assert!(session.niko_dispatch_mac_key_from_host(&ctrl, true));
            assert!(session.niko_dispatch_mac_key_from_host(&c, true));
            assert_eq!(
                drain(&mut receiver),
                vec![
                    ctrl.clone(),
                    release(&ctrl),
                    expected_command(mode, true),
                    as_command(&c)
                ]
            );
            *session.server_keyboard_enabled.write().unwrap() = false;
            session
                .niko_dispatch_mac_key_from_host(&ctrl_letter(mode, rdev::Key::KeyC, false), true);
            assert_eq!(
                drain(&mut receiver),
                vec![
                    release(&as_command(&c)),
                    expected_command(mode, false),
                    release(&ctrl)
                ]
            );
            assert!(drain(&mut other_receiver).is_empty());
            assert!(other_session
                .niko_mac_shortcuts
                .lock()
                .unwrap()
                .reset()
                .is_empty());
        }
    }

    #[test]
    #[cfg(feature = "flutter")]
    fn semantic_buttons_use_real_native_key_map_and_permissions_without_physical_modifier_state() {
        let (session, mut receiver) = create_session();
        session.lc.write().unwrap().get_config().allow_swap_key.v = true;
        session.input_key(
            "NikoShortcut:VK_LEFT",
            false,
            true,
            false,
            true,
            false,
            false,
        );
        let keys = drain(&mut receiver);
        assert_eq!(keys.len(), 1);
        assert_eq!(keys[0].control_key(), ControlKey::LeftArrow);
        assert!(keys[0].press);
        assert_eq!(keys[0].modifiers, vec![ControlKey::Control.into()]);
        session.input_key("NikoShortcut:VK_TAB", false, true, false, false, true, true);
        let keys = drain(&mut receiver);
        assert_eq!(keys[0].control_key(), ControlKey::Tab);
        assert_eq!(
            keys[0].modifiers,
            vec![ControlKey::Shift.into(), ControlKey::Meta.into()]
        );
        *session.server_keyboard_enabled.write().unwrap() = false;
        session.input_key("NikoShortcut:VK_C", false, true, false, false, false, true);
        assert!(drain(&mut receiver).is_empty());
        session.input_key(
            "NikoShortcut:VK_C",
            false,
            false,
            false,
            false,
            false,
            false,
        );
        assert!(
            drain(&mut receiver).is_empty(),
            "atomic button cleanup does not send an unowned key-up"
        );
        session.input_key(
            "NikoShortcut:UNSUPPORTED",
            false,
            true,
            false,
            true,
            false,
            true,
        );
        assert!(drain(&mut receiver).is_empty());
    }

    #[test]
    #[cfg(feature = "flutter")]
    fn original_mode_and_control_arrows_ignore_global_swap_only_for_this_mac_path() {
        let (session, mut receiver) = create_session();
        session.lc.write().unwrap().get_config().allow_swap_key.v = true;
        session
            .lc
            .write()
            .unwrap()
            .get_config()
            .options
            .insert(OPTION.into(), "original".into());
        let ctrl = event(KeyboardMode::Map, rdev::Key::ControlLeft, true);
        let c = ctrl_letter(KeyboardMode::Map, rdev::Key::KeyC, true);
        session.niko_dispatch_mac_key_from_host(&ctrl, true);
        session.niko_dispatch_mac_key_from_host(&c, true);
        assert_eq!(drain(&mut receiver), vec![ctrl.clone(), c]);
        assert!(
            !session.niko_dispatch_mac_key_from_host(&ctrl, false),
            "Mac hosts retain the upstream physical-key path"
        );
        session.lc.write().unwrap().get_config().info.platform = "Windows".into();
        assert!(
            !session.niko_dispatch_mac_key_from_host(&ctrl, true),
            "non-Mac peers retain the upstream physical-key path"
        );
    }

    #[test]
    #[cfg(feature = "flutter")]
    fn close_releases_the_mapped_keys_before_queuing_the_original_session_close() {
        let (session, mut receiver) = create_session();
        let ctrl = event(KeyboardMode::Map, rdev::Key::ControlLeft, true);
        let c = ctrl_letter(KeyboardMode::Map, rdev::Key::KeyC, true);
        session.niko_dispatch_mac_key_from_host(&ctrl, true);
        session.niko_dispatch_mac_key_from_host(&c, true);
        drain(&mut receiver);
        session.close();
        for expected in [
            release(&as_command(&c)),
            expected_command(KeyboardMode::Map, false),
            release(&ctrl),
        ] {
            let Data::Message(message) = receiver.try_recv().unwrap() else {
                panic!("key release must precede Close");
            };
            assert_eq!(message.key_event(), &expected);
        }
        assert!(matches!(receiver.try_recv(), Ok(Data::Close)));
        session.niko_clear_mac_shortcuts();
        assert!(
            drain(&mut receiver).is_empty(),
            "disconnect cleanup must not send old keys to a new round"
        );
    }

    #[test]
    #[cfg(feature = "flutter")]
    fn delayed_atomic_button_cleanup_cannot_release_a_new_physical_chord_or_connection_round() {
        for mode in [KeyboardMode::Map, KeyboardMode::Legacy] {
            for reconnect in [false, true] {
                let (session, mut receiver) = create_session();
                session.input_key("NikoShortcut:VK_C", false, true, false, false, false, true);
                let button = drain(&mut receiver);
                assert_eq!(button.len(), 1);
                assert!(
                    button[0].press,
                    "server receives the existing atomic down/up operation"
                );
                if reconnect {
                    session.niko_clear_mac_shortcuts();
                    let mut round = session.connection_round_state.lock().unwrap();
                    round.new_round();
                    round.set_connected();
                }
                let ctrl = event(mode, rdev::Key::ControlLeft, true);
                let c = ctrl_letter(mode, rdev::Key::KeyC, true);
                session.niko_dispatch_mac_key_from_host(&ctrl, true);
                session.niko_dispatch_mac_key_from_host(&c, true);
                drain(&mut receiver);
                session.input_key(
                    "NikoShortcut:VK_C",
                    false,
                    false,
                    false,
                    false,
                    false,
                    false,
                );
                assert!(
                    drain(&mut receiver).is_empty(),
                    "old Flutter finally cannot touch new native input"
                );
                let c_up = ctrl_letter(mode, rdev::Key::KeyC, false);
                session.niko_dispatch_mac_key_from_host(&c_up, true);
                assert_eq!(
                    drain(&mut receiver),
                    vec![as_command(&c_up), expected_command(mode, false), ctrl]
                );
            }
        }
    }

    #[test]
    #[cfg(feature = "flutter")]
    fn translate_mode_leaves_the_upstream_path_after_releasing_previous_mapped_keys() {
        let (session, mut receiver) = create_session();
        let ctrl = event(KeyboardMode::Map, rdev::Key::ControlLeft, true);
        let c = ctrl_letter(KeyboardMode::Map, rdev::Key::KeyC, true);
        session.niko_dispatch_mac_key_from_host(&ctrl, true);
        session.niko_dispatch_mac_key_from_host(&c, true);
        drain(&mut receiver);
        let mut translate = KeyEvent::new();
        translate.mode = KeyboardMode::Translate.into();
        translate.set_chr('c' as _);
        translate.down = true;
        assert!(!session.niko_dispatch_mac_key_from_host(&translate, true));
        assert_eq!(
            drain(&mut receiver),
            vec![
                release(&as_command(&c)),
                expected_command(KeyboardMode::Map, false),
                release(&ctrl)
            ]
        );
    }
}
