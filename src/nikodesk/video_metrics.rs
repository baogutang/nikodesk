use serde::Serialize;
use std::{
    cell::RefCell,
    sync::{
        atomic::{AtomicBool, AtomicU64, Ordering},
        Arc, Mutex,
    },
    time::Instant,
};

pub const MAX_DISPLAYS: usize = 16;
pub const MAX_STAGE_SAMPLES: u64 = 8;
const HISTOGRAM_BINS: usize = 32;
static NEXT_EPOCH: AtomicU64 = AtomicU64::new(1);

#[derive(Debug)]
struct Control {
    enabled: Arc<AtomicBool>,
    revision: Arc<AtomicU64>,
    active: AtomicBool,
    latest: Mutex<Option<(u64, Instant)>>,
}

pub struct SessionTelemetry {
    namespace: String,
    epoch: u64,
    connection_route: Mutex<Option<String>>,
    control: Arc<Control>,
    displays: [Arc<DisplayTelemetry>; MAX_DISPLAYS],
}

pub struct DisplayTelemetry {
    display: usize,
    control: Arc<Control>,
    counters: Mutex<Counters>,
}

#[derive(Clone, Copy)]
pub enum Stage {
    DecodeConvert,
    NativeSubmit,
}

#[derive(Clone, Copy)]
pub enum Counter {
    DecodedCallbacks,
    DecodeErrors,
    DeltaOverflow,
    RefreshDiscard,
    NativeCalls,
    NoTarget,
    NoPointer,
    SizeMismatch,
    MissingPlugin,
    SoftBusy,
    SoftNoConsumer,
}

#[derive(Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
struct StageSamples {
    samples: u64,
    total_us: u64,
    max_us: u64,
    histogram_us_log2: [u64; HISTOGRAM_BINS],
    #[serde(skip)]
    reserved: u64,
}

#[derive(Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
struct Counters {
    decoded_callbacks: u64,
    decode_errors: u64,
    delta_overflow: u64,
    refresh_discard: u64,
    native_calls: u64,
    no_target: u64,
    no_pointer: u64,
    size_mismatch: u64,
    missing_plugin: u64,
    soft_busy: u64,
    soft_no_consumer: u64,
    delta_queue_max: usize,
    decoder_backend: Option<&'static str>,
    hardware_decoder: Option<bool>,
    decode_convert: StageSamples,
    native_submit: StageSamples,
    #[serde(skip)]
    window: u64,
    #[serde(skip)]
    revision: u64,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct VideoSnapshot {
    schema_version: u8,
    namespace: String,
    epoch: String,
    revision: String,
    sequence: String,
    #[serde(skip)]
    captured_revision: u64,
    #[serde(skip)]
    control: Arc<Control>,
    window_ms: u64,
    display_limit: usize,
    displays: Vec<DisplaySnapshot>,
}

#[derive(Debug, Serialize)]
struct DisplaySnapshot {
    display: usize,
    #[serde(flatten)]
    counters: Counters,
}

impl SessionTelemetry {
    pub fn new(namespace: String, enabled: Arc<AtomicBool>, revision: Arc<AtomicU64>) -> Self {
        let epoch = NEXT_EPOCH
            .fetch_update(Ordering::Relaxed, Ordering::Relaxed, |value| {
                value.checked_add(1)
            })
            .unwrap_or(0);
        let control = Arc::new(Control {
            enabled,
            revision,
            active: AtomicBool::new(
                epoch != 0
                    && namespace.len() == 64
                    && namespace
                        .bytes()
                        .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte)),
            ),
            latest: Mutex::new(None),
        });
        Self {
            namespace,
            epoch,
            connection_route: Mutex::new(None),
            displays: std::array::from_fn(|display| {
                Arc::new(DisplayTelemetry {
                    display,
                    control: control.clone(),
                    counters: Mutex::new(Counters::default()),
                })
            }),
            control,
        }
    }

    pub fn epoch(&self) -> u64 {
        self.epoch
    }
    pub fn namespace(&self) -> &str {
        &self.namespace
    }
    pub(crate) fn capture_connection_route(&self, route: &super::connection_snapshot::ConnectionSnapshot, direct: bool) {
        if self.is_active() {
            *self.connection_route.lock().unwrap() = route.connected_route_json(direct);
        }
    }
    pub(crate) fn connection_route(&self) -> Option<String> {
        if !self.is_active() { return None; }
        self.connection_route.lock().unwrap().clone()
    }
    pub fn revision(&self) -> u64 {
        self.control.revision.load(Ordering::Acquire)
    }
    pub fn display(&self, display: usize) -> Option<Arc<DisplayTelemetry>> {
        self.displays.get(display).cloned()
    }
    pub fn stop(&self) {
        self.control.active.store(false, Ordering::Release);
    }
    pub fn is_active(&self) -> bool {
        self.control.active.load(Ordering::Acquire)
    }
    pub fn binding(&self) -> Option<String> {
        if !self.is_active() {
            return None;
        }
        let revision = self.revision();
        let enabled = self.control.enabled.load(Ordering::Acquire);
        let (sequence, age) = if enabled {
            let latest = self.control.latest.lock().unwrap();
            match latest.as_ref() {
                Some((sequence, at)) => (
                    Some(sequence.to_string()),
                    Some(at.elapsed().as_millis().min(u64::MAX as u128) as u64),
                ),
                None => (None, None),
            }
        } else {
            (None, None)
        };
        if !self.is_active() || self.revision() != revision {
            return None;
        }
        serde_json::to_string(&serde_json::json!({
            "namespace": self.namespace, "epoch": self.epoch.to_string(), "revision": revision.to_string(),
            "enabled": enabled && self.control.enabled.load(Ordering::Acquire), "sequence": sequence, "sampleAgeMs": age,
        })).ok()
    }

    pub fn snapshot(&self, window_ms: u64) -> Option<VideoSnapshot> {
        let enabled = self.control.enabled.load(Ordering::Acquire)
            && self.control.active.load(Ordering::Acquire);
        if !enabled {
            return None;
        }
        let revision = self.control.revision.load(Ordering::Acquire);
        let mut displays = Vec::new();
        for display in &self.displays {
            let mut counters = display.counters.lock().unwrap();
            display.refresh(&mut counters, revision);
            let next_window = counters.window.wrapping_add(1);
            let backend = if enabled {
                counters.decoder_backend
            } else {
                None
            };
            let hardware = if enabled {
                counters.hardware_decoder
            } else {
                None
            };
            let old = std::mem::replace(
                &mut *counters,
                Counters {
                    window: next_window,
                    revision,
                    decoder_backend: backend,
                    hardware_decoder: hardware,
                    ..Default::default()
                },
            );
            if enabled
                && (old.decoder_backend.is_some()
                    || old.decoded_callbacks > 0
                    || old.decode_errors > 0
                    || old.delta_overflow > 0
                    || old.refresh_discard > 0
                    || old.native_calls > 0
                    || old.soft_busy > 0
                    || old.no_target > 0
                    || old.no_pointer > 0
                    || old.size_mismatch > 0
                    || old.missing_plugin > 0
                    || old.soft_no_consumer > 0)
            {
                displays.push(DisplaySnapshot {
                    display: display.display,
                    counters: old,
                });
            }
        }
        if !self.control.enabled.load(Ordering::Acquire)
            || !self.control.active.load(Ordering::Acquire)
            || self.control.revision.load(Ordering::Acquire) != revision
        {
            return None;
        }
        let sequence = {
            let mut latest = self.control.latest.lock().unwrap();
            let sequence = latest
                .as_ref()
                .map_or(Some(1), |(sequence, _)| sequence.checked_add(1));
            let Some(sequence) = sequence else {
                self.stop();
                return None;
            };
            *latest = Some((sequence, Instant::now()));
            sequence
        };
        enabled.then(|| VideoSnapshot {
            schema_version: 1,
            namespace: self.namespace.clone(),
            epoch: self.epoch.to_string(),
            revision: revision.to_string(),
            sequence: sequence.to_string(),
            captured_revision: revision,
            control: self.control.clone(),
            window_ms,
            display_limit: MAX_DISPLAYS,
            displays,
        })
    }
}

impl VideoSnapshot {
    pub fn is_current(&self) -> bool {
        self.control.enabled.load(Ordering::Acquire)
            && self.control.active.load(Ordering::Acquire)
            && self.control.revision.load(Ordering::Acquire) == self.captured_revision
    }
}

impl Drop for SessionTelemetry {
    fn drop(&mut self) {
        self.stop();
    }
}

impl DisplayTelemetry {
    fn enabled(&self) -> bool {
        self.control.enabled.load(Ordering::Acquire) && self.control.active.load(Ordering::Acquire)
    }

    fn refresh(&self, counters: &mut Counters, revision: u64) {
        if counters.revision != revision {
            *counters = Counters {
                revision,
                window: counters.window.wrapping_add(1),
                ..Default::default()
            };
        }
    }

    pub fn count(&self, kind: Counter) {
        if !self.enabled() {
            return;
        }
        let mut counters = self.counters.lock().unwrap();
        if !self.enabled() {
            return;
        }
        self.refresh(&mut counters, self.control.revision.load(Ordering::Acquire));
        let value = match kind {
            Counter::DecodedCallbacks => &mut counters.decoded_callbacks,
            Counter::DecodeErrors => &mut counters.decode_errors,
            Counter::DeltaOverflow => &mut counters.delta_overflow,
            Counter::RefreshDiscard => &mut counters.refresh_discard,
            Counter::NativeCalls => &mut counters.native_calls,
            Counter::NoTarget => &mut counters.no_target,
            Counter::NoPointer => &mut counters.no_pointer,
            Counter::SizeMismatch => &mut counters.size_mismatch,
            Counter::MissingPlugin => &mut counters.missing_plugin,
            Counter::SoftBusy => &mut counters.soft_busy,
            Counter::SoftNoConsumer => &mut counters.soft_no_consumer,
        };
        *value = value.saturating_add(1);
    }

    pub fn queue_depth(&self, depth: usize) {
        if !self.enabled() {
            return;
        }
        let mut counters = self.counters.lock().unwrap();
        if self.enabled() {
            self.refresh(&mut counters, self.control.revision.load(Ordering::Acquire));
            counters.delta_queue_max = counters.delta_queue_max.max(depth.min(120));
        }
    }

    fn clear_decoder(&self) {
        if !self.enabled() {
            return;
        }
        let mut counters = self.counters.lock().unwrap();
        if self.enabled() {
            counters.decoder_backend = None;
            counters.hardware_decoder = None;
        }
    }

    fn decoder(&self, backend: (&'static str, Option<bool>)) {
        if !self.enabled() {
            return;
        }
        let mut counters = self.counters.lock().unwrap();
        if self.enabled() {
            self.refresh(&mut counters, self.control.revision.load(Ordering::Acquire));
            counters.decoder_backend = Some(backend.0);
            counters.hardware_decoder = backend.1;
        }
    }

    fn reserve(&self, stage: Stage) -> Option<(u64, u64)> {
        if !self.enabled() {
            return None;
        }
        let mut counters = self.counters.lock().unwrap();
        if !self.enabled() {
            return None;
        }
        self.refresh(&mut counters, self.control.revision.load(Ordering::Acquire));
        let samples = match stage {
            Stage::DecodeConvert => &mut counters.decode_convert,
            Stage::NativeSubmit => &mut counters.native_submit,
        };
        if samples.reserved >= MAX_STAGE_SAMPLES {
            return None;
        }
        samples.reserved += 1;
        Some((counters.window, counters.revision))
    }

    fn finish(&self, stage: Stage, token: (u64, u64), us: u64) {
        if !self.enabled() {
            return;
        }
        let mut counters = self.counters.lock().unwrap();
        if !self.enabled()
            || counters.window != token.0
            || counters.revision != token.1
            || self.control.revision.load(Ordering::Acquire) != token.1
        {
            return;
        }
        let samples = match stage {
            Stage::DecodeConvert => &mut counters.decode_convert,
            Stage::NativeSubmit => &mut counters.native_submit,
        };
        let us = us.min(60_000_000);
        samples.samples = samples.samples.saturating_add(1);
        samples.total_us = samples.total_us.saturating_add(us);
        samples.max_us = samples.max_us.max(us);
        let bin = if us == 0 {
            0
        } else {
            (64 - us.leading_zeros()) as usize
        }
        .min(HISTOGRAM_BINS - 1);
        samples.histogram_us_log2[bin] = samples.histogram_us_log2[bin].saturating_add(1);
    }
}

thread_local! {
    static CURRENT: RefCell<Option<Arc<DisplayTelemetry>>> = const { RefCell::new(None) };
}

pub struct ThreadGuard(Option<Arc<DisplayTelemetry>>);
pub fn install_thread(display: Option<Arc<DisplayTelemetry>>) -> ThreadGuard {
    ThreadGuard(CURRENT.with(|current| current.replace(display)))
}
impl Drop for ThreadGuard {
    fn drop(&mut self) {
        CURRENT.with(|current| current.replace(self.0.take()));
    }
}

pub fn count(kind: Counter) {
    CURRENT.with(|current| {
        if let Some(display) = current.borrow().as_ref() {
            display.count(kind);
        }
    });
}
pub fn clear_decoder() {
    CURRENT.with(|current| {
        if let Some(display) = current.borrow().as_ref() {
            display.clear_decoder();
        }
    });
}
pub fn decoder_output(backend: impl FnOnce() -> (&'static str, Option<bool>)) {
    CURRENT.with(|current| {
        if let Some(display) = current.borrow().as_ref() {
            if display.enabled() {
                display.decoder(backend());
            }
        }
    });
}

pub struct StageTimer {
    display: Arc<DisplayTelemetry>,
    stage: Stage,
    token: (u64, u64),
    start: Instant,
}
pub fn measure(stage: Stage) -> Option<StageTimer> {
    CURRENT.with(|current| {
        let current = current.borrow();
        let display = current.as_ref()?;
        let token = display.reserve(stage)?;
        Some(StageTimer {
            display: display.clone(),
            stage,
            token,
            start: Instant::now(),
        })
    })
}
impl Drop for StageTimer {
    fn drop(&mut self) {
        if self.display.enabled()
            && self.display.control.revision.load(Ordering::Acquire) == self.token.1
        {
            self.display.finish(
                self.stage,
                self.token,
                self.start.elapsed().as_micros().min(u64::MAX as u128) as u64,
            );
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn session(enabled: bool) -> (SessionTelemetry, Arc<AtomicBool>) {
        let gate = Arc::new(AtomicBool::new(enabled));
        (
            SessionTelemetry::new("a".repeat(64), gate.clone(), Arc::new(AtomicU64::new(0))),
            gate,
        )
    }

    #[test]
    fn disabled_does_not_reserve_measure_or_increment() {
        let (session, _) = session(false);
        let display = session.display(0).unwrap();
        let _thread = install_thread(Some(display.clone()));
        assert!(measure(Stage::DecodeConvert).is_none());
        count(Counter::NativeCalls);
        display.queue_depth(120);
        assert!(session.snapshot(1000).is_none());
        let counters = display.counters.lock().unwrap();
        assert_eq!(counters.native_calls, 0);
        assert_eq!(counters.decode_convert.reserved, 0);
    }

    #[test]
    fn fixed_sampling_budget_and_exact_counters_reset_per_window() {
        let (session, _) = session(true);
        let display = session.display(0).unwrap();
        for _ in 0..1000 {
            display.count(Counter::DecodedCallbacks);
            if let Some(window) = display.reserve(Stage::DecodeConvert) {
                display.finish(Stage::DecodeConvert, window, 1234);
            }
        }
        display.queue_depth(9999);
        let snapshot = session.snapshot(1030).unwrap();
        assert_eq!(snapshot.displays[0].counters.decoded_callbacks, 1000);
        assert_eq!(snapshot.displays[0].counters.decode_convert.samples, 8);
        assert_eq!(snapshot.displays[0].counters.delta_queue_max, 120);
        assert!(session.snapshot(1000).unwrap().displays.is_empty());
    }

    #[test]
    fn stopped_and_disabled_late_work_is_discarded() {
        let (session, gate) = session(true);
        let display = session.display(0).unwrap();
        let window = display.reserve(Stage::NativeSubmit).unwrap();
        gate.store(false, Ordering::Release);
        display.finish(Stage::NativeSubmit, window, 12);
        display.count(Counter::NativeCalls);
        assert_eq!(display.counters.lock().unwrap().native_calls, 0);
        gate.store(true, Ordering::Release);
        session.stop();
        display.count(Counter::DecodedCallbacks);
        assert!(session.snapshot(1000).is_none());
    }

    #[test]
    fn old_window_timer_cannot_enter_new_window() {
        let (session, _) = session(true);
        let display = session.display(0).unwrap();
        let window = display.reserve(Stage::DecodeConvert).unwrap();
        session.snapshot(1000);
        display.finish(Stage::DecodeConvert, window, 100);
        assert_eq!(display.counters.lock().unwrap().decode_convert.samples, 0);
    }

    #[test]
    fn bounded_displays_epochs_and_actual_backend_unknown_hardware() {
        let (a, _) = session(true);
        let (b, _) = session(true);
        assert_ne!(a.epoch(), b.epoch());
        assert!(a.display(MAX_DISPLAYS).is_none());
        a.display(0).unwrap().decoder(("mediacodec", None));
        a.display(1).unwrap().decoder(("vpx-vp9", Some(false)));
        let snapshot = a.snapshot(1000).unwrap();
        assert_eq!(snapshot.displays.len(), 2);
        assert_eq!(snapshot.displays[0].counters.hardware_decoder, None);
        assert_eq!(snapshot.displays[1].counters.hardware_decoder, Some(false));
        assert!(b.snapshot(1000).unwrap().displays.is_empty());
    }

    #[test]
    fn revision_change_rejects_inflight_and_clears_previous_window() {
        let (session, gate) = session(true);
        let display = session.display(0).unwrap();
        display.count(Counter::NativeCalls);
        let token = display.reserve(Stage::NativeSubmit).unwrap();
        gate.store(false, Ordering::Release);
        session.control.revision.fetch_add(1, Ordering::AcqRel);
        gate.store(true, Ordering::Release);
        display.finish(Stage::NativeSubmit, token, 500);
        display.count(Counter::DecodedCallbacks);
        let snapshot = session.snapshot(1000).unwrap();
        assert_eq!(snapshot.displays[0].counters.native_calls, 0);
        assert_eq!(snapshot.displays[0].counters.native_submit.samples, 0);
        assert_eq!(snapshot.displays[0].counters.decoded_callbacks, 1);
    }

    #[test]
    fn binding_exposes_current_window_and_disabled_snapshot_is_invalid() {
        let (session, gate) = session(true);
        let snapshot = session.snapshot(1000).unwrap();
        let binding: serde_json::Value = serde_json::from_str(&session.binding().unwrap()).unwrap();
        assert_eq!(binding["epoch"], session.epoch().to_string());
        assert_eq!(binding["sequence"], snapshot.sequence);
        assert!(binding["sampleAgeMs"].as_u64().is_some());
        gate.store(false, Ordering::Release);
        assert!(!snapshot.is_current());
        let binding: serde_json::Value = serde_json::from_str(&session.binding().unwrap()).unwrap();
        assert_eq!(binding["enabled"], false);
        assert!(binding["sampleAgeMs"].is_null());
        session.stop();
        assert!(session.binding().is_none());
    }

    #[test]
    fn synthetic_software_codec_roundtrip_reports_actual_instances_without_config() {
        use scrap::{
            aom::AomEncoderConfig,
            codec::{Decoder, Encoder, EncoderCfg},
            CodecFormat, EncodeInput, ImageFormat, ImageRgb, ImageTexture, VpxEncoderConfig,
            VpxVideoCodecId,
        };
        for (format, config, backend) in [
            (
                CodecFormat::VP8,
                EncoderCfg::VPX(VpxEncoderConfig {
                    width: 64,
                    height: 64,
                    quality: 1.0,
                    codec: VpxVideoCodecId::VP8,
                    keyframe_interval: None,
                }),
                "vpx-vp8",
            ),
            (
                CodecFormat::VP9,
                EncoderCfg::VPX(VpxEncoderConfig {
                    width: 64,
                    height: 64,
                    quality: 1.0,
                    codec: VpxVideoCodecId::VP9,
                    keyframe_interval: None,
                }),
                "vpx-vp9",
            ),
            (
                CodecFormat::AV1,
                EncoderCfg::AOM(AomEncoderConfig {
                    width: 64,
                    height: 64,
                    quality: 1.0,
                    keyframe_interval: None,
                }),
                "aom-av1",
            ),
        ] {
            // Only the software constructors are used: no Config, Display or Capturer path.
            let mut encoder = Encoder::new(config, false).unwrap();
            let fmt = encoder.yuvfmt();
            let len = (fmt.v + fmt.stride[1] * fmt.h / 2)
                .max(fmt.u + fmt.stride[1] * fmt.h / 2)
                .max(fmt.stride[0] * fmt.h);
            let mut yuv = vec![128u8; len];
            for y in 0..64 {
                for x in 0..64 {
                    yuv[y * fmt.stride[0] + x] = 32 + ((x + y) % 128) as u8;
                }
            }
            let frame = encoder
                .encode_to_message(EncodeInput::YUV(&yuv), 0)
                .unwrap();
            let mut decoder = Decoder::new(format, None);
            let mut rgb = ImageRgb::new(ImageFormat::ARGB, 1);
            let mut texture = ImageTexture::default();
            let mut pixelbuffer = true;
            let mut chroma = None;
            let (session, _) = session(true);
            let _thread = install_thread(session.display(0));
            let timer = measure(Stage::DecodeConvert);
            let output = decoder
                .handle_video_frame(
                    frame.union.as_ref().unwrap(),
                    &mut rgb,
                    &mut texture,
                    &mut pixelbuffer,
                    &mut chroma,
                )
                .unwrap();
            drop(timer);
            assert!(output);
            assert_eq!((rgb.w, rgb.h), (64, 64));
            assert!(!rgb.raw.is_empty());
            assert!(chroma.is_some());
            assert_eq!(decoder.niko_backend(), (backend, Some(false)));
            decoder_output(|| decoder.niko_backend());
            count(Counter::DecodedCallbacks);
            let snapshot = session.snapshot(1000).unwrap();
            assert_eq!(snapshot.displays[0].counters.decoder_backend, Some(backend));
            assert_eq!(snapshot.displays[0].counters.decode_convert.samples, 1);
            assert_eq!(snapshot.displays[0].counters.decoded_callbacks, 1);
        }
    }
}
