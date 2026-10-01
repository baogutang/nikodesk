use super::*;

static FLUTTER_RUNTIME: Mutex<Option<hbb_common::tokio::runtime::Handle>> = Mutex::new(None);

#[cfg(feature = "flutter")]
pub(crate) fn flutter_runtime() -> Option<hbb_common::tokio::runtime::Handle> {
    FLUTTER_RUNTIME.lock().ok().and_then(|runtime| runtime.clone())
}

const REQUEST_LIFETIME: std::time::Duration = std::time::Duration::from_secs(5);
const ROLLBACK_WAIT: std::time::Duration = std::time::Duration::from_secs(3);

#[derive(Clone, Copy)]
pub(crate) struct Deadline {
    expires_at_ms: u64,
    expires: std::time::Instant,
}

impl Deadline {
    fn now_ms() -> ResultType<u64> {
        Ok(std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH)?.as_millis().try_into()?)
    }

    pub(crate) fn new() -> ResultType<Self> {
        Self::from_wire(Self::now_ms()? + REQUEST_LIFETIME.as_millis() as u64)
    }

    pub(crate) fn from_wire(expires_at_ms: u64) -> ResultType<Self> {
        let remaining = expires_at_ms.checked_sub(Self::now_ms()?)
            .filter(|remaining| *remaining > 0 && *remaining <= REQUEST_LIFETIME.as_millis() as u64)
            .ok_or_else(|| anyhow!("NikoDesk settings request expired"))?;
        Ok(Self {
            expires_at_ms,
            expires: std::time::Instant::now() + std::time::Duration::from_millis(remaining),
        })
    }

    pub(crate) fn check(&self) -> ResultType<()> {
        if std::time::Instant::now() >= self.expires || Self::now_ms()? >= self.expires_at_ms {
            bail!("NikoDesk settings request expired");
        }
        Ok(())
    }

    pub(crate) fn wire(&self) -> u64 { self.expires_at_ms }

    pub(crate) fn wait_ms(&self) -> u64 {
        self.expires.saturating_duration_since(std::time::Instant::now()).as_millis() as u64
            + ROLLBACK_WAIT.as_millis() as u64
    }
}

#[cfg(any(feature = "flutter", target_os = "android", target_os = "ios"))]
pub(crate) async fn run_flutter_tasks(
    receiver: std::sync::mpsc::Receiver<super::online_query::Query>,
) {
    use hbb_common::tokio;
    *FLUTTER_RUNTIME.lock().unwrap() = Some(tokio::runtime::Handle::current());
    let receiver = std::sync::Arc::new(Mutex::new(receiver));
    loop {
        let receiver = receiver.clone();
        let ids = tokio::task::spawn_blocking(move || receiver.lock().unwrap().recv()).await;
        match ids {
            Ok(Ok(query)) => {
                if let Ok((onlines,offlines))=query.run().await {
                    let captured=query.route.clone();
                    let _=tokio::task::spawn_blocking(move || {
                            let current = server_scope::current();
                            if current.as_ref().map(server_scope::ServerScope::namespace)==Some(captured.namespace()) {
                                super::online_status::observe(captured.namespace(),&onlines,&offlines);
                            }
                            if let Some(event) = online_event(captured.namespace(),
                                current.as_ref().map(server_scope::ServerScope::namespace), onlines, offlines) {
                                let _ = crate::flutter::push_global_event(crate::flutter::APP_TYPE_MAIN, event);
                            }
                    }).await;
                }
            }
            _ => break,
        }
    }
}

#[cfg(any(feature = "flutter", target_os = "android", target_os = "ios"))]
fn online_event(captured: &str, current: Option<&str>, onlines: Vec<String>, offlines: Vec<String>) -> Option<String> {
    if current != Some(captured) { return None; }
    serde_json::to_string(&HashMap::from([
        ("name", "callback_query_onlines".to_owned()),
        ("onlines", onlines.join(",")),
        ("offlines", offlines.join(",")),
        ("nikodesk-server-namespace", captured.to_owned()),
    ])).ok()
}

pub fn save(json: String) -> String {
    run_request(move |deadline| async move {
        crate::ipc::save_niko_private_server(json, deadline).await
    }).json()
}

pub fn patch(key: String, value: String) -> ResultType<()> {
    let result = run_request(move |deadline| async move {
        crate::ipc::patch_niko_option(key, value, deadline).await
    });
    if !result.ok { bail!("NikoDesk option persistence was not confirmed"); }
    Ok(())
}

fn run_request<F, T>(request: F) -> SaveResult
where
    F: FnOnce(Deadline) -> T + Send + 'static,
    T: std::future::Future<Output = String> + Send + 'static,
{
    let deadline = match Deadline::new() {
        Ok(deadline) => deadline,
        Err(_) => { reject_snapshot_write(); return SaveResult::unknown(); }
    };
    let runtime = match FLUTTER_RUNTIME.lock().unwrap().clone() {
        Some(runtime) => runtime,
        None => { reject_snapshot_write(); return SaveResult::unknown(); }
    };
    let (sender, receiver) = std::sync::mpsc::sync_channel(1);
    runtime.spawn(async move {
        let result = request(deadline).await;
        let _ = sender.try_send(result);
    });
    match receiver.recv_timeout(std::time::Duration::from_millis(deadline.wait_ms())) {
        Ok(json) => match SaveResult::parse(&json) {
            Ok(result) => {
                if !result.ok && !result.stopped_verified { reject_snapshot_write(); }
                result
            }
            Err(_) => { reject_snapshot_write(); SaveResult::unknown() }
        },
        Err(_) => { reject_snapshot_write(); SaveResult::unknown() }
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct PrivateServerSettings {
    id_server: String,
    relay_server: String,
    public_key: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SaveResult {
    pub ok: bool,
    pub state: &'static str,
    pub stopped_verified: bool,
}

impl SaveResult {
    fn new(ok: bool, state: &'static str, stopped_verified: bool) -> Self {
        Self { ok, state, stopped_verified }
    }

    pub fn unknown() -> Self {
        Self::new(false, "unknown", false)
    }

    pub fn json(&self) -> String {
        serde_json::to_string(self).unwrap_or_else(|_| {
            r#"{"ok":false,"state":"unknown","stoppedVerified":false}"#.to_owned()
        })
    }

    pub(crate) fn parse(json: &str) -> ResultType<Self> {
        let value: serde_json::Value = serde_json::from_str(json)?;
        let ok = value.get("ok").and_then(|v| v.as_bool()).ok_or_else(|| anyhow!("Invalid settings result"))?;
        let stopped = value.get("stoppedVerified").and_then(|v| v.as_bool()).ok_or_else(|| anyhow!("Invalid settings result"))?;
        let state = match value.get("state").and_then(|v| v.as_str()) {
            Some("enabled") if ok && !stopped => "enabled",
            Some("stopped") if stopped => "stopped",
            Some("unknown") if !ok && !stopped => "unknown",
            Some("invalid") if !ok && !stopped => "invalid",
            Some("unsupported") if !ok && !stopped => "unsupported",
            _ => bail!("Invalid settings result"),
        };
        Ok(Self::new(ok, state, stopped))
    }
}

impl PrivateServerSettings {
    fn parse(json: &str) -> ResultType<Self> {
        if json.len() > 1024 {
            bail!("Invalid private server settings");
        }
        let value: Self = serde_json::from_str(json)
            .map_err(|_| anyhow!("Invalid private server settings"))?;
        if value.id_server.len() > 260 || value.relay_server.is_empty()
            || value.relay_server.len() > 260 || value.public_key.len() != 44 {
            bail!("Invalid private server settings");
        }
        validate_server_values(&value.id_server, &value.relay_server, &value.public_key)?;
        let decoded = base64::decode(&value.public_key, base64::Variant::Original)
            .map_err(|_| anyhow!("Invalid server public key"))?;
        if base64::encode(&decoded, base64::Variant::Original) != value.public_key {
            bail!("Invalid server public key");
        }
        Ok(value)
    }
}

trait SettingsBackend {
    fn read(&mut self) -> ResultType<HashMap<String, String>>;
    fn write(&mut self, options: &HashMap<String, String>) -> ResultType<()>;
}

fn transact(settings: &PrivateServerSettings, backend: &mut impl SettingsBackend, deadline: Deadline) -> SaveResult {
    if deadline.check().is_err() { return SaveResult::unknown(); }
    let mut options = match backend.read() {
        Ok(options) => options,
        Err(_) => return SaveResult::unknown(),
    };
    options.insert("custom-rendezvous-server".into(), settings.id_server.clone());
    options.insert("relay-server".into(), settings.relay_server.clone());
    options.insert("key".into(), settings.public_key.clone());
    options.insert("stop-service".into(), "Y".into());
    let stopped = options.clone();
    let result = (|| -> ResultType<()> {
        deadline.check()?;
        backend.write(&stopped)?;
        if backend.read()? != stopped {
            bail!("Private server settings were not confirmed");
        }
        deadline.check()?;
        options.insert("stop-service".into(), "N".into());
        backend.write(&options)?;
        deadline.check()?;
        if backend.read()? != options {
            bail!("Private server activation was not confirmed");
        }
        deadline.check()?;
        Ok(())
    })();
    if result.is_ok() {
        return SaveResult::new(true, "enabled", false);
    }
    // A failed final verification must not leave registration enabled.
    restore_stop(&stopped, backend)
}

fn restore_stop(stopped: &HashMap<String, String>, backend: &mut impl SettingsBackend) -> SaveResult {
    let stopped_verified = backend.write(stopped).is_ok()
        && backend.read().map(|saved| saved == *stopped).unwrap_or(false);
    SaveResult::new(false, if stopped_verified { "stopped" } else { "unknown" }, stopped_verified)
}

fn patch_transaction(key: &str, value: &str, backend: &mut impl SettingsBackend,
    deadline: Deadline, unconfirmed: bool) -> SaveResult {
    if !valid_patch(key, value) { return SaveResult::new(false, "invalid", false); }
    if deadline.check().is_err() { return SaveResult::unknown(); }
    let mut options = match backend.read() {
        Ok(options) => options,
        Err(_) => return SaveResult::unknown(),
    };
    if key == super::wol_proxy::OPTION && super::wol_proxy::validate_patch(value, &options).is_err() {
        return SaveResult::new(false, "invalid", false);
    }
    if value.is_empty() {
        options.remove(key);
        if let Some(default) = config::DEFAULT_SETTINGS.read().unwrap().get(key) {
            options.insert(key.to_owned(), default.clone());
        }
    } else {
        options.insert(key.to_owned(), value.to_owned());
    }
    if matches!(key, "custom-rendezvous-server" | "relay-server" | "key") {
        options.insert("stop-service".into(), "Y".into());
    }
    if unconfirmed && !(key == "stop-service" && value == "N") {
        options.insert("stop-service".into(), "Y".into());
    }
    if prepare_options(&mut options).is_err() { return SaveResult::new(false, "invalid", false); }
    let mut stopped = options.clone();
    stopped.insert("stop-service".into(), "Y".into());
    let result = (|| -> ResultType<()> {
        deadline.check()?;
        backend.write(&options)?;
        deadline.check()?;
        if backend.read()? != options { bail!("NikoDesk option was not confirmed"); }
        deadline.check()?;
        Ok(())
    })();
    if result.is_err() { return restore_stop(&stopped, backend); }
    let stopped = options.get("stop-service").map(String::as_str) != Some("N");
    SaveResult::new(true, if stopped { "stopped" } else { "enabled" }, stopped)
}

#[derive(Clone, Copy)]
struct SettingsGate<'a> {
    writing: &'a AtomicBool,
    failed: &'a AtomicBool,
}

impl SettingsGate<'_> {
    fn unconfirmed(&self) -> bool {
        self.writing.load(Ordering::SeqCst) || self.failed.load(Ordering::SeqCst)
    }

    fn finish(&self, result: &SaveResult) {
        self.failed.store(!result.ok, Ordering::SeqCst);
        // An unverified rollback keeps the connection gate closed until a
        // later transaction verifies either the stopped or the enabled state.
        self.writing.store(!result.ok && !result.stopped_verified, Ordering::SeqCst);
    }
}

fn gate() -> SettingsGate<'static> {
    SettingsGate { writing: &SETTINGS_WRITING, failed: &SETTINGS_SAVE_FAILED }
}

fn with_write_lock<B, F>(identity: &std::path::Path, lock: &Mutex<()>, gate: SettingsGate,
    deadline: Deadline, backend: &mut B, apply: F) -> SaveResult
where B: SettingsBackend, F: FnOnce(bool, &mut B) -> SaveResult {
    let _lock = lock.lock().unwrap();
    let unconfirmed = gate.unconfirmed();
    let was_writing = gate.writing.load(Ordering::SeqCst);
    gate.writing.store(true, Ordering::SeqCst);
    let result = (|| {
        let (_file_lock, _) = match identity_file::prepare(identity) {
            Ok(locked) => locked,
            Err(_) => {
                let result = SaveResult::unknown();
                gate.finish(&result);
                return result;
            }
        };
        if deadline.check().is_err() {
            // No settings were changed. A queued expired request must not
            // invalidate a newer transaction that already completed.
            gate.writing.store(was_writing, Ordering::SeqCst);
            return SaveResult::unknown();
        }
        let mut result = apply(unconfirmed, backend);
        if result.ok && deadline.check().is_err() {
            result = match backend.read() {
                Ok(mut stopped) => {
                    stopped.insert("stop-service".into(), "Y".into());
                    restore_stop(&stopped, backend)
                }
                Err(_) => SaveResult::unknown(),
            };
        }
        gate.finish(&result);
        result
    })();
    result
}

struct LocalSettingsBackend;

impl SettingsBackend for LocalSettingsBackend {
    fn read(&mut self) -> ResultType<HashMap<String, String>> {
        let path = config::Config2::file();
        let stored = match std::fs::symlink_metadata(&path) {
            Ok(_) => read_options_file(&path),
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => Ok(HashMap::new()),
            Err(err) => Err(err.into()),
        }?;
        let mut options = config::DEFAULT_SETTINGS.read().unwrap().clone();
        options.extend(stored);
        options.extend(config::OVERWRITE_SETTINGS.read().unwrap().clone());
        options.remove("nikodesk-server-namespace");
        Ok(options)
    }

    fn write(&mut self, options: &HashMap<String, String>) -> ResultType<()> {
        let saved = purified_options(options.clone());
        write_options_file(&config::Config2::file(), &saved)?;
        Config::replace_options_cache_without_store(saved);
        Ok(())
    }
}

pub fn save_locally(json: &str, expires_at_ms: u64) -> SaveResult {
    if super::background::is_system_worker() {
        return SaveResult::new(false, "machine_settings_read_only", false);
    }
    let settings = match PrivateServerSettings::parse(json) {
        Ok(settings) => settings,
        Err(_) => return SaveResult::new(false, "invalid", false),
    };
    if initialize().is_err() {
        return SaveResult::unknown();
    }
    let deadline = match Deadline::from_wire(expires_at_ms) {
        Ok(deadline) => deadline,
        Err(_) => return SaveResult::unknown(),
    };
    let result = with_write_lock(&Config::file(), &SETTINGS_WRITE_LOCK, gate(), deadline,
        &mut LocalSettingsBackend, |_, backend| transact(&settings, backend, deadline));
    crate::rendezvous_mediator::RendezvousMediator::restart();
    result
}

pub fn patch_locally(key: &str, value: &str, expires_at_ms: u64) -> SaveResult {
    if super::background::is_system_worker() {
        return SaveResult::new(false, "machine_settings_read_only", false);
    }
    if !valid_patch(key, value) {
        return SaveResult::new(false, "invalid", false);
    }
    if initialize().is_err() { return SaveResult::unknown(); }
    let deadline = match Deadline::from_wire(expires_at_ms) {
        Ok(deadline) => deadline,
        Err(_) => return SaveResult::unknown(),
    };
    let result = with_write_lock(&Config::file(), &SETTINGS_WRITE_LOCK, gate(), deadline,
        &mut LocalSettingsBackend, |unconfirmed, backend| patch_transaction(key, value, backend, deadline, unconfirmed));
    #[cfg(any(target_os = "macos", target_os = "windows"))]
    if result.ok && key == super::auto_lock::OPTION && value != "Y" {
        super::auto_lock::cancel_pending();
    }
    crate::rendezvous_mediator::RendezvousMediator::restart();
    result
}

fn valid_patch(key: &str, value: &str) -> bool {
    !key.is_empty() && key.len() <= 260 && value.len() <= 64 * 1024
        && !matches!(key, "nikodesk-server-namespace" | "nikodesk-two-factor-status" | "voice-call-input")
        && (!matches!(key, "custom-rendezvous-server" | "relay-server" | "key" | "api-server") || value.is_empty())
        && !config::OVERWRITE_SETTINGS.read().unwrap().get(key).map_or(false, |forced| forced != value)
}

pub fn reject_snapshot_write() {
    SETTINGS_WRITING.store(true, Ordering::SeqCst);
    stop_after_settings_failure();
}

pub fn refresh_cache() -> ResultType<()> {
    if super::background::is_system_worker() { bail!("Machine settings require a verified service restart"); }
    let _lock = SETTINGS_WRITE_LOCK.lock().unwrap();
    let (_file_lock, _) = identity_file::prepare(&Config::file())?;
    Config::replace_options_cache_without_store(read_options_file(&config::Config2::file())?);
    Ok(())
}

pub fn read_verified_options() -> ResultType<HashMap<String, String>> {
    #[cfg(windows)]
    if super::background::is_system_worker() {
        return Config::trusted_machine_runtime_options()
            .ok_or_else(|| anyhow!("Verified machine startup settings are unavailable").into());
    }
    with_verified_options(|options| Ok(options.clone()))
}

/// A short synchronous local policy transaction may keep the verified scope
/// locked until its own disk CAS finishes. Never await or acquire these locks
/// in the opposite (policy -> settings) order.
pub(crate) fn with_verified_options<T>(
    operation: impl FnOnce(&HashMap<String, String>) -> ResultType<T>,
) -> ResultType<T> {
    if super::background::is_system_worker() { bail!("Machine settings are read-only in the ordinary settings API"); }
    let _lock = SETTINGS_WRITE_LOCK.lock().unwrap();
    let (_file_lock, _) = identity_file::prepare(&Config::file())?;
    if gate().unconfirmed() { bail!("NikoDesk settings have not been confirmed"); }
    let options = match LocalSettingsBackend.read() {
        Ok(options) => options,
        Err(err) => { reject_snapshot_write(); return Err(err); }
    };
    Config::replace_options_cache_without_store(purified_options(options.clone()));
    operation(&options)
}

pub fn confirm_remote_result(json: &str, expected: impl FnOnce(&HashMap<String, String>) -> bool) -> String {
    let result = (|| -> ResultType<SaveResult> {
        let result = SaveResult::parse(json)?;
        let _lock = SETTINGS_WRITE_LOCK.lock().unwrap();
        let (_file_lock, _) = identity_file::prepare(&Config::file())?;
        let mut backend = LocalSettingsBackend;
        let options = backend.read()?;
        Config::replace_options_cache_without_store(purified_options(options.clone()));
        let stopped = options.get("stop-service").map(String::as_str) != Some("N");
        if (result.ok && (!expected(&options) || stopped != result.stopped_verified))
            || (result.stopped_verified && !stopped) {
            bail!("NikoDesk settings result does not match the saved state");
        }
        gate().finish(&result);
        Ok(result)
    })();
    match result {
        Ok(result) => result.json(),
        Err(_) => { reject_snapshot_write(); SaveResult::unknown().json() }
    }
}

pub fn matches_server(json: &str, options: &HashMap<String, String>) -> bool {
    PrivateServerSettings::parse(json).map(|settings| {
        options.get("custom-rendezvous-server") == Some(&settings.id_server)
            && options.get("relay-server") == Some(&settings.relay_server)
            && options.get("key") == Some(&settings.public_key)
    }).unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn legacy_voice_input_patch_is_rejected_before_any_settings_write() {
        let mut backend = backend();
        let original = backend.options.clone();
        for device in ["", "default", "selected-microphone"] {
            let result = patch_transaction("voice-call-input", device, &mut backend,
                Deadline::new().unwrap(), false);
            assert!(!result.ok);
            assert_eq!(result.state, "invalid");
        }
        assert!(backend.writes.is_empty());
        assert_eq!(backend.reads, 0);
        assert_eq!(backend.options, original);
    }

    struct Backend {
        options: HashMap<String, String>,
        writes: Vec<HashMap<String, String>>,
        reads: usize,
        fail_read: Option<usize>,
        fail_writes: bool,
    }

    impl SettingsBackend for Backend {
        fn read(&mut self) -> ResultType<HashMap<String, String>> {
            self.reads += 1;
            if self.fail_read == Some(self.reads) {
                bail!("synthetic read failure");
            }
            Ok(self.options.clone())
        }

        fn write(&mut self, options: &HashMap<String, String>) -> ResultType<()> {
            if self.fail_writes { bail!("synthetic write failure"); }
            self.options = options.clone();
            self.writes.push(options.clone());
            Ok(())
        }
    }

    fn settings() -> PrivateServerSettings {
        PrivateServerSettings {
            id_server: "private.example:21116".into(),
            relay_server: "private.example:21117".into(),
            public_key: base64::encode(&[7; 32], base64::Variant::Original),
        }
    }

    fn backend() -> Backend {
        Backend {
            options: HashMap::from([("enable-keyboard".into(), "N".into())]),
            writes: vec![], reads: 0, fail_read: None, fail_writes: false,
        }
    }

    #[test]
    fn private_server_transaction_commits_the_complete_tuple_and_preserves_other_options() {
        let settings = settings();
        let mut backend = backend();
        let result = transact(&settings, &mut backend, Deadline::new().unwrap());
        assert!(result.ok);
        assert_eq!(backend.writes.len(), 2);
        for write in &backend.writes {
            assert_eq!(write["custom-rendezvous-server"], settings.id_server);
            assert_eq!(write["relay-server"], settings.relay_server);
            assert_eq!(write["key"], settings.public_key);
            assert_eq!(write["enable-keyboard"], "N");
        }
        assert_eq!(backend.writes[0]["stop-service"], "Y");
        assert_eq!(backend.writes[1]["stop-service"], "N");
    }

    #[test]
    fn private_server_transaction_final_read_failure_restores_a_verified_stop() {
        let mut backend = backend();
        backend.fail_read = Some(3);
        let result = transact(&settings(), &mut backend, Deadline::new().unwrap());
        assert!(!result.ok);
        assert!(result.stopped_verified);
        assert_eq!(backend.options["stop-service"], "Y");
    }

    #[test]
    fn private_server_transaction_write_failure_never_claims_a_verified_stop() {
        let mut backend = backend();
        backend.fail_writes = true;
        let result = transact(&settings(), &mut backend, Deadline::new().unwrap());
        assert!(!result.ok);
        assert!(!result.stopped_verified);
        assert_eq!(result.state, "unknown");
    }

    #[test]
    fn private_server_transaction_rejects_extra_fields_and_public_servers() {
        let key = settings().public_key;
        let json = serde_json::json!({"idServer":"private.example", "relayServer":"private.example",
            "publicKey":key, "password":"synthetic-secret"}).to_string();
        assert!(PrivateServerSettings::parse(&json).is_err());
        let json = serde_json::json!({"idServer":"public", "relayServer":"private.example", "publicKey":key}).to_string();
        assert!(PrivateServerSettings::parse(&json).is_err());
        assert!(!SaveResult::unknown().json().contains("synthetic-secret"));
    }

    #[test]
    fn settings_deadline_is_preserved_by_the_ipc_payload() {
        let deadline = Deadline::new().unwrap();
        let data = crate::ipc::Data::NikoOptionPatch("stop-service".into(), "Y".into(), deadline.wire());
        let wire = serde_json::to_string(&data).unwrap();
        match serde_json::from_str::<crate::ipc::Data>(&wire).unwrap() {
            crate::ipc::Data::NikoOptionPatch(_, _, expires) => {
                assert_eq!(Deadline::from_wire(expires).unwrap().wire(), deadline.wire());
            }
            _ => panic!("wrong IPC payload"),
        }
        assert!(Deadline::from_wire(Deadline::now_ms().unwrap()).is_err());
        assert!(Deadline::from_wire(Deadline::now_ms().unwrap() + 60_000).is_err());
    }

    #[test]
    fn reserved_namespace_is_never_saved_by_a_patch() {
        let mut backend = backend();
        let result = patch_transaction("nikodesk-server-namespace", "synthetic", &mut backend,
            Deadline::new().unwrap(), false);
        assert!(!result.ok);
        assert!(backend.writes.is_empty());
    }

    #[test]
    fn private_server_tuple_requires_a_transaction_and_clearing_one_field_stops_registration() {
        for key in ["custom-rendezvous-server", "relay-server", "key", "api-server"] {
            let mut backend = backend();
            let result = patch_transaction(key, "synthetic", &mut backend, Deadline::new().unwrap(), false);
            assert!(!result.ok);
            assert!(backend.writes.is_empty());
        }
        for key in ["custom-rendezvous-server", "relay-server", "key"] {
            let mut backend = backend();
            assert!(transact(&settings(), &mut backend, Deadline::new().unwrap()).ok);
            let result = patch_transaction(key, "", &mut backend, Deadline::new().unwrap(), false);
            assert!(result.ok && result.stopped_verified);
            assert_eq!(backend.options["stop-service"], "Y");
        }
    }

    #[test]
    #[cfg(any(feature = "flutter", target_os = "android", target_os = "ios"))]
    fn online_callback_keeps_the_captured_namespace_and_discards_changed_or_unknown_scope() {
        let event = online_event("captured", Some("captured"), vec!["123456789".into()], vec![]).unwrap();
        let event: serde_json::Value = serde_json::from_str(&event).unwrap();
        assert_eq!(event["nikodesk-server-namespace"], "captured");
        assert_eq!(event["onlines"], "123456789");
        assert!(online_event("captured", Some("other"), vec![], vec![]).is_none());
        assert!(online_event("captured", None, vec![], vec![]).is_none());
    }

    #[cfg(unix)]
    mod disk_regressions {
        use super::*;
        use std::{fs, os::unix::fs::PermissionsExt, sync::{Arc, mpsc}, time::Duration};

        #[derive(Default)]
        struct State { writing: AtomicBool, failed: AtomicBool }
        impl State {
            fn gate(&self) -> SettingsGate<'_> {
                SettingsGate { writing: &self.writing, failed: &self.failed }
            }
        }

        struct Files(std::path::PathBuf);
        impl Files {
            fn new() -> Self {
                sodiumoxide::init().unwrap();
                let directory = std::env::temp_dir().join(format!("niko-deadline-{}", hbb_common::uuid::Uuid::new_v4()));
                fs::create_dir(&directory).unwrap();
                fs::set_permissions(&directory, fs::Permissions::from_mode(0o700)).unwrap();
                let files = Self(directory);
                fs::write(files.config(), "unlock_pin = 'preserved-test-value'\n[options]\nstop-service = 'Y'\nenable-keyboard = 'N'\n").unwrap();
                fs::set_permissions(files.config(), fs::Permissions::from_mode(0o600)).unwrap();
                drop(identity_file::prepare(&files.identity()).unwrap());
                files
            }
            fn identity(&self) -> std::path::PathBuf { self.0.join("NikoDesk.toml") }
            fn config(&self) -> std::path::PathBuf { self.0.join("NikoDesk2.toml") }
            fn read(&self) -> HashMap<String, String> { read_options_file(&self.config()).unwrap() }
        }
        impl Drop for Files {
            fn drop(&mut self) { fs::remove_dir_all(&self.0).unwrap(); }
        }

        struct Disk {
            path: std::path::PathBuf,
            state: Arc<State>,
            delay_enable: Duration,
            delay_enabled_read: Duration,
            enabled_written: bool,
            fail_rollback: bool,
            stopped_signal: Option<mpsc::Sender<()>>,
            continue_write: Option<mpsc::Receiver<()>>,
            writes: usize,
        }
        impl Disk {
            fn new(path: std::path::PathBuf, state: Arc<State>) -> Self {
                Self { path, state, delay_enable: Duration::ZERO, delay_enabled_read: Duration::ZERO,
                    enabled_written: false, fail_rollback: false, stopped_signal: None,
                    continue_write: None, writes: 0 }
            }
        }
        impl SettingsBackend for Disk {
            fn read(&mut self) -> ResultType<HashMap<String, String>> {
                let options = read_options_file(&self.path)?;
                if self.enabled_written && !self.delay_enabled_read.is_zero() {
                    assert!(self.state.writing.load(Ordering::SeqCst));
                    std::thread::sleep(std::mem::replace(&mut self.delay_enabled_read, Duration::ZERO));
                }
                Ok(options)
            }
            fn write(&mut self, options: &HashMap<String, String>) -> ResultType<()> {
                assert!(self.state.writing.load(Ordering::SeqCst));
                let enabled = options.get("stop-service").map(String::as_str) == Some("N");
                if !enabled && self.enabled_written && self.fail_rollback { bail!("synthetic rollback failure"); }
                if enabled && !self.delay_enable.is_zero() {
                    std::thread::sleep(std::mem::replace(&mut self.delay_enable, Duration::ZERO));
                }
                write_options_file(&self.path, options)?;
                self.writes += 1;
                self.enabled_written |= enabled;
                if !enabled {
                    if let Some(signal) = self.stopped_signal.take() { signal.send(()).unwrap(); }
                    if let Some(continue_write) = self.continue_write.take() {
                        continue_write.recv_timeout(Duration::from_secs(2)).unwrap();
                    }
                }
                assert!(self.state.writing.load(Ordering::SeqCst));
                Ok(())
            }
        }

        fn deadline_after(ms: u64) -> Deadline {
            Deadline::from_wire(Deadline::now_ms().unwrap() + ms).unwrap()
        }

        fn wait_for_writer(state: &State) {
            let end = std::time::Instant::now() + Duration::from_secs(2);
            while !state.writing.load(Ordering::SeqCst) {
                assert!(std::time::Instant::now() < end);
                std::thread::sleep(Duration::from_millis(1));
            }
        }

        #[test]
        fn request_expired_while_waiting_for_the_real_file_lock_never_writes() {
            let files = Files::new();
            let mut current = files.read();
            current.insert("custom-rendezvous-server".into(), "newer.example:21116".into());
            current.insert("relay-server".into(), "newer.example:21117".into());
            current.insert("key".into(), settings().public_key);
            current.insert("stop-service".into(), "N".into());
            write_options_file(&files.config(), &current).unwrap();
            let before = fs::read(files.config()).unwrap();
            let (held, _) = identity_file::prepare(&files.identity()).unwrap();
            let state = Arc::new(State::default());
            let (identity, path, writer_state) = (files.identity(), files.config(), state.clone());
            let deadline = deadline_after(100);
            let job = std::thread::spawn(move || {
                let mut disk = Disk::new(path, writer_state.clone());
                let result = with_write_lock(&identity, &Mutex::new(()), writer_state.gate(), deadline, &mut disk,
                    |_, backend| transact(&settings(), backend, deadline));
                (result, disk.writes)
            });
            wait_for_writer(&state);
            std::thread::sleep(Duration::from_millis(250));
            drop(held);
            let (result, writes) = job.join().unwrap();
            assert!(!result.ok);
            assert_eq!(writes, 0);
            assert_eq!(fs::read(files.config()).unwrap(), before);
            assert!(!state.gate().unconfirmed());
        }

        #[test]
        fn request_expired_during_enable_write_restores_a_verified_stop() {
            let files = Files::new();
            let state = Arc::new(State::default());
            let mut disk = Disk::new(files.config(), state.clone());
            disk.delay_enable = Duration::from_millis(1400);
            let deadline = deadline_after(1000);
            let result = with_write_lock(&files.identity(), &Mutex::new(()), state.gate(), deadline, &mut disk,
                |_, backend| transact(&settings(), backend, deadline));
            assert!(disk.enabled_written);
            assert!(!result.ok);
            assert!(result.stopped_verified);
            assert_eq!(files.read()["stop-service"], "Y");
            assert!(!state.writing.load(Ordering::SeqCst));
            assert!(state.failed.load(Ordering::SeqCst));
        }

        #[test]
        fn request_expired_during_final_read_restores_a_verified_stop() {
            let files = Files::new();
            let state = Arc::new(State::default());
            let mut disk = Disk::new(files.config(), state.clone());
            disk.delay_enabled_read = Duration::from_millis(1400);
            let deadline = deadline_after(1000);
            let result = with_write_lock(&files.identity(), &Mutex::new(()), state.gate(), deadline, &mut disk,
                |_, backend| transact(&settings(), backend, deadline));
            assert!(disk.enabled_written);
            assert!(!result.ok);
            assert!(result.stopped_verified);
            assert_eq!(files.read()["stop-service"], "Y");
            assert!(!state.writing.load(Ordering::SeqCst));
        }

        #[test]
        fn request_expired_after_readback_never_reopens_the_connection_gate() {
            let files = Files::new();
            let state = Arc::new(State::default());
            let mut disk = Disk::new(files.config(), state.clone());
            let deadline = deadline_after(1000);
            let result = with_write_lock(&files.identity(), &Mutex::new(()), state.gate(), deadline, &mut disk,
                |_, backend| {
                    let result = transact(&settings(), backend, deadline);
                    assert!(result.ok);
                    std::thread::sleep(Duration::from_millis(1400));
                    assert!(state.writing.load(Ordering::SeqCst));
                    result
                });
            assert!(!result.ok && result.stopped_verified);
            assert_eq!(files.read()["stop-service"], "Y");
            assert!(!state.writing.load(Ordering::SeqCst));
            assert!(state.failed.load(Ordering::SeqCst));
        }

        #[test]
        fn unverified_expired_rollback_keeps_the_gate_closed_and_an_unrelated_retry_stopped() {
            let files = Files::new();
            let state = Arc::new(State::default());
            let mut disk = Disk::new(files.config(), state.clone());
            disk.delay_enable = Duration::from_millis(1400);
            disk.fail_rollback = true;
            let deadline = deadline_after(1000);
            let result = with_write_lock(&files.identity(), &Mutex::new(()), state.gate(), deadline, &mut disk,
                |_, backend| transact(&settings(), backend, deadline));
            assert!(!result.ok);
            assert!(!result.stopped_verified);
            assert!(state.writing.load(Ordering::SeqCst));
            assert!(state.failed.load(Ordering::SeqCst));
            let deadline = Deadline::new().unwrap();
            let mut disk = Disk::new(files.config(), state.clone());
            let result = with_write_lock(&files.identity(), &Mutex::new(()), state.gate(), deadline, &mut disk,
                |unconfirmed, backend| patch_transaction("verification-method", "use-both-passwords",
                    backend, deadline, unconfirmed));
            assert!(result.ok && result.stopped_verified);
            assert_eq!(files.read()["stop-service"], "Y");
            assert!(!state.gate().unconfirmed());
        }

        #[test]
        fn concurrent_option_patch_reads_latest_disk_and_never_reverts_the_new_server() {
            let files = Files::new();
            let (stopped_tx, stopped_rx) = mpsc::channel();
            let (continue_tx, continue_rx) = mpsc::channel();
            let (identity, path) = (files.identity(), files.config());
            let server = std::thread::spawn(move || {
                let state = Arc::new(State::default());
                let mut disk = Disk::new(path, state.clone());
                disk.stopped_signal = Some(stopped_tx);
                disk.continue_write = Some(continue_rx);
                let deadline = Deadline::new().unwrap();
                with_write_lock(&identity, &Mutex::new(()), state.gate(), deadline, &mut disk,
                    |_, backend| transact(&settings(), backend, deadline))
            });
            stopped_rx.recv_timeout(Duration::from_secs(2)).unwrap();
            let state = Arc::new(State::default());
            let (identity, path, patch_state) = (files.identity(), files.config(), state.clone());
            let patch = std::thread::spawn(move || {
                let mut disk = Disk::new(path, patch_state.clone());
                let deadline = Deadline::new().unwrap();
                with_write_lock(&identity, &Mutex::new(()), patch_state.gate(), deadline, &mut disk,
                    |unconfirmed, backend| patch_transaction("verification-method", "use-both-passwords",
                        backend, deadline, unconfirmed))
            });
            wait_for_writer(&state);
            continue_tx.send(()).unwrap();
            assert!(server.join().unwrap().ok);
            assert!(patch.join().unwrap().ok);
            let options = files.read();
            assert_eq!(options["custom-rendezvous-server"], settings().id_server);
            assert_eq!(options["relay-server"], settings().relay_server);
            assert_eq!(options["key"], settings().public_key);
            assert_eq!(options["verification-method"], "use-both-passwords");
            assert_eq!(options["stop-service"], "N");
            assert_eq!(options["enable-keyboard"], "N");
            let saved: toml::Value = toml::from_str(&fs::read_to_string(files.config()).unwrap()).unwrap();
            assert_eq!(saved["unlock_pin"].as_str(), Some("preserved-test-value"));
        }
    }

    #[cfg(unix)]
    #[test]
    fn private_server_transactions_share_the_file_lock_and_preserve_disk_fields() {
        use std::{fs, os::unix::fs::PermissionsExt, sync::{Arc, Barrier}};
        struct Files(std::path::PathBuf);
        impl Drop for Files {
            fn drop(&mut self) { fs::remove_dir_all(&self.0).unwrap(); }
        }
        struct Disk(std::path::PathBuf);
        impl SettingsBackend for Disk {
            fn read(&mut self) -> ResultType<HashMap<String, String>> {
                read_options_file(&self.0)
            }
            fn write(&mut self, options: &HashMap<String, String>) -> ResultType<()> {
                write_options_file(&self.0, options)
            }
        }
        sodiumoxide::init().unwrap();
        let directory = std::env::temp_dir().join(format!("niko-server-{}", hbb_common::uuid::Uuid::new_v4()));
        fs::create_dir(&directory).unwrap();
        fs::set_permissions(&directory, fs::Permissions::from_mode(0o700)).unwrap();
        let files = Files(directory);
        let identity = files.0.join("NikoDesk.toml");
        let config = files.0.join("NikoDesk2.toml");
        fs::write(&config, "unlock_pin = 'preserved-test-value'\n[options]\nstop-service = 'Y'\nenable-keyboard = 'N'\n").unwrap();
        fs::set_permissions(&config, fs::Permissions::from_mode(0o600)).unwrap();
        let barrier = Arc::new(Barrier::new(8));
        let jobs: Vec<_> = (0..8).map(|index| {
            let (identity, config, barrier) = (identity.clone(), config.clone(), barrier.clone());
            std::thread::spawn(move || {
                let settings = PrivateServerSettings {
                    id_server: format!("private-{index}.example:21116"),
                    relay_server: format!("private-{index}.example:21117"),
                    public_key: base64::encode(&[index + 1; 32], base64::Variant::Original),
                };
                barrier.wait();
                let (_lock, _) = identity_file::prepare(&identity).unwrap();
                let mut backend = Disk(config);
                assert!(transact(&settings, &mut backend, Deadline::new().unwrap()).ok);
                let saved = backend.read().unwrap();
                assert_eq!(saved["custom-rendezvous-server"], settings.id_server);
                assert_eq!(saved["relay-server"], settings.relay_server);
                assert_eq!(saved["key"], settings.public_key);
                assert_eq!(saved["stop-service"], "N");
                assert_eq!(saved["enable-keyboard"], "N");
            })
        }).collect();
        for job in jobs { job.join().unwrap(); }
        let saved: toml::Value = toml::from_str(&fs::read_to_string(&config).unwrap()).unwrap();
        assert_eq!(saved["unlock_pin"].as_str(), Some("preserved-test-value"));
        assert_eq!(fs::metadata(&config).unwrap().permissions().mode() & 0o777, 0o600);
        assert!(fs::read_dir(&files.0).unwrap().all(|entry| !entry.unwrap().file_name().to_string_lossy().contains(".tmp.")));
    }
}
