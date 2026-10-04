//! A controller says how wide a picture it can show. The controlled Mac then
//! captures no more than the widest request among its controllers, scaled on
//! the GPU by the display stream, without changing the display mode.
use std::{collections::HashMap, sync::Mutex};

static WANTED: Mutex<Option<HashMap<i32, u32>>> = Mutex::new(None);

const NARROWEST: i32 = 640;

/// The edge to capture for these requests: the widest one, or zero (the
/// display's own size) when nobody asked.
fn widest(wanted: impl Iterator<Item = u32>) -> u32 {
    wanted.max().unwrap_or(0)
}

fn apply(wanted: &HashMap<i32, u32>) {
    let edge = widest(wanted.values().copied());
    #[cfg(target_os = "macos")]
    scrap::quartz::CAPTURE_LONG_EDGE.store(edge, std::sync::atomic::Ordering::Relaxed);
    #[cfg(not(target_os = "macos"))]
    let _ = edge;
}

/// Zero keeps this connection's earlier request, as an unset option does.
pub(crate) fn declare(conn: i32, width: i32) {
    if width <= 0 {
        return;
    }
    let mut wanted = WANTED.lock().unwrap();
    let wanted = wanted.get_or_insert_with(HashMap::new);
    wanted.insert(conn, width.max(NARROWEST) as u32);
    apply(wanted);
}

pub(crate) fn forget(conn: i32) {
    let mut wanted = WANTED.lock().unwrap();
    if let Some(wanted) = wanted.as_mut() {
        if wanted.remove(&conn).is_some() {
            apply(wanted);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_widest_controller_decides_and_nobody_means_native() {
        assert_eq!(widest([].into_iter()), 0);
        assert_eq!(widest([2560, 3840].into_iter()), 3840);
        assert_eq!(widest([3840, 65535].into_iter()), 65535);
    }

    #[test]
    fn only_a_plausible_width_is_sent() {
        use crate::nikodesk::capture_width;
        assert_eq!(capture_width("3840"), 3840);
        assert_eq!(capture_width("65535"), 65535);
        for value in ["", "0", "-1", "65536", "wide", "3840.5"] {
            assert_eq!(capture_width(value), 0, "{value}");
        }
    }

    #[test]
    fn a_change_is_sent_only_to_a_session_that_has_logged_in() {
        use crate::nikodesk::{capture_width_message, CAPTURE_WIDTH_OPTION};
        let sent = |option, value, version| {
            capture_width_message(option, value, version)
                .map(|msg| msg.misc().option().nikodesk_capture_width)
        };
        assert_eq!(sent(CAPTURE_WIDTH_OPTION, "3840", 1005000), Some(3840));
        assert_eq!(sent(CAPTURE_WIDTH_OPTION, "3840", 0), None);
        assert_eq!(sent(CAPTURE_WIDTH_OPTION, "", 1005000), None);
        assert_eq!(sent("custom-fps", "3840", 1005000), None);
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn a_hardware_encoder_is_given_time_after_a_restart() {
        use crate::nikodesk::encode_fail_limit;
        assert_eq!(encode_fail_limit(true, 3), 30);
        assert_eq!(encode_fail_limit(false, 3), 3);
    }

    #[test]
    fn a_request_is_kept_until_its_connection_leaves() {
        // Ids no real connection uses; the registry is process-wide.
        let (a, b) = (i32::MAX - 7, i32::MAX - 8);
        let edge = |conn: i32| WANTED.lock().unwrap().as_ref().and_then(|wanted| wanted.get(&conn).copied());
        declare(a, 3840);
        declare(b, 200);
        declare(a, 0);
        assert_eq!(edge(a), Some(3840));
        assert_eq!(edge(b), Some(NARROWEST as u32));
        forget(a);
        forget(b);
        assert_eq!(edge(a), None);
        assert_eq!(edge(b), None);
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn the_capture_scale_fills_the_controller_in_quarter_steps() {
        use scrap::quartz::capture_scale;
        // A 5K display in its default mode: 2560 by 1440 points at 2x.
        let five_k = |wanted| capture_scale(2., 2560, 1440, wanted);
        assert_eq!(five_k(0), 2.);
        assert_eq!(five_k(5120), 2.);
        assert_eq!(five_k(65535), 2.);
        assert_eq!(five_k(3840), 1.5);
        assert_eq!(five_k(3456), 1.5);
        assert_eq!(five_k(3200), 1.25);
        assert_eq!(five_k(2560), 1.);
        assert_eq!(five_k(640), 1.);
        // A display that is not Retina is never scaled.
        assert_eq!(capture_scale(1., 3840, 2160, 1920), 1.);
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn a_scale_is_used_only_when_points_stay_exact() {
        use scrap::quartz::capture_scale;
        // Point sizes of real Mac displays, including ones whose edges do not
        // divide evenly at every quarter step, and a rotated one.
        for (width, height) in [(2560, 1440), (1512, 982), (1728, 1117), (1470, 956), (1440, 900),
            (1710, 1112), (3008, 1692), (1920, 1080), (1680, 1050), (1440, 2560)] {
            for wanted in [640u32, 1280, 1920, 2400, 2560, 3024, 3840, 5120, 65535] {
                let scale = capture_scale(2., width, height, wanted);
                assert!((1. ..=2.).contains(&scale), "{width}x{height} {wanted}");
                for points in [width, height] {
                    let pixels = points as f64 * scale;
                    assert_eq!(pixels.fract(), 0., "{width}x{height} {wanted} at {scale}");
                    assert_eq!(pixels as usize % 2, 0, "{width}x{height} {wanted} at {scale}");
                    assert_eq!((pixels / scale).round() as usize, points);
                }
                // Never fewer pixels than asked for, unless the display has no more.
                let long_edge = width.max(height) as f64 * scale;
                assert!(long_edge >= (wanted as f64).min(width.max(height) as f64 * 2.),
                    "{width}x{height} {wanted} at {scale}");
            }
        }
        // 1512 by 982 has no usable step below 2x for a 1920-wide controller.
        assert_eq!(capture_scale(2., 1512, 982, 1920), 2.);
        // An odd point height cannot be captured at 1x with an even size.
        assert_eq!(capture_scale(2., 1728, 1117, 640), 2.);
    }
}
