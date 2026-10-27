//! Each device's last screen for the controller's device tiles: a small PNG
//! under the server's scope beside the device directory, refreshed while a
//! session shows pictures. Only this computer keeps it, and the option
//! `OPTION` = "N" turns it off (the settings page then deletes the files).
use hbb_common::{config::LocalConfig, log, ResultType};
use scrap::{ImageFormat, ImageRgb};
use std::{
    collections::HashMap,
    io::Write,
    path::{Path, PathBuf},
    sync::{Mutex, OnceLock},
    time::{Duration, Instant},
};

pub const OPTION: &str = "nikodesk-peer-thumbnails";
/// Twice the widest tile, so it stays sharp on Retina screens.
const WIDTH: usize = 480;
/// The first pictures of a session are often still a login or a resize.
const FIRST: Duration = Duration::from_secs(3);
const EVERY: Duration = Duration::from_secs(30);

struct Schedule {
    display: Option<usize>,
    started: Instant,
    saved: Option<Instant>,
    writing: bool,
}

fn schedules() -> &'static Mutex<HashMap<PathBuf, Schedule>> {
    static SCHEDULES: OnceLock<Mutex<HashMap<PathBuf, Schedule>>> = OnceLock::new();
    SCHEDULES.get_or_init(Default::default)
}

/// Where one session's pictures go.
pub struct Target {
    path: PathBuf,
}

impl Target {
    /// `None` when the session has no valid scope or ID; nothing is saved then.
    pub fn new(namespace: &str, id: &str) -> Option<Self> {
        super::server_scope::ServerScope::from_namespace(namespace)?;
        super::validate_remote_id(id).ok()?;
        let root = super::favorites::application_root().ok()?;
        let path = root
            .join("scopes")
            .join(namespace)
            .join("thumbnails")
            .join(format!("{id}.png"));
        // A new session waits for its own first pictures to settle.
        if let Ok(mut schedules) = schedules().lock() {
            schedules.insert(
                path.clone(),
                Schedule {
                    display: None,
                    started: Instant::now(),
                    saved: None,
                    writing: false,
                },
            );
        }
        Some(Self { path })
    }

    /// Called for every decoded picture; does work only when one is due.
    pub fn offer_rgba(&self, display: usize, rgba: &ImageRgb) {
        if self.begin(display) {
            self.write(shrink(rgba));
        }
    }

    /// The Mac's VideoToolbox pictures stay NV12 on the GPU; one is converted
    /// only when a thumbnail is due. `picture` is valid only during this call.
    #[cfg(all(target_os = "macos", feature = "hwcodec"))]
    pub fn offer_picture(&self, display: usize, picture: *mut std::ffi::c_void) {
        if picture.is_null() || !self.begin(display) {
            return;
        }
        let mut rgb = ImageRgb::new(ImageFormat::ARGB, 1);
        let small = scrap::nikodesk_vtdec::picture_to_rgb(picture, &mut rgb)
            .ok()
            .and_then(|_| shrink(&rgb));
        self.write(small);
    }

    fn begin(&self, display: usize) -> bool {
        let Ok(mut schedules) = schedules().lock() else {
            return false;
        };
        let Some(schedule) = schedules.get_mut(&self.path) else {
            return false;
        };
        // One display stands for the device: the first that shows a picture.
        if *schedule.display.get_or_insert(display) != display || schedule.writing {
            return false;
        }
        let now = Instant::now();
        let due = match schedule.saved {
            None => now.duration_since(schedule.started) >= FIRST,
            Some(saved) => now.duration_since(saved) >= EVERY,
        };
        if !due {
            return false;
        }
        // Checked only when due, not on every picture.
        if LocalConfig::get_option(OPTION) == "N" {
            schedule.saved = Some(now);
            return false;
        }
        schedule.writing = true;
        true
    }

    fn write(&self, small: Option<(usize, usize, Vec<u8>)>) {
        let path = self.path.clone();
        std::thread::spawn(move || {
            let result = match small {
                Some((w, h, rgba)) => save(&path, w, h, &rgba),
                None => Err(hbb_common::anyhow::anyhow!("unsupported picture")),
            };
            if let Err(err) = result {
                hbb_common::throttled_log!(
                    Duration::from_secs(300),
                    warn,
                    "NikoDesk could not save a device thumbnail: {err}"
                );
            }
            if let Ok(mut schedules) = schedules().lock() {
                if let Some(schedule) = schedules.get_mut(&path) {
                    schedule.writing = false;
                    schedule.saved = Some(Instant::now());
                }
            }
        });
    }
}

/// Box-filters a decoded picture down to at most `WIDTH` wide, as RGBA. It
/// runs on the video thread, so each box reads at most 4 x 4 samples: a 5K
/// picture then costs about two million reads instead of fifteen.
fn shrink(rgba: &ImageRgb) -> Option<(usize, usize, Vec<u8>)> {
    let (src_w, src_h) = (rgba.w, rgba.h);
    if src_w == 0 || src_h == 0 {
        return None;
    }
    // Byte order of each pixel's red, green and blue.
    let (r, g, b) = match rgba.fmt() {
        ImageFormat::ARGB => (2, 1, 0),
        ImageFormat::ABGR => (0, 1, 2),
        ImageFormat::Raw => return None,
    };
    let align = rgba.align().max(1);
    let stride = (src_w * 4 + align - 1) & !(align - 1);
    if rgba.raw.len() < stride * (src_h - 1) + src_w * 4 {
        return None;
    }
    let w = src_w.min(WIDTH);
    let h = ((src_h * w + src_w / 2) / src_w).max(1);
    let mut out = Vec::with_capacity(w * h * 4);
    for y in 0..h {
        let (y0, y1) = (y * src_h / h, ((y + 1) * src_h / h).max(y * src_h / h + 1));
        for x in 0..w {
            let (x0, x1) = (x * src_w / w, ((x + 1) * src_w / w).max(x * src_w / w + 1));
            let (step_y, step_x) = ((y1 - y0).div_ceil(4), (x1 - x0).div_ceil(4));
            let (mut sum, mut count) = ([0u64; 3], 0u64);
            for row in (y0..y1).step_by(step_y) {
                let line = &rgba.raw[row * stride..];
                for col in (x0..x1).step_by(step_x) {
                    let pixel = &line[col * 4..col * 4 + 4];
                    sum[0] += pixel[r] as u64;
                    sum[1] += pixel[g] as u64;
                    sum[2] += pixel[b] as u64;
                    count += 1;
                }
            }
            out.extend_from_slice(&[
                (sum[0] / count) as u8,
                (sum[1] / count) as u8,
                (sum[2] / count) as u8,
                255,
            ]);
        }
    }
    Some((w, h, out))
}

fn save(path: &Path, w: usize, h: usize, rgba: &[u8]) -> ResultType<()> {
    let Some(directory) = path.parent() else {
        hbb_common::bail!("thumbnail path has no directory");
    };
    std::fs::create_dir_all(directory)?;
    let mut png = Vec::new();
    repng::encode(&mut png, w as u32, h as u32, rgba)?;
    let partial = path.with_extension("png.partial");
    {
        let mut options = std::fs::OpenOptions::new();
        options.write(true).create(true).truncate(true);
        #[cfg(unix)]
        std::os::unix::fs::OpenOptionsExt::mode(&mut options, 0o600);
        let mut file = options.open(&partial)?;
        file.write_all(&png)?;
        file.sync_all()?;
    }
    std::fs::rename(&partial, path)?;
    log::trace!("device thumbnail saved, {w}x{h}");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn picture(fmt: ImageFormat, w: usize, h: usize, align: usize, pixel: [u8; 4]) -> ImageRgb {
        let mut rgb = ImageRgb::new(fmt, align);
        let stride = (w * 4 + align - 1) & !(align - 1);
        rgb.w = w;
        rgb.h = h;
        rgb.raw = vec![0; stride * h];
        for y in 0..h {
            for x in 0..w {
                rgb.raw[y * stride + x * 4..y * stride + x * 4 + 4].copy_from_slice(&pixel);
            }
        }
        rgb
    }

    #[test]
    fn shrinks_to_width_keeping_aspect_and_colour_order() {
        // libyuv ARGB is stored blue, green, red, alpha.
        let rgb = picture(ImageFormat::ARGB, 1920, 1080, 64, [10, 20, 30, 255]);
        let (w, h, out) = shrink(&rgb).unwrap();
        assert_eq!((w, h), (480, 270));
        assert_eq!(&out[..4], &[30, 20, 10, 255]);
        let rgb = picture(ImageFormat::ABGR, 300, 200, 1, [10, 20, 30, 255]);
        let (w, h, out) = shrink(&rgb).unwrap();
        assert_eq!((w, h), (300, 200));
        assert_eq!(&out[..4], &[10, 20, 30, 255]);
    }

    #[test]
    fn refuses_short_or_unknown_pictures() {
        let mut rgb = picture(ImageFormat::ARGB, 100, 100, 1, [0; 4]);
        rgb.raw.truncate(100);
        assert!(shrink(&rgb).is_none());
        assert!(shrink(&ImageRgb::new(ImageFormat::Raw, 1)).is_none());
    }

    #[test]
    fn saves_atomically_and_privately() {
        let directory = std::env::temp_dir().join(format!("niko-thumb-{}", std::process::id()));
        let path = directory.join("scopes/x/thumbnails/123456.png");
        save(&path, 2, 1, &[255, 0, 0, 255, 0, 255, 0, 255]).unwrap();
        let bytes = std::fs::read(&path).unwrap();
        assert_eq!(&bytes[..8], b"\x89PNG\r\n\x1a\n");
        assert!(!path.with_extension("png.partial").exists());
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = std::fs::metadata(&path).unwrap().permissions().mode();
            assert_eq!(mode & 0o777, 0o600);
        }
        let _ = std::fs::remove_dir_all(directory);
    }
}
