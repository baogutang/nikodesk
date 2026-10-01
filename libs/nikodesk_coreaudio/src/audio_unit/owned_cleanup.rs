//! Niko-only native teardown progress. An error never discards the native owner.
use std::sync::{atomic::{AtomicBool, AtomicUsize, Ordering}, Arc};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Stage { Stop, Uninitialize, Dispose }
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CleanupError { Native(i32), CallbacksPending }
#[derive(Default)]
pub struct CallbackFence { closing: AtomicBool, active: AtomicUsize }
pub struct CallbackGuard { fence: Arc<CallbackFence>, pub accepted: bool }
impl CallbackFence {
    pub fn enter(self: &Arc<Self>) -> Option<CallbackGuard> {
        let previous = self.active.fetch_update(Ordering::SeqCst, Ordering::SeqCst, |n| n.checked_add(1)).ok()?;
        Some(CallbackGuard { fence: self.clone(), accepted: previous == 0 && !self.closing.load(Ordering::SeqCst) })
    }
    pub fn close(&self) { self.closing.store(true, Ordering::SeqCst); }
    pub fn drained(&self) -> bool { self.active.load(Ordering::SeqCst) == 0 }
}
impl Drop for CallbackGuard {
    fn drop(&mut self) { self.fence.active.fetch_sub(1, Ordering::SeqCst); }
}
pub struct OwnedCleanup {
    pub lease: u64,
    pub callbacks: Arc<CallbackFence>,
    pub initialize_attempted: bool,
    pub start_attempted: bool,
    stopped: bool,
    uninitialized: bool,
    disposed: bool,
}
impl OwnedCleanup {
    pub fn new(lease: u64) -> Self {
        Self { lease, callbacks: Arc::new(CallbackFence::default()), initialize_attempted: false,
            start_attempted: false, stopped: false, uninitialized: false, disposed: false }
    }
    pub fn release(&mut self, mut call: impl FnMut(Stage) -> i32) -> Result<(), CleanupError> {
        self.callbacks.close();
        if self.start_attempted && !self.stopped {
            let status = call(Stage::Stop);
            if status != 0 { return Err(CleanupError::Native(status)); }
            self.stopped = true;
        }
        if !self.callbacks.drained() { return Err(CleanupError::CallbacksPending); }
        if self.initialize_attempted && !self.uninitialized {
            let status = call(Stage::Uninitialize);
            // A failed Initialize may leave an already-uninitialized owned unit.
            // Dispose must still succeed; all other statuses retain the owner.
            if status != 0 && status != -10867 { return Err(CleanupError::Native(status)); }
            self.uninitialized = true;
        }
        if !self.disposed {
            let status = call(Stage::Dispose);
            if status != 0 { return Err(CleanupError::Native(status)); }
            self.disposed = true;
        }
        if !self.callbacks.drained() { return Err(CleanupError::CallbacksPending); }
        Ok(())
    }
    pub fn disposed(&self) -> bool { self.disposed }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn partial_construction_requires_dispose_even_without_initialize_or_start() {
        let mut owner = OwnedCleanup::new(1); let mut calls = vec![];
        owner.release(|stage| { calls.push(stage); 0 }).unwrap();
        assert_eq!(calls, vec![Stage::Dispose]);
        owner.release(|_| panic!("double native dispose")).unwrap();
    }
    #[test]
    fn stop_failure_retains_instance_and_all_later_cleanup_stages() {
        let mut owner = OwnedCleanup::new(1); owner.start_attempted = true; owner.initialize_attempted = true;
        assert_eq!(owner.release(|stage| { assert_eq!(stage, Stage::Stop); -1 }), Err(CleanupError::Native(-1)));
        assert!(!owner.disposed()); let mut calls = vec![];
        owner.release(|stage| { calls.push(stage); 0 }).unwrap();
        assert_eq!(calls, vec![Stage::Stop, Stage::Uninitialize, Stage::Dispose]);
    }
    #[test]
    fn failed_dispose_is_retryable_without_repeating_acknowledged_stop() {
        let mut owner = OwnedCleanup::new(1); owner.start_attempted = true; owner.initialize_attempted = true;
        assert_eq!(owner.release(|stage| if stage == Stage::Dispose { -1 } else { 0 }), Err(CleanupError::Native(-1)));
        assert!(!owner.disposed());
        owner.release(|stage| { assert_eq!(stage, Stage::Dispose); 0 }).unwrap();
    }
    #[test]
    fn callback_owner_must_drain_before_uninitialize_and_dispose() {
        let mut owner = OwnedCleanup::new(1); let callback = owner.callbacks.enter().unwrap();
        assert!(callback.accepted);
        assert_eq!(owner.release(|_| panic!("callback owner still live")), Err(CleanupError::CallbacksPending));
        assert!(!owner.callbacks.enter().unwrap().accepted);
        drop(callback); owner.release(|stage| { assert_eq!(stage, Stage::Dispose); 0 }).unwrap();
    }
    #[test]
    fn failed_initialize_uninitialized_status_still_requires_native_dispose_ack() {
        let mut owner = OwnedCleanup::new(1); owner.initialize_attempted = true;
        assert_eq!(owner.release(|stage| match stage { Stage::Uninitialize => -10867, Stage::Dispose => -9, _ => panic!() }), Err(CleanupError::Native(-9)));
        owner.release(|stage| { assert_eq!(stage, Stage::Dispose); 0 }).unwrap();
    }
    #[test]
    fn uninitialize_failure_does_not_release_or_skip_to_dispose() {
        let mut owner = OwnedCleanup::new(1); owner.initialize_attempted = true;
        assert_eq!(owner.release(|stage| { assert_eq!(stage, Stage::Uninitialize); -50 }), Err(CleanupError::Native(-50)));
        assert!(!owner.disposed());
    }
    #[test]
    fn concurrent_native_callback_cannot_alias_a_mutable_rust_callback() {
        let fence = Arc::new(CallbackFence::default());
        let first = fence.enter().unwrap(); assert!(first.accepted);
        let concurrent = fence.enter().unwrap(); assert!(!concurrent.accepted);
        drop(concurrent); assert!(!fence.drained()); drop(first); assert!(fence.drained());
        assert!(fence.enter().unwrap().accepted);
    }
}
