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
    #[serde(default)]
    pub inf_path: String,
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
        match value.action.as_str() {
            "status" | "probe" if value.inf_path.is_empty() => Some(value),
            "install"
                if value.inf_path.len() < 260
                    && value.inf_path.as_bytes().get(1) == Some(&b':')
                    && value
                        .inf_path
                        .as_bytes()
                        .get(2)
                        .is_some_and(|b| *b == b'\\' || *b == b'/')
                    && value
                        .inf_path
                        .as_bytes()
                        .first()
                        .is_some_and(u8::is_ascii_alphabetic)
                    && !value.inf_path.chars().any(char::is_control)
                    && value.inf_path.replace('\\', "/").rsplit('/').next()
                        == Some("NikoDeskIddDriver.inf") =>
            {
                Some(value)
            }
            _ => None,
        }
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
    fn driver_requests_cannot_select_foreign_packages_or_supply_approval() {
        let mut raw = serde_json::json!({"action":"install", "namespace":"a".repeat(64),
            "inf_path":"C:\\selected\\NikoDeskIddDriver.inf"});
        assert!(Request::parse(&raw.to_string()).is_some());
        for path in [
            "C:\\RustDeskIddDriver.inf",
            "\\\\nas\\public\\NikoDeskIddDriver.inf",
            "C:NikoDeskIddDriver.inf",
            "C:\\selected\\NikoDeskIddDriver.inf\n",
        ] {
            raw["inf_path"] = path.into();
            assert!(Request::parse(&raw.to_string()).is_none());
        }
        raw["inf_path"] = "C:\\selected\\NikoDeskIddDriver.inf".into();
        raw["approved"] = true.into();
        assert!(Request::parse(&raw.to_string()).is_none());
    }
    #[test]
    fn probes_and_status_have_no_installation_payload() {
        let mut raw = serde_json::json!({"action":"probe", "namespace":"a".repeat(64)});
        assert!(Request::parse(&raw.to_string()).is_some());
        raw["inf_path"] = "C:\\selected\\NikoDeskIddDriver.inf".into();
        assert!(Request::parse(&raw.to_string()).is_none());
        raw["inf_path"] = "".into();
        raw["namespace"] = "0".repeat(64).into();
        assert!(Request::parse(&raw.to_string()).is_none());
    }
}
