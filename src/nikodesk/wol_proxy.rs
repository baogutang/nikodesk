//! Optional LAN wake receiver in the existing private NikoDesk core.
//! No service is installed and no public listener is opened by this module.
use super::{server_scope, server_settings};
use hbb_common::{anyhow::anyhow, bail, ResultType};
use nikodesk_wol_agent::{Config, Target};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::HashMap;

pub(crate) const OPTION: &str = "nikodesk-wake-proxy-v1";
const ADDRESS: &str = "127.0.0.1:21128";

#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Policy {
    version: u32,
    namespace: String,
    enabled: bool,
    targets: Vec<Target>,
}

impl Policy {
    fn parse(raw: &str) -> ResultType<Self> {
        if raw.len() > 32768 {
            bail!("wake_proxy_invalid_policy");
        }
        let mut policy: Self =
            serde_json::from_str(raw).map_err(|_| anyhow!("wake_proxy_invalid_policy"))?;
        if policy.version != 1
            || policy.namespace.len() != 64
            || policy
                .namespace
                .bytes()
                .any(|b| !(b'0'..=b'9').contains(&b) && !(b'a'..=b'f').contains(&b))
            || policy.namespace.bytes().all(|b| b == b'0')
            || policy.targets.len() > 64
            || policy.enabled && policy.targets.is_empty()
        {
            bail!("wake_proxy_invalid_policy");
        }
        let mut seen = std::collections::HashSet::new();
        for target in &mut policy.targets {
            let mac = nikodesk_wol_agent::mac(&target.mac)
                .map_err(|_| anyhow!("wake_proxy_invalid_target"))?;
            target.mac = mac
                .iter()
                .map(|b| format!("{b:02X}"))
                .collect::<Vec<_>>()
                .join(":");
            Config {
                schema: 1,
                listen: ADDRESS.parse()?,
                targets: vec![target.clone()],
            }
            .validate()
            .map_err(|_| anyhow!("wake_proxy_invalid_target"))?;
            if !seen.insert((mac, target.broadcast, target.port)) {
                bail!("wake_proxy_duplicate_target");
            }
        }
        // Stable policy identity even if the UI displays the rows in a new order.
        policy
            .targets
            .sort_by(|a, b| (&a.mac, a.broadcast, a.port).cmp(&(&b.mac, b.broadcast, b.port)));
        Ok(policy)
    }

    fn revision(&self) -> ResultType<String> {
        Ok(Sha256::digest(serde_json::to_vec(self)?)
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect())
    }

    fn config(&self) -> Config {
        Config {
            schema: 1,
            listen: ADDRESS.parse().unwrap(),
            targets: self.targets.clone(),
        }
    }
}

pub(crate) fn validate_patch(raw: &str, options: &HashMap<String, String>) -> ResultType<()> {
    if raw.is_empty() {
        return Ok(());
    }
    let policy = Policy::parse(raw)?;
    if server_scope::namespace_from_options(options).as_deref() != Some(&policy.namespace) {
        bail!("wake_proxy_namespace_changed");
    }
    #[cfg(any(target_os = "android", target_os = "ios"))]
    if policy.enabled {
        bail!("wake_proxy_controller_only");
    }
    Ok(())
}

fn configured(options: &HashMap<String, String>, namespace: &str) -> ResultType<Policy> {
    if server_scope::namespace_from_options(options).as_deref() != Some(namespace) {
        bail!("wake_proxy_namespace_changed");
    }
    let raw = options.get(OPTION).map(String::as_str).unwrap_or("");
    if raw.is_empty() {
        return Ok(Policy {
            version: 1,
            namespace: namespace.into(),
            enabled: false,
            targets: vec![],
        });
    }
    let policy = Policy::parse(raw)?;
    if policy.namespace != namespace {
        // Switching private servers never carries a LAN allowlist into the
        // new realm. The old policy is inactive and the new realm starts off.
        return Ok(Policy {
            version: 1,
            namespace: namespace.into(),
            enabled: false,
            targets: vec![],
        });
    }
    Ok(policy)
}

#[cfg(not(any(target_os = "android", target_os = "ios")))]
fn active() -> ResultType<Policy> {
    // Never expose arbitrary forwarding through an elevated machine worker.
    if super::background::is_system_worker() {
        bail!("wake_proxy_machine_role_unavailable");
    }
    let options = server_settings::read_verified_options()?;
    let namespace = server_scope::namespace_from_options(&options)
        .ok_or_else(|| anyhow!("wake_proxy_private_server_unavailable"))?;
    let policy = configured(&options, &namespace)?;
    if !policy.enabled || options.get("stop-service").map(String::as_str) != Some("N") {
        bail!("wake_proxy_disabled");
    }
    Ok(policy)
}

#[cfg(not(any(target_os = "android", target_os = "ios")))]
pub(crate) fn start() {
    use std::{net::TcpListener, sync::OnceLock, thread, time::Duration};
    static STARTED: OnceLock<()> = OnceLock::new();
    if super::background::is_system_worker() {
        return;
    }
    STARTED.get_or_init(|| {
        if thread::Builder::new()
            .name("niko-wake-proxy".into())
            .spawn(|| {
                let mut listener: Option<TcpListener> = None;
                let mut identity = String::new();
                loop {
                    let policy = match active() {
                        Ok(policy) => policy,
                        Err(_) => {
                            listener.take();
                            identity.clear();
                            thread::sleep(Duration::from_millis(500));
                            continue;
                        }
                    };
                    let revision = match policy.revision() {
                        Ok(value) => value,
                        Err(_) => continue,
                    };
                    if revision != identity {
                        listener.take();
                        identity = revision.clone();
                    }
                    if listener.is_none() {
                        listener = TcpListener::bind(ADDRESS)
                            .ok()
                            .and_then(|bound| bound.set_nonblocking(true).ok().map(|_| bound));
                        if listener.is_none() {
                            thread::sleep(Duration::from_secs(1));
                            continue;
                        }
                    }
                    match listener.as_ref().unwrap().accept() {
                        Ok((mut stream, address)) if address.ip().is_loopback() => {
                            // A single bounded request at a time. Policy is freshly
                            // verified before every send, including mid-request revocation.
                            let _ = nikodesk_wol_agent::handle_guarded(
                                &mut stream,
                                &policy.config(),
                                Some(nikodesk_wol_agent::Scope {
                                    namespace: &policy.namespace,
                                    revision: &revision,
                                }),
                                || {
                                    active()
                                        .and_then(|current| current.revision())
                                        .ok()
                                        .as_deref()
                                        == Some(&revision)
                                },
                            );
                        }
                        Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                            thread::sleep(Duration::from_millis(100));
                        }
                        _ => {
                            listener.take();
                        }
                    }
                }
            })
            .is_err()
        {
            hbb_common::log::warn!("NikoDesk wake receiver could not start");
        }
    });
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Selector {
    namespace: String,
}

/// Configuration readback and actual listener health are separate facts.
pub(crate) fn status(selector: &str) -> String {
    let result = (|| -> ResultType<serde_json::Value> {
        if selector.len() > 256 {
            bail!("wake_proxy_invalid_selector");
        }
        let selector: Selector = serde_json::from_str(selector)?;
        let options = server_settings::read_verified_options()?;
        let policy = configured(&options, &selector.namespace)?;
        let revision = policy.revision()?;
        let mut state = if policy.enabled {
            "unavailable"
        } else {
            "disabled"
        };
        #[cfg(not(any(target_os = "android", target_os = "ios")))]
        if policy.enabled {
            if super::background::is_system_worker() {
                state = "unsupported";
            } else if options.get("stop-service").map(String::as_str) != Some("N") {
                state = "paused";
            } else if healthy(&policy.namespace, &revision) {
                state = "listening";
            }
        }
        #[cfg(any(target_os = "android", target_os = "ios"))]
        {
            state = "unsupported";
        }
        // Probe I/O cannot turn a stale server/profile into a valid result.
        let current = server_settings::read_verified_options()?;
        if configured(&current, &selector.namespace)?.revision()? != revision
            || current.get("stop-service") != options.get("stop-service")
        {
            bail!("wake_proxy_namespace_changed");
        }
        Ok(
            serde_json::json!({"schema":1,"namespace":selector.namespace,
            "policy":policy,"revision":revision,"state":state}),
        )
    })();
    result
        .map(|value| value.to_string())
        .unwrap_or_else(|_| "".into())
}

#[cfg(not(any(target_os = "android", target_os = "ios")))]
fn healthy(namespace: &str, revision: &str) -> bool {
    use std::{
        io::{Read, Write},
        net::TcpStream,
        time::{Duration, Instant},
    };
    let result = (|| -> ResultType<()> {
        let mut stream = TcpStream::connect_timeout(&ADDRESS.parse()?, Duration::from_millis(400))?;
        stream.set_write_timeout(Some(Duration::from_millis(400)))?;
        let request_id = hbb_common::uuid::Uuid::new_v4().simple().to_string();
        writeln!(
            stream,
            "{}",
            serde_json::json!({"schema":1,"command":"health",
            "namespace":namespace,"request_id":request_id})
        )?;
        let deadline = Instant::now() + Duration::from_millis(800);
        let mut bytes = Vec::new();
        loop {
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() || bytes.len() >= 1024 {
                bail!("wake_proxy_unavailable");
            }
            stream.set_read_timeout(Some(remaining))?;
            let mut byte = [0];
            if stream.read(&mut byte)? != 1 {
                bail!("wake_proxy_unavailable");
            }
            if byte[0] == b'\n' {
                break;
            }
            bytes.push(byte[0]);
        }
        let reply: serde_json::Value = serde_json::from_slice(&bytes)?;
        let fields = reply
            .as_object()
            .ok_or_else(|| anyhow!("wake_proxy_unavailable"))?;
        if fields.len() != 6
            || reply["schema"] != 1
            || reply["request_id"] != request_id
            || reply["command"] != "health"
            || reply["namespace"] != namespace
            || reply["revision"] != revision
            || reply["ready"] != true
        {
            bail!("wake_proxy_unavailable");
        }
        Ok(())
    })();
    result.is_ok()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn save_is_bound_to_the_private_tuple_and_canonical_order() {
        let mut options = HashMap::from([
            (
                "custom-rendezvous-server".into(),
                "192.168.1.10:21116".into(),
            ),
            (
                "key".into(),
                hbb_common::sodiumoxide::base64::encode(
                    &[1; 32],
                    hbb_common::sodiumoxide::base64::Variant::Original,
                ),
            ),
        ]);
        let namespace = server_scope::namespace_from_options(&options).unwrap();
        let raw = serde_json::json!({"version":1,"namespace":namespace,"enabled":true,
            "targets":[{"mac":"02:11:22:33:44:55","broadcast":"10.12.0.255","port":21},
                {"mac":"02:11:22:33:44:55","broadcast":"10.2.0.255","port":9},
                {"mac":"02:11:22:33:44:55","broadcast":"10.12.0.255","port":9}]})
        .to_string();
        assert!(validate_patch(&raw, &options).is_ok());
        let parsed = Policy::parse(&raw).unwrap();
        assert_eq!(
            parsed.targets[0].broadcast,
            "10.2.0.255".parse::<std::net::Ipv4Addr>().unwrap()
        );
        assert_eq!(parsed.targets[1].port, 9);
        options.insert(
            "custom-rendezvous-server".into(),
            "192.168.1.11:21116".into(),
        );
        assert!(validate_patch(&raw, &options).is_err());
        options.insert(OPTION.into(), raw);
        let namespace = server_scope::namespace_from_options(&options).unwrap();
        let inactive = configured(&options, &namespace).unwrap();
        assert!(!inactive.enabled && inactive.targets.is_empty());
        assert!(validate_patch("", &options).is_ok());
    }
    #[test]
    fn policy_is_strict_and_revision_normalizes_mac_and_row_order() {
        let policy = |mac: &str, broadcast: &str| {
            serde_json::json!({"version":1,
            "namespace":"a".repeat(64),"enabled":true,
            "targets":[{"mac":mac,"broadcast":broadcast,"port":9}]})
            .to_string()
        };
        assert_eq!(
            Policy::parse(&policy("02:11:22:33:44:55", "192.168.1.255"))
                .unwrap()
                .revision()
                .unwrap(),
            Policy::parse(&policy("02-11-22-33-44-55", "192.168.1.255"))
                .unwrap()
                .revision()
                .unwrap()
        );
        assert!(Policy::parse(&policy("02:11:22:33:44:55", "8.8.8.8")).is_err());
        let mut value: serde_json::Value =
            serde_json::from_str(&policy("02:11:22:33:44:55", "192.168.1.255")).unwrap();
        let duplicate = value["targets"][0].clone();
        value["targets"].as_array_mut().unwrap().push(duplicate);
        assert!(Policy::parse(&value.to_string()).is_err());
        value["targets"] = serde_json::json!([]);
        assert!(Policy::parse(&value.to_string()).is_err());
        value["enabled"] = serde_json::json!(false);
        assert!(Policy::parse(&value.to_string()).is_ok());
        value["command"] = serde_json::json!("install");
        assert!(Policy::parse(&value.to_string()).is_err());
    }
}
