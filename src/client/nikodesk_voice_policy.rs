use super::*;

impl<T: InvokeUiSession> Remote<T> {
    pub(super) fn handle_nikodesk_voice_policy(&mut self, message: &Message, peer: &Stream) -> bool {
        let Some(policy) = crate::nikodesk::voice_policy::extract(message) else { return false; };
        let current = self.is_connected && self.handler.is_default() && peer.is_secured()
            && self.niko_voice.is_some();
        if crate::nikodesk::voice_policy::apply(self.peer_info.niko_voice_features.as_mut(), policy, current) {
            if let Some(call)=self.niko_voice.as_mut().and_then(|voice|voice.call.as_mut()) {call.peer_requests_policy(policy.requests_allowed);}
        }
        true
    }
}
