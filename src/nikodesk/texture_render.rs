//! Texture rendering by default on the Mac controller (plan A3-1). Upstream
//! keeps it opt-in on macOS; here it is on unless the user turned it off or
//! this machine recorded a failure in `texture-render-health`:
//! - "pending" is written before the process first hands a frame to a
//!   texture and "ok" once that returned, so a crash inside it leaves
//!   "pending" and the next start uses the soft renderer;
//! - a window whose frames still have not reached its texture after
//!   `GIVE_UP_AFTER` records "failed-no-frames" and switches every session to
//!   the soft renderer, as unticking the setting does.
//!
//! An explicit "Y" keeps texture rendering whatever the record says, and the
//! record is only written while the default applies.
#[cfg(feature = "hwcodec")]
use crate::flutter::FlutterRgbaRendererPluginOnPixelBuffer;
use crate::flutter::sessions;
use base::config::keys::{OPTION_TEXTURE_RENDER, OPTION_TEXTURE_RENDER_HEALTH};
#[cfg(feature = "hwcodec")]
use hbb_common::dlopen::{
    symbor::{Library, Symbol},
    Error as LibError,
};
use hbb_common::{config::LocalConfig, log};
use std::{
    sync::atomic::{AtomicBool, Ordering},
    time::{Duration, Instant},
};

/// Creating a window's texture normally takes well under a second; a session
/// can open slowly, and a wrong verdict turns texture rendering off for good.
const GIVE_UP_AFTER: Duration = Duration::from_secs(8);
/// A still screen sends few frames; do not judge on fewer.
const GIVE_UP_FRAMES: u32 = 10;

/// This process wrote "pending" and has not seen its first submit return.
static OWN_PENDING: AtomicBool = AtomicBool::new(false);
/// A submit returned in this process.
static SUBMITTED: AtomicBool = AtomicBool::new(false);
static LOGGED: AtomicBool = AtomicBool::new(false);

pub fn enabled() -> bool {
    let option = LocalConfig::get_option(OPTION_TEXTURE_RENDER);
    let record = LocalConfig::get_option(OPTION_TEXTURE_RENDER_HEALTH);
    let on = decide(&option, &record, OWN_PENDING.load(Ordering::Acquire));
    if option.is_empty() && !on && !LOGGED.swap(true, Ordering::AcqRel) {
        log::warn!("texture render off by default on this machine, record: {record}");
    }
    on
}

fn decide(option: &str, record: &str, own_pending: bool) -> bool {
    match option {
        "Y" => true,
        "N" => false,
        _ => (record != "pending" || own_pending) && !record.starts_with("failed"),
    }
}

/// Whether this process may write the record: texture rendering is on by
/// default and nothing has failed.
fn guarding() -> bool {
    LocalConfig::get_option(OPTION_TEXTURE_RENDER).is_empty()
        && !LocalConfig::get_option(OPTION_TEXTURE_RENDER_HEALTH).starts_with("failed")
}

/// Right before a frame goes to the texture plugin.
pub fn submitting() {
    if SUBMITTED.load(Ordering::Acquire) || OWN_PENDING.load(Ordering::Acquire) || !guarding() {
        return;
    }
    OWN_PENDING.store(true, Ordering::Release);
    LocalConfig::set_option(OPTION_TEXTURE_RENDER_HEALTH.to_owned(), "pending".to_owned());
}

/// One window's frames, from the decoder until they reach its texture.
#[derive(Default)]
pub struct Watch {
    first: Option<Instant>,
    frames: u32,
    delivered: bool,
    gave_up: bool,
}

impl Watch {
    /// A decoded frame for this window arrived.
    pub fn frame(&mut self) {
        if self.delivered || self.gave_up {
            return;
        }
        let first = *self.first.get_or_insert_with(Instant::now);
        self.frames = self.frames.saturating_add(1);
        if self.frames >= GIVE_UP_FRAMES && first.elapsed() >= GIVE_UP_AFTER {
            self.gave_up = true;
            give_up(self.frames);
        }
    }

    /// The texture plugin took a frame for this window.
    pub fn submitted(&mut self) {
        self.delivered = true;
        if !SUBMITTED.swap(true, Ordering::AcqRel) && OWN_PENDING.swap(false, Ordering::AcqRel) {
            LocalConfig::set_option(OPTION_TEXTURE_RENDER_HEALTH.to_owned(), "ok".to_owned());
        }
    }
}

/// The plugin's entry for VideoToolbox pictures. Once found, decoders send
/// their pictures there whenever the video goes to textures.
#[cfg(feature = "hwcodec")]
pub fn pixel_buffer_func(
    plugin: &'static Result<Library, LibError>,
) -> Option<Symbol<'static, FlutterRgbaRendererPluginOnPixelBuffer>> {
    // A failure to load the plugin is logged with the RGBA entry's lookup.
    let lib = plugin.as_ref().ok()?;
    match unsafe { lib.symbol::<FlutterRgbaRendererPluginOnPixelBuffer>("FlutterRgbaRendererPluginOnPixelBuffer") } {
        Ok(func) => {
            scrap::nikodesk_vtdec::set_output_check(crate::ui_interface::use_texture_render);
            Some(func)
        }
        Err(e) => {
            log::error!("Failed to find symbol FlutterRgbaRendererPluginOnPixelBuffer, {e}");
            None
        }
    }
}

fn give_up(frames: u32) {
    if !guarding() {
        log::warn!("texture render: {frames} frames did not reach the texture");
        return;
    }
    log::warn!("texture render: {frames} frames did not reach the texture, using the soft renderer");
    LocalConfig::set_option(
        OPTION_TEXTURE_RENDER_HEALTH.to_owned(),
        "failed-no-frames".to_owned(),
    );
    // Called on a video thread with the renderer locked; the switch resets
    // that thread's decoder.
    std::thread::spawn(|| {
        let event = [("v", "N")];
        for session in sessions::get_sessions() {
            if !(session.is_default() || session.is_view_camera()) {
                continue;
            }
            session.push_event("use_texture_render", &event, &[]);
            session.use_texture_render_changed();
            session.ui_handler.update_use_texture_render();
        }
    });
}

#[cfg(test)]
mod tests {
    use super::decide;

    #[test]
    fn default_follows_the_record() {
        assert!(decide("", "", false));
        assert!(decide("", "ok", false));
        assert!(!decide("", "pending", false));
        assert!(decide("", "pending", true));
        assert!(!decide("", "failed-no-frames", false));
        assert!(!decide("", "failed-no-frames", true));
    }

    #[test]
    fn explicit_choice_wins() {
        assert!(decide("Y", "failed-no-frames", false));
        assert!(decide("Y", "pending", false));
        assert!(!decide("N", "", false));
        assert!(!decide("N", "ok", false));
    }
}
