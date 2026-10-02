use crate::ui_cm_interface::Client;

pub(crate) fn known(name: &str) -> bool {
    matches!(name, "keyboard" | "clipboard" | "audio" | "file" | "restart" |
        "recording" | "block_input" | "privacy_mode")
}

pub(crate) fn apply(client: &mut Client, name: &str, enabled: bool) -> bool {
    if client.disconnected || client.niko_camera_cleanup || client.niko_voice_cleanup ||
        client.niko_tunnel_cleanup {
        return false;
    }
    let field = match name {
        "keyboard" => &mut client.keyboard,
        "clipboard" => &mut client.clipboard,
        "audio" => &mut client.audio,
        "file" => &mut client.file,
        "restart" => &mut client.restart,
        "recording" => &mut client.recording,
        "block_input" => &mut client.block_input,
        "privacy_mode" => &mut client.privacy_mode,
        _ => return false,
    };
    *field = enabled;
    true
}

#[cfg(all(test, not(target_os = "ios")))]
mod tests {
    use super::*;
    use crate::nikodesk::{camera_flow::Status, connection_capabilities::Identity};

    fn client() -> Client {
        let mut client = Client::camera_cleanup_fixture(Status {
            identity: Identity { connection_id: 12, namespace: "a".repeat(64),
                peer_id: "123456789".into(), connection_nonce: "b".repeat(32),
                request_nonce: "c".repeat(32), epoch: "1".into() },
            kind: "camera".into(), phase: "Running".into(), reason: String::new(),
            resource_epoch: "1".into(), revision: "1".into(), selection: None,
        });
        client.is_view_camera = false;
        client.niko_camera = None;
        client
    }

    #[test]
    fn confirmed_permissions_update_the_serialized_cm_snapshot_without_reauthenticating() {
        for name in ["keyboard", "clipboard", "audio", "file", "restart",
            "recording", "block_input", "privacy_mode"] {
            let mut client = client();
            client.authorized = false;
            assert!(known(name));
            assert!(apply(&mut client, name, true));
            let snapshot = serde_json::to_value(&client).unwrap();
            assert_eq!(snapshot[name], true);
            assert_eq!(snapshot["authorized"], false);
            assert_eq!(snapshot["disconnected"], false);
            assert!(apply(&mut client, name, false));
            assert_eq!(serde_json::to_value(&client).unwrap()[name], false);
        }
    }

    #[test]
    fn retired_rows_and_unknown_permissions_cannot_change_a_cm_snapshot() {
        for state in 0..4 {
            let mut client = client();
            match state {
                0 => client.disconnected = true,
                1 => client.niko_camera_cleanup = true,
                2 => client.niko_voice_cleanup = true,
                _ => client.niko_tunnel_cleanup = true,
            }
            let before = serde_json::to_value(&client).unwrap();
            assert!(!apply(&mut client, "keyboard", true));
            assert_eq!(serde_json::to_value(&client).unwrap(), before);
        }
        let mut client = client();
        let before = serde_json::to_value(&client).unwrap();
        assert!(!known("authorize"));
        assert!(!apply(&mut client, "authorize", true));
        assert_eq!(serde_json::to_value(&client).unwrap(), before);
    }
}
