//! Native overlay ownership. Preserves the legacy black-screen implementation.
use super::{helper::Screen, validate, IMPL, MAX_IMAGE_BYTES};
use crate::privacy_mode::{PrivacyMode, PrivacyModeState};
use base::message_proto::NikoPrivacyStyle;
use hbb_common::{anyhow::anyhow, bail, ResultType};
use std::{io::Cursor, sync::Arc};

pub(crate) struct Wallpaper {
    pub options: NikoPrivacyStyle,
    pub pixels: Vec<u8>, // opaque BGRA, full source resolution
    pub width: u32,
    pub height: u32,
}

pub(crate) fn supported() -> bool {
    #[cfg(target_os = "macos")]
    {
        super::macos::supported() && scrap::privacy_capture::supported()
    }
    #[cfg(windows)]
    {
        crate::nikodesk::privacy_windows::supported()
    }
}

pub(crate) fn prepare(style: &NikoPrivacyStyle) -> ResultType<Arc<Wallpaper>> {
    validate(style)?;
    let bytes: &[u8] = match style.preset.as_str() {
        "snow" => include_bytes!("../../../res/privacy/snow-ridge.png"),
        "paper" => include_bytes!("../../../res/privacy/paper-light.png"),
        "rain" => include_bytes!("../../../res/privacy/pixel-rain.png"),
        "custom" => &style.image,
        _ => bail!("unknown_style"),
    };
    if bytes.len() > MAX_IMAGE_BYTES {
        bail!("image_size_limit");
    }
    let format = image::guess_format(bytes).map_err(|_| anyhow!("invalid_image"))?;
    // The controller imports WebP too, but sends a normalized JPEG/PNG. These
    // decoders inspect dimensions before allocating the decoded pixel buffer.
    if !matches!(format, image::ImageFormat::Png | image::ImageFormat::Jpeg) {
        bail!("unsupported_image_format");
    }
    let (width, height) = image::io::Reader::with_format(Cursor::new(bytes), format)
        .into_dimensions()
        .map_err(|_| anyhow!("invalid_image"))?;
    if width == 0
        || height == 0
        || width > 4096
        || height > 4096
        || u64::from(width) * u64::from(height) > 8_000_000
    {
        bail!("image_dimensions_limit");
    }
    let mut reader = image::io::Reader::with_format(Cursor::new(bytes), format);
    let mut limits = image::io::Limits::default();
    limits.max_image_width = Some(4096);
    limits.max_image_height = Some(4096);
    limits.max_alloc = Some(64 * 1024 * 1024);
    reader.limits(limits);
    let mut pixels = reader
        .decode()
        .map_err(|_| anyhow!("invalid_image"))?
        .to_rgba8()
        .into_raw();
    for pixel in pixels.chunks_exact_mut(4) {
        let alpha = u16::from(pixel[3]);
        let r = (u16::from(pixel[0]) * alpha / 255) as u8;
        pixel[0] = (u16::from(pixel[2]) * alpha / 255) as u8;
        pixel[1] = (u16::from(pixel[1]) * alpha / 255) as u8;
        pixel[2] = r;
        pixel[3] = 255;
    }
    let mut options = style.clone();
    options.image.clear();
    Ok(Arc::new(Wallpaper {
        options,
        pixels,
        width,
        height,
    }))
}

pub(crate) struct StyledPrivacy {
    screen: Option<Screen>,
    inactive_notified: bool,
}
impl StyledPrivacy {
    pub(crate) fn new() -> Self {
        Self {
            screen: None,
            inactive_notified: false,
        }
    }
}
impl PrivacyMode for StyledPrivacy {
    fn is_async_privacy_mode(&self) -> bool {
        true
    }
    fn init(&self) -> ResultType<()> {
        Ok(())
    }
    fn clear(&mut self) {
        let _ = self.turn_off_privacy(0, None);
    }
    fn turn_on_privacy(&mut self, conn_id: i32) -> ResultType<bool> {
        self.nikodesk_apply_style(
            conn_id,
            NikoPrivacyStyle {
                request_id: 1,
                preset: "snow".into(),
                effect: "fog".into(),
                motion: true,
                brightness: 100,
                intensity: 120,
                hint: true,
                ..Default::default()
            },
        )
    }
    fn nikodesk_apply_style(&mut self, conn_id: i32, style: NikoPrivacyStyle) -> ResultType<bool> {
        if conn_id <= 0 {
            bail!("authentication_required");
        }
        self.check_on_conn_id(conn_id)?;
        // Decode before changing any running cover, including during updates.
        let _validated = prepare(&style)?;
        if let Some(screen) = self.screen.as_mut() {
            if let Err(error) = screen.update(&style) {
                if !screen.running() && screen.stop().is_ok() {
                    self.screen = None;
                }
                return Err(error);
            }
        } else {
            self.screen = Some(Screen::start(conn_id, &style)?);
        }
        self.inactive_notified = false;
        Ok(true)
    }
    fn turn_off_privacy(&mut self, conn_id: i32, _: Option<PrivacyModeState>) -> ResultType<()> {
        self.check_off_conn_id(conn_id)?;
        if let Some(screen) = self.screen.as_mut() {
            screen.stop()?;
        }
        self.screen = None;
        Ok(())
    }
    fn pre_conn_id(&self) -> i32 {
        self.screen.as_ref().map_or(0, |screen| screen.conn_id)
    }
    fn get_impl_key(&self) -> &str {
        IMPL
    }
    fn nikodesk_heartbeat(&mut self, conn_id: i32, permitted: bool) -> bool {
        let Some(screen) = self
            .screen
            .as_mut()
            .filter(|screen| screen.conn_id == conn_id)
        else {
            return false;
        };
        if screen.renew(permitted) {
            return false;
        }
        if screen.stop().is_ok() {
            self.screen = None;
        }
        let notify = !self.inactive_notified;
        self.inactive_notified = true;
        notify
    }
}
impl Drop for StyledPrivacy {
    fn drop(&mut self) {
        self.clear();
    }
}

pub(crate) fn apply_owned(
    mode: &mut Option<Box<dyn PrivacyMode>>,
    conn_id: i32,
    style: NikoPrivacyStyle,
) -> ResultType<bool> {
    if let Some(current) = mode.as_ref() {
        current.check_on_conn_id(conn_id)?;
        if current.pre_conn_id() != 0 && current.get_impl_key() != IMPL {
            bail!("close_legacy_privacy_first");
        }
    }
    if mode
        .as_ref()
        .is_none_or(|current| current.get_impl_key() != IMPL)
    {
        // Validate before replacing even an inactive legacy implementation.
        let _validated = prepare(&style)?;
        if let Some(current) = mode.as_mut() {
            current.clear();
        }
        *mode = Some(Box::new(StyledPrivacy::new()));
    }
    mode.as_mut()
        .ok_or_else(|| anyhow!("style_unsupported"))?
        .nikodesk_apply_style(conn_id, style)
}

#[cfg(test)]
mod tests {
    use super::*;
    fn value(preset: &str, effect: &str) -> NikoPrivacyStyle {
        NikoPrivacyStyle {
            request_id: 1,
            preset: preset.into(),
            effect: effect.into(),
            brightness: 100,
            intensity: 120,
            hint: true,
            motion: true,
            ..Default::default()
        }
    }
    #[test]
    fn all_selected_assets_decode_to_opaque_bgra() {
        for (preset, effect) in [("snow", "fog"), ("paper", "light"), ("rain", "rain")] {
            let image = prepare(&value(preset, effect)).expect("bundled wallpaper");
            assert_eq!(
                image.pixels.len(),
                image.width as usize * image.height as usize * 4
            );
            assert!(image.pixels.chunks_exact(4).all(|p| p[3] == 255));
        }
    }
    #[test]
    fn malformed_custom_image_does_not_start_a_helper() {
        let mut input = value("custom", "none");
        input.image = vec![0; 1024].into();
        assert!(prepare(&input).is_err());
    }
    struct Owned {
        id: i32,
        key: &'static str,
        updates: Arc<std::sync::atomic::AtomicUsize>,
    }
    impl PrivacyMode for Owned {
        fn is_async_privacy_mode(&self) -> bool {
            false
        }
        fn init(&self) -> ResultType<()> {
            Ok(())
        }
        fn clear(&mut self) {
            panic!("must preserve running owner");
        }
        fn turn_on_privacy(&mut self, _: i32) -> ResultType<bool> {
            Ok(true)
        }
        fn turn_off_privacy(&mut self, _: i32, _: Option<PrivacyModeState>) -> ResultType<()> {
            Ok(())
        }
        fn pre_conn_id(&self) -> i32 {
            self.id
        }
        fn get_impl_key(&self) -> &str {
            self.key
        }
        fn nikodesk_apply_style(&mut self, _: i32, style: NikoPrivacyStyle) -> ResultType<bool> {
            prepare(&style)?;
            self.updates
                .fetch_add(1, std::sync::atomic::Ordering::Relaxed);
            Ok(true)
        }
    }
    #[test]
    fn another_connection_and_active_legacy_mode_are_preserved() {
        let updates = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        for (owner, key, request) in [(7, IMPL, 8), (7, "legacy", 7), (7, "legacy", 8)] {
            let mut mode: Option<Box<dyn PrivacyMode>> = Some(Box::new(Owned {
                id: owner,
                key,
                updates: updates.clone(),
            }));
            assert!(apply_owned(&mut mode, request, value("paper", "light")).is_err());
            assert_eq!(mode.as_ref().expect("owner").pre_conn_id(), owner);
            assert_eq!(mode.as_ref().expect("key").get_impl_key(), key);
        }
        assert_eq!(updates.load(std::sync::atomic::Ordering::Relaxed), 0);
    }
    #[test]
    fn owner_updates_in_place_and_bad_image_keeps_current_style() {
        let updates = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let mut mode: Option<Box<dyn PrivacyMode>> = Some(Box::new(Owned {
            id: 7,
            key: IMPL,
            updates: updates.clone(),
        }));
        assert_eq!(
            apply_owned(&mut mode, 7, value("rain", "rain")).expect("owner updates"),
            true
        );
        let mut invalid = value("custom", "none");
        invalid.image = vec![0; 32].into();
        assert!(apply_owned(&mut mode, 7, invalid).is_err());
        assert_eq!(mode.as_ref().expect("preserved").pre_conn_id(), 7);
        assert_eq!(updates.load(std::sync::atomic::Ordering::Relaxed), 1);
    }
}
