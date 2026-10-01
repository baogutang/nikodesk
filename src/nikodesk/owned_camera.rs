//! One native worker owns the exact capturer and a private software encoder.
use super::camera_flow::runtime::Gate;
use base::message_proto::Message;
use hbb_common::{bail, ResultType};
use scrap::{
    camera::{Cameras, CaptureSelection},
    codec::{Encoder, EncoderCfg},
    vpxcodec::{VpxEncoderConfig, VpxVideoCodecId},
    Frame, TraitCapturer, TraitPixelBuffer,
};
use std::{
    sync::{
        atomic::{AtomicBool, Ordering},
        mpsc::{sync_channel, Receiver, SyncSender, TryRecvError, TrySendError},
        Arc, Mutex,
    },
    thread::{self, JoinHandle},
    time::{Duration, Instant},
};

struct Completion {
    ack: AtomicBool,
    error: Mutex<Option<&'static str>>,
}
pub(crate) struct Worker {
    gate: Arc<Gate>,
    completion: Arc<Completion>,
    packets: Mutex<Receiver<Message>>,
    join: Option<JoinHandle<()>>,
}
impl Worker {
    #[cfg(test)]
    pub(crate) fn join_for_fixture_pending(&self) -> bool {
        self.join.as_ref().map_or(false, |join| !join.is_finished())
    }
    #[cfg(test)]
    pub(crate) fn cleanup_fixture(gate: Arc<Gate>, release: Receiver<()>, panic: bool) -> Self {
        let completion = Arc::new(Completion {
            ack: AtomicBool::new(false),
            error: Mutex::new(None),
        });
        let owned = completion.clone();
        let join = thread::spawn(move || {
            release.recv().unwrap();
            owned.ack.store(true, Ordering::SeqCst);
            assert!(!panic, "synthetic cleanup failure after ack");
        });
        let (_, packets) = sync_channel(1);
        Self {
            gate,
            completion,
            packets: Mutex::new(packets),
            join: Some(join),
        }
    }
    pub(crate) fn start(selection: CaptureSelection, gate: Arc<Gate>) -> ResultType<Self> {
        let (sender, packets) = sync_channel(1);
        let completion = Arc::new(Completion {
            ack: AtomicBool::new(false),
            error: Mutex::new(None),
        });
        let c = completion.clone();
        let g = gate.clone();
        let join = thread::Builder::new()
            .name("niko-camera-owned".into())
            .spawn(move || run(selection, g, c, sender))?;
        Ok(Self {
            gate,
            completion,
            packets: Mutex::new(packets),
            join: Some(join),
        })
    }
    pub(crate) fn cancel(&mut self) {
        self.gate.cancelled.store(true, Ordering::SeqCst);
        if let Ok(packets) = self.packets.lock() {
            while packets.try_recv().is_ok() {}
        } else {
            failure(&self.completion, "camera_output_unavailable");
        }
    }
    pub(crate) fn stop_ack(&mut self) -> bool {
        confirmed_worker_exit(&self.completion, &mut self.join)
    }
    pub(crate) fn error(&self) -> Option<&'static str> {
        self.completion
            .error
            .lock()
            .map(|e| *e)
            .unwrap_or(Some("camera_worker_unconfirmed"))
    }
    pub(crate) fn packet(&self) -> ResultType<Option<Message>> {
        match self
            .packets
            .lock()
            .map_err(|_| hbb_common::anyhow::anyhow!("camera_output_unavailable"))?
            .try_recv()
        {
            Ok(packet) => Ok(Some(packet)),
            Err(TryRecvError::Empty) => Ok(None),
            Err(TryRecvError::Disconnected) => {
                Err(hbb_common::anyhow::anyhow!("camera_worker_closed").into())
            }
        }
    }
}
impl Drop for Worker {
    fn drop(&mut self) {
        self.cancel();
    }
}
fn failure(completion: &Completion, reason: &'static str) {
    if let Ok(mut error) = completion.error.lock() {
        *error = Some(reason);
    }
}
fn confirmed_worker_exit(completion: &Completion, join: &mut Option<JoinHandle<()>>) -> bool {
    if !completion.ack.load(Ordering::SeqCst)
        || join.as_ref().map_or(false, |join| !join.is_finished())
    {
        return false;
    }
    if join.take().map_or(false, |join| join.join().is_err()) {
        completion.ack.store(false, Ordering::SeqCst);
        failure(completion, "camera_worker_unconfirmed");
        return false;
    }
    true
}
fn run(
    selection: CaptureSelection,
    gate: Arc<Gate>,
    completion: Arc<Completion>,
    sender: SyncSender<Message>,
) {
    // Native objects are constructed and destroyed on this same worker thread.
    if gate.check().is_err() {
        completion.ack.store(true, Ordering::SeqCst);
        return;
    }
    let mut capturer = None;
    let mut attempted = false;
    let started = gate.execute(|| {
        attempted = true;
        capturer = Some(Cameras::get_approved_capturer(&selection)?);
        Ok(())
    });
    let Some(mut capturer) = capturer else {
        if !attempted {
            completion.ack.store(true, Ordering::SeqCst);
            return;
        }
        failure(&completion, "camera_start_failed");
        // The construction call has returned. Only the provider's matching
        // pending-owner ledger can confirm whether a failed native start left
        // resources behind; absence of the returned Box proves nothing.
        cleanup_pending(&completion, || {
            Cameras::stop_pending_capture(selection.epoch)
        });
        return;
    };
    let outcome = if started.is_ok() {
        stream(capturer.as_mut(), &selection, &gate, &sender)
    } else {
        Err(hbb_common::anyhow::anyhow!("camera_permission_revoked").into())
    };
    if outcome.is_err() {
        failure(&completion, "camera_capture_or_encode_failed");
    }
    gate.cancelled.store(true, Ordering::SeqCst);
    // An unsuccessful stop cannot discard the only resource owner. This worker
    // keeps the native source until its actual stop operation acknowledges.
    while capturer.stop_capture().is_err() {
        failure(&completion, "camera_cleanup_unconfirmed_owner_retained");
        thread::sleep(Duration::from_millis(250));
    }
    drop(capturer);
    completion.ack.store(true, Ordering::SeqCst);
}
fn cleanup_pending(completion: &Completion, mut stop: impl FnMut() -> ResultType<()>) {
    while stop().is_err() {
        failure(completion, "camera_cleanup_unconfirmed_owner_retained");
        thread::sleep(Duration::from_millis(250));
    }
    completion.ack.store(true, Ordering::SeqCst);
}

#[cfg(target_os = "windows")]
pub(crate) struct ProbeWorker {
    completion: Arc<Completion>,
    result: Mutex<Receiver<Result<scrap::camera::CameraDevice, ()>>>,
    join: Option<JoinHandle<()>>,
}
#[cfg(target_os = "windows")]
impl ProbeWorker {
    pub(crate) fn start(uid: String, lease: u64) -> ResultType<Self> {
        let (sender, result) = sync_channel(1);
        let completion = Arc::new(Completion {
            ack: AtomicBool::new(false),
            error: Mutex::new(None),
        });
        let owned = completion.clone();
        let join = thread::Builder::new()
            .name("niko-camera-probe".into())
            .spawn(move || {
                match Cameras::probe_approved_formats(&uid, lease) {
                    Ok(device) => {
                        let _ = sender.try_send(Ok(device));
                    }
                    Err(_) => {
                        let _ = sender.try_send(Err(()));
                        cleanup_pending(&owned, || Cameras::stop_pending_capture(lease));
                    }
                }
                owned.ack.store(true, Ordering::SeqCst);
            })?;
        Ok(Self {
            completion,
            result: Mutex::new(result),
            join: Some(join),
        })
    }
    pub(crate) fn result(&self) -> ResultType<Option<Result<scrap::camera::CameraDevice, ()>>> {
        match self
            .result
            .lock()
            .map_err(|_| hbb_common::anyhow::anyhow!("camera_probe_unconfirmed"))?
            .try_recv()
        {
            Ok(result) => Ok(Some(result)),
            Err(TryRecvError::Empty) => Ok(None),
            Err(TryRecvError::Disconnected) => Ok(Some(Err(()))),
        }
    }
    pub(crate) fn stop_ack(&mut self) -> bool {
        confirmed_worker_exit(&self.completion, &mut self.join)
    }
}
fn stream(
    capturer: &mut dyn TraitCapturer,
    selection: &CaptureSelection,
    gate: &Gate,
    sender: &SyncSender<Message>,
) -> ResultType<()> {
    let mut encoder = Encoder::new(
        EncoderCfg::VPX(VpxEncoderConfig {
            width: selection.format.width,
            height: selection.format.height,
            quality: 1.0,
            codec: VpxVideoCodecId::VP9,
            keyframe_interval: Some(120),
        }),
        false,
    )?;
    let mut yuv = Vec::new();
    let mut mid = Vec::new();
    let started = Instant::now();
    let mut pending: Option<Message> = None;
    #[cfg(target_os = "macos")]
    let interval = Duration::from_secs_f64(1.0 / f64::from(selection.fps));
    #[cfg(target_os = "windows")]
    let interval = Duration::from_secs_f64(
        f64::from(selection.format.fps_den()) / f64::from(selection.format.fps_num()),
    );
    let mut next = Instant::now();
    while !gate.cancelled.load(Ordering::SeqCst) {
        gate.check()?;
        if let Some(packet) = pending.take() {
            match sender.try_send(packet) {
                Ok(()) => {}
                Err(TrySendError::Full(packet)) => {
                    pending = Some(packet);
                    thread::sleep(Duration::from_millis(5));
                    continue;
                }
                Err(TrySendError::Disconnected(_)) => return Ok(()),
            }
        }
        if Instant::now() < next {
            thread::sleep(Duration::from_millis(2));
            continue;
        }
        next = Instant::now() + interval;
        // The borrowed native frame and converted input both end before the
        // encoded owned message enters the bounded output channel.
        let encoded = gate.execute(|| {
            let frame = match capturer.frame(Duration::from_millis(50)) {
                Ok(frame) => frame,
                Err(error)
                    if matches!(
                        error.kind(),
                        std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                    ) =>
                {
                    return Ok(None)
                }
                Err(error) => return Err(error.into()),
            };
            match &frame {
                Frame::PixelBuffer(buffer)
                    if buffer.width() == selection.format.width as usize
                        && buffer.height() == selection.format.height as usize => {}
                _ => bail!("camera_frame_format_changed"),
            }
            let input = frame.to(encoder.yuvfmt(), &mut yuv, &mut mid)?;
            let mut video = encoder.encode_to_message(
                input,
                started.elapsed().as_millis().min(i64::MAX as u128) as i64,
            )?;
            video.display = 0;
            let mut message = Message::new();
            message.set_video_frame(video);
            Ok(Some(message))
        })?;
        gate.check()?;
        pending = encoded;
    }
    Ok(())
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn camera_output_channel_has_one_packet_capacity_and_no_unbounded_queue() {
        let (tx, rx) = sync_channel(1);
        tx.try_send(Message::new()).unwrap();
        assert!(matches!(
            tx.try_send(Message::new()),
            Err(TrySendError::Full(_))
        ));
        assert!(rx.try_recv().is_ok());
        assert!(tx.try_send(Message::new()).is_ok());
    }
    #[test]
    fn stop_requires_native_ack_and_worker_exit() {
        let completion = Arc::new(Completion {
            ack: AtomicBool::new(false),
            error: Mutex::new(None),
        });
        let (release, wait) = std::sync::mpsc::channel();
        let mut join = Some(thread::spawn(move || wait.recv().unwrap()));
        assert!(!confirmed_worker_exit(&completion, &mut join));
        completion.ack.store(true, Ordering::SeqCst);
        assert!(!confirmed_worker_exit(&completion, &mut join));
        release.send(()).unwrap();
        while !join.as_ref().unwrap().is_finished() {
            thread::yield_now();
        }
        assert!(confirmed_worker_exit(&completion, &mut join));
        assert!(confirmed_worker_exit(&completion, &mut join));
    }
    #[test]
    fn camera_worker_panic_cannot_become_confirmed_on_a_later_cleanup_poll() {
        let completion = Completion {
            ack: AtomicBool::new(true),
            error: Mutex::new(None),
        };
        let mut join = Some(thread::spawn(|| panic!("synthetic owned worker failure")));
        while !join.as_ref().unwrap().is_finished() {
            thread::yield_now();
        }
        assert!(!confirmed_worker_exit(&completion, &mut join));
        assert!(!confirmed_worker_exit(&completion, &mut join));
        assert_eq!(
            *completion.error.lock().unwrap(),
            Some("camera_worker_unconfirmed")
        );
    }
    #[test]
    fn failed_start_waits_for_authoritative_cleanup_ack_instead_of_box_absence() {
        let completion = Arc::new(Completion {
            ack: AtomicBool::new(false),
            error: Mutex::new(None),
        });
        let owned = completion.clone();
        let (called, calls) = std::sync::mpsc::channel();
        let (allow, wait) = std::sync::mpsc::channel();
        let worker = thread::spawn(move || {
            let mut tries = 0;
            cleanup_pending(&owned, || {
                tries += 1;
                called.send(tries).unwrap();
                if tries == 1 {
                    bail!("native_owner_retained")
                }
                wait.recv().unwrap();
                Ok(())
            });
        });
        assert_eq!(calls.recv().unwrap(), 1);
        assert!(!completion.ack.load(Ordering::SeqCst));
        assert_eq!(calls.recv().unwrap(), 2);
        assert!(!completion.ack.load(Ordering::SeqCst));
        allow.send(()).unwrap();
        worker.join().unwrap();
        assert!(completion.ack.load(Ordering::SeqCst));
        let clean = Completion {
            ack: AtomicBool::new(false),
            error: Mutex::new(None),
        };
        cleanup_pending(&clean, || Ok(()));
        assert!(clean.ack.load(Ordering::SeqCst));
    }
}
