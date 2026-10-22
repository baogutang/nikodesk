//! Main display capture on ScreenCaptureKit (see nikodesk_sck.mm), on unless
//! the option `nikodesk-sck-capture` is "N". Only pictures the system
//! reports as changed come out, so the whole-frame comparison of the
//! CGDisplayStream path is not needed. For the native encoder it hands over
//! the picture's IOSurface; otherwise the encoder reads the locked picture in
//! place, without a copy. Starting it can fail (no permission, display not
//! listed, timeout); the caller then uses CGDisplayStream.
use crate::{Display, Frame, PixelBuffer, TraitCapturer};
use hbb_common::config::Config;
use std::{ffi::c_void, io, time::Duration};

extern "C" {
    fn NSCStart(
        display: u32,
        width: u32,
        height: u32,
        queue_depth: u32,
        timeout_ms: u32,
        failure: *mut u32,
    ) -> *mut c_void;
    fn NSCHealthy(stream: *mut c_void) -> bool;
    fn NSCTake(stream: *mut c_void) -> *mut c_void;
    fn NSCSurface(buffer: *mut c_void) -> *mut c_void;
    fn NSCLock(buffer: *mut c_void, base: *mut *const u8, stride: *mut usize) -> bool;
    fn NSCUnlock(buffer: *mut c_void);
    fn NSCRetainBuffer(buffer: *mut c_void);
    fn NSCReleaseBuffer(buffer: *mut c_void);
    fn NSCStop(stream: *mut c_void);
}

const OPTION: &str = "nikodesk-sck-capture";
const START_TIMEOUT_MS: u32 = 2000;
// The encoder keeps one picture while working on it, the capturer one more,
// and the stream must still have buffers to draw into.
const QUEUE_DEPTH: u32 = 6;

pub fn wanted() -> bool {
    Config::get_option(OPTION) != "N"
}

/// A locked picture read in place; unlocked and released on drop.
pub(crate) struct SckFrame {
    buffer: usize,
    base: usize,
    stride: usize,
    pub(crate) width: usize,
    pub(crate) height: usize,
}

// The buffer is immutable while locked and retained by this frame.
unsafe impl Send for SckFrame {}

impl SckFrame {
    fn lock(buffer: *mut c_void, width: usize, height: usize) -> io::Result<Self> {
        let (mut base, mut stride) = (std::ptr::null(), 0);
        if !unsafe { NSCLock(buffer, &mut base, &mut stride) } || stride < width * 4 {
            return Err(io::Error::new(io::ErrorKind::Other, "sck_lock_failed"));
        }
        unsafe { NSCRetainBuffer(buffer) };
        Ok(Self {
            buffer: buffer as usize,
            base: base as usize,
            stride,
            width,
            height,
        })
    }

    pub(crate) fn data(&self) -> &[u8] {
        unsafe { std::slice::from_raw_parts(self.base as *const u8, self.stride * self.height) }
    }

    pub(crate) fn stride(&self) -> usize {
        self.stride
    }
}

impl Drop for SckFrame {
    fn drop(&mut self) {
        unsafe {
            NSCUnlock(self.buffer as _);
            NSCReleaseBuffer(self.buffer as _);
        }
    }
}

pub struct SckCapturer {
    stream: usize,
    // The picture handed out last; kept until the next one so the encoder
    // can still read it.
    current: usize,
    texture: bool,
    width: usize,
    height: usize,
}

// The native stream serializes its own state.
unsafe impl Send for SckCapturer {}

impl SckCapturer {
    /// `texture`: hand IOSurfaces to the native encoder instead of pixels.
    pub fn new(display: &Display, texture: bool) -> io::Result<Self> {
        let id = display
            .name()
            .parse::<u32>()
            .map_err(|_| io::ErrorKind::InvalidData)?;
        let (width, height) = (display.width(), display.height());
        if width == 0 || height == 0 || width > 16384 || height > 16384 {
            return Err(io::ErrorKind::InvalidInput.into());
        }
        let mut failure = 0;
        let stream = unsafe {
            NSCStart(
                id,
                width as u32,
                height as u32,
                QUEUE_DEPTH,
                START_TIMEOUT_MS,
                &mut failure,
            )
        };
        if stream.is_null() {
            return Err(io::Error::new(
                io::ErrorKind::Other,
                format!("sck_start_failed_{failure}"),
            ));
        }
        Ok(Self {
            stream: stream as usize,
            current: 0,
            texture,
            width,
            height,
        })
    }
}

impl Drop for SckCapturer {
    fn drop(&mut self) {
        unsafe {
            if self.current != 0 {
                NSCReleaseBuffer(self.current as _);
            }
            NSCStop(self.stream as _);
        }
    }
}

impl TraitCapturer for SckCapturer {
    fn frame<'a>(&'a mut self, _timeout: Duration) -> io::Result<Frame<'a>> {
        if super::privacy_capture::reserved() {
            return Err(io::ErrorKind::WouldBlock.into());
        }
        // The encoder fell back to a session that takes only pixels: restart
        // the video service, which then captures for it.
        #[cfg(feature = "hwcodec")]
        if self.texture && super::nikodesk_vt::is_disabled() {
            return Err(io::Error::new(io::ErrorKind::Other, "texture_encoder_unavailable"));
        }
        if !unsafe { NSCHealthy(self.stream as _) } {
            return Err(io::Error::new(io::ErrorKind::Other, "sck_capture_stopped"));
        }
        let next = unsafe { NSCTake(self.stream as _) };
        if next.is_null() {
            return Err(io::ErrorKind::WouldBlock.into());
        }
        if self.current != 0 {
            unsafe { NSCReleaseBuffer(self.current as _) };
        }
        self.current = next as usize;
        if self.texture {
            let surface = unsafe { NSCSurface(next) };
            if surface.is_null() {
                return Err(io::Error::new(io::ErrorKind::Other, "sck_no_surface"));
            }
            return Ok(Frame::Texture((surface, 0)));
        }
        let frame = SckFrame::lock(next, self.width, self.height)?;
        Ok(Frame::PixelBuffer(PixelBuffer::from_sck(frame)))
    }
}

