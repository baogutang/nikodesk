use super::*;
use crate::nikodesk::{
    tunnel_flow::{Command, Op},
    tunnel_wire::{ReadOnlyStatus, ReadPhase},
};

fn same_target(a: &ReadOnlyStatus, b: &ReadOnlyStatus) -> bool {
    a.target_host() == b.target_host() && a.target_port() == b.target_port()
}
fn counter(value: &str) -> Option<u64> {
    value.parse::<u64>().ok().filter(|v| *v > 0 && v.to_string() == value)
}
fn follows(old: ReadPhase, new: ReadPhase) -> bool {
    use ReadPhase::*;
    match old {
        Pending => true,
        Starting => new != Pending,
        Running => !matches!(new, Pending | Starting),
        Revoking => matches!(new, Revoking | RecoveryRequired | Stopped),
        RecoveryRequired => matches!(new, RecoveryRequired | Stopped),
        Stopped => new == Stopped,
    }
}
fn cleanup_phase(phase: ReadPhase) -> bool {
    matches!(phase, ReadPhase::Revoking | ReadPhase::RecoveryRequired | ReadPhase::Stopped)
}

impl Client {
    fn tunnel_session(&self) -> bool {
        !self.port_forward.is_empty() && !self.is_file_transfer && !self.is_view_camera && !self.is_terminal
    }
    fn tunnel_status_route(&self, status: &ReadOnlyStatus) -> bool {
        if !self.tunnel_session() || status.identity.connection_id != self.id
            || status.identity.peer_id != self.peer_id || !status.identity.valid()
        { return false; }
        crate::nikodesk::tunnel_endpoint::Target::parse(status.target_host(), i32::from(status.target_port()))
            .is_ok_and(|target| self.port_forward == target.label())
    }
    pub(super) fn apply_tunnel_status(&mut self, json: &str, retirement: Option<bool>) -> bool {
        let Ok(status) = ReadOnlyStatus::parse(json) else { return false; };
        if !self.tunnel_status_route(&status) { return false; }
        if let Some(old) = self.niko_tunnel.as_ref() {
            if old.identity != status.identity || !same_target(old, &status)
                || counter(&status.revision) < counter(&old.revision)
                || counter(&status.resource_epoch) < counter(&old.resource_epoch)
                || old.revision == status.revision && old != &status
                || !follows(old.phase, status.phase)
            { return false; }
        } else if retirement.is_some() || status.phase != ReadPhase::Pending
            || status.revision != "1" || status.resource_epoch != "1"
            || !status.addresses.is_empty() || status.selected_address.is_some()
        { return false; }
        match retirement {
            None => {
                if !self.authorized || self.disconnected || self.niko_tunnel_cleanup || status.cleanup_only {
                    return false;
                }
            }
            Some(retiring) => {
                let Some(old) = self.niko_tunnel.as_ref() else { return false; };
                if !status.cleanup_only || !cleanup_phase(status.phase) || old.revision == status.revision
                    || if retiring { self.niko_tunnel_cleanup || self.disconnected || !self.authorized }
                       else { !self.niko_tunnel_cleanup || !self.disconnected || self.authorized }
                { return false; }
                self.niko_tunnel_cleanup = true;
                self.authorized = false;
                self.disconnected = true;
            }
        }
        self.niko_tunnel = Some(status);
        true
    }
    pub(super) fn tunnel_cleanup_dispatch(&self, data: &Data) -> bool {
        match data {
            Data::NikoTunnelCommand(command) => self.niko_tunnel.as_ref().is_some_and(|status|
                command.identity == status.identity && command.revision == status.revision
                && matches!(command.op, Op::Query | Op::RetryCleanup)),
            Data::Close => self.niko_tunnel.as_ref().is_some_and(|status| status.phase == ReadPhase::Stopped),
            _ => false,
        }
    }
}

impl<T: InvokeUiCM> IpcTaskRunner<T> {
    pub(super) fn handle_nikodesk_tunnel_data(&mut self, data: Data) {
        let (json, retirement) = match data {
            Data::NikoTunnelStatus(json) => (json, None),
            Data::NikoTunnelRetired(json) => (json, Some(true)),
            Data::NikoTunnelCleanupStatus(json) => (json, Some(false)),
            _ => return,
        };
        let snapshot = CLIENTS.write().ok().and_then(|mut clients| {
            let client = clients.get_mut(&self.conn_id)?;
            client.apply_tunnel_status(&json, retirement).then(|| client.clone())
        });
        let Some(client) = snapshot else { return; };
        if retirement.is_some() {
            self.tunnel_cleanup_identity = client.niko_tunnel.as_ref().map(|s| s.identity.clone());
            self.close = false;
        }
        self.cm.ui_handler.add_connection(&client);
    }
}

#[cfg(any(target_os = "macos", target_os = "windows"))]
pub(crate) fn nikodesk_tunnel_command(json: String) -> String {
    let command = match Command::parse(&json) {
        Ok(value) => value,
        Err(error) => return serde_json::json!({"ok":false,"reason":error.code()}).to_string(),
    };
    let result = (|| -> Result<(), &'static str> {
        let clients = CLIENTS.read().map_err(|_| "cm_state_unavailable")?;
        let client = clients.get(&command.identity.connection_id).ok_or("cm_connection_missing")?;
        let status = client.niko_tunnel.as_ref().ok_or("tunnel_stale_request")?;
        if !client.tunnel_status_route(status) || status.identity != command.identity
            || status.revision != command.revision
        { return Err("tunnel_stale_request"); }
        if client.niko_tunnel_cleanup {
            if client.authorized || !client.disconnected || !matches!(command.op, Op::Query | Op::RetryCleanup) {
                return Err("tunnel_cleanup_unconfirmed");
            }
        } else if !client.authorized || client.disconnected {
            return Err("tunnel_stale_request");
        }
        client.tx.send(Data::NikoTunnelCommand(command.clone())).map_err(|_| "cm_connection_channel_closed")
    })();
    serde_json::json!({"ok":result.is_ok(),"reason":result.err().unwrap_or("queued"),
        "identity":command.identity,"revision":command.revision}).to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::nikodesk::connection_capabilities::Identity;
    fn fixture() -> (Client, serde_json::Value) {
        let identity = Identity {connection_id:7,namespace:"a".repeat(64),peer_id:"123456789".into(),
            connection_nonce:"01".repeat(16),request_nonce:"02".repeat(16),epoch:"1".into()};
        let camera = crate::nikodesk::camera_flow::Status {identity:identity.clone(),kind:"camera".into(),phase:"Pending".into(),
            reason:"pending_local_approval".into(),revision:"1".into(),resource_epoch:"1".into(),selection:None};
        let mut client = Client::camera_cleanup_fixture(camera);
        client.is_view_camera = false;
        client.niko_camera = None;
        client.port_forward = "127.0.0.1:23456".into();
        let status = serde_json::json!({"identity":identity,"kind":"tunnel","phase":"Pending",
            "reason":"local_approval_required","revision":"1","resource_epoch":"1",
            "target":{"host":"127.0.0.1","port":23456},"addresses":[],"selected_address":null,"cleanup_only":false});
        (client, status)
    }
    fn apply(client: &mut Client, status: &serde_json::Value, retired: Option<bool>) -> bool {
        client.apply_tunnel_status(&status.to_string(), retired)
    }
    #[test]
    fn cm_initial_anchor_requires_actual_tunnel_login_route_and_pending() {
        let (mut client, status) = fixture();
        client.authorized = false;
        assert!(!apply(&mut client, &status, None));
        client.authorized = true;
        client.is_terminal = true;
        assert!(!apply(&mut client, &status, None));
        client.is_terminal = false;
        let mut wrong = status.clone();
        wrong["identity"]["connection_id"] = 8.into();
        assert!(!apply(&mut client, &wrong, None));
        wrong = status.clone();
        wrong["target"]["port"] = 12345.into();
        assert!(!apply(&mut client, &wrong, None));
        wrong = status.clone();
        wrong["revision"] = "2".into();
        assert!(!apply(&mut client, &wrong, None));
        assert!(apply(&mut client, &status, None));
    }
    #[test]
    fn cm_initial_route_accepts_native_target_labels_for_ip_and_dns() {
        use crate::nikodesk::tunnel_endpoint::Target;
        for (input, expected_host, expected_label) in [
            ("127.0.0.1", "127.0.0.1", "127.0.0.1:23456"),
            ("Example.COM.", "example.com", "example.com:23456"),
            ("[::1]", "::1", "[::1]:23456"),
        ] {
            let target = Target::parse(input, 23456).unwrap();
            assert_eq!(target.host(), expected_host);
            assert_eq!(target.label(), expected_label);
            let (mut client, mut status) = fixture();
            client.port_forward = target.label();
            status["target"]["host"] = target.host().into();
            if input == "[::1]" {
                client.port_forward = "::1:23456".into();
                assert!(!apply(&mut client, &status, None));
                client.port_forward = target.label();
            }
            assert!(apply(&mut client, &status, None));
            assert_eq!(client.niko_tunnel.as_ref().unwrap().target_host(), expected_host);
        }
    }
    #[test]
    fn cm_pending_queue_cannot_change_owner_target_or_revision_facts() {
        let (mut client, status) = fixture();
        assert!(apply(&mut client, &status, None));
        let mut wrong = status.clone();
        wrong["reason"] = "running".into();
        assert!(!apply(&mut client, &wrong, None));
        wrong["revision"] = "2".into();
        wrong["identity"]["request_nonce"] = "03".repeat(16).into();
        assert!(!apply(&mut client, &wrong, None));
        wrong = status.clone();
        wrong["cleanup_only"] = true.into();
        wrong["phase"] = "Revoking".into();
        wrong["revision"] = "2".into();
        assert!(!apply(&mut client, &wrong, None));
        assert_eq!(client.niko_tunnel.as_ref().unwrap().phase, ReadPhase::Pending);
        assert!(!client.niko_tunnel_cleanup);
    }
    #[test]
    fn cm_retired_owner_only_accepts_query_retry_and_actual_stopped_close() {
        let (mut client, mut status) = fixture();
        assert!(apply(&mut client, &status, None));
        status["cleanup_only"] = true.into();
        status["phase"] = "Revoking".into();
        status["revision"] = "2".into();
        status["resource_epoch"] = "2".into();
        assert!(apply(&mut client, &status, Some(true)));
        assert!(client.niko_tunnel_cleanup && client.disconnected && !client.authorized);
        assert!(!client.tunnel_cleanup_dispatch(&Data::Authorize));
        assert!(!client.tunnel_cleanup_dispatch(&Data::Close));
        let mut command = Command::parse(&serde_json::json!({"identity":status["identity"],"revision":"2","op":"query"}).to_string()).unwrap();
        assert!(client.tunnel_cleanup_dispatch(&Data::NikoTunnelCommand(command.clone())));
        command.op = Op::Resolve;
        assert!(!client.tunnel_cleanup_dispatch(&Data::NikoTunnelCommand(command)));
        status["phase"] = "RecoveryRequired".into();
        status["revision"] = "3".into();
        assert!(apply(&mut client, &status, Some(false)));
        status["phase"] = "Stopped".into();
        status["revision"] = "4".into();
        assert!(apply(&mut client, &status, Some(false)));
        assert!(client.tunnel_cleanup_dispatch(&Data::Close));
        status["phase"] = "Running".into();
        status["revision"] = "5".into();
        assert!(!apply(&mut client, &status, Some(false)));
    }
}
