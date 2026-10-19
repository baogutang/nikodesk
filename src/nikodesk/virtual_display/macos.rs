use crate::nikodesk::display_spec::Plan;
use std::ffi::c_void;
extern "C" {
    fn NikoMacVirtualDisplaySupported() -> bool;
    fn NikoMacVirtualDisplayCreate(slot: u32, display_id: *mut u32, serial: *mut u32, applied: *mut bool) -> *mut c_void;
    fn NikoMacVirtualDisplayOnline(display_id: u32, serial: u32) -> bool;
    fn NikoMacVirtualDisplayRelease(display: *mut c_void);
    fn NikoMacVirtualDisplayCreateMatched(slot: u32, width: u32, height: u32, hidpi: bool, refresh_hz: u32,
        display_id: *mut u32, serial: *mut u32, applied: *mut bool, matched: *mut i32) -> *mut c_void;
    fn NikoMacOtherDisplayOnline(excluded: *const u32, count: u32) -> bool;
}
pub(super) fn supported() -> bool { unsafe { NikoMacVirtualDisplaySupported() } }
/// Whether removing these screens leaves the computer a display to show.
pub(super) fn keeps_a_display(removed: &[&Screen]) -> bool {
    let ids: Vec<u32> = removed.iter().map(|screen| screen.id).collect();
    unsafe { NikoMacOtherDisplayOnline(ids.as_ptr(), ids.len() as u32) }
}
pub(super) struct Screen { handle: Option<usize>, id: u32, serial: u32, applied: bool }
impl Screen {
    pub(super) fn create(slot: u32, plan: Option<Plan>) -> Result<Self, &'static str> {
        if let Some(screen) = plan.and_then(|plan| Self::create_matched(slot, plan)) {
            return Ok(screen);
        }
        let mut id = 0;
        let mut serial = 0;
        let mut applied = false;
        let handle = unsafe { NikoMacVirtualDisplayCreate(slot, &mut id, &mut serial, &mut applied) };
        if handle.is_null() { return Err("backend_unavailable"); }
        Ok(Self { handle: Some(handle as usize), id, serial, applied })
    }
    /// None falls back to the fixed modes.
    fn create_matched(slot: u32, plan: Plan) -> Option<Self> {
        let (mut id, mut serial, mut applied, mut matched) = (0, 0, false, 0);
        let handle = unsafe {
            NikoMacVirtualDisplayCreateMatched(slot, plan.width, plan.height, plan.hidpi, plan.refresh_hz,
                &mut id, &mut serial, &mut applied, &mut matched)
        };
        if handle.is_null() {
            hbb_common::log::warn!("Virtual display {slot} for {plan:?} was not created; using the fixed modes");
            return None;
        }
        let screen = Self { handle: Some(handle as usize), id, serial, applied };
        if !applied {
            hbb_common::log::warn!("Virtual display {slot} refused {plan:?}; using the fixed modes");
            return None;
        }
        hbb_common::log::info!("Virtual display {slot}: {plan:?}, mode {}",
            match matched { 1 => "exact", 2 => "lower refresh rate", _ => "not selected" });
        Some(screen)
    }
    pub(super) fn online(&self) -> bool {
        self.applied && self.handle.is_some() && self.present()
    }
    fn present(&self) -> bool { unsafe { NikoMacVirtualDisplayOnline(self.id, self.serial) } }
    pub(super) fn remove(&mut self) -> Result<(), &'static str> {
        if let Some(handle) = self.handle.take() { unsafe { NikoMacVirtualDisplayRelease(handle as *mut c_void) }; }
        if self.present() { Err("cleanup_pending") } else { Ok(()) }
    }
}
impl Drop for Screen {
    fn drop(&mut self) { let _ = self.remove(); }
}
