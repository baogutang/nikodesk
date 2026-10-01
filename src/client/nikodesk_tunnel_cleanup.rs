//! Cleanup of the original native PF thread, independent of the UI registry.
use serde::Deserialize;
use std::{
    collections::HashMap,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex, MutexGuard, OnceLock,
    },
    thread::{JoinHandle, ThreadId},
};
use uuid::Uuid;

const MAX_OWNERS: usize = 64;

#[derive(Default)]
pub(crate) struct ThreadProofState {
    closing: AtomicBool,
    close_requested: AtomicBool,
    transitioning: AtomicBool,
    failed: AtomicBool,
    started: AtomicBool,
    run: Mutex<Option<Arc<RunProof>>>,
}

#[derive(Default)]
pub(crate) struct RunProof {
    thread_id: Mutex<Option<ThreadId>>,
    children_closed: AtomicBool,
    failed: AtomicBool,
}
impl RunProof {
    fn bind(&self, handle: &JoinHandle<()>) -> Result<(), &'static str> {
        *self.thread_id.lock().map_err(|_| "tunnel_worker_failed")? = Some(handle.thread().id());
        Ok(())
    }
    fn matches(&self, handle: &JoinHandle<()>) -> bool {
        self.thread_id
            .lock()
            .map_or(false, |id| *id == Some(handle.thread().id()))
    }
    pub(crate) fn record_children_cleanup(&self, closed: bool) {
        if !closed {
            self.failed.store(true, Ordering::Release);
        }
        self.children_closed.store(closed, Ordering::Release);
    }
    fn closed(&self) -> bool {
        self.children_closed.load(Ordering::Acquire) && !self.failed.load(Ordering::Acquire)
    }
}
impl ThreadProofState {
    pub(crate) fn run_proof(&self) -> Option<Arc<RunProof>> {
        self.run.lock().ok().and_then(|run| run.clone())
    }
    pub(crate) fn closing(&self) -> bool {
        self.closing.load(Ordering::Acquire)
    }
    pub(crate) fn close_requested(&self) -> bool {
        self.close_requested.load(Ordering::Acquire)
    }
}

#[derive(Clone, PartialEq, Eq)]
struct Key {
    session_id: Uuid,
    namespace: String,
    peer_id: String,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Command {
    namespace: String,
    peer_id: String,
}
impl Key {
    fn parse(session_id: Uuid, json: &str) -> Result<Self, &'static str> {
        if session_id.is_nil() || json.len() > 1024 {
            return Err("tunnel_invalid_command");
        }
        let value: Command = serde_json::from_str(json).map_err(|_| "tunnel_invalid_command")?;
        if value.namespace.len() != 64
            || !value
                .namespace
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
            || !(6..=16).contains(&value.peer_id.len())
            || !value.peer_id.bytes().all(|b| b.is_ascii_digit())
            || value.peer_id.bytes().all(|b| b == b'0')
        {
            return Err("tunnel_invalid_command");
        }
        Ok(Self {
            session_id,
            namespace: value.namespace,
            peer_id: value.peer_id,
        })
    }
}

enum Completion {
    Pending,
    Joining,
    Closed,
    Failed,
}
struct Owner {
    key: Key,
    thread: Option<JoinHandle<()>>,
    proof: Option<Arc<RunProof>>,
    completion: Completion,
    #[cfg(feature = "flutter")]
    _original_session: Option<crate::flutter::FlutterSession>,
}
impl Owner {
    fn reason(&self) -> &'static str {
        match self.completion {
            Completion::Closed => "closed",
            Completion::Failed => "tunnel_worker_failed",
            Completion::Pending | Completion::Joining => "cleanup_pending",
        }
    }
}
type RetainedOwner = Arc<Mutex<Owner>>;
#[derive(Default)]
struct Registry {
    owners: HashMap<Uuid, RetainedOwner>,
}
impl Registry {
    fn reserve(&mut self) -> Result<(), &'static str> {
        if self.owners.len() >= MAX_OWNERS {
            self.owners.retain(|_, owner| {
                owner.try_lock().map_or(true, |owner| {
                    !matches!(owner.completion, Completion::Closed)
                })
            });
        }
        if self.owners.len() >= MAX_OWNERS {
            return Err("owner_full");
        }
        Ok(())
    }
    fn get(&self, key: &Key) -> Result<Option<RetainedOwner>, &'static str> {
        let Some(owner) = self.owners.get(&key.session_id) else {
            return Ok(None);
        };
        let value = owner.lock().map_err(|_| "tunnel_worker_failed")?;
        if &value.key != key {
            return Err("tunnel_owner_mismatch");
        }
        drop(value);
        Ok(Some(owner.clone()))
    }
}
fn registry() -> &'static Mutex<Registry> {
    static REGISTRY: OnceLock<Mutex<Registry>> = OnceLock::new();
    REGISTRY.get_or_init(|| Mutex::new(Registry::default()))
}

pub(crate) struct UuidAdmission {
    _guard: MutexGuard<'static, Registry>,
}
pub(crate) fn admit_uuid(session_id: &Uuid) -> Result<UuidAdmission, &'static str> {
    let guard = registry().lock().map_err(|_| "tunnel_worker_failed")?;
    if guard.owners.contains_key(session_id) { return Err("tunnel_cleanup_uuid_retained"); }
    Ok(UuidAdmission { _guard: guard })
}

fn poll_owner(owner: &RetainedOwner) -> Result<(&'static str, bool), &'static str> {
    let work = {
        let mut owner = owner.lock().map_err(|_| "tunnel_worker_failed")?;
        match owner.completion {
            Completion::Closed => return Ok(("closed", true)),
            Completion::Failed if owner.thread.is_none() => {
                return Ok(("tunnel_worker_failed", false))
            }
            Completion::Failed => {}
            Completion::Joining => return Ok(("cleanup_pending", false)),
            Completion::Pending => {}
        }
        let failed = matches!(owner.completion, Completion::Failed);
        let Some(thread) = owner.thread.as_ref() else {
            owner.completion = Completion::Failed;
            return Ok(("tunnel_worker_failed", false));
        };
        if !thread.is_finished() {
            return Ok((owner.reason(), false));
        }
        let thread = owner.thread.take().ok_or("tunnel_worker_failed")?;
        let proof = owner.proof.clone();
        owner.completion = Completion::Joining;
        (thread, proof, failed)
    };
    // is_finished is checked above; no registry or owner guard crosses the join.
    let matched = work.1.as_ref().is_some_and(|proof| proof.matches(&work.0));
    let joined = work.0.join().is_ok();
    let closed = !work.2 && joined && matched && work.1.is_some_and(|proof| proof.closed());
    let mut owner = owner.lock().map_err(|_| "tunnel_worker_failed")?;
    owner.completion = if closed {
        Completion::Closed
    } else {
        Completion::Failed
    };
    Ok((owner.reason(), closed))
}
fn reply(key: &Key, ok: bool, reason: &'static str, closed: bool) -> String {
    serde_json::json!({"session_id":key.session_id.to_string(),"namespace":key.namespace,
        "peer_id":key.peer_id,"ok":ok,"reason":reason,"local_resources_closed":closed})
    .to_string()
}
fn invalid_reply(session_id: Uuid, reason: &'static str) -> String {
    reply(
        &Key {
            session_id,
            namespace: String::new(),
            peer_id: String::new(),
        },
        false,
        reason,
        false,
    )
}
pub(crate) fn query(session_id: Uuid, json: String) -> String {
    let key = match Key::parse(session_id, &json) {
        Ok(key) => key,
        Err(reason) => return invalid_reply(session_id, reason),
    };
    let result = registry()
        .lock()
        .map_err(|_| "tunnel_worker_failed")
        .and_then(|registry| registry.get(&key));
    match result {
        Ok(Some(owner)) => match poll_owner(&owner) {
            Ok((reason, closed)) => reply(&key, true, reason, closed),
            Err(reason) => reply(&key, false, reason, false),
        },
        Ok(None) => {
            #[cfg(feature = "flutter")]
            if requested_key_matches(&key) {
                return reply(&key, false, "owner_full", false);
            }
            reply(&key, false, "tunnel_cleanup_owner_not_found", false)
        }
        Err(reason) => reply(&key, false, reason, false),
    }
}
pub(crate) fn list() -> String {
    let owners = match registry().lock() {
        Ok(registry) => registry.owners.values().cloned().collect::<Vec<_>>(),
        Err(_) => {
            return serde_json::json!({"ok":false,"reason":"tunnel_worker_failed","owners":[]})
                .to_string()
        }
    };
    let mut records = Vec::new();
    for owner in owners {
        if poll_owner(&owner).is_err() {
            return serde_json::json!({"ok":false,"reason":"tunnel_worker_failed","owners":[]})
                .to_string();
        }
        let owner = match owner.lock() {
            Ok(owner) => owner,
            Err(_) => {
                return serde_json::json!({"ok":false,"reason":"tunnel_worker_failed","owners":[]})
                    .to_string()
            }
        };
        if !matches!(owner.completion, Completion::Closed) {
            records.push(serde_json::json!({"session_id":owner.key.session_id.to_string(),
                "namespace":owner.key.namespace,"peer_id":owner.key.peer_id,"reason":owner.reason()}));
        }
    }
    #[cfg(feature = "flutter")]
    if records.len() < MAX_OWNERS {
        let requested = match crate::flutter::sessions::requested_nikodesk_tunnel_owners() {
            Ok(owners) => owners,
            Err(_) => {
                return serde_json::json!({"ok":false,"reason":"tunnel_worker_failed","owners":[]})
                    .to_string()
            }
        };
        for (session_id, namespace, peer_id) in
            requested.into_iter().take(MAX_OWNERS - records.len())
        {
            records.push(serde_json::json!({"session_id":session_id.to_string(),"namespace":namespace,"peer_id":peer_id,"reason":"owner_full"}));
        }
    }
    serde_json::json!({"ok":true,"reason":"ready","owners":records}).to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        sync::mpsc,
        time::{Duration, Instant},
    };
    fn key(n: u128) -> Key {
        Key {
            session_id: Uuid::from_u128(n),
            namespace: "a".repeat(64),
            peer_id: "123456789".into(),
        }
    }
    fn owner(key: Key, thread: JoinHandle<()>, proof: Option<Arc<RunProof>>) -> RetainedOwner {
        Arc::new(Mutex::new(Owner {
            key,
            thread: Some(thread),
            proof,
            completion: Completion::Pending,
            #[cfg(feature = "flutter")]
            _original_session: None,
        }))
    }
    fn await_finished(owner: &RetainedOwner) {
        let deadline = Instant::now() + Duration::from_secs(2);
        loop {
            if owner.lock().unwrap().thread.as_ref().unwrap().is_finished() {
                return;
            }
            assert!(
                Instant::now() < deadline,
                "isolated native worker did not exit"
            );
            std::thread::yield_now();
        }
    }
    fn completed(n: u128, closed: bool, panics: bool) -> RetainedOwner {
        let proof = Arc::new(RunProof::default());
        let worker = proof.clone();
        let thread = std::thread::spawn(move || {
            worker.record_children_cleanup(closed);
            if panics {
                panic!("isolated tunnel native worker panic");
            }
        });
        proof.bind(&thread).unwrap();
        let owner = owner(key(n), thread, Some(proof));
        await_finished(&owner);
        owner
    }
    #[test]
    fn original_waiting_thread_is_retained_until_real_children_and_join() {
        let proof = Arc::new(RunProof::default());
        let worker = proof.clone();
        let (done, wait) = mpsc::channel();
        let thread = std::thread::spawn(move || {
            wait.recv().unwrap();
            worker.record_children_cleanup(true);
        });
        proof.bind(&thread).unwrap();
        let owner = owner(key(1), thread, Some(proof));
        assert_eq!(poll_owner(&owner).unwrap(), ("cleanup_pending", false));
        assert!(owner.lock().unwrap().thread.is_some());
        done.send(()).unwrap();
        await_finished(&owner);
        assert_eq!(poll_owner(&owner).unwrap(), ("closed", true));
        assert!(owner.lock().unwrap().thread.is_none());
        assert_eq!(poll_owner(&owner).unwrap(), ("closed", true));
    }
    #[test]
    fn native_thread_panic_cannot_be_overwritten_by_successful_children() {
        let owner = completed(2, true, true);
        assert_eq!(poll_owner(&owner).unwrap(), ("tunnel_worker_failed", false));
        assert!(owner.lock().unwrap().thread.is_none());
        assert_eq!(poll_owner(&owner).unwrap(), ("tunnel_worker_failed", false));
    }
    #[test]
    fn normal_native_thread_join_cannot_replace_failed_children() {
        let owner = completed(3, false, false);
        assert_eq!(poll_owner(&owner).unwrap(), ("tunnel_worker_failed", false));
        let proof = owner.lock().unwrap().proof.clone().unwrap();
        proof.record_children_cleanup(true);
        assert!(!proof.closed());
        assert_eq!(poll_owner(&owner).unwrap(), ("tunnel_worker_failed", false));
    }
    #[test]
    fn original_thread_without_children_proof_remains_unknown() {
        let thread = std::thread::spawn(|| {});
        let owner = owner(key(4), thread, None);
        await_finished(&owner);
        assert_eq!(poll_owner(&owner).unwrap(), ("tunnel_worker_failed", false));
    }
    #[test]
    fn another_real_thread_proof_cannot_confirm_original_thread() {
        let proof = Arc::new(RunProof::default());
        proof.record_children_cleanup(true);
        let other = std::thread::spawn(|| {});
        proof.bind(&other).unwrap();
        other.join().unwrap();
        let thread = std::thread::spawn(|| {});
        let owner = owner(key(5), thread, Some(proof));
        await_finished(&owner);
        assert_eq!(poll_owner(&owner).unwrap(), ("tunnel_worker_failed", false));
    }
    #[test]
    fn original_uuid_namespace_peer_are_all_required_for_retained_owner() {
        let original = key(6);
        let owner = completed(6, true, false);
        let mut registry = Registry::default();
        registry.owners.insert(original.session_id, owner.clone());
        let mut changed = original.clone();
        changed.namespace = "b".repeat(64);
        assert!(registry.get(&changed).is_err());
        changed = original.clone();
        changed.peer_id = "987654321".into();
        assert!(registry.get(&changed).is_err());
        changed = original.clone();
        changed.session_id = Uuid::from_u128(7);
        assert!(registry.get(&changed).unwrap().is_none());
        assert!(Arc::ptr_eq(
            &registry.get(&original).unwrap().unwrap(),
            &owner
        ));
        poll_owner(&owner).unwrap();
    }
    #[test]
    fn owner_capacity_cannot_evict_unknown_but_can_reclaim_closed_tombstone() {
        let mut registry = Registry::default();
        for i in 1..=MAX_OWNERS {
            let key = key(100 + i as u128);
            registry.owners.insert(
                key.session_id,
                Arc::new(Mutex::new(Owner {
                    key,
                    thread: None,
                    proof: None,
                    completion: Completion::Failed,
                    #[cfg(feature = "flutter")]
                    _original_session: None,
                })),
            );
        }
        assert_eq!(registry.reserve(), Err("owner_full"));
        assert_eq!(registry.owners.len(), MAX_OWNERS);
        let id = key(101).session_id;
        registry.owners.get(&id).unwrap().lock().unwrap().completion = Completion::Closed;
        assert!(registry.reserve().is_ok());
        assert!(!registry.owners.contains_key(&id));
        assert_eq!(registry.owners.len(), MAX_OWNERS - 1);
    }
    #[test]
    fn unknown_owner_still_joins_its_actual_finished_thread_without_ack() {
        let owner = completed(8, true, false);
        owner.lock().unwrap().completion = Completion::Failed;
        assert_eq!(poll_owner(&owner).unwrap(), ("tunnel_worker_failed", false));
        assert!(owner.lock().unwrap().thread.is_none());
    }
    #[test]
    fn strict_commands_and_six_key_reply_cannot_mint_resource_ack() {
        let id = Uuid::from_u128(9);
        let raw = serde_json::json!({"namespace":"a".repeat(64),"peer_id":"123456789"});
        let key = Key::parse(id, &raw.to_string()).unwrap();
        let mut extra = raw.clone();
        extra["approved"] = true.into();
        assert!(Key::parse(id, &extra.to_string()).is_err());
        assert!(Key::parse(Uuid::nil(), &raw.to_string()).is_err());
        let value: serde_json::Value =
            serde_json::from_str(&reply(&key, true, "cleanup_pending", false)).unwrap();
        assert_eq!(value.as_object().unwrap().len(), 6);
        assert_eq!(value["session_id"], id.to_string());
        assert_eq!(value["local_resources_closed"], false);
    }
}

// Native session integration.
use crate::ui_session_interface::{io_loop, InvokeUiSession, Session};

pub(crate) fn start_thread<T: InvokeUiSession>(
    session: &Session<T>,
    round: u32,
) -> Result<(), &'static str> {
    let state = &session.niko_tunnel_thread;
    let mut slot = session.thread.lock().map_err(|_| "tunnel_worker_failed")?;
    if state.closing()
        || state.transitioning.load(Ordering::Acquire)
        || state.failed.load(Ordering::Acquire)
    {
        return Err("tunnel_cleanup_pending");
    }
    if slot.is_some() || state.started.load(Ordering::Acquire) {
        return Err("tunnel_thread_already_started");
    }
    spawn_locked(session, round, &mut slot)
}
fn spawn_locked<T: InvokeUiSession>(
    session: &Session<T>,
    round: u32,
    slot: &mut Option<JoinHandle<()>>,
) -> Result<(), &'static str> {
    let proof = Arc::new(RunProof::default());
    *session
        .niko_tunnel_thread
        .run
        .lock()
        .map_err(|_| "tunnel_worker_failed")? = Some(proof.clone());
    let cloned = session.clone();
    let handle = std::thread::spawn(move || io_loop(cloned, round));
    // Bind and retain under the original thread guard, even if binding fails.
    let result = proof.bind(&handle);
    *slot = Some(handle);
    session
        .niko_tunnel_thread
        .started
        .store(true, Ordering::Release);
    if result.is_err() {
        session
            .niko_tunnel_thread
            .failed
            .store(true, Ordering::Release);
    }
    result
}
pub(crate) fn reconnect<T: InvokeUiSession>(
    session: &Session<T>,
    force_relay: bool,
) -> Result<(), &'static str> {
    let state = &session.niko_tunnel_thread;
    let old = {
        let mut slot = session.thread.lock().map_err(|_| "tunnel_worker_failed")?;
        if state.closing()
            || state.failed.load(Ordering::Acquire)
            || state.transitioning.load(Ordering::Acquire)
        {
            return Err("tunnel_cleanup_pending");
        }
        if slot.as_ref().is_some_and(|thread| !thread.is_finished()) {
            return Err("tunnel_cleanup_pending");
        }
        let proof = state.run_proof();
        if let Some(thread) = slot.as_ref() {
            if !proof
                .as_ref()
                .is_some_and(|proof| proof.matches(thread) && proof.closed())
            {
                state.failed.store(true, Ordering::Release);
                return Err("tunnel_worker_failed");
            }
        } else if state.started.load(Ordering::Acquire) {
            return Err("tunnel_worker_failed");
        }
        state.transitioning.store(true, Ordering::Release);
        slot.take()
    };
    if old.is_some_and(|thread| thread.join().is_err()) {
        state.failed.store(true, Ordering::Release);
        state.transitioning.store(false, Ordering::Release);
        return Err("tunnel_worker_failed");
    }
    let result = (|| {
        if force_relay {
            let mut lc = session.lc.write().map_err(|_| "tunnel_worker_failed")?;
            lc.force_relay = true;
            lc.policy_relay = true;
            lc.peer_relay = true;
        }
        session
            .lc
            .write()
            .map_err(|_| "tunnel_worker_failed")?
            .peer_info = None;
        session.reconnect_count.fetch_add(1, Ordering::SeqCst);
        let round = session
            .connection_round_state
            .lock()
            .map_err(|_| "tunnel_worker_failed")?
            .new_round();
        let mut slot = session.thread.lock().map_err(|_| "tunnel_worker_failed")?;
        if state.closing() || slot.is_some() {
            return Err("tunnel_cleanup_pending");
        }
        spawn_locked(session, round, &mut slot)
    })();
    state.transitioning.store(false, Ordering::Release);
    if result.is_err() {
        state.failed.store(true, Ordering::Release);
    }
    result
}

#[cfg(feature = "flutter")]
pub(crate) fn close(session_id: Uuid, json: String) -> String {
    use crate::client::{Data, Interface};
    let key = match Key::parse(session_id, &json) {
        Ok(key) => key,
        Err(reason) => return invalid_reply(session_id, reason),
    };
    let mut cancelled_on_full = None;
    let result = (|| -> Result<Option<RetainedOwner>, &'static str> {
        let mut registry = registry().lock().map_err(|_| "tunnel_worker_failed")?;
        if let Some(owner) = registry.get(&key)? {
            if let Some(current) = crate::flutter::sessions::get_session_by_session_id(&session_id) {
                let original = owner.lock().map_err(|_| "tunnel_worker_failed")?;
                if !original._original_session.as_ref().is_some_and(|session| Arc::ptr_eq(session, &current)) {
                    return Err("tunnel_owner_mismatch");
                }
            }
            return Ok(Some(owner));
        }
        let session = crate::flutter::sessions::get_session_by_session_id(&session_id)
            .ok_or("tunnel_session_closed")?;
        if !session.is_port_forward() || session.is_rdp() {
            return Err("tunnel_session_mismatch");
        }
        let snapshot = session
            .connection_snapshot()
            .map_err(|_| "tunnel_worker_failed")?;
        if snapshot.namespace() != key.namespace || session.get_id() != key.peer_id {
            return Err("tunnel_owner_mismatch");
        }
        let mut slot = session.thread.lock().map_err(|_| "tunnel_worker_failed")?;
        if session
            .niko_tunnel_thread
            .transitioning
            .load(Ordering::Acquire)
        {
            return Err("tunnel_cleanup_pending");
        }
        let proof = session.niko_tunnel_thread.run_proof();
        let mut retained = None;
        let last = crate::flutter::sessions::detach_nikodesk_tunnel_ui_if_current(
            &session_id,
            &session,
            || {
                if let Err(reason) = registry.reserve() {
                    session
                        .niko_tunnel_thread
                        .close_requested
                        .store(true, Ordering::Release);
                    session
                        .niko_tunnel_thread
                        .closing
                        .store(true, Ordering::Release);
                    cancelled_on_full = Some(session.clone());
                    return Err(reason);
                }
                session
                    .niko_tunnel_thread
                    .close_requested
                    .store(true, Ordering::Release);
                session
                    .niko_tunnel_thread
                    .closing
                    .store(true, Ordering::Release);
                let handle = slot.take();
                let never_started =
                    !session.niko_tunnel_thread.started.load(Ordering::Acquire) && handle.is_none();
                let failed = session.niko_tunnel_thread.failed.load(Ordering::Acquire);
                let completion = if never_started && !failed {
                    Completion::Closed
                } else if handle.is_none() || failed {
                    Completion::Failed
                } else {
                    Completion::Pending
                };
                let owner = Arc::new(Mutex::new(Owner {
                    key: key.clone(),
                    thread: handle,
                    proof: proof.clone(),
                    completion,
                    _original_session: Some(session.clone()),
                }));
                registry.owners.insert(session_id, owner.clone());
                retained = Some(owner);
                Ok(())
            },
        )?;
        drop(slot);
        drop(registry);
        if last {
            // The old native thread can publish its sender after an early close;
            // io_loop checks the irreversible closing flag before PF starts.
            if let Ok(sender) = session.sender.read() {
                if let Some(sender) = sender.as_ref() {
                    let _ = sender.send(Data::Close);
                }
            }
        }
        Ok(retained)
    })();
    if let Some(session) = cancelled_on_full {
        if let Ok(sender) = session.sender.read() {
            if let Some(sender) = sender.as_ref() {
                let _ = sender.send(Data::Close);
            }
        }
    }
    match result {
        Ok(Some(owner)) => match poll_owner(&owner) {
            Ok((reason, closed)) => reply(&key, true, reason, closed),
            Err(reason) => reply(&key, false, reason, false),
        },
        Ok(None) => reply(&key, true, "ui_detached", false),
        Err(reason) => reply(&key, false, reason, false),
    }
}

#[cfg(feature = "flutter")]
fn requested_key_matches(key: &Key) -> bool {
    use crate::client::Interface;
    crate::flutter::sessions::get_session_by_session_id(&key.session_id).is_some_and(|session| {
        session.niko_tunnel_thread.close_requested()
            && session.is_port_forward()
            && !session.is_rdp()
            && session.get_id() == key.peer_id
            && session
                .connection_snapshot()
                .is_ok_and(|snapshot| snapshot.namespace() == key.namespace)
    })
}
