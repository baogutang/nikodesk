//! Explicit legacy attribution. Originals and secrets never enter scoped output.
use super::{
    favorites::{self, storage::Directory},
    server_scope::ServerScope,
};
use hbb_common::{anyhow::anyhow, bail, toml, ResultType};
use serde::Serialize;
use sha2::{Digest, Sha256};
use std::{collections::BTreeMap, path::PathBuf};

// Pre-coordination clients only write `peers/`. This generation has its own
// destination; all of its writers use the disk lock and session leases below.
pub(crate) const PEERS: &str = "nikodesk-peers-v2";
const REMOVED: &[u8] = b"nikodesk-peer-removed-v2\n";

fn existing_directory(root: &Directory, name: &str) -> ResultType<Option<Directory>> {
    match root.child(name) {
        Ok(directory) => Ok(Some(directory)),
        Err(error) if error.downcast_ref::<std::io::Error>()
            .map_or(false, |e| e.kind() == std::io::ErrorKind::NotFound) => Ok(None),
        Err(error) => Err(error),
    }
}

fn validate_storage(storage: &str) -> ResultType<()> {
    let (namespace, id) = storage.strip_prefix("nikodesk_v1_")
        .and_then(|s| s.split_once('_')).ok_or_else(|| anyhow!("invalid_peer_storage"))?;
    let scope = ServerScope::from_namespace(namespace)
        .ok_or_else(|| anyhow!("invalid_peer_storage"))?;
    if scope.peer_id(storage).as_deref() != Some(id) {bail!("invalid_peer_storage");}
    Ok(())
}

fn validate_peer_file(bytes: &[u8]) -> ResultType<()> {
    let value: toml::Value = toml::from_str(std::str::from_utf8(bytes)
        .map_err(|_| anyhow!("invalid_peer_config"))?)
        .map_err(|_| anyhow!("invalid_peer_config"))?;
    if !value.is_table() {bail!("invalid_peer_config");}
    Ok(())
}

// Caller owns nikodesk-peer-storage.lock. Only an already attributed scoped
// legacy file may be copied automatically; numeric files require UI selection.
fn read_peer_locked(root: &Directory, storage: &str) -> ResultType<Option<Vec<u8>>> {
    validate_storage(storage)?;
    let filename = format!("{storage}.toml");
    if let Some(peers) = existing_directory(root, PEERS)? {
        if let Some(bytes) = peers.read(&filename, 1024 * 1024)? {return Ok(Some(bytes));}
        if let Some(marker) = peers.read(&format!("{storage}.removed"), 128)? {
            if marker != REMOVED {bail!("invalid_peer_tombstone");}
            return Ok(None);
        }
    }
    let Some(legacy) = existing_directory(root, "peers")? else {return Ok(None);};
    let Some(bytes) = legacy.read_legacy(&filename, 256 * 1024)? else {return Ok(None);};
    let safe = toml::to_string(&sanitize(&bytes)?)?.into_bytes();
    let peers = root.ensure_child(PEERS)?;
    peers.publish_new(&filename, &safe)?;
    peers.read(&filename, 1024 * 1024)
}

#[derive(Serialize)]
pub struct Item {
    pub id: String,
    pub alias: String,
    pub fields: Vec<String>,
    pub target_exists: bool,
    pub status: &'static str,
    #[serde(skip)]
    value: toml::Value,
    #[serde(skip)]
    source_name: Option<String>,
}

#[derive(Serialize)]
pub struct Preview {
    pub ok: bool,
    pub status: &'static str,
    pub namespace: String,
    pub revision: String,
    pub requires_local_restart: bool,
    pub items: Vec<Item>,
}

pub(crate) struct Repository {
    root: PathBuf,
}
impl Repository {
    pub(crate) fn new(root: PathBuf) -> Self {
        Self { root }
    }

    fn read_peer(&self, storage: &str) -> ResultType<Option<Vec<u8>>> {
        let root = Directory::open(&self.root)?;
        let _lock = root.lock("nikodesk-peer-storage.lock")?;
        read_peer_locked(&root, storage)
    }

    fn write_peer(&self, storage: &str, bytes: &[u8]) -> ResultType<()> {
        validate_storage(storage)?;
        validate_peer_file(bytes)?;
        let root = Directory::open(&self.root)?;
        let _lock = root.lock("nikodesk-peer-storage.lock")?;
        let peers = root.ensure_child(PEERS)?;
        let filename = format!("{storage}.toml");
        // A session may have fallen back to defaults after a failed load. It
        // cannot silently overwrite the damaged record with those defaults.
        if let Some(previous) = peers.read(&filename, 1024 * 1024)? {
            validate_peer_file(&previous)?;
        }
        peers.replace(&filename, bytes)
    }

    fn remove_peer(&self, storage: &str) -> ResultType<()> {
        validate_storage(storage)?;
        let root = Directory::open(&self.root)?;
        let _lock = root.lock("nikodesk-peer-storage.lock")?;
        let peers = root.ensure_child(PEERS)?;
        // Keep this marker after future saves as well. Removing the current file
        // must never resurrect a preserved older-client snapshot on next read.
        peers.replace(&format!("{storage}.removed"), REMOVED)?;
        peers.remove(&format!("{storage}.toml"))
    }

    /// Read one scoped list under the same disk lock as all current writers.
    /// Decode defaults only after this method has released the filesystem lock.
    pub(crate) fn scoped_preferences(
        &self,
        namespace: &str,
        ids: Option<&[String]>,
    ) -> ResultType<Vec<(String, std::time::SystemTime, Vec<u8>)>> {
        let scope =
            ServerScope::from_namespace(namespace).ok_or_else(|| anyhow!("invalid_namespace"))?;
        if let Some(ids) = ids {
            if ids.len() > 4096 {
                bail!("too_many_peers");
            }
            for id in ids {
                super::validate_remote_id(id)?;
            }
        }
        let root = Directory::open(&self.root)?;
        let _lock = root.lock("nikodesk-peer-storage.lock")?;
        let mut filenames = std::collections::BTreeSet::new();
        for directory in [existing_directory(&root, PEERS)?, existing_directory(&root, "peers")?]
            .into_iter().flatten() {
            filenames.extend(directory.entries()?);
        }
        let mut output = Vec::new();
        let mut byte_count = 0usize;
        for filename in filenames {
            let Some(storage) = filename.strip_suffix(".toml") else {
                continue;
            };
            let Some(id) = scope.peer_id(storage) else {
                continue;
            };
            if ids.map_or(false, |ids| !ids.contains(&id)) {
                continue;
            }
            let Some(bytes) = read_peer_locked(&root, storage)? else {continue;};
            byte_count = byte_count
                .checked_add(bytes.len())
                .ok_or_else(|| anyhow!("too_many_peers"))?;
            if byte_count > 32 * 1024 * 1024 {
                bail!("too_many_peers");
            }
            if output.len() >= 4096 {bail!("too_many_peers");}
            output.push((id, root.child(PEERS)?.modified(&filename)?, bytes));
        }
        output.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.cmp(&b.0)));
        Ok(output)
    }

    pub(crate) fn preview(&self, namespace: &str) -> ResultType<Preview> {
        let root = Directory::open(&self.root)?;
        let _lock = root.lock("nikodesk-peer-storage.lock")?;
        Self::preview_locked(namespace, &root)
    }

    fn preview_locked(namespace: &str, root: &Directory) -> ResultType<Preview> {
        let scope =
            ServerScope::from_namespace(namespace).ok_or_else(|| anyhow!("invalid_namespace"))?;
        let peers = existing_directory(root, "peers")?;
        let targets = existing_directory(root, PEERS)?;
        let mut items = BTreeMap::new();
        let mut canonical = BTreeMap::new();
        for filename in peers
            .as_ref()
            .map(|peers| peers.entries())
            .transpose()?
            .unwrap_or_default()
        {
            let peers = peers
                .as_ref()
                .ok_or_else(|| anyhow!("legacy_peer_changed"))?;
            let Some(storage) = filename.strip_suffix(".toml") else {
                continue;
            };
            let id = match scope.peer_id(storage) {
                Some(id) => id,
                None if super::validate_remote_id(storage).is_ok() => storage.to_owned(),
                None => continue,
            };
            let bytes = peers
                .read_legacy(&filename, 256 * 1024)?
                .ok_or_else(|| anyhow!("legacy_peer_changed"))?;
            let value = sanitize(&bytes)?;
            let target = format!(
                "{}.toml",
                scope
                    .peer_key(&id)
                    .ok_or_else(|| anyhow!("invalid_peer_id"))?
                    .storage()
            );
            let target_exists = targets.as_ref().map(|d| d.exists(&target)).transpose()?.unwrap_or(false);
            let alias = value
                .get("options")
                .and_then(|v| v.get("alias"))
                .and_then(|v| v.as_str())
                .unwrap_or_default()
                .to_owned();
            let fields = value
                .as_table()
                .ok_or_else(|| anyhow!("invalid_legacy_peer"))?
                .keys()
                .cloned()
                .collect();
            // Scoped entries sort after numeric ones and are already attributed
            // to this server, so they take precedence for the same peer ID.
            canonical.insert(id.clone(), (filename.clone(), toml::to_string(&value)?));
            items.insert(id.clone(), Item {
                id,
                alias,
                fields,
                target_exists,
                status: if target_exists {
                    "target_exists"
                } else {
                    "available"
                },
                value,
                source_name: Some(filename),
            });
        }
        if let Some(bytes) = root.read_legacy("NikoDesk_local.toml", 1024 * 1024)? {
            let local: toml::Value = toml::from_str(std::str::from_utf8(&bytes)
                .map_err(|_| anyhow!("invalid_legacy_favorites_file"))?)
                .map_err(|_| anyhow!("invalid_legacy_favorites_file"))?;
            let favorites = local.get("fav").and_then(toml::Value::as_array)
                .filter(|ids| ids.len() <= 4096)
                .ok_or_else(|| anyhow!("invalid_legacy_favorites_file"))?;
            for favorite in favorites {
                let stored = favorite.as_str().ok_or_else(|| anyhow!("invalid_legacy_favorites_file"))?;
                let id = match scope.peer_id(stored) {
                    Some(id) => id,
                    None if super::validate_remote_id(stored).is_ok() => stored.to_owned(),
                    None => continue,
                };
                if items.contains_key(&id) {continue;}
                let key = scope.peer_key(&id).ok_or_else(|| anyhow!("invalid_peer_id"))?;
                let target_exists = targets.as_ref().map(|d| d.exists(&format!("{}.toml", key.storage())))
                    .transpose()?.unwrap_or(false);
                let value = toml::Value::Table(toml::map::Map::new());
                canonical.insert(id.clone(), ("favorites".into(), toml::to_string(&value)?));
                items.insert(id.clone(), Item {
                    id, alias: String::new(), fields: Vec::new(), target_exists,
                    status: if target_exists {"target_exists"} else {"available"},
                    value, source_name: None,
                });
            }
        }
        let mut digest = Sha256::new();
        digest.update(b"nikodesk-peer-import-revision-v1\0");
        digest.update(namespace.as_bytes());
        for (id, (filename, value)) in canonical {
            digest.update([0]);
            digest.update(id.as_bytes());
            digest.update([0]);
            digest.update(filename.as_bytes());
            digest.update([0]);
            digest.update(value.as_bytes());
        }
        Ok(Preview {
            ok: true,
            status: "preview",
            namespace: namespace.to_owned(),
            revision: format!("{:x}", digest.finalize()),
            requires_local_restart: false,
            items: items.into_values().collect(),
        })
    }

    // Only current-generation writers participate in this destination. Older
    // clients can change sources, which remain revision-checked and read-only.
    pub(crate) fn import(
        &self,
        namespace: &str,
        revision: &str,
        ids: &[String],
        writers_coordinated: bool,
        active: impl Fn(&str) -> bool,
    ) -> ResultType<serde_json::Value> {
        if ServerScope::from_namespace(revision).is_none() {
            bail!("invalid_revision");
        }
        if ids.len() > 2048 {
            bail!("too_many_peers");
        }
        for id in ids {
            super::validate_remote_id(id)?;
        }
        let preview = self.preview(namespace)?;
        if preview.revision != revision {
            return Ok(
                serde_json::json!({"ok":false,"status":"revision_changed","namespace":namespace,"revision":preview.revision}),
            );
        }
        if !writers_coordinated {
            bail!("peer_writers_not_coordinated");
        }
        let scope =
            ServerScope::from_namespace(namespace).ok_or_else(|| anyhow!("invalid_namespace"))?;
        let root = Directory::open(&self.root)?;
        let _lock = root.lock("nikodesk-peer-storage.lock")?;
        // Re-read the whole preview under the current writer lock. Published
        // values must match the confirmed snapshot; originals stay independent.
        let preview = Self::preview_locked(namespace, &root)?;
        if preview.revision != revision {
            return Ok(
                serde_json::json!({"ok":false,"status":"revision_changed","namespace":namespace,"revision":preview.revision}),
            );
        }
        let sources = existing_directory(&root, "peers")?;
        let peers = root.ensure_child(PEERS)?;
        let mut imported = Vec::new();
        let mut skipped = BTreeMap::new();
        let mut prepared = Vec::new();
        // Re-read sanitized source under the writer lock, not the preview's old bytes.
        for id in ids.iter().collect::<std::collections::BTreeSet<_>>() {
            let item = preview
                .items
                .iter()
                .find(|item| &item.id == id)
                .ok_or_else(|| anyhow!("peer_not_in_preview"))?;
            if active(id) {
                skipped.insert(id.clone(), "active_peer");
                continue;
            }
            let storage = scope
                .peer_key(id)
                .ok_or_else(|| anyhow!("invalid_peer_id"))?;
            let Some(_lease) = root.try_exclusive_lease(&lease_name(storage.storage()))? else {
                skipped.insert(id.clone(), "active_peer");
                continue;
            };
            let value = match &item.source_name {
                Some(filename) => {
                    let bytes = sources.as_ref().ok_or_else(|| anyhow!("legacy_peer_changed"))?
                        .read_legacy(filename, 256 * 1024)?
                        .ok_or_else(|| anyhow!("legacy_peer_changed"))?;
                    sanitize(&bytes)?
                }
                None => item.value.clone(),
            };
            if value != item.value {
                bail!("legacy_peer_changed");
            }
            let target = format!("{}.toml", storage.storage());
            prepared.push((id.clone(), target, toml::to_string(&value)?, _lease));
        }
        for (id, target, value, _lease) in prepared {
            match peers.publish_new(&target, value.as_bytes()) {
                Ok(true) => imported.push(id.clone()),
                Ok(false) => {
                    skipped.insert(id.clone(), "target_exists");
                }
                Err(_) => {
                    return Ok(
                        serde_json::json!({"ok":false,"status":"partial_or_unconfirmed","namespace":namespace,"revision":revision,"imported":imported,"skipped":skipped,"failed":id}),
                    )
                }
            }
        }
        Ok(
            serde_json::json!({"ok":true,"status":"imported","namespace":namespace,"revision":revision,"imported":imported,"skipped":skipped}),
        )
    }
}

fn lease_name(storage: &str) -> String {
    format!(
        "nikodesk-peer-{:x}.lease",
        Sha256::digest(storage.as_bytes())
    )
}
pub(crate) struct PeerLease {
    _lock: super::favorites::storage::Lock,
}
pub(crate) fn acquire_lease(storage: &str) -> ResultType<std::sync::Arc<PeerLease>> {
    let root = Directory::open(&favorites::application_root()?)?;
    Ok(std::sync::Arc::new(PeerLease {
        _lock: root.lease(&lease_name(storage))?,
    }))
}
pub(crate) fn read_peer(storage: &str) -> ResultType<Option<Vec<u8>>> {
    Repository::new(favorites::application_root()?).read_peer(storage)
}
pub(crate) fn write_peer(storage: &str, bytes: &[u8]) -> ResultType<()> {
    Repository::new(favorites::application_root()?).write_peer(storage, bytes)
}
pub(crate) fn remove_peer(storage: &str) -> ResultType<()> {
    Repository::new(favorites::application_root()?).remove_peer(storage)
}

fn sanitize(bytes: &[u8]) -> ResultType<toml::Value> {
    let input: toml::Value =
        toml::from_str(std::str::from_utf8(bytes).map_err(|_| anyhow!("invalid_legacy_peer"))?)
            .map_err(|_| anyhow!("invalid_legacy_peer"))?;
    let table = input
        .as_table()
        .ok_or_else(|| anyhow!("invalid_legacy_peer"))?;
    let mut output = toml::map::Map::new();
    for (name, allowed) in [
        ("view_style", &["original", "adaptive", "stretch"][..]),
        (
            "scroll_style",
            &["scrollauto", "scrollbar", "scrolledge"][..],
        ),
        ("image_quality", &["best", "balanced", "low", "custom"][..]),
        ("keyboard_mode", &["legacy", "map", "translate", "auto"][..]),
        ("reverse_mouse_wheel", &["", "Y", "N"][..]),
        ("displays_as_individual_windows", &["", "Y", "N"][..]),
        ("use_all_my_displays_for_the_remote_session", &["", "Y", "N"][..]),
    ] {
        if let Some(value) = table.get(name) {
            let value = value
                .as_str()
                .filter(|value| allowed.contains(value))
                .ok_or_else(|| anyhow!("invalid_legacy_preference"))?;
            output.insert(name.into(), toml::Value::String(value.to_owned()));
        }
    }
    for name in [
        "show_remote_cursor",
        "show_quality_monitor",
        "follow_remote_cursor",
        "follow_remote_window",
        "view_only",
        "show_my_cursor",
        "disable_audio",
        "disable_clipboard",
        "allow_swap_key",
    ] {
        if let Some(value) = table.get(name) {
            let value = value
                .as_bool()
                .ok_or_else(|| anyhow!("invalid_legacy_preference"))?;
            output.insert(name.into(), toml::Value::Boolean(value));
        }
    }
    for name in ["size", "size_ft", "size_pf"] {
        if let Some(value) = table.get(name) {
            let values = value
                .as_array()
                .filter(|v| v.len() == 4)
                .ok_or_else(|| anyhow!("invalid_legacy_preference"))?;
            if !values.iter().all(|v| {
                v.as_integer()
                    .map_or(false, |v| (-100_000..=100_000).contains(&v))
            }) {
                bail!("invalid_legacy_preference");
            }
            output.insert(name.into(), value.clone());
        }
    }
    for (name, min, max) in [
        ("edge_scroll_edge_thickness", 0, 1000),
        ("trackpad-speed", 1, 200),
    ] {
        if let Some(value) = table.get(name) {
            let v = value
                .as_integer()
                .ok_or_else(|| anyhow!("invalid_legacy_preference"))?;
            if !(min..=max).contains(&v) {
                bail!("invalid_legacy_preference");
            }
            output.insert(name.into(), value.clone());
        }
    }
    if let Some(value) = table.get("custom_image_quality") {
        let values = value
            .as_array()
            .filter(|v| v.len() <= 2)
            .ok_or_else(|| anyhow!("invalid_legacy_preference"))?;
        if !values
            .iter()
            .all(|v| v.as_integer().map_or(false, |v| (1..=100).contains(&v)))
        {
            bail!("invalid_legacy_preference");
        }
        output.insert("custom_image_quality".into(), value.clone());
    }
    if let Some(resolutions) = table.get("custom_resolutions") {
        let resolutions = resolutions.as_table().filter(|v| v.len() <= 64)
            .ok_or_else(|| anyhow!("invalid_legacy_preference"))?;
        for (display, resolution) in resolutions {
            if display.is_empty() || display.len() > 128 || display.chars().any(char::is_control) {
                bail!("invalid_legacy_preference");
            }
            let resolution = resolution.as_table().filter(|v| v.len() == 2)
                .ok_or_else(|| anyhow!("invalid_legacy_preference"))?;
            for dimension in ["w", "h"] {
                if !resolution.get(dimension).and_then(toml::Value::as_integer)
                    .map_or(false, |v| (0..=16384).contains(&v)) {
                    bail!("invalid_legacy_preference");
                }
            }
        }
        output.insert("custom_resolutions".into(), toml::Value::Table(resolutions.clone()));
    }
    if let Some(options) = table.get("options") {
        let options = options
            .as_table()
            .ok_or_else(|| anyhow!("invalid_legacy_preference"))?;
        let mut copied = toml::map::Map::new();
        if let Some(alias) = options.get("alias") {
            let alias = alias
                .as_str()
                .filter(|v| v.len() <= 256 && !v.chars().any(char::is_control))
                .ok_or_else(|| anyhow!("invalid_legacy_preference"))?;
            copied.insert("alias".into(), toml::Value::String(alias.to_owned()));
        }
        for (name, allowed) in [
            ("codec-preference", &["", "auto", "vp8", "vp9", "av1", "h264", "h265"][..]),
            ("nikodesk-picture-mode", &["office", "smooth", "constrained", "custom"][..]),
            ("zoom-cursor", &["", "Y", "N"][..]),
        ] {
            if let Some(value) = options.get(name) {
                let value = value.as_str().filter(|value| allowed.contains(value))
                    .ok_or_else(|| anyhow!("invalid_legacy_preference"))?;
                copied.insert(name.into(), toml::Value::String(value.to_owned()));
            }
        }
        if let Some(value) = options.get("custom-fps") {
            let value = value.as_str().ok_or_else(|| anyhow!("invalid_legacy_preference"))?;
            if !value.is_empty() && !value.parse::<u32>().ok().map_or(false, |fps| fps <= 240) {
                bail!("invalid_legacy_preference");
            }
            copied.insert("custom-fps".into(), toml::Value::String(value.to_owned()));
        }
        if !copied.is_empty() {
            output.insert("options".into(), toml::Value::Table(copied));
        }
    }
    // No PeerConfig deserializer: missing fields must not initialize user defaults.
    Ok(toml::Value::Table(output))
}

pub fn preview(namespace: &str) -> String {
    favorites::json(
        favorites::context(namespace)
            .and_then(|_| Repository::new(favorites::application_root()?).preview(namespace)),
    )
}
pub fn import(namespace: &str, revision: &str, ids: &[String]) -> String {
    favorites::json(favorites::context(namespace).and_then(|_| {
        // Older clients do not know the v2 destination. Every current peer writer
        // and session uses this repository's disk lock and kernel-backed leases.
        Repository::new(favorites::application_root()?).import(
            namespace,
            revision,
            ids,
            true,
            |_| false,
        )
    }))
}

#[cfg(all(test, unix))]
mod tests {
    use super::super::favorites::tests::{ns, Temp};
    use super::*;
    use std::fs;
    const SOURCE: &[u8] = b"password = [1,2,3]\nview_style = 'original'\nimage_quality = 'balanced'\nshow_remote_cursor = true\nterminal_persistent = true\nport_forwards = [[1,'private-host',2]]\n[options]\nalias = 'public-fixture-alias'\nos-password = 'synthetic-secret'\nrdp_password = 'synthetic-secret'\nkey = 'synthetic-secret'\nterminal-service-id = 'old-owner'\n";
    fn setup() -> (Temp, Repository) {
        let temp = Temp::new();
        let dir = Directory::open(&temp.0)
            .unwrap()
            .ensure_child("peers")
            .unwrap();
        dir.replace("123456789.toml", SOURCE).unwrap();
        let repo = Repository::new(temp.0.clone());
        (temp, repo)
    }
    #[test]
    fn scoped_list_missing_directory_is_confirmed_empty_without_creating_peers() {
        let temp = Temp::new();
        let repository = Repository::new(temp.0.clone());
        assert!(repository
            .scoped_preferences(&ns('a'), None)
            .unwrap()
            .is_empty());
        assert!(!temp.0.join("peers").exists());
    }
    #[test]
    fn scoped_list_filters_before_reading_foreign_or_unselected_files() {
        use std::os::unix::fs::symlink;
        let temp = Temp::new();
        let peers = Directory::open(&temp.0)
            .unwrap()
            .ensure_child(PEERS)
            .unwrap();
        let a = ServerScope::from_namespace(&ns('a')).unwrap();
        let b = ServerScope::from_namespace(&ns('b')).unwrap();
        let selected = a.peer_key("123456789").unwrap();
        peers
            .replace(
                &format!("{}.toml", selected.storage()),
                b"view_style='original'\n",
            )
            .unwrap();
        let unselected = a.peer_key("987654321").unwrap();
        let foreign = b.peer_key("123456789").unwrap();
        for key in [unselected, foreign] {
            symlink(
                temp.0.join("missing"),
                temp.0.join(PEERS).join(format!("{}.toml", key.storage())),
            )
            .unwrap();
        }
        let repository = Repository::new(temp.0.clone());
        let selected_ids = vec!["123456789".to_owned()];
        let items = repository
            .scoped_preferences(&ns('a'), Some(&selected_ids))
            .unwrap();
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].0, "123456789");
        assert_eq!(items[0].2, b"view_style='original'\n");
        // The same selected broken file is a read failure, not empty data.
        assert!(repository.scoped_preferences(&ns('a'), None).is_err());
    }
    #[test]
    fn scoped_list_linked_directory_and_oversized_file_are_errors() {
        use std::os::unix::fs::symlink;
        let temp = Temp::new();
        let foreign = Temp::new();
        symlink(&foreign.0, temp.0.join(PEERS)).unwrap();
        let repository = Repository::new(temp.0.clone());
        assert!(repository.scoped_preferences(&ns('a'), None).is_err());
        fs::remove_file(temp.0.join(PEERS)).unwrap();
        let peers = Directory::open(&temp.0)
            .unwrap()
            .ensure_child(PEERS)
            .unwrap();
        let key = ServerScope::from_namespace(&ns('a'))
            .unwrap()
            .peer_key("123456789")
            .unwrap();
        let name = format!("{}.toml", key.storage());
        peers.replace(&name, b"complete").unwrap();
        let file = fs::OpenOptions::new()
            .write(true)
            .open(temp.0.join(PEERS).join(&name))
            .unwrap();
        file.set_len(1024 * 1024 + 1).unwrap();
        assert!(repository.scoped_preferences(&ns('a'), None).is_err());
        assert_eq!(
            fs::metadata(temp.0.join(PEERS).join(name)).unwrap().len(),
            1024 * 1024 + 1
        );
    }
    #[test]
    fn preview_sanitizes_fields_and_never_serializes_secrets() {
        let (_temp, repo) = setup();
        let preview = repo.preview(&ns('a')).unwrap();
        let value = serde_json::to_string(&preview).unwrap();
        assert_eq!(preview.items.len(), 1);
        assert_eq!(preview.items[0].alias, "public-fixture-alias");
        assert!(!value.contains("synthetic-secret"));
        assert!(!value.contains("old-owner"));
        assert!(!value.contains("password"));
        assert!(preview.items[0].value.get("terminal_persistent").is_none());
        assert!(preview.items[0].value.get("port_forwards").is_none());
    }
    #[test]
    fn atomic_import_preserves_original_and_does_not_overwrite_target() {
        let (temp, repo) = setup();
        let a = ns('a');
        let p = repo.preview(&a).unwrap();
        let result = repo
            .import(&a, &p.revision, &["123456789".into()], true, |_| false)
            .unwrap();
        assert_eq!(result["imported"][0], "123456789");
        let target = temp.0.join(PEERS).join(format!("nikodesk_v1_{a}_123456789.toml"));
        let first = fs::read(&target).unwrap();
        assert!(!String::from_utf8(first.clone())
            .unwrap()
            .contains("synthetic-secret"));
        let result = repo
            .import(&a, &p.revision, &["123456789".into()], true, |_| false)
            .unwrap();
        assert_eq!(result["skipped"]["123456789"], "target_exists");
        assert_eq!(fs::read(target).unwrap(), first);
        assert_eq!(
            fs::read(temp.0.join("peers/123456789.toml")).unwrap(),
            SOURCE
        );
    }
    #[test]
    fn source_or_namespace_change_invalidates_confirmation() {
        let (temp, repo) = setup();
        let a = ns('a');
        let p = repo.preview(&a).unwrap();
        let result = repo
            .import(&ns('b'), &p.revision, &["123456789".into()], true, |_| {
                false
            })
            .unwrap();
        assert_eq!(result["status"], "revision_changed");
        let dir = Directory::open(&temp.0).unwrap().child("peers").unwrap();
        dir.replace("123456789.toml", b"view_style = 'adaptive'\n")
            .unwrap();
        let result = repo
            .import(&a, &p.revision, &["123456789".into()], true, |_| false)
            .unwrap();
        assert_eq!(result["status"], "revision_changed");
        assert_eq!(fs::read_dir(temp.0.join("peers")).unwrap().count(), 1);
    }
    #[test]
    fn uncoordinated_writer_gate_does_not_publish_any_target() {
        let (temp, repo) = setup();
        let p = repo.preview(&ns('a')).unwrap();
        let error = repo
            .import(&ns('a'), &p.revision, &["123456789".into()], false, |_| {
                false
            })
            .unwrap_err();
        assert_eq!(error.to_string(), "peer_writers_not_coordinated");
        assert_eq!(fs::read_dir(temp.0.join("peers")).unwrap().count(), 1);
    }
    #[test]
    fn active_peer_callback_and_shared_lease_both_skip_import() {
        let (temp, repo) = setup();
        let a = ns('a');
        let p = repo.preview(&a).unwrap();
        let result = repo
            .import(&a, &p.revision, &["123456789".into()], true, |_| true)
            .unwrap();
        assert_eq!(result["skipped"]["123456789"], "active_peer");
        let dir = Directory::open(&temp.0).unwrap();
        let storage = format!("nikodesk_v1_{a}_123456789");
        let lease = dir.lease(&lease_name(&storage)).unwrap();
        let result = repo
            .import(&a, &p.revision, &["123456789".into()], true, |_| false)
            .unwrap();
        assert_eq!(result["skipped"]["123456789"], "active_peer");
        drop(lease);
        let result = repo
            .import(&a, &p.revision, &["123456789".into()], true, |_| false)
            .unwrap();
        assert_eq!(result["imported"][0], "123456789");
    }
    #[test]
    fn published_file_is_complete_or_existing_and_has_no_temporary_alias() {
        let temp = Temp::new();
        let dir = Directory::open(&temp.0).unwrap();
        assert!(dir.publish_new("target", b"whole-file").unwrap());
        assert!(!dir.publish_new("target", b"replacement").unwrap());
        assert_eq!(dir.read("target", 100).unwrap().unwrap(), b"whole-file");
        assert_eq!(dir.entries().unwrap(), vec!["target"]);
    }
    #[test]
    fn captured_lease_stays_active_until_the_last_session_clone_drops() {
        let temp = Temp::new();
        let root = Directory::open(&temp.0).unwrap();
        let name = lease_name(&format!("nikodesk_v1_{}_123456789", ns('a')));
        let lease = std::sync::Arc::new(PeerLease {
            _lock: root.lease(&name).unwrap(),
        });
        let session_clone = lease.clone();
        drop(lease);
        assert!(root.try_exclusive_lease(&name).unwrap().is_none());
        drop(session_clone);
        assert!(root.try_exclusive_lease(&name).unwrap().is_some());
    }
    #[test]
    fn invalid_preference_and_large_file_preserve_sources() {
        let (temp, repo) = setup();
        let dir = Directory::open(&temp.0).unwrap().child("peers").unwrap();
        dir.replace("123456789.toml", b"view_style = ['wrong-type']")
            .unwrap();
        assert!(repo.preview(&ns('a')).is_err());
        dir.replace("123456789.toml", &vec![b'x'; 256 * 1024 + 1])
            .unwrap();
        assert!(repo.preview(&ns('a')).is_err());
        assert_eq!(
            dir.read("123456789.toml", 1024 * 1024)
                .unwrap()
                .unwrap()
                .len(),
            256 * 1024 + 1
        );
    }

    #[test]
    fn scoped_compatibility_copy_is_private_authoritative_and_deleted_peers_stay_deleted() {
        let (temp, repo) = setup();
        let legacy = Directory::open(&temp.0).unwrap().child("peers").unwrap();
        let a = ns('a');
        let storage = format!("nikodesk_v1_{a}_123456789");
        let filename = format!("{storage}.toml");
        let mut complete_source = b"reverse_mouse_wheel='Y'\nallow_swap_key=true\nsize_ft=[0,0,640,480]\n".to_vec();
        complete_source.extend_from_slice(SOURCE);
        complete_source.extend_from_slice(b"custom-fps='48'\ncodec-preference='auto'\nnikodesk-picture-mode='office'\n");
        complete_source.extend_from_slice(b"[custom_resolutions.'0']\nw=1920\nh=1080\n");
        legacy.replace(&filename, &complete_source).unwrap();
        let copied = repo.read_peer(&storage).unwrap().unwrap();
        let value: toml::Value = toml::from_str(std::str::from_utf8(&copied).unwrap()).unwrap();
        assert_eq!(value["view_style"].as_str(), Some("original"));
        assert_eq!(value["options"]["custom-fps"].as_str(), Some("48"));
        assert_eq!(value["options"]["nikodesk-picture-mode"].as_str(), Some("office"));
        assert_eq!(value["reverse_mouse_wheel"].as_str(), Some("Y"));
        assert_eq!(value["allow_swap_key"].as_bool(), Some(true));
        assert_eq!(value["size_ft"][2].as_integer(), Some(640));
        assert_eq!(value["custom_resolutions"]["0"]["w"].as_integer(), Some(1920));
        assert!(value.get("password").is_none());
        assert!(value.get("port_forwards").is_none());
        assert!(!std::str::from_utf8(&copied).unwrap().contains("synthetic-secret"));
        assert_eq!(legacy.read(&filename, 256 * 1024).unwrap().unwrap(), complete_source);
        assert_eq!(legacy.read("123456789.toml", 256 * 1024).unwrap().unwrap(), SOURCE);
        legacy.replace(&filename, b"view_style='stretch'\n").unwrap();
        assert_eq!(repo.read_peer(&storage).unwrap().unwrap(), copied);
        repo.write_peer(&storage, b"view_style='adaptive'\n").unwrap();
        assert_eq!(repo.read_peer(&storage).unwrap().unwrap(), b"view_style='adaptive'\n");
        assert_eq!(legacy.read(&filename, 256 * 1024).unwrap().unwrap(), b"view_style='stretch'\n");
        repo.remove_peer(&storage).unwrap();
        assert!(repo.read_peer(&storage).unwrap().is_none());
        assert!(repo.scoped_preferences(&a, None).unwrap().is_empty());
        assert!(legacy.exists(&filename).unwrap());
        // Explicitly selected import may restore a removed preference; a read cannot.
        let preview = repo.preview(&a).unwrap();
        assert!(!preview.requires_local_restart);
        assert_eq!(preview.items.len(), 1);
        repo.import(&a, &preview.revision, &["123456789".into()], true, |_| false).unwrap();
        assert!(repo.read_peer(&storage).unwrap().is_some());
        // An existing v2 record wins over later source edits and manual imports.
        legacy.replace(&filename, SOURCE).unwrap();
        let preview = repo.preview(&a).unwrap();
        let result = repo.import(&a, &preview.revision, &["123456789".into()], true, |_| false).unwrap();
        assert_eq!(result["skipped"]["123456789"], "target_exists");
        assert_eq!(toml::from_str::<toml::Value>(std::str::from_utf8(&repo.read_peer(&storage).unwrap().unwrap()).unwrap()).unwrap()["view_style"].as_str(), Some("stretch"));
        assert!(repo.read_peer("123456789").is_err());
        assert!(repo.read_peer(&format!("nikodesk_v1_{a}_../123456789")).is_err());
    }

    #[test]
    fn favorite_only_entries_can_be_attributed_without_modifying_legacy_files() {
        let temp = Temp::new();
        let root = Directory::open(&temp.0).unwrap();
        let a = ns('a');
        let b = ns('b');
        let source = format!("fav=['123456789','nikodesk_v1_{a}_987654321','nikodesk_v1_{b}_111111111']\n[options]\npassword='synthetic-secret'\n");
        root.replace("NikoDesk_local.toml", source.as_bytes()).unwrap();
        let repo = Repository::new(temp.0.clone());
        let preview = repo.preview(&a).unwrap();
        assert_eq!(preview.items.iter().map(|i| i.id.as_str()).collect::<Vec<_>>(), vec!["123456789", "987654321"]);
        assert!(preview.items.iter().all(|item| item.fields.is_empty()));
        let result = repo.import(&a, &preview.revision, &["123456789".into()], true, |_| false).unwrap();
        assert_eq!(result["imported"][0], "123456789");
        let storage = format!("nikodesk_v1_{a}_123456789");
        let imported = repo.read_peer(&storage).unwrap().unwrap();
        assert!(toml::from_str::<toml::Value>(std::str::from_utf8(&imported).unwrap()).unwrap().as_table().unwrap().is_empty());
        assert!(!std::str::from_utf8(&imported).unwrap().contains("synthetic-secret"));
        assert_eq!(root.read("NikoDesk_local.toml", 1024 * 1024).unwrap().unwrap(), source.as_bytes());
        assert!(!temp.0.join("peers").exists());
        root.replace("NikoDesk_local.toml", b"fav=[]\n").unwrap();
        let result = repo.import(&a, &preview.revision, &["987654321".into()], true, |_| false).unwrap();
        assert_eq!(result["status"], "revision_changed");
        assert!(repo.read_peer(&format!("nikodesk_v1_{a}_987654321")).unwrap().is_none());
    }

    #[test]
    fn failed_load_cannot_overwrite_a_damaged_current_preference() {
        let temp = Temp::new();
        let root = Directory::open(&temp.0).unwrap();
        let repo = Repository::new(temp.0.clone());
        let storage = format!("nikodesk_v1_{}_123456789", ns('a'));
        assert!(repo.write_peer(&storage, b"view_style=[").is_err());
        assert!(!temp.0.join(PEERS).exists());
        let peers = root.ensure_child(PEERS).unwrap();
        let filename = format!("{storage}.toml");
        for damaged in [b"view_style=[".as_slice(), b"\xff".as_slice()] {
            peers.replace(&filename, damaged).unwrap();
            assert!(repo.write_peer(&storage, b"view_style='original'\n").is_err());
            assert_eq!(peers.read(&filename, 1024).unwrap().unwrap(), damaged);
        }
        peers.replace(&filename, b"view_style=[").unwrap();
        repo.remove_peer(&storage).unwrap();
        repo.write_peer(&storage, b"view_style='original'\n").unwrap();
        assert_eq!(repo.read_peer(&storage).unwrap().unwrap(), b"view_style='original'\n");
    }

    #[test]
    fn migration_child() {
        let Some(root) = std::env::var_os("NIKODESK_PEER_TEST_ROOT") else {
            return;
        };
        let dir = Directory::open(&PathBuf::from(root)).unwrap();
        match std::env::var("NIKODESK_PEER_TEST_MODE").unwrap().as_str() {
            "lease" => {
                let storage = format!("nikodesk_v1_{}_123456789", ns('a'));
                let _lease = dir.lease(&lease_name(&storage)).unwrap();
                dir.replace("lease-ready", b"ready").unwrap();
                let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
                while !dir.exists("lease-release").unwrap() {
                    assert!(std::time::Instant::now() < deadline);
                    std::thread::sleep(std::time::Duration::from_millis(5));
                }
            }
            "publish" => {
                let content = std::env::var("NIKODESK_PEER_TEST_CONTENT").unwrap();
                dir.publish_new("target", content.as_bytes()).unwrap();
            }
            _ => panic!("unknown test mode"),
        }
    }
    fn child(temp: &Temp, mode: &str, content: &str) -> std::process::Child {
        std::process::Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "nikodesk::peer_migration::tests::migration_child",
                "--nocapture",
            ])
            .env("NIKODESK_PEER_TEST_ROOT", &temp.0)
            .env("NIKODESK_PEER_TEST_MODE", mode)
            .env("NIKODESK_PEER_TEST_CONTENT", content)
            .spawn()
            .unwrap()
    }
    #[test]
    fn independent_process_lease_blocks_until_the_owner_exits() {
        let (temp, repo) = setup();
        let a = ns('a');
        let preview = repo.preview(&a).unwrap();
        let dir = Directory::open(&temp.0).unwrap();
        let mut child = child(&temp, "lease", "");
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        while !dir.exists("lease-ready").unwrap() {
            assert!(std::time::Instant::now() < deadline);
            std::thread::sleep(std::time::Duration::from_millis(5));
        }
        let result = repo
            .import(&a, &preview.revision, &["123456789".into()], true, |_| {
                false
            })
            .unwrap();
        assert_eq!(result["skipped"]["123456789"], "active_peer");
        dir.replace("lease-release", b"release").unwrap();
        assert!(child.wait().unwrap().success());
        let result = repo
            .import(&a, &preview.revision, &["123456789".into()], true, |_| {
                false
            })
            .unwrap();
        assert_eq!(result["imported"][0], "123456789");
    }
    #[test]
    fn independent_publish_race_never_overwrites_a_complete_winner() {
        let temp = Temp::new();
        let mut first = child(&temp, "publish", "first-whole-content");
        let mut second = child(&temp, "publish", "second-whole-content");
        assert!(first.wait().unwrap().success());
        assert!(second.wait().unwrap().success());
        let dir = Directory::open(&temp.0).unwrap();
        let value = String::from_utf8(dir.read("target", 100).unwrap().unwrap()).unwrap();
        assert!(matches!(
            value.as_str(),
            "first-whole-content" | "second-whole-content"
        ));
        assert_eq!(dir.entries().unwrap(), vec!["target"]);
    }

    #[test]
    fn empty_preview_does_not_create_the_peer_directory() {
        let temp = Temp::new();
        let repo = Repository::new(temp.0.clone());
        assert!(repo.preview(&ns('a')).unwrap().items.is_empty());
        assert!(!temp.0.join("peers").exists());
    }
}
