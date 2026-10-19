//! A launchd user agent reuses the signed NikoDesk application/core and TCC identity.
//! No root daemon, copied key, public rendezvous or alternative capture core.
use hbb_common::{anyhow::anyhow, bail, config::Config, libc, ResultType};
use std::{
    fs::{File, OpenOptions},
    os::unix::fs::{MetadataExt, OpenOptionsExt},
    sync::{
        atomic::{AtomicBool, Ordering},
        Mutex,
    },
    time::Duration,
};
static SELECTED: AtomicBool = AtomicBool::new(false);
static CORE_OWNER: Mutex<Option<File>> = Mutex::new(None);
extern "C" {
    fn NikoMacBackgroundEnvironment() -> bool;
    fn NikoMacBackgroundRunLoop();
}
pub(crate) fn selected() -> bool {
    SELECTED.load(Ordering::Acquire)
}
pub(crate) fn active_user() -> bool {
    unsafe { NikoMacBackgroundEnvironment() }
}

/// GUI and agent contend for one OS-held core lease. An agent never kills an
/// existing GUI; a GUI attaches to the same authenticated private IPC core.
pub(crate) fn claim_core() -> ResultType<bool> {
    let mut owner = CORE_OWNER
        .lock()
        .map_err(|_| anyhow!("core_owner_unavailable"))?;
    if owner.is_some() {
        return Ok(false);
    }
    let path = Config::file().with_extension("core.lock");
    let file = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(path)?;
    let meta = file.metadata()?;
    if !meta.is_file()
        || meta.nlink() != 1
        || meta.uid() != unsafe { libc::geteuid() }
        || meta.mode() & 0o077 != 0
    {
        bail!("unsafe_core_owner_file");
    }
    use std::os::fd::AsRawFd;
    if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
        let error = std::io::Error::last_os_error();
        if error.kind() == std::io::ErrorKind::WouldBlock {
            return Ok(false);
        }
        return Err(error.into());
    }
    *owner = Some(file);
    Ok(true)
}
/// Why the agent cannot serve yet, if anything. Every condition can change
/// later through the app or the system, so the agent waits rather than exits.
fn not_ready() -> Option<String> {
    if !active_user() {
        return Some("ordinary_aqua_session_required".into());
    }
    if let Err(error) = super::validate_active_private_server() {
        return Some(error.to_string());
    }
    if !Config::has_permanent_password()
        || Config::get_option("approve-mode") != "password"
        || Config::get_option("verification-method") != "use-permanent-password"
    {
        return Some("explicit_unattended_policy_required".into());
    }
    if !crate::platform::is_can_screen_recording(false)
        || !crate::platform::is_process_trusted(false)
    {
        return Some("local_system_permissions_required".into());
    }
    None
}

/// Exiting here made launchd (KeepAlive) start the agent again every few
/// seconds for as long as a condition stayed unmet, for example after an
/// update cleared the privacy grants. Wait in the process instead, logging
/// each new reason once, so a later fix still takes effect without a login.
fn wait_until_ready() {
    let mut logged: Option<String> = None;
    while let Some(reason) = not_ready() {
        if logged.as_deref() != Some(reason.as_str()) {
            hbb_common::log::warn!("Background agent waiting: {reason}");
            logged = Some(reason);
        }
        std::thread::sleep(Duration::from_secs(30));
    }
    if logged.is_some() {
        hbb_common::log::info!("Background agent ready");
    }
}

pub(crate) fn run() -> ResultType<()> {
    if unsafe { libc::geteuid() } == 0 {
        bail!("ordinary_aqua_session_required");
    }
    wait_until_ready();
    SELECTED.store(true, Ordering::Release);
    // This is the real upstream core, including authentication/2FA and CM.
    // The non-server branch attaches if the GUI already owns it.
    std::thread::Builder::new()
        .name("niko-agent-core".into())
        .spawn(|| loop {
            if !active_user() {
                std::process::exit(1);
            }
            // If the GUI was the owner and exits, this exact private IPC probe
            // starts the real core. It cannot replace a held core lease.
            crate::start_server(false, false);
            std::thread::sleep(Duration::from_secs(2));
        })?;
    // ScreenCaptureKit and the privacy/permission bridges need the real main
    // AppKit loop. A sleeping Rust main thread would deadlock their callbacks.
    unsafe {
        NikoMacBackgroundRunLoop();
    }
    bail!("background_main_loop_ended")
}
