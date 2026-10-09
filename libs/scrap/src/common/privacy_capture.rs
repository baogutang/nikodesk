//! Niko-only ScreenCaptureKit backend while an excluded wallpaper helper owns
//! the local cover. Ordinary capture keeps its existing Quartz path.
use crate::{Display, Frame, TraitCapturer};
use std::{
    collections::HashMap,
    io,
    sync::{
        atomic::{AtomicU32, Ordering},
        Arc, Mutex,
    },
    time::{Duration, Instant},
};

extern "C" {
    fn NPSCaptureSupported() -> bool;
    fn NPSCaptureStart(display: u32, pid: u32, width: u32, height: u32, timeout_ms: u32, failure: *mut u32) -> *mut std::ffi::c_void;
    fn NPSCaptureReady(pointer: *mut std::ffi::c_void) -> bool;
    fn NPSCaptureHealthy(pointer: *mut std::ffi::c_void) -> bool;
    fn NPSCapturePending(pointer: *mut std::ffi::c_void) -> bool;
    fn NPSCaptureTake(pointer: *mut std::ffi::c_void, pixels: *mut u8, length: usize) -> i32;
    fn NPSCaptureRelease(pointer: *mut std::ffi::c_void);
}
static TARGET_PID: AtomicU32 = AtomicU32::new(0);
static FAILED_PID: AtomicU32 = AtomicU32::new(0);
lazy_static::lazy_static! { static ref STREAMS:Mutex<HashMap<u32,Arc<Stream>>>=Mutex::new(HashMap::new()); }
struct Stream {
    pointer: usize,
    width: usize,
    height: usize,
}
// The native state serializes its sample slot; dimensions never change.
unsafe impl Send for Stream {}
unsafe impl Sync for Stream {}
impl Drop for Stream {
    fn drop(&mut self) {
        unsafe {
            NPSCaptureRelease(self.pointer as _);
        }
    }
}
pub fn supported() -> bool {
    unsafe { NPSCaptureSupported() }
}
pub fn reserved() -> bool {
    TARGET_PID.load(Ordering::Acquire) != 0
}
pub fn reserve(pid: u32) {
    FAILED_PID.store(0, Ordering::Release);
    TARGET_PID.store(pid, Ordering::Release);
}

pub fn prepare(pid: u32) -> io::Result<()> {
    if pid == 0 || TARGET_PID.load(Ordering::Acquire) != pid || !supported() {
        return Err(io::ErrorKind::PermissionDenied.into());
    }
    let deadline = Instant::now() + Duration::from_secs(4);
    let mut streams = HashMap::new();
    for display in Display::all()? {
        let id = display
            .name()
            .parse::<u32>()
            .map_err(|_| io::ErrorKind::InvalidData)?;
        let (width, height) = (display.width(), display.height());
        if width == 0
            || height == 0
            || width
                .checked_mul(height)
                .is_none_or(|size| size > 64_000_000)
            || Instant::now() > deadline
        {
            return Err(io::ErrorKind::InvalidData.into());
        }
        let mut failure = 0;
        let remaining = deadline.saturating_duration_since(Instant::now()).as_millis() as u32;
        let pointer = unsafe { NPSCaptureStart(id, pid, width as u32, height as u32, remaining, &mut failure) };
        if pointer.is_null() {
            return Err(io::Error::new(
                io::ErrorKind::Other,
                match failure {
                    2 => "excluded_capture_content_timeout",
                    3 => "excluded_capture_content_failed",
                    4 => "excluded_capture_helper_unavailable",
                    5 => "excluded_capture_output_failed",
                    6 => "excluded_capture_start_timeout",
                    _ => "excluded_capture_start_failed",
                },
            ));
        }
        streams.insert(
            id,
            Arc::new(Stream {
                pointer: pointer as usize,
                width,
                height,
            }),
        );
    }
    if streams.is_empty() {
        return Err(io::ErrorKind::NotFound.into());
    }
    while streams
        .values()
        .any(|s| !unsafe { NPSCaptureReady(s.pointer as _) })
    {
        if Instant::now() > deadline
            || streams
                .values()
                .any(|s| !unsafe { NPSCaptureHealthy(s.pointer as _) })
        {
            return Err(io::Error::new(
                io::ErrorKind::TimedOut,
                "excluded_capture_not_ready",
            ));
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    if TARGET_PID.load(Ordering::Acquire) != pid {
        return Err(io::ErrorKind::Interrupted.into());
    }
    *STREAMS.lock().map_err(|_| io::ErrorKind::Other)? = streams;
    Ok(())
}
pub fn healthy(pid: u32) -> bool {
    TARGET_PID.load(Ordering::Acquire) == pid
        && FAILED_PID.load(Ordering::Acquire) != pid
        && supported()
        && STREAMS.lock().is_ok_and(|streams| {
            !streams.is_empty()
                && streams
                    .values()
                    .all(|s| unsafe { NPSCaptureHealthy(s.pointer as _) })
        })
}
pub fn clear(pid: u32) {
    if TARGET_PID
        .compare_exchange(pid, 0, Ordering::AcqRel, Ordering::Acquire)
        .is_ok()
    {
        if let Ok(mut streams) = STREAMS.lock() {
            streams.clear();
        }
    }
}
pub struct PrivacyFrame {
    pub(super) pixels: Vec<u8>,
    pub(super) width: usize,
    pub(super) height: usize,
}
impl PrivacyFrame {
    pub(super) fn data(&self) -> &[u8] {
        &self.pixels
    }
    pub(super) fn stride(&self) -> usize {
        self.width * 4
    }
}
pub struct PrivacyCapturer {
    stream: Arc<Stream>,
    saved: Vec<u8>,
}
impl PrivacyCapturer {
    pub fn new(display: Display) -> io::Result<Self> {
        let id = display
            .name()
            .parse::<u32>()
            .map_err(|_| io::ErrorKind::InvalidData)?;
        let stream = STREAMS
            .lock()
            .map_err(|_| io::ErrorKind::Other)?
            .get(&id)
            .cloned()
            .ok_or_else(|| io::Error::new(io::ErrorKind::Other, "excluded_capture_unavailable"))?;
        if (stream.width, stream.height) != (display.width(), display.height()) {
            // Restore through the owner rather than encode stale-size frames.
            FAILED_PID.store(TARGET_PID.load(Ordering::Acquire), Ordering::Release);
            return Err(io::Error::new(
                io::ErrorKind::Other,
                "excluded_capture_size_changed",
            ));
        }
        Ok(Self {
            stream,
            saved: Vec::new(),
        })
    }
}
impl TraitCapturer for PrivacyCapturer {
    fn frame<'a>(&'a mut self, _timeout: Duration) -> io::Result<Frame<'a>> {
        if !unsafe { NPSCaptureHealthy(self.stream.pointer as _) } {
            return Err(io::ErrorKind::Other.into());
        }
        if !unsafe { NPSCapturePending(self.stream.pointer as _) } {
            return Err(io::ErrorKind::WouldBlock.into());
        }
        let mut pixels = vec![0; self.stream.width * self.stream.height * 4];
        match unsafe { NPSCaptureTake(self.stream.pointer as _, pixels.as_mut_ptr(), pixels.len()) }
        {
            1 => {}
            0 => return Err(io::ErrorKind::WouldBlock.into()),
            _ => {
                return Err(io::Error::new(
                    io::ErrorKind::Other,
                    "excluded_capture_stopped",
                ))
            }
        }
        crate::would_block_if_equal(&mut self.saved, &pixels)?;
        Ok(Frame::PixelBuffer(
            super::quartz::PixelBuffer::from_privacy(PrivacyFrame {
                pixels,
                width: self.stream.width,
                height: self.stream.height,
            }),
        ))
    }
}
