//! No-device lifecycle and bounded latest-frame state, used by the real callback.
use super::{layout::OwnedFrame, Code, Failure};
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Condvar, Mutex,
};

pub struct State {
    pub epoch: u64,
    pub first_frame: bool,
    pub delivered: bool,
    pub latest: Option<OwnedFrame>,
    pub pending_read: bool,
    pub callbacks: usize,
    pub flush_requested: bool,
    pub flush_ack: bool,
    pub shutdown_ack: bool,
    pub runtime_ack: bool,
    pub buffer_uncertain: bool,
    pub callback_attached: bool,
    pub callback_released: bool,
    pub finished: bool,
    pub error: Option<Failure>,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PendingAction {
    NoOwner,
    Cleaned,
    Pending,
    Delivered,
}
pub struct Shared {
    pub cancelled: AtomicBool,
    execution: Mutex<()>,
    pub state: Mutex<State>,
    pub changed: Condvar,
}
impl Shared {
    pub fn new(epoch: u64) -> Self {
        Self {
            cancelled: AtomicBool::new(false),
            execution: Mutex::new(()),
            state: Mutex::new(State {
                epoch,
                first_frame: false,
                delivered: false,
                latest: None,
                pending_read: false,
                callbacks: 0,
                flush_requested: false,
                flush_ack: false,
                shutdown_ack: false,
                runtime_ack: false,
                buffer_uncertain: false,
                callback_attached: false,
                callback_released: false,
                finished: false,
                error: None,
            }),
            changed: Condvar::new(),
        }
    }
    pub fn open(&self) -> bool {
        !self.cancelled.load(Ordering::Acquire)
    }
    /// Native operations that have already entered may finish, but cancelled
    /// startup/probe work cannot issue a later activation/read. Never hold the
    /// callback-state mutex across COM (callbacks can run synchronously).
    pub fn execute<T>(&self, run: impl FnOnce() -> Result<T, Failure>) -> Result<T, Failure> {
        let _execution = self.execution.lock().unwrap();
        if !self.open() {
            return Err(Failure::new(Code::Closed));
        }
        run()
    }
    pub fn cancel_pending(&self) -> Result<(), Failure> {
        let mut state = self.state.lock().unwrap();
        // Delivery and pending cancellation share this mutex. A None error
        // path can never cancel an already handed-out native capturer.
        if state.delivered {
            return Err(Failure::new(Code::Busy));
        }
        self.cancelled.store(true, Ordering::Release);
        state.latest.take();
        self.changed.notify_all();
        Ok(())
    }
    pub fn cancel(&self) {
        self.cancelled.store(true, Ordering::Release);
        self.state.lock().unwrap().latest.take();
        self.changed.notify_all();
    }
    pub fn fail(&self, error: Failure) {
        self.cancelled.store(true, Ordering::Release);
        let mut state = self.state.lock().unwrap();
        state.error.get_or_insert(error);
        state.latest.take();
        self.changed.notify_all();
    }
    pub fn begin_read(&self) -> bool {
        let mut state = self.state.lock().unwrap();
        if !self.open() || state.pending_read || state.callbacks != 0 || state.flush_requested {
            return false;
        }
        state.pending_read = true;
        true
    }
    pub fn publish(&self, frame: OwnedFrame) {
        let mut state = self.state.lock().unwrap();
        if self.open() && frame.epoch == state.epoch && !state.flush_requested {
            state.latest = Some(frame);
            state.first_frame = true;
        }
        self.changed.notify_all();
    }
    pub fn callback(&self) -> Callback<'_> {
        self.state.lock().unwrap().callbacks += 1;
        Callback(self)
    }
    pub fn flushed(&self) {
        let mut state = self.state.lock().unwrap();
        if state.flush_requested {
            state.flush_ack = true;
            state.pending_read = false;
        }
        self.changed.notify_all();
    }
}
impl State {
    pub fn pending_action(&self, lease: u64, joined: bool) -> PendingAction {
        if self.epoch != lease {
            PendingAction::NoOwner
        } else if self.stop_ack(joined).is_ok() {
            PendingAction::Cleaned
        } else if self.delivered {
            PendingAction::Delivered
        } else {
            PendingAction::Pending
        }
    }
    pub fn drained(&self) -> bool {
        self.flush_ack && !self.pending_read && self.callbacks == 0 && self.latest.is_none()
    }
    pub fn stop_ack(&self, joined: bool) -> Result<(), Failure> {
        if self.finished
            && self.shutdown_ack
            && self.runtime_ack
            && !self.buffer_uncertain
            && (!self.callback_attached || self.callback_released)
            && self.callbacks == 0
            && self.latest.is_none()
            && joined
        {
            Ok(())
        } else {
            Err(Failure::new(Code::StopPending))
        }
    }
}
pub struct Callback<'a>(&'a Shared);
impl Drop for Callback<'_> {
    fn drop(&mut self) {
        self.0.state.lock().unwrap().callbacks -= 1;
        self.0.changed.notify_all();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn frame(epoch: u64, byte: u8) -> OwnedFrame {
        OwnedFrame {
            data: vec![byte; 16],
            width: 2,
            height: 2,
            epoch,
        }
    }
    #[test]
    fn latest_frame_is_bounded_and_stale_epoch_is_rejected() {
        let s = Shared::new(9);
        s.publish(frame(9, 1));
        s.publish(frame(9, 2));
        s.publish(frame(8, 3));
        assert_eq!(s.state.lock().unwrap().latest.as_ref().unwrap().data[0], 2);
    }
    #[test]
    fn cancellation_closes_publish_and_read_even_with_late_callback() {
        let s = Shared::new(1);
        assert!(s.begin_read());
        let callback = s.callback();
        s.cancel();
        s.publish(frame(1, 2));
        assert!(s.state.lock().unwrap().latest.is_none());
        assert!(!s.begin_read());
        drop(callback);
    }
    #[test]
    fn flush_is_not_shutdown_or_thread_join() {
        let s = Shared::new(1);
        s.cancel();
        s.state.lock().unwrap().flush_requested = true;
        let callback = s.callback();
        s.flushed();
        assert!(!s.state.lock().unwrap().drained());
        drop(callback);
        assert!(s.state.lock().unwrap().drained());
        let mut state = s.state.lock().unwrap();
        assert!(state.stop_ack(true).is_err());
        state.shutdown_ack = true;
        state.runtime_ack = true;
        state.finished = true;
        assert!(state.stop_ack(false).is_err());
        assert!(state.stop_ack(true).is_ok());
    }
    #[test]
    fn unsolicited_flush_and_error_never_ack_readiness() {
        let s = Shared::new(1);
        s.flushed();
        assert!(!s.state.lock().unwrap().flush_ack);
        s.fail(Failure::new(Code::Native));
        s.publish(frame(1, 1));
        assert!(!s.state.lock().unwrap().first_frame);
        assert!(!s.begin_read());
    }
    #[test]
    fn only_one_read_can_be_outstanding() {
        let s = Shared::new(1);
        assert!(s.begin_read());
        assert!(!s.begin_read());
        let callback = s.callback();
        s.state.lock().unwrap().pending_read = false;
        assert!(!s.begin_read());
        drop(callback);
        assert!(s.begin_read());
    }
    #[test]
    fn cancellation_before_delayed_native_init_prevents_later_activation() {
        let s = Shared::new(1);
        s.cancel_pending().unwrap();
        let invoked = std::cell::Cell::new(false);
        assert!(s
            .execute(|| {
                invoked.set(true);
                Ok(())
            })
            .is_err());
        assert!(!invoked.get());
    }
    #[test]
    fn pending_cleanup_cannot_cancel_a_delivered_capturer() {
        let s = Shared::new(1);
        s.state.lock().unwrap().delivered = true;
        assert_eq!(s.cancel_pending().unwrap_err().code, Code::Busy);
        assert!(s.open());
    }
    #[test]
    fn foreign_busy_constructor_never_acquires_cleanup_of_another_lease() {
        let s = Shared::new(7);
        let mut state = s.state.lock().unwrap();
        assert_eq!(state.pending_action(8, false), PendingAction::NoOwner);
        assert_eq!(state.pending_action(7, false), PendingAction::Pending);
        state.delivered = true;
        assert_eq!(state.pending_action(7, false), PendingAction::Delivered);
        state.shutdown_ack = true;
        state.runtime_ack = true;
        state.finished = true;
        assert_eq!(state.pending_action(7, true), PendingAction::Cleaned);
    }
}
