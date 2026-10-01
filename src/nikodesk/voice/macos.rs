use super::{MediaIo, VoiceBackend, VoiceDriver, VoiceError, SAMPLE_RATE};
use nikodesk_cpal::{
    platform::{CoreAudioDevice, CoreAudioHost, CoreAudioStream},
    traits::{DeviceTrait, HostTrait, StreamTrait},
};
use std::{
    ffi::{CStr, CString},
    sync::{
        atomic::{AtomicU64, Ordering},
        Mutex,
    },
};

extern "C" {
    fn NKVoiceMicrophoneAuthorization() -> i32;
    fn NKVoiceRequestMicrophoneAuthorization(
        completion: extern "C" fn(*mut std::ffi::c_void, i32),
        context: *mut std::ffi::c_void,
    ) -> i32;
    fn NKVoiceReadDeviceUID(device: u32, output: *mut std::ffi::c_char, capacity: u32) -> i32;
    fn NKVoiceReadDeviceMetadata(
        device: u32,
        capture: *mut u32,
        playback: *mut u32,
        rate: *mut f64,
    ) -> i32;
    fn NKVoiceDeviceMatches(device: u32, expected_uid: *const std::ffi::c_char) -> i32;
}
#[cfg(test)]
extern "C" {
    fn NKVoiceUIDEquals(expected: *const std::ffi::c_char, actual: *const std::ffi::c_char) -> i32;
}
static NEXT_SNAPSHOT: AtomicU64 = AtomicU64::new(1);
static LEASES: Mutex<Vec<(u64, String)>> = Mutex::new(Vec::new());

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct DeviceToken {
    snapshot: u64,
    index: usize,
}
#[derive(Clone)]
pub struct DeviceInfo {
    pub token: DeviceToken,
    pub label: String,
    pub uid: String,
    pub capture_channels: u16,
    pub playback_channels: u16,
}
#[derive(Clone)]
struct FrozenDevice {
    device: CoreAudioDevice,
    uid: CString,
    capture_channels: u32,
    playback_channels: u32,
    rate: f64,
}
impl FrozenDevice {
    fn freeze(device: CoreAudioDevice) -> Result<Self, VoiceError> {
        let mut output = [0 as std::ffi::c_char; 8192];
        if unsafe {
            NKVoiceReadDeviceUID(
                device.nikodesk_audio_device_id(),
                output.as_mut_ptr(),
                output.len() as u32,
            )
        } != 1
        {
            return Err(VoiceError::Device(
                "Audio device identity is unavailable".into(),
            ));
        }
        let uid = unsafe { CStr::from_ptr(output.as_ptr()) }.to_owned();
        let (capture_channels, playback_channels, rate) = metadata(&device)?;
        Ok(Self {
            device,
            uid,
            capture_channels,
            playback_channels,
            rate,
        })
    }
    fn verify(&self) -> Result<(), VoiceError> {
        if unsafe {
            NKVoiceDeviceMatches(self.device.nikodesk_audio_device_id(), self.uid.as_ptr())
        } != 1
        {
            return Err(VoiceError::Device(
                "Approved audio device changed or disappeared".into(),
            ));
        }
        if metadata(&self.device)? != (self.capture_channels, self.playback_channels, self.rate) {
            return Err(VoiceError::StaleBinding);
        }
        Ok(())
    }
    fn uid_string(&self) -> Result<String, VoiceError> {
        self.uid
            .to_str()
            .map(str::to_owned)
            .map_err(|_| VoiceError::Device("Invalid audio device UID".into()))
    }
}
pub struct DeviceSnapshot {
    generation: u64,
    devices: Vec<FrozenDevice>,
    infos: Vec<DeviceInfo>,
}

/// Exact enumerated device objects are held for this local approval snapshot.
/// Names are display-only; neither enumerate nor select opens an AudioUnit.
impl DeviceSnapshot {
    pub fn enumerate() -> Result<Self, VoiceError> {
        if authorization_status() == -2 {
            return Err(VoiceError::PermissionDenied);
        }
        let generation = NEXT_SNAPSHOT
            .fetch_update(Ordering::Relaxed, Ordering::Relaxed, |value| {
                value.checked_add(1)
            })
            .map_err(|_| VoiceError::Busy)?;
        let host = CoreAudioHost::new().map_err(device_error)?;
        let mut devices = Vec::new();
        let mut infos = Vec::new();
        for device in host.devices().map_err(device_error)? {
            if devices.len() >= 128 {
                return Err(VoiceError::Unsupported);
            }
            let device = FrozenDevice::freeze(device)?;
            let label = device.device.name().map_err(device_error)?;
            device.verify()?;
            infos.push(DeviceInfo {
                token: DeviceToken {
                    snapshot: generation,
                    index: devices.len(),
                },
                label,
                uid: device.uid_string()?,
                capture_channels: approved_channels(device.capture_channels, device.rate),
                playback_channels: approved_channels(device.playback_channels, device.rate),
            });
            devices.push(device);
        }
        Ok(Self {
            generation,
            devices,
            infos,
        })
    }
    pub fn devices(&self) -> &[DeviceInfo] {
        &self.infos
    }
    pub fn select(
        &self,
        capture: DeviceToken,
        playback: DeviceToken,
        capture_channels: u16,
        playback_channels: u16,
    ) -> Result<MacBackend, VoiceError> {
        if capture.snapshot != self.generation || playback.snapshot != self.generation {
            return Err(VoiceError::StaleBinding);
        }
        if !(1..=2).contains(&capture_channels) || !(1..=2).contains(&playback_channels) {
            return Err(VoiceError::Unsupported);
        }
        let capture = self
            .devices
            .get(capture.index)
            .ok_or(VoiceError::StaleBinding)?
            .clone();
        let playback = self
            .devices
            .get(playback.index)
            .ok_or(VoiceError::StaleBinding)?
            .clone();
        capture.verify()?;
        playback.verify()?;
        if approved_channels(capture.capture_channels, capture.rate) != capture_channels
            || approved_channels(playback.playback_channels, playback.rate) != playback_channels
        {
            return Err(VoiceError::Unsupported);
        }
        Ok(MacBackend {
            capture,
            playback,
            capture_channels,
            playback_channels,
            lease: super::owner::reserve_native_lease()?,
        })
    }
}

/// Does not request TCC. The existing local UI is the sole requestAccess entry.
pub fn authorization_status() -> i32 {
    unsafe { NKVoiceMicrophoneAuthorization() }
}
/// Only a protected, explicit local request_permission action may construct
/// this job. Cancel/Drop never frees a context retained by the native block.
pub(crate) struct PermissionRequest {
    result: std::sync::mpsc::Receiver<i32>,
    cancelled: std::sync::Arc<std::sync::atomic::AtomicBool>,
}
struct PermissionCompletion {
    result: std::sync::mpsc::SyncSender<i32>,
    cancelled: std::sync::Arc<std::sync::atomic::AtomicBool>,
}
extern "C" fn permission_completed(context: *mut std::ffi::c_void, status: i32) {
    if context.is_null() {
        return;
    }
    let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        // Native accepted contexts complete exactly once, including exceptions.
        let completion = unsafe { Box::from_raw(context.cast::<PermissionCompletion>()) };
        if !completion.cancelled.load(Ordering::Acquire) {
            let _ = completion.result.try_send(status);
        }
    }));
}
impl PermissionRequest {
    pub(crate) fn begin() -> Result<Self, VoiceError> {
        let (result, receiver) = std::sync::mpsc::sync_channel(1);
        let cancelled = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
        let context = Box::into_raw(Box::new(PermissionCompletion {
            result,
            cancelled: cancelled.clone(),
        }));
        if unsafe { NKVoiceRequestMicrophoneAuthorization(permission_completed, context.cast()) }
            != 1
        {
            // Rejected means native did not acquire the context.
            unsafe {
                drop(Box::from_raw(context));
            }
            return Err(VoiceError::PermissionDenied);
        }
        Ok(Self {
            result: receiver,
            cancelled,
        })
    }
    pub(crate) fn try_result(&self) -> Option<i32> {
        self.result.try_recv().ok()
    }
    pub(crate) fn cancel(&self) {
        self.cancelled.store(true, Ordering::Release);
    }
}
impl Drop for PermissionRequest {
    fn drop(&mut self) {
        self.cancel();
    }
}
fn permission() -> Result<(), VoiceError> {
    if crate::nikodesk::background::is_system_worker() || authorization_status() != 1 {
        return Err(VoiceError::PermissionDenied);
    }
    Ok(())
}
fn device_error(error: impl std::fmt::Display) -> VoiceError {
    VoiceError::Device(error.to_string())
}

fn metadata(device: &CoreAudioDevice) -> Result<(u32, u32, f64), VoiceError> {
    let mut capture = 0;
    let mut playback = 0;
    let mut rate = 0.;
    if unsafe {
        NKVoiceReadDeviceMetadata(
            device.nikodesk_audio_device_id(),
            &mut capture,
            &mut playback,
            &mut rate,
        )
    } != 1
    {
        return Err(VoiceError::Device("audio_metadata_unavailable".into()));
    }
    Ok((capture, playback, rate))
}
fn approved_channels(channels: u32, rate: f64) -> u16 {
    // The current codec is 48k. Metadata does not change hardware rate or
    // silently choose a default device/channel mapping.
    if rate == SAMPLE_RATE as f64 && (1..=2).contains(&channels) {
        channels as u16
    } else {
        0
    }
}
pub struct MacBackend {
    capture: FrozenDevice,
    playback: FrozenDevice,
    capture_channels: u16,
    playback_channels: u16,
    lease: u64,
}
impl MacBackend {
    pub(crate) fn native_lease(&self) -> u64 {
        self.lease
    }
}
struct Lease {
    id: u64,
    devices: Vec<String>,
}
impl Lease {
    fn new(id: u64, capture: &FrozenDevice, playback: &FrozenDevice) -> Result<Self, VoiceError> {
        let capture = capture.uid_string()?;
        let playback = playback.uid_string()?;
        let mut leases = LEASES.lock().unwrap_or_else(|error| error.into_inner());
        if leases
            .iter()
            .any(|(_, uid)| uid == &capture || uid == &playback)
        {
            return Err(VoiceError::Busy);
        }
        let mut devices = vec![capture.clone()];
        if capture != playback {
            devices.push(playback);
        }
        leases.extend(devices.iter().cloned().map(|uid| (id, uid)));
        Ok(Self { id, devices })
    }
}
impl Drop for Lease {
    fn drop(&mut self) {
        // An unexpected driver Drop can only park an owned AudioUnit; it never
        // frees the exact device reservation until its native cleanup ACK.
        if CoreAudioStream::nikodesk_pending(self.id) {
            return;
        }
        LEASES
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .retain(|(id, uid)| *id != self.id || !self.devices.contains(uid));
    }
}
struct MacDriver {
    capture: Option<CoreAudioStream>,
    playback: Option<CoreAudioStream>,
    selection: MacBackend,
    io: MediaIo,
    lease: Option<Lease>,
    started: bool,
}
impl super::sealed::Sealed for MacBackend {}
impl VoiceBackend for MacBackend {
    fn physical_device_provider(&self) -> bool {
        true
    }
    fn open(self, io: MediaIo) -> Result<Box<dyn VoiceDriver>, VoiceError> {
        // No OS resources acquired here. Any poll error leaves all partial
        // streams in this driver, reachable by the owner's stop retry loop.
        Ok(Box::new(MacDriver {
            capture: None,
            playback: None,
            selection: self,
            io,
            lease: None,
            started: false,
        }))
    }
}
impl VoiceDriver for MacDriver {
    fn stop(&mut self) -> Result<(), VoiceError> {
        let capture = self.capture.as_ref().map_or(Ok(()), |stream| {
            stream.nikodesk_release().map_err(device_error)
        });
        let playback = self.playback.as_ref().map_or(Ok(()), |stream| {
            stream.nikodesk_release().map_err(device_error)
        });
        capture.and(playback)?;
        CoreAudioStream::nikodesk_retry_pending(self.selection.lease).map_err(device_error)?;
        self.capture = None;
        self.playback = None;
        self.lease = None;
        self.started = false;
        Ok(())
    }
    fn check_permission(&self) -> Result<(), VoiceError> {
        permission()?;
        self.selection.capture.verify()?;
        self.selection.playback.verify()
    }
    fn poll(&mut self) -> Result<(), VoiceError> {
        if self.started {
            return Ok(());
        }
        let io = self.io.clone();
        io.execute(|| {
            self.check_permission()?;
            self.lease = Some(Lease::new(
                self.selection.lease,
                &self.selection.capture,
                &self.selection.playback,
            )?);
            // Both empty owners are installed before any native acquisition.
            self.capture = Some(CoreAudioStream::nikodesk_empty(
                self.selection.capture.device.nikodesk_audio_device_id(),
                self.selection.lease,
            ));
            self.playback = Some(CoreAudioStream::nikodesk_empty(
                self.selection.playback.device.nikodesk_audio_device_id(),
                self.selection.lease,
            ));
            let input = io.clone();
            let channels = self.selection.capture_channels;
            self.capture
                .as_ref()
                .ok_or(VoiceError::WorkerFailed)?
                .nikodesk_prepare_capture(channels, move |samples| {
                    match input.capture(samples, channels as usize) {
                        Ok(()) | Err(VoiceError::Busy) | Err(VoiceError::Closed) => (),
                        Err(error) => input.fail(error),
                    }
                })
                .map_err(device_error)?;
            if !io.active() {
                return Err(VoiceError::Closed);
            }
            self.check_permission()?;
            let output = io.clone();
            let channels = self.selection.playback_channels;
            self.playback
                .as_ref()
                .ok_or(VoiceError::WorkerFailed)?
                .nikodesk_prepare_playback(channels, move |samples| {
                    output.render(samples, channels as usize)
                })
                .map_err(device_error)?;
            if !io.active() {
                return Err(VoiceError::Closed);
            }
            self.check_permission()?;
            self.playback
                .as_ref()
                .ok_or(VoiceError::WorkerFailed)?
                .play()
                .map_err(device_error)?;
            if !io.active() {
                return Err(VoiceError::Closed);
            }
            self.check_permission()?;
            self.capture
                .as_ref()
                .ok_or(VoiceError::WorkerFailed)?
                .play()
                .map_err(device_error)?;
            if !io.active() {
                return Err(VoiceError::Closed);
            }
            self.check_permission()?;
            self.started = true;
            Ok(())
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn explicit_permission_callback_is_reclaimed_once_without_a_permission_request() {
        let (sender, receiver) = std::sync::mpsc::sync_channel(1);
        let cancelled = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
        let context = Box::into_raw(Box::new(PermissionCompletion {
            result: sender,
            cancelled: cancelled.clone(),
        }));
        permission_completed(context.cast(), 1);
        assert_eq!(receiver.try_recv().unwrap(), 1);
        assert_eq!(std::sync::Arc::strong_count(&cancelled), 1);
    }
    #[test]
    fn cancelled_permission_callback_never_delivers_late_authorized_result() {
        let (sender, receiver) = std::sync::mpsc::sync_channel(1);
        let cancelled = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(true));
        let context = Box::into_raw(Box::new(PermissionCompletion {
            result: sender,
            cancelled: cancelled.clone(),
        }));
        permission_completed(context.cast(), 1);
        assert!(receiver.try_recv().is_err());
        assert_eq!(std::sync::Arc::strong_count(&cancelled), 1);
    }
    #[test]
    fn late_native_permission_callback_can_complete_after_the_ui_receiver_disappears() {
        let (sender, receiver) = std::sync::mpsc::sync_channel(1);
        drop(receiver);
        let cancelled = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
        let context = Box::into_raw(Box::new(PermissionCompletion {
            result: sender,
            cancelled: cancelled.clone(),
        }));
        permission_completed(context.cast(), 1);
        assert_eq!(std::sync::Arc::strong_count(&cancelled), 1);
    }
    #[test]
    fn nikodesk_voice_mac_snapshot_never_resolves_old_or_missing_tokens() {
        let snapshot = DeviceSnapshot {
            generation: 7,
            devices: vec![],
            infos: vec![],
        };
        let old = DeviceToken {
            snapshot: 6,
            index: 0,
        };
        let current = DeviceToken {
            snapshot: 7,
            index: 0,
        };
        assert!(matches!(
            snapshot.select(old, current, 1, 2),
            Err(VoiceError::StaleBinding)
        ));
        assert!(matches!(
            snapshot.select(current, current, 1, 2),
            Err(VoiceError::StaleBinding)
        ));
        assert!(matches!(
            snapshot.select(current, current, 0, 2),
            Err(VoiceError::Unsupported)
        ));
    }
    #[test]
    fn nikodesk_voice_mac_permission_native_rejects_unbundled_test_process() {
        // The native UID/bundle guard rejects this harness before querying TCC.
        assert_eq!(authorization_status(), -2);
    }
    #[test]
    fn nikodesk_voice_mac_uid_native_rejects_unknown_and_invalid_buffers() {
        let mut output = [7 as std::ffi::c_char; 16];
        assert_eq!(
            unsafe { NKVoiceReadDeviceUID(0, output.as_mut_ptr(), 16) },
            0
        );
        assert_eq!(output[0], 0);
        assert_eq!(
            unsafe { NKVoiceReadDeviceUID(0, std::ptr::null_mut(), 0) },
            0
        );
        assert_eq!(unsafe { NKVoiceDeviceMatches(0, std::ptr::null()) }, 0);
        let expected = CString::new("approved-device").unwrap();
        assert_eq!(unsafe { NKVoiceDeviceMatches(0, expected.as_ptr()) }, 0);
    }
    #[test]
    fn nikodesk_voice_mac_actual_native_uid_comparison_is_exact() {
        let approved = CString::new("approved-uid").unwrap();
        let different = CString::new("approved-uid-reused-object-id").unwrap();
        let empty = CString::new("").unwrap();
        assert_eq!(
            unsafe { NKVoiceUIDEquals(approved.as_ptr(), approved.as_ptr()) },
            1
        );
        assert_eq!(
            unsafe { NKVoiceUIDEquals(approved.as_ptr(), different.as_ptr()) },
            0
        );
        assert_eq!(
            unsafe { NKVoiceUIDEquals(empty.as_ptr(), empty.as_ptr()) },
            0
        );
        assert_eq!(
            unsafe { NKVoiceUIDEquals(std::ptr::null(), approved.as_ptr()) },
            0
        );
    }
}
