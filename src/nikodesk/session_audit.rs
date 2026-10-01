//! Local native lifecycle records. No passwords, endpoints or remote error text.
use super::{favorites::storage::Directory, server_scope::ServerScope};
use hbb_common::{anyhow::anyhow, bail, log, uuid::Uuid, ResultType};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    path::PathBuf,
    sync::{
        atomic::{AtomicBool, Ordering},
        mpsc::{sync_channel, SyncSender},
        Mutex, OnceLock,
    },
    time::{Instant, SystemTime, UNIX_EPOCH},
};

const KEEP: usize = 200;
const LIMIT: u64 = 256 * 1024;
static WRITE_FAILED: AtomicBool = AtomicBool::new(false);
// Native UI reads and the writer can share one process. Serialize them here;
// the existing file lock additionally coordinates independent app processes.
static REPOSITORY_LOCK: Mutex<()> = Mutex::new(());

#[derive(Clone, Copy, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum Role {
    Controller,
    Receiver,
}

#[derive(Clone, Copy, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum Kind {
    Desktop,
    FileTransfer,
    Camera,
    Terminal,
    Tunnel,
}

impl Kind {
    pub(crate) fn from_login_kind(kind: &str) -> Self {
        match kind {
            "file_transfer" => Self::FileTransfer,
            "view_camera" => Self::Camera,
            "terminal" => Self::Terminal,
            "port_forward" => Self::Tunnel,
            _ => Self::Desktop,
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
enum Phase {
    Connecting,
    Authenticated,
    Disconnected,
    NotAuthenticated,
    Interrupted,
}

impl Phase {
    fn rank(self) -> u8 {
        match self {
            Self::Connecting => 0,
            Self::Authenticated => 1,
            _ => 2,
        }
    }
}

#[derive(Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Entry {
    session: String,
    peer_id: Option<String>,
    role: Role,
    kind: Kind,
    phase: Phase,
    started_at: u64,
    authenticated_at: Option<u64>,
    ended_at: Option<u64>,
    duration_ms: Option<u64>,
}

impl Entry {
    fn validate(&self) -> ResultType<()> {
        if Uuid::parse_str(&self.session).ok().map(|id| id.to_string())
            != Some(self.session.clone())
            || self
                .peer_id
                .as_ref()
                .is_some_and(|id| super::validate_remote_id(id).is_err())
            || self.started_at == 0
            || self.authenticated_at.is_some_and(|at| at < self.started_at)
            || self
                .ended_at
                .is_some_and(|at| at < self.authenticated_at.unwrap_or(self.started_at))
            || (self.ended_at.is_some() != self.duration_ms.is_some())
        {
            bail!("invalid_audit_record");
        }
        let valid = match self.phase {
            Phase::Connecting => self.authenticated_at.is_none() && self.ended_at.is_none(),
            Phase::Authenticated => self.authenticated_at.is_some() && self.ended_at.is_none(),
            Phase::Disconnected => self.authenticated_at.is_some() && self.ended_at.is_some(),
            Phase::NotAuthenticated => self.authenticated_at.is_none() && self.ended_at.is_some(),
            Phase::Interrupted => self.ended_at.is_some(),
        };
        if !valid {
            bail!("invalid_audit_record");
        }
        Ok(())
    }
}

#[derive(Serialize)]
struct Document {
    version: u8,
    namespace: String,
    entries: Vec<Entry>,
    activities: Vec<super::capability_audit::Event>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct StoredDocument {
    version: u8,
    namespace: String,
    entries: Vec<Entry>,
    activities: Option<Vec<super::capability_audit::Event>>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Snapshot {
    ok: bool,
    status: &'static str,
    namespace: String,
    revision: String,
    incomplete: bool,
    entries: Vec<Entry>,
    activities: Vec<super::capability_audit::Event>,
}

struct Repository {
    root: PathBuf,
}

impl Repository {
    fn load(&self, directory: &Directory, namespace: &str) -> ResultType<Document> {
        if ServerScope::from_namespace(namespace).is_none() {
            bail!("invalid_namespace");
        }
        let stored = match directory.read(&format!("nikodesk-audit-{namespace}.json"), LIMIT)? {
            Some(bytes) => serde_json::from_slice::<StoredDocument>(&bytes)
                .map_err(|_| anyhow!("invalid_audit_file"))?,
            None => StoredDocument {
                version: 2,
                namespace: namespace.into(),
                entries: vec![],
                activities: Some(vec![]),
            },
        };
        if !matches!(stored.version, 1 | 2)
            || stored.namespace != namespace
            || stored.entries.len() > KEEP
            || (stored.version == 2 && stored.activities.is_none())
            || stored
                .activities
                .as_ref()
                .is_some_and(|events| events.len() > KEEP)
        {
            bail!("invalid_audit_file");
        }
        let document = Document {
            version: 2,
            namespace: stored.namespace,
            entries: stored.entries,
            activities: stored.activities.unwrap_or_default(),
        };
        let mut activities = std::collections::HashSet::new();
        let mut sequences = std::collections::HashSet::new();
        for event in &document.activities {
            if !event.valid()
                || !activities.insert(&event.id)
                || !sequences.insert((&event.session, event.sequence))
            {
                bail!("invalid_audit_file");
            }
        }
        let mut sessions = std::collections::HashSet::new();
        for entry in &document.entries {
            entry.validate()?;
            if !sessions.insert(&entry.session) {
                bail!("invalid_audit_file");
            }
        }
        Ok(document)
    }

    fn write(&self, directory: &Directory, document: &Document) -> ResultType<()> {
        directory.replace(
            &format!("nikodesk-audit-{}.json", document.namespace),
            &serde_json::to_vec(document)?,
        )
    }

    fn record(&self, namespace: &str, entry: Entry) -> ResultType<()> {
        let _local = REPOSITORY_LOCK
            .lock()
            .map_err(|_| anyhow!("audit_storage_unavailable"))?;
        entry.validate()?;
        let directory = Directory::open(&self.root)?;
        let _lock = directory.lock("nikodesk-audit.lock")?;
        let mut document = self.load(&directory, namespace)?;
        if let Some(existing) = document
            .entries
            .iter_mut()
            .find(|old| old.session == entry.session)
        {
            if existing.peer_id != entry.peer_id
                || existing.role != entry.role
                || existing.kind != entry.kind
                || existing.started_at != entry.started_at
            {
                bail!("audit_session_mismatch");
            }
            if entry.phase.rank() <= existing.phase.rank() {
                return Ok(());
            }
            *existing = entry;
        } else {
            document.entries.push(entry);
        }
        document.entries.sort_by(|a, b| {
            b.started_at
                .cmp(&a.started_at)
                .then_with(|| a.session.cmp(&b.session))
        });
        document.entries.truncate(KEEP);
        self.write(&directory, &document)
    }

    fn activity(&self, namespace: &str, event: super::capability_audit::Event) -> ResultType<()> {
        let _local = REPOSITORY_LOCK
            .lock()
            .map_err(|_| anyhow!("audit_storage_unavailable"))?;
        if !event.valid() {
            bail!("invalid_audit_record");
        }
        let directory = Directory::open(&self.root)?;
        let _lock = directory.lock("nikodesk-audit.lock")?;
        let mut document = self.load(&directory, namespace)?;
        if document.activities.iter().any(|old| old.id == event.id) {
            return Ok(());
        }
        document.activities.push(event);
        document.activities.sort_by(|a, b| {
            b.at.cmp(&a.at)
                .then_with(|| b.sequence.cmp(&a.sequence))
                .then_with(|| a.id.cmp(&b.id))
        });
        document.activities.truncate(KEEP);
        self.write(&directory, &document)
    }

    fn snapshot(&self, namespace: &str, clear_revision: Option<&str>) -> ResultType<Snapshot> {
        let _local = REPOSITORY_LOCK
            .lock()
            .map_err(|_| anyhow!("audit_storage_unavailable"))?;
        let directory = Directory::open(&self.root)?;
        let _lock = directory.lock("nikodesk-audit.lock")?;
        let mut document = self.load(&directory, namespace)?;
        let revision = |value: &Document| -> ResultType<String> {
            Ok(format!("{:x}", Sha256::digest(serde_json::to_vec(value)?)))
        };
        let mut status = "ready";
        let mut ok = true;
        if let Some(expected) = clear_revision {
            if expected != revision(&document)? {
                status = "conflict";
                ok = false;
            } else {
                document.entries.clear();
                document.activities.clear();
                self.write(&directory, &document)?;
                status = "cleared";
            }
        }
        Ok(Snapshot {
            ok,
            status,
            namespace: namespace.to_owned(),
            revision: revision(&document)?,
            incomplete: WRITE_FAILED.load(Ordering::Relaxed),
            entries: document.entries,
            activities: document.activities,
        })
    }
}

struct Write {
    root: PathBuf,
    namespace: String,
    payload: Payload,
}
enum Payload {
    Session(Entry),
    Activity(super::capability_audit::Event),
    #[cfg(test)]
    Drain(std::sync::mpsc::Sender<()>),
}

pub(super) fn failed() {
    if !WRITE_FAILED.swap(true, Ordering::Relaxed) {
        log::warn!(
            "NikoDesk local session records may be incomplete: storage unavailable or queue full"
        );
    }
}

fn writer() -> Option<&'static SyncSender<Write>> {
    static WRITER: OnceLock<Option<SyncSender<Write>>> = OnceLock::new();
    WRITER
        .get_or_init(|| {
            let (sender, receiver) = sync_channel::<Write>(128);
            std::thread::Builder::new()
                .name("nikodesk-session-records".into())
                .spawn(move || {
                    while let Ok(write) = receiver.recv() {
                        let repository = Repository { root: write.root };
                        let result = match write.payload {
                            Payload::Session(entry) => repository.record(&write.namespace, entry),
                            Payload::Activity(event) => {
                                repository.activity(&write.namespace, event)
                            }
                            #[cfg(test)]
                            Payload::Drain(done) => {
                                let _ = done.send(());
                                Ok(())
                            }
                        };
                        if result.is_err() {
                            failed();
                        }
                    }
                })
                .ok()
                .map(|_| sender)
        })
        .as_ref()
}

pub(super) fn timestamp() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|value| value.as_millis().min(u64::MAX as u128) as u64)
        .unwrap_or(0)
}

pub(super) fn queue_activity(
    context: &super::capability_audit::Context,
    event: super::capability_audit::Event,
) {
    let write = Write {
        root: context.root.clone(),
        namespace: context.namespace.clone(),
        payload: Payload::Activity(event),
    };
    if writer().is_none_or(|writer| writer.try_send(write).is_err()) {
        failed();
    }
}

pub(crate) struct SessionAudit {
    root: PathBuf,
    namespace: String,
    entry: Entry,
    started: Instant,
    capabilities: super::capability_audit::Context,
}

impl SessionAudit {
    pub(crate) fn begin(namespace: &str, peer: &str, role: Role, kind: Kind) -> Option<Self> {
        if ServerScope::from_namespace(namespace).is_none() {
            return None;
        }
        let root = match super::favorites::application_root() {
            Ok(root) => root,
            Err(_) => {
                failed();
                return None;
            }
        };
        let entry = Entry {
            session: Uuid::new_v4().to_string(),
            peer_id: super::validate_remote_id(peer)
                .is_ok()
                .then(|| peer.to_owned()),
            role,
            kind,
            phase: Phase::Connecting,
            started_at: timestamp(),
            authenticated_at: None,
            ended_at: None,
            duration_ms: None,
        };
        let capabilities = super::capability_audit::Context::new(
            root.clone(),
            namespace.into(),
            entry.session.clone(),
            entry.peer_id.clone(),
            role,
            entry.started_at,
        );
        let value = Self {
            root,
            namespace: namespace.into(),
            entry,
            started: Instant::now(),
            capabilities,
        };
        value.save();
        Some(value)
    }

    fn save(&self) {
        let write = Write {
            root: self.root.clone(),
            namespace: self.namespace.clone(),
            payload: Payload::Session(self.entry.clone()),
        };
        if writer().is_none_or(|writer| writer.try_send(write).is_err()) {
            failed();
        }
    }

    pub(crate) fn capability_context(&self) -> super::capability_audit::Context {
        self.capabilities.clone()
    }

    pub(crate) fn authenticated(&mut self) {
        if self.entry.phase != Phase::Connecting {
            return;
        }
        self.entry.phase = Phase::Authenticated;
        self.entry.authenticated_at = Some(timestamp().max(self.entry.started_at));
        self.save();
    }

    pub(crate) fn finish(&mut self) {
        self.end(false);
    }

    fn end(&mut self, interrupted: bool) {
        if self.entry.phase.rank() == 2 {
            return;
        }
        self.entry.phase = if interrupted {
            Phase::Interrupted
        } else if self.entry.authenticated_at.is_some() {
            Phase::Disconnected
        } else {
            Phase::NotAuthenticated
        };
        self.entry.ended_at =
            Some(timestamp().max(self.entry.authenticated_at.unwrap_or(self.entry.started_at)));
        self.entry.duration_ms =
            Some(self.started.elapsed().as_millis().min(u64::MAX as u128) as u64);
        self.save();
    }
}

impl Drop for SessionAudit {
    fn drop(&mut self) {
        self.end(true);
    }
}

fn dispatch(namespace: &str, revision: Option<&str>) -> String {
    let result = (|| {
        super::initialize()?;
        let current =
            super::server_scope::current().ok_or_else(|| anyhow!("audit_scope_unavailable"))?;
        if current.namespace() != namespace {
            bail!("audit_scope_changed");
        }
        Repository {
            root: super::favorites::application_root()?,
        }
        .snapshot(namespace, revision)
    })();
    match result {
        Ok(snapshot) => serde_json::to_string(&snapshot).unwrap_or_default(),
        Err(_) => r#"{"ok":false,"status":"unavailable"}"#.to_owned(),
    }
}

pub(crate) fn read(namespace: &str) -> String {
    dispatch(namespace, None)
}
pub(crate) fn clear(namespace: &str, revision: &str) -> String {
    dispatch(namespace, Some(revision))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::nikodesk::favorites::tests::Temp;

    fn entry(role: Role) -> Entry {
        Entry {
            session: Uuid::new_v4().to_string(),
            peer_id: Some("123456789".into()),
            role,
            kind: Kind::Desktop,
            phase: Phase::Connecting,
            started_at: 1000,
            authenticated_at: None,
            ended_at: None,
            duration_ms: None,
        }
    }

    fn drain() {
        let (sender, receiver) = std::sync::mpsc::channel();
        writer()
            .unwrap()
            .send(Write {
                root: PathBuf::new(),
                namespace: String::new(),
                payload: Payload::Drain(sender),
            })
            .unwrap();
        receiver
            .recv_timeout(std::time::Duration::from_secs(10))
            .unwrap();
    }

    fn context(temp: &Temp, ns: &str) -> super::super::capability_audit::Context {
        super::super::capability_audit::Context::new(
            temp.0.clone(),
            ns.into(),
            Uuid::new_v4().to_string(),
            Some("123456789".into()),
            Role::Receiver,
            1000,
        )
    }

    #[test]
    fn actual_capability_acknowledgements_are_local_and_survive_parent_close() {
        use crate::nikodesk::{
            capability_audit::Stage,
            capability_state::{Binding, Capabilities, Kind as Resource, Scope},
        };
        let temp = Temp::new();
        let ns = "a".repeat(64);
        let repository = Repository {
            root: temp.0.clone(),
        };
        let context = context(&temp, &ns);
        let session = context.session_id_for_test();
        let mut lifecycle = entry(Role::Receiver);
        lifecycle.session = session.clone();
        repository.record(&ns, lifecycle.clone()).unwrap();
        let mut state = Capabilities::new(
            Binding::new(ns.clone(), "123456789".into(), [3; 16]).unwrap(),
            true,
            true,
        );
        state.attach_audit(Some(context));
        state.set_policy(Resource::Camera, true, true).unwrap();
        let now = Instant::now();
        let request = state
            .request(Scope::Camera("private-camera-name".into()), [4; 16], now)
            .unwrap();
        let ticket = state
            .approve(&request, now, std::time::Duration::from_secs(60))
            .unwrap();
        state.did_start(&ticket, now).unwrap();
        lifecycle.phase = Phase::Interrupted;
        lifecycle.ended_at = Some(2000);
        lifecycle.duration_ms = Some(1000);
        repository.record(&ns, lifecycle).unwrap();
        let stop = state.revoke(Resource::Camera).unwrap().unwrap();
        state.did_stop(&stop, false).unwrap();
        drain();
        let mut pending = repository.snapshot(&ns, None).unwrap().activities;
        pending.sort_by_key(|event| event.sequence);
        assert_eq!(
            pending.iter().map(|event| event.stage).collect::<Vec<_>>(),
            vec![
                Stage::Requested,
                Stage::Approved,
                Stage::LocalStarted,
                Stage::Revoking,
                Stage::CleanupPending
            ]
        );
        state.did_stop(&stop, true).unwrap();
        assert!(state.did_start(&ticket, now).is_err());
        drain();
        let result = repository.snapshot(&ns, None).unwrap();
        assert_eq!(result.activities.len(), 6);
        assert_eq!(result.activities[0].stage, Stage::Stopped);
        assert!(result
            .activities
            .iter()
            .all(|event| event.session == session));
        let saved = String::from_utf8(
            Directory::open(&temp.0)
                .unwrap()
                .read(&format!("nikodesk-audit-{ns}.json"), LIMIT)
                .unwrap()
                .unwrap(),
        )
        .unwrap();
        assert!(!saved.contains("private-camera-name"));
        assert!(!saved.contains(&"04".repeat(16)));
        assert!(!saved.contains("connection_nonce"));
        assert!(repository
            .snapshot(&"b".repeat(64), None)
            .unwrap()
            .activities
            .is_empty());
    }

    #[test]
    fn capability_events_invalidate_clear_and_wrong_scope_and_duplicates_are_inert() {
        use crate::nikodesk::capability_audit::{Kind as Capability, Stage};
        let temp = Temp::new();
        let ns = "a".repeat(64);
        let repository = Repository {
            root: temp.0.clone(),
        };
        let context = context(&temp, &ns);
        let nonce = "04".repeat(16);
        context.observe(
            Capability::Terminal,
            &ns,
            "123456789",
            &nonce,
            "Pending",
            false,
            false,
        );
        drain();
        let revision = repository.snapshot(&ns, None).unwrap().revision;
        context.observe(
            Capability::Terminal,
            &"b".repeat(64),
            "123456789",
            &nonce,
            "Running",
            false,
            false,
        );
        context.observe(
            Capability::Terminal,
            &ns,
            "987654321",
            &nonce,
            "Running",
            false,
            false,
        );
        context.observe(
            Capability::Terminal,
            &ns,
            "123456789",
            &nonce,
            "Pending",
            false,
            false,
        );
        context.observe(
            Capability::Terminal,
            &ns,
            "123456789",
            &nonce,
            "Stopped",
            true,
            false,
        );
        drain();
        let changed = repository.snapshot(&ns, Some(&revision)).unwrap();
        assert_eq!(changed.status, "conflict");
        assert_eq!(changed.activities.len(), 2);
        assert_eq!(changed.activities[0].stage, Stage::Rejected);
        assert_eq!(
            changed.activities[0].operation,
            changed.activities[1].operation
        );
        let cleared = repository.snapshot(&ns, Some(&changed.revision)).unwrap();
        assert_eq!(cleared.status, "cleared");
        assert!(cleared.activities.is_empty());
    }

    #[test]
    fn legacy_records_upgrade_without_loss_and_damaged_v2_is_not_overwritten() {
        use crate::nikodesk::capability_audit::Kind as Capability;
        let temp = Temp::new();
        let ns = "a".repeat(64);
        let directory = Directory::open(&temp.0).unwrap();
        let file = format!("nikodesk-audit-{ns}.json");
        let repository = Repository {
            root: temp.0.clone(),
        };
        let saved = entry(Role::Controller);
        directory
            .replace(
                &file,
                &serde_json::to_vec(&serde_json::json!({
            "version":1,"namespace":ns,"entries":[saved]}))
                .unwrap(),
            )
            .unwrap();
        assert_eq!(
            repository.snapshot(&ns, None).unwrap().entries[0].session,
            saved.session
        );
        let context = context(&temp, &ns);
        context.observe(
            Capability::Tunnel,
            &ns,
            "123456789",
            &"05".repeat(16),
            "Pending",
            false,
            false,
        );
        drain();
        let upgraded = repository.snapshot(&ns, None).unwrap();
        assert_eq!(upgraded.entries[0].session, saved.session);
        assert_eq!(upgraded.activities.len(), 1);
        let corrupt =
            serde_json::to_vec(&serde_json::json!({"version":2,"namespace":ns,"entries":[]}))
                .unwrap();
        directory.replace(&file, &corrupt).unwrap();
        assert!(repository.record(&ns, entry(Role::Controller)).is_err());
        assert_eq!(directory.read(&file, LIMIT).unwrap().unwrap(), corrupt);
    }

    #[test]
    fn native_preflight_retry_does_not_hide_later_approval_and_start() {
        use crate::nikodesk::capability_audit::{Kind as Capability, Stage};
        let temp = Temp::new();
        let ns = "a".repeat(64);
        let context = context(&temp, &ns);
        let nonce = "06".repeat(16);
        for phase in [
            "Pending",
            "RecoveryRequired",
            "Pending",
            "Starting",
            "Running",
            "Stopped",
        ] {
            context.observe(
                Capability::Camera,
                &ns,
                "123456789",
                &nonce,
                phase,
                false,
                false,
            );
        }
        context.observe(
            Capability::Camera,
            &ns,
            "123456789",
            &nonce,
            "Running",
            false,
            false,
        );
        drain();
        let mut events = Repository {
            root: temp.0.clone(),
        }
        .snapshot(&ns, None)
        .unwrap()
        .activities;
        events.sort_by_key(|event| event.sequence);
        assert_eq!(
            events.iter().map(|event| event.stage).collect::<Vec<_>>(),
            vec![
                Stage::Requested,
                Stage::CleanupPending,
                Stage::Requested,
                Stage::Approved,
                Stage::LocalStarted,
                Stage::Stopped
            ]
        );
    }

    #[test]
    fn retained_voice_observer_distinguishes_local_ready_from_joint_acceptance() {
        use crate::nikodesk::{
            capability_audit::{self, Stage},
            voice_call,
            voice_flow::{Identity, Phase as VoicePhase, Status, Wire},
        };
        let temp = Temp::new();
        let ns = "a".repeat(64);
        let context = context(&temp, &ns);
        let forwarded = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let count = forwarded.clone();
        let observer = capability_audit::voice_observer(
            std::sync::Arc::new(move |_| {
                count.fetch_add(1, Ordering::Relaxed);
            }),
            Some(context.clone()),
        );
        let mut status = Status::pending(
            Identity {
                connection_id: 1,
                namespace: ns.clone(),
                peer_id: "123456789".into(),
                connection_nonce: "07".repeat(16),
                request_nonce: "08".repeat(16),
                epoch: "1".into(),
            },
            Wire {
                call_nonce: "09".repeat(16),
                call_epoch: "1".into(),
            },
        )
        .unwrap();
        observer(voice_call::Event::Status(status.clone()));
        status.local_ready = true;
        status.advance(VoicePhase::Running, "running").unwrap();
        observer(voice_call::Event::Status(status.clone()));
        status.peer_accepted = true;
        status.advance(VoicePhase::Running, "running").unwrap();
        observer(voice_call::Event::Status(status.clone()));
        drop(context);
        status.advance(VoicePhase::Stopped, "stopped").unwrap();
        observer(voice_call::Event::Status(status));
        drain();
        assert_eq!(forwarded.load(Ordering::Relaxed), 4);
        let mut events = Repository {
            root: temp.0.clone(),
        }
        .snapshot(&ns, None)
        .unwrap()
        .activities;
        events.sort_by_key(|event| event.sequence);
        assert_eq!(
            events.iter().map(|event| event.stage).collect::<Vec<_>>(),
            vec![
                Stage::Requested,
                Stage::LocalStarted,
                Stage::Started,
                Stage::Stopped
            ]
        );
    }

    #[test]
    fn native_lifecycle_updates_one_record_and_never_rolls_back_after_close() {
        let temp = Temp::new();
        let repository = Repository {
            root: temp.0.clone(),
        };
        let ns = "a".repeat(64);
        let mut value = entry(Role::Controller);
        repository.record(&ns, value.clone()).unwrap();
        value.phase = Phase::Authenticated;
        value.authenticated_at = Some(2000);
        repository.record(&ns, value.clone()).unwrap();
        let late = value.clone();
        value.phase = Phase::Disconnected;
        value.ended_at = Some(3000);
        value.duration_ms = Some(2000);
        repository.record(&ns, value).unwrap();
        repository.record(&ns, late).unwrap();
        let result = repository.snapshot(&ns, None).unwrap();
        assert_eq!(result.entries.len(), 1);
        assert!(result.entries[0].phase == Phase::Disconnected);
        assert_eq!(result.entries[0].duration_ms, Some(2000));
    }

    #[test]
    fn audit_scopes_and_clear_revision_preserve_newer_records() {
        let temp = Temp::new();
        let repository = Repository {
            root: temp.0.clone(),
        };
        let ns = "a".repeat(64);
        repository.record(&ns, entry(Role::Receiver)).unwrap();
        let revision = repository.snapshot(&ns, None).unwrap().revision;
        repository.record(&ns, entry(Role::Controller)).unwrap();
        assert_eq!(
            repository.snapshot(&ns, Some(&revision)).unwrap().status,
            "conflict"
        );
        assert!(repository
            .snapshot(&"b".repeat(64), None)
            .unwrap()
            .entries
            .is_empty());
        let current = repository.snapshot(&ns, None).unwrap();
        assert_eq!(current.entries.len(), 2);
        assert!(repository
            .snapshot(&ns, Some(&current.revision))
            .unwrap()
            .entries
            .is_empty());
    }

    #[test]
    fn damaged_audit_file_is_preserved_and_untrusted_fields_cannot_be_stored() {
        let temp = Temp::new();
        let repository = Repository {
            root: temp.0.clone(),
        };
        let ns = "a".repeat(64);
        let file = format!("nikodesk-audit-{ns}.json");
        let directory = Directory::open(&temp.0).unwrap();
        directory.replace(&file, b"invalid-json").unwrap();
        assert!(repository.record(&ns, entry(Role::Controller)).is_err());
        assert_eq!(
            directory.read(&file, LIMIT).unwrap().unwrap(),
            b"invalid-json"
        );
        let mut private = serde_json::to_value(entry(Role::Controller)).unwrap();
        private["password"] = serde_json::json!("never-store");
        assert!(serde_json::from_value::<Entry>(private).is_err());
    }

    #[test]
    fn simultaneous_native_writers_do_not_lose_sessions_and_retention_is_bounded() {
        let temp = Temp::new();
        let ns = "a".repeat(64);
        let threads = (0..8)
            .map(|_| {
                let root = temp.0.clone();
                let ns = ns.clone();
                std::thread::spawn(move || {
                    (Repository { root })
                        .record(&ns, entry(Role::Controller))
                        .unwrap()
                })
            })
            .collect::<Vec<_>>();
        let joined = threads
            .into_iter()
            .map(|thread| thread.join())
            .collect::<Vec<_>>();
        assert!(joined.iter().all(Result::is_ok));
        let repository = Repository {
            root: temp.0.clone(),
        };
        assert_eq!(repository.snapshot(&ns, None).unwrap().entries.len(), 8);
        for index in 0..KEEP {
            let mut value = entry(Role::Receiver);
            value.started_at += index as u64;
            repository.record(&ns, value).unwrap();
        }
        assert_eq!(repository.snapshot(&ns, None).unwrap().entries.len(), KEEP);
    }
}
