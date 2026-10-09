use std::ptr;

use block::{Block, ConcreteBlock};
use hbb_common::libc::c_void;
use std::sync::{Arc, Mutex};

use super::config::Config;
use super::display::Display;
use super::ffi::*;
use super::frame::Frame;

pub struct Capturer {
    stream: CGDisplayStreamRef,
    queue: DispatchQueue,

    width: usize,
    height: usize,
    format: PixelFormat,
    display: Display,
    stopped: Arc<Mutex<bool>>,
}

impl Capturer {
    pub fn new<F: Fn(Frame) + 'static>(
        display: Display,
        width: usize,
        height: usize,
        format: PixelFormat,
        config: Config,
        handler: F,
    ) -> Result<Capturer, CGError> {
        let stopped = Arc::new(Mutex::new(false));
        let cloned_stopped = stopped.clone();
        let handler: FrameAvailableHandler = ConcreteBlock::new(move |status, _, surface, _| {
            use self::CGDisplayStreamFrameStatus::*;
            if status == Stopped {
                let mut lock = cloned_stopped.lock().unwrap();
                *lock = true;
                return;
            }
            if status == FrameComplete {
                handler(unsafe { Frame::new(surface) });
            }
        })
        .copy();

        let queue = unsafe {
            dispatch_queue_create(
                b"quadrupleslap.scrap\0".as_ptr() as *const i8,
                ptr::null_mut(),
            )
        };

        let stream = unsafe {
            let config = config.build();
            let stream = CGDisplayStreamCreateWithDispatchQueue(
                display.id(),
                width,
                height,
                format,
                config,
                queue,
                &*handler as *const Block<_, _> as *const c_void,
            );
            CFRelease(config);
            stream
        };

        match unsafe { CGDisplayStreamStart(stream) } {
            CGError::Success => Ok(Capturer {
                stream,
                queue,
                width,
                height,
                format,
                display,
                stopped,
            }),
            x => Err(x),
        }
    }

    pub fn width(&self) -> usize {
        self.width
    }
    pub fn height(&self) -> usize {
        self.height
    }
    pub fn format(&self) -> PixelFormat {
        self.format
    }
    pub fn display(&self) -> Display {
        self.display
    }
}

impl Drop for Capturer {
    fn drop(&mut self) {
        #[cfg(feature = "nikodesk")]
        {
            // Privacy capture changes backend. A lost CG stop callback must
            // not hang that transition or release a still-running stream.
            let result = unsafe { CGDisplayStreamStop(self.stream) };
            let deadline = std::time::Instant::now() + std::time::Duration::from_secs(2);
            while !*self.stopped.lock().unwrap() && std::time::Instant::now() < deadline {
                std::thread::sleep(std::time::Duration::from_millis(10));
            }
            if *self.stopped.lock().unwrap() {
                unsafe { CFRelease(self.stream); dispatch_release(self.queue); }
            } else {
                hbb_common::throttled_log!(std::time::Duration::from_secs(10), warn,
                    "Capture stop callback delayed: {:?}", result);
                let stream = self.stream as usize;
                let queue = self.queue as usize;
                let stopped = self.stopped.clone();
                std::thread::spawn(move || {
                    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
                    while !*stopped.lock().unwrap() && std::time::Instant::now() < deadline {
                        std::thread::sleep(std::time::Duration::from_millis(30));
                    }
                    if *stopped.lock().unwrap() {
                        unsafe { CFRelease(stream as _); dispatch_release(queue as _); }
                    } else {
                        // Keep the two CF references alive if stop never
                        // confirms; releasing them could invalidate callbacks.
                        hbb_common::throttled_log!(std::time::Duration::from_secs(10), warn,
                            "Capture stop unconfirmed; retaining native references");
                    }
                });
            }
        }
        #[cfg(not(feature = "nikodesk"))]
        unsafe {
            let _ = CGDisplayStreamStop(self.stream);
            loop {
                if *self.stopped.lock().unwrap() {
                    break;
                }
                std::thread::sleep(std::time::Duration::from_millis(30));
            }
            CFRelease(self.stream);
            dispatch_release(self.queue);
        }
    }
}
