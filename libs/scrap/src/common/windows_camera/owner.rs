//! Production thread ownership and join acknowledgement, with no device calls.
use super::{state::Shared, Code, Failure, DEADLINE};
use std::sync::Arc;
use std::{
    sync::{
        atomic::{AtomicBool, Ordering},
        Mutex,
    },
    thread::JoinHandle,
    time::{Duration, Instant},
};
pub(super) struct Owner<T> {
    pub(super) shared: Arc<Shared>,
    pub(super) thread: Mutex<Option<JoinHandle<()>>>,
    pub(super) result: Mutex<Option<Result<T, Failure>>>,
    pub(super) join_failed: AtomicBool,
}
impl<T> Owner<T> {
    pub(super) fn join_finished(&self) -> Result<bool, Failure> {
        let mut thread = self.thread.lock().unwrap();
        if self.join_failed.load(Ordering::Acquire) {
            return Err(Failure::new(Code::StopPending));
        }
        if thread.as_ref().is_some_and(|t| !t.is_finished()) {
            return Ok(false);
        }
        if let Some(t) = thread.take() {
            if t.join().is_err() {
                self.join_failed.store(true, Ordering::Release);
                return Err(Failure::new(Code::StopPending));
            }
        }
        Ok(true)
    }
    pub(super) fn stop(&self, timeout: Duration) -> Result<(), Failure> {
        self.shared.cancel();
        let deadline = Instant::now() + timeout;
        loop {
            let joined = self.join_finished()?;
            let state = self.shared.state.lock().unwrap();
            if state.stop_ack(joined).is_ok() {
                return Ok(());
            }
            let now = Instant::now();
            if now >= deadline {
                return Err(Failure::new(Code::StopPending));
            }
            let _ = self
                .shared
                .changed
                .wait_timeout(state, (deadline - now).min(Duration::from_millis(25)))
                .unwrap();
        }
    }
    pub(super) fn wait_payload(&self) -> Result<T, Failure> {
        let deadline = Instant::now() + DEADLINE;
        loop {
            let joined = self.join_finished()?;
            let state = self.shared.state.lock().unwrap();
            if state.stop_ack(joined).is_ok() {
                return self
                    .result
                    .lock()
                    .unwrap()
                    .take()
                    .unwrap_or_else(|| Err(Failure::new(Code::Native)));
            }
            if let Some(error) = state.error {
                drop(state);
                self.stop(DEADLINE)?;
                return Err(error);
            }
            if Instant::now() >= deadline {
                drop(state);
                self.stop(DEADLINE)?;
                return Err(Failure::new(Code::StartPending));
            }
            let _ = self
                .shared
                .changed
                .wait_timeout(state, Duration::from_millis(25))
                .unwrap();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::mpsc;
    fn owner() -> Arc<Owner<()>> {
        Arc::new(Owner {
            shared: Arc::new(Shared::new(1)),
            thread: Mutex::new(None),
            result: Mutex::new(None),
            join_failed: AtomicBool::new(false),
        })
    }
    #[test]
    fn actual_thread_is_retained_on_timeout_then_joined_before_ack() {
        let o = owner();
        let s = o.shared.clone();
        let (tx, rx) = mpsc::channel();
        *o.thread.lock().unwrap() = Some(std::thread::spawn(move || {
            rx.recv().unwrap();
            let mut state = s.state.lock().unwrap();
            state.shutdown_ack = true;
            state.runtime_ack = true;
            state.finished = true;
            s.changed.notify_all();
        }));
        assert_eq!(
            o.stop(Duration::from_millis(1)).unwrap_err().code,
            Code::StopPending
        );
        assert!(o.thread.lock().unwrap().is_some());
        assert!(!o.join_finished().unwrap());
        tx.send(()).unwrap();
        assert!(o.stop(Duration::from_secs(2)).is_ok());
        assert!(o.thread.lock().unwrap().is_none());
    }
    #[test]
    fn cleanup_flags_before_worker_exit_cannot_fake_join() {
        let o = owner();
        let s = o.shared.clone();
        let (ready_tx, ready_rx) = mpsc::channel();
        let (tx, rx) = mpsc::channel();
        *o.thread.lock().unwrap() = Some(std::thread::spawn(move || {
            {
                let mut state = s.state.lock().unwrap();
                state.shutdown_ack = true;
                state.runtime_ack = true;
                state.finished = true;
            }
            ready_tx.send(()).unwrap();
            rx.recv().unwrap();
        }));
        ready_rx.recv().unwrap();
        assert!(o.stop(Duration::from_millis(1)).is_err());
        tx.send(()).unwrap();
        assert!(o.stop(Duration::from_secs(2)).is_ok());
    }
    #[test]
    fn uncertain_native_unlock_or_last_com_release_blocks_ack() {
        let o = owner();
        let mut s = o.shared.state.lock().unwrap();
        s.shutdown_ack = true;
        s.runtime_ack = true;
        s.finished = true;
        s.callback_attached = true;
        assert!(s.stop_ack(true).is_err());
        s.callback_released = true;
        s.buffer_uncertain = true;
        assert!(s.stop_ack(true).is_err());
    }
    #[test]
    fn a_failed_actual_join_remains_unconfirmed_on_every_retry() {
        let o = owner();
        let s = o.shared.clone();
        *o.thread.lock().unwrap() = Some(std::thread::spawn(move || {
            {
                let mut state = s.state.lock().unwrap();
                state.shutdown_ack = true;
                state.runtime_ack = true;
                state.finished = true;
            }
            panic!("synthetic post-cleanup worker failure");
        }));
        assert!(o.stop(Duration::from_secs(2)).is_err());
        assert!(o.stop(Duration::from_millis(1)).is_err());
    }
}
