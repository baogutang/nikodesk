use super::*;
use crate::nikodesk::{
    voice_call::{self, Call},
    voice_session::{self, Availability, Input, Request},
    voice_runtime::AuthFacts,
};

impl<T:InvokeUiSession> Remote<T> {
    pub(super) async fn handle_nikodesk_voice_ui(&mut self,request:Request,peer:&mut Stream) {
        if !request.live() {return;}
        let Some(session)=crate::flutter::sessions::get_session_by_session_id(&request.session_id) else {request.error("session_closed");return;};
        if !Arc::ptr_eq(&session.lc,&self.handler.lc) {request.error("context_unsupported");return;}
        if !self.handler.is_default() || !self.is_connected || !peer.is_secured() {request.error("authentication_required");return;}
        let Some(voice)=self.niko_voice.as_mut() else {request.error("context_unsupported");return;};
        if voice.round!=request.round || voice.namespace!=request.namespace {request.error("stale_command");return;}
        match request.input.clone() {
            Input::Availability=>{
                let peer_features=self.peer_info.niko_voice_features.as_ref();
                let local=voice_session::local_availability(voice.namespace.clone()).await;
                let supported=local.is_ok() || matches!(local,Err("policy_disabled"));
                let peer_supported=peer_features.is_some_and(|features|features.nikodesk_voice_v1);
                let peer_requests_allowed=peer_features.is_some_and(|features|features.nikodesk_voice_requests_allowed);
                let incoming=voice.incoming && voice.call.as_ref().is_some_and(|call|call.status().phase!=crate::nikodesk::voice_flow::Phase::Stopped);
                let reason=match local {Err(reason)=>reason,Ok(()) if !peer_supported=>"peer_unsupported",Ok(()) if !peer_requests_allowed && !incoming=>"peer_policy_disabled",Ok(())=>"available"};
                request.complete(Availability {supported,requests_allowed:local.is_ok(),peer_supported,peer_requests_allowed,reason:reason.into()}.json());
            }
            Input::Prepare=>{
                if let Err(reason)=voice_session::local_availability(voice.namespace.clone()).await {request.error(reason);return;}
                if !request.live() {return;}
                if let Some(call)=voice.call.as_mut() {
                    if !matches!(call.finished(),Ok(true)) {request.error("busy");return;}
                }
                let Some(features)=self.peer_info.niko_voice_features.as_ref().cloned() else {request.error("peer_unsupported");return;};
                let identity=match voice.identity() {Ok(identity)=>identity,Err(reason)=>{request.error(reason);return;}};
                let previous=voice.call.as_ref().and_then(|call|call.status().wire.call_epoch.parse::<u64>().ok()).unwrap_or(0);
                let wire=match voice_call::new_wire_after(previous) {Ok(wire)=>wire,Err(reason)=>{request.error(reason);return;}};
                let observer=voice_session::session_observer(request.session_id,session.ui_handler.clone());
                let observer=crate::nikodesk::capability_audit::voice_observer(observer,voice.audit.clone());
                let facts=AuthFacts {encrypted:peer.is_secured(),peer_authenticated:self.is_connected,totp_required:false,totp_verified_current:false};
                match Call::outgoing(identity,wire,features,facts,observer) {
                    Ok(call)=>{voice.owner=Some(request.session_id);voice.incoming=false;voice.call=Some(call);request.complete("{\"ok\":true,\"status\":\"queued\"}".into());},
                    Err(reason)=>request.error(reason),
                }
            }
            Input::Command(command)=>{
                if voice.owner!=Some(request.session_id) {request.error("stale_command");return;}
                let Some(call)=voice.call.as_mut() else {request.error("session_closed");return;};
                match call.command(command) {
                    Ok(reply)=>match serde_json::to_string(&reply) {Ok(json)=>request.complete(json),Err(_)=>request.error("worker_failed")},
                    Err(reason)=>request.error(reason),
                }
            }
        }
    }

    pub(super) async fn handle_nikodesk_incoming_voice(&mut self,message:&Message,peer:&mut Stream) {
        if !self.handler.is_default() || !self.is_connected || !peer.is_secured() {return;}
        let Some(features)=self.peer_info.niko_voice_features.as_ref().cloned() else {return;};
        if !features.nikodesk_voice_v1 {return;}
        if let Some(message::Union::VoiceCallRequest(request))=message.union.as_ref() {
            if request.is_connect {
                let Some(voice)=self.niko_voice.as_mut() else {return;};
                let Ok(binding)=voice.incoming_fence.accept(&features,request) else {return;};
                let available=voice_session::local_availability(voice.namespace.clone()).await.is_ok();
                let busy=voice.call.as_mut().is_some_and(|call|!matches!(call.finished(),Ok(true)));
                let owner=crate::flutter::sessions::nikodesk_voice_ui_owner(&self.handler.lc);
                if !available || busy || owner.is_none() {
                    if let Ok(response)=crate::nikodesk::voice_wire::response(&features,binding,request,false,hbb_common::get_time()) {
                        let mut message=Message::new();message.set_voice_call_response(response);
                        let _=tokio::time::timeout(Duration::from_millis(500),peer.send(&message)).await;
                    }
                    return;
                }
                let Some((session_id,ui))=owner else {return;};
                let Ok(identity)=voice.identity() else {return;};
                let facts=AuthFacts {encrypted:peer.is_secured(),peer_authenticated:self.is_connected,totp_required:false,totp_verified_current:false};
                let observer=voice_session::incoming_observer(session_id,ui);
                let observer=crate::nikodesk::capability_audit::voice_observer(observer,voice.audit.clone());
                match Call::incoming(identity,binding,features,request.clone(),facts,observer) {
                    Ok(call)=>{voice.owner=Some(session_id);voice.incoming=true;voice.call=Some(call);},
                    Err(_)=>{},
                }
                return;
            }
        }
        if let Some(call)=self.niko_voice.as_mut().and_then(|voice|voice.call.as_mut()) {call.incoming_message(message);}
    }

    pub(super) async fn poll_nikodesk_voice(&mut self,peer:&mut Stream) {
        let Some(call)=self.niko_voice.as_mut().and_then(|voice|voice.call.as_mut()) else {return;};
        let messages=match call.poll() {Ok(messages)=>messages,Err(_)=>{call.cancel();return;}};
        let mut pending=messages.into();
        while let Some(message)=call.next_send(&mut pending) {
            if !matches!(tokio::time::timeout(Duration::from_millis(500),peer.send(&message)).await,Ok(Ok(()))) {call.cancel();break;}
        }
    }
}
