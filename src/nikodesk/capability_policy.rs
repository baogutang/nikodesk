//! Local permission to receive requests, never a persisted session grant.
use super::{capability_state::Kind, favorites::storage::Directory, server_scope::ServerScope};
use hbb_common::{anyhow::anyhow, bail, ResultType};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{collections::BTreeMap, path::PathBuf};

const FILE: &str = "nikodesk-capability-policy-v1.json";
const LOCK: &str = "nikodesk-capability-policy.lock";
const MAX_SCOPES: usize = 256;

#[derive(Clone, Copy, Debug, Default, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub(crate) struct Policy {
    terminal: bool,
    tunnel: bool,
    camera: bool,
    voice: bool,
}

impl Policy {
    pub(crate) fn allows_requests(&self, kind: Kind) -> bool {
        match kind {
            Kind::Terminal => self.terminal,
            Kind::Tunnel => self.tunnel,
            Kind::Camera => self.camera,
            Kind::Voice => self.voice,
        }
    }

    fn patch(&mut self, kind: Kind, enabled: bool) {
        match kind {
            Kind::Terminal => self.terminal = enabled,
            Kind::Tunnel => self.tunnel = enabled,
            Kind::Camera => self.camera = enabled,
            Kind::Voice => self.voice = enabled,
        }
    }
}

#[derive(Default, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Entry {
    generation: u64,
    policy: Policy,
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Document {
    version: u32,
    scopes: BTreeMap<String, Entry>,
}

#[derive(Debug, Serialize)]
pub(crate) struct Snapshot {
    pub(crate) ok: bool,
    pub(crate) status: &'static str,
    pub(crate) namespace: String,
    pub(crate) revision: String,
    pub(crate) generation: u64,
    pub(crate) allow_requests: Policy,
}

pub(crate) struct Repository {
    root: PathBuf,
}

impl Repository {
    pub(crate) fn new(root: PathBuf) -> Self {
        Self { root }
    }

    fn load(directory: &Directory) -> ResultType<Document> {
        let document = match directory.read(FILE, 128 * 1024)? {
            Some(bytes) => serde_json::from_slice::<Document>(&bytes)
                .map_err(|_| anyhow!("invalid_capability_policy"))?,
            None => Document {
                version: 1,
                scopes: BTreeMap::new(),
            },
        };
        if document.version != 1
            || document.scopes.len() > MAX_SCOPES
            || document.scopes.iter().any(|(namespace, entry)| {
                ServerScope::from_namespace(namespace).is_none() || entry.generation == 0
            })
        {
            bail!("invalid_capability_policy");
        }
        Ok(document)
    }

    pub(crate) fn get(&self, namespace: &str) -> ResultType<Snapshot> {
        validate(namespace)?;
        let directory = Directory::open(&self.root)?;
        let _lock = directory.lock(LOCK)?;
        let document = Self::load(&directory)?;
        Ok(snapshot(
            namespace,
            document.scopes.get(namespace),
            true,
            "ready",
        ))
    }

    /// A local settings adapter supplies this operation. No remote options,
    /// login cache, password or unattended policy may call it automatically.
    pub(crate) fn set_allow_requests(
        &self,
        namespace: &str,
        expected_revision: &str,
        kind: Kind,
        enabled: bool,
    ) -> ResultType<Snapshot> {
        validate(namespace)?;
        if ServerScope::from_namespace(expected_revision).is_none() {
            bail!("invalid_revision");
        }
        let directory = Directory::open(&self.root)?;
        let _lock = directory.lock(LOCK)?;
        let mut document = Self::load(&directory)?;
        let current = snapshot(namespace, document.scopes.get(namespace), true, "ready");
        if current.revision != expected_revision {
            return Ok(snapshot(
                namespace,
                document.scopes.get(namespace),
                false,
                "conflict",
            ));
        }
        // Exhaustion permanently prevents widening policy. A user must still
        // be able to turn an existing permission off; its changed bits give
        // the resulting revision a different digest even at the last counter.
        if current.generation == u64::MAX && enabled {
            bail!("capability_policy_generation_exhausted");
        }
        if current.allow_requests.allows_requests(kind) == enabled {
            return Ok(snapshot(
                namespace,
                document.scopes.get(namespace),
                true,
                "unchanged",
            ));
        }
        if !document.scopes.contains_key(namespace) && document.scopes.len() >= MAX_SCOPES {
            bail!("capability_policy_limit");
        }
        let entry = document.scopes.entry(namespace.to_owned()).or_default();
        entry.generation = entry.generation.checked_add(1).unwrap_or(u64::MAX);
        entry.policy.patch(kind, enabled);
        let result = snapshot(namespace, Some(entry), true, "saved");
        directory.replace(FILE, &serde_json::to_vec(&document)?)?;
        // Success refers only to durable local policy; running resources must
        // independently revoke/stop and publish their own acknowledgement.
        Ok(result)
    }
}

fn validate(namespace: &str) -> ResultType<()> {
    if ServerScope::from_namespace(namespace).is_none() {
        bail!("invalid_namespace");
    }
    Ok(())
}

fn snapshot(namespace: &str, entry: Option<&Entry>, ok: bool, status: &'static str) -> Snapshot {
    let generation = entry.map_or(0, |entry| entry.generation);
    let policy = entry.map_or(Policy::default(), |entry| entry.policy);
    let mut digest = Sha256::new();
    digest.update(b"nikodesk-capability-policy-revision-v1\0");
    digest.update(namespace.as_bytes());
    digest.update(generation.to_le_bytes());
    for kind in [Kind::Terminal, Kind::Tunnel, Kind::Camera, Kind::Voice] {
        digest.update([u8::from(policy.allows_requests(kind))]);
    }
    Snapshot {
        ok,
        status,
        namespace: namespace.to_owned(),
        revision: format!("{:x}", digest.finalize()),
        generation,
        allow_requests: policy,
    }
}

#[cfg(test)]
mod tests {
    use super::super::favorites::tests::Temp;
    use super::*;

    fn ns() -> String {
        "a".repeat(64)
    }
    fn repo(temp: &Temp) -> Repository {
        Repository::new(temp.0.clone())
    }

    #[test]
    fn missing_policy_is_four_disabled_requests_without_writing_a_file() {
        let temp = Temp::new();
        let snapshot = repo(&temp).get(&ns()).unwrap();
        assert!(snapshot.ok);
        assert_eq!(snapshot.generation, 0);
        assert_eq!(snapshot.allow_requests, Policy::default());
        assert!(!temp.0.join(FILE).exists());
    }

    #[test]
    fn stale_window_cannot_overwrite_another_capability() {
        let temp = Temp::new();
        let first = repo(&temp).get(&ns()).unwrap();
        repo(&temp)
            .set_allow_requests(&ns(), &first.revision, Kind::Camera, true)
            .unwrap();
        let conflict = repo(&temp)
            .set_allow_requests(&ns(), &first.revision, Kind::Terminal, true)
            .unwrap();
        assert!(!conflict.ok);
        assert_eq!(conflict.status, "conflict");
        assert!(conflict.allow_requests.camera);
        assert!(!conflict.allow_requests.terminal);
        let merged = repo(&temp)
            .set_allow_requests(&ns(), &conflict.revision, Kind::Terminal, true)
            .unwrap();
        assert!(merged.allow_requests.camera && merged.allow_requests.terminal);
    }

    #[test]
    fn enable_disable_cycle_never_reuses_an_old_revision() {
        let temp = Temp::new();
        let first = repo(&temp).get(&ns()).unwrap();
        let on = repo(&temp)
            .set_allow_requests(&ns(), &first.revision, Kind::Voice, true)
            .unwrap();
        let off = repo(&temp)
            .set_allow_requests(&ns(), &on.revision, Kind::Voice, false)
            .unwrap();
        assert_eq!(off.allow_requests, first.allow_requests);
        assert_ne!(off.revision, first.revision);
        assert_eq!(off.generation, 2);
        let stale = repo(&temp)
            .set_allow_requests(&ns(), &first.revision, Kind::Voice, true)
            .unwrap();
        assert!(!stale.ok && !stale.allow_requests.voice);
    }

    #[test]
    fn policies_from_another_server_are_never_inherited() {
        let temp = Temp::new();
        let first = repo(&temp).get(&ns()).unwrap();
        repo(&temp)
            .set_allow_requests(&ns(), &first.revision, Kind::Tunnel, true)
            .unwrap();
        let other = repo(&temp).get(&"b".repeat(64)).unwrap();
        assert_eq!(other.allow_requests, Policy::default());
        assert_eq!(other.generation, 0);
    }

    #[test]
    fn corrupted_policy_never_reads_or_writes_as_successful_disabled_default() {
        let temp = Temp::new();
        let first = repo(&temp).get(&ns()).unwrap();
        Directory::open(&temp.0)
            .unwrap()
            .replace(FILE, b"malformed")
            .unwrap();
        assert!(repo(&temp).get(&ns()).is_err());
        assert!(repo(&temp)
            .set_allow_requests(&ns(), &first.revision, Kind::Camera, false)
            .is_err());
        assert_eq!(std::fs::read(temp.0.join(FILE)).unwrap(), b"malformed");
    }

    #[test]
    fn missing_foreign_root_and_invalid_scope_do_not_succeed() {
        let temp = Temp::new();
        assert!(Repository::new(temp.0.join("absent")).get(&ns()).is_err());
        assert!(repo(&temp).get("../bad").is_err());
        let first = repo(&temp).get(&ns()).unwrap();
        assert!(repo(&temp)
            .set_allow_requests(&ns(), "bad", Kind::Voice, true)
            .is_err());
        assert_eq!(repo(&temp).get(&ns()).unwrap().revision, first.revision);
    }

    #[test]
    fn malformed_schema_and_counter_exhaustion_preserve_original_bytes() {
        let temp = Temp::new();
        let directory = Directory::open(&temp.0).unwrap();
        for raw in [
            serde_json::json!({"version": 2, "scopes": {}}),
            serde_json::json!({"version": 1, "scopes": {}, "unexpected": true}),
            serde_json::json!({"version": 1, "scopes": {ns(): {"generation": 1, "policy": {"camera": true}}}}),
        ] {
            let bytes = serde_json::to_vec(&raw).unwrap();
            directory.replace(FILE, &bytes).unwrap();
            assert!(repo(&temp).get(&ns()).is_err());
            assert_eq!(std::fs::read(temp.0.join(FILE)).unwrap(), bytes);
        }
        let document = Document {
            version: 1,
            scopes: BTreeMap::from([(
                ns(),
                Entry {
                    generation: u64::MAX,
                    policy: Policy::default(),
                },
            )]),
        };
        let bytes = serde_json::to_vec(&document).unwrap();
        directory.replace(FILE, &bytes).unwrap();
        let max = repo(&temp).get(&ns()).unwrap();
        assert!(repo(&temp)
            .set_allow_requests(&ns(), &max.revision, Kind::Terminal, true)
            .is_err());
        assert_eq!(std::fs::read(temp.0.join(FILE)).unwrap(), bytes);
    }

    #[test]
    fn exhausted_policy_can_only_narrow_and_stale_windows_cannot_restore_it() {
        let temp = Temp::new();
        let directory = Directory::open(&temp.0).unwrap();
        let document = Document {
            version: 1,
            scopes: BTreeMap::from([(
                ns(),
                Entry {
                    generation: u64::MAX,
                    policy: Policy {
                        terminal: true,
                        camera: true,
                        ..Policy::default()
                    },
                },
            )]),
        };
        directory
            .replace(FILE, &serde_json::to_vec(&document).unwrap())
            .unwrap();
        let before = repo(&temp).get(&ns()).unwrap();
        let off = repo(&temp)
            .set_allow_requests(&ns(), &before.revision, Kind::Terminal, false)
            .unwrap();
        assert!(off.ok && !off.allow_requests.terminal && off.allow_requests.camera);
        assert_eq!(off.generation, u64::MAX);
        assert_ne!(off.revision, before.revision);
        let stale = repo(&temp)
            .set_allow_requests(&ns(), &before.revision, Kind::Terminal, true)
            .unwrap();
        assert!(!stale.ok && !stale.allow_requests.terminal);
        assert!(repo(&temp)
            .set_allow_requests(&ns(), &off.revision, Kind::Terminal, true)
            .is_err());
        assert!(repo(&temp)
            .set_allow_requests(&ns(), &off.revision, Kind::Camera, true)
            .is_err());
        let closed = repo(&temp)
            .set_allow_requests(&ns(), &off.revision, Kind::Camera, false)
            .unwrap();
        assert_eq!(closed.allow_requests, Policy::default());
        assert_eq!(repo(&temp).get(&ns()).unwrap().revision, closed.revision);
    }

    #[test]
    fn concurrent_windows_have_one_cas_winner() {
        let temp = Temp::new();
        let first = repo(&temp).get(&ns()).unwrap();
        let barrier = std::sync::Arc::new(std::sync::Barrier::new(3));
        let mut threads = Vec::new();
        for kind in [Kind::Camera, Kind::Voice] {
            let root = temp.0.clone();
            let revision = first.revision.clone();
            let ready = barrier.clone();
            threads.push(std::thread::spawn(move || {
                ready.wait();
                Repository::new(root)
                    .set_allow_requests(&ns(), &revision, kind, true)
                    .unwrap()
            }));
        }
        barrier.wait();
        let results: Vec<_> = threads
            .into_iter()
            .map(|thread| thread.join().unwrap())
            .collect();
        assert_eq!(results.iter().filter(|result| result.ok).count(), 1);
        assert_eq!(repo(&temp).get(&ns()).unwrap().generation, 1);
    }
}
