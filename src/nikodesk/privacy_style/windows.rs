//! Paints inside the existing WDA_EXCLUDEFROMCAPTURE helper windows. The full
//! image stays sharp; only the transparent motion mask is downsampled.
use super::{effects, native::Wallpaper};
use hbb_common::{bail, ResultType};
use std::{
    ptr::null_mut,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex, OnceLock,
    },
};
use winapi::{
    shared::{minwindef::*, windef::*},
    um::{wingdi::*, winuser::*},
};
#[link(name = "msimg32")]
extern "system" {
    fn AlphaBlend(
        target: HDC,
        x: i32,
        y: i32,
        w: i32,
        h: i32,
        source: HDC,
        sx: i32,
        sy: i32,
        sw: i32,
        sh: i32,
        blend: BLENDFUNCTION,
    ) -> BOOL;
}

static VIEW: OnceLock<Mutex<Option<Renderer>>> = OnceLock::new();
static FAILED: AtomicBool = AtomicBool::new(false);
struct Renderer {
    wallpaper: Arc<Wallpaper>,
    dc: usize,
    bitmap: usize,
    old: usize,
    bits: usize,
}
unsafe impl Send for Renderer {}
impl Drop for Renderer {
    fn drop(&mut self) {
        unsafe {
            SelectObject(self.dc as _, self.old as _);
            DeleteObject(self.bitmap as _);
            DeleteDC(self.dc as _);
        }
    }
}
fn info(width: u32, height: u32) -> BITMAPINFO {
    BITMAPINFO {
        bmiHeader: BITMAPINFOHEADER {
            biSize: std::mem::size_of::<BITMAPINFOHEADER>() as u32,
            biWidth: width as i32,
            biHeight: -(height as i32),
            biPlanes: 1,
            biBitCount: 32,
            biCompression: BI_RGB,
            ..unsafe { std::mem::zeroed() }
        },
        bmiColors: unsafe { std::mem::zeroed() },
    }
}
pub(crate) fn set(wallpaper: Arc<Wallpaper>) -> ResultType<()> {
    let view = VIEW.get_or_init(|| Mutex::new(None));
    let mut slot = view
        .lock()
        .map_err(|_| hbb_common::anyhow::anyhow!("renderer_unavailable"))?;
    if let Some(renderer) = slot.as_mut() {
        renderer.wallpaper = wallpaper;
        return Ok(());
    }
    unsafe {
        let dc = CreateCompatibleDC(null_mut());
        if dc.is_null() {
            bail!("renderer_unavailable");
        }
        let mut bits = null_mut();
        let bitmap = CreateDIBSection(
            dc,
            &info(640, 400),
            DIB_RGB_COLORS,
            &mut bits,
            null_mut(),
            0,
        );
        if bitmap.is_null() || bits.is_null() {
            DeleteDC(dc);
            bail!("renderer_unavailable");
        }
        let old = SelectObject(dc, bitmap.cast());
        if old.is_null() || old == HGDI_ERROR {
            DeleteObject(bitmap.cast());
            DeleteDC(dc);
            bail!("renderer_unavailable");
        }
        *slot = Some(Renderer {
            wallpaper,
            dc: dc as usize,
            bitmap: bitmap as usize,
            old: old as usize,
            bits: bits as usize,
        });
    }
    FAILED.store(false, Ordering::Release);
    Ok(())
}
pub(crate) fn tick(time: f32) -> ResultType<()> {
    let mut animations: BOOL = 0;
    let allowed = unsafe {
        SystemParametersInfoW(0x1042, 0, &mut animations as *mut _ as _, 0) != 0 && animations != 0
    };
    let slot = VIEW
        .get_or_init(|| Mutex::new(None))
        .lock()
        .map_err(|_| hbb_common::anyhow::anyhow!("renderer_unavailable"))?;
    if let Some(renderer) = slot.as_ref() {
        let mask = effects::frame(&renderer.wallpaper.options, 640, 400, time, allowed);
        unsafe {
            std::ptr::copy_nonoverlapping(mask.as_ptr(), renderer.bits as *mut u8, mask.len());
        }
    }
    if FAILED.load(Ordering::Acquire) {
        bail!("renderer_paint_failed");
    }
    Ok(())
}
pub(crate) fn clear() {
    if let Some(view) = VIEW.get() {
        if let Ok(mut slot) = view.lock() {
            *slot = None;
        }
    }
}
pub(crate) unsafe fn paint(dc: HDC, rect: &RECT) -> bool {
    let Some(view) = VIEW.get() else {
        return false;
    };
    let Ok(slot) = view.lock() else {
        FAILED.store(true, Ordering::Release);
        return false;
    };
    let Some(renderer) = slot.as_ref() else {
        return false;
    };
    let wallpaper = &renderer.wallpaper;
    let width = rect.right - rect.left;
    let height = rect.bottom - rect.top;
    let scale =
        (width as f64 / wallpaper.width as f64).max(height as f64 / wallpaper.height as f64);
    let iw = (wallpaper.width as f64 * scale).ceil() as i32;
    let ih = (wallpaper.height as f64 * scale).ceil() as i32;
    SetStretchBltMode(dc, HALFTONE);
    SetBrushOrgEx(dc, 0, 0, null_mut());
    let copied = StretchDIBits(
        dc,
        (width - iw) / 2,
        (height - ih) / 2,
        iw,
        ih,
        0,
        0,
        wallpaper.width as i32,
        wallpaper.height as i32,
        wallpaper.pixels.as_ptr().cast(),
        &info(wallpaper.width, wallpaper.height),
        DIB_RGB_COLORS,
        SRCCOPY,
    );
    let blend = BLENDFUNCTION {
        BlendOp: AC_SRC_OVER,
        BlendFlags: 0,
        SourceConstantAlpha: 255,
        AlphaFormat: AC_SRC_ALPHA,
    };
    if copied == 0
        || copied == GDI_ERROR as i32
        || AlphaBlend(
            dc,
            0,
            0,
            width,
            height,
            renderer.dc as _,
            0,
            0,
            640,
            400,
            blend,
        ) == 0
    {
        FAILED.store(true, Ordering::Release);
    }
    SetBkMode(dc, TRANSPARENT as i32);
    SetTextColor(dc, 0x00dddddd);
    let font = SelectObject(dc, GetStockObject(DEFAULT_GUI_FONT as i32));
    if wallpaper.options.hint {
        let text = "Esc 恢复".encode_utf16().collect::<Vec<_>>();
        TextOutW(
            dc,
            24,
            (height - 36).max(0),
            text.as_ptr(),
            text.len() as i32,
        );
    }
    if wallpaper.options.clock {
        let mut now: winapi::um::minwinbase::SYSTEMTIME = std::mem::zeroed();
        winapi::um::sysinfoapi::GetLocalTime(&mut now);
        let text = format!("{:02}:{:02}", now.wHour, now.wMinute)
            .encode_utf16()
            .collect::<Vec<_>>();
        TextOutW(
            dc,
            (width - 64).max(24),
            24,
            text.as_ptr(),
            text.len() as i32,
        );
    }
    SelectObject(dc, font);
    true
}

pub(crate) struct Cleanup;
impl Drop for Cleanup {
    fn drop(&mut self) {
        clear();
    }
}
