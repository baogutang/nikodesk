//! FRB 1.x worker-thread entry points use the existing Flutter async runner.
use super::voice_session::{self, Input};
use crate::flutter_ffi::SessionID;
use hbb_common::tokio;
use std::{future::Future, sync::{atomic::{AtomicBool, Ordering}, mpsc, Arc}, time::{Duration, Instant}};

const WAIT: Duration = Duration::from_secs(5);

fn dispatch<F>(deadline: Instant, cancelled: Arc<AtomicBool>, future: F) -> Result<String, &'static str>
where F: Future<Output = String> + Send + 'static {
    // A normal FRB call runs on its worker pool. Reject any unexpected async
    // caller rather than blocking a Tokio thread or creating another runtime.
    if tokio::runtime::Handle::try_current().is_ok() { return Err("worker_failed"); }
    let runtime = super::server_settings::flutter_runtime().ok_or("runtime_unavailable")?;
    let (sender, receiver) = mpsc::sync_channel(1);
    let task = runtime.spawn(async move {
        let result = future.await;
        let _ = sender.try_send(result);
    });
    match receiver.recv_timeout(deadline.saturating_duration_since(Instant::now())) {
        Ok(result) => Ok(result),
        Err(mpsc::RecvTimeoutError::Timeout) => {
            cancelled.store(true, Ordering::Release);
            task.abort();
            Err("timeout")
        },
        Err(mpsc::RecvTimeoutError::Disconnected) => Err("worker_failed"),
    }
}

pub(crate) fn session(session_id: SessionID, input: Input) -> String {
    let operation = input.clone();
    let deadline = Instant::now() + WAIT;
    let cancelled = Arc::new(AtomicBool::new(false));
    let pending_cancel = cancelled.clone();
    dispatch(deadline, cancelled, async move { voice_session::submit(session_id, operation, deadline, pending_cancel).await })
        .unwrap_or_else(|reason| voice_session::error(&input, reason))
}

#[cfg(any(target_os = "macos", target_os = "windows"))]
pub(crate) fn cm_availability(identity: String) -> String {
    dispatch(Instant::now() + WAIT, Arc::new(AtomicBool::new(false)), async move { crate::ui_cm_interface::nikodesk_voice_availability(identity).await })
        .unwrap_or_else(|reason| voice_session::Availability::disabled(reason).json())
}
