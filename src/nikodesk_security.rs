use base::message_proto::{login_request, message, LoginRequest, Message};
use hbb_common::{bail, ResultType};

pub(crate) fn require_encrypted(secured: bool) -> ResultType<()> {
    if !secured {
        bail!("NikoDesk requires an authenticated encrypted session");
    }
    Ok(())
}

pub(crate) fn allows_login(request: &LoginRequest) -> bool {
    if crate::nikodesk::background::is_system_worker() { return allows_system_login(request); }
    if matches!(request.union.as_ref(),Some(login_request::Union::Terminal(terminal))
        if terminal.service_id.is_empty()) {
        return cfg!(not(any(target_os="android",target_os="ios")))
            && request.os_login.username.is_empty() && request.os_login.password.is_empty()
            && request.option.as_ref().map_or(true, |o|o.terminal_persistent.enum_value()!=Ok(base::message_proto::option_message::BoolOption::Yes));
    }
    matches!(request.union.as_ref(), None | Some(login_request::Union::FileTransfer(_)))
}

fn allows_system_login(request: &LoginRequest) -> bool {
    request.union.is_none() && !request.password.is_empty() && request.os_login.username.is_empty()
}

fn allows_system_message(message: &Message, authenticated: bool, keyboard: bool, active: bool) -> bool {
    use base::message_proto::misc;
    if !active { return false; }
    match message.union.as_ref() {
        Some(message::Union::LoginRequest(login)) => !authenticated && allows_system_login(login),
        Some(message::Union::Auth2fa(_)) | Some(message::Union::TestDelay(_)) => true,
        Some(message::Union::MouseEvent(_)) | Some(message::Union::KeyEvent(_))
        | Some(message::Union::PointerDeviceEvent(_)) => authenticated && keyboard,
        Some(message::Union::Misc(misc)) => match misc.union.as_ref() {
            Some(misc::Union::CloseReason(_)) => true,
            Some(misc::Union::Option(_)) | Some(misc::Union::RefreshVideo(_))
            | Some(misc::Union::VideoReceived(_)) | Some(misc::Union::SwitchDisplay(_))
            | Some(misc::Union::CaptureDisplays(_)) | Some(misc::Union::RefreshVideoDisplay(_))
            | Some(misc::Union::SupportedEncoding(_)) | Some(misc::Union::MessageQuery(_))
            | Some(misc::Union::FollowCurrentDisplay(_)) | Some(misc::Union::RequestCursorData(_)) => authenticated,
            _ => false,
        },
        _ => false,
    }
}

/// Evaluated at the receiving dispatcher, before any input or filesystem action.
pub(crate) fn allows_message(
    message: &Message,
    authenticated: bool,
    keyboard: bool,
    clipboard: bool,
    file: bool,
    file_clipboard: bool,
) -> bool {
    if crate::nikodesk::background::is_system_worker() {
        return allows_system_message(message, authenticated, keyboard, crate::nikodesk::background::worker_input_ready());
    }
    match message.union.as_ref() {
        // The legacy voice path has no per-call grant and changes shared audio
        // state. Owned voice sessions must enter through their ticketed path.
        Some(message::Union::VoiceCallRequest(_))
        | Some(message::Union::VoiceCallResponse(_))
        | Some(message::Union::AudioFrame(_)) => false,
        Some(message::Union::Misc(misc))
            if matches!(misc.union.as_ref(), Some(base::message_proto::misc::Union::AudioFormat(_))) => false,
        Some(message::Union::MouseEvent(_))
        | Some(message::Union::PointerDeviceEvent(_))
        | Some(message::Union::KeyEvent(_)) => authenticated && keyboard,
        Some(message::Union::Clipboard(_)) | Some(message::Union::MultiClipboards(_)) => {
            authenticated && clipboard
        }
        Some(message::Union::Cliprdr(_)) => authenticated && clipboard && file && file_clipboard,
        Some(message::Union::FileAction(_)) | Some(message::Union::FileResponse(_)) => {
            authenticated && file
        }
        _ => true,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use base::message_proto::{Clipboard, Cliprdr, FileAction, FileResponse, KeyEvent, LoginRequest, MouseEvent};

    #[test]
    fn nikodesk_plaintext_never_passes_the_session_boundary() {
        assert!(require_encrypted(false).is_err());
        assert!(require_encrypted(true).is_ok());
    }

    #[test]
    fn nikodesk_unauthenticated_operations_are_rejected_even_with_all_permissions() {
        let operations = [
            message::Union::KeyEvent(KeyEvent::new()),
            message::Union::MouseEvent(MouseEvent::new()),
            message::Union::Clipboard(Clipboard::new()),
            message::Union::Cliprdr(Cliprdr::new()),
            message::Union::FileAction(FileAction::new()),
            message::Union::FileResponse(FileResponse::new()),
        ];
        for operation in operations {
            let mut message = Message::new();
            message.union = Some(operation);
            assert!(!allows_message(&message, false, true, true, true, true));
        }
    }

    #[test]
    fn nikodesk_revoked_permissions_block_subsequent_messages() {
        let mut message = Message::new();
        message.set_key_event(KeyEvent::new());
        assert!(allows_message(&message, true, true, false, false, false));
        assert!(!allows_message(&message, true, false, true, true, true));
        message.set_clipboard(Clipboard::new());
        assert!(!allows_message(&message, true, true, false, true, true));
        message.set_file_response(FileResponse::new());
        assert!(allows_message(&message, true, false, false, true, false));
        assert!(!allows_message(&message, true, true, true, false, true));
        message.set_cliprdr(Cliprdr::new());
        for (clipboard, file, enabled) in [(false, true, true), (true, false, true), (true, true, false)] {
            assert!(!allows_message(&message, true, true, clipboard, file, enabled));
        }
        assert!(allows_message(&message, true, false, true, true, true));
    }

    #[test]
    fn nikodesk_handshake_still_reaches_upstream_authentication() {
        let mut message = Message::new();
        message.set_login_request(LoginRequest::new());
        assert!(allows_message(&message, false, false, false, false, false));
    }

    #[test]
    fn nikodesk_legacy_voice_cannot_bypass_default_off_or_local_grants() {
        let mut messages = vec![];
        let mut message = Message::new();
        message.set_voice_call_request(Default::default()); messages.push(message);
        let mut message = Message::new();
        message.set_voice_call_response(Default::default()); messages.push(message);
        let mut message = Message::new();
        message.set_audio_frame(Default::default()); messages.push(message);
        let mut misc = base::message_proto::Misc::new();
        misc.set_audio_format(Default::default());
        let mut message = Message::new(); message.set_misc(misc); messages.push(message);
        for message in messages {
            for authenticated in [false, true] {
                assert!(!allows_message(&message, authenticated, true, true, true, true));
            }
        }
        let mut misc = base::message_proto::Misc::new();
        misc.set_refresh_video(Default::default());
        let mut message = Message::new(); message.set_misc(misc);
        assert!(allows_message(&message, true, true, true, true, true));
    }

    #[test]
    fn nikodesk_unsupported_login_scopes_cannot_be_enabled_by_configuration() {
        let mut login = LoginRequest::new();
        assert!(allows_login(&login));
        login.set_file_transfer(Default::default());
        assert!(allows_login(&login));
        login.set_port_forward(Default::default());
        assert!(!allows_login(&login));
        login.set_view_camera(Default::default());
        assert!(!allows_login(&login));
        login.set_terminal(Default::default());
        assert_eq!(allows_login(&login),cfg!(not(any(target_os="android",target_os="ios"))));
        if let Some(login_request::Union::Terminal(terminal))=login.union.as_mut() {terminal.service_id="ts_foreign".into();}
        assert!(!allows_login(&login));
        login.set_terminal(Default::default());login.os_login.mut_or_insert_default().username="administrator".into();
        assert!(!allows_login(&login));
    }
    #[test]
    fn system_desktop_requires_new_password_and_denies_privileged_resource_scopes() {
        let mut login=LoginRequest::new();assert!(!allows_system_login(&login));
        login.password=vec![1].into();assert!(allows_system_login(&login));
        login.set_file_transfer(Default::default());assert!(!allows_system_login(&login));
        let mut msg=Message::new();msg.set_file_action(Default::default());
        assert!(!allows_system_message(&msg,true,true,true));
        msg.set_clipboard(Default::default());assert!(!allows_system_message(&msg,true,true,true));
        msg.set_terminal_action(Default::default());assert!(!allows_system_message(&msg,true,true,true));
        msg.set_voice_call_request(Default::default());assert!(!allows_system_message(&msg,true,true,true));
        msg.set_key_event(Default::default());assert!(allows_system_message(&msg,true,true,true));
        assert!(!allows_system_message(&msg,true,true,false));assert!(!allows_system_message(&msg,false,true,true));
    }
}
