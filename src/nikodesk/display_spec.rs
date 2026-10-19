//! A virtual display made to the controller's screen: the controller sends its
//! pixel size, scale and refresh rate, and the controlled side creates a
//! display it can show pixel for pixel at that refresh rate.
use crate::{
    client::{Data, Interface},
    ui_session_interface::{InvokeUiSession, Session},
};
use base::message_proto::{Message, Misc, NikoVirtualDisplaySpec, ToggleVirtualDisplay};

const MIN_EDGE: u32 = 480;
const MAX_EDGE: u32 = 8192;
const MAX_PIXELS: u64 = 7680 * 4320;
/// The highest frame limit a session can set; a faster display only costs
/// compositing work.
const MAX_REFRESH_HZ: u32 = 120;
const MIN_REFRESH_HZ: u32 = 30;
const UNKNOWN_REFRESH_HZ: u32 = 60;
/// A controller at 150% or more gets a 2x HiDPI display, unless that would
/// leave too little room for a desktop (a phone).
const HIDPI_SCALE_MILLI: u32 = 1500;
const HIDPI_MIN_SHORT_EDGE: u32 = 720;

/// The display to create, in logical pixels; a HiDPI display has twice as
/// many physical pixels in each direction.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct Plan {
    pub(crate) width: u32,
    pub(crate) height: u32,
    pub(crate) hidpi: bool,
    pub(crate) refresh_hz: u32,
}

impl Plan {
    pub(crate) fn pixels(&self) -> (u32, u32) {
        let factor = if self.hidpi { 2 } else { 1 };
        (self.width * factor, self.height * factor)
    }
}

/// What the controller reports, or None when its screen is unknown.
pub fn spec(width: u32, height: u32, scale_milli: u32, refresh_milli_hz: u32) -> Option<NikoVirtualDisplaySpec> {
    let spec = NikoVirtualDisplaySpec { width, height, scale_milli, refresh_milli_hz, ..Default::default() };
    plan(&spec).map(|_| spec)
}

/// None for a screen size no display should be made for.
pub(crate) fn plan(spec: &NikoVirtualDisplaySpec) -> Option<Plan> {
    let (width, height) = (spec.width & !1, spec.height & !1);
    if !(MIN_EDGE..=MAX_EDGE).contains(&width)
        || !(MIN_EDGE..=MAX_EDGE).contains(&height)
        || width as u64 * height as u64 > MAX_PIXELS
    {
        return None;
    }
    let refresh_hz = match spec.refresh_milli_hz {
        0 => UNKNOWN_REFRESH_HZ,
        milli => ((milli + 500) / 1000).clamp(MIN_REFRESH_HZ, MAX_REFRESH_HZ),
    };
    let hidpi = spec.scale_milli >= HIDPI_SCALE_MILLI && width.min(height) / 2 >= HIDPI_MIN_SHORT_EDGE;
    Some(if hidpi {
        Plan { width: width / 2, height: height / 2, hidpi, refresh_hz }
    } else {
        Plan { width, height, hidpi, refresh_hz }
    })
}

impl<T: InvokeUiSession> Session<T> {
    /// Like `toggle_virtual_display`, with the controller's screen attached.
    pub fn nikodesk_toggle_virtual_display(&self, index: i32, on: bool, spec: Option<NikoVirtualDisplaySpec>) {
        let mut misc = Misc::new();
        misc.set_toggle_virtual_display(ToggleVirtualDisplay {
            display: index,
            on,
            nikodesk_spec: spec.filter(|_| on).into(),
            ..Default::default()
        });
        let mut message = Message::new();
        message.set_misc(misc);
        self.send(Data::Message(message));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn plan_for(width: u32, height: u32, scale_milli: u32, refresh_milli_hz: u32) -> Option<Plan> {
        plan(&NikoVirtualDisplaySpec { width, height, scale_milli, refresh_milli_hz, ..Default::default() })
    }

    #[test]
    fn retina_and_scaled_screens_get_a_hidpi_display_of_the_same_pixels() {
        let mbp = plan_for(3024, 1964, 2000, 120_000).unwrap();
        assert_eq!(mbp, Plan { width: 1512, height: 982, hidpi: true, refresh_hz: 120 });
        assert_eq!(mbp.pixels(), (3024, 1964));
        let windows_4k = plan_for(3840, 2160, 1500, 143_856).unwrap();
        assert_eq!(windows_4k, Plan { width: 1920, height: 1080, hidpi: true, refresh_hz: 120 });
    }

    #[test]
    fn standard_and_small_screens_get_a_display_at_their_own_pixels() {
        assert_eq!(plan_for(2560, 1440, 1000, 59_940).unwrap(),
            Plan { width: 2560, height: 1440, hidpi: false, refresh_hz: 60 });
        assert_eq!(plan_for(2560, 1440, 1250, 75_000).unwrap(),
            Plan { width: 2560, height: 1440, hidpi: false, refresh_hz: 75 });
        // A 1080p laptop at 150% would get a 960x540 desktop.
        assert_eq!(plan_for(1920, 1080, 1500, 60_000).unwrap().hidpi, false);
        // A phone in landscape.
        assert_eq!(plan_for(2400, 1080, 2750, 120_000).unwrap(),
            Plan { width: 2400, height: 1080, hidpi: false, refresh_hz: 120 });
    }

    #[test]
    fn odd_sizes_are_made_even_and_refresh_rates_are_bounded() {
        assert_eq!(plan_for(1367, 769, 1000, 0).unwrap(),
            Plan { width: 1366, height: 768, hidpi: false, refresh_hz: 60 });
        assert_eq!(plan_for(1920, 1080, 1000, 240_000).unwrap().refresh_hz, 120);
        assert_eq!(plan_for(1920, 1080, 1000, 24_000).unwrap().refresh_hz, 30);
        assert_eq!(plan_for(6016, 3384, 2000, 60_000).unwrap().pixels(), (6016, 3384));
    }

    #[test]
    fn impossible_screens_are_refused() {
        assert_eq!(plan_for(0, 0, 0, 0), None);
        assert_eq!(plan_for(320, 240, 1000, 60_000), None);
        assert_eq!(plan_for(8192, 8192, 1000, 60_000), None);
        assert_eq!(plan_for(16384, 2160, 1000, 60_000), None);
        assert!(spec(320, 240, 1000, 60_000).is_none());
        assert!(spec(3024, 1964, 2000, 120_000).is_some());
    }
}
