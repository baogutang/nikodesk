//! Zero-copy capture for the native VideoToolbox session (see
//! nikodesk_texture.mm): the encoder gets the display stream's IOSurface, and
//! a picture counts as new only when the window server reports it changed.
use crate::{Display, Frame, TraitCapturer};
use std::{ffi::c_void, io, time::Duration};

extern "C" {
    fn NTCStart(display: u32, width: u32, height: u32) -> *mut c_void;
    fn NTCTake(capture: *mut c_void) -> *mut c_void;
    fn NTCRelease(surface: *mut c_void);
    fn NTCRunning(capture: *mut c_void) -> bool;
    fn NTCStop(capture: *mut c_void);
}

pub struct TextureCapturer {
    capture: usize,
    // The surface handed out last; kept until the next frame so the encoder
    // can still read it.
    current: usize,
}

// The native capture serializes its own state.
unsafe impl Send for TextureCapturer {}

impl TextureCapturer {
    pub fn new(display: &Display) -> io::Result<Self> {
        let id = display
            .name()
            .parse::<u32>()
            .map_err(|_| io::ErrorKind::InvalidData)?;
        let (width, height) = (display.width(), display.height());
        if width == 0 || height == 0 || width > 16384 || height > 16384 {
            return Err(io::ErrorKind::InvalidInput.into());
        }
        let capture = unsafe { NTCStart(id, width as u32, height as u32) };
        if capture.is_null() {
            return Err(io::Error::new(io::ErrorKind::Other, "texture_capture_failed"));
        }
        Ok(Self {
            capture: capture as usize,
            current: 0,
        })
    }
}

impl Drop for TextureCapturer {
    fn drop(&mut self) {
        unsafe {
            if self.current != 0 {
                NTCRelease(self.current as _);
            }
            NTCStop(self.capture as _);
        }
    }
}

impl TraitCapturer for TextureCapturer {
    fn frame<'a>(&'a mut self, _timeout: Duration) -> io::Result<Frame<'a>> {
        if super::privacy_capture::reserved() {
            return Err(io::ErrorKind::WouldBlock.into());
        }
        // The encoder fell back to a session that takes only NV12: restart
        // the video service, which then captures on the CPU.
        if super::nikodesk_vt::is_disabled() {
            return Err(io::Error::new(io::ErrorKind::Other, "texture_encoder_unavailable"));
        }
        if !unsafe { NTCRunning(self.capture as _) } {
            return Err(io::Error::new(io::ErrorKind::Other, "texture_capture_stopped"));
        }
        let next = unsafe { NTCTake(self.capture as _) };
        if next.is_null() {
            return Err(io::ErrorKind::WouldBlock.into());
        }
        if self.current != 0 {
            unsafe { NTCRelease(self.current as _) };
        }
        self.current = next as usize;
        Ok(Frame::Texture((next, 0)))
    }
}
