//! Private-server namespaces for local peer preferences. Wire peer IDs are unchanged.
use hbb_common::{
    config::PeerConfig,
    sodiumoxide::base64,
    ResultType,
};
use sha2::{Digest, Sha256};
use std::{collections::HashMap, net::IpAddr, path::PathBuf, time::SystemTime};

const DOMAIN: &[u8] = b"nikodesk-server-namespace-v1\0";
const PEER_PREFIX: &str = "nikodesk_v1_";

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ServerScope(String);

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PeerStorageKey {
    scope: ServerScope,
    storage: String,
}

/// Pure derivation from one option snapshot; never initializes Config or touches disk.
pub fn namespace_from_options(options: &HashMap<String, String>) -> Option<String> {
    let endpoint = canonical_endpoint(options.get("custom-rendezvous-server")?)?;
    let key = base64::decode(options.get("key")?, base64::Variant::Original).ok()?;
    if key.len() != 32 || key.iter().all(|b| *b == 0) {
        return None;
    }
    let mut digest = Sha256::new();
    digest.update(DOMAIN);
    digest.update(endpoint.as_bytes());
    digest.update(b"\0");
    digest.update(Sha256::digest(&key));
    Some(format!("{:x}", digest.finalize()))
}

fn canonical_endpoint(address: &str) -> Option<String> {
    super::validate_server_address(address).ok()?;
    let (host, port) = if let Some(tail) = address.strip_prefix('[') {
        let (host, tail) = tail.split_once(']')?;
        (host, tail.strip_prefix(':'))
    } else {
        address
            .split_once(':')
            .map_or((address, None), |(host, port)| (host, Some(port)))
    };
    let port = port.map_or(Some(21116), |p| p.parse::<u16>().ok())?;
    let host = match host.parse::<IpAddr>() {
        Ok(IpAddr::V6(ip)) => format!("[{ip}]"),
        Ok(ip) => ip.to_string(),
        Err(_) => host.to_ascii_lowercase(),
    };
    Some(format!("{host}:{port}"))
}

/// Reads a confirmed, locked settings snapshot after establishing NikoDesk's identity.
/// A failed/unconfigured scope never falls back to legacy peer files.
pub fn current() -> Option<ServerScope> {
    super::initialize().ok()?;
    let options = super::server_settings::read_verified_options().ok()?;
    namespace_from_options(&options).map(ServerScope)
}

pub fn current_peer_key(id: &str) -> Option<PeerStorageKey> {
    current()?.peer_key(id)
}

pub fn peer_key_in_namespace(namespace: &str, id: &str) -> Option<PeerStorageKey> {
    let key = ServerScope::from_namespace(namespace)?.peer_key(id)?;
    super::initialize().ok()?;
    Some(key)
}

impl ServerScope {
    pub fn from_namespace(namespace: &str) -> Option<Self> {
        (namespace.len() == 64
            && namespace
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b)))
        .then(|| Self(namespace.to_owned()))
    }

    pub(crate) fn from_options(options: &HashMap<String, String>) -> Option<Self> {
        namespace_from_options(options).map(Self)
    }

    pub fn namespace(&self) -> &str {
        &self.0
    }

    fn matches_active_options(&self, options: &HashMap<String, String>) -> bool {
        options.get("stop-service").map(String::as_str) == Some("N")
            && Self::from_options(options).as_ref() == Some(self)
    }

    fn prefix(&self) -> String {
        format!("{PEER_PREFIX}{}_", self.0)
    }

    pub fn peer_key(&self, id: &str) -> Option<PeerStorageKey> {
        super::validate_remote_id(id).ok()?;
        Some(PeerStorageKey {
            scope: self.clone(),
            storage: format!("{}{id}", self.prefix()),
        })
    }

    pub fn peer_id(&self, storage: &str) -> Option<String> {
        let id = storage.strip_prefix(&self.prefix())?;
        super::validate_remote_id(id).ok()?;
        Some(id.to_owned())
    }

    /// Filter names before upstream batch loading, which can delete incomplete files.
    pub fn peer_entries(&self) -> Vec<(String, SystemTime, PathBuf)> {
        let entries = super::favorites::application_root().and_then(|root| {
            let repository = super::peer_migration::Repository::new(root.clone());
            repository.scoped_preferences(self.namespace(), None).map(|items| {
                items.into_iter().filter_map(|(id, modified, _)| {
                    let key = self.peer_key(&id)?;
                    Some((key.storage.clone(), modified,
                        root.join(super::peer_migration::PEERS).join(format!("{}.toml", key.storage))))
                }).collect()
            })
        });
        entries.unwrap_or_else(|_| {
            hbb_common::log::warn!("NikoDesk peer list requires the fallible preferences API");
            Vec::new()
        })
    }

    fn filter_entries(
        &self,
        entries: Vec<(String, SystemTime, PathBuf)>,
    ) -> Vec<(String, SystemTime, PathBuf)> {
        entries
            .into_iter()
            .filter(|(id, _, _)| self.peer_id(id).is_some())
            .collect()
    }

    pub fn peers(&self, ids: Option<Vec<String>>) -> Vec<(String, SystemTime, PeerConfig)> {
        let entries = self
            .peer_entries()
            .into_iter()
            .filter(|(storage, _, _)| {
                ids.as_ref().map_or(true, |ids| {
                    self.peer_id(storage).map_or(false, |id| ids.contains(&id))
                })
            })
            .collect::<Vec<_>>();
        entries.into_iter()
            .filter_map(|(storage, modified, _)| {
                let id = self.peer_id(&storage)?;
                let config = self.peer_key(&id)?.load();
                Some((id, modified, config))
            })
            .collect()
    }

    /// UI list reads must report failed/corrupt storage instead of publishing
    /// a successful empty list or silently substituting default preferences.
    pub(crate) fn try_peers(&self, ids: Option<&[String]>) -> ResultType<Vec<(String, SystemTime, PeerConfig)>> {
        let repository = super::peer_migration::Repository::new(super::favorites::application_root()?);
        repository.scoped_preferences(self.namespace(), ids)?.into_iter()
            .map(|(id, modified, bytes)| {
                Ok((id, modified, decode_preferences(&bytes)?))
            }).collect()
    }

    pub fn favorites(&self) -> Vec<String> {
        self.try_favorites().unwrap_or_else(|_| {
            hbb_common::log::warn!("NikoDesk legacy favorites getter cannot report a storage failure; use the revision-aware API");
            Vec::new()
        })
    }

    pub fn try_favorites(&self) -> ResultType<Vec<String>> {
        self.try_favorites_from(super::favorites::Repository::new(super::favorites::application_root()?))
    }

    fn try_favorites_from(&self, repository: super::favorites::Repository) -> ResultType<Vec<String>> {
        repository.get(self.namespace()).map(|snapshot| snapshot.ids)
    }

    fn decode_favorites(&self, stored: &[String]) -> Vec<String> {
        stored.iter().filter_map(|id| self.peer_id(id)).collect()
    }

    fn replace_favorites(&self, mut stored: Vec<String>, ids: Vec<String>) -> Vec<String> {
        stored.retain(|id| !id.starts_with(&self.prefix()));
        for id in ids {
            if let Some(key) = self.peer_key(&id) {
                if !stored.contains(&key.storage) {
                    stored.push(key.storage);
                }
            }
        }
        stored
    }

    pub fn store_favorites(&self, ids: Vec<String>) {
        if super::favorites::application_root().and_then(|root| {
            super::favorites::Repository::new(root).replace_compat(self.namespace(), ids)
        }).is_err() { hbb_common::log::warn!("NikoDesk favorites update requires the revision-aware API"); }
    }
}

impl PeerStorageKey {
    pub(crate) fn storage(&self) -> &str { &self.storage }
    pub fn load(&self) -> PeerConfig {
        self.load_with(|storage| {
            // Decode outside the disk lock; defaults may consult Config.
            super::peer_migration::read_peer(storage).ok().flatten()
                .and_then(|bytes| std::str::from_utf8(&bytes).ok().and_then(|text| hbb_common::toml::from_str(text).ok()))
                .unwrap_or_default()
        })
    }

    fn load_with(&self, load: impl FnOnce(&str) -> PeerConfig) -> PeerConfig {
        let mut config = load(&self.storage);
        super::clear_saved_credentials(&mut config.password, &mut config.options);
        config
    }

    /// Always uses this captured key, even if settings change during the session.
    pub fn store(&self, config: &PeerConfig) {
        self.store_with(config, |storage, config| {
            match hbb_common::toml::to_string(config).map_err(Into::into)
                .and_then(|text| super::peer_migration::write_peer(storage, text.as_bytes())) {
                Ok(()) => { hbb_common::config::NEW_STORED_PEER_CONFIG.lock().unwrap().insert(storage.to_owned()); },
                Err(_) => hbb_common::log::warn!("NikoDesk peer preferences could not be persisted"),
            }
        });
    }

    fn store_with(&self, config: &PeerConfig, store: impl FnOnce(&str, &PeerConfig)) {
        let mut config = config.clone();
        super::clear_saved_credentials(&mut config.password, &mut config.options);
        store(&self.storage, &config);
    }

    pub fn exists(&self) -> bool {
        super::peer_migration::read_peer(&self.storage).map_or(false, |bytes| bytes.is_some())
    }
    pub fn remove(&self) {
        self.remove_with(|storage| {
            if super::peer_migration::remove_peer(storage).is_err() {
                hbb_common::log::warn!("NikoDesk peer preferences could not be removed");
            }
        });
    }
    fn remove_with(&self, remove: impl FnOnce(&str)) {
        remove(&self.storage);
    }
    pub fn is_current(&self) -> bool {
        if super::initialize().is_err() {
            return false;
        }
        super::server_settings::read_verified_options()
            .map_or(false, |options| self.scope.matches_active_options(&options))
    }
}

pub fn load_peer(id: &str) -> PeerConfig {
    current_peer_key(id).map_or_else(PeerConfig::default, |key| key.load())
}

fn decode_preferences(bytes: &[u8]) -> ResultType<PeerConfig> {
    let text = std::str::from_utf8(bytes)
        .map_err(|_| hbb_common::anyhow::anyhow!("invalid_peer_config"))?;
    let mut config: PeerConfig = hbb_common::toml::from_str(text)
        .map_err(|_| hbb_common::anyhow::anyhow!("invalid_peer_config"))?;
    super::clear_saved_credentials(&mut config.password, &mut config.options);
    Ok(config)
}

pub fn remove_peer(id: &str) {
    if let Some(key) = current_peer_key(id) {
        key.remove();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn damaged_peer_bytes_are_bounded_errors_without_default_substitution() {
        // Both fail before scalar defaults, hence cannot consult global Config.
        for bytes in [&[0xff, 0xfe][..], b"view_style = [".as_slice()] {
            assert_eq!(decode_preferences(bytes).unwrap_err().to_string(), "invalid_peer_config");
        }
    }

    // PeerConfig::default and its scalar deserializers consult lazy global user
    // defaults. Construct this fixture explicitly so tests cannot read those files.
    fn fixture_peer() -> PeerConfig {
        use hbb_common::config;
        PeerConfig {
            password: vec![],
            size: (0, 0, 0, 0),
            size_ft: (0, 0, 0, 0),
            size_pf: (0, 0, 0, 0),
            view_style: "original".into(),
            scroll_style: "scrollauto".into(),
            edge_scroll_edge_thickness: 100,
            image_quality: "balanced".into(),
            custom_image_quality: vec![50],
            show_remote_cursor: config::ShowRemoteCursor { v: false },
            lock_after_session_end: config::LockAfterSessionEnd { v: false },
            terminal_persistent: config::TerminalPersistent { v: false },
            privacy_mode: config::PrivacyMode { v: false },
            allow_swap_key: config::AllowSwapKey { v: false },
            port_forwards: vec![],
            direct_failures: 0,
            disable_audio: config::DisableAudio { v: false },
            disable_clipboard: config::DisableClipboard { v: false },
            enable_file_copy_paste: config::EnableFileCopyPaste { v: false },
            show_quality_monitor: config::ShowQualityMonitor { v: false },
            follow_remote_cursor: config::FollowRemoteCursor { v: false },
            follow_remote_window: config::FollowRemoteWindow { v: false },
            keyboard_mode: String::new(),
            view_only: config::ViewOnly { v: false },
            show_my_cursor: config::ShowMyCursor { v: false },
            sync_init_clipboard: config::SyncInitClipboard { v: false },
            reverse_mouse_wheel: "N".into(),
            displays_as_individual_windows: "N".into(),
            use_all_my_displays_for_the_remote_session: "N".into(),
            trackpad_speed: 100,
            custom_resolutions: HashMap::new(),
            options: HashMap::new(),
            ui_flutter: HashMap::new(),
            info: config::PeerInfoSerde {
                username: String::new(),
                hostname: String::new(),
                platform: "test".into(),
            },
            transfer: config::TransferSerde {
                write_jobs: vec![],
                read_jobs: vec![],
            },
        }
    }

    fn options(server: &str, key_byte: u8) -> HashMap<String, String> {
        HashMap::from([
            ("custom-rendezvous-server".into(), server.into()),
            (
                "key".into(),
                base64::encode([key_byte; 32], base64::Variant::Original),
            ),
        ])
    }

    fn scope(server: &str, key_byte: u8) -> ServerScope {
        ServerScope(namespace_from_options(&options(server, key_byte)).unwrap())
    }

    #[test]
    fn handshake_scope_check_rejects_paused_or_changed_identity() {
        let captured = scope("private.example", 7);
        let mut settings = options("private.example", 7);
        assert!(!captured.matches_active_options(&settings));
        settings.insert("stop-service".into(), "N".into());
        assert!(captured.matches_active_options(&settings));
        settings.insert("relay-server".into(), "new-relay.example".into());
        assert!(captured.matches_active_options(&settings));
        settings.insert("stop-service".into(), "Y".into());
        assert!(!captured.matches_active_options(&settings));
        settings.insert("stop-service".into(), "N".into());
        settings.insert(
            "key".into(),
            base64::encode([8; 32], base64::Variant::Original),
        );
        assert!(!captured.matches_active_options(&settings));
    }

    // These adapters serialize the real PeerConfig in an explicitly created temporary
    // directory. Reading projects only the fields exercised here from generic TOML;
    // it deliberately avoids PeerConfig deserializers and their lazy user defaults.
    struct TemporaryPeers(PathBuf);
    impl TemporaryPeers {
        fn new() -> Self {
            let unique = SystemTime::now()
                .duration_since(SystemTime::UNIX_EPOCH)
                .unwrap()
                .as_nanos();
            let path = std::env::temp_dir().join(format!(
                "nikodesk-scoped-peers-{}-{unique}",
                std::process::id()
            ));
            std::fs::create_dir(&path).unwrap();
            Self(path)
        }
        fn path(&self, key: &str) -> PathBuf {
            self.0.join(format!("{key}.toml"))
        }
        fn load(&self, key: &str) -> PeerConfig {
            let mut peer = fixture_peer();
            let Some(value) = std::fs::read_to_string(self.path(key))
                .ok()
                .and_then(|text| hbb_common::toml::from_str::<hbb_common::toml::Value>(&text).ok())
            else {
                return peer;
            };
            if let Some(options) = value
                .get("options")
                .and_then(hbb_common::toml::Value::as_table)
            {
                peer.options = options
                    .iter()
                    .map(|(key, value)| (key.clone(), value.as_str().unwrap().to_owned()))
                    .collect();
            }
            if let Some(password) = value
                .get("password")
                .and_then(hbb_common::toml::Value::as_array)
            {
                peer.password = password
                    .iter()
                    .map(|value| value.as_integer().unwrap() as u8)
                    .collect();
            }
            peer
        }
        fn store(&self, key: &str, config: &PeerConfig) {
            std::fs::write(self.path(key), hbb_common::toml::to_string(config).unwrap()).unwrap();
        }
    }
    impl Drop for TemporaryPeers {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn canonical_endpoint_and_default_port_share_identity() {
        assert_eq!(
            scope("PRIVATE.example", 7),
            scope("private.example:21116", 7)
        );
        assert_eq!(
            scope("private.example:021116", 7),
            scope("private.example", 7)
        );
        assert_eq!(
            scope("[2001:db8:0:0:0:0:0:1]", 7),
            scope("[2001:db8::1]:21116", 7)
        );
        assert_ne!(
            scope("private.example:21117", 7),
            scope("private.example", 7)
        );
        assert_ne!(scope("private.example", 8), scope("private.example", 7));
    }

    #[test]
    fn public_fixture_is_stable_and_relay_and_pause_are_not_identity() {
        let mut options = options("private.example", 7);
        let namespace = namespace_from_options(&options).unwrap();
        assert_eq!(
            namespace,
            "4717a60e9ab11564e57677e826ef3aa202cdc0d304cb12559c89b48058a5d484"
        );
        options.insert("relay-server".into(), "relay.example:21117".into());
        options.insert("stop-service".into(), "Y".into());
        assert_eq!(namespace_from_options(&options), Some(namespace));
    }

    #[test]
    fn invalid_identity_has_no_namespace_or_legacy_fallback() {
        for host in [
            "",
            "private.example/path",
            " public",
            "rustdesk.com",
            "private.example:0",
            "[::]",
        ] {
            assert!(namespace_from_options(&options(host, 7)).is_none());
        }
        assert!(namespace_from_options(&options("private.example", 0)).is_none());
        let mut options = options("private.example", 7);
        options.insert("key".into(), "not-base64".into());
        assert!(namespace_from_options(&options).is_none());
        options.remove("key");
        assert!(namespace_from_options(&options).is_none());
    }

    #[test]
    fn storage_keys_round_trip_only_inside_their_scope() {
        let a = scope("a.example", 7);
        let b = scope("b.example", 7);
        let key = a.peer_key("123456789").unwrap();
        assert_eq!(a.peer_id(&key.storage).as_deref(), Some("123456789"));
        assert!(b.peer_id(&key.storage).is_none());
        assert!(a.peer_id("123456789").is_none());
        for id in [
            "../123456",
            "123456@private.example",
            "123",
            "192.168.1.1",
            "123456/r",
        ] {
            assert!(a.peer_key(id).is_none());
        }
    }

    #[test]
    fn fallible_favorites_reader_preserves_error_instead_of_empty_success() {
        let temp = super::super::favorites::tests::Temp::new();
        let scope = scope("a.example", 7);
        let repository = || super::super::favorites::Repository::new(temp.0.clone());
        let snapshot = repository().get(scope.namespace()).unwrap();
        repository().patch(scope.namespace(), &snapshot.revision, &["123456789".into()], &[]).unwrap();
        assert_eq!(scope.try_favorites_from(repository()).unwrap(), ["123456789"]);
        super::super::favorites::storage::Directory::open(&temp.0).unwrap()
            .replace("nikodesk-favorites-v1.json", b"damaged fixture").unwrap();
        assert!(scope.try_favorites_from(repository()).is_err());
        assert!(scope.try_favorites_from(super::super::favorites::Repository::new(temp.0.join("missing"))).is_err());
    }

    #[test]
    fn captured_key_remains_in_original_scope_after_switch() {
        let original = scope("a.example", 7).peer_key("123456789").unwrap();
        let stored = original.storage.clone();
        let next = scope("a.example", 8).peer_key("123456789").unwrap();
        assert_ne!(stored, next.storage);
        assert_eq!(original.storage, stored);
    }

    #[test]
    fn favorite_update_preserves_legacy_and_other_scope_entries() {
        let a = scope("a.example", 7);
        let b = scope("b.example", 7);
        let legacy = "123456789".to_owned();
        let other = b.peer_key("123456789").unwrap().storage;
        let old = a.peer_key("987654321").unwrap().storage;
        let stored = a.replace_favorites(
            vec![legacy.clone(), other.clone(), old],
            vec!["123456789".into(), "123456789".into(), "../123456".into()],
        );
        assert!(stored.contains(&legacy));
        assert!(stored.contains(&other));
        assert_eq!(a.decode_favorites(&stored), vec!["123456789"]);
        assert_eq!(b.decode_favorites(&stored), vec!["123456789"]);
        let cleared = a.replace_favorites(stored, vec![]);
        assert_eq!(cleared, vec![legacy, other]);
    }

    #[test]
    fn captured_preferences_write_original_scope_and_do_not_import_legacy() {
        let files = TemporaryPeers::new();
        let mut legacy = fixture_peer();
        legacy.options.insert("alias".into(), "legacy-owner".into());
        files.store("123456789", &legacy);
        let original = scope("a.example", 7).peer_key("123456789").unwrap();
        let next = scope("a.example", 8).peer_key("123456789").unwrap();
        assert!(original
            .load_with(|key| files.load(key))
            .options
            .get("alias")
            .is_none());
        let mut config = fixture_peer();
        config.options.insert("alias".into(), "server-a".into());
        original.store_with(&config, |key, config| files.store(key, config));
        assert!(next
            .load_with(|key| files.load(key))
            .options
            .get("alias")
            .is_none());
        config
            .options
            .insert("alias".into(), "late-old-session-write".into());
        original.store_with(&config, |key, config| files.store(key, config));
        assert_eq!(
            original.load_with(|key| files.load(key)).options["alias"],
            "late-old-session-write"
        );
        assert!(next
            .load_with(|key| files.load(key))
            .options
            .get("alias")
            .is_none());
        assert_eq!(files.load("123456789").options["alias"], "legacy-owner");
    }

    #[test]
    fn storage_adapters_clear_saved_credentials_before_serialization_and_after_read() {
        let files = TemporaryPeers::new();
        let key = scope("a.example", 7).peer_key("123456789").unwrap();
        let mut config = fixture_peer();
        config.password = vec![1, 2, 3];
        config
            .options
            .insert("os-password".into(), "synthetic-secret".into());
        config
            .options
            .insert("rdp_password".into(), "synthetic-secret".into());
        config.options.insert("alias".into(), "permitted".into());
        key.store_with(&config, |storage, config| files.store(storage, config));
        let stored = files.load(&key.storage);
        assert!(stored.password.is_empty());
        assert!(!std::fs::read_to_string(files.path(&key.storage))
            .unwrap()
            .contains("synthetic-secret"));
        assert_eq!(stored.options["alias"], "permitted");
        files.store(&key.storage, &config);
        let read = key.load_with(|storage| files.load(storage));
        assert!(read.password.is_empty());
        assert!(!read.options.contains_key("os-password"));
        assert!(!read.options.contains_key("rdp_password"));
    }

    #[test]
    fn enumeration_and_removal_preserve_other_scope_and_legacy_files() {
        let files = TemporaryPeers::new();
        let a = scope("a.example", 7);
        let own = a.peer_key("123456789").unwrap();
        let other = scope("b.example", 7).peer_key("123456789").unwrap();
        for name in ["123456789", &own.storage, &other.storage] {
            files.store(name, &fixture_peer());
        }
        let entries = std::fs::read_dir(&files.0)
            .unwrap()
            .map(|entry| {
                let path = entry.unwrap().path();
                (
                    path.file_stem().unwrap().to_str().unwrap().to_owned(),
                    SystemTime::UNIX_EPOCH,
                    path,
                )
            })
            .collect();
        let entries = a.filter_entries(entries);
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].0, own.storage);
        own.remove_with(|storage| std::fs::remove_file(files.path(storage)).unwrap());
        assert!(!files.path(&own.storage).exists());
        assert!(files.path(&other.storage).exists());
        assert!(files.path("123456789").exists());
    }
}
