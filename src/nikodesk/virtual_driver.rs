//! Local driver jobs never accept approval through remote/session messages.
use serde::{Deserialize, Serialize};
#[cfg(windows)]
#[path = "virtual_driver/windows.rs"]
mod platform;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Request {
    pub action: String,
    pub namespace: String,
}
impl Request {
    fn parse(raw: &str) -> Option<Self> {
        if raw.len() > 8192 {
            return None;
        }
        let value: Self = serde_json::from_str(raw).ok()?;
        if value.namespace.len() != 64
            || !value
                .namespace
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
            || value.namespace.bytes().all(|b| b == b'0')
        {
            return None;
        }
        // The driver is the one bundled with this build; a request cannot name a package.
        matches!(value.action.as_str(), "status" | "probe" | "install").then_some(value)
    }
}
#[derive(Clone, Serialize)]
pub(super) struct Reply {
    pub ok: bool,
    pub namespace: String,
    pub job_id: String,
    pub phase: String,
    pub reason: String,
    pub elevated: bool,
    pub os_supported: bool,
    pub joined: bool,
}
impl Reply {
    fn empty(namespace: &str, reason: &str) -> Self {
        Self {
            ok: false,
            namespace: namespace.into(),
            job_id: String::new(),
            phase: "idle".into(),
            reason: reason.into(),
            elevated: false,
            os_supported: false,
            joined: false,
        }
    }
    fn json(&self) -> String {
        serde_json::to_string(self).unwrap_or_default()
    }
}
pub(crate) fn command(raw: &str) -> String {
    let Some(request) = Request::parse(raw) else {
        return Reply::empty("", "invalid_request").json();
    };
    #[cfg(windows)]
    {
        platform::command(request).json()
    }
    #[cfg(not(windows))]
    {
        Reply::empty(&request.namespace, "unsupported").json()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn driver_requests_cannot_name_a_package_or_supply_approval() {
        let mut raw = serde_json::json!({"action":"install", "namespace":"a".repeat(64)});
        assert!(Request::parse(&raw.to_string()).is_some());
        raw["inf_path"] = "C:\\selected\\usbmmIdd.inf".into();
        assert!(Request::parse(&raw.to_string()).is_none());
        let mut raw = serde_json::json!({"action":"install", "namespace":"a".repeat(64)});
        raw["approved"] = true.into();
        assert!(Request::parse(&raw.to_string()).is_none());
    }
    #[test]
    fn only_known_actions_in_a_real_server_scope_are_accepted() {
        let mut raw = serde_json::json!({"action":"probe", "namespace":"a".repeat(64)});
        assert!(Request::parse(&raw.to_string()).is_some());
        raw["action"] = "status".into();
        assert!(Request::parse(&raw.to_string()).is_some());
        raw["action"] = "uninstall".into();
        assert!(Request::parse(&raw.to_string()).is_none());
        raw["action"] = "probe".into();
        raw["namespace"] = "0".repeat(64).into();
        assert!(Request::parse(&raw.to_string()).is_none());
    }
}
