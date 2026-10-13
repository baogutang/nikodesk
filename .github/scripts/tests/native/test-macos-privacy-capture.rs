//! Runs the production Rust stream registry with a fake native backend. No
//! application, screen capture, cover, input tap, profile or network is started.
use std::{
    io,
    marker::PhantomData,
    sync::{
        atomic::{AtomicBool, AtomicUsize, Ordering},
        Mutex,
    },
    time::Duration,
};

extern crate self as lazy_static;
#[macro_export]
macro_rules! lazy_static {
    ($vis:vis static ref $name:ident: $ty:ty = $value:expr;) => {
        $vis static $name: std::sync::LazyLock<$ty> = std::sync::LazyLock::new(|| $value);
    };
}

#[derive(Clone)]
pub struct Display {
    id: u32,
    width: usize,
    height: usize,
}
static DISPLAYS: Mutex<Vec<Display>> = Mutex::new(Vec::new());
impl Display {
    pub fn all() -> io::Result<Vec<Self>> {
        Ok(DISPLAYS.lock().unwrap().clone())
    }
    pub fn name(&self) -> String {
        self.id.to_string()
    }
    pub fn width(&self) -> usize {
        self.width
    }
    pub fn height(&self) -> usize {
        self.height
    }
}
pub enum Frame<'a> {
    PixelBuffer(quartz::PixelBuffer<'a>),
}
pub trait TraitCapturer {
    fn frame<'a>(&'a mut self, timeout: Duration) -> io::Result<Frame<'a>>;
}
fn would_block_if_equal(saved: &mut Vec<u8>, pixels: &[u8]) -> io::Result<()> {
    if saved == pixels {
        return Err(io::ErrorKind::WouldBlock.into());
    }
    *saved = pixels.to_vec();
    Ok(())
}
mod quartz {
    use super::*;
    pub struct PixelBuffer<'a> {
        frame: privacy_capture::PrivacyFrame,
        marker: PhantomData<&'a [u8]>,
    }
    impl PixelBuffer<'_> {
        pub(super) fn from_privacy(frame: privacy_capture::PrivacyFrame) -> Self {
            Self {
                frame,
                marker: PhantomData,
            }
        }
        pub fn dimensions(&self) -> (usize, usize) {
            (self.frame.width, self.frame.height)
        }
        pub fn length(&self) -> usize {
            self.frame.data().len()
        }
        pub fn stride(&self) -> usize {
            self.frame.stride()
        }
    }
}
#[path = "../../../../libs/scrap/src/common/privacy_capture.rs"]
mod privacy_capture;

struct NativeStream {
    width: u32,
    height: u32,
    ready: bool,
}
static STARTS: Mutex<Vec<(u32, u32, u32, u32)>> = Mutex::new(Vec::new());
static RELEASES: AtomicUsize = AtomicUsize::new(0);
static FAIL_START: AtomicBool = AtomicBool::new(false);
static FAIL_READY: AtomicBool = AtomicBool::new(false);
static CHANGE_OWNER: AtomicBool = AtomicBool::new(false);
static TEST_LOCK: Mutex<()> = Mutex::new(());

#[no_mangle]
extern "C" fn NPSCaptureSupported() -> bool {
    true
}
#[no_mangle]
extern "C" fn NPSCaptureStart(
    id: u32,
    pid: u32,
    width: u32,
    height: u32,
    _timeout: u32,
    failure: *mut u32,
) -> *mut std::ffi::c_void {
    STARTS.lock().unwrap().push((id, pid, width, height));
    if FAIL_START.load(Ordering::SeqCst) {
        unsafe {
            *failure = 4;
        }
        return std::ptr::null_mut();
    }
    if CHANGE_OWNER.swap(false, Ordering::SeqCst) {
        privacy_capture::clear(pid);
        privacy_capture::reserve(pid + 1);
    }
    unsafe {
        *failure = 0;
    }
    Box::into_raw(Box::new(NativeStream {
        width,
        height,
        ready: !FAIL_READY.load(Ordering::SeqCst),
    }))
    .cast()
}
#[no_mangle]
extern "C" fn NPSCaptureReady(pointer: *mut std::ffi::c_void) -> bool {
    unsafe { (*(pointer as *mut NativeStream)).ready }
}
#[no_mangle]
extern "C" fn NPSCaptureHealthy(pointer: *mut std::ffi::c_void) -> bool {
    NPSCaptureReady(pointer)
}
#[no_mangle]
extern "C" fn NPSCapturePending(pointer: *mut std::ffi::c_void) -> bool {
    NPSCaptureReady(pointer)
}
#[no_mangle]
extern "C" fn NPSCaptureTake(
    pointer: *mut std::ffi::c_void,
    pixels: *mut u8,
    length: usize,
) -> i32 {
    let stream = unsafe { &*(pointer as *mut NativeStream) };
    assert_eq!(length, stream.width as usize * stream.height as usize * 4);
    unsafe {
        std::ptr::write_bytes(pixels, 17, length);
    }
    1
}
#[no_mangle]
extern "C" fn NPSCaptureRelease(pointer: *mut std::ffi::c_void) {
    unsafe {
        drop(Box::from_raw(pointer as *mut NativeStream));
    }
    RELEASES.fetch_add(1, Ordering::SeqCst);
}

fn display(id: u32, width: usize, height: usize) -> Display {
    Display { id, width, height }
}
struct Fixture;
impl Fixture {
    fn start() -> Self {
        privacy_capture::clear(700);
        privacy_capture::clear(701);
        FAIL_START.store(false, Ordering::SeqCst);
        FAIL_READY.store(false, Ordering::SeqCst);
        CHANGE_OWNER.store(false, Ordering::SeqCst);
        STARTS.lock().unwrap().clear();
        RELEASES.store(0, Ordering::SeqCst);
        *DISPLAYS.lock().unwrap() = vec![display(5, 3840, 2160), display(6, 16, 8)];
        privacy_capture::reserve(700);
        privacy_capture::prepare(700).unwrap();
        Self
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        privacy_capture::clear(700);
        privacy_capture::clear(701);
    }
}

#[test]
fn controller_departure_resizes_excluded_capture_without_releasing_privacy() {
    let _guard = TEST_LOCK.lock().unwrap();
    let _fixture = Fixture::start();
    let old = privacy_capture::PrivacyCapturer::new(display(5, 3840, 2160)).unwrap();
    let mut resized = privacy_capture::PrivacyCapturer::new(display(5, 3200, 1800)).unwrap();
    assert!(privacy_capture::reserved());
    assert!(privacy_capture::healthy(700));
    assert_eq!(
        STARTS.lock().unwrap().as_slice(),
        &[(5, 700, 3840, 2160), (6, 700, 16, 8), (5, 700, 3200, 1800)]
    );
    let Frame::PixelBuffer(frame) = resized.frame(Duration::ZERO).unwrap();
    assert_eq!(frame.dimensions(), (3200, 1800));
    assert_eq!(frame.length(), 3200 * 1800 * 4);
    assert_eq!(frame.stride(), 3200 * 4);
    assert_eq!(RELEASES.load(Ordering::SeqCst), 0);
    drop(old);
    assert_eq!(RELEASES.load(Ordering::SeqCst), 1);
    privacy_capture::clear(700);
    assert!(!privacy_capture::reserved());
    assert!(!privacy_capture::healthy(700));
}

#[test]
fn unchanged_size_and_other_monitor_reuse_their_ready_streams() {
    let _guard = TEST_LOCK.lock().unwrap();
    let _fixture = Fixture::start();
    let _first = privacy_capture::PrivacyCapturer::new(display(5, 3840, 2160)).unwrap();
    let _second = privacy_capture::PrivacyCapturer::new(display(6, 16, 8)).unwrap();
    assert_eq!(STARTS.lock().unwrap().len(), 2);
    let _resized = privacy_capture::PrivacyCapturer::new(display(5, 3200, 1800)).unwrap();
    let _other = privacy_capture::PrivacyCapturer::new(display(6, 16, 8)).unwrap();
    assert_eq!(STARTS.lock().unwrap().len(), 3);
    let _reused = privacy_capture::PrivacyCapturer::new(display(5, 3200, 1800)).unwrap();
    assert_eq!(STARTS.lock().unwrap().len(), 3);
    assert!(privacy_capture::healthy(700));
}

#[test]
fn missing_exclusion_fails_closed_and_never_uses_the_old_size() {
    let _guard = TEST_LOCK.lock().unwrap();
    let _fixture = Fixture::start();
    FAIL_START.store(true, Ordering::SeqCst);
    let error = privacy_capture::PrivacyCapturer::new(display(5, 3200, 1800))
        .err()
        .unwrap();
    assert_eq!(error.to_string(), "excluded_capture_helper_unavailable");
    assert!(!privacy_capture::healthy(700));
    assert!(privacy_capture::reserved());
    assert!(privacy_capture::PrivacyCapturer::new(display(5, 3840, 2160)).is_err());
}

#[test]
fn unready_replacement_is_released_and_invalidates_the_owner() {
    let _guard = TEST_LOCK.lock().unwrap();
    let _fixture = Fixture::start();
    FAIL_READY.store(true, Ordering::SeqCst);
    let error = privacy_capture::PrivacyCapturer::new(display(5, 3200, 1800))
        .err()
        .unwrap();
    assert_eq!(error.to_string(), "excluded_capture_not_ready");
    assert_eq!(RELEASES.load(Ordering::SeqCst), 1);
    assert!(!privacy_capture::healthy(700));
}

#[test]
fn changed_owner_cannot_publish_a_late_replacement_into_the_new_session() {
    let _guard = TEST_LOCK.lock().unwrap();
    let _fixture = Fixture::start();
    CHANGE_OWNER.store(true, Ordering::SeqCst);
    let error = privacy_capture::PrivacyCapturer::new(display(5, 3200, 1800))
        .err()
        .unwrap();
    assert_eq!(error.kind(), io::ErrorKind::Interrupted);
    assert!(!privacy_capture::healthy(701));
    assert!(privacy_capture::PrivacyCapturer::new(display(5, 3200, 1800)).is_err());
    assert_eq!(RELEASES.load(Ordering::SeqCst), 3);
    privacy_capture::prepare(701).unwrap();
    assert!(privacy_capture::healthy(701));
}

#[test]
fn invalid_replacement_size_is_rejected_before_native_allocation() {
    let _guard = TEST_LOCK.lock().unwrap();
    let _fixture = Fixture::start();
    assert!(privacy_capture::PrivacyCapturer::new(display(5, 0, 1800)).is_err());
    assert_eq!(STARTS.lock().unwrap().len(), 2);
    assert!(!privacy_capture::healthy(700));
}
