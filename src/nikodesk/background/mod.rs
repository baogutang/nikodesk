//! Dedicated background entry. It is never reached by ordinary client CLI/IPC.
mod policy;
mod protocol;
#[cfg(windows)]
mod windows;
#[cfg(windows)]
mod worker;

use hbb_common::{bail, ResultType};
use std::sync::{
    atomic::{AtomicBool, Ordering},
    OnceLock,
};
static WORKER: OnceLock<policy::Binding> = OnceLock::new();
static WORKER_ACTIVE: AtomicBool = AtomicBool::new(false);
static CORE_BOOTSTRAPPED: AtomicBool = AtomicBool::new(false);

pub(crate) fn is_system_worker() -> bool {
    WORKER.get().is_some()
}
pub(crate) fn worker_active() -> bool {
    is_system_worker() && WORKER_ACTIVE.load(Ordering::Acquire)
}
#[cfg(windows)]
fn enter_worker(binding: policy::Binding) -> ResultType<()> {
    WORKER
        .set(binding)
        .map_err(|_| hbb_common::anyhow::anyhow!("Background worker role already selected"))?;
    Ok(())
}
pub(crate) fn revoke_worker() {
    WORKER_ACTIVE.store(false, Ordering::Release);
}
pub(crate) fn core_bootstrap_ready() {
    if is_system_worker() {
        CORE_BOOTSTRAPPED.store(true, Ordering::Release);
    }
}
#[cfg(windows)]
pub(crate) fn desktop_matches() -> bool {
    worker::desktop_matches()
}
#[cfg(not(windows))]
pub(crate) fn desktop_matches() -> bool {
    !is_system_worker()
}
pub(crate) fn worker_input_ready() -> bool {
    if !is_system_worker() {
        return true;
    }
    if worker_active() && desktop_matches() {
        true
    } else {
        revoke_worker();
        false
    }
}
#[cfg(windows)]
pub(crate) use worker::connection_status;

/// A dedicated binary may dispatch SCM or its fixed child worker only.
pub fn run(arguments: Vec<String>) -> ResultType<()> {
    #[cfg(windows)]
    {
        return windows::run(arguments);
    }
    #[cfg(not(windows))]
    {
        let _ = arguments;
        bail!("NikoDeskHost is available on Windows only");
    }
}
