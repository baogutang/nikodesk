use super::*;
use super::queue::Queue;
use std::sync::{atomic::{AtomicBool, AtomicUsize, Ordering}, Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

fn binding() -> Binding { Binding::new([3; 16], 1).unwrap() }
fn other() -> Binding { Binding::new([3; 16], 2).unwrap() }
fn pcm(binding: Binding) -> PcmFrame {
    let mut samples = [0.; FRAME_SAMPLES];
    for (index, sample) in samples.iter_mut().enumerate() {
        *sample = (index as f32 * std::f32::consts::TAU * 440. / SAMPLE_RATE as f32).sin() * 0.25;
    }
    PcmFrame::new(binding, samples).unwrap()
}
fn feed(io: &MediaIo, data: &[f32], channels: usize) {
    eventually(|| match io.capture(data, channels) {
        Ok(()) => true,
        Err(VoiceError::Busy) => false,
        Err(error) => panic!("synthetic input rejected: {error}"),
    });
}
#[test]
fn nikodesk_voice_binding_requires_nonce_and_epoch() {
    assert_eq!(Binding::new([0; 16], 1), Err(VoiceError::InvalidBinding));
    assert_eq!(Binding::new([1; 16], 0), Err(VoiceError::InvalidBinding));
    assert_eq!(binding().epoch(), 1);
    assert_eq!(binding().nonce(), &[3; 16]);
}
#[test]
fn nikodesk_voice_pcm_rejects_nonfinite_and_headroom() {
    for invalid in [f32::NAN, f32::INFINITY, 1.01, -1.01] {
        let mut samples = [0.; FRAME_SAMPLES]; samples[17] = invalid;
        assert!(matches!(PcmFrame::new(binding(), samples), Err(VoiceError::InvalidPcm)));
    }
}
#[test]
fn nikodesk_voice_real_opus_roundtrip_ten_ms() {
    let mut encoder = VoiceEncoder::new(binding()).unwrap();
    let mut decoder = VoiceDecoder::new(binding()).unwrap();
    let frame = pcm(binding());
    let mut energy = 0.;
    for _ in 0..5 {
        let packet = encoder.encode(&frame).unwrap();
        assert!(!packet.bytes().is_empty() && packet.bytes().len() <= MAX_OPUS_BYTES);
        let decoded = decoder.decode(&packet).unwrap();
        assert_eq!(decoded.samples().len(), FRAME_SAMPLES);
        energy += decoded.samples().iter().map(|sample| sample * sample).sum::<f32>();
    }
    assert!(energy > 1.);
}
#[test]
fn nikodesk_voice_real_opus_full_scale_uses_native_soft_clip() {
    let mut encoder = VoiceEncoder::new(binding()).unwrap();
    let mut decoder = VoiceDecoder::new(binding()).unwrap();
    let frame = PcmFrame::new(binding(), std::array::from_fn(|index| if index % 97 < 48 { 1. } else { -1. })).unwrap();
    for _ in 0..20 {
        let decoded = decoder.decode(&encoder.encode(&frame).unwrap()).unwrap();
        assert!(decoded.samples().iter().all(|value| value.is_finite() && value.abs() <= 1.));
    }
}
#[test]
fn nikodesk_voice_opus_rejects_old_call_before_codec() {
    let mut encoder = VoiceEncoder::new(binding()).unwrap();
    assert!(matches!(encoder.encode(&pcm(other())), Err(VoiceError::StaleBinding)));
    let packet = encoder.encode(&pcm(binding())).unwrap();
    let mut decoder = VoiceDecoder::new(other()).unwrap();
    assert!(matches!(decoder.decode(&packet), Err(VoiceError::StaleBinding)));
}
#[test]
fn nikodesk_voice_packet_bounds() {
    assert!(matches!(EncodedPacket::new(binding(), vec![]), Err(VoiceError::InvalidPacket)));
    assert!(matches!(EncodedPacket::new(binding(), vec![0; MAX_OPUS_BYTES + 1]), Err(VoiceError::InvalidPacket)));
    let mut excess = Vec::with_capacity(1024 * 1024); excess.push(1);
    let packet = EncodedPacket::new(binding(), excess).unwrap();
    assert_eq!(packet.bytes.capacity(), packet.bytes.len());
}
#[test]
fn nikodesk_voice_decoder_rejects_malformed_and_long_frame() {
    let mut decoder = VoiceDecoder::new(binding()).unwrap();
    assert!(decoder.decode(&EncodedPacket::new(binding(), vec![3]).unwrap()).is_err());
    let mut encoder = magnum_opus::Encoder::new(SAMPLE_RATE, magnum_opus::Channels::Mono,
        magnum_opus::Application::Voip).unwrap();
    let bytes = encoder.encode_vec_float(&[0.; FRAME_SAMPLES * 2], MAX_OPUS_BYTES).unwrap();
    assert!(decoder.decode(&EncodedPacket::new(binding(), bytes).unwrap()).is_err());
}
#[test]
fn nikodesk_voice_queue_keeps_bounded_latest_frames() {
    let mut queue = Queue::new();
    for value in 0..2000 { queue.push(value); assert!(queue.len() <= QUEUE_FRAMES); }
    for expected in 1990..2000 { assert_eq!(queue.pop(), Some(expected)); }
    assert_eq!(queue.pop(), None);
    queue.push(1); queue.clear(); assert_eq!(queue.len(), 0);
}

#[derive(Clone)]
struct Controls {
    io: Arc<(Mutex<Option<MediaIo>>, Condvar)>,
    release: Arc<AtomicBool>,
    dropped: Arc<AtomicUsize>,
}
impl Controls {
    fn new() -> Self {
        Self { io: Arc::new((Mutex::new(None), Condvar::new())),
            release: Arc::new(AtomicBool::new(true)), dropped: Arc::new(AtomicUsize::new(0)) }
    }
    fn io(&self) -> MediaIo {
        let (lock, changed) = &*self.io;
        let guard = lock.lock().unwrap();
        let (guard, _) = changed.wait_timeout_while(guard, Duration::from_secs(2), |io| io.is_none()).unwrap();
        guard.as_ref().unwrap().clone()
    }
}
struct NoDeviceBackend { controls: Controls }
struct NoDeviceDriver { controls: Controls }
impl super::sealed::Sealed for NoDeviceBackend {}
impl VoiceBackend for NoDeviceBackend {
    fn physical_device_provider(&self) -> bool { false }
    fn open(self, io: MediaIo) -> Result<Box<dyn VoiceDriver>, VoiceError> {
        *self.controls.io.0.lock().unwrap() = Some(io); self.controls.io.1.notify_all();
        Ok(Box::new(NoDeviceDriver { controls: self.controls }))
    }
}
impl VoiceDriver for NoDeviceDriver {
    fn check_permission(&self) -> Result<(), VoiceError> { Ok(()) }
    fn stop(&mut self) -> Result<(), VoiceError> {
        if !self.controls.release.load(Ordering::Acquire) { return Err(VoiceError::Device("test stop pending".into())); }
        Ok(())
    }
}
impl Drop for NoDeviceDriver {
    fn drop(&mut self) { self.controls.dropped.fetch_add(1, Ordering::AcqRel); }
}
fn owner() -> (VoiceOwner, Controls) {
    let controls = Controls::new();
    let owner = VoiceOwner::start(binding(), NoDeviceBackend { controls: controls.clone() }).unwrap();
    (owner, controls)
}
fn eventually(mut predicate: impl FnMut() -> bool) {
    let end = Instant::now() + Duration::from_secs(2);
    while !predicate() {
        assert!(Instant::now() < end, "condition did not become true");
        std::thread::sleep(Duration::from_millis(2));
    }
}
#[test]
fn nikodesk_voice_no_device_provider_cannot_ack_synthetic_pcm() {
    let (mut owner, controls) = owner(); let io = controls.io();
    feed(&io, pcm(binding()).samples(), 1);
    io.render(&mut [0.; FRAME_SAMPLES], 1);
    assert_eq!(owner.ready().unwrap(), false);
    assert_eq!(owner.wait_started(Duration::from_millis(3)), Err(VoiceError::Timeout));
    owner.stop(Duration::from_secs(1)).unwrap();
}
#[test]
fn nikodesk_voice_worker_encodes_synthetic_pcm_with_actual_opus() {
    let (mut owner, controls) = owner(); let io = controls.io();
    feed(&io, pcm(binding()).samples(), 1);
    let mut packet = None;
    eventually(|| { packet = owner.take_outgoing(binding()).unwrap(); packet.is_some() });
    assert_eq!(packet.unwrap().binding(), binding());
    owner.stop(Duration::from_secs(1)).unwrap();
}
#[test]
fn nikodesk_voice_owner_rejects_stale_and_closed_media() {
    let (mut owner, controls) = owner(); let io = controls.io();
    assert_eq!(owner.enqueue_incoming(EncodedPacket::new(other(), vec![1]).unwrap()), Err(VoiceError::StaleBinding));
    assert!(matches!(owner.take_outgoing(other()), Err(VoiceError::StaleBinding)));
    feed(&io, pcm(binding()).samples(), 1);
    owner.cancel();
    assert_eq!(io.capture(pcm(binding()).samples(), 1), Err(VoiceError::Closed));
    let mut data = [1.; FRAME_SAMPLES]; io.render(&mut data, 1); assert_eq!(data, [0.; FRAME_SAMPLES]);
    assert!(matches!(owner.take_outgoing(binding()), Err(VoiceError::Closed)));
    assert_eq!(owner.enqueue_incoming(EncodedPacket::new(binding(), vec![1]).unwrap()), Err(VoiceError::Closed));
    owner.stop(Duration::from_secs(1)).unwrap(); owner.stop(Duration::from_millis(0)).unwrap();
}
#[test]
fn nikodesk_voice_stop_timeout_retains_driver_until_actual_release() {
    let (mut owner, controls) = owner(); let io = controls.io();
    controls.release.store(false, Ordering::Release);
    assert_eq!(owner.stop(Duration::from_millis(5)), Err(VoiceError::Timeout));
    assert_eq!(controls.dropped.load(Ordering::Acquire), 0);
    assert!(!io.active());
    assert_eq!(io.execute(|| Ok(())), Err(VoiceError::Closed));
    controls.release.store(true, Ordering::Release);
    owner.stop(Duration::from_secs(1)).unwrap();
    assert_eq!(controls.dropped.load(Ordering::Acquire), 1);
}
#[test]
fn nikodesk_voice_drop_keeps_stalled_driver_owned_by_worker() {
    let (owner, controls) = owner(); controls.io(); controls.release.store(false, Ordering::Release);
    drop(owner);
    assert_eq!(controls.dropped.load(Ordering::Acquire), 0);
    controls.release.store(true, Ordering::Release);
    eventually(|| controls.dropped.load(Ordering::Acquire) == 1);
}
#[test]
fn nikodesk_voice_cancel_stops_late_device_start() {
    struct Opening { controls: Controls, go: Arc<(Mutex<bool>, Condvar)>, actions: Arc<AtomicUsize> }
    impl super::sealed::Sealed for Opening {}
    impl VoiceBackend for Opening {
        fn physical_device_provider(&self) -> bool { false }
        fn open(self, io: MediaIo) -> Result<Box<dyn VoiceDriver>, VoiceError> {
            *self.controls.io.0.lock().unwrap() = Some(io.clone()); self.controls.io.1.notify_all();
            let (lock, changed) = &*self.go;
            let guard = lock.lock().unwrap(); let _guard = changed.wait_while(guard, |go| !*go).unwrap();
            io.execute(|| { self.actions.fetch_add(1, Ordering::AcqRel); Ok(()) })?;
            Ok(Box::new(NoDeviceDriver { controls: self.controls }))
        }
    }
    let controls = Controls::new(); let go = Arc::new((Mutex::new(false), Condvar::new()));
    let actions = Arc::new(AtomicUsize::new(0));
    let mut owner = VoiceOwner::start(binding(), Opening { controls: controls.clone(), go: go.clone(), actions: actions.clone() }).unwrap();
    controls.io(); owner.cancel(); *go.0.lock().unwrap() = true; go.1.notify_all();
    owner.stop(Duration::from_secs(1)).unwrap(); assert_eq!(actions.load(Ordering::Acquire), 0);
}
#[test]
fn nikodesk_voice_capture_partial_stereo_downmix_is_bounded() {
    let (mut owner, controls) = owner(); let io = controls.io();
    feed(&io, &[0.25; FRAME_SAMPLES - 1], 1);
    assert!(owner.take_outgoing(binding()).unwrap().is_none());
    feed(&io, &[0.25], 1);
    eventually(|| owner.take_outgoing(binding()).unwrap().is_some());
    assert_eq!(io.capture(&[0.; 3], 2), Err(VoiceError::InvalidPcm));
    assert_eq!(io.capture(&[f32::NAN], 1), Err(VoiceError::InvalidPcm));
    owner.stop(Duration::from_secs(1)).unwrap();
}
#[test]
fn nikodesk_voice_decode_error_closes_and_flushes_owner() {
    let (mut owner, controls) = owner(); let io = controls.io();
    owner.enqueue_incoming(EncodedPacket::new(binding(), vec![3]).unwrap()).unwrap();
    eventually(|| !io.active());
    assert!(owner.ready().is_err());
    owner.stop(Duration::from_secs(1)).unwrap();
}
