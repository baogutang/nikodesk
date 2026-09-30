//! Niko-only AVFoundation adapter. These APIs do not establish a local grant:
//! the caller must validate its exact device/format/epoch capability first.
use std::{convert::TryFrom, ffi::{c_char, CStr, CString}, io, ptr::NonNull, slice, time::Duration};

const OK: i32 = 0;
const MAX_FRAME_BYTES: usize = 64 * 1024 * 1024;
const MAX_DIMENSION: u32 = 4096;

#[repr(C)]
struct NativePermission { _private: [u8; 0] }
#[repr(C)]
struct NativeDevices { _private: [u8; 0] }
#[repr(C)]
struct NativeSession { _private: [u8; 0] }
#[repr(C)]
struct NativeFrame { _private: [u8; 0] }
#[repr(C)]
#[derive(Default)]
struct NativeDevice { unique_id: *const c_char, name: *const c_char, format_count: usize }
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct CameraFormat {
    pub width: u32, pub height: u32, pub min_fps_milli: u32, pub max_fps_milli: u32,
}
#[repr(C)]
#[derive(Clone, Copy)]
struct NativeSelection { width: u32, height: u32, fps: u32, epoch: u64 }
#[repr(C)]
#[derive(Default)]
struct NativeFrameView {
    data: *const u8, length: usize, stride: usize, width: u32, height: u32, epoch: u64,
}
extern "C" {
    fn NKCameraAuthorizationStatus() -> i32;
    fn NKCameraRequestAccess(request_id: u64) -> *mut NativePermission;
    fn NKCameraPermissionPoll(p: *mut NativePermission, status: *mut i32) -> i32;
    fn NKCameraPermissionCancel(p: *mut NativePermission);
    fn NKCameraPermissionRelease(p: *mut NativePermission);
    fn NKCameraEnumerate(result: *mut i32) -> *mut NativeDevices;
    fn NKCameraDeviceCount(p: *const NativeDevices) -> usize;
    fn NKCameraDeviceAt(p: *const NativeDevices, index: usize, value: *mut NativeDevice) -> i32;
    fn NKCameraFormatAt(p: *const NativeDevices, device: usize, format: usize, value: *mut CameraFormat) -> i32;
    fn NKCameraDevicesRelease(p: *mut NativeDevices);
    fn NKCameraStart(id: *const c_char, selection: NativeSelection, result: *mut i32) -> *mut NativeSession;
    fn NKCameraWaitRunning(p: *mut NativeSession, timeout: u32) -> i32;
    fn NKCameraTakeLatest(p: *mut NativeSession, epoch: u64, timeout: u32, frame: *mut *mut NativeFrame) -> i32;
    fn NKCameraSessionStatus(p: *mut NativeSession, phase: *mut i32) -> i32;
    fn NKCameraStop(p: *mut NativeSession) -> i32;
    fn NKCameraSessionRelease(p: *mut NativeSession) -> i32;
    fn NKCameraFrameDescribe(p: *const NativeFrame, view: *mut NativeFrameView) -> i32;
    fn NKCameraFrameRelease(p: *mut NativeFrame);
}

fn native_error(result: i32) -> io::Error {
    let kind = match result {
        1 | 6 => io::ErrorKind::WouldBlock,
        2 => io::ErrorKind::PermissionDenied,
        3 => io::ErrorKind::InvalidInput,
        4 | 7 => io::ErrorKind::ConnectionAborted,
        8 => io::ErrorKind::AddrInUse,
        _ => io::ErrorKind::Other,
    };
    io::Error::new(kind, format!("Niko camera native result {result}"))
}
fn check(result: i32) -> io::Result<()> { if result == OK { Ok(()) } else { Err(native_error(result)) } }

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CameraAuthorization { NotDetermined, Restricted, Denied, Authorized }
impl CameraAuthorization {
    fn from_native(value: i32) -> io::Result<Self> {
        match value { 0 => Ok(Self::NotDetermined), 1 => Ok(Self::Restricted), 2 => Ok(Self::Denied),
            3 => Ok(Self::Authorized), _ => Err(native_error(2)) }
    }
}
pub fn authorization_status() -> io::Result<CameraAuthorization> {
    CameraAuthorization::from_native(unsafe { NKCameraAuthorizationStatus() })
}

pub struct PermissionRequest { native: NonNull<NativePermission>, pub request_id: u64 }
impl PermissionRequest {
    /// Explicit local UI action only. Never called by enumeration or capture.
    pub fn request_local(request_id: u64) -> io::Result<Self> {
        let native = NonNull::new(unsafe { NKCameraRequestAccess(request_id) }).ok_or_else(|| native_error(2))?;
        Ok(Self { native, request_id })
    }
    pub fn poll(&self) -> io::Result<Option<CameraAuthorization>> {
        let mut status = -1;
        let result = unsafe { NKCameraPermissionPoll(self.native.as_ptr(), &mut status) };
        if result == 1 { return Ok(None); }
        check(result)?;
        Ok(Some(CameraAuthorization::from_native(status)?))
    }
    pub fn cancel(&mut self) { unsafe { NKCameraPermissionCancel(self.native.as_ptr()); } }
}
impl Drop for PermissionRequest { fn drop(&mut self) { unsafe { NKCameraPermissionRelease(self.native.as_ptr()); } } }

#[derive(Clone, Debug)]
pub struct CameraDevice { pub unique_id: String, pub name: String, pub formats: Vec<CameraFormat> }
struct DeviceList(NonNull<NativeDevices>);
impl Drop for DeviceList { fn drop(&mut self) { unsafe { NKCameraDevicesRelease(self.0.as_ptr()); } } }
pub fn enumerate() -> io::Result<Vec<CameraDevice>> {
    let mut result = 3;
    let native = unsafe { NKCameraEnumerate(&mut result) };
    check(result)?;
    let list = DeviceList(NonNull::new(native).ok_or_else(|| native_error(5))?);
    let count = unsafe { NKCameraDeviceCount(list.0.as_ptr()) };
    if count > 64 { return Err(native_error(3)); }
    let mut devices = Vec::with_capacity(count);
    for i in 0..count {
        let mut device = NativeDevice::default();
        check(unsafe { NKCameraDeviceAt(list.0.as_ptr(), i, &mut device) })?;
        if device.unique_id.is_null() || device.name.is_null() || device.format_count > 512 { return Err(native_error(3)); }
        // Strings are owned by the bounded native roster and copied before release.
        let unique_id = unsafe { CStr::from_ptr(device.unique_id) }.to_str().map_err(|_| native_error(3))?.to_owned();
        let name = unsafe { CStr::from_ptr(device.name) }.to_str().map_err(|_| native_error(3))?.to_owned();
        let mut formats = Vec::with_capacity(device.format_count);
        for j in 0..device.format_count {
            let mut format = CameraFormat::default();
            check(unsafe { NKCameraFormatAt(list.0.as_ptr(), i, j, &mut format) })?;
            formats.push(format);
        }
        devices.push(CameraDevice { unique_id, name, formats });
    }
    Ok(devices)
}

#[derive(Clone, Debug)]
pub struct CaptureSelection {
    pub unique_id: String,
    pub format: CameraFormat,
    pub fps: u32,
    pub epoch: u64,
}
impl CaptureSelection {
    pub fn validate(&self) -> io::Result<()> {
        let f = self.format;
        let fps_milli = self.fps.checked_mul(1000).ok_or_else(|| native_error(3))?;
        if self.unique_id.is_empty() || self.unique_id.len() > 1024 || self.unique_id.contains('\0') || self.epoch == 0 ||
            f.width == 0 || f.height == 0 || f.width > MAX_DIMENSION || f.height > MAX_DIMENSION ||
            f.width % 2 != 0 || f.height % 2 != 0 || self.fps == 0 || self.fps > 60 ||
            f.min_fps_milli > fps_milli || f.max_fps_milli < fps_milli {
            return Err(native_error(3));
        }
        Ok(())
    }
}

pub(crate) struct OwnedFrame { native: NonNull<NativeFrame>, view: NativeFrameView }
impl OwnedFrame {
    unsafe fn from_native(native: NonNull<NativeFrame>, epoch: u64) -> io::Result<Self> {
        let mut frame = Self { native, view: NativeFrameView::default() };
        check(NKCameraFrameDescribe(native.as_ptr(), &mut frame.view))?;
        let v = &frame.view;
        let minimum = usize::try_from(v.width).ok().and_then(|w| w.checked_mul(4));
        let length = v.stride.checked_mul(v.height as usize);
        if v.data.is_null() || v.width == 0 || v.height == 0 || v.width > MAX_DIMENSION || v.height > MAX_DIMENSION ||
            v.width % 2 != 0 || v.height % 2 != 0 || minimum.map(|w| w > v.stride).unwrap_or(true) ||
            length != Some(v.length) || v.length > MAX_FRAME_BYTES || v.epoch != epoch { return Err(native_error(3)); }
        Ok(frame)
    }
    pub(crate) fn data(&self) -> &[u8] { unsafe { slice::from_raw_parts(self.view.data, self.view.length) } }
    pub(crate) fn width(&self) -> usize { self.view.width as usize }
    pub(crate) fn height(&self) -> usize { self.view.height as usize }
    pub(crate) fn stride(&self) -> usize { self.view.stride }
}
impl Drop for OwnedFrame { fn drop(&mut self) { unsafe { NKCameraFrameRelease(self.native.as_ptr()); } } }

pub(crate) struct CameraSession { native: NonNull<NativeSession>, epoch: u64 }
impl CameraSession {
    pub(crate) fn start(selection: &CaptureSelection) -> io::Result<Self> {
        selection.validate()?;
        let unique = CString::new(selection.unique_id.as_bytes()).map_err(|_| native_error(3))?;
        let mut result = 3;
        let native = unsafe { NKCameraStart(unique.as_ptr(), NativeSelection { width: selection.format.width,
            height: selection.format.height, fps: selection.fps, epoch: selection.epoch }, &mut result) };
        check(result)?;
        let session = Self { native: NonNull::new(native).ok_or_else(|| native_error(5))?, epoch: selection.epoch };
        // Native start-return plus first valid frame, never a UI timer, establishes readiness.
        check(unsafe { NKCameraWaitRunning(session.native.as_ptr(), 5000) })?;
        Ok(session)
    }
    pub(crate) fn frame(&mut self, timeout: Duration) -> io::Result<OwnedFrame> {
        let mut frame = std::ptr::null_mut();
        check(unsafe { NKCameraTakeLatest(self.native.as_ptr(), self.epoch, timeout.as_millis().min(30000) as u32, &mut frame) })?;
        unsafe { OwnedFrame::from_native(NonNull::new(frame).ok_or_else(|| native_error(5))?, self.epoch) }
    }
    pub(crate) fn stop(&mut self) -> io::Result<()> { check(unsafe { NKCameraStop(self.native.as_ptr()) }) }
    pub(crate) fn phase(&self) -> io::Result<i32> {
        let mut phase = -1;
        check(unsafe { NKCameraSessionStatus(self.native.as_ptr(), &mut phase) })?; Ok(phase)
    }
}
impl Drop for CameraSession {
    fn drop(&mut self) {
        let result = unsafe { NKCameraSessionRelease(self.native.as_ptr()) };
        if result != OK { eprintln!("Niko camera stop not acknowledged ({result}); native owner retained"); }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn selection() -> CaptureSelection {
        CaptureSelection { unique_id: "approved-device".into(), format: CameraFormat {
            width: 1920, height: 1080, min_fps_milli: 15000, max_fps_milli: 60000 }, fps: 30, epoch: 8 }
    }
    #[test]
    fn camera_selection_requires_identity_and_epoch() {
        let mut value = selection(); assert!(value.validate().is_ok());
        for id in [String::new(), "x\0y".into(), "x".repeat(1025)] {
            value.unique_id = id; assert!(value.validate().is_err());
        }
        value = selection(); value.epoch = 0; assert!(value.validate().is_err());
    }
    #[test]
    fn camera_selection_requires_exact_even_bounded_format() {
        for (w,h) in [(0,1080),(1920,0),(1921,1080),(1920,1081),(4098,1080),(1920,4098)] {
            let mut value = selection(); value.format.width = w; value.format.height = h;
            assert!(value.validate().is_err());
        }
    }
    #[test]
    fn camera_selection_requires_supported_bounded_fps() {
        for fps in [0,14,61,u32::MAX] { let mut value=selection();value.fps=fps;assert!(value.validate().is_err()); }
        let mut value=selection();value.format.min_fps_milli=30001;assert!(value.validate().is_err());
        value=selection();value.format.max_fps_milli=29999;assert!(value.validate().is_err());
    }
    #[test]
    fn camera_authorization_values_are_fail_closed_without_request() {
        assert_eq!(CameraAuthorization::from_native(0).unwrap(),CameraAuthorization::NotDetermined);
        assert_eq!(CameraAuthorization::from_native(3).unwrap(),CameraAuthorization::Authorized);
        assert!(CameraAuthorization::from_native(-1).is_err());assert!(CameraAuthorization::from_native(4).is_err());
    }
}

// Only the isolated harness links test provider exports. Normal cargo tests and
// production objects never expose a route to bypass bundle/TCC checks.
#[cfg(all(test, nikodesk_camera_native_tests))]
mod native_buffer_tests {
    use super::*;
    use std::{ffi::c_void, sync::{Arc, atomic::{AtomicUsize, Ordering}}};
    extern "C" {
        fn NKCameraTestCreate(selection: NativeSelection) -> *mut NativeSession;
        fn NKCameraTestStarted(session: *mut NativeSession);
        fn NKCameraTestPublish(session: *mut NativeSession, buffer: *mut c_void, epoch: u64) -> i32;
        fn CVPixelBufferCreateWithBytes(allocator: *const c_void, width: usize, height: usize, format: u32,
            data: *mut c_void, stride: usize, callback: extern "C" fn(*mut c_void,*const c_void), context: *mut c_void,
            attributes: *const c_void, output: *mut *mut c_void) -> i32;
        fn CVPixelBufferRelease(buffer: *mut c_void);
    }
    struct Allocation { bytes: [u8;2048], released: Arc<AtomicUsize> }
    extern "C" fn release(context: *mut c_void, _base: *const c_void) {
        unsafe { let owned=Box::from_raw(context.cast::<Allocation>());owned.released.fetch_add(1,Ordering::SeqCst); }
    }
    fn session() -> CameraSession {
        CameraSession { native: NonNull::new(unsafe { NKCameraTestCreate(NativeSelection {width:16,height:16,fps:30,epoch:42}) }).unwrap(),epoch:42 }
    }
    fn publish(session: &CameraSession, marker: u8, epoch: u64, count: &Arc<AtomicUsize>) -> i32 {
        unsafe {
            let allocation=Box::into_raw(Box::new(Allocation {bytes:[marker;2048],released:count.clone()}));
            let mut buffer=std::ptr::null_mut();
            assert_eq!(CVPixelBufferCreateWithBytes(std::ptr::null(),16,16,0x42475241,
                (*allocation).bytes.as_mut_ptr().cast(),128,release,allocation.cast(),std::ptr::null(),&mut buffer),0);
            let result=NKCameraTestPublish(session.native.as_ptr(),buffer,epoch);CVPixelBufferRelease(buffer);result
        }
    }
    #[test]
    fn camera_rust_owner_keeps_actual_cvbuffer_alive_after_acknowledged_stop() {
        let count=Arc::new(AtomicUsize::new(0));let mut session=session();
        unsafe { NKCameraTestStarted(session.native.as_ptr()); }
        assert_eq!(publish(&session,91,42,&count),0);
        let frame=session.frame(Duration::ZERO).unwrap();assert_eq!((frame.width(),frame.height(),frame.stride()),(16,16,128));
        session.stop().unwrap();drop(session);assert_eq!(count.load(Ordering::SeqCst),0);assert_eq!(frame.data(),&[91;2048]);
        drop(frame);assert_eq!(count.load(Ordering::SeqCst),1);
    }
    #[test]
    fn camera_rust_latest_queue_releases_replaced_and_stopped_buffers() {
        let count=Arc::new(AtomicUsize::new(0));let mut session=session();
        assert_eq!(publish(&session,1,42,&count),0);assert_eq!(publish(&session,2,42,&count),0);
        assert_eq!(count.load(Ordering::SeqCst),1);session.stop().unwrap();assert_eq!(count.load(Ordering::SeqCst),2);
        assert_eq!(session.frame(Duration::ZERO).err().unwrap().kind(),io::ErrorKind::ConnectionAborted);
    }
    #[test]
    fn camera_rust_stale_epoch_cannot_make_first_frame_ready() {
        let count=Arc::new(AtomicUsize::new(0));let session=session();
        assert_eq!(publish(&session,1,41,&count),7);assert_eq!(count.load(Ordering::SeqCst),1);
        unsafe { NKCameraTestStarted(session.native.as_ptr());assert_eq!(NKCameraWaitRunning(session.native.as_ptr(),0),6); }
    }
}
