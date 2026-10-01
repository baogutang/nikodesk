//! Niko-only Windows MF provider. A caller must establish its own explicit
//! current-user capability before probing or starting an exact selection.
//! Discovery and permission reads never request access or activate a source.
use std::{
    io,
    sync::{atomic::AtomicBool, Arc, Mutex},
    time::{Duration, Instant},
};
#[path = "windows_camera/layout.rs"]
mod layout;
#[path = "windows_camera/lease.rs"]
mod lease;
#[path = "windows_camera/model.rs"]
mod model;
#[path = "windows_camera/native.rs"]
mod native;
#[path = "windows_camera/owner.rs"]
mod owner;
#[path = "windows_camera/state.rs"]
mod state;
pub(crate) use layout::OwnedFrame;
pub use model::{CameraAuthorization, CameraDevice, CameraFormat, CaptureSelection, Code, Failure};
use state::{PendingAction, Shared};

const DEADLINE: Duration = Duration::from_secs(5);
// A timed-out or failed cleanup stays here with the actual worker and source.
// Never advertise stop or allow a replacement while the owner is unresolved.
static OWNER: Mutex<Option<Arc<Owner>>> = Mutex::new(None);
type Owner = owner::Owner<Payload>;
enum Payload {
    Devices(Vec<CameraDevice>),
    Probe(CameraDevice),
}
enum Job {
    Devices,
    Probe { id: String, epoch: u64 },
    Capture(CaptureSelection),
}

fn spawn(job: Job, epoch: u64) -> Result<Arc<Owner>, Failure> {
    let mut registry = OWNER.lock().unwrap();
    if let Some(old) = registry.as_ref() {
        if old
            .shared
            .state
            .lock()
            .unwrap()
            .stop_ack(old.join_finished()?)
            .is_err()
        {
            return Err(Failure::new(Code::Busy));
        }
    }
    let owner = Arc::new(Owner {
        shared: Arc::new(Shared::new(epoch)),
        thread: Mutex::new(None),
        result: Mutex::new(None),
        join_failed: AtomicBool::new(false),
    });
    let shared = owner.shared.clone();
    let result_owner = owner.clone();
    let worker = std::thread::Builder::new()
        .name("NikoCameraMF".into())
        .spawn(move || native::run(job, shared, result_owner))
        .map_err(|_| Failure::new(Code::Native))?;
    *owner.thread.lock().unwrap() = Some(worker);
    *registry = Some(owner.clone());
    Ok(owner)
}
/// A fresh MTA on the caller's behalf; no OS prompt and no camera source.
pub fn authorization_status() -> io::Result<CameraAuthorization> {
    native::authorization_status().map_err(Failure::io)
}
pub(crate) fn enumerate() -> io::Result<Vec<CameraDevice>> {
    match spawn(Job::Devices, 0)
        .and_then(|o| o.wait_payload())
        .map_err(Failure::io)?
    {
        Payload::Devices(devices) => Ok(devices),
        _ => Err(Failure::new(Code::Native).io()),
    }
}
/// Explicit local approval to probe this UID is required. Format enumeration
/// needs a real source; the result is returned only after Shutdown and join.
pub(crate) fn probe_approved_formats(id: &str, epoch: u64) -> io::Result<CameraDevice> {
    model::validate_id(id, epoch).map_err(Failure::io)?;
    match spawn(
        Job::Probe {
            id: id.into(),
            epoch,
        },
        epoch,
    )
    .and_then(|o| o.wait_payload())
    .map_err(Failure::io)?
    {
        Payload::Probe(device) => Ok(device),
        _ => Err(Failure::new(Code::Native).io()),
    }
}
/// Only after the probe/constructor invocation has actually returned (a dropped
/// async JoinHandle is insufficient). `epoch` is the core's process-unique,
/// never-reused native lease, independent of wire/capability epoch.
pub(crate) fn stop_pending_capture(epoch: u64) -> io::Result<()> {
    if epoch == 0 {
        return Err(Failure::new(Code::Stale).io());
    }
    let owner = OWNER.lock().unwrap().as_ref().cloned();
    if let Some(owner) = owner {
        if owner.shared.state.lock().unwrap().epoch != epoch {
            return Ok(());
        }
        let joined = owner.join_finished().map_err(Failure::io)?;
        {
            let state = owner.shared.state.lock().unwrap();
            // No owner was ever registered for this call's lease, or its old
            // owner was reaped only after real cleanup. Do not touch another.
            match state.pending_action(epoch, joined) {
                PendingAction::NoOwner | PendingAction::Cleaned => return Ok(()),
                PendingAction::Delivered => return Err(Failure::new(Code::Busy).io()),
                PendingAction::Pending => (),
            }
        }
        owner.shared.cancel_pending().map_err(Failure::io)?;
        owner.stop(DEADLINE).map_err(Failure::io)?;
    }
    Ok(())
}
pub(crate) struct CameraSession {
    owner: Arc<Owner>,
    epoch: u64,
}
impl CameraSession {
    pub(crate) fn start(selection: &CaptureSelection) -> io::Result<Self> {
        selection.validate()?;
        let owner = spawn(Job::Capture(selection.clone()), selection.epoch).map_err(Failure::io)?;
        let deadline = Instant::now() + DEADLINE;
        loop {
            let mut state = owner.shared.state.lock().unwrap();
            if let Some(error) = state.error {
                drop(state);
                owner.stop(DEADLINE).map_err(Failure::io)?;
                return Err(error.io());
            }
            if state.first_frame && owner.shared.open() {
                state.delivered = true;
                return Ok(Self {
                    owner: owner.clone(),
                    epoch: selection.epoch,
                });
            }
            if Instant::now() >= deadline {
                drop(state);
                owner.stop(DEADLINE).map_err(Failure::io)?;
                return Err(Failure::new(Code::StartPending).io());
            }
            let _ = owner
                .shared
                .changed
                .wait_timeout(state, Duration::from_millis(25))
                .unwrap();
        }
    }
    pub(crate) fn frame(&mut self, timeout: Duration) -> io::Result<OwnedFrame> {
        let deadline = Instant::now() + timeout.min(Duration::from_secs(30));
        loop {
            let mut state = self.owner.shared.state.lock().unwrap();
            if let Some(error) = state.error {
                return Err(error.io());
            }
            if !self.owner.shared.open() {
                return Err(Failure::new(Code::Closed).io());
            }
            if let Some(frame) = state.latest.take() {
                if frame.epoch == self.epoch {
                    return Ok(frame);
                }
                return Err(Failure::new(Code::Stale).io());
            }
            let now = Instant::now();
            if now >= deadline {
                return Err(io::Error::new(
                    io::ErrorKind::WouldBlock,
                    "Niko camera frame pending",
                ));
            }
            let _ = self
                .owner
                .shared
                .changed
                .wait_timeout(state, deadline - now)
                .unwrap();
        }
    }
    pub(crate) fn stop(&mut self) -> io::Result<()> {
        self.owner.stop(DEADLINE).map_err(Failure::io)
    }
}
impl Drop for CameraSession {
    fn drop(&mut self) {
        let _ = self.owner.stop(DEADLINE); /* OWNER retains unresolved cleanup. */
    }
}
