use super::{codec::{VoiceDecoder, VoiceEncoder}, queue::Queue, Binding, EncodedPacket, PcmFrame,
    VoiceError, FRAME_SAMPLES};
use std::{sync::{atomic::{AtomicBool, Ordering}, Arc, Condvar, Mutex, TryLockError}, thread::{self, JoinHandle},
    time::{Duration, Instant}};

pub trait VoiceDriver {
    /// A successful return means the native device has stopped, not that a
    /// command was submitted. The driver is retained and retried on failure.
    fn stop(&mut self) -> Result<(), VoiceError>;
    fn check_permission(&self) -> Result<(), VoiceError>;
    fn poll(&mut self) -> Result<(), VoiceError> { Ok(()) }
}
pub trait VoiceBackend: super::sealed::Sealed + Send + 'static {
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
        self.capture.clear(); self.incoming.clear(); self.outgoing.clear(); self.playback.clear();
        self.partial.fill(0.); self.partial_len = 0;
        self.playing = None; self.playing_offset = 0;
    }
}
struct Shared { state: Mutex<State>, execution: Mutex<()>, cancelled: AtomicBool, changed: Condvar }

#[derive(Clone)]
pub struct MediaIo { shared: Arc<Shared> }
impl MediaIo {
    fn active_atomic(&self) -> bool { !self.shared.cancelled.load(Ordering::Acquire) }
    pub fn active(&self) -> bool {
        !self.shared.cancelled.load(Ordering::Acquire) && self.shared.state.lock().unwrap().active
    }
    pub(super) fn execute<T>(&self, action: impl FnOnce() -> Result<T, VoiceError>) -> Result<T, VoiceError> {
        let _execution = self.shared.execution.lock().unwrap();
        if !self.active() { return Err(VoiceError::Closed); }
        action()
    }
    pub fn fail(&self, error: VoiceError) {
        self.shared.cancelled.store(true, Ordering::Release);
        let mut state = self.shared.state.lock().unwrap();
        state.error = Some(error); state.close();
        self.shared.changed.notify_all();
    }
    /// Only a production provider calls this with real device PCM. It must
    /// provide interleaved 48k samples from the previously approved channels.
    pub(super) fn capture(&self, data: &[f32], channels: usize) -> Result<(), VoiceError> {
        if !self.active_atomic() { return Err(VoiceError::Closed); }
        if channels == 0 || channels > 2 || data.len() % channels != 0 || data.len() > 192_000 {
            return Err(VoiceError::InvalidPcm);
        }
        let mut state = match self.shared.state.try_lock() {
            Ok(state) => state,
            Err(TryLockError::WouldBlock) => return Err(VoiceError::Busy),
            Err(TryLockError::Poisoned(error)) => error.into_inner(),
        };
        if !state.active || self.shared.cancelled.load(Ordering::Acquire) { return Err(VoiceError::Closed); }
        for frame in data.chunks_exact(channels) {
            if frame.iter().any(|sample| !sample.is_finite() || sample.abs() > 1.) {
                state.partial.fill(0.); state.partial_len = 0;
                return Err(VoiceError::InvalidPcm);
            }
            let sample = frame.iter().sum::<f32>() / channels as f32;
            let index = state.partial_len;
            state.partial[index] = sample;
            state.partial_len += 1;
            if state.partial_len == FRAME_SAMPLES {
                let packet = PcmFrame { binding: state.binding, samples: state.partial };
                state.capture.push(packet);
                state.partial.fill(0.); state.partial_len = 0;
                if state.native { state.first_pcm = true; }
            }
        }
        self.shared.changed.notify_all();
        Ok(())
    }
    pub(super) fn render(&self, data: &mut [f32], channels: usize) {
        self.render_pending(data, channels);
        if !data.is_empty() { self.playback_prepared(); }
    }
    pub(super) fn playback_prepared(&self) {
        let mut state = self.shared.state.lock().unwrap();
        if state.active && state.native && !self.shared.cancelled.load(Ordering::Acquire) { state.playback_ready = true; }
        self.shared.changed.notify_all();
    }
    pub(super) fn render_pending(&self, data: &mut [f32], channels: usize) {
        data.fill(0.);
        if channels == 0 || channels > 2 || data.len() % channels != 0 { return; }
        let mut state = match self.shared.state.try_lock() {
            Ok(state) => state,
            Err(TryLockError::WouldBlock) => return,
            Err(TryLockError::Poisoned(error)) => error.into_inner(),
        };
        if !state.active || self.shared.cancelled.load(Ordering::Acquire) { return; }
        for frame in data.chunks_exact_mut(channels) {
            if state.playing.is_none() {
                state.playing = state.playback.pop(); state.playing_offset = 0;
            }
            if let Some(packet) = &state.playing {
                frame.fill(packet.samples[state.playing_offset]);
                state.playing_offset += 1;
                if state.playing_offset == FRAME_SAMPLES { state.playing = None; }
            }
        }
        self.shared.changed.notify_all();
    }
    fn cancelled(&self) -> bool { !self.active() }
    fn wait_tick(&self, duration: Duration) {
        let state = self.shared.state.lock().unwrap();
        let _result = self.shared.changed.wait_timeout(state, duration).unwrap();
    }
}

pub struct VoiceOwner {
    io: MediaIo,
    worker: Option<JoinHandle<()>>,
}
impl VoiceOwner {
    /// The caller must hold its live capability ticket throughout start and
    /// every wire send. A local binding never authorizes the peer or devices.
    pub fn start<B: VoiceBackend>(binding: Binding, backend: B) -> Result<Self, VoiceError> {
        let encoder = VoiceEncoder::new(binding)?;
        let decoder = VoiceDecoder::new(binding)?;
        let native = backend.physical_device_provider();
        let io = MediaIo { shared: Arc::new(Shared { changed: Condvar::new(), execution: Mutex::new(()),
            cancelled: AtomicBool::new(false), state: Mutex::new(State {
            binding, native, active: true, first_pcm: false, playback_ready: false, released: false,
            error: None, capture: Queue::new(), incoming: Queue::new(), outgoing: Queue::new(),
            playback: Queue::new(), partial: [0.; FRAME_SAMPLES], partial_len: 0,
            playing: None, playing_offset: 0,
        }) }) };
        let worker_io = io.clone();
        let worker = thread::Builder::new().name("niko-voice-owner".into())
            .spawn(move || run(backend, worker_io, encoder, decoder))
            .map_err(|_| VoiceError::WorkerFailed)?;
        Ok(Self { io, worker: Some(worker) })
    }
    pub fn binding(&self) -> Binding { self.io.shared.state.lock().unwrap().binding }
    pub fn ready(&self) -> Result<bool, VoiceError> {
        let state = self.io.shared.state.lock().unwrap();
        if let Some(error) = &state.error { return Err(error.clone()); }
        if !state.active || self.io.shared.cancelled.load(Ordering::Acquire) { return Err(VoiceError::Closed); }
        Ok(state.native && state.first_pcm && state.playback_ready)
    }
    pub fn wait_started(&self, timeout: Duration) -> Result<(), VoiceError> {
        let end = Instant::now().checked_add(timeout).ok_or(VoiceError::Timeout)?;
        loop {
            if self.ready()? { return Ok(()); }
            let now = Instant::now();
            if now >= end { return Err(VoiceError::Timeout); }
            self.io.wait_tick((end - now).min(Duration::from_millis(10)));
        }
    }
    pub fn enqueue_incoming(&self, packet: EncodedPacket) -> Result<(), VoiceError> {
        let mut state = self.io.shared.state.lock().unwrap();
        if packet.binding != state.binding { return Err(VoiceError::StaleBinding); }
        if !state.active || self.io.shared.cancelled.load(Ordering::Acquire) { return Err(VoiceError::Closed); }
        state.incoming.push(packet); self.io.shared.changed.notify_all();
        Ok(())
    }
    /// After returning a packet the caller still checks its current ticket and
    /// epoch immediately at the transport send; revoke may race this handoff.
    pub fn take_outgoing(&self, binding: Binding) -> Result<Option<EncodedPacket>, VoiceError> {
        let mut state = self.io.shared.state.lock().unwrap();
        if binding != state.binding { return Err(VoiceError::StaleBinding); }
        if !state.active || self.io.shared.cancelled.load(Ordering::Acquire) { return Err(VoiceError::Closed); }
        Ok(state.outgoing.pop())
    }
    pub fn cancel(&self) {
        self.io.shared.cancelled.store(true, Ordering::Release);
        self.io.shared.state.lock().unwrap().close(); self.io.shared.changed.notify_all();
    }
    /// Timeout keeps the join handle and native worker owner available for a
    /// later stop retry. No resource or device release is acknowledged early.
    pub fn stop(&mut self, timeout: Duration) -> Result<(), VoiceError> {
        self.cancel();
        let end = Instant::now().checked_add(timeout).ok_or(VoiceError::Timeout)?;
        while let Some(worker) = &self.worker {
            if worker.is_finished() {
                if let Some(worker) = self.worker.take() { worker.join().map_err(|_| VoiceError::WorkerFailed)?; }
                break;
            }
            let now = Instant::now();
            if now >= end { return Err(VoiceError::Timeout); }
            self.io.wait_tick((end - now).min(Duration::from_millis(10)));
        }
        if !self.io.shared.state.lock().unwrap().released { return Err(VoiceError::WorkerFailed); }
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
                if worker.join().is_err() { self.io.fail(VoiceError::WorkerFailed); }
            }
        }
    }
}

fn run<B: VoiceBackend>(backend: B, io: MediaIo, mut encoder: VoiceEncoder, mut decoder: VoiceDecoder) {
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
        if let Err(error) = driver.check_permission() { io.fail(error); break; }
        if let Err(error) = driver.poll() { io.fail(error); break; }
        let (capture, incoming) = {
            let mut state = io.shared.state.lock().unwrap();
            (state.capture.pop(), state.incoming.pop())
        };
        if let Some(frame) = capture {
            match encoder.encode(&frame) {
                Ok(packet) => {
                    let mut state = io.shared.state.lock().unwrap();
                    if state.active && io.active_atomic() && packet.binding == state.binding { state.outgoing.push(packet); }
                }
                Err(error) => { io.fail(error); break; }
            }
        }
        if let Some(packet) = incoming {
            match decoder.decode(&packet) {
                Ok(frame) => {
                    let mut state = io.shared.state.lock().unwrap();
                    if state.active && io.active_atomic() && frame.binding == state.binding { state.playback.push(frame); }
                }
                Err(error) => { io.fail(error); break; }
            }
        }
        io.wait_tick(Duration::from_millis(5));
    }
    io.shared.state.lock().unwrap().close();
    loop {
        match driver.stop() {
            Ok(()) => break,
            Err(error) => {
                io.shared.state.lock().unwrap().error = Some(error);
                io.wait_tick(Duration::from_millis(100));
            }
        }
    }
    drop(driver);
    let mut state = io.shared.state.lock().unwrap();
    state.close(); state.released = true;
    io.shared.changed.notify_all();
}
