//! A CM preparation request is scoped to the actual authenticated connection.
//! It creates a pending local call; it never grants a microphone or starts media.
use super::voice_flow;
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Context {
    pub schema: u32,
    pub connection_id: i32,
    pub namespace: String,
    pub peer_id: String,
    pub connection_nonce: String,
}
impl Context {
    pub(crate) fn valid(&self) -> bool {
        self.schema == 1 && self.connection_id > 0
            && voice_flow::hex(&self.namespace, 64, false)
            && voice_flow::hex(&self.connection_nonce, 32, true)
            && super::validate_remote_id(&self.peer_id).is_ok()
    }
    pub(crate) fn parse(json: &str) -> Option<Self> {
        if json.len() > 1024 { return None; }
        serde_json::from_str::<Self>(json).ok().filter(Self::valid)
    }
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Prepare {
    pub op: String,
    pub context: Context,
    pub expires_at_ms: u64,
}
impl Prepare {
    pub(crate) fn parse(json: &str) -> Option<Self> {
        if json.len() > 1536 { return None; }
        serde_json::from_str::<Self>(json).ok().filter(|request| request.live())
    }
    pub(crate) fn live(&self) -> bool {
        let Some(now) = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH)
            .ok().and_then(|now| u64::try_from(now.as_millis()).ok()) else { return false; };
        self.op == "prepare" && self.context.valid()
            && self.expires_at_ms.checked_sub(now).is_some_and(|remaining| remaining > 0 && remaining <= 5000)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn reverse_preparation_cannot_substitute_a_call_grant_or_outlive_its_deadline() {
        let context = Context { schema: 1, connection_id: 9, namespace: "a".repeat(64),
            peer_id: "123456789".into(), connection_nonce: "1".repeat(32) };
        let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_millis() as u64;
        let mut request = serde_json::to_value(Prepare { op: "prepare".into(), context, expires_at_ms: now + 4000 }).unwrap();
        assert!(Prepare::parse(&request.to_string()).is_some());
        request["approve"] = true.into();
        assert!(Prepare::parse(&request.to_string()).is_none());
        request.as_object_mut().unwrap().remove("approve");
        request["expires_at_ms"] = now.into();
        assert!(Prepare::parse(&request.to_string()).is_none());
        request["expires_at_ms"] = (now + 30000).into();
        assert!(Prepare::parse(&request.to_string()).is_none());
        request["expires_at_ms"] = (now + 4000).into();
        request["context"]["connection_nonce"] = "0".repeat(32).into();
        assert!(Prepare::parse(&request.to_string()).is_none());
    }
}
