//! Ordinary local UI owns one explicit setup job; IPC and remote messages never grant it.
use hbb_common::{anyhow::{anyhow, bail, Result}, serde_derive::{Deserialize, Serialize}};

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct BeginRequest {
    #[serde(default)]
    action: super::background::install::policy::Action,
    expected_namespace: String,
    selected_setup: String,
    password: String,
    start_after_commit: bool,
    #[serde(default)]
    allow_virtual_display: bool,
    #[serde(default)]
    lock_on_disconnect: bool,
    #[serde(default)]
    allow_privacy: bool,
    #[serde(default)]
    allow_remote_restart: bool,
}
impl Drop for BeginRequest {
    fn drop(&mut self) {
        unsafe { hbb_common::sodiumoxide::utils::memzero(self.password.as_bytes_mut()); }
    }
}
struct SecretJson(String);
impl Drop for SecretJson {
    fn drop(&mut self) {
        unsafe { hbb_common::sodiumoxide::utils::memzero(self.0.as_bytes_mut()); }
    }
}
impl BeginRequest {
    fn parse(json: String) -> Result<Self> {
        let json = SecretJson(json);
        if json.0.is_empty() || json.0.len() > 16 * 1024 { bail!("invalid_request"); }
        let request: Self = serde_json::from_str(&json.0).map_err(|_| anyhow!("invalid_request"))?;
        if !namespace_valid(&request.expected_namespace)
            || request.selected_setup.is_empty() || request.selected_setup.len() > 4096
            || request.selected_setup.chars().any(char::is_control)
            || request.password.chars().count() > 128
            || (request.action.accepts_password() && request.password.trim().is_empty())
            || (!request.action.accepts_password() && !request.password.is_empty())
            || (!request.action.accepts_start() && request.start_after_commit)
            || (!request.action.accepts_session_policies() &&
                (request.allow_privacy || request.allow_remote_restart || request.allow_virtual_display || request.lock_on_disconnect))
        { bail!("invalid_request"); }
        Ok(request)
    }
}
fn namespace_valid(value: &str) -> bool {
    value.len() == 64 && value.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
        && value.bytes().any(|b| b != b'0')
}
fn job_valid(value: &str) -> bool {
    hbb_common::uuid::Uuid::parse_str(value).is_ok_and(|id| !id.is_nil() && id.to_string() == value)
}

#[cfg(windows)]
pub(crate) fn dispatch(future: impl std::future::Future<Output = String> + Send + 'static) -> String {
    use hbb_common::tokio;
    // FRB1 runs a normal call on its worker pool. It must never block a Tokio worker.
    if tokio::runtime::Handle::try_current().is_ok() {
        return Reply::empty(false, "unconfirmed").json();
    }
    let Some(runtime) = super::server_settings::flutter_runtime() else {
        return Reply::empty(false, "unconfirmed").json();
    };
    let (sender, receiver) = std::sync::mpsc::sync_channel(1);
    let task = runtime.spawn(async move {
        let result = future.await;
        let _ = sender.try_send(result);
    });
    // Observer timeout does not abort a setup task or discard its original owner.
    // The existing runtime owns this awaiter through the original operation join.
    runtime.spawn(async move {
        if task.await.is_err() { hbb_common::log::trace!("NikoDesk local install bridge task did not complete"); }
    });
    receiver.recv_timeout(std::time::Duration::from_secs(5))
        .unwrap_or_else(|_| Reply::empty(false, "unconfirmed").json())
}

#[derive(Clone, Serialize)]
struct Reply {
    action: super::background::install::policy::Action,
    ok: bool,
    job_id: String,
    namespace: String,
    phase: String,
    reason: String,
    quiescent: bool,
    process_exited: bool,
    task_joined: bool,
    machine_id: String,
}
impl Reply {
    fn empty(ok: bool, reason: &str) -> Self {
        Self { action: super::background::install::policy::Action::Install, ok, job_id: String::new(), namespace: String::new(), phase: "idle".into(),
            reason: reason.into(), quiescent: false, process_exited: false, task_joined: false, machine_id: String::new() }
    }
    fn json(&self) -> String {
        serde_json::to_string(self).unwrap_or_else(|_| {
            "{\"ok\":false,\"job_id\":\"\",\"namespace\":\"\",\"phase\":\"idle\",\"reason\":\"unconfirmed\",\"quiescent\":false,\"process_exited\":false,\"task_joined\":false}".into()
        })
    }
    fn terminal(&self) -> bool {
        self.ok && job_valid(&self.job_id) && namespace_valid(&self.namespace)
            && self.quiescent && self.process_exited && self.task_joined
            && matches!(self.phase.as_str(), "complete" | "launch_not_started" | "recovery_disabled" | "install_recovered")
            && (self.phase != "install_recovered" || (self.machine_id.is_empty()
                && matches!(self.action,super::background::install::policy::Action::Install|super::background::install::policy::Action::RecoverInstall)))
            && (self.phase != "complete" || (self.machine_id.len() == 10
                && !self.machine_id.starts_with('0') && self.machine_id.bytes().all(|b| b.is_ascii_digit())))
    }
}

pub(crate) async fn begin(json: String) -> String {
    let request = match BeginRequest::parse(json) {
        Ok(request) => request,
        Err(_) => return Reply::empty(false, "invalid_request").json(),
    };
    #[cfg(windows)]
    { return native::begin(request).await; }
    #[cfg(not(windows))]
    { let _ = request; Reply::empty(false, "unsupported").json() }
}
pub(crate) async fn status(job_id: String) -> String {
    if !job_valid(&job_id) { return Reply::empty(false, "invalid_request").json(); }
    #[cfg(windows)]
    { return native::query(Some(&job_id)).await.json(); }
    #[cfg(not(windows))]
    { Reply::empty(false, "unsupported").json() }
}
pub(crate) async fn current() -> String {
    #[cfg(windows)]
    { return native::query(None).await.json(); }
    #[cfg(not(windows))]
    { Reply::empty(false, "unsupported").json() }
}
pub(crate) async fn cancel(job_id: String) -> String {
    if !job_valid(&job_id) { return Reply::empty(false, "invalid_request").json(); }
    #[cfg(windows)]
    { return native::cancel(&job_id).await.json(); }
    #[cfg(not(windows))]
    { Reply::empty(false, "unsupported").json() }
}

#[cfg(windows)]
#[path = "unattended_install_windows.rs"]
mod native;

#[cfg(test)]
mod tests {
    use super::*;
    fn request() -> serde_json::Value {
        serde_json::json!({"expected_namespace":"a".repeat(64),"selected_setup":"C:\\fixture\\nikodesk-setup.exe",
            "password":"fixture-user-entry","start_after_commit":false})
    }
    #[test]
    fn request_cannot_supply_installation_or_cleanup_authority() {
        assert!(BeginRequest::parse(request().to_string()).is_ok());
        for field in ["approved", "quiescent", "task_joined", "job_id", "machine_identity"] {
            let mut value = request(); value[field] = true.into();
            assert!(BeginRequest::parse(value.to_string()).is_err());
        }
        for value in ["0".repeat(64), "A".repeat(64), "a".repeat(63)] {
            let mut json = request(); json["expected_namespace"] = value.into();
            assert!(BeginRequest::parse(json.to_string()).is_err());
        }
        let mut json = request(); json["password"] = " ".into();
        assert!(BeginRequest::parse(json.to_string()).is_err());
    }
    #[test]
    fn password_rotation_requires_a_new_secret_without_granting_other_machine_permissions() {
        let mut value = request(); value["action"] = "change_password".into();
        assert!(BeginRequest::parse(value.to_string()).is_ok());
        value["start_after_commit"] = true.into();
        assert!(BeginRequest::parse(value.to_string()).is_ok());
        for field in ["allow_virtual_display", "lock_on_disconnect", "allow_privacy", "allow_remote_restart"] {
            let mut extra = value.clone(); extra[field] = true.into();
            assert!(BeginRequest::parse(extra.to_string()).is_err());
        }
        for password in ["", " "] {
            value["password"] = password.into();
            assert!(BeginRequest::parse(value.to_string()).is_err());
        }
        value["password"] = "new-fixture-secret".into();
        value["start_after_commit"] = false.into();
        value["action"] = "configure".into();
        assert!(BeginRequest::parse(value.to_string()).is_err());
    }
    #[test]
    fn queued_cancel_and_idle_never_prove_installed_or_clear_owned_resources() {
        let mut reply = Reply::empty(true, "queued");
        assert!(!reply.terminal());
        reply.job_id = "f2ee6922-ce2e-4bb4-82df-0b8c2bcc0498".into();
        reply.namespace = "a".repeat(64);
        reply.phase = "complete".into();
        for flags in [(true, true, false), (true, false, true), (false, true, true)] {
            (reply.quiescent, reply.process_exited, reply.task_joined) = flags;
            assert!(!reply.terminal());
        }
        (reply.quiescent, reply.process_exited, reply.task_joined) = (true, true, true);
        assert!(!reply.terminal());
        reply.machine_id = "1234567890".into();
        assert!(reply.terminal());
        reply.phase = "recovery_unconfirmed".into(); assert!(!reply.terminal());
        assert!(!Reply::empty(true, "idle").terminal());
        let mut empty = Reply::empty(true, "complete"); empty.phase = "complete".into();
        (empty.quiescent, empty.process_exited, empty.task_joined) = (true, true, true);
        assert!(!empty.terminal());
        let value: serde_json::Value = serde_json::from_str(&reply.json()).unwrap();
        assert_eq!(value.as_object().unwrap().len(), 10);
    }
    #[test]
    fn first_install_recovery_is_not_an_installed_machine_or_an_uninstall_ack() {
        let mut reply=Reply::empty(true,"install_recovered");
        reply.action=crate::nikodesk::background::install::policy::Action::RecoverInstall;
        reply.job_id="f2ee6922-ce2e-4bb4-82df-0b8c2bcc0498".into();reply.namespace="a".repeat(64);
        reply.phase="install_recovered".into();
        (reply.quiescent,reply.process_exited,reply.task_joined)=(true,true,true);
        assert!(reply.terminal());
        reply.machine_id="1234567890".into();assert!(!reply.terminal());reply.machine_id.clear();
        reply.task_joined=false;assert!(!reply.terminal());reply.task_joined=true;
        reply.action=crate::nikodesk::background::install::policy::Action::Remove;
        assert!(!reply.terminal());
    }
    #[test]
    fn maintenance_actions_cannot_carry_a_password_or_new_install_policy() {
        for action in ["stop", "resume", "remove", "upgrade", "repair", "recover_install"] {
            let mut value=request(); value["action"]=action.into(); value["password"]="".into();
            assert!(BeginRequest::parse(value.to_string()).is_ok());
            for field in ["start_after_commit","allow_virtual_display","lock_on_disconnect","allow_privacy","allow_remote_restart"] {
                let mut mixed=value.clone(); mixed[field]=true.into();
                assert!(BeginRequest::parse(mixed.to_string()).is_err());
            }
            value["password"]="unexpected credential".into();
            assert!(BeginRequest::parse(value.to_string()).is_err());
        }
        let mut value=request(); value["action"]="stop_all_services".into();
        assert!(BeginRequest::parse(value.to_string()).is_err());
    }
    #[test]
    fn local_machine_configuration_accepts_only_selected_policies_without_a_password() {
        let mut value = request();
        value["action"] = "configure".into();
        value["password"] = "".into();
        for field in ["allow_virtual_display", "lock_on_disconnect", "allow_privacy", "allow_remote_restart", "start_after_commit"] {
            value[field] = true.into();
        }
        assert!(BeginRequest::parse(value.to_string()).is_ok());
        value["password"] = "unexpected credential".into();
        assert!(BeginRequest::parse(value.to_string()).is_err());
        value["password"] = "".into();
        value["action"] = "resume".into();
        assert!(BeginRequest::parse(value.to_string()).is_err());
    }
    #[test]
    fn only_original_canonical_job_uuid_is_a_query_key() {
        let id = "f2ee6922-ce2e-4bb4-82df-0b8c2bcc0498";
        assert!(job_valid(id)); assert!(!job_valid(&id.to_uppercase()));
        assert!(!job_valid("00000000-0000-0000-0000-000000000000"));
        assert!(!job_valid("current"));
    }
    #[test]
    fn install_status_fixture_uses_actual_reply_serializer() {
        let base = Reply { action: crate::nikodesk::background::install::policy::Action::Install, ok: true, job_id: "f2ee6922-ce2e-4bb4-82df-0b8c2bcc0498".into(),
            namespace: "a".repeat(64), phase: "preparing".into(), reason: "queued".into(),
            quiescent: false, process_exited: false, task_joined: false, machine_id: String::new() };
        let mut values = vec![Reply::empty(true, "idle"), Reply::empty(false, "unsupported"), base.clone()];
        for (phase, reason, quiet, exited, joined) in [
            ("complete", "in_progress", false, true, false),
            ("complete", "complete", true, true, true),
            ("recovery_unconfirmed", "recovery_required", false, true, true),
            ("recovery_disabled", "recovery_required", true, true, true),
            ("launch_not_started", "launch_not_started", true, true, true),
        ] {
            let mut reply = base.clone(); reply.phase = phase.into(); reply.reason = reason.into();
            reply.quiescent = quiet; reply.process_exited = exited; reply.task_joined = joined;
            if phase == "complete" && quiet { reply.machine_id = "1234567890".into(); }
            values.push(reply);
        }
        let json = values.iter().map(|value| serde_json::from_str::<serde_json::Value>(&value.json()).unwrap()).collect::<Vec<_>>();
        assert!(json.iter().all(|value| value.as_object().unwrap().len() == 10));
        if let Ok(path) = std::env::var("NIKODESK_INSTALL_STATUS_FIXTURE") {
            std::fs::write(path, serde_json::to_vec_pretty(&json).unwrap()).unwrap();
        }
    }
}
