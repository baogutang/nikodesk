use std::ffi::c_void;
extern "C" {
    fn NikoMacVirtualDisplaySupported() -> bool;
    fn NikoMacVirtualDisplayCreate(slot: u32, display_id: *mut u32, serial: *mut u32, applied: *mut bool) -> *mut c_void;
    fn NikoMacVirtualDisplayOnline(display_id: u32, serial: u32) -> bool;
    fn NikoMacVirtualDisplayRelease(display: *mut c_void);
}
pub(super) fn supported() -> bool { unsafe { NikoMacVirtualDisplaySupported() } }
pub(super) struct Screen { handle: Option<usize>, id: u32, serial: u32, applied: bool }
impl Screen {
    pub(super) fn create(slot: u32) -> Result<Self, &'static str> {
        let mut id = 0;
        let mut serial = 0;
        let mut applied = false;
        let handle = unsafe { NikoMacVirtualDisplayCreate(slot, &mut id, &mut serial, &mut applied) };
        if handle.is_null() { return Err("backend_unavailable"); }
        Ok(Self { handle: Some(handle as usize), id, serial, applied })
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
