//! Explicit per-session routing inputs. No task-local or mutable global route state.
use super::server_scope::{PeerStorageKey, ServerScope};
use hbb_common::{
    anyhow::{anyhow, Context},
    bail,
    config::{Config, Socks5Server},
    rendezvous_proto::ConnType,
    sodiumoxide::base64,
    tcp::FramedStream,
    tokio::{self, net::UdpSocket},
    websocket::WsFramedStream,
    ResultType, Stream,
};
use std::{
    collections::HashMap,
    net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr},
    sync::Arc,
};

#[derive(Clone, PartialEq, Eq, Hash)]
pub struct RegistryKey {
    pub namespace: String,
    pub peer_id: String,
    pub conn_type: ConnType,
}

impl RegistryKey {
    pub fn new(namespace: &str, peer_id: &str, conn_type: ConnType) -> ResultType<Self> {
        validate_namespace(namespace)?;
        super::validate_remote_id(peer_id)?;
        Ok(Self {
            namespace: namespace.to_owned(),
            peer_id: peer_id.to_owned(),
            conn_type,
        })
    }
}

pub fn validate_namespace(namespace: &str) -> ResultType<()> {
    if ServerScope::from_namespace(namespace).is_none() {
        bail!("NikoDesk session requires its original server namespace");
    }
    Ok(())
}

impl RegistryKey {
    pub fn check_uuid_binding<'a>(
        &self,
        occupied: impl Iterator<Item = &'a Self>,
        allow_same: bool,
    ) -> ResultType<()> {
        for existing in occupied {
            if !allow_same || existing != self {
                bail!("NikoDesk session UUID already belongs to another connection");
            }
        }
        Ok(())
    }
}

// Deliberately has no Debug/Serialize implementation: proxy credentials stay in memory.
#[derive(Clone)]
pub struct ConnectionSnapshot {
    scope: ServerScope,
    rendezvous: String,
    key: String,
    relay: String,
    proxy: Option<Socks5Server>,
    websocket: bool,
    secure_websocket: bool,
    pub tcp_punch: bool,
    pub udp_punch: bool,
}

impl ConnectionSnapshot {
    pub fn capture(expected_namespace: &str) -> ResultType<Arc<Self>> {
        validate_namespace(expected_namespace)?;
        let snapshot = Self::capture_current()?;
        if snapshot.namespace() != expected_namespace {
            bail!(
                "NikoDesk server identity changed; reconnect from the current server's device list"
            );
        }
        Ok(snapshot)
    }

    pub fn capture_current() -> ResultType<Arc<Self>> {
        super::initialize()?;
        let options = super::server_settings::read_verified_options()?;
        // Each independent application preference is cloned once. A later proxy or
        // transport change applies to newly created sessions, never this snapshot.
        let proxy = Config::get_socks();
        let tcp = crate::get_tcp_punch_enabled();
        let udp = crate::get_udp_punch_enabled();
        Ok(Arc::new(Self::from_options(&options, proxy, tcp, udp)?))
    }

    fn from_options(
        options: &HashMap<String, String>,
        proxy: Option<Socks5Server>,
        tcp: bool,
        udp: bool,
    ) -> ResultType<Self> {
        if options.get("stop-service").map(String::as_str) != Some("N") {
            bail!("NikoDesk is paused");
        }
        let id = options
            .get("custom-rendezvous-server")
            .map(String::as_str)
            .unwrap_or_default();
        let relay = options
            .get("relay-server")
            .map(String::as_str)
            .unwrap_or_default();
        let key = options.get("key").map(String::as_str).unwrap_or_default();
        super::validate_server_values(id, relay, key)?;
        let scope = ServerScope::from_options(options)
            .ok_or_else(|| anyhow!("Invalid NikoDesk server identity"))?;
        let key = base64::decode(key, base64::Variant::Original)
            .map_err(|_| anyhow!("Invalid NikoDesk server public key"))?;
        let websocket = hbb_common::config::option2bool(
            "allow-websocket",
            options
                .get("allow-websocket")
                .map(String::as_str)
                .unwrap_or_default(),
        );
        if websocket && proxy.is_some() {
            // Upstream WsFramedStream ignores its proxy argument. Do not silently
            // bypass the captured proxy for WebSocket connections.
            bail!("NikoDesk cannot combine WebSocket with a proxy; use TCP with the proxy");
        }
        Ok(Self {
            scope,
            rendezvous: hbb_common::socket_client::check_port(id, 21116),
            key: base64::encode(key, base64::Variant::Original),
            relay: if relay.is_empty() {
                String::new()
            } else {
                hbb_common::socket_client::check_port(relay, 21117)
            },
            proxy,
            websocket,
            secure_websocket: options
                .get("api-server")
                .map_or(false, |v| v.starts_with("https")),
            // Preserve upstream's TCP backstop when every enabled direct transport
            // is disabled. NikoDesk's IPv6 and WebRTC gates remain disabled.
            tcp_punch: tcp || !udp,
            udp_punch: udp,
        })
    }

    pub fn namespace(&self) -> &str {
        self.scope.namespace()
    }
    pub fn peer_key(&self, id: &str) -> Option<PeerStorageKey> {
        self.scope.peer_key(id)
    }
    pub fn registry_key(&self, id: &str, conn_type: ConnType) -> ResultType<RegistryKey> {
        RegistryKey::new(self.namespace(), id, conn_type)
    }
    pub fn key(&self) -> &str {
        &self.key
    }
    pub fn rendezvous(&self) -> &str {
        &self.rendezvous
    }
    pub fn proxy_enabled(&self) -> bool {
        self.proxy.is_some()
    }
    pub(crate) fn websocket_enabled(&self) -> bool {self.websocket}
    pub fn forces_relay(&self) -> bool {
        self.proxy_enabled() || self.websocket
    }
    pub fn relay_protocol(&self) -> &'static str {
        if self.websocket {
            "WebSocket"
        } else {
            "Relay"
        }
    }

    pub fn relay_target(&self, advertised: &str) -> ResultType<String> {
        let relay = if self.relay.is_empty() {
            advertised
        } else {
            &self.relay
        };
        super::validate_server_address(relay)?;
        Ok(hbb_common::socket_client::check_port(relay, 21117))
    }

    pub fn optional_relay_target(&self, advertised: &str) -> ResultType<String> {
        if advertised.is_empty() && self.relay.is_empty() {
            return Ok(String::new());
        }
        self.relay_target(advertised)
    }

    // Called only after the native transport wins and is secured. A nonempty
    // captured relay overrides every advertised relay in relay_target(), so this
    // is the target used by that transport, not a later Config lookup or a DNS IP.
    // With an advertised-only relay we cannot recover the winning target here.
    pub(crate) fn connected_route_json(&self, direct: bool) -> Option<String> {
        let relay_target = if direct || self.relay.is_empty() {
            None
        } else if self.websocket {
            self.websocket_target(&self.relay, true).ok()
        } else {
            Some(self.relay.clone())
        };
        let websocket_tls = relay_target.as_ref().and_then(|target| {
            self.websocket.then(|| target.starts_with("wss://"))
        });
        serde_json::to_string(&serde_json::json!({
            "schemaVersion": 1,
            "relayTarget": relay_target,
            "relayTargetSource": relay_target.as_ref().map(|_| "captured_private_relay"),
            "proxyInUse": !direct && self.proxy.is_some(),
            "websocketTls": websocket_tls,
        })).ok()
    }

    fn websocket_target(&self, target: &str, relay: bool) -> ResultType<String> {
        let (host, port) = hbb_common::socket_client::split_host_port(target)
            .ok_or_else(|| anyhow!("Invalid NikoDesk WebSocket target"))?;
        let ip = host
            .trim_start_matches('[')
            .trim_end_matches(']')
            .parse::<IpAddr>()
            .is_ok();
        if ip {
            let port = port
                .checked_add(2)
                .filter(|p| *p <= 65535)
                .ok_or_else(|| anyhow!("Invalid NikoDesk WebSocket port"))?;
            Ok(format!("ws://{host}:{port}"))
        } else {
            let scheme = if self.secure_websocket { "wss" } else { "ws" };
            Ok(format!(
                "{scheme}://{host}/ws/{}",
                if relay { "relay" } else { "id" }
            ))
        }
    }

    pub async fn connect_server(
        &self,
        target: String,
        relay: bool,
        timeout: u64,
    ) -> ResultType<Stream> {
        if self.websocket {
            let target = self.websocket_target(&target, relay)?;
            return Ok(Stream::WebSocket(
                WsFramedStream::new_strict(target, timeout).await?,
            ));
        }
        self.connect_direct(target, None, timeout).await
    }

    pub async fn connect_direct(
        &self,
        target: String,
        local: Option<SocketAddr>,
        timeout: u64,
    ) -> ResultType<Stream> {
        match &self.proxy {
            Some(proxy) => Ok(Stream::Tcp(
                FramedStream::connect(target, local, proxy, timeout).await?,
            )),
            None => Ok(Stream::Tcp(
                FramedStream::new(target, local, timeout).await?,
            )),
        }
    }

    pub async fn direct_udp(&self) -> ResultType<(Arc<UdpSocket>, SocketAddr)> {
        if self.forces_relay() {
            bail!("NikoDesk's captured route requires a relay");
        }
        let remote = hbb_common::timeout(1000, tokio::net::lookup_host(&self.rendezvous))
            .await??
            .next()
            .context("Cannot resolve captured NikoDesk rendezvous server")?;
        let local = SocketAddr::new(
            if remote.is_ipv4() {
                IpAddr::V4(Ipv4Addr::UNSPECIFIED)
            } else {
                IpAddr::V6(Ipv6Addr::UNSPECIFIED)
            },
            0,
        );
        Ok((Arc::new(UdpSocket::bind(local).await?), remote))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn options() -> HashMap<String, String> {
        HashMap::from([
            ("custom-rendezvous-server".into(), "private.example".into()),
            (
                "key".into(),
                base64::encode([7; 32], base64::Variant::Original),
            ),
            ("stop-service".into(), "N".into()),
        ])
    }
    #[test]
    fn same_numeric_peer_and_type_on_two_servers_have_distinct_registry_keys() {
        let a = ConnectionSnapshot::from_options(&options(), None, true, true).unwrap();
        let mut next = options();
        next.insert(
            "key".into(),
            base64::encode([8; 32], base64::Variant::Original),
        );
        let b = ConnectionSnapshot::from_options(&next, None, true, true).unwrap();
        let mut registry = HashMap::new();
        registry.insert(
            a.registry_key("123456789", ConnType::DEFAULT_CONN).unwrap(),
            "original",
        );
        registry
            .entry(b.registry_key("123456789", ConnType::DEFAULT_CONN).unwrap())
            .or_insert("next");
        assert_eq!(registry.len(), 2);
        assert_eq!(
            registry[&a.registry_key("123456789", ConnType::DEFAULT_CONN).unwrap()],
            "original"
        );
        assert_eq!(
            registry[&b.registry_key("123456789", ConnType::DEFAULT_CONN).unwrap()],
            "next"
        );
    }
    #[test]
    fn later_options_and_proxy_changes_do_not_mutate_captured_route() {
        let mut values = options();
        values.insert("relay-server".into(), "relay.example".into());
        let proxy = Socks5Server {
            proxy: "proxy.example:1080".into(),
            username: "synthetic".into(),
            password: "synthetic".into(),
        };
        let original =
            ConnectionSnapshot::from_options(&values, Some(proxy.clone()), false, true).unwrap();
        values.insert("custom-rendezvous-server".into(), "next.example".into());
        values.insert("relay-server".into(), "next-relay.example".into());
        let next = ConnectionSnapshot::from_options(&values, None, true, false).unwrap();
        assert_eq!(original.rendezvous(), "private.example:21116");
        assert_eq!(
            original.relay_target("provided.example").unwrap(),
            "relay.example:21117"
        );
        assert_eq!(original.proxy, Some(proxy));
        assert!(!original.tcp_punch);
        assert!(original.udp_punch);
        assert_ne!(original.namespace(), next.namespace());
    }
    #[test]
    fn relay_changes_preserve_namespace_but_new_snapshots_get_new_route() {
        let a = ConnectionSnapshot::from_options(&options(), None, true, true).unwrap();
        let mut values = options();
        values.insert("relay-server".into(), "new-relay.example:31117".into());
        let b = ConnectionSnapshot::from_options(&values, None, true, true).unwrap();
        assert_eq!(a.namespace(), b.namespace());
        assert_eq!(
            a.relay_target("provided.example").unwrap(),
            "provided.example:21117"
        );
        assert_eq!(
            b.relay_target("provided.example").unwrap(),
            "new-relay.example:31117"
        );
        assert!(a.relay_target("rs.rustdesk.com").is_err());
        assert_eq!(a.optional_relay_target("").unwrap(), "");
        assert!(a.relay_target("").is_err());
        assert_eq!(
            b.optional_relay_target("").unwrap(),
            "new-relay.example:31117"
        );
        assert!(a.optional_relay_target("rs.rustdesk.com").is_err());
    }
    #[test]
    fn websocket_targets_use_snapshot_and_proxy_combination_fails_closed() {
        let mut values = options();
        values.insert("allow-websocket".into(), "Y".into());
        values.insert("api-server".into(), "https://private.example".into());
        let snapshot = ConnectionSnapshot::from_options(&values, None, true, true).unwrap();
        assert_eq!(
            snapshot
                .websocket_target("private.example:21116", false)
                .unwrap(),
            "wss://private.example/ws/id"
        );
        assert_eq!(
            snapshot
                .websocket_target("[2001:db8::1]:21117", true)
                .unwrap(),
            "ws://[2001:db8::1]:21119"
        );
        assert!(snapshot.websocket_target("127.0.0.1:65535", true).is_err());
        assert!(ConnectionSnapshot::from_options(
            &values,
            Some(Socks5Server {
                proxy: "proxy.example:1080".into(),
                username: String::new(),
                password: String::new()
            }),
            true,
            true
        )
        .is_err());
    }
    #[test]
    fn invalid_namespace_cannot_be_an_unscoped_registry_key() {
        for namespace in [
            "",
            "unconfigured",
            "123456",
            &"A".repeat(64),
            &"g".repeat(64),
        ] {
            assert!(RegistryKey::new(namespace, "123456789", ConnType::DEFAULT_CONN).is_err());
        }
        let snapshot = ConnectionSnapshot::from_options(&options(), None, false, false).unwrap();
        assert!(snapshot.tcp_punch);
        assert!(snapshot
            .registry_key("123456@private.example", ConnType::DEFAULT_CONN)
            .is_err());
        let mut paused = options();
        paused.insert("stop-service".into(), "Y".into());
        assert!(ConnectionSnapshot::from_options(&paused, None, true, true).is_err());
    }

    #[cfg(feature = "flutter")]
    #[test]
    fn invalid_scope_ffi_operations_reject_before_identity_or_peer_files() {
        use crate::flutter_ffi;
        let session_id = flutter_ffi::SessionID::new_v4();
        let result = flutter_ffi::session_add_nikodesk_sync(
            session_id.clone(),
            "123456789".into(),
            "unconfigured".into(),
            false,
            false,
            false,
            false,
            false,
            String::new(),
            false,
            "synthetic".into(),
            false,
            None,
        );
        assert!(!result.0.is_empty());
        assert!(!flutter_ffi::session_add_sync(
            session_id.clone(),
            "123456789".into(),
            false,
            false,
            false,
            false,
            false,
            String::new(),
            false,
            "synthetic".into(),
            false,
            None,
        )
        .0
        .is_empty());
        assert!(!flutter_ffi::session_add_nikodesk_existed_sync(
            "123456789".into(),
            session_id,
            vec![],
            false,
            "unconfigured".into(),
        )
        .0
        .is_empty());
        assert_eq!(
            flutter_ffi::peer_get_nikodesk_sessions_count(
                "123456789".into(),
                ConnType::DEFAULT_CONN as i32,
                "unconfigured".into(),
            )
            .0,
            0
        );
        assert_eq!(
            flutter_ffi::main_get_nikodesk_peer_option_sync(
                "123456789".into(),
                "unconfigured".into(),
                "alias".into(),
            )
            .0,
            ""
        );
        assert!(
            !flutter_ffi::main_set_nikodesk_peer_option_sync(
                "123456789".into(),
                "unconfigured".into(),
                "alias".into(),
                "synthetic".into(),
            )
            .0
        );
        assert_eq!(
            flutter_ffi::main_get_nikodesk_peer_flutter_option_sync(
                "123456789".into(),
                "unconfigured".into(),
                "window".into(),
            )
            .0,
            ""
        );
        assert!(
            !flutter_ffi::main_set_nikodesk_peer_flutter_option_sync(
                "123456789".into(),
                "unconfigured".into(),
                "window".into(),
                "synthetic".into(),
            )
            .0
        );
    }

    #[test]
    fn an_existing_uuid_cannot_change_server_device_or_type() {
        let snapshot = ConnectionSnapshot::from_options(&options(), None, true, true).unwrap();
        let original = snapshot
            .registry_key("123456789", ConnType::DEFAULT_CONN)
            .unwrap();
        assert!(original
            .check_uuid_binding(std::iter::empty(), false)
            .is_ok());
        assert!(original
            .check_uuid_binding(std::iter::once(&original), true)
            .is_ok());
        assert!(original
            .check_uuid_binding(std::iter::once(&original), false)
            .is_err());
        let mut values = options();
        values.insert("custom-rendezvous-server".into(), "next.example".into());
        let next = ConnectionSnapshot::from_options(&values, None, true, true).unwrap();
        for request in [
            next.registry_key("123456789", ConnType::DEFAULT_CONN)
                .unwrap(),
            snapshot
                .registry_key("987654321", ConnType::DEFAULT_CONN)
                .unwrap(),
            snapshot
                .registry_key("123456789", ConnType::FILE_TRANSFER)
                .unwrap(),
        ] {
            assert!(request
                .check_uuid_binding(std::iter::once(&original), true)
                .is_err());
            assert!(request
                .check_uuid_binding(std::iter::once(&original), false)
                .is_err());
        }
    }

    #[test]
    fn connected_route_uses_the_captured_override_and_omits_proxy_credentials() {
        let mut values = options();
        values.insert("relay-server".into(), "relay.example:31117".into());
        let snapshot = ConnectionSnapshot::from_options(&values, Some(Socks5Server {
            proxy: "proxy.example:1080".into(), username: "private-user".into(),
            password: "private-password".into(),
        }), true, true).unwrap();
        values.insert("relay-server".into(), "later.example:41117".into());
        let telemetry = super::super::video_metrics::SessionTelemetry::new(
            snapshot.namespace().to_owned(), Arc::new(std::sync::atomic::AtomicBool::new(false)),
            Arc::new(std::sync::atomic::AtomicU64::new(0)));
        telemetry.capture_connection_route(&snapshot, false);
        let json = telemetry.connection_route().unwrap();
        let route: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert_eq!(route["relayTarget"], "relay.example:31117");
        assert_eq!(route["proxyInUse"], true);
        for private in ["later.example", "proxy.example", "private-user", "private-password"] {
            assert!(!json.contains(private));
        }
        telemetry.stop();
        assert!(telemetry.connection_route().is_none());
        let direct: serde_json::Value = serde_json::from_str(&snapshot.connected_route_json(true).unwrap()).unwrap();
        assert!(direct["relayTarget"].is_null());
        assert_eq!(direct["proxyInUse"], false);
        let advertised_only = ConnectionSnapshot::from_options(&options(), None, true, true).unwrap();
        let unknown: serde_json::Value = serde_json::from_str(&advertised_only.connected_route_json(false).unwrap()).unwrap();
        assert!(unknown["relayTarget"].is_null());
        assert!(unknown["relayTargetSource"].is_null());
    }

    #[test]
    fn connected_websocket_route_reports_the_actual_url_and_tls_scheme() {
        let mut values = options();
        values.insert("relay-server".into(), "relay.example:21117".into());
        values.insert("allow-websocket".into(), "Y".into());
        values.insert("api-server".into(), "https://private.example".into());
        let snapshot = ConnectionSnapshot::from_options(&values, None, true, true).unwrap();
        let route: serde_json::Value = serde_json::from_str(&snapshot.connected_route_json(false).unwrap()).unwrap();
        assert_eq!(route["relayTarget"], "wss://relay.example/ws/relay");
        assert_eq!(route["websocketTls"], true);
        values.insert("relay-server".into(), "[2001:db8::1]:21117".into());
        let snapshot = ConnectionSnapshot::from_options(&values, None, true, true).unwrap();
        let route: serde_json::Value = serde_json::from_str(&snapshot.connected_route_json(false).unwrap()).unwrap();
        assert_eq!(route["relayTarget"], "ws://[2001:db8::1]:21119");
        assert_eq!(route["websocketTls"], false);
    }
}
