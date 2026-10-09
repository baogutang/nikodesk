//! NikoDesk's legacy black choice uses the same excluded local cover and
//! password exit as wallpapers. The upstream gamma implementation is retained.
use super::native::StyledPrivacy;
use crate::privacy_mode::{PrivacyMode, PrivacyModeState};
use base::message_proto::NikoPrivacyStyle;
use hbb_common::ResultType;

pub(crate) struct BlackPrivacy {
    inner: StyledPrivacy,
}
impl BlackPrivacy {
    pub(crate) fn new() -> Self {
        Self {
            inner: StyledPrivacy::new(),
        }
    }
    fn style() -> ResultType<NikoPrivacyStyle> {
        use image::ImageEncoder;
        let mut image = Vec::new();
        image::codecs::png::PngEncoder::new(&mut image).write_image(
            &[0, 0, 0, 255],
            1,
            1,
            image::ColorType::Rgba8,
        )?;
        Ok(NikoPrivacyStyle {
            request_id: 1,
            preset: "custom".into(),
            effect: "none".into(),
            brightness: 100,
            intensity: 100,
            image: image.into(),
            ..Default::default()
        })
    }
}
impl PrivacyMode for BlackPrivacy {
    fn is_async_privacy_mode(&self) -> bool {
        true
    }
    fn init(&self) -> ResultType<()> {
        Ok(())
    }
    fn clear(&mut self) {
        self.inner.clear();
    }
    fn turn_on_privacy(&mut self, conn_id: i32) -> ResultType<bool> {
        self.inner.nikodesk_apply_style(conn_id, Self::style()?)
    }
    fn turn_off_privacy(
        &mut self,
        conn_id: i32,
        state: Option<PrivacyModeState>,
    ) -> ResultType<()> {
        self.inner.turn_off_privacy(conn_id, state)
    }
    fn pre_conn_id(&self) -> i32 {
        self.inner.pre_conn_id()
    }
    fn get_impl_key(&self) -> &str {
        crate::privacy_mode::macos::PRIVACY_MODE_IMPL
    }
    fn nikodesk_heartbeat(&mut self, conn_id: i32, permitted: bool) -> bool {
        self.inner.nikodesk_heartbeat(conn_id, permitted)
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn legacy_black_cover_is_opaque_and_uses_the_password_renderer() {
        let wallpaper = super::super::native::prepare(&BlackPrivacy::style().expect("black PNG"))
            .expect("opaque black");
        assert_eq!((wallpaper.width, wallpaper.height), (1, 1));
        assert_eq!(wallpaper.pixels, [0, 0, 0, 255]);
        assert!(!wallpaper.options.motion);
    }
}
