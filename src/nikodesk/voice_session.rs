//! Local Flutter commands are delivered to the actual captured connection loop.
use super::{voice_call::{self, Call}, voice_flow::{Command, Identity, Operation, Phase}};
use crate::{client::{Data, Interface}, flutter::{self, sessions}, flutter_ffi::SessionID};
use hbb_common::tokio::{self, sync::oneshot};
use serde::Serialize;
use std::{sync::{atomic::{AtomicBool, Ordering}, Arc, Mutex}, time::{Duration, Instant}};

#[derive(Clone)]
pub(crate) enum Input { Prepare, Availability, Command(Command) }

#[derive(Clone)]
pub(crate) struct Request {
    pub session_id: SessionID,
    pub namespace: String,
    pub round: u32,
    pub input: Input,
    deadline: Instant,
    cancelled: Arc<AtomicBool>,
    reply: Arc<Mutex<Option<oneshot::Sender<String>>>>,
}
impl Request {
    pub(crate) fn live(&self) -> bool {
        !self.cancelled.load(Ordering::Acquire) && self.deadline>Instant::now() && self.reply.lock().map_or(false,
            |reply| reply.as_ref().is_some_and(|reply| !reply.is_closed()))
    }
    pub(crate) fn complete(&self, result: String) {
        if let Ok(mut reply)=self.reply.lock() {
            if let Some(reply)=reply.take() { let _=reply.send(result); }
        }
    }
    pub(crate) fn error(&self, reason: &str) { self.complete(error(&self.input,reason)); }
}

pub(crate) fn error(input:&Input, reason:&str)->String {
    match input {
        Input::Command(command)=>serde_json::json!({"ok":false,"status":"error",
            "identity":command.identity,"revision":command.revision,"reason":reason}).to_string(),
        Input::Availability=>Availability::disabled(reason).json(),
        Input::Prepare=>serde_json::json!({"ok":false,"status":"error","reason":reason}).to_string(),
    }
}
#[derive(Serialize)]
pub(crate) struct Availability {
    pub supported: bool,
    pub requests_allowed: bool,
    pub peer_supported: bool,
    pub peer_requests_allowed: bool,
    pub reason: String,
}
impl Availability {
    pub(crate) fn disabled(reason:&str)->Self {
        Self {supported:false,requests_allowed:false,peer_supported:false,peer_requests_allowed:false,reason:reason.into()}
    }
    pub(crate) fn json(&self)->String {
        serde_json::to_string(self).unwrap_or_else(|_| "{\"supported\":false,\"requests_allowed\":false,\"peer_supported\":false,\"peer_requests_allowed\":false,\"reason\":\"worker_failed\"}".into())
    }
}

pub(crate) async fn local_availability(namespace:String)->Result<(), &'static str> {
    tokio::task::spawn_blocking(move||super::voice_runtime::availability(&namespace))
        .await.map_err(|_|"worker_failed")?
}

pub(crate) async fn submit(session_id:SessionID,input:Input,deadline:Instant,cancelled:Arc<AtomicBool>)->String {
    if cancelled.load(Ordering::Acquire) || deadline<=Instant::now() {return error(&input,"timeout");}
    if let Input::Command(command)=&input {
        if let Some(reply)=retired_command(session_id,command) {return reply;}
    }
    let Some(session)=sessions::get_session_by_session_id(&session_id) else {return error(&input,"session_closed");};
    if !session.is_default() {return error(&input,"context_unsupported");}
    let Some(round)=session.connection_round_state.lock().ok().and_then(|state|state.niko_voice_round()) else {return error(&input,"authentication_required");};
    let Some(namespace)=session.lc.read().ok().and_then(|config|config.connection_snapshot().map(|snapshot|snapshot.namespace().to_owned())) else {return error(&input,"namespace_changed");};
    let Some(sender)=session.sender.read().ok().and_then(|sender|sender.clone()) else {return error(&input,"session_closed");};
    let (reply, receiver)=oneshot::channel();
    let request=Request {session_id,namespace,round,input:input.clone(),deadline,cancelled,reply:Arc::new(Mutex::new(Some(reply)))};
    if !request.live() {return error(&input,"timeout");}
    if sender.send(Data::NikoVoiceUi(request)).is_err() {return error(&input,"session_closed");}
    match tokio::time::timeout(deadline.saturating_duration_since(Instant::now()),receiver).await {
        Ok(Ok(reply))=>reply,
        Ok(Err(_))=>error(&input,"session_closed"),
        Err(_)=>error(&input,"timeout"),
    }
}

pub(crate) fn session_observer(session_id:SessionID, ui:flutter::FlutterHandler)->voice_call::Observer {
    session_observer_with_role(session_id, ui, false)
}
pub(crate) fn incoming_observer(session_id:SessionID, ui:flutter::FlutterHandler)->voice_call::Observer {
    session_observer_with_role(session_id, ui, true)
}
fn session_observer_with_role(session_id:SessionID, ui:flutter::FlutterHandler, incoming:bool)->voice_call::Observer {
    Arc::new(move |event| {
        let (name, identity, payload)=match event {
            voice_call::Event::Status(status)=>{
                let identity=status.identity.clone();
                ("nikodesk_voice_status",identity,serde_json::to_string(&status))
            },
            voice_call::Event::Catalog(catalog)=>{
                let identity=catalog.identity.clone();
                ("nikodesk_voice_catalog",identity,serde_json::to_string(&catalog))
            },
        };
        if let Ok(payload)=payload {
            ui.push_event_to(name,&[("payload",payload),("namespace",identity.namespace),
                ("peer_id",identity.peer_id),("connection_nonce",identity.connection_nonce),
                ("initiator",if incoming {"peer"} else {"local"}.into())],&[&session_id]);
        }
    })
}

struct Retired {
    session_id:SessionID,
    identity:Identity,
    call:Mutex<Call>,
}
static RETIRED:Mutex<Vec<Arc<Retired>>>=Mutex::new(Vec::new());

#[derive(Serialize)]
struct CleanupSnapshot {
    session_id: String,
    status: super::voice_flow::Status,
    join_state: &'static str,
}

pub(crate) fn pending_cleanup() -> String {
    let records=match RETIRED.lock() {
        Ok(records)=>records.clone(),
        Err(_)=>return serde_json::json!({"ok":false,"pending":[],"reason":"worker_failed"}).to_string(),
    };
    let mut pending=Vec::new();
    let mut finished=Vec::new();
    for record in records {
        let mut call=match record.call.try_lock() {
            Ok(call)=>call,
            Err(std::sync::TryLockError::WouldBlock)=>return serde_json::json!({"ok":false,"pending":[],"reason":"busy"}).to_string(),
            Err(std::sync::TryLockError::Poisoned(_))=>return serde_json::json!({"ok":false,"pending":[],"reason":"worker_failed"}).to_string(),
        };
        let join_state=match call.finished() {
            Ok(true)=>{finished.push(record.clone());continue;},
            Ok(false)=>"pending",
            Err(_)=>"failed",
        };
        pending.push(CleanupSnapshot {session_id:record.session_id.to_string(),status:call.status(),join_state});
    }
    if !finished.is_empty() {
        match RETIRED.lock() {
            Ok(mut records)=>records.retain(|record|!finished.iter().any(|done|Arc::ptr_eq(record,done))),
            Err(_)=>return serde_json::json!({"ok":false,"pending":[],"reason":"worker_failed"}).to_string(),
        }
    }
    serde_json::json!({"ok":true,"pending":pending}).to_string()
}

pub(crate) fn retire(session_id:SessionID,call:Call) {
    retire_on(super::server_settings::flutter_runtime(),session_id,call);
}

fn retire_on(runtime:Option<tokio::runtime::Handle>,session_id:SessionID,mut call:Call) {
    call.retire();
    let record=Arc::new(Retired {session_id,identity:call.status().identity,call:Mutex::new(call)});
    RETIRED.lock().unwrap_or_else(|error|error.into_inner()).push(record.clone());
    let Some(runtime)=runtime else {return;};
    runtime.spawn(async move {
        let mut timer=tokio::time::interval(Duration::from_millis(20));
        loop {
            timer.tick().await;
            let pending=record.clone();
            let finished=tokio::task::spawn_blocking(move|| {
                let mut call=pending.call.lock().unwrap_or_else(|error|error.into_inner());
                // Its transport is gone. Only cleanup/status remains reachable.
                let _=call.poll();
                matches!(call.finished(),Ok(true))
            }).await.unwrap_or(false);
            if finished {
                RETIRED.lock().unwrap_or_else(|error|error.into_inner())
                    .retain(|item|!Arc::ptr_eq(item,&record));
                break;
            }
        }
    });
}

fn retired_command(session_id:SessionID,command:&Command)->Option<String> {
    let record=RETIRED.lock().ok()?.iter().find(|item| item.session_id==session_id && item.identity==command.identity)?.clone();
    if !matches!(command.op,Operation::Query|Operation::RetryCleanup) {
        return Some(error(&Input::Command(command.clone()),"cleanup_pending"));
    }
    let result=record.call.try_lock().map_err(|error|match error {
        std::sync::TryLockError::WouldBlock=>"busy",
        std::sync::TryLockError::Poisoned(_)=>"worker_failed",
    }).and_then(|mut call|call.command(command.clone()));
    Some(match result {
        Ok(reply)=>serde_json::to_string(&reply).unwrap_or_else(|_|error(&Input::Command(command.clone()),"worker_failed")),
        Err(reason)=>error(&Input::Command(command.clone()),reason),
    })
}

pub(crate) struct Controller {
    pub round:u32,
    pub connection_id:i32,
    pub connection_nonce:String,
    pub namespace:String,
    pub peer_id:String,
    pub owner:Option<SessionID>,
    pub call:Option<Call>,
    pub incoming:bool,
    pub incoming_fence:super::voice_wire::IncomingCallFence,
    pub audit:Option<super::capability_audit::Context>,
}
impl Controller {
    pub(crate) fn new(namespace:String,peer_id:String)->Result<Self,&'static str> {
        if !super::voice_flow::hex(&namespace,64,false) || super::validate_remote_id(&peer_id).is_err() {return Err("context_unsupported");}
        Ok(Self {round:0,connection_id:voice_call::connection_id()?,connection_nonce:voice_call::nonce()?,namespace,peer_id,owner:None,call:None,incoming:false,incoming_fence:Default::default(),audit:None})
    }
    pub(crate) fn identity(&self)->Result<Identity,&'static str> {
        let identity=Identity {connection_id:self.connection_id,namespace:self.namespace.clone(),peer_id:self.peer_id.clone(),connection_nonce:self.connection_nonce.clone(),request_nonce:voice_call::nonce()?,epoch:"1".into()};
        if !identity.valid() {return Err("context_unsupported");}
        Ok(identity)
    }
    pub(crate) fn retire(&mut self) {
        if let (Some(owner),Some(call))=(self.owner.take(),self.call.take()) {retire(owner,call);}
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    static RETIRED_TESTS:Mutex<()>=Mutex::new(());

    #[test]
    fn voice_cancelled_bridge_request_is_inert_before_tokio_abort_runs() {
        let (sender, receiver)=oneshot::channel();
        let cancelled=Arc::new(AtomicBool::new(false));
        let request=Request {session_id:SessionID::nil(),namespace:"a".repeat(64),round:1,
            input:Input::Prepare,deadline:Instant::now()+Duration::from_secs(5),
            cancelled:cancelled.clone(),reply:Arc::new(Mutex::new(Some(sender)))};
        let queued=request.clone();
        assert!(queued.live());
        cancelled.store(true,Ordering::Release);
        assert!(!queued.live());
        assert!(!request.live());
        drop(receiver);
    }

    #[test]
    fn voice_bridge_deadline_does_not_restart_when_native_queue_is_consumed() {
        let (sender, receiver)=oneshot::channel();
        let request=Request {session_id:SessionID::nil(),namespace:"a".repeat(64),round:1,
            input:Input::Prepare,deadline:Instant::now()-Duration::from_millis(1),
            cancelled:Arc::new(AtomicBool::new(false)),reply:Arc::new(Mutex::new(Some(sender)))};
        assert!(!request.live());
        assert!(!request.clone().live());
        drop(receiver);
    }

    #[test]
    fn voice_cleanup_snapshot_keeps_original_owner_and_join_fact_separate() {
        use super::super::voice_flow::{Status,Wire};
        let identity=Identity {connection_id:7,namespace:"a".repeat(64),peer_id:"123456789".into(),
            connection_nonce:"1".repeat(32),request_nonce:"2".repeat(32),epoch:"1".into()};
        let mut status=Status::pending(identity.clone(),Wire {call_nonce:"3".repeat(32),call_epoch:"4".into()}).unwrap();
        status.cleanup_only=true;
        status.advance(Phase::Stopped,"stopped").unwrap();
        let session_id=SessionID::from_bytes([9;16]);
        let value=serde_json::to_value(CleanupSnapshot {session_id:session_id.to_string(),status,join_state:"pending"}).unwrap();
        assert_eq!(value["session_id"],session_id.to_string());
        assert_eq!(value["status"]["identity"],serde_json::to_value(identity).unwrap());
        assert_eq!(value["status"]["phase"],"Stopped");
        assert_eq!(value["join_state"],"pending");
    }

    #[test]
    fn voice_retired_owner_outlives_short_session_runtime_and_is_reaped_after_real_join() {
        let _exclusive=RETIRED_TESTS.lock().unwrap();
        let runner=tokio::runtime::Builder::new_multi_thread().worker_threads(1).enable_all().build().unwrap();
        let session=tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
        let session_id=SessionID::from_bytes([0xa7;16]);
        let (done, worker)=std::sync::mpsc::channel();
        let call=voice_call::cleanup_test_call(worker);
        session.block_on(async {
            retire_on(Some(runner.handle().clone()),session_id,call);
        });
        drop(session);
        assert!(RETIRED.lock().unwrap().iter().any(|record|record.session_id==session_id));
        done.send(()).unwrap();
        let deadline=Instant::now()+Duration::from_secs(2);
        while RETIRED.lock().unwrap().iter().any(|record|record.session_id==session_id) {
            assert!(Instant::now()<deadline,"actual retired owner was not joined and reaped by persistent runner");
            std::thread::sleep(Duration::from_millis(5));
        }
        drop(runner);
    }

    #[test]
    fn voice_cleanup_query_reaps_joined_owner_when_runner_was_unavailable() {
        let _exclusive=RETIRED_TESTS.lock().unwrap();
        let session_id=SessionID::from_bytes([0xb8;16]);
        let (done, worker)=std::sync::mpsc::channel();
        retire_on(None,session_id,voice_call::cleanup_test_call(worker));
        assert!(RETIRED.lock().unwrap().iter().any(|record|record.session_id==session_id));
        done.send(()).unwrap();
        let deadline=Instant::now()+Duration::from_secs(2);
        while RETIRED.lock().unwrap().iter().any(|record|record.session_id==session_id) {
            assert!(Instant::now()<deadline,"query did not reap actual finished owner");
            let response:serde_json::Value=serde_json::from_str(&pending_cleanup()).unwrap();
            assert_eq!(response["ok"],true);
            std::thread::sleep(Duration::from_millis(5));
        }
    }

    #[test]
    fn voice_cleanup_busy_owner_is_unconfirmed_and_preserved_until_actual_join() {
        let _exclusive=RETIRED_TESTS.lock().unwrap();
        let session_id=SessionID::from_bytes([0xc9;16]);
        let (done,worker)=std::sync::mpsc::channel();
        retire_on(None,session_id,voice_call::cleanup_test_call(worker));
        let record=RETIRED.lock().unwrap().iter().find(|record|record.session_id==session_id).unwrap().clone();
        let held=record.call.lock().unwrap();
        let response:serde_json::Value=serde_json::from_str(&pending_cleanup()).unwrap();
        assert_eq!(response["ok"],false);
        assert_eq!(response["reason"],"busy");
        assert!(RETIRED.lock().unwrap().iter().any(|item|Arc::ptr_eq(item,&record)));
        drop(held);
        let response:serde_json::Value=serde_json::from_str(&pending_cleanup()).unwrap();
        assert_eq!(response["ok"],true);
        assert!(response["pending"].as_array().unwrap().iter().any(|item|item["session_id"]==session_id.to_string()));
        done.send(()).unwrap();
        let deadline=Instant::now()+Duration::from_secs(2);
        while RETIRED.lock().unwrap().iter().any(|item|Arc::ptr_eq(item,&record)) {
            assert!(Instant::now()<deadline,"busy owner did not retain and join its actual worker");
            let _=pending_cleanup();
            std::thread::sleep(Duration::from_millis(5));
        }
    }
}
