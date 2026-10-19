//! The controlled side's own view of one streamed display, sent to its
//! controllers about once a second so their quality panel can show where time
//! goes on this side and what limits the frame rate.
use base::message_proto::NikoHostVideoStats;
#[cfg(not(any(target_os = "android", target_os = "ios")))]
use base::message_proto::{misc, Message, Misc};
#[cfg(not(any(target_os = "android", target_os = "ios")))]
use std::time::{Duration, Instant};

#[cfg(not(any(target_os = "android", target_os = "ios")))]
pub(crate) struct HostVideoStats {
    display: i32,
    refresh_milli_hz: u32,
    frames: u32,
    capture: Duration,
    convert: Duration,
    encode: Duration,
    since: Instant,
}

#[cfg(not(any(target_os = "android", target_os = "ios")))]
impl HostVideoStats {
    const EVERY: Duration = Duration::from_secs(1);

    pub(crate) fn new(display: usize, display_name: Option<String>) -> Self {
        Self {
            display: display as i32,
            refresh_milli_hz: display_name.as_deref().map_or(0, refresh_milli_hz),
            frames: 0,
            capture: Duration::ZERO,
            convert: Duration::ZERO,
            encode: Duration::ZERO,
            since: Instant::now(),
        }
    }

    /// One new picture: time to capture it, convert it for the encoder, and
    /// encode and hand it to the connections.
    pub(crate) fn add(&mut self, capture: Duration, convert: Duration, encode: Duration) {
        self.frames += 1;
        self.capture += capture;
        self.convert += convert;
        self.encode += encode;
    }

    /// The window's summary once a second has passed, then a fresh window.
    pub(crate) fn take(
        &mut self,
        (width, height): (usize, usize),
        encoder: impl std::fmt::Debug,
        hardware: bool,
        limit: Duration,
    ) -> Option<Message> {
        let elapsed = self.since.elapsed();
        if elapsed < Self::EVERY {
            return None;
        }
        let encoder = format!("{encoder:?}");
        let stats = self.summary(elapsed, (width, height), &encoder, hardware, limit);
        self.frames = 0;
        self.capture = Duration::ZERO;
        self.convert = Duration::ZERO;
        self.encode = Duration::ZERO;
        self.since = Instant::now();
        let mut misc = Misc::new();
        misc.union = Some(misc::Union::NikodeskHostVideoStats(stats));
        let mut message = Message::new();
        message.set_misc(misc);
        Some(message)
    }

    fn summary(
        &self,
        elapsed: Duration,
        (width, height): (usize, usize),
        encoder: &str,
        hardware: bool,
        limit: Duration,
    ) -> NikoHostVideoStats {
        let mean = |total: Duration| {
            if self.frames == 0 {
                0
            } else {
                (total.as_micros() / self.frames as u128).min(u32::MAX as u128) as u32
            }
        };
        let per_second_milli = |count: f64, seconds: f64| {
            if seconds <= 0. {
                0
            } else {
                (count / seconds * 1000.).round().clamp(0., u32::MAX as f64) as u32
            }
        };
        NikoHostVideoStats {
            display: self.display,
            width: width.min(u32::MAX as usize) as u32,
            height: height.min(u32::MAX as usize) as u32,
            encoder: encoder.to_owned(),
            hardware,
            frames_milli: per_second_milli(self.frames as f64, elapsed.as_secs_f64()),
            limit_milli: per_second_milli(1., limit.as_secs_f64()),
            refresh_milli_hz: self.refresh_milli_hz,
            capture_us: mean(self.capture),
            convert_us: mean(self.convert),
            encode_us: mean(self.encode),
            // Only the Mac capturers return at once when nothing changed.
            capture_includes_wait: !cfg!(target_os = "macos"),
            ..Default::default()
        }
    }
}

#[cfg(not(any(target_os = "android", target_os = "ios")))]
fn refresh_milli_hz(display_name: &str) -> u32 {
    #[cfg(any(target_os = "macos", target_os = "windows"))]
    return crate::platform::nikodesk_refresh_milli_hz(display_name);
    #[cfg(not(any(target_os = "macos", target_os = "windows")))]
    {
        let _ = display_name;
        0
    }
}

/// What a controller's panel may show of [NikoHostVideoStats]: values outside
/// plausible ranges become unknown rather than being displayed.
pub(crate) fn to_ui_json(stats: &NikoHostVideoStats) -> Option<String> {
    if !(0..64).contains(&stats.display)
        || !(1..=16384).contains(&stats.width)
        || !(1..=16384).contains(&stats.height)
    {
        return None;
    }
    let encoder: String = stats
        .encoder
        .chars()
        .filter(|c| c.is_ascii_alphanumeric())
        .take(16)
        .collect();
    let rate = |milli: u32| (milli <= 1_000_000).then(|| milli as f64 / 1000.);
    let hertz = |milli: u32| (1..=1_000_000).contains(&milli).then(|| milli as f64 / 1000.);
    let ms = |us: u32| (us <= 60_000_000).then(|| us as f64 / 1000.);
    serde_json::to_string(&serde_json::json!({
        "display": stats.display,
        "width": stats.width,
        "height": stats.height,
        "encoder": encoder,
        "hardware": stats.hardware,
        "fps": rate(stats.frames_milli),
        "limit": hertz(stats.limit_milli),
        "refreshHz": hertz(stats.refresh_milli_hz),
        "captureMs": ms(stats.capture_us),
        "convertMs": ms(stats.convert_us),
        "encodeMs": ms(stats.encode_us),
        "captureIncludesWait": stats.capture_includes_wait,
    }))
    .ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_window_reports_means_rates_and_the_limit() {
        let mut stats = HostVideoStats::new(1, None);
        for _ in 0..4 {
            stats.add(
                Duration::from_millis(3),
                Duration::from_millis(2),
                Duration::from_micros(500),
            );
        }
        let summary = stats.summary(
            Duration::from_secs(2),
            (3200, 1800),
            "H265",
            true,
            Duration::from_secs_f64(1. / 60.),
        );
        assert_eq!(summary.display, 1);
        assert_eq!((summary.width, summary.height), (3200, 1800));
        assert_eq!(summary.frames_milli, 2000);
        assert_eq!(summary.limit_milli, 60000);
        assert_eq!(summary.capture_us, 3000);
        assert_eq!(summary.convert_us, 2000);
        assert_eq!(summary.encode_us, 500);
        assert_eq!(summary.capture_includes_wait, !cfg!(target_os = "macos"));
    }

    #[test]
    fn a_quiet_window_reports_no_durations_and_waits_for_a_second() {
        let mut stats = HostVideoStats::new(0, None);
        assert!(stats
            .take((1920, 1080), "VP9", false, Duration::from_millis(33))
            .is_none());
        let summary = stats.summary(
            Duration::from_secs(1),
            (1920, 1080),
            "VP9",
            false,
            Duration::ZERO,
        );
        assert_eq!(summary.frames_milli, 0);
        assert_eq!(summary.limit_milli, 0);
        assert_eq!((summary.capture_us, summary.convert_us, summary.encode_us), (0, 0, 0));
    }

    #[test]
    fn the_panel_gets_only_plausible_values() {
        let stats = NikoHostVideoStats {
            display: 0,
            width: 3200,
            height: 1800,
            encoder: "H265<script>".into(),
            hardware: true,
            frames_milli: 54_200,
            limit_milli: 60_000,
            refresh_milli_hz: 0,
            capture_us: 3_100,
            convert_us: u32::MAX,
            encode_us: 800,
            capture_includes_wait: false,
            ..Default::default()
        };
        let json: serde_json::Value =
            serde_json::from_str(&to_ui_json(&stats).unwrap()).unwrap();
        assert_eq!(json["encoder"], "H265script");
        assert_eq!(json["fps"], 54.2);
        assert_eq!(json["limit"], 60.0);
        assert!(json["refreshHz"].is_null());
        assert_eq!(json["captureMs"], 3.1);
        assert!(json["convertMs"].is_null());
        assert!(to_ui_json(&NikoHostVideoStats { width: 0, ..stats.clone() }).is_none());
        assert!(to_ui_json(&NikoHostVideoStats { display: -1, ..stats }).is_none());
    }
}
