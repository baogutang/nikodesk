//! Ordinary client stays non-elevated. The selected setup is separately launched
//! through UAC; only that setup's kernel-bound native confirmation can grant.
use super::{
    broker_origin::{require_visible_ordinary_ui, SelectedSetup},
    wire::{self, Packet, SnapshotProvider},
};
use ::windows::{
    core::PCWSTR,
    Win32::{
        Foundation::{CloseHandle, HANDLE, WAIT_TIMEOUT},
        System::{
            Com::{
                CoInitializeEx, CoUninitialize, COINIT_APARTMENTTHREADED, COINIT_DISABLE_OLE1DDE,
            },
            Pipes::GetNamedPipeServerProcessId,
            Threading::{GetCurrentProcessId, GetProcessId, WaitForSingleObject},
        },
        UI::{
            Shell::{
                ShellExecuteExW, SEE_MASK_NOASYNC, SEE_MASK_NOCLOSEPROCESS, SHELLEXECUTEINFOW,
            },
            WindowsAndMessaging::{
                GetForegroundWindow, MessageBoxW, IDYES, MB_DEFBUTTON2, MB_ICONWARNING, MB_YESNO,
                SW_SHOWNORMAL,
            },
        },
    },
};
use hbb_common::{
    anyhow::{anyhow, bail, Result},
    serde_derive::Serialize,
    tokio::{
        self,
        time::{sleep, Duration},
    },
};
use std::{
    os::windows::io::AsRawHandle,
    path::PathBuf,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex, OnceLock,
    },
    time::Instant,
};

static INSTALL_ACTIVE: AtomicBool = AtomicBool::new(false);
static RETIRED: OnceLock<Mutex<Vec<tokio::task::JoinHandle<Result<()>>>>> = OnceLock::new();
struct Lease;
impl Lease {
    fn acquire() -> Result<Self> {
        INSTALL_ACTIVE
            .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
            .map_err(|_| anyhow!("install_job_busy"))?;
        Ok(Self)
    }
}
impl Drop for Lease {
    fn drop(&mut self) {
        INSTALL_ACTIVE.store(false, Ordering::Release);
    }
}
struct Kernel(HANDLE);
unsafe impl Send for Kernel {}
impl Drop for Kernel {
    fn drop(&mut self) {
        unsafe {
            let _ = CloseHandle(self.0);
        }
    }
}
struct Com;
impl Drop for Com {
    fn drop(&mut self) {
        unsafe {
            CoUninitialize();
        }
    }
}
struct Launch {
    process: Kernel,
    selected: SelectedSetup,
    pid: u32,
}
impl Launch {
    fn exited(&self) -> Result<bool> {
        let wait = unsafe { WaitForSingleObject(self.process.0, 0) };
        if wait == WAIT_TIMEOUT {
            Ok(false)
        } else if wait.0 == 0 {
            Ok(true)
        } else {
            bail!("install_setup_wait_unconfirmed")
        }
    }
    fn verify_server(&mut self, pipe: HANDLE) -> Result<()> {
        if self.exited()? || unsafe { GetProcessId(self.process.0) } != self.pid {
            bail!("install_setup_process_changed");
        }
        let mut server = 0;
        unsafe {
            GetNamedPipeServerProcessId(pipe, &mut server)?;
        }
        if server != self.pid {
            bail!("install_setup_pipe_server_changed");
        }
        self.selected.validate_process(self.process.0)?;
        let mut repeated = 0;
        unsafe {
            GetNamedPipeServerProcessId(pipe, &mut repeated)?;
        }
        if repeated != self.pid || self.exited()? {
            bail!("install_setup_process_changed");
        }
        Ok(())
    }
}
fn wide(text: &str) -> Vec<u16> {
    text.encode_utf16().chain(Some(0)).collect()
}
fn launch(
    mut selected: SelectedSetup,
    nonce: [u8; 32],
    cancelled: &AtomicBool,
    dispatch_started: &AtomicBool,
) -> Result<Launch> {
    require_visible_ordinary_ui()?;
    let caption = wide("NikoDesk — 选择专用安装器");
    let body=wide(&format!("您选择了此安装程序，下一步 Windows 将显示 UAC。普通 NikoDesk 客户端不会提权。\r\n\r\n路径：{}\r\n本次文件 SHA256：{}\r\n\r\n仅显示本次选择文件的指纹；此步骤没有确认可信发布者。未签名验证版必须由您明确信任。专用安装器还会再次显示独立机器身份、服务和私服的本机确认。是否继续？",selected.path().display(),selected.digest_hex()));
    let hwnd = unsafe { GetForegroundWindow() };
    if unsafe {
        MessageBoxW(
            Some(hwnd),
            PCWSTR(body.as_ptr()),
            PCWSTR(caption.as_ptr()),
            MB_YESNO | MB_DEFBUTTON2 | MB_ICONWARNING,
        )
    } != IDYES
        || cancelled.load(Ordering::Acquire)
    {
        bail!("install_local_selection_declined");
    }
    require_visible_ordinary_ui()?;
    unsafe {
        CoInitializeEx(None, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE).ok()?;
    }
    let _com = Com;
    use std::os::windows::ffi::OsStrExt;
    let file: Vec<u16> = selected
        .path()
        .as_os_str()
        .encode_wide()
        .chain(Some(0))
        .collect();
    let verb = wide("runas");
    let nonce_text: String = nonce.iter().map(|b| format!("{b:02x}")).collect();
    let args = wide(&format!("--broker {nonce_text} --ui-pid {}", unsafe {
        GetCurrentProcessId()
    }));
    let mut info = SHELLEXECUTEINFOW {
        cbSize: std::mem::size_of::<SHELLEXECUTEINFOW>() as u32,
        fMask: SEE_MASK_NOCLOSEPROCESS | SEE_MASK_NOASYNC,
        hwnd,
        lpVerb: PCWSTR(verb.as_ptr()),
        lpFile: PCWSTR(file.as_ptr()),
        lpParameters: PCWSTR(args.as_ptr()),
        nShow: SW_SHOWNORMAL.0,
        ..Default::default()
    };
    dispatch_started.store(true, Ordering::Release);
    unsafe {
        ShellExecuteExW(&mut info)?;
    }
    if info.hProcess.0.is_null() {
        bail!("install_setup_process_handle_missing");
    }
    let process = Kernel(info.hProcess);
    let pid = unsafe { GetProcessId(process.0) };
    // Do not drop a successfully launched process if this validation fails. The
    // async owner waits for its actual exit and never sends it a password.
    let _ = &mut selected;
    Ok(Launch {
        process,
        selected,
        pid,
    })
}

fn failed_launch_status(dispatch_started: bool) -> Status {
    Status {
        phase: if dispatch_started {
            "recovery_unconfirmed"
        } else {
            "launch_not_started"
        }
        .into(),
        quiescent: !dispatch_started,
        process_exited: !dispatch_started,
        machine_id: String::new(),
    }
}

pub(crate) struct LocalInstallRequest {
    pub(crate) action: super::policy::Action,
    pub(crate) selected_setup: PathBuf,
    pub(crate) password: String,
    pub(crate) start_after_commit: bool,
    pub(crate) allow_virtual_display: bool,
    pub(crate) lock_on_disconnect: bool,
    pub(crate) allow_privacy: bool,
    pub(crate) allow_remote_restart: bool,
}
impl Drop for LocalInstallRequest {
    fn drop(&mut self) {
        unsafe {
            hbb_common::sodiumoxide::utils::memzero(self.password.as_bytes_mut());
        }
    }
}
#[derive(Clone, Serialize)]
pub(crate) struct Status {
    pub(crate) phase: String,
    pub(crate) quiescent: bool,
    pub(crate) process_exited: bool,
    pub(crate) machine_id: String,
}
pub(crate) struct FinishResult {
    pub(crate) status: Status,
    pub(crate) task_joined: bool,
    pub(crate) succeeded: bool,
}
pub(crate) struct InstallJob {
    cancelled: Arc<AtomicBool>,
    status: Arc<Mutex<Status>>,
    task: Option<tokio::task::JoinHandle<Result<()>>>,
}
impl InstallJob {
    pub(crate) fn status(&self) -> Status {
        self.status.lock().unwrap().clone()
    }
    pub(crate) fn is_finished(&self) -> bool {
        self.task.as_ref().is_some_and(|task| task.is_finished())
    }
    pub(crate) fn cancel(&self) {
        self.cancelled.store(true, Ordering::Release);
    }
    pub(crate) async fn finish_with_status(mut self) -> FinishResult {
        let (task_joined, succeeded) = match self.task.take() {
            Some(task) => match task.await {
                Ok(Ok(())) => (true, true),
                Ok(Err(_)) => (true, false),
                Err(_) => (false, false),
            },
            None => (false, false),
        };
        FinishResult {
            status: self.status(),
            task_joined,
            succeeded,
        }
    }
    pub(crate) async fn finish(mut self) -> Result<()> {
        self.task
            .take()
            .ok_or_else(|| anyhow!("install_job_already_joined"))?
            .await
            .map_err(|_| anyhow!("install_job_exit_unconfirmed"))?
    }
}
impl Drop for InstallJob {
    fn drop(&mut self) {
        self.cancel();
        if let Some(task) = self.task.take() {
            // No dropped JoinHandle/false Stop ACK. This bounded registry (one active
            // setup) retains actual task/process ownership after its UI owner exits.
            RETIRED
                .get_or_init(|| Mutex::new(Vec::new()))
                .lock()
                .unwrap()
                .push(task);
        }
    }
}
pub(crate) fn retained_job_count() -> usize {
    RETIRED
        .get_or_init(|| Mutex::new(Vec::new()))
        .lock()
        .unwrap()
        .iter()
        .filter(|task| !task.is_finished())
        .count()
}
fn set_status(status: &Mutex<Status>, phase: &str, quiescent: bool, exited: bool) {
    *status.lock().unwrap() = Status {
        phase: phase.into(),
        quiescent,
        process_exited: exited,
        machine_id: String::new(),
    };
}
async fn read_current(provider: &SnapshotProvider) -> Result<wire::CurrentServerSnapshot> {
    let owned = Arc::clone(provider);
    tokio::task::spawn_blocking(move || owned.read_current_verified())
        .await
        .map_err(|_| anyhow!("install_current_snapshot_worker_unconfirmed"))?
}
async fn serve(
    launch: &mut Launch,
    request: &mut LocalInstallRequest,
    provider: &SnapshotProvider,
    nonce: [u8; 32],
    cancelled: &AtomicBool,
    status: &Mutex<Status>,
) -> Result<()> {
    let deadline = Instant::now() + std::time::Duration::from_secs(60);
    let mut pipe = loop {
        if cancelled.load(Ordering::Acquire) || launch.exited()? {
            bail!("install_handoff_cancelled");
        }
        match tokio::net::windows::named_pipe::ClientOptions::new().open(wire::pipe_name(&nonce)) {
            Ok(pipe) => break pipe,
            Err(error)
                if matches!(error.raw_os_error(), Some(2 | 231)) && Instant::now() < deadline =>
            {
                sleep(Duration::from_millis(100)).await
            }
            Err(_) => bail!("install_handoff_pipe_unavailable"),
        }
    };
    launch.verify_server(HANDLE(pipe.as_raw_handle()))?;
    let current = read_current(provider).await?;
    current.validate()?;
    wire::write_packet(
        &mut pipe,
        &Packet::Begin {
            action: request.action,
            sequence: 1,
            nonce,
            current: current.clone(),
            password: std::mem::take(&mut request.password),
            start_after_commit: request.start_after_commit,
            allow_virtual_display: request.allow_virtual_display,
            lock_on_disconnect: request.lock_on_disconnect,
            allow_privacy: request.allow_privacy,
            allow_remote_restart: request.allow_remote_restart,
        },
    )
    .await?;
    let mut sequence = 1u64;
    let mut cancellation_sent = false;
    loop {
        if cancelled.load(Ordering::Acquire) && !cancellation_sent {
            wire::write_packet(&mut pipe, &Packet::Cancel { sequence, nonce }).await?;
            cancellation_sent = true;
        }
        launch.verify_server(HANDLE(pipe.as_raw_handle()))?;
        let packet = wire::read_packet(&mut pipe).await?;
        match &packet {
            Packet::Read {
                sequence: next,
                nonce: bound,
            } => {
                let expected = sequence
                    .checked_add(1)
                    .ok_or_else(|| anyhow!("install_sequence_exhausted"))?;
                wire::expect_sequence(*next, expected, bound, &nonce)?;
                sequence = expected;
                if cancelled.load(Ordering::Acquire) {
                    wire::write_packet(&mut pipe, &Packet::Cancel { sequence, nonce }).await?;
                    continue;
                }
                let actual = read_current(provider).await?;
                actual.validate()?;
                if actual != current {
                    bail!("install_private_server_snapshot_changed");
                }
                wire::write_packet(
                    &mut pipe,
                    &Packet::Snapshot {
                        sequence,
                        nonce,
                        current: actual,
                    },
                )
                .await?;
            }
            Packet::Progress {
                sequence: actual,
                nonce: bound,
                phase,
                quiescent,
                machine_id,
            } => {
                wire::expect_sequence(*actual, sequence, bound, &nonce)?;
                if !matches!(
                    phase.as_str(),
                    "awaiting_native_confirmation"
                        | "preflight"
                        | "roots"
                        | "journal"
                        | "payload"
                        | "disabled_service"
                        | "profile"
                        | "verify"
                        | "consent"
                        | "auto_start"
                        | "started"
                        | "complete"
                        | "recovery"
                        | "recovery_disabled"
                        | "install_recovered"
                ) {
                    bail!("install_progress_invalid");
                }
                let completed = phase == "complete" && *quiescent;
                if (completed && (machine_id.len() != 10 || !machine_id.bytes().all(|b| b.is_ascii_digit()) || machine_id.starts_with('0')))
                    || (!completed && !machine_id.is_empty()) {
                    bail!("install_machine_id_unconfirmed");
                }
                set_status(status, phase, false, false);
                if *quiescent && matches!(phase.as_str(), "complete" | "recovery_disabled" | "install_recovered") {
                    // Actual process exit is additionally required below.
                    while !launch.exited()? {
                        sleep(Duration::from_millis(100)).await;
                    }
                    set_status(status, phase, true, true);
                    if completed { status.lock().unwrap().machine_id = machine_id.clone(); }
                    return if matches!(phase.as_str(),"complete"|"install_recovered") {
                        Ok(())
                    } else {
                        Err(anyhow!("install_failed_recovery_disabled"))
                    };
                }
            }
            _ => bail!("install_packet_direction_invalid"),
        }
    }
}
/// Called by the real explicit ordinary local UI action. It does not consume
/// setup embedded pins (the GUI is built before them) and cannot mint a grant.
pub(crate) async fn begin_explicit(
    mut request: LocalInstallRequest,
    provider: SnapshotProvider,
) -> Result<InstallJob> {
    RETIRED
        .get_or_init(|| Mutex::new(Vec::new()))
        .lock()
        .unwrap()
        .retain(|task| !task.is_finished());
    let lease = Lease::acquire()?;
    if (request.action.accepts_password() && request.password.trim().is_empty())
        || request.password.chars().count() > 128
        || (!request.action.accepts_password() && !request.password.is_empty())
        || (!request.action.accepts_start() && request.start_after_commit)
        || (!request.action.accepts_session_policies() &&
            (request.allow_virtual_display || request.lock_on_disconnect || request.allow_privacy || request.allow_remote_restart)) {
        bail!("explicit_unattended_password_required");
    }
    let status = Arc::new(Mutex::new(Status {
        phase: "awaiting_native_confirmation".into(),
        quiescent: false,
        process_exited: false,
        machine_id: String::new(),
    }));
    let cancelled = Arc::new(AtomicBool::new(false));
    let state = Arc::clone(&status);
    let cancel = Arc::clone(&cancelled);
    let nonce: [u8; 32] = hbb_common::sodiumoxide::randombytes::randombytes(32)
        .try_into()
        .map_err(|_| anyhow!("install_nonce_generation_failed"))?;
    let task = tokio::spawn(async move {
        let _lease = lease;
        let path = std::mem::take(&mut request.selected_setup);
        let token = Arc::clone(&cancel);
        let dispatch_started = Arc::new(AtomicBool::new(false));
        let dispatched = Arc::clone(&dispatch_started);
        let launched = tokio::task::spawn_blocking(move || {
            launch(SelectedSetup::open(path)?, nonce, &token, &dispatched)
        })
        .await;
        let mut launch = match launched {
            Ok(Ok(value)) => value,
            _ => {
                *state.lock().unwrap() =
                    failed_launch_status(dispatch_started.load(Ordering::Acquire));
                return Err(anyhow!("install_launch_unconfirmed"));
            }
        };
        let result = serve(&mut launch, &mut request, &provider, nonce, &cancel, &state).await;
        if !state.lock().unwrap().process_exited {
            // EOF, cancel, timeout and invalid packets never imply SCM stopped.
            // Retain the exact launched process until it has actually exited.
            set_status(&state, "recovery_unconfirmed", false, false);
            loop {
                match launch.exited() {
                    Ok(true) => break,
                    Ok(false) | Err(_) => sleep(Duration::from_millis(100)).await,
                }
            }
            set_status(&state, "recovery_unconfirmed", false, true);
        }
        result
    });
    Ok(InstallJob {
        cancelled,
        status,
        task: Some(task),
    })
}
