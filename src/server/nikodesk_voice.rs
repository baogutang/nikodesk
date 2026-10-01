use super::*;
use crate::nikodesk::{
    voice_call::{self, Call, Event},
    voice_flow::{Command, Identity, Operation, Phase},
    voice_runtime::AuthFacts,
    voice_wire,
};
use std::sync::atomic::{AtomicBool, Ordering};

impl Connection {
    fn outgoing_voice_context(&self)->Option<crate::nikodesk::voice_start::Context> {
        if !self.voice_role() || !self.lr.nikodesk_features.as_ref().is_some_and(|peer|peer.nikodesk_voice_reverse_v1 && peer.nikodesk_voice_v1) {return None;}
        let context=crate::nikodesk::voice_start::Context {schema:1,connection_id:self.inner.id(),
            namespace:self.niko_voice_namespace.clone()?,peer_id:self.lr.my_id.clone(),connection_nonce:self.niko_voice_nonce.clone()?};
        context.valid().then_some(context)
    }
    pub(super) fn publish_nikodesk_voice_ready(&mut self) {
        let Some(context)=self.outgoing_voice_context() else {return;};
        let allowed=self.lr.nikodesk_features.as_ref().is_some_and(|peer|peer.nikodesk_voice_requests_allowed);
        if self.niko_voice_ready_sent==Some(allowed) {return;}
        if self.tx_to_cm.send(Data::NikoVoiceReady {context,peer_requests_allowed:allowed}).is_ok() {self.niko_voice_ready_sent=Some(allowed);}
    }
    pub(super) async fn prepare_nikodesk_outgoing_voice(&mut self,request:crate::nikodesk::voice_start::Prepare) {
        let context=request.context.clone();
        let result=self.start_nikodesk_outgoing_voice(&request).await;
        if let Err(reason)=result {self.send_to_cm(Data::NikoVoicePrepareError {context,expires_at_ms:request.expires_at_ms,reason:reason.into()});}
    }
    async fn start_nikodesk_outgoing_voice(&mut self,request:&crate::nikodesk::voice_start::Prepare)->Result<(),&'static str> {
        if !request.live() || self.outgoing_voice_context().as_ref()!=Some(&request.context) {return Err("stale_command");}
        if self.niko_voice_retiring.load(Ordering::Acquire) {return Err("cleanup_pending");}
        let previous=if let Some(call)=self.niko_voice.as_mut() {
            if !matches!(call.finished(),Ok(true)) {return Err("busy");}
            call.status().wire.call_epoch.parse::<u64>().map_err(|_|"worker_failed")?
        } else {0};
        let namespace=request.context.namespace.clone();
        tokio::task::spawn_blocking(move||crate::nikodesk::voice_runtime::availability(&namespace)).await.map_err(|_|"worker_failed")??;
        if !request.live() || self.outgoing_voice_context().as_ref()!=Some(&request.context) {return Err("stale_command");}
        let peer=self.lr.nikodesk_features.as_ref().cloned().ok_or("peer_unsupported")?;
        let identity=Identity {connection_id:self.inner.id(),namespace:request.context.namespace.clone(),
            peer_id:request.context.peer_id.clone(),connection_nonce:request.context.connection_nonce.clone(),
            request_nonce:voice_call::nonce()?,epoch:"1".into()};
        let wire=voice_call::new_wire_after(previous)?;
        let sender=self.tx_to_cm.clone();
        let retiring=self.niko_voice_retiring.clone();
        let retirement_sent=Arc::new(AtomicBool::new(false));
        let peer_requests_allowed=peer.nikodesk_voice_requests_allowed;
        let observer=Arc::new(move|event| {
            let data=match event {
                Event::Status(status) if retiring.load(Ordering::Acquire) && status.cleanup_only=>{
                    if retirement_sent.swap(true,Ordering::AcqRel) {Data::NikoVoiceCleanupStatus(status)} else {Data::NikoVoiceRetired(status)}
                },
                Event::Status(status)=>Data::NikoVoiceStatus {status,peer_supported:true,peer_requests_allowed},
                Event::Catalog(catalog)=>Data::NikoVoiceCatalog(catalog),
            };
            let _=sender.send(data);
        });
        let facts=AuthFacts {encrypted:self.stream.is_secured(),peer_authenticated:self.authorized,
            totp_required:self.niko_voice_totp_required,totp_verified_current:self.niko_voice_totp_verified};
        let observer=crate::nikodesk::capability_audit::voice_observer(observer,self.niko_audit.as_ref().map(|audit|audit.capability_context()));
        self.niko_voice=Some(Call::outgoing(identity,wire,peer,facts,observer)?);
        Ok(())
    }
    pub(super) fn voice_role(&self)->bool {
        self.authorized && !self.closed && self.stream.is_secured()
            && self.authed_conn_type()==Some(AuthConnType::Remote)
            && !crate::nikodesk::background::is_system_worker()
            && (!self.niko_voice_totp_required || self.niko_voice_totp_verified)
    }
    pub(super) async fn populate_nikodesk_voice_features(&self,pi:&mut PeerInfo) {
        if !self.voice_role() {return;}
        let Some(namespace)=self.niko_voice_namespace.clone() else {return;};
        let available=tokio::task::spawn_blocking(move||crate::nikodesk::voice_runtime::availability(&namespace))
            .await.unwrap_or(Err("worker_failed"));
        if let Some(features)=pi.features.as_mut() {
            crate::nikodesk::voice_policy::advertise(features,available.is_ok());
        }
    }
    pub(super) async fn handle_nikodesk_voice_message(&mut self,message:&Message) {
        if !self.voice_role() {return;}
        let Some(peer)=self.lr.nikodesk_features.as_ref().cloned() else {return;};
        if !peer.nikodesk_voice_v1 {return;}
        if let Some(message::Union::VoiceCallRequest(request))=message.union.as_ref() {
            if request.is_connect {
                if let Some(call)=self.niko_voice.as_mut() {
                    if !matches!(call.finished(),Ok(true)) {return;}
                }
                let Ok(binding)=self.niko_voice_fence.accept(&peer,request) else {return;};
                let Some(namespace)=self.niko_voice_namespace.clone() else {return;};
                let check_namespace=namespace.clone();
                if !matches!(tokio::task::spawn_blocking(move||crate::nikodesk::voice_runtime::availability(&check_namespace)).await,Ok(Ok(()))) {return;}
                let Some(connection_nonce)=self.niko_voice_nonce.clone() else {return;};
                let Ok(request_nonce)=voice_call::nonce() else {return;};
                let identity=Identity {connection_id:self.inner.id(),namespace,peer_id:self.lr.my_id.clone(),connection_nonce,request_nonce,epoch:"1".into()};
                let sender=self.tx_to_cm.clone();
                let retiring=self.niko_voice_retiring.clone();
                let retirement_sent=Arc::new(AtomicBool::new(false));
                let peer_supported=peer.nikodesk_voice_v1;
                let peer_requests_allowed=peer.nikodesk_voice_requests_allowed;
                let observer=Arc::new(move |event| {
                    let data=match event {
                        Event::Status(status)=>{
                            if retiring.load(Ordering::Acquire) && status.cleanup_only {
                                if !matches!(status.phase,Phase::Revoking|Phase::RecoveryRequired|Phase::Stopped) {return;}
                                if retirement_sent.swap(true,Ordering::AcqRel) {Data::NikoVoiceCleanupStatus(status)}
                                else {Data::NikoVoiceRetired(status)}
                            } else {Data::NikoVoiceStatus {status,peer_supported,peer_requests_allowed}}
                        },
                        Event::Catalog(catalog)=>Data::NikoVoiceCatalog(catalog),
                    };
                    let _=sender.send(data);
                });
                let facts=AuthFacts {encrypted:self.stream.is_secured(),peer_authenticated:self.authorized,
                    totp_required:self.niko_voice_totp_required,totp_verified_current:self.niko_voice_totp_verified};
                let observer=crate::nikodesk::capability_audit::voice_observer(observer,self.niko_audit.as_ref().map(|audit|audit.capability_context()));
                if let Ok(call)=Call::incoming(identity,binding,peer,request.clone(),facts,observer) {self.niko_voice=Some(call);}
                return;
            }
        }
        if let Some(call)=self.niko_voice.as_mut() {call.incoming_message(message);}
    }
    pub(super) fn handle_nikodesk_voice_command(&mut self,command:Command) {
        if !self.voice_role() {return;}
        if let Some(call)=self.niko_voice.as_mut() {let _=call.command(command);}
    }
    pub(super) async fn poll_nikodesk_voice(&mut self) {
        let Some(call)=self.niko_voice.as_mut() else {return;};
        let messages=match call.poll() {Ok(messages)=>messages,Err(_)=>{call.cancel();return;}};
        let mut pending=messages.into();
        while let Some(message)=call.next_send(&mut pending) {
            if !matches!(tokio::time::timeout(Duration::from_millis(500),self.stream.send(&message)).await,Ok(Ok(()))) {call.cancel();break;}
        }
    }
    pub(super) fn retire_nikodesk_voice(&mut self) {
        if let Some(call)=self.niko_voice.as_mut() {
            if !matches!(call.finished(),Ok(true)) {
                self.niko_voice_retiring.store(true,Ordering::Release);
                call.retire();
            }
        }
    }
}

pub(super) async fn retired_cleanup(mut call:Call,mut receiver:mpsc::UnboundedReceiver<Data>,sender:mpsc::UnboundedSender<Data>) {
    let mut timer=time::interval(Duration::from_millis(20));
    let mut original_channel_open=true;
    loop {
        tokio::select! {
            command=receiver.recv(),if original_channel_open=>{
                match command {
                    Some(Data::NikoVoiceCommand(command)) if matches!(command.op,Operation::Query|Operation::RetryCleanup)=>{let _=call.command(command);},
                    Some(_)=>{},
                    None=>original_channel_open=false,
                }
            }
            _=timer.tick()=>{
                // No network send and no replacement CM channel after retirement.
                let _=call.poll();
                if matches!(call.finished(),Ok(true)) {let _=sender.send(Data::Close);break;}
            }
        }
    }
}
