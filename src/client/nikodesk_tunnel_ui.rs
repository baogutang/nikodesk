//! Read-only controller events and commands on the original session route.
use super::{Data, Interface, LoginConfigHandler, Target};
use hbb_common::{anyhow::anyhow, bail, serde_json, ResultType};
use serde::Deserialize;
use std::sync::{atomic::{AtomicU64, Ordering}, Arc, RwLock};

static GENERATION: AtomicU64 = AtomicU64::new(1);

#[cfg(feature = "flutter")]
#[derive(Clone)]
struct WakeEndpoint {
    namespace: String,
    peer_id: String,
    lc: std::sync::Weak<RwLock<LoginConfigHandler>>,
    status: String,
}
#[cfg(feature = "flutter")]
lazy_static::lazy_static! {
    static ref WAKE_ENDPOINTS: std::sync::Mutex<std::collections::HashMap<u64, WakeEndpoint>> =
        std::sync::Mutex::new(std::collections::HashMap::new());
}

pub(super) struct Publisher {
    lc: Arc<RwLock<LoginConfigHandler>>,
    namespace: String,
    peer_id: String,
    local_port: u16,
    target: Target,
    generation: u64,
    revision: u64,
    pub(super) remote_phase: Option<&'static str>,
    terminal: bool,
}
impl Publisher {
    pub(super) fn new(interface: &impl Interface, local_port: u16, target: Target) -> ResultType<Self> {
        let snapshot = interface.connection_snapshot()?;
        let generation = GENERATION.fetch_update(Ordering::AcqRel, Ordering::Acquire,
            |value| value.checked_add(1)).map_err(|_| anyhow!("tunnel_generation_exhausted"))?;
        Ok(Self { lc: interface.get_lch(), namespace: snapshot.namespace().to_owned(),
            peer_id: interface.get_id(), local_port, target, generation, revision: 0,
            remote_phase: None, terminal: false })
    }
    pub(super) fn remote(&mut self, phase: super::ReadPhase) {
        self.remote_phase = Some(match phase {
            super::ReadPhase::Pending => "Pending",
            super::ReadPhase::Starting => "Starting",
            super::ReadPhase::Running => "Running",
            super::ReadPhase::Revoking => "Revoking",
            super::ReadPhase::RecoveryRequired => "RecoveryRequired",
            super::ReadPhase::Stopped => "Stopped",
        });
    }
    pub(super) fn emit(&mut self, phase: &'static str, reason: &'static str, local_resources_closed: bool) {
        if self.terminal { return; }
        let Some(next) = self.revision.checked_add(1) else { return; };
        self.revision = next;
        let status = status_json(&self.namespace, &self.peer_id, self.local_port, &self.target,
            self.generation, next, phase, reason, self.remote_phase, local_resources_closed);
        #[cfg(feature = "flutter")]
        if let Ok(mut endpoints) = WAKE_ENDPOINTS.lock() {
            endpoints.retain(|_, value| value.lc.strong_count() != 0);
            if phase == "Listening" && self.remote_phase == Some("Running")
                && !local_resources_closed && self.target.host() == "127.0.0.1"
                && self.target.port() == 21128 && (endpoints.len() < 64 || endpoints.contains_key(&self.generation)) {
                endpoints.insert(self.generation, WakeEndpoint {
                    namespace: self.namespace.clone(), peer_id: self.peer_id.clone(),
                    lc: Arc::downgrade(&self.lc), status: status.clone(),
                });
            } else { endpoints.remove(&self.generation); }
        }
        #[cfg(feature = "flutter")]
        for session in crate::flutter::sessions::get_sessions() {
            if Arc::ptr_eq(&session.lc, &self.lc) {
                session.ui_handler.push_event("nikodesk_tunnel_controller", &[("status", &status)], &[]);
            }
        }
        #[cfg(not(feature = "flutter"))]
        let _ = status;
        self.terminal = matches!(phase, "Closed" | "Failed" | "RecoveryRequired");
    }
    pub(super) fn complete(&mut self, result: &ResultType<()>) {
        match result {
            Ok(()) => self.emit("Closed", "tunnel_local_closed", true),
            Err(error) if error.to_string() == "tunnel_local_cleanup_unconfirmed" =>
                self.emit("RecoveryRequired", "tunnel_local_cleanup_unconfirmed", false),
            Err(error) => self.emit("Failed", failure_reason(&error.to_string()), true),
        }
    }
}
impl Drop for Publisher {
    fn drop(&mut self) {
        if !self.terminal { self.emit("RecoveryRequired", "tunnel_worker_failed", false); }
        #[cfg(feature = "flutter")]
        if let Ok(mut endpoints) = WAKE_ENDPOINTS.lock() { endpoints.remove(&self.generation); }
    }
}

/// Read-only discovery across Flutter windows/engines. Only actual original
/// tunnel publishers create entries; saved preferences or queued commands do not.
#[cfg(feature = "flutter")]
pub(crate) fn wake_endpoints(selector: &str) -> String {
    #[derive(Deserialize)]
    #[serde(deny_unknown_fields)]
    struct Selector { namespace: String }
    let result = (|| -> ResultType<String> {
        if selector.len() > 256 { bail!("wake_proxy_invalid_selector"); }
        let selector: Selector = serde_json::from_str(selector)?;
        let scope = crate::nikodesk::server_scope::current()
            .filter(|scope| scope.namespace() == selector.namespace)
            .ok_or_else(|| anyhow!("wake_proxy_namespace_changed"))?;
        let options = crate::nikodesk::server_settings::read_verified_options()?;
        if options.get("stop-service").map(String::as_str) != Some("N") {
            bail!("wake_proxy_private_server_paused");
        }
        let entries: Vec<WakeEndpoint> = WAKE_ENDPOINTS.lock()
            .map_err(|_| anyhow!("wake_proxy_unconfirmed"))?.values().cloned().collect();
        let sessions = crate::flutter::sessions::get_sessions();
        let mut statuses = Vec::new();
        for entry in entries {
            if entry.namespace != selector.namespace { continue; }
            let Some(lc) = entry.lc.upgrade() else { continue; };
            if !sessions.iter().any(|session| Arc::ptr_eq(&session.lc, &lc)
                && session.is_port_forward() && !session.is_rdp()) { continue; }
            if crate::flutter::sessions::get_session_count_scoped(&selector.namespace,
                &entry.peer_id, hbb_common::rendezvous_proto::ConnType::PORT_FORWARD) == 0 { continue; }
            let status: serde_json::Value = serde_json::from_str(&entry.status)?;
            statuses.push(status);
        }
        if crate::nikodesk::server_scope::current().as_ref().map(|current| current.namespace())
            != Some(scope.namespace()) { bail!("wake_proxy_namespace_changed"); }
        let options = crate::nikodesk::server_settings::read_verified_options()?;
        if options.get("stop-service").map(String::as_str) != Some("N") {
            bail!("wake_proxy_private_server_paused");
        }
        statuses.sort_by_key(|value| (value["peer_id"].as_str().unwrap_or("").to_owned(),
            value["local_port"].as_u64().unwrap_or(0)));
        Ok(serde_json::json!({"schema":1,"namespace":selector.namespace,"endpoints":statuses}).to_string())
    })();
    result.unwrap_or_default()
}

// Shared by the real session event publisher and the cross-language contract fixture.
fn status_json(namespace: &str, peer_id: &str, local_port: u16, target: &Target,
    generation: u64, revision: u64, phase: &str, reason: &str,
    remote_phase: Option<&str>, local_resources_closed: bool) -> String {
    serde_json::json!({"namespace":namespace,"peer_id":peer_id,"local_port":local_port,
        "target":{"host":target.host(),"port":target.port()},
        "generation":generation.to_string(),"revision":revision.to_string(),
        "phase":phase,"reason":reason,"remote_phase":remote_phase,
        "local_resources_closed":local_resources_closed}).to_string()
}

fn failure_reason(error: &str) -> &'static str {
    match error {
        "tunnel_local_port_unavailable" => "tunnel_local_port_unavailable",
        "tunnel_status_unconfirmed" | "tunnel_send_queue_expired" => "tunnel_status_unconfirmed",
        "tunnel_namespace_changed" => "tunnel_namespace_changed",
        "tunnel_protocol_unsupported" | "tunnel_protocol_probe_expired" |
            "tunnel_protocol_probe_invalid" => "tunnel_protocol_unsupported",
        "tunnel_cancelled" => "tunnel_cancelled",
        _ => "tunnel_connection_failed",
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Command {
    namespace: String,
    peer_id: String,
    op: String,
    local_port: i32,
    host: Option<String>,
    remote_port: Option<i32>,
}
impl Command {
    fn parse(json: &str) -> ResultType<Self> {
        if json.len() > 4096 { bail!("tunnel_invalid_command"); }
        let value: Self = serde_json::from_str(json).map_err(|_| anyhow!("tunnel_invalid_command"))?;
        if value.namespace.len() != 64 || !value.namespace.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
            || crate::nikodesk::validate_remote_id(&value.peer_id).is_err() || !(1..=65535).contains(&value.local_port) {
            bail!("tunnel_invalid_command");
        }
        match value.op.as_str() {
            "add" => {
                Target::parse(value.host.as_deref().ok_or_else(|| anyhow!("tunnel_invalid_target"))?,
                    value.remote_port.ok_or_else(|| anyhow!("tunnel_invalid_target"))?)
                    .map_err(|_| anyhow!("tunnel_invalid_target"))?;
            }
            "remove" if value.host.is_none() && value.remote_port.is_none() => {},
            _ => bail!("tunnel_invalid_command"),
        }
        Ok(value)
    }
    fn data(&self) -> ResultType<Data> {
        if self.op == "remove" { return Ok(Data::RemovePortForward(self.local_port)); }
        let target = Target::parse(self.host.as_deref().ok_or_else(|| anyhow!("tunnel_invalid_target"))?,
            self.remote_port.ok_or_else(|| anyhow!("tunnel_invalid_target"))?)
            .map_err(|_| anyhow!("tunnel_invalid_target"))?;
        Ok(Data::AddPortForward((self.local_port, target.host().to_owned(), i32::from(target.port()))))
    }
}

#[cfg(feature = "flutter")]
pub(crate) fn command(session_id: crate::flutter_ffi::SessionID, json: String) -> String {
    let result = (|| -> ResultType<()> {
        let command = Command::parse(&json)?;
        let session = crate::flutter::sessions::get_session_by_session_id(&session_id)
            .ok_or_else(|| anyhow!("tunnel_session_closed"))?;
        if !session.is_port_forward() || session.is_rdp() { bail!("tunnel_session_mismatch"); }
        let snapshot = session.connection_snapshot()?;
        if snapshot.namespace() != command.namespace || session.get_id() != command.peer_id {
            bail!("tunnel_namespace_changed");
        }
        // Cancellation is still allowed for the original session after a switch.
        if command.op == "add" {
            let key = snapshot.peer_key(&command.peer_id).ok_or_else(|| anyhow!("tunnel_namespace_changed"))?;
            if !key.is_current() || crate::nikodesk::background::is_system_worker() {
                bail!("tunnel_namespace_changed");
            }
        }
        let sender = session.sender.read().map_err(|_| anyhow!("tunnel_worker_failed"))?
            .clone().ok_or_else(|| anyhow!("tunnel_session_not_ready"))?;
        sender.send(command.data()?).map_err(|_| anyhow!("tunnel_session_closed"))?;
        Ok(())
    })();
    match result {
        Ok(()) => serde_json::json!({"ok":true,"reason":"queued"}).to_string(),
        Err(error) => serde_json::json!({"ok":false,"reason":error.to_string()}).to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn controller_status_fixture_uses_production_serializer() {
        let target = Target::parse("[::1]", 23456).unwrap();
        let cases = [
            ("Connecting", "tunnel_connecting", None, false),
            ("WaitingApproval", "tunnel_waiting_approval", Some("Pending"), false),
            ("Starting", "tunnel_starting", Some("Starting"), false),
            ("Listening", "tunnel_listening", Some("Running"), false),
            ("Stopping", "tunnel_stopping", Some("Revoking"), false),
            ("Closed", "tunnel_local_closed", Some("Revoking"), true),
            ("Failed", "tunnel_local_port_unavailable", None, true),
            ("RecoveryRequired", "tunnel_local_cleanup_unconfirmed", Some("RecoveryRequired"), false),
        ];
        let statuses: Vec<serde_json::Value> = cases.iter().enumerate().map(|(index, case)| {
            let raw = status_json(&"a".repeat(64), "123456789", 12345, &target,
                9007199254740993, index as u64 + 1, case.0, case.1, case.2, case.3);
            let value: serde_json::Value = serde_json::from_str(&raw).unwrap();
            assert_eq!(value.as_object().unwrap().len(), 10);
            assert_eq!(value["generation"], "9007199254740993");
            assert_eq!(value["revision"], (index + 1).to_string());
            assert_eq!(value["target"]["host"], "::1");
            value
        }).collect();
        // Export only synthetic metadata when explicitly requested by the verifier.
        if let Some(path) = std::env::var_os("NIKODESK_TUNNEL_CONTROLLER_FIXTURE") {
            let fixture = serde_json::json!({"schema":"nikodesk-tunnel-controller-fixture-v1",
                "synthetic":true,"event_name":"nikodesk_tunnel_controller","statuses":statuses});
            std::fs::write(path, serde_json::to_vec_pretty(&fixture).unwrap()).unwrap();
        }
    }
    fn add() -> serde_json::Value { serde_json::json!({"namespace":"a".repeat(64),"peer_id":"123456789",
        "op":"add","local_port":12345,"host":"[::1]","remote_port":23456}) }
    #[test]
    fn commands_normalize_targets_and_cannot_supply_authorization() {
        let value = Command::parse(&add().to_string()).unwrap();
        assert!(matches!(value.data().unwrap(), Data::AddPortForward((12345, host, 23456)) if host == "::1"));
        let mut bad = add(); bad["approved"] = true.into();
        assert!(Command::parse(&bad.to_string()).is_err());
        for port in [0, -1, 65536] {
            let mut bad = add(); bad["local_port"] = port.into();
            assert!(Command::parse(&bad.to_string()).is_err());
        }
    }
    #[test]
    fn cancellation_cannot_replace_a_target_or_namespace() {
        let mut value = add(); value["op"] = "remove".into();
        assert!(Command::parse(&value.to_string()).is_err());
        let raw = value.as_object_mut().unwrap(); raw.remove("host"); raw.remove("remote_port");
        assert!(matches!(Command::parse(&value.to_string()).unwrap().data().unwrap(), Data::RemovePortForward(12345)));
        value["namespace"] = "B".repeat(64).into();
        assert!(Command::parse(&value.to_string()).is_err());
    }
    #[test]
    fn arbitrary_network_errors_never_enter_the_controller_status() {
        assert_eq!(failure_reason("secret=synthetic-example"), "tunnel_connection_failed");
        assert_eq!(failure_reason("tunnel_local_port_unavailable"), "tunnel_local_port_unavailable");
    }
}
