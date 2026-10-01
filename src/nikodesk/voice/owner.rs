use super::{
    codec::{VoiceDecoder, VoiceEncoder},
    queue::Queue,
    Binding, EncodedPacket, PcmFrame, VoiceError, FRAME_SAMPLES,
};
use std::{
    sync::{
        atomic::{AtomicBool, AtomicU64, Ordering},
        Arc, Condvar, Mutex, TryLockError,
    },
    thread::{self, JoinHandle},
    time::{Duration, Instant},
};

pub trait VoiceDriver {
    /// A successful return means the native device has stopped, not that a
    /// command was submitted. The driver is retained and retried on failure.
    fn stop(&mut self) -> Result<(), VoiceError>;
    fn check_permission(&self) -> Result<(), VoiceError>;
    fn poll(&mut self) -> Result<(), VoiceError> {
        Ok(())
    }
}
pub trait VoiceBackend: super::sealed::Sealed + Send + 'static {
    /// Returning Err must mean no native resource has been acquired. Providers
    /// return an empty driver and perform every fallible acquisition in poll.
    fn open(self, io: MediaIo) -> Result<Box<dyn VoiceDriver>, VoiceError>;
    fn physical_device_provider(&self) -> bool;
}

struct State {
    binding: Binding,
    active: bool,
    native: bool,
    first_pcm: bool,
    playback_ready: bool,
    released: bool,
    error: Option<VoiceError>,
    capture_generation: u64,
    capture: Queue<PcmFrame>,
    incoming: Queue<EncodedPacket>,
    outgoing: Queue<EncodedPacket>,
    playback: Queue<PcmFrame>,
    partial: [f32; FRAME_SAMPLES],
    partial_len: usize,
    playing: Option<PcmFrame>,
    playing_offset: usize,
}
impl State {
    fn close(&mut self) {
        self.active = false;
        self.capture.clear();
        self.incoming.clear();
        self.outgoing.clear();
        self.playback.clear();
        self.partial.fill(0.);
        self.partial_len = 0;
        self.playing = None;
        self.playing_offset = 0;
    }
}
static NEXT_NATIVE_LEASE: AtomicU64 = AtomicU64::new(1);
pub(super) fn reserve_native_lease() -> Result<u64, VoiceError> {
    NEXT_NATIVE_LEASE
        .fetch_update(Ordering::AcqRel, Ordering::Acquire, |value| {
            value.checked_add(1)
        })
        .map_err(|_| VoiceError::Busy)
}
struct Shared {
    state: Mutex<State>,
    execution: Mutex<()>,
    cancelled: AtomicBool,
    external_cancel: Arc<AtomicBool>,
    muted: AtomicBool,
    changed: Condvar,
}

#[derive(Clone)]
pub struct MediaIo {
    shared: Arc<Shared>,
}
impl MediaIo {
    pub(super) fn binding(&self) -> Binding {
        self.shared
            .state
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .binding
    }
    pub(crate) fn set_muted(&self, muted: bool) {
        self.shared.muted.store(muted, Ordering::Release);
        let mut state = self
            .shared
            .state
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        state.capture_generation = match state.capture_generation.checked_add(1) {
            Some(generation) => generation,
            None => {
                self.shared.cancelled.store(true, Ordering::Release);
                state.close();
                state.error = Some(VoiceError::WorkerFailed);
                return;
            }
        };
        state.capture.clear();
        state.outgoing.clear();
        state.partial.fill(0.);
        state.partial_len = 0;
    }
    pub(crate) fn enqueue_incoming(&self, packet: EncodedPacket) -> Result<(), VoiceError> {
        let mut state = self
            .shared
            .state
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        if packet.binding != state.binding {
            return Err(VoiceError::StaleBinding);
        }
        if !state.active || !self.active_atomic() {
            return Err(VoiceError::Closed);
        }
        state.incoming.push(packet);
        self.shared.changed.notify_all();
        Ok(())
    }
    pub(crate) fn take_outgoing(
        &self,
        binding: Binding,
    ) -> Result<Option<EncodedPacket>, VoiceError> {
        let mut state = self
            .shared
            .state
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        if binding != state.binding {
            return Err(VoiceError::StaleBinding);
        }
        if !state.active || !self.active_atomic() {
            return Err(VoiceError::Closed);
        }
        if self.shared.muted.load(Ordering::Acquire) {
            state.outgoing.clear();
            return Ok(None);
        }
        Ok(state.outgoing.pop())
    }
    fn active_atomic(&self) -> bool {
        !self.shared.cancelled.load(Ordering::Acquire)
            && !self.shared.external_cancel.load(Ordering::Acquire)
    }
    fn publish_encoded(&self, packet: EncodedPacket, generation: u64) {
        let mut state = self
            .shared
            .state
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        if state.active
            && self.active_atomic()
            && !self.shared.muted.load(Ordering::Acquire)
            && generation == state.capture_generation
            && packet.binding == state.binding
        {
            state.outgoing.push(packet);
        }
    }
    pub fn active(&self) -> bool {
        self.active_atomic()
            && self
                .shared
                .state
                .lock()
                .unwrap_or_else(|error| error.into_inner())
                .active
    }
    pub(super) fn execute<T>(
        &self,
        action: impl FnOnce() -> Result<T, VoiceError>,
    ) -> Result<T, VoiceError> {
        let _execution = self
            .shared
            .execution
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        if !self.active() {
            return Err(VoiceError::Closed);
        }
        action()
    }
    pub fn fail(&self, error: VoiceError) {
        self.shared.cancelled.store(true, Ordering::Release);
        let mut state = self
            .shared
            .state
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        state.error = Some(error);
        state.close();
        self.shared.changed.notify_all();
    }
    /// Only a production provider calls this with real device PCM. It must
    /// provide interleaved 48k samples from the previously approved channels.
    pub(super) fn capture(&self, data: &[f32], channels: usize) -> Result<(), VoiceError> {
        if !self.active_atomic() {
            return Err(VoiceError::Closed);
        }
        if channels == 0 || channels > 2 || data.len() % channels != 0 || data.len() > 192_000 {
            return Err(VoiceError::InvalidPcm);
        }
        let mut state = match self.shared.state.try_lock() {
            Ok(state) => state,
            Err(TryLockError::WouldBlock) => return Err(VoiceError::Busy),
            Err(TryLockError::Poisoned(error)) => error.into_inner(),
        };
        if !state.active || !self.active_atomic() {
            return Err(VoiceError::Closed);
        }
        for frame in data.chunks_exact(channels) {
            if frame
                .iter()
                .any(|sample| !sample.is_finite() || sample.abs() > 1.)
            {
                state.partial.fill(0.);
                state.partial_len = 0;
                return Err(VoiceError::InvalidPcm);
            }
            let sample = frame.iter().sum::<f32>() / channels as f32;
            let index = state.partial_len;
            state.partial[index] = sample;
            state.partial_len += 1;
            if state.partial_len == FRAME_SAMPLES {
                let packet = PcmFrame {
                    binding: state.binding,
                    samples: state.partial,
                };
                if !self.shared.muted.load(Ordering::Acquire) {
                    state.capture.push(packet);
                }
                state.partial.fill(0.);
                state.partial_len = 0;
                if state.native {
                    state.first_pcm = true;
                }
            }
        }
        self.shared.changed.notify_all();
        Ok(())
    }
    pub(super) fn render(&self, data: &mut [f32], channels: usize) {
        self.render_pending(data, channels);
        if !data.is_empty() {
            self.playback_prepared();
        }
    }
    pub(super) fn playback_prepared(&self) {
        let mut state = self.shared.state.lock().unwrap();
        if state.active && state.native && self.active_atomic() {
            state.playback_ready = true;
        }
        self.shared.changed.notify_all();
    }
    pub(super) fn render_pending(&self, data: &mut [f32], channels: usize) {
        data.fill(0.);
        if channels == 0 || channels > 2 || data.len() % channels != 0 {
            return;
        }
        let mut state = match self.shared.state.try_lock() {
            Ok(state) => state,
            Err(TryLockError::WouldBlock) => return,
            Err(TryLockError::Poisoned(error)) => error.into_inner(),
        };
        if !state.active || !self.active_atomic() {
            return;
        }
        for frame in data.chunks_exact_mut(channels) {
            if state.playing.is_none() {
                state.playing = state.playback.pop();
                state.playing_offset = 0;
            }
            if let Some(packet) = &state.playing {
                frame.fill(packet.samples[state.playing_offset]);
                state.playing_offset += 1;
                if state.playing_offset == FRAME_SAMPLES {
                    state.playing = None;
                }
            }
        }
        self.shared.changed.notify_all();
    }
    fn cancelled(&self) -> bool {
        !self.active()
    }
    fn wait_tick(&self, duration: Duration) {
        let state = self.shared.state.lock().unwrap();
        let _result = self.shared.changed.wait_timeout(state, duration).unwrap();
    }
}

pub struct VoiceOwner {
    io: MediaIo,
    worker: Option<JoinHandle<()>>,
    join_failed: bool,
}
impl VoiceOwner {
    /// The caller must hold its live capability ticket throughout start and
    /// every wire send. A local binding never authorizes the peer or devices.
    pub fn start<B: VoiceBackend>(binding: Binding, backend: B) -> Result<Self, VoiceError> {
        Self::start_guarded(binding, backend, Arc::new(AtomicBool::new(false)))
    }
    pub fn start_guarded<B: VoiceBackend>(
        binding: Binding,
        backend: B,
        external_cancel: Arc<AtomicBool>,
    ) -> Result<Self, VoiceError> {
        let encoder = VoiceEncoder::new(binding)?;
        let decoder = VoiceDecoder::new(binding)?;
        let native = backend.physical_device_provider();
        let io = MediaIo {
            shared: Arc::new(Shared {
                changed: Condvar::new(),
                execution: Mutex::new(()),
                cancelled: AtomicBool::new(false),
                external_cancel,
                muted: AtomicBool::new(false),
                state: Mutex::new(State {
                    binding,
                    native,
                    active: true,
                    first_pcm: false,
                    playback_ready: false,
                    released: false,
                    error: None,
                    capture_generation: 0,
                    capture: Queue::new(),
                    incoming: Queue::new(),
                    outgoing: Queue::new(),
                    playback: Queue::new(),
                    partial: [0.; FRAME_SAMPLES],
                    partial_len: 0,
                    playing: None,
                    playing_offset: 0,
                }),
            }),
        };
        let worker_io = io.clone();
        let worker = thread::Builder::new()
            .name("niko-voice-owner".into())
            .spawn(move || run(backend, worker_io, encoder, decoder))
            .map_err(|_| VoiceError::WorkerFailed)?;
        Ok(Self {
            io,
            worker: Some(worker),
            join_failed: false,
        })
    }
    pub fn binding(&self) -> Binding {
        self.io.shared.state.lock().unwrap().binding
    }
    pub(crate) fn media(&self) -> MediaIo {
        self.io.clone()
    }
    pub fn ready(&self) -> Result<bool, VoiceError> {
        let state = self.io.shared.state.lock().unwrap();
        if let Some(error) = &state.error {
            return Err(error.clone());
        }
        if !state.active || !self.io.active_atomic() {
            return Err(VoiceError::Closed);
        }
        Ok(state.native && state.first_pcm && state.playback_ready)
    }
    pub fn wait_started(&self, timeout: Duration) -> Result<(), VoiceError> {
        let end = Instant::now()
            .checked_add(timeout)
            .ok_or(VoiceError::Timeout)?;
        loop {
            if self.ready()? {
                return Ok(());
            }
            let now = Instant::now();
            if now >= end {
                return Err(VoiceError::Timeout);
            }
            self.io
                .wait_tick((end - now).min(Duration::from_millis(10)));
        }
    }
    pub fn enqueue_incoming(&self, packet: EncodedPacket) -> Result<(), VoiceError> {
        self.io.enqueue_incoming(packet)
    }
    /// After returning a packet the caller still checks its current ticket and
    /// epoch immediately at the transport send; revoke may race this handoff.
    pub fn take_outgoing(&self, binding: Binding) -> Result<Option<EncodedPacket>, VoiceError> {
        self.io.take_outgoing(binding)
    }
    pub fn cancel(&self) {
        self.io.shared.cancelled.store(true, Ordering::Release);
        self.io.shared.state.lock().unwrap().close();
        self.io.shared.changed.notify_all();
    }
    /// Nonblocking completion poll; native calls and joins remain owned by the
    /// worker. A normal join and its release fact are both required.
    pub fn try_stop(&mut self) -> Result<bool, VoiceError> {
        self.cancel();
        if self.join_failed {
            return Err(VoiceError::WorkerFailed);
        }
        if self
            .worker
            .as_ref()
            .is_some_and(|worker| !worker.is_finished())
        {
            return Ok(false);
        }
        if let Some(worker) = self.worker.take() {
            if worker.join().is_err() {
                self.join_failed = true;
                return Err(VoiceError::WorkerFailed);
            }
        }
        if !self
            .io
            .shared
            .state
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .released
        {
            return Err(VoiceError::WorkerFailed);
        }
        Ok(true)
    }
    /// Timeout keeps the join handle and native worker owner available for a
    /// later stop retry. No resource or device release is acknowledged early.
    pub fn stop(&mut self, timeout: Duration) -> Result<(), VoiceError> {
        self.cancel();
        if self.join_failed {
            return Err(VoiceError::WorkerFailed);
        }
        let end = Instant::now()
            .checked_add(timeout)
            .ok_or(VoiceError::Timeout)?;
        while let Some(worker) = &self.worker {
            if worker.is_finished() {
                if let Some(worker) = self.worker.take() {
                    if worker.join().is_err() {
                        self.join_failed = true;
                        return Err(VoiceError::WorkerFailed);
                    }
                }
                break;
            }
            let now = Instant::now();
            if now >= end {
                return Err(VoiceError::Timeout);
            }
            self.io
                .wait_tick((end - now).min(Duration::from_millis(10)));
        }
        if !self.io.shared.state.lock().unwrap().released {
            return Err(VoiceError::WorkerFailed);
        }
        Ok(())
    }
}
impl Drop for VoiceOwner {
    fn drop(&mut self) {
        // A stalled native stop remains owned by its worker, including the
        // device lease. Dropping a connection never returns a false stop ACK.
        self.cancel();
        if self.worker.as_ref().is_some_and(JoinHandle::is_finished) {
            if let Some(worker) = self.worker.take() {
                if worker.join().is_err() {
                    self.io.fail(VoiceError::WorkerFailed);
                }
            }
        }
    }
}

fn run<B: VoiceBackend>(
    backend: B,
    io: MediaIo,
    mut encoder: VoiceEncoder,
    mut decoder: VoiceDecoder,
) {
    let mut driver = match backend.open(io.clone()) {
        Ok(driver) => driver,
        Err(error) => {
            io.fail(error);
            io.shared.state.lock().unwrap().released = true;
            io.shared.changed.notify_all();
            return;
        }
    };
    while !io.cancelled() {
        let checked = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            driver.check_permission()?;
            driver.poll()
        }))
        .unwrap_or(Err(VoiceError::WorkerFailed));
        if let Err(error) = checked {
            io.fail(error);
            break;
        }
        let (capture, incoming, capture_generation) = {
            let mut state = io.shared.state.lock().unwrap();
            (
                state.capture.pop(),
                state.incoming.pop(),
                state.capture_generation,
            )
        };
        if let Some(frame) = capture {
            match encoder.encode(&frame) {
                Ok(packet) => {
                    io.publish_encoded(packet, capture_generation);
                }
                Err(error) => {
                    io.fail(error);
                    break;
                }
            }
        }
        if let Some(packet) = incoming {
            match decoder.decode(&packet) {
                Ok(frame) => {
                    let mut state = io.shared.state.lock().unwrap();
                    if state.active && io.active_atomic() && frame.binding == state.binding {
                        state.playback.push(frame);
                    }
                }
                Err(error) => {
                    io.fail(error);
                    break;
                }
            }
        }
        io.wait_tick(Duration::from_millis(5));
    }
    io.shared.state.lock().unwrap().close();
    loop {
        match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| driver.stop()))
            .unwrap_or(Err(VoiceError::WorkerFailed))
        {
            Ok(()) => break,
            Err(error) => {
                io.shared.state.lock().unwrap().error = Some(error);
                io.wait_tick(Duration::from_millis(100));
            }
        }
    }
    drop(driver);
    let mut state = io.shared.state.lock().unwrap();
    state.close();
    state.released = true;
    io.shared.changed.notify_all();
}

#[cfg(test)]
mod partial_create_tests {
    use super::*;
    use std::sync::atomic::AtomicUsize;
    struct Backend {
        created: Arc<AtomicBool>,
        released: Arc<AtomicBool>,
        attempts: Arc<AtomicUsize>,
        panic: bool,
    }
    impl super::super::sealed::Sealed for Backend {}
    struct Driver {
        backend: Backend,
    }
    impl VoiceBackend for Backend {
        fn physical_device_provider(&self) -> bool {
            false
        }
        fn open(self, _: MediaIo) -> Result<Box<dyn VoiceDriver>, VoiceError> {
            Ok(Box::new(Driver { backend: self }))
        }
    }
    impl VoiceDriver for Driver {
        fn check_permission(&self) -> Result<(), VoiceError> {
            Ok(())
        }
        fn poll(&mut self) -> Result<(), VoiceError> {
            self.backend.created.store(true, Ordering::Release);
            if self.backend.panic {
                panic!("synthetic partial native construction panic");
            }
            Err(VoiceError::Device("synthetic_partial_create".into()))
        }
        fn stop(&mut self) -> Result<(), VoiceError> {
            self.backend.attempts.fetch_add(1, Ordering::AcqRel);
            if !self.backend.released.load(Ordering::Acquire) {
                return Err(VoiceError::Busy);
            }
            Ok(())
        }
    }
    fn partial(panic: bool) -> (VoiceOwner, Arc<AtomicBool>, Arc<AtomicUsize>) {
        let created = Arc::new(AtomicBool::new(false));
        let released = Arc::new(AtomicBool::new(false));
        let attempts = Arc::new(AtomicUsize::new(0));
        let owner = VoiceOwner::start(
            Binding::new([3; 16], 2).unwrap(),
            Backend {
                created: created.clone(),
                released: released.clone(),
                attempts: attempts.clone(),
                panic,
            },
        )
        .unwrap();
        let deadline = Instant::now() + Duration::from_secs(2);
        while !created.load(Ordering::Acquire) {
            assert!(Instant::now() < deadline);
            thread::yield_now();
        }
        (owner, released, attempts)
    }
    #[test]
    fn partial_native_create_error_retains_driver_until_stop_ack_and_normal_join() {
        let (mut owner, released, attempts) = partial(false);
        assert_eq!(
            owner.stop(Duration::from_millis(1)),
            Err(VoiceError::Timeout)
        );
        assert!(!owner.try_stop().unwrap());
        released.store(true, Ordering::Release);
        owner.stop(Duration::from_secs(2)).unwrap();
        assert!(owner.try_stop().unwrap());
        assert!(attempts.load(Ordering::Acquire) >= 1);
    }
    #[test]
    fn partial_native_create_panic_is_caught_and_cannot_drop_the_owned_driver() {
        let (mut owner, released, _) = partial(true);
        assert_eq!(
            owner.stop(Duration::from_millis(1)),
            Err(VoiceError::Timeout)
        );
        released.store(true, Ordering::Release);
        owner.stop(Duration::from_secs(2)).unwrap();
    }
    #[test]
    fn native_lease_is_checked_unique_and_independent_of_wire_binding() {
        let first = reserve_native_lease().unwrap();
        let second = reserve_native_lease().unwrap();
        assert_ne!(first, second);
        assert_ne!(first, 0);
        assert_ne!(second, 0);
        assert_eq!(
            Binding::new([3; 16], 2).unwrap(),
            Binding::new([3; 16], 2).unwrap()
        );
    }
    struct Idle;
    impl super::super::sealed::Sealed for Idle {}
    impl VoiceBackend for Idle {
        fn physical_device_provider(&self) -> bool {
            false
        }
        fn open(self, _: MediaIo) -> Result<Box<dyn VoiceDriver>, VoiceError> {
            Ok(Box::new(self))
        }
    }
    impl VoiceDriver for Idle {
        fn check_permission(&self) -> Result<(), VoiceError> {
            Ok(())
        }
        fn stop(&mut self) -> Result<(), VoiceError> {
            Ok(())
        }
    }
    #[test]
    fn mute_unmute_cannot_publish_a_pre_mute_inflight_opus_packet() {
        let binding = Binding::new([8; 16], 3).unwrap();
        let mut owner = VoiceOwner::start(binding, Idle).unwrap();
        let io = owner.media();
        let old_generation = io.shared.state.lock().unwrap().capture_generation;
        let packet = VoiceEncoder::new(binding)
            .unwrap()
            .encode(&PcmFrame {
                binding,
                samples: [0.1; FRAME_SAMPLES],
            })
            .unwrap();
        io.set_muted(true);
        io.set_muted(false);
        io.publish_encoded(packet.clone(), old_generation);
        assert!(io.take_outgoing(binding).unwrap().is_none());
        let current_generation = io.shared.state.lock().unwrap().capture_generation;
        io.publish_encoded(packet, current_generation);
        assert!(io.take_outgoing(binding).unwrap().is_some());
        owner.stop(Duration::from_secs(2)).unwrap();
    }
    #[test]
    fn external_cancel_closes_pcm_before_any_state_mutex_or_worker_join() {
        let cancel = Arc::new(AtomicBool::new(false));
        let mut owner =
            VoiceOwner::start_guarded(Binding::new([9; 16], 4).unwrap(), Idle, cancel.clone())
                .unwrap();
        let io = owner.media();
        let state = io.shared.state.lock().unwrap();
        cancel.store(true, Ordering::Release);
        assert!(!io.active_atomic());
        assert_eq!(
            io.capture(&[0.1; FRAME_SAMPLES], 1),
            Err(VoiceError::Closed)
        );
        drop(state);
        owner.stop(Duration::from_secs(2)).unwrap();
    }
}
