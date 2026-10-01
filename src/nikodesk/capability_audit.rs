//! Bounded, local observations of native capability transitions. No scope payload,
//! device names, endpoints, terminal data, permission tokens or wire nonces persist.
use super::session_audit::Role;
use hbb_common::uuid::Uuid;
use serde::{Deserialize, Serialize};
use std::{
    collections::VecDeque,
    path::PathBuf,
    sync::{Arc, Mutex},
};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum Kind {
    Terminal,
    Camera,
    Tunnel,
    Voice,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum Stage {
    Requested,
    Approved,
    LocalStarted,
    Started,
    Revoking,
    CleanupPending,
    Stopped,
    Rejected,
    RequestEnded,
    StartUnconfirmed,
}
impl Stage {
    fn rank(self) -> u8 {
        match self {
            Self::Requested => 1,
            Self::Approved => 2,
            Self::LocalStarted => 3,
            Self::Started => 4,
            Self::Revoking => 5,
            Self::CleanupPending => 6,
            Self::Stopped | Self::Rejected | Self::RequestEnded | Self::StartUnconfirmed => 7,
        }
    }
    fn terminal(self) -> bool {
        self.rank() == 7
    }
}
#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct Event {
    pub id: String,
    pub session: String,
    pub operation: String,
    pub sequence: u64,
    pub peer_id: Option<String>,
    pub role: Role,
    pub kind: Kind,
    pub stage: Stage,
    pub at: u64,
}
fn valid_uuid(raw: &str) -> bool {
    Uuid::parse_str(raw).is_ok_and(|id| !id.is_nil() && id.to_string() == raw)
}
impl Event {
    pub(super) fn valid(&self) -> bool {
        valid_uuid(&self.id)
            && valid_uuid(&self.session)
            && valid_uuid(&self.operation)
            && self.sequence != 0
            && self.at != 0
            && self.at <= 8_640_000_000_000_000
            && (self.stage != Stage::Started || self.kind == Kind::Voice)
            && self
                .peer_id
                .as_ref()
                .is_none_or(|id| super::validate_remote_id(id).is_ok())
    }
}
struct Operation {
    kind: Kind,
    nonce: String,
    id: String,
    stage: Stage,
    started: bool,
}
#[derive(Default)]
struct Tracker {
    operations: VecDeque<Operation>,
    sequence: u64,
    last_at: u64,
}
#[derive(Clone)]
pub(crate) struct Context {
    pub(super) root: PathBuf,
    pub(super) namespace: String,
    session: String,
    peer: Option<String>,
    role: Role,
    started: u64,
    tracker: Arc<Mutex<Tracker>>,
}
impl Context {
    pub(super) fn new(
        root: PathBuf,
        namespace: String,
        session: String,
        peer: Option<String>,
        role: Role,
        started: u64,
    ) -> Self {
        Self {
            root,
            namespace,
            session,
            peer,
            role,
            started,
            tracker: Arc::new(Mutex::new(Tracker::default())),
        }
    }
    pub(crate) fn matches(&self, namespace: &str, peer: &str) -> bool {
        self.namespace == namespace && self.peer.as_deref() == Some(peer)
    }
    #[cfg(test)]
    pub(super) fn session_id_for_test(&self) -> String {
        self.session.clone()
    }
    pub(crate) fn observe(
        &self,
        kind: Kind,
        namespace: &str,
        peer: &str,
        nonce: &str,
        phase: &str,
        denied: bool,
        joint_voice: bool,
    ) {
        if !self.matches(namespace, peer)
            || nonce.len() != 32
            || nonce.bytes().all(|b| b == b'0')
            || !nonce
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
        {
            return;
        }
        let Ok(mut tracker) = self.tracker.lock() else {
            super::session_audit::failed();
            return;
        };
        let index = tracker
            .operations
            .iter()
            .position(|item| item.kind == kind && item.nonce == nonce);
        let previous = index.map(|index| tracker.operations[index].stage);
        let stage = match phase {
            "Pending" | "pending" => Stage::Requested,
            "Starting" | "starting" => Stage::Approved,
            "Running" | "running" if kind == Kind::Voice && joint_voice => Stage::Started,
            "Running" | "running" => Stage::LocalStarted,
            "Revoking" | "revoking" => Stage::Revoking,
            "RecoveryRequired" | "recovery_required" => Stage::CleanupPending,
            "Stopped" | "stopped" if denied => Stage::Rejected,
            "Stopped" | "stopped" if previous == Some(Stage::Requested) => Stage::RequestEnded,
            "Stopped" | "stopped" if previous == Some(Stage::Approved) => Stage::StartUnconfirmed,
            "Stopped" | "stopped" if previous.is_some() => Stage::Stopped,
            // An unsolicited idle/late stop cannot prove cleanup of an unobserved operation.
            _ => return,
        };
        // A direct local denial may arrive after the native idle transition.
        let denial = previous == Some(Stage::RequestEnded) && stage == Stage::Rejected;
        // A native preflight/failed start can return to waiting for approval.
        // Once a resource ran, an earlier callback cannot regress its record.
        let retry = index.is_some_and(|index| !tracker.operations[index].started)
            && matches!(previous, Some(Stage::Approved | Stage::CleanupPending))
            && matches!(stage, Stage::Requested | Stage::Approved);
        if !denial
            && !retry
            && previous
                .is_some_and(|old| old == stage || old.terminal() || old.rank() > stage.rank())
        {
            return;
        }
        if index.is_none() && stage.rank() >= Stage::Revoking.rank() {
            return;
        }
        if index.is_none() && tracker.operations.len() == 64 {
            let Some(closed) = tracker
                .operations
                .iter()
                .position(|entry| entry.stage.terminal())
            else {
                super::session_audit::failed();
                return;
            };
            tracker.operations.remove(closed);
        }
        let operation = if let Some(index) = index {
            tracker.operations[index].stage = stage;
            tracker.operations[index].started |=
                matches!(stage, Stage::LocalStarted | Stage::Started);
            tracker.operations[index].id.clone()
        } else {
            let id = Uuid::new_v4().to_string();
            tracker.operations.push_back(Operation {
                kind,
                nonce: nonce.into(),
                id: id.clone(),
                stage,
                started: matches!(stage, Stage::LocalStarted | Stage::Started),
            });
            id
        };
        let Some(sequence) = tracker.sequence.checked_add(1) else {
            super::session_audit::failed();
            return;
        };
        tracker.sequence = sequence;
        let at = super::session_audit::timestamp()
            .max(self.started)
            .max(tracker.last_at);
        tracker.last_at = at;
        let event = Event {
            id: Uuid::new_v4().to_string(),
            session: self.session.clone(),
            operation,
            sequence,
            peer_id: self.peer.clone(),
            role: self.role,
            kind,
            stage,
            at,
        };
        // Enqueue while the short observation lock preserves native transition order.
        // Persistence runs on the existing bounded writer, never this control path.
        super::session_audit::queue_activity(self, event);
    }
}

#[cfg(not(any(target_os = "android", target_os = "ios")))]
pub(crate) fn cm(context: &Context, data: &crate::ipc::Data) {
    use crate::ipc::Data;
    match data {
        Data::NikoCapabilityStatus(status) if status.kind == "terminal" => context.observe(
            Kind::Terminal,
            &status.identity.namespace,
            &status.identity.peer_id,
            &status.identity.request_nonce,
            &status.phase,
            status.reason == "Denied locally",
            false,
        ),
        Data::NikoCameraStatus(status) | Data::NikoCameraRetired(status) => context.observe(
            Kind::Camera,
            &status.identity.namespace,
            &status.identity.peer_id,
            &status.identity.request_nonce,
            &status.phase,
            status.reason == "denied",
            false,
        ),
        Data::NikoVoiceStatus { status, .. }
        | Data::NikoVoiceRetired(status)
        | Data::NikoVoiceCleanupStatus(status) => voice(context, status),
        Data::NikoTunnelStatus(raw)
        | Data::NikoTunnelRetired(raw)
        | Data::NikoTunnelCleanupStatus(raw) => {
            if raw.len() > 32768 {
                return;
            }
            #[derive(Deserialize)]
            struct Projection {
                identity: super::connection_capabilities::Identity,
                phase: String,
                reason: String,
            }
            if let Ok(status) = serde_json::from_str::<Projection>(raw) {
                context.observe(
                    Kind::Tunnel,
                    &status.identity.namespace,
                    &status.identity.peer_id,
                    &status.identity.request_nonce,
                    &status.phase,
                    status.reason == "denied_locally",
                    false,
                );
            }
        }
        _ => {}
    }
}
pub(crate) fn voice(context: &Context, status: &super::voice_flow::Status) {
    if status.phase == super::voice_flow::Phase::Running && !status.local_ready {
        return;
    }
    context.observe(
        Kind::Voice,
        &status.identity.namespace,
        &status.identity.peer_id,
        &status.identity.request_nonce,
        &format!("{:?}", status.phase),
        status.reason == "denied",
        status.call_running && status.local_ready && status.peer_accepted,
    );
}

/// The actual native Call retains this observer through worker cleanup, even
/// when its parent session or Flutter page has already closed.
pub(crate) fn voice_observer(
    observer: super::voice_call::Observer,
    context: Option<Context>,
) -> super::voice_call::Observer {
    let Some(context) = context else {
        return observer;
    };
    Arc::new(move |event| {
        if let super::voice_call::Event::Status(status) = &event {
            voice(&context, status);
        }
        observer(event);
    })
}
