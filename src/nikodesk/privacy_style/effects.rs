//! Low resolution premultiplied overlay only. The full-resolution wallpaper is
//! painted separately by the native window, preserving image detail.
use base::message_proto::NikoPrivacyStyle;

fn over(pixel: &mut [u8], rgb: [f32; 3], alpha: f32) {
    let alpha = alpha.clamp(0., 1.);
    let remain = 1. - alpha;
    for (out, channel) in pixel[..3].iter_mut().zip(rgb.iter().rev()) {
        *out = (channel * 255. * alpha + f32::from(*out) * remain).clamp(0., 255.) as u8;
    }
    pixel[3] = (255. * alpha + f32::from(pixel[3]) * remain).clamp(0., 255.) as u8;
}

pub(crate) fn frame(
    style: &NikoPrivacyStyle,
    width: usize,
    height: usize,
    time: f32,
    motion_allowed: bool,
) -> Vec<u8> {
    let mut pixels = vec![0; width * height * 4];
    let moving = style.motion && motion_allowed;
    let intensity = style.intensity as f32 / 100.;
    let centers = std::array::from_fn::<_, 6, _>(|i| {
        let seed = i as f32;
        (
            (seed * 0.217 + time * (0.035 + seed * 0.003)).rem_euclid(1.5) - 0.25,
            0.64 + 0.035 * (seed * 2. + time * 0.32).sin(),
        )
    });
    let light_center = 0.55 + 0.33 * (time * 0.62).sin();
    for y in 0..height {
        for x in 0..width {
            let pixel = &mut pixels[(y * width + x) * 4..][..4];
            over(pixel, [0., 0., 0.], 1. - style.brightness as f32 / 100.);
            if !moving {
                continue;
            }
            let qx = x as f32 / width as f32;
            let qy = y as f32 / height as f32;
            match style.effect.as_str() {
                "fog" => {
                    let mut alpha = 0.;
                    for (cx, cy) in centers {
                        let d = ((qx - cx) / 0.25).powi(2) + ((qy - cy) / 0.11).powi(2);
                        alpha += (1. - d).max(0.).powi(2) * 0.20;
                    }
                    over(pixel, [0.71, 0.76, 0.81], (alpha * intensity).min(0.48));
                }
                "light" => {
                    let distance = (qx * 0.86 + qy * 0.3 - light_center) / 0.19;
                    let light = (1. - distance * distance).max(0.).powi(2);
                    let shadow =
                        (0.5 + 0.5 * (qx * 14. + qy * 9. + time * 0.9).sin()) * (1. - light);
                    over(pixel, [0.12, 0.10, 0.07], shadow * 0.10 * intensity);
                    over(pixel, [1., 0.91, 0.71], light * 0.25 * intensity);
                }
                _ => {}
            }
        }
    }
    if moving && style.effect == "rain" {
        for index in 0..90 {
            let seed = index as f32;
            let x = ((seed * 0.618034).fract() * width as f32) as usize;
            let speed = 40. + (seed * 1.73).sin().abs() * 55.;
            let y =
                ((seed * 0.411 + time * speed / height as f32).fract() * height as f32) as usize;
            for dy in 0..(3 + index % 5) {
                let y = (y + dy) % height;
                let x = x.saturating_sub(dy / 5);
                over(
                    &mut pixels[(y * width + x) * 4..][..4],
                    [0.69, 0.79, 0.86],
                    0.42 * intensity,
                );
            }
        }
    }
    pixels
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn each_selected_effect_moves_and_respects_motion_and_brightness() {
        for effect in ["fog", "light", "rain"] {
            let mut style = NikoPrivacyStyle {
                effect: effect.into(),
                motion: true,
                brightness: 100,
                intensity: 120,
                ..Default::default()
            };
            assert_ne!(
                frame(&style, 160, 100, 0., true),
                frame(&style, 160, 100, 2., true)
            );
            assert_eq!(
                frame(&style, 160, 100, 0., false),
                frame(&style, 160, 100, 2., false)
            );
            style.motion = false;
            assert_eq!(
                frame(&style, 160, 100, 0., true),
                frame(&style, 160, 100, 2., true)
            );
            style.brightness = 40;
            assert!(frame(&style, 160, 100, 0., true)
                .chunks_exact(4)
                .all(|p| p[3] >= 152));
        }
    }
}
