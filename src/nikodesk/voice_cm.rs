use super::*;
use crate::nikodesk::voice_flow::{self, Command, Identity, Operation, Phase, Status};

fn newer_counter(new:&str,old:&str)->bool {
    voice_flow::counter(new) && voice_flow::counter(old)
        && new.parse::<u64>().ok()>=old.parse::<u64>().ok()
}
impl Client {
    fn voice_desktop(&self)->bool { !self.is_file_transfer && !self.is_view_camera && !self.is_terminal && self.port_forward.is_empty() }
    fn voice_status_matches(&self,status:&Status)->bool {
        self.voice_desktop() && status.identity.valid() && status.identity.connection_id==self.id
            && status.identity.peer_id==self.peer_id && status.kind=="voice"
            && status.wire.valid() && voice_flow::counter(&status.revision) && voice_flow::counter(&status.resource_epoch)
    }
    fn apply_voice_status(&mut self,status:Status,peer_supported:bool,peer_requests_allowed:bool)->bool {
        if !self.authorized || self.disconnected || self.niko_voice_cleanup || status.cleanup_only
            || !peer_supported || !self.voice_status_matches(&status) {return false;}
        let valid=match self.niko_voice.as_ref() {
            None=>status.phase==Phase::Pending,
            Some(old) if old.identity==status.identity=>{
                old.wire==status.wire && newer_counter(&status.revision,&old.revision)
                    && newer_counter(&status.resource_epoch,&old.resource_epoch)
                    && (old.revision!=status.revision || old==&status)
                    && (old.phase!=Phase::Stopped || status.phase==Phase::Stopped)
            },
            Some(old)=>old.phase==Phase::Stopped && status.phase==Phase::Pending
                && old.identity.namespace==status.identity.namespace && old.identity.connection_nonce==status.identity.connection_nonce
                && old.identity.request_nonce!=status.identity.request_nonce
                && status.wire.call_epoch.parse::<u64>().ok()>old.wire.call_epoch.parse::<u64>().ok(),
        };
        if !valid {return false;}
        self.niko_voice_prepare_error=None;
        self.niko_voice_prepare_deadline=None;
        if self.niko_voice.as_ref().is_some_and(|old|old.revision!=status.revision || old.identity!=status.identity) {self.niko_voice_catalog=None;}
        self.niko_voice=Some(status);
        self.niko_voice_peer_supported=peer_supported;
        self.niko_voice_peer_requests_allowed=peer_requests_allowed;
        true
    }
    fn apply_voice_cleanup(&mut self,status:Status,retiring:bool)->bool {
        let Some(old)=self.niko_voice.as_ref() else {return false;};
        if !self.voice_status_matches(&status) || old.identity!=status.identity || old.wire!=status.wire
            || !status.cleanup_only || !matches!(status.phase,Phase::Revoking|Phase::RecoveryRequired|Phase::Stopped)
            || !newer_counter(&status.revision,&old.revision) || status.revision==old.revision
            || !newer_counter(&status.resource_epoch,&old.resource_epoch)
            || old.phase==Phase::Stopped && status.phase!=Phase::Stopped
            || if retiring {self.niko_voice_cleanup || self.disconnected || !self.authorized}
               else {!self.niko_voice_cleanup || !self.disconnected || self.authorized}
        {return false;}
        self.niko_voice_cleanup=true;
        self.authorized=false;
        self.disconnected=true;
        self.niko_voice_catalog=None;
        self.niko_voice=Some(status);
        true
    }
}

impl<T:InvokeUiCM> IpcTaskRunner<T> {
    pub(super) fn handle_nikodesk_voice_data(&mut self,data:Data) {
        let mut retiring=false;
        let snapshot=CLIENTS.write().ok().and_then(|mut clients| {
            let client=clients.get_mut(&self.conn_id)?;
            let accepted=match &data {
                Data::NikoVoiceReady {context,peer_requests_allowed}=>{
                    let accepted=client.authorized && !client.disconnected && !client.niko_voice_cleanup
                        && client.voice_desktop() && context.valid() && context.connection_id==client.id
                        && context.peer_id==client.peer_id
                        && client.niko_voice_context.as_ref().is_none_or(|old|old==context);
                    if accepted {
                        client.niko_voice_context=Some(context.clone());
                        client.niko_voice_peer_supported=true;
                        client.niko_voice_peer_requests_allowed=*peer_requests_allowed;
                    }
                    accepted
                },
                Data::NikoVoicePrepareError {context,expires_at_ms,reason}=>{
                    let accepted=client.authorized && !client.disconnected && !client.niko_voice_cleanup
                        && client.niko_voice_context.as_ref()==Some(context)
                        && client.niko_voice_prepare_deadline==Some(*expires_at_ms)
                        && !reason.is_empty() && reason.len()<=96 && reason.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b==b'_');
                    if accepted {client.niko_voice_prepare_error=Some(reason.clone());}
                    accepted
                },
                Data::NikoVoiceStatus {status,peer_supported,peer_requests_allowed}=>client.apply_voice_status(status.clone(),*peer_supported,*peer_requests_allowed),
                Data::NikoVoiceRetired(status)=>{retiring=true;client.apply_voice_cleanup(status.clone(),true)},
                Data::NikoVoiceCleanupStatus(status)=>{retiring=true;client.apply_voice_cleanup(status.clone(),false)},
                Data::NikoVoiceCatalog(catalog)=>{
                    let accepted=client.authorized && !client.disconnected && !client.niko_voice_cleanup
                        && catalog.validate().is_ok() && client.niko_voice.as_ref().is_some_and(|status|
                            status.phase==Phase::Pending && status.identity==catalog.identity && status.revision==catalog.revision);
                    if accepted {client.niko_voice_catalog=Some(catalog.clone());}
                    accepted
                },
                _=>false,
            };
            accepted.then(||client.clone())
        });
        let Some(client)=snapshot else {return;};
        if retiring {self.voice_cleanup_identity=client.niko_voice.as_ref().map(|status|status.identity.clone());self.close=false;}
        self.cm.ui_handler.add_connection(&client);
    }
}

#[cfg(any(target_os="macos",target_os="windows"))]
pub(crate) fn nikodesk_voice_command(json:String)->String {
    if let Some(request)=crate::nikodesk::voice_start::Prepare::parse(&json) {
        let result=(||->Result<(),&'static str> {
            let mut clients=CLIENTS.write().map_err(|_|"worker_failed")?;
            let client=clients.get_mut(&request.context.connection_id).ok_or("cm_connection_missing")?;
            if !request.live() || !client.authorized || client.disconnected || client.niko_voice_cleanup
                || !client.voice_desktop() || client.niko_voice_context.as_ref()!=Some(&request.context)
                || client.niko_voice.as_ref().is_some_and(|status|status.phase!=Phase::Stopped) {return Err("stale_command");}
            client.niko_voice_prepare_error=None;
            client.niko_voice_prepare_deadline=Some(request.expires_at_ms);
            if client.tx.send(Data::NikoVoicePrepare(request)).is_err() {
                client.niko_voice_prepare_deadline=None;
                return Err("cm_connection_channel_closed");
            }
            Ok(())
        })();
        return match result {
            Ok(())=>"{\"ok\":true,\"status\":\"queued\"}".into(),
            Err(reason)=>serde_json::json!({"ok":false,"status":"error","reason":reason}).to_string(),
        };
    }
    let command=match Command::parse(&json) {Ok(command)=>command,Err(reason)=>return serde_json::json!({"ok":false,"status":"error","reason":reason}).to_string()};
    let result=(||->Result<(), &'static str> {
        let clients=CLIENTS.read().map_err(|_|"worker_failed")?;
        let client=clients.get(&command.identity.connection_id).ok_or("cm_connection_missing")?;
        let status=client.niko_voice.as_ref().ok_or("stale_command")?;
        if !client.voice_desktop() || client.peer_id!=command.identity.peer_id || status.identity!=command.identity || status.revision!=command.revision {return Err("stale_command");}
        if client.niko_voice_cleanup {
            if client.authorized || !client.disconnected || !matches!(command.op,Operation::Query|Operation::RetryCleanup) {return Err("cleanup_pending");}
        } else if !client.authorized || client.disconnected {return Err("stale_command");}
        client.tx.send(Data::NikoVoiceCommand(command.clone())).map_err(|_|"cm_connection_channel_closed")
    })();
    match result {
        Ok(())=>serde_json::to_string(&voice_flow::Reply::queued(&command)).unwrap_or_else(|_|"{\"ok\":false,\"status\":\"error\",\"reason\":\"worker_failed\"}".into()),
        Err(reason)=>serde_json::json!({"ok":false,"status":"error","identity":command.identity,"revision":command.revision,"reason":reason}).to_string(),
    }
}

#[cfg(any(target_os="macos",target_os="windows"))]
pub(crate) async fn nikodesk_voice_availability(json_identity:String)->String {
    let disabled=|reason:&str|serde_json::json!({"supported":false,"requests_allowed":false,"peer_supported":false,"peer_requests_allowed":false,"reason":reason}).to_string();
    if json_identity.len()>4096 {return disabled("invalid_command");}
    if let Some(context)=crate::nikodesk::voice_start::Context::parse(&json_identity) {
        let anchor=||CLIENTS.read().ok().and_then(|clients|clients.get(&context.connection_id)
            .filter(|client|client.authorized && !client.disconnected && !client.niko_voice_cleanup
                && client.voice_desktop() && client.niko_voice_context.as_ref()==Some(&context))
            .map(|client|(client.niko_voice_peer_supported,client.niko_voice_peer_requests_allowed)));
        let Some(peer)=anchor() else {return disabled("stale_command");};
        let namespace=context.namespace.clone();
        let local=tokio::task::spawn_blocking(move||crate::nikodesk::voice_runtime::availability(&namespace)).await.unwrap_or(Err("worker_failed"));
        if anchor()!=Some(peer) {return disabled("stale_command");}
        let reason=match local {Err(reason)=>reason,Ok(()) if !peer.0=>"peer_unsupported",Ok(()) if !peer.1=>"peer_policy_disabled",Ok(())=>"available"};
        return serde_json::json!({"supported":local.is_ok() || matches!(local,Err("policy_disabled")),"requests_allowed":local.is_ok(),
            "peer_supported":peer.0,"peer_requests_allowed":peer.1,"reason":reason}).to_string();
    }
    let identity=match serde_json::from_str::<Identity>(&json_identity) {Ok(identity) if identity.valid()=>identity,_=>return disabled("invalid_command")};
    let anchor=||CLIENTS.read().ok().and_then(|clients|clients.get(&identity.connection_id).filter(|client|
        client.authorized && !client.disconnected && !client.niko_voice_cleanup && client.voice_desktop()
        && client.peer_id==identity.peer_id && client.niko_voice.as_ref().is_some_and(|status|status.identity==identity))
        .map(|client|(client.niko_voice_peer_supported,client.niko_voice_peer_requests_allowed)));
    let Some(peer)=anchor() else {return disabled("stale_command");};
    let namespace=identity.namespace.clone();
    let local=tokio::task::spawn_blocking(move||crate::nikodesk::voice_runtime::availability(&namespace)).await.unwrap_or(Err("worker_failed"));
    if anchor()!=Some(peer) {return disabled("stale_command");}
    serde_json::json!({"supported":local.is_ok() || matches!(local,Err("policy_disabled")),"requests_allowed":local.is_ok(),
        "peer_supported":peer.0,"peer_requests_allowed":peer.1,"reason":local.err().unwrap_or("available")}).to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    fn client_and_status()->(Client,Status) {
        let identity=Identity {connection_id:7,namespace:"a".repeat(64),peer_id:"123456789".into(),
            connection_nonce:"1".repeat(32),request_nonce:"2".repeat(32),epoch:"1".into()};
        let camera_identity=crate::nikodesk::connection_capabilities::Identity {
            connection_id:identity.connection_id,namespace:identity.namespace.clone(),peer_id:identity.peer_id.clone(),
            connection_nonce:identity.connection_nonce.clone(),request_nonce:identity.request_nonce.clone(),epoch:identity.epoch.clone()};
        let camera=crate::nikodesk::camera_flow::Status {identity:camera_identity,kind:"camera".into(),phase:"Pending".into(),
            reason:"pending_local_approval".into(),revision:"1".into(),resource_epoch:"1".into(),selection:None};
        let mut client=Client::camera_cleanup_fixture(camera);
        client.is_view_camera=false;
        client.niko_camera=None;
        let status=Status::pending(identity,voice_flow::Wire{call_nonce:"3".repeat(32),call_epoch:"4".into()}).unwrap();
        (client,status)
    }
    #[test]
    fn voice_anchor_requires_actual_desktop_login_and_exact_current_call() {
        let (mut client,status)=client_and_status();
        client.authorized=false;
        assert!(!client.apply_voice_status(status.clone(),true,false));
        client.authorized=true;
        client.is_terminal=true;
        assert!(!client.apply_voice_status(status.clone(),true,false));
        client.is_terminal=false;
        assert!(!client.apply_voice_status(status.clone(),false,true));
        assert!(client.apply_voice_status(status.clone(),true,false));
        let mut late=status.clone();
        late.identity.connection_nonce="5".repeat(32);
        late.advance(Phase::Pending,"pending_local_approval").unwrap();
        assert!(!client.apply_voice_status(late,true,false));
        let mut changed=status;
        changed.wire.call_nonce="6".repeat(32);
        changed.advance(Phase::Pending,"pending_local_approval").unwrap();
        assert!(!client.apply_voice_status(changed,true,false));
    }
    #[test]
    fn retired_call_only_allows_query_and_retry_until_actual_stop() {
        let (mut client,mut status)=client_and_status();
        assert!(client.apply_voice_status(status.clone(),true,false));
        status.cleanup_only=true;
        status.advance(Phase::Revoking,"cleanup_pending").unwrap();
        assert!(client.apply_voice_cleanup(status.clone(),true));
        assert!(client.disconnected && !client.authorized && client.niko_voice_cleanup);
        assert!(!client.accepts_cleanup_dispatch(&Data::Authorize));
        assert!(!client.accepts_cleanup_dispatch(&Data::Close));
        let mut command:Command=serde_json::from_value(serde_json::json!({"identity":status.identity,
            "revision":status.revision,"op":"query"})).unwrap();
        assert!(client.accepts_cleanup_dispatch(&Data::NikoVoiceCommand(command.clone())));
        command.op=Operation::Unmute;
        assert!(!client.accepts_cleanup_dispatch(&Data::NikoVoiceCommand(command)));
        let mut wrong=status.clone();
        wrong.identity.request_nonce="7".repeat(32);
        wrong.advance(Phase::Stopped,"stopped").unwrap();
        assert!(!client.apply_voice_cleanup(wrong,false));
        status.advance(Phase::Stopped,"stopped").unwrap();
        assert!(client.apply_voice_cleanup(status,false));
        assert!(client.accepts_cleanup_dispatch(&Data::Close));
    }
    #[test]
    fn next_call_requires_prior_stop_and_higher_wire_epoch_on_original_connection() {
        let (mut client,mut status)=client_and_status();
        assert!(client.apply_voice_status(status.clone(),true,false));
        let mut next=status.clone();
        next.identity.request_nonce="8".repeat(32);
        next.wire.call_nonce="9".repeat(32);
        next.wire.call_epoch="5".into();
        assert!(!client.apply_voice_status(next.clone(),true,false));
        status.advance(Phase::Stopped,"stopped").unwrap();
        assert!(client.apply_voice_status(status,true,false));
        let mut replay=next.clone();
        replay.wire.call_epoch="4".into();
        assert!(!client.apply_voice_status(replay,true,false));
        assert!(client.apply_voice_status(next,true,false));
    }
}
