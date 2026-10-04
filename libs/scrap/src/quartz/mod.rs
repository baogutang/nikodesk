pub use self::capturer::Capturer;
pub use self::config::Config;
pub use self::display::Display;
pub use self::ffi::{CGError, PixelFormat};
pub use self::frame::Frame;

mod capturer;
mod config;
mod display;
pub mod ffi;
mod frame;

use std::sync::{Arc, Mutex};

lazy_static::lazy_static! {
    pub static ref ENABLE_RETINA: Arc<Mutex<bool>> = Arc::new(Mutex::new(true));
}

/// The longest edge, in pixels, worth capturing; zero means the display's own.
#[cfg(feature = "nikodesk")]
pub static CAPTURE_LONG_EDGE: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);

/// The capture scale for a Retina display of `width` by `height` points: the
/// smallest quarter step that still gives `wanted` pixels along the long edge,
/// never below the point size and never above the display's `backing` scale.
/// A step is used only if both edges come out as even whole pixels, so the
/// point size is always exactly the pixel size divided by the scale.
#[cfg(feature = "nikodesk")]
pub fn capture_scale(backing: f64, width: usize, height: usize, wanted: u32) -> f64 {
    let long_edge = width.max(height);
    let quarters = (backing * 4.).round() as usize;
    if wanted == 0 || long_edge == 0 || quarters <= 4 || quarters as f64 != backing * 4. {
        return backing;
    }
    let needed = (wanted as f64 / long_edge as f64 * 4.).ceil() as usize;
    (needed.clamp(4, quarters)..quarters)
        .find(|q| width * q % 8 == 0 && height * q % 8 == 0)
        .map_or(backing, |q| q as f64 / 4.)
}
