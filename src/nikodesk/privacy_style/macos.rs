use super::{
    effects,
    helper::{self, Input},
    native::Wallpaper,
};
use hbb_common::{anyhow::anyhow, bail, ResultType};
use std::{
    sync::{mpsc, Arc},
    time::{Duration, Instant},
};
extern "C" {
    fn NPSWindowSupported() -> bool;
    fn NPSWindowPipes() -> bool;
    fn NPSWindowsCreate(
        pixels: *const u8,
        width: u32,
        height: u32,
        hint: bool,
        clock: bool,
        scene: *const std::ffi::c_char,
        motion: bool,
        brightness: u32,
        intensity: u32,
    ) -> bool;
    fn NPSWindowsStyle(
        pixels: *const u8,
        width: u32,
        height: u32,
        hint: bool,
        clock: bool,
        scene: *const std::ffi::c_char,
        motion: bool,
        brightness: u32,
        intensity: u32,
    ) -> bool;
    fn NPSWindowsShow() -> bool;
    fn NPSWindowsTick(pixels: *const u8, width: u32, height: u32) -> bool;
    fn NPSWindowsMotionAllowed() -> bool;
    fn NPSWindowsClose();
    fn NPSWindowsRequestUnlock() -> bool;
    fn NPSWindowsUnlocked() -> bool;
    fn NikoMacStyledPrivacyInput(on: bool, helper_pid: u32) -> bool;
    fn NikoMacStyledPrivacyInputRenew() -> bool;
    fn NikoMacStyledPrivacyUnlockPending(consume: bool) -> bool;
}
pub(super) fn supported() -> bool {
    unsafe { NPSWindowSupported() }
}
pub(super) fn input(on: bool, helper_pid: u32) -> bool {
    unsafe { NikoMacStyledPrivacyInput(on, helper_pid) }
}
pub(super) fn unlock_pending(consume: bool) -> bool {
    unsafe { NikoMacStyledPrivacyUnlockPending(consume) }
}
pub(super) fn input_active() -> bool {
    unsafe { NikoMacStyledPrivacyInputRenew() }
}
struct Windows;
impl Drop for Windows {
    fn drop(&mut self) {
        unsafe {
            NPSWindowsClose();
        }
    }
}
fn apply(style: &Arc<Wallpaper>, initial: bool) -> bool {
    let scene = style.scene.map(|scene| std::ffi::CString::new(scene).unwrap_or_default());
    let scene = scene.as_ref().map_or(std::ptr::null(), |scene| scene.as_ptr());
    let o = &style.options;
    unsafe {
        if initial {
            NPSWindowsCreate(
                style.pixels.as_ptr(),
                style.width,
                style.height,
                o.hint,
                o.clock,
                scene,
                o.motion,
                o.brightness,
                o.intensity,
            )
        } else {
            NPSWindowsStyle(
                style.pixels.as_ptr(),
                style.width,
                style.height,
                o.hint,
                o.clock,
                scene,
                o.motion,
                o.brightness,
                o.intensity,
            )
        }
    }
}
pub(crate) fn run() -> ResultType<()> {
    if !unsafe { NPSWindowPipes() } {
        bail!("helper_pipe_required");
    }
    let receiver = helper::incoming();
    let mut style = helper::initial(&receiver)?;
    if !apply(&style, true) {
        bail!("helper_window_failed");
    }
    let _windows = Windows;
    helper::respond(b'R')?;
    let mut lease = Instant::now();
    let started = Instant::now();
    let mut shown = false;
    loop {
        let mut acknowledge = false;
        match receiver.try_recv() {
            Ok(frame) if frame.issued().elapsed() < Duration::from_secs(2) => {
                lease = frame.issued();
                match frame {
                    Input::Show(_) => {
                        if !unsafe { NPSWindowsShow() } {
                            bail!("monitor_cover_failed");
                        }
                        shown = true;
                    }
                    Input::Style(_, next) => {
                        if !apply(&next, false) {
                            bail!("helper_update_failed");
                        }
                        style = next;
                    }
                    Input::Heartbeat(_) => {}
                    Input::Unlock(_) => {
                        let _ = unsafe { NPSWindowsRequestUnlock() };
                    }
                    Input::Ready(_, _) => bail!("invalid_frame"),
                }
                acknowledge = true;
            }
            Ok(_) | Err(mpsc::TryRecvError::Disconnected) => break,
            Err(mpsc::TryRecvError::Empty) => {}
        }
        if lease.elapsed() > helper::LEASE {
            break;
        }
        if unsafe { NPSWindowsUnlocked() } {
            break;
        }
        // A scene animates in the window server; only a picture needs a mask.
        let (mask, width, height) = if style.scene.is_some() {
            (vec![0; 4], 1, 1)
        } else {
            let mask = effects::frame(
                &style.options,
                640,
                400,
                started.elapsed().as_secs_f32(),
                shown && unsafe { NPSWindowsMotionAllowed() },
            );
            (mask, 640, 400)
        };
        if !unsafe { NPSWindowsTick(mask.as_ptr(), width, height) } {
            return Err(anyhow!("monitor_cover_changed"));
        }
        if acknowledge {
            helper::respond(b'A')?;
        }
        std::thread::sleep(Duration::from_millis(33));
    }
    Ok(())
}
