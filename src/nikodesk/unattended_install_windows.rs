use super::{BeginRequest, Reply};
use crate::nikodesk::{background::{self, install::{local_ui, wire}}, server_scope, server_settings};
use hbb_common::{anyhow::{anyhow, bail, Result}, config::{self, Config2}, tokio};
use sha2::{Digest, Sha256};
use std::{collections::HashMap, fs::{File, OpenOptions}, os::windows::{fs::OpenOptionsExt, io::AsRawHandle},
    path::PathBuf, sync::{Arc, Mutex, OnceLock, atomic::{AtomicBool, Ordering}}, time::{Duration, Instant}};
use ::windows::Win32::{Foundation::HANDLE, Storage::FileSystem::{
    GetFileInformationByHandle, BY_HANDLE_FILE_INFORMATION, FILE_FLAG_OPEN_REPARSE_POINT, FILE_SHARE_READ}};

#[derive(Clone, Copy, PartialEq, Eq)]
struct FileStamp { volume: u32, high: u32, low: u32, size: u64, written: u64 }
fn stamp(file: &File) -> Result<FileStamp> {
    let mut info = BY_HANDLE_FILE_INFORMATION::default();
    unsafe { GetFileInformationByHandle(HANDLE(file.as_raw_handle()), &mut info)?; }
    if info.dwFileAttributes & (0x400 | 0x10) != 0 || info.nNumberOfLinks != 1
        || (info.nFileIndexHigh == 0 && info.nFileIndexLow == 0)
    { bail!("install_settings_file_invalid"); }
    let size = (u64::from(info.nFileSizeHigh) << 32) | u64::from(info.nFileSizeLow);
    if size == 0 || size > 1024 * 1024 { bail!("install_settings_file_invalid"); }
    Ok(FileStamp { volume: info.dwVolumeSerialNumber, high: info.nFileIndexHigh, low: info.nFileIndexLow,
        size, written: (u64::from(info.ftLastWriteTime.dwHighDateTime) << 32) | u64::from(info.ftLastWriteTime.dwLowDateTime) })
}
fn held_file(path: &PathBuf) -> Result<File> {
    Ok(OpenOptions::new().read(true).share_mode(FILE_SHARE_READ.0)
        .custom_flags(FILE_FLAG_OPEN_REPARSE_POINT.0).open(path)?)
}
fn options_binding(options: &HashMap<String, String>, file: FileStamp) -> [u8; 32] {
    let mut digest = Sha256::new();
    digest.update(b"NikoDesk local install settings binding v1\0");
    let sorted = options.iter().collect::<std::collections::BTreeMap<_, _>>();
    for (key, value) in sorted {
        digest.update((key.len() as u64).to_le_bytes()); digest.update(key.as_bytes());
        digest.update((value.len() as u64).to_le_bytes()); digest.update(value.as_bytes());
    }
    for value in [u64::from(file.volume), u64::from(file.high), u64::from(file.low), file.size, file.written] {
        digest.update(value.to_le_bytes());
    }
    digest.finalize().into()
}
struct Provider {
    path: PathBuf,
    held: File,
    stamp: FileStamp,
    binding: [u8; 32],
    snapshot: wire::CurrentServerSnapshot,
    allow_paused: bool,
}
impl Provider {
    fn capture(expected: &str, allow_paused: bool) -> Result<Arc<Self>> {
        if background::is_system_worker() { bail!("install_ordinary_ui_required"); }
        crate::nikodesk::initialize()?;
        server_settings::with_verified_options(|options| {
            if (!allow_paused && options.get("stop-service").map(String::as_str) != Some("N"))
                || server_scope::namespace_from_options(options).as_deref() != Some(expected)
            { bail!("private_server_changed"); }
            let path = Config2::file();
            let held = held_file(&path)?;
            let file_stamp = stamp(&held)?;
            // Read again after denying data writes/deletes; do not bind an earlier
            // snapshot to a file that changed between the read and handle open.
            let mut repeated = config::DEFAULT_SETTINGS.read().unwrap().clone();
            repeated.extend(crate::nikodesk::read_options_file(&path)?);
            repeated.extend(config::OVERWRITE_SETTINGS.read().unwrap().clone());
            repeated.remove("nikodesk-server-namespace");
            if &repeated != options { bail!("private_server_changed"); }
            let binding = options_binding(options, file_stamp);
            let mut namespace = [0; 32];
            for (i, byte) in namespace.iter_mut().enumerate() {
                *byte = u8::from_str_radix(&expected[i * 2..i * 2 + 2], 16)
                    .map_err(|_| anyhow!("private_server_changed"))?;
            }
            // These are per-job comparison tokens, not a persisted global revision.
            // The original kernel handle prevents writes/deletes and is rechecked each phase.
            let random = hbb_common::sodiumoxide::randombytes::randombytes(8);
            let generation = u64::from_le_bytes(random.try_into().map_err(|_| anyhow!("install_nonce_unavailable"))?);
            let revision = u64::from_le_bytes(binding[..8].try_into().map_err(|_| anyhow!("install_revision_unavailable"))?);
            if generation == 0 || revision == 0 { bail!("install_comparison_token_unavailable"); }
            let value = wire::CurrentServerSnapshot::from_verified_local_read(namespace, generation, revision,
                options.get("custom-rendezvous-server").cloned().unwrap_or_default(),
                options.get("relay-server").cloned().unwrap_or_default(),
                options.get("key").cloned().unwrap_or_default())?;
            Ok(Arc::new(Self { path, held, stamp: file_stamp, binding, snapshot: value, allow_paused }))
        })
    }
}
impl wire::CurrentServerSnapshotProvider for Provider {
    fn read_current_verified(&self) -> Result<wire::CurrentServerSnapshot> {
        server_settings::with_verified_options(|options| {
            if Config2::file() != self.path || stamp(&self.held)? != self.stamp
                || stamp(&held_file(&self.path)?)? != self.stamp
                || options_binding(options, self.stamp) != self.binding
                || (!self.allow_paused && options.get("stop-service").map(String::as_str) != Some("N"))
            { bail!("install_private_server_snapshot_changed"); }
            Ok(self.snapshot.clone())
        })
    }
}

struct Entry {
    reply: Reply,
    cancelled: Arc<AtomicBool>,
    job: Option<local_ui::InstallJob>,
    provider: Option<Arc<Provider>>,
}
static ENTRY: OnceLock<Mutex<Option<Entry>>> = OnceLock::new();
fn registry() -> &'static Mutex<Option<Entry>> { ENTRY.get_or_init(|| Mutex::new(None)) }
fn snapshot(entry: &Entry) -> Reply {
    let mut reply = entry.reply.clone();
    if let Some(job) = &entry.job {
        let status = job.status();
        reply.phase = status.phase;
        reply.process_exited = status.process_exited;
        reply.machine_id = status.machine_id;
        reply.quiescent = false;
        reply.task_joined = false;
        reply.reason = if entry.cancelled.load(Ordering::Acquire) { "cancel_requested" } else { "in_progress" }.into();
    }
    reply
}
pub(super) async fn query(id: Option<&str>) -> Reply {
    let taken = {
        let mut guard = registry().lock().unwrap();
        let Some(entry) = guard.as_mut() else {
            return Reply::empty(id.is_none(), if id.is_none() { "idle" } else { "unknown_job" });
        };
        if id.is_some_and(|id| id != entry.reply.job_id) {
            return Reply::empty(false, "unknown_job");
        }
        if entry.job.as_ref().is_some_and(local_ui::InstallJob::is_finished) {
            entry.reply = snapshot(entry);
            entry.job.take().map(|job| (entry.reply.job_id.clone(), job))
        } else { return snapshot(entry); }
    };
    if let Some((id, job)) = taken {
        let result = job.finish_with_status().await;
        let mut guard = registry().lock().unwrap();
        if let Some(entry) = guard.as_mut().filter(|entry| entry.reply.job_id == id) {
            entry.reply.phase = result.status.phase;
            entry.reply.process_exited = result.status.process_exited;
            entry.reply.machine_id = result.status.machine_id;
            entry.reply.task_joined = result.task_joined;
            entry.reply.quiescent = result.task_joined && result.status.quiescent && result.status.process_exited;
            entry.reply.reason = if result.succeeded && entry.reply.phase == "complete" && entry.reply.terminal() {
                "complete"
            } else if result.succeeded && entry.reply.phase == "install_recovered" && entry.reply.terminal() {
                "install_recovered"
            } else if entry.reply.phase == "launch_not_started" && entry.reply.terminal() {
                "launch_not_started"
            } else { "recovery_required" }.into();
            if result.task_joined { entry.provider.take(); }
            return entry.reply.clone();
        }
    }
    Reply::empty(false, "unconfirmed")
}
fn not_started(id: &str, reason: &str, joined: bool) -> String {
    let mut guard = registry().lock().unwrap();
    if let Some(entry) = guard.as_mut().filter(|entry| entry.reply.job_id == id) {
        entry.reply.phase = if joined { "launch_not_started" } else { "recovery_unconfirmed" }.into();
        entry.reply.reason = reason.into();
        entry.reply.quiescent = joined;
        entry.reply.process_exited = joined;
        entry.reply.task_joined = joined;
        if joined { entry.provider.take(); }
        return entry.reply.json();
    }
    Reply::empty(false, "unconfirmed").json()
}
pub(super) async fn begin(mut request: BeginRequest) -> String {
    let _ = query(None).await;
    let runtime = match server_settings::flutter_runtime() {
        Some(runtime) => runtime,
        None => return Reply::empty(false, "unconfirmed").json(),
    };
    let id = hbb_common::uuid::Uuid::new_v4().to_string();
    let cancelled = Arc::new(AtomicBool::new(false));
    {
        let mut guard = registry().lock().unwrap();
        if let Some(existing) = guard.as_ref().filter(|entry| !entry.reply.terminal()) {
            let mut reply = snapshot(existing); reply.ok = false; reply.reason = "busy".into();
            return reply.json();
        }
        *guard = Some(Entry { reply: Reply { action: request.action, ok: true, job_id: id.clone(), namespace: request.expected_namespace.clone(),
            phase: "preparing".into(), reason: "queued".into(), quiescent: false, process_exited: false, task_joined: false, machine_id: String::new() },
            cancelled: Arc::clone(&cancelled), job: None, provider: None });
    }
    let deadline = Instant::now() + Duration::from_secs(30);
    let expected = request.expected_namespace.clone();
    let allow_paused = request.action != crate::nikodesk::background::install::policy::Action::Install;
    let provider = match runtime.spawn_blocking(move || Provider::capture(&expected,allow_paused)).await {
        Ok(Ok(provider)) => provider,
        Ok(Err(_)) => return not_started(&id, "private_server_unavailable", true),
        Err(_) => return not_started(&id, "unconfirmed", false),
    };
    if cancelled.load(Ordering::Acquire) || Instant::now() >= deadline {
        return not_started(&id, "launch_not_started", true);
    }
    {
        let mut guard = registry().lock().unwrap();
        let Some(entry) = guard.as_mut().filter(|entry| entry.reply.job_id == id) else {
            return Reply::empty(false, "unconfirmed").json();
        };
        entry.provider = Some(Arc::clone(&provider));
    }
    let selected_setup = PathBuf::from(std::mem::take(&mut request.selected_setup));
    if !selected_setup.is_absolute() || selected_setup.extension().and_then(|ext| ext.to_str())
        .is_none_or(|ext| !ext.eq_ignore_ascii_case("exe"))
    { return not_started(&id, "invalid_request", true); }
    let input = local_ui::LocalInstallRequest { selected_setup, action: request.action,
        password: std::mem::take(&mut request.password), start_after_commit: request.start_after_commit,
        allow_virtual_display: request.allow_virtual_display, lock_on_disconnect: request.lock_on_disconnect,
        allow_privacy: request.allow_privacy, allow_remote_restart: request.allow_remote_restart };
    let launched = runtime.spawn(async move { local_ui::begin_explicit(input, provider).await }).await;
    match launched {
        Ok(Ok(job)) => {
            let mut guard = registry().lock().unwrap();
            let Some(entry) = guard.as_mut().filter(|entry| entry.reply.job_id == id) else {
                job.cancel(); return Reply::empty(false, "unconfirmed").json();
            };
            if cancelled.load(Ordering::Acquire) { job.cancel(); }
            entry.job = Some(job);
            // This reply acknowledges the original queued job only. Actual native
            // progress and completion are obtained by Status/Current and real join.
            entry.reply.json()
        }
        Ok(Err(_)) => not_started(&id, "launch_not_started", true),
        Err(_) => not_started(&id, "unconfirmed", false),
    }
}
pub(super) async fn cancel(id: &str) -> Reply {
    let previous = query(Some(id)).await;
    if !previous.ok || previous.terminal() { return previous; }
    let guard = registry().lock().unwrap();
    let Some(entry) = guard.as_ref().filter(|entry| entry.reply.job_id == id) else {
        return Reply::empty(false, "unknown_job");
    };
    entry.cancelled.store(true, Ordering::Release);
    if let Some(job) = &entry.job { job.cancel(); }
    let mut reply = snapshot(entry); reply.reason = "cancel_requested".into(); reply
}
