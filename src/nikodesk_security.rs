use base::message_proto::{login_request, message, LoginRequest, Message};
use hbb_common::{bail, ResultType};

pub(crate) fn require_encrypted(secured: bool) -> ResultType<()> {
    if !secured {
        bail!("NikoDesk requires an authenticated encrypted session");
    }
    Ok(())
}

pub(crate) fn allows_login(request: &LoginRequest) -> bool {
    matches!(request.union.as_ref(), None | Some(login_request::Union::FileTransfer(_)))
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
    match message.union.as_ref() {
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
        assert!(!allows_login(&login));
    }
}
