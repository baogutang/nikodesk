//! Development-only latency probe for a controller (feature `nikodesk-probe`).
//!
//! The controller clicks the middle of the controlled display, where
//! `scripts/latency-target.swift` shows a square that turns black or white on
//! every click, and times how long the new colour takes to reach the decoded
//! picture and the UI. Every time comes from this device's clock, so no clock
//! sync between the two machines is involved. A second step clicks the
//! target's motion corner and records frame rate, bitrate and decode cost
//! while the target animates.
//!
//! It runs only when `NIKODESK_PROBE_PLAN` is set in the environment and
//! writes `<APP_DIR>/nikodesk-probe/<unix ms>.json`.
use crate::{
    common::input::{MOUSE_BUTTON_LEFT, MOUSE_TYPE_DOWN, MOUSE_TYPE_MOVE, MOUSE_TYPE_UP},
    flutter::sessions,
};
use base::message_proto::{video_frame, VideoFrame};
use hbb_common::{config, get_time, log};
use serde::Serialize;
use std::{
    sync::Mutex,
    time::{Duration, Instant},
};

const PLAN_ENV: &str = "NIKODESK_PROBE_PLAN";
/// Luma (0-255) above which the square counts as white, and below which as black.
const WHITE: u32 = 180;
const BLACK: u32 = 75;
const SAMPLE_EDGE: usize = 8;

#[derive(Clone, Debug, Serialize)]
struct Plan {
    warmup_s: u64,
    clicks: u32,
    interval_ms: u64,
    timeout_ms: u64,
    motion_s: u64,
    /// 0 keeps the default picture (balanced quality, which the host holds to
    /// 30 fps); otherwise the responsive mode's request at this frame rate.
    fps: u32,
}

impl Plan {
    /// `clicks=200,interval=600,warmup=8,timeout=3000,motion=30,fps=0`; missing keys keep defaults.
    fn parse(text: &str) -> Self {
        let mut plan = Plan {
            warmup_s: 8,
            clicks: 200,
            interval_ms: 600,
            timeout_ms: 3000,
            motion_s: 30,
            fps: 0,
        };
        for part in text.split(',') {
            let Some((key, value)) = part.split_once('=') else {
                continue;
            };
            let Ok(value) = value.trim().parse::<u64>() else {
                continue;
            };
            match key.trim() {
                "warmup" => plan.warmup_s = value,
                "clicks" => plan.clicks = value.min(10_000) as u32,
                "interval" => plan.interval_ms = value.max(200),
                "timeout" => plan.timeout_ms = value.max(500),
                "motion" => plan.motion_s = value,
                "fps" => plan.fps = value.min(120) as u32,
                _ => {}
            }
        }
        plan
    }
}

#[derive(Default, Serialize)]
struct Sample {
    /// Click sent until the first decoded picture with the new colour.
    decoded_ms: Option<f64>,
    /// Until the first picture with the new colour that the UI accepted.
    accepted_ms: Option<f64>,
    /// Until the UI released that picture, i.e. made an image of it.
    handed_ms: Option<f64>,
    /// Decoded pictures with the new colour the UI was too busy to take.
    dropped: u32,
    /// Wall clock (ms since the epoch) when the click was sent; the host logs the same clock.
    sent_wall_ms: i64,
    /// Frame timestamp of the first picture that showed the new colour.
    pts: Option<i64>,
}

struct Pending {
    sent: Instant,
    want_white: bool,
    sample: Sample,
    /// The last decoded picture showed the wanted colour.
    last_decoded_matches: bool,
    awaiting_hand: bool,
}

#[derive(Serialize)]
struct FrameStat {
    at_ms: f64,
    bytes: usize,
    decode_us: u64,
    ok: bool,
    pts: i64,
    /// Wall clock when the frame arrived, before decoding.
    arrived_wall_ms: i64,
}

#[derive(Default)]
struct State {
    epoch: Option<Instant>,
    pending: Option<Pending>,
    frames: Vec<FrameStat>,
    width: usize,
    height: usize,
    codec: String,
    decoder: String,
    last_luma: Option<u32>,
    last_pts: i64,
}

static STATE: Mutex<Option<State>> = Mutex::new(None);

fn with_state<R>(f: impl FnOnce(&mut State) -> R) -> Option<R> {
    let mut guard = STATE.lock().unwrap();
    guard.as_mut().map(f)
}

fn ms(from: Instant, to: Instant) -> f64 {
    to.saturating_duration_since(from).as_secs_f64() * 1000.0
}

/// Mean luma of a small block in the middle of a BGRA or RGBA picture.
fn centre_luma(raw: &[u8], width: usize, height: usize) -> Option<u32> {
    if width < SAMPLE_EDGE || height < SAMPLE_EDGE || raw.is_empty() {
        return None;
    }
    let stride = raw.len() / height;
    if stride < width * 4 {
        return None;
    }
    let (x0, y0) = (width / 2 - SAMPLE_EDGE / 2, height / 2 - SAMPLE_EDGE / 2);
    let mut sum = 0u32;
    for y in y0..y0 + SAMPLE_EDGE {
        for x in x0..x0 + SAMPLE_EDGE {
            let p = y * stride + x * 4;
            let (a, b, c) = (raw[p] as u32, raw[p + 1] as u32, raw[p + 2] as u32);
            sum += (a + b + c) / 3;
        }
    }
    Some(sum / (SAMPLE_EDGE * SAMPLE_EDGE) as u32)
}

fn matches(luma: u32, want_white: bool) -> bool {
    if want_white {
        luma >= WHITE
    } else {
        luma <= BLACK
    }
}

/// Every received video frame: its encoded size and how long decoding took.
pub(crate) fn frame(bytes: usize, decode: Duration, ok: bool, codec: &str, decoder: &str, pts: i64) {
    let now = Instant::now();
    with_state(|s| {
        let Some(epoch) = s.epoch else { return };
        s.last_pts = pts;
        if s.codec.is_empty() {
            s.codec = codec.to_owned();
        }
        if ok && s.decoder != decoder {
            s.decoder = decoder.to_owned();
        }
        s.frames.push(FrameStat {
            at_ms: ms(epoch, now),
            bytes,
            decode_us: decode.as_micros() as u64,
            ok,
            pts,
            arrived_wall_ms: get_time() - decode.as_millis() as i64,
        });
    });
}

/// A decoded picture, before the UI is offered it.
// Only the mobile UI path hands decoded pictures over here.
#[cfg_attr(not(any(target_os = "android", target_os = "ios")), allow(dead_code))]
pub(crate) fn decoded(rgba: &scrap::ImageRgb) {
    let now = Instant::now();
    with_state(|s| {
        s.width = rgba.w;
        s.height = rgba.h;
        let Some(luma) = centre_luma(&rgba.raw, rgba.w, rgba.h) else { return };
        s.last_luma = Some(luma);
        let pts = s.last_pts;
        if let Some(p) = s.pending.as_mut() {
            p.last_decoded_matches = matches(luma, p.want_white);
            if p.last_decoded_matches && p.sample.decoded_ms.is_none() {
                p.sample.decoded_ms = Some(ms(p.sent, now));
                p.sample.pts = Some(pts);
            }
        }
    });
}

/// The UI took the picture last passed to [`decoded`].
pub(crate) fn accepted() {
    let now = Instant::now();
    with_state(|s| {
        if let Some(p) = s.pending.as_mut() {
            if p.last_decoded_matches && p.sample.accepted_ms.is_none() {
                p.sample.accepted_ms = Some(ms(p.sent, now));
                p.awaiting_hand = true;
            }
        }
    });
}

/// The UI was busy and dropped the picture last passed to [`decoded`].
pub(crate) fn dropped() {
    with_state(|s| {
        if let Some(p) = s.pending.as_mut() {
            if p.last_decoded_matches && p.sample.accepted_ms.is_none() {
                p.sample.dropped += 1;
            }
        }
    });
}

/// The UI finished with the picture it accepted last.
pub(crate) fn handed() {
    let now = Instant::now();
    with_state(|s| {
        if let Some(p) = s.pending.as_mut() {
            if p.awaiting_hand && p.sample.handed_ms.is_none() {
                p.sample.handed_ms = Some(ms(p.sent, now));
                p.awaiting_hand = false;
            }
        }
    });
}

/// Starts the probe for a new remote-control session when the plan is set.
pub(crate) fn start(session_id: crate::flutter_ffi::SessionID) {
    let Ok(text) = std::env::var(PLAN_ENV) else { return };
    let plan = Plan::parse(&text);
    {
        let mut guard = STATE.lock().unwrap();
        if guard.is_some() {
            log::warn!("NikoDesk probe already running; not starting another");
            return;
        }
        *guard = Some(State::default());
    }
    log::info!("NikoDesk probe armed: {plan:?}");
    std::thread::spawn(move || {
        let report = run(session_id, &plan);
        let state = STATE.lock().unwrap().take();
        match (report, state) {
            (Ok(samples), Some(state)) => write(&plan, samples, state),
            (Err(reason), _) => {
                log::error!("NikoDesk probe failed: {reason}");
                println!("NIKODESK-PROBE failed: {reason}");
            }
            (Ok(_), None) => {}
        }
    });
}

struct Clicked {
    samples: Vec<Sample>,
    timeouts: u32,
    motion_from_ms: f64,
    motion_to_ms: f64,
}

fn display_rect(session_id: &crate::flutter_ffi::SessionID) -> Option<(i32, i32, i32, i32)> {
    let session = sessions::get_session_by_session_id(session_id)?;
    let lc = session.lc.read().unwrap();
    let pi = lc.peer_info.as_ref()?;
    let d = pi
        .displays
        .get(pi.current_display as usize)
        .or_else(|| pi.displays.first())?;
    Some((d.x, d.y, d.width, d.height))
}

fn click(session_id: &crate::flutter_ffi::SessionID, x: i32, y: i32) -> bool {
    let Some(session) = sessions::get_session_by_session_id(session_id) else {
        return false;
    };
    // The controlled side presses where its pointer is, so move it there first.
    session.send_mouse(MOUSE_TYPE_MOVE, x, y, false, false, false, false);
    session.send_mouse(MOUSE_TYPE_DOWN | MOUSE_BUTTON_LEFT << 3, x, y, false, false, false, false);
    session.send_mouse(MOUSE_TYPE_UP | MOUSE_BUTTON_LEFT << 3, x, y, false, false, false, false);
    true
}

fn run(session_id: crate::flutter_ffi::SessionID, plan: &Plan) -> Result<Clicked, String> {
    let begin = Instant::now();
    with_state(|s| s.epoch = Some(begin));
    let rect = loop {
        let decoded = with_state(|s| s.last_luma.is_some()).unwrap_or(false);
        if decoded {
            if let Some(rect) = display_rect(&session_id) {
                break rect;
            }
        }
        if begin.elapsed() > Duration::from_secs(90) {
            return Err("no picture within 90 s".to_owned());
        }
        if sessions::get_session_by_session_id(&session_id).is_none() {
            return Err("session closed before the first picture".to_owned());
        }
        std::thread::sleep(Duration::from_millis(100));
    };
    // Saved in the probe's peer config, so a run without `fps` resets it.
    if let Some(session) = sessions::get_session_by_session_id(&session_id) {
        if plan.fps > 0 {
            session.save_image_quality("custom".to_owned());
            session.save_custom_image_quality(50);
            session.set_custom_fps(plan.fps as _);
        } else {
            session.save_image_quality("balanced".to_owned());
        }
    }
    println!("NIKODESK-PROBE connected, fps request {}, warming up {} s", plan.fps, plan.warmup_s);
    std::thread::sleep(Duration::from_secs(plan.warmup_s));
    let (x0, y0, w, h) = rect;
    let (cx, cy) = (x0 + w / 2, y0 + h / 2);
    let mut samples = Vec::with_capacity(plan.clicks as usize);
    let mut timeouts = 0;
    for n in 0..plan.clicks {
        let Some(luma) = with_state(|s| s.last_luma).flatten() else {
            return Err("picture stopped".to_owned());
        };
        // The target starts black, but resynchronise from the picture itself.
        let want_white = luma < (WHITE + BLACK) / 2;
        let sent = Instant::now();
        with_state(|s| {
            s.pending = Some(Pending {
                sent,
                want_white,
                sample: Sample { sent_wall_ms: get_time(), ..Sample::default() },
                last_decoded_matches: false,
                awaiting_hand: false,
            })
        });
        if !click(&session_id, cx, cy) {
            return Err("session closed".to_owned());
        }
        let deadline = sent + Duration::from_millis(plan.timeout_ms);
        loop {
            let done = with_state(|s| {
                s.pending
                    .as_ref()
                    .map_or(true, |p| p.sample.handed_ms.is_some())
            })
            .unwrap_or(true);
            if done || Instant::now() >= deadline {
                break;
            }
            std::thread::sleep(Duration::from_millis(1));
        }
        let sample = with_state(|s| s.pending.take().map(|p| p.sample))
            .flatten()
            .unwrap_or_default();
        if sample.handed_ms.is_none() {
            timeouts += 1;
        }
        if (n + 1) % 25 == 0 {
            println!("NIKODESK-PROBE {} / {} clicks", n + 1, plan.clicks);
        }
        samples.push(sample);
        let next = sent + Duration::from_millis(plan.interval_ms);
        let now = Instant::now();
        if next > now {
            std::thread::sleep(next - now);
        }
    }
    let (mut motion_from_ms, mut motion_to_ms) = (0.0, 0.0);
    if plan.motion_s > 0 {
        // The target's motion corner; it animates for the time it was started with.
        // Above the Dock, which takes clicks in the bottom few percent.
        let (mx, my) = (x0 + w * 94 / 100, y0 + h * 90 / 100);
        if !click(&session_id, mx, my) {
            return Err("session closed".to_owned());
        }
        println!("NIKODESK-PROBE motion {} s", plan.motion_s);
        let started = Instant::now();
        // The controlled side raises its frame limit gradually; skip the ramp.
        let settle = Duration::from_secs(plan.motion_s.min(8));
        std::thread::sleep(settle);
        motion_from_ms = ms(begin, Instant::now());
        let rest = Duration::from_secs(plan.motion_s).saturating_sub(started.elapsed() + Duration::from_secs(1));
        std::thread::sleep(rest);
        motion_to_ms = ms(begin, Instant::now());
    }
    Ok(Clicked {
        samples,
        timeouts,
        motion_from_ms,
        motion_to_ms,
    })
}

#[derive(Serialize)]
struct Summary {
    count: usize,
    median: f64,
    p90: f64,
    p95: f64,
    max: f64,
}

fn summary(mut values: Vec<f64>) -> Option<Summary> {
    if values.is_empty() {
        return None;
    }
    values.sort_by(|a, b| a.total_cmp(b));
    let at = |q: f64| values[((values.len() - 1) as f64 * q).round() as usize];
    Some(Summary {
        count: values.len(),
        median: at(0.5),
        p90: at(0.9),
        p95: at(0.95),
        max: values[values.len() - 1],
    })
}

#[derive(Serialize)]
struct Window {
    seconds: f64,
    frames: usize,
    fps: f64,
    mbit_per_s: f64,
    decode_ms: Option<Summary>,
    decode_errors: usize,
}

fn window(frames: &[FrameStat], from_ms: f64, to_ms: f64) -> Option<Window> {
    let seconds = (to_ms - from_ms) / 1000.0;
    if seconds <= 0.0 {
        return None;
    }
    let inside: Vec<&FrameStat> = frames
        .iter()
        .filter(|f| f.at_ms >= from_ms && f.at_ms < to_ms)
        .collect();
    let bytes: usize = inside.iter().map(|f| f.bytes).sum();
    Some(Window {
        seconds,
        frames: inside.len(),
        fps: inside.len() as f64 / seconds,
        mbit_per_s: bytes as f64 * 8.0 / seconds / 1e6,
        decode_ms: summary(inside.iter().map(|f| f.decode_us as f64 / 1000.0).collect()),
        decode_errors: inside.iter().filter(|f| !f.ok).count(),
    })
}

fn write(plan: &Plan, clicked: Clicked, state: State) {
    let pick = |f: fn(&Sample) -> Option<f64>| -> Vec<f64> {
        clicked.samples.iter().filter_map(f).collect()
    };
    let report = serde_json::json!({
        "plan": plan,
        "platform": std::env::consts::OS,
        "picture": { "width": state.width, "height": state.height },
        "codec": state.codec,
        "decoder": state.decoder,
        "click_to_decoded_ms": summary(pick(|s| s.decoded_ms)),
        "click_to_accepted_ms": summary(pick(|s| s.accepted_ms)),
        "click_to_handed_ms": summary(pick(|s| s.handed_ms)),
        "timeouts": clicked.timeouts,
        "busy_drops": clicked.samples.iter().map(|s| s.dropped).sum::<u32>(),
        "motion": window(&state.frames, clicked.motion_from_ms, clicked.motion_to_ms),
        "samples": clicked.samples,
        "frames": state.frames,
    });
    let line = serde_json::json!({
        "picture": report["picture"],
        "codec": report["codec"],
        "decoder": report["decoder"],
        "click_to_handed_ms": report["click_to_handed_ms"],
        "timeouts": report["timeouts"],
        "motion_fps": report["motion"]["fps"],
        "motion_mbit_per_s": report["motion"]["mbit_per_s"],
    });
    println!("NIKODESK-PROBE summary {line}");
    log::info!("NikoDesk probe summary {line}");
    let dir = std::path::Path::new(&*config::APP_DIR.read().unwrap()).join("nikodesk-probe");
    let stamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or_default();
    let path = dir.join(format!("{stamp}.json"));
    let result = std::fs::create_dir_all(&dir)
        .and_then(|_| std::fs::write(&path, report.to_string()));
    match result {
        Ok(()) => println!("NIKODESK-PROBE wrote {}", path.display()),
        Err(e) => {
            log::error!("NikoDesk probe could not write its report: {e}");
            println!("NIKODESK-PROBE failed: write {e}");
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn plan_keeps_defaults_for_missing_or_bad_keys() {
        let plan = Plan::parse("clicks=12,interval=50,bogus=1,motion=x");
        assert_eq!(plan.clicks, 12);
        assert_eq!(plan.interval_ms, 200);
        assert_eq!(plan.motion_s, 30);
        assert_eq!(plan.warmup_s, 8);
        assert_eq!(plan.fps, 0);
        assert_eq!(Plan::parse("fps=500").fps, 120);
    }

    #[test]
    fn centre_luma_reads_the_middle_with_row_padding() {
        let (w, h, stride) = (32usize, 16usize, 32 * 4 + 16);
        let mut raw = vec![0u8; stride * h];
        for y in 4..12 {
            for x in 12..20 {
                let p = y * stride + x * 4;
                raw[p..p + 3].copy_from_slice(&[255, 255, 255]);
            }
        }
        assert_eq!(centre_luma(&raw, w, h), Some(255));
        assert!(matches(255, true) && !matches(255, false));
    }

    #[test]
    fn summary_picks_rank_values() {
        let s = summary((1..=100).map(|v| v as f64).collect()).unwrap();
        assert_eq!((s.median, s.p95, s.max), (51.0, 95.0, 100.0));
    }
}

/// Frame timestamp of an encoded video frame; the host's frame log uses the same key.
pub(crate) fn pts_of(vf: &VideoFrame) -> i64 {
    let frames = match &vf.union {
        Some(video_frame::Union::H265s(f))
        | Some(video_frame::Union::H264s(f))
        | Some(video_frame::Union::Vp8s(f))
        | Some(video_frame::Union::Vp9s(f))
        | Some(video_frame::Union::Av1s(f)) => f,
        _ => return -1,
    };
    frames.frames.last().map_or(-1, |frame| frame.pts)
}
