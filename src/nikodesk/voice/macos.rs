use super::{MediaIo, VoiceBackend, VoiceDriver, VoiceError, SAMPLE_RATE};
use nikodesk_cpal::{platform::{CoreAudioDevice, CoreAudioHost, CoreAudioStream},
    traits::{DeviceTrait, HostTrait, StreamTrait}, BufferSize, SampleRate, StreamConfig};
use std::{ffi::{CStr, CString}, sync::{atomic::{AtomicU64, Ordering}, Mutex}};

extern "C" {
    fn NKVoiceMicrophoneAuthorization() -> i32;
    fn NKVoiceReadDeviceUID(device: u32, output: *mut std::ffi::c_char, capacity: u32) -> i32;
    fn NKVoiceDeviceMatches(device: u32, expected_uid: *const std::ffi::c_char) -> i32;
}
#[cfg(test)]
extern "C" { fn NKVoiceUIDEquals(expected: *const std::ffi::c_char, actual: *const std::ffi::c_char) -> i32; }
static NEXT_SNAPSHOT: AtomicU64 = AtomicU64::new(1);
static LEASES: Mutex<Vec<String>> = Mutex::new(Vec::new());

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct DeviceToken { snapshot: u64, index: usize }
#[derive(Clone)]
pub struct DeviceInfo { pub token: DeviceToken, pub label: String, pub uid: String }
#[derive(Clone)]
struct FrozenDevice { device: CoreAudioDevice, uid: CString }
impl FrozenDevice {
    fn freeze(device: CoreAudioDevice) -> Result<Self, VoiceError> {
        let mut output = [0 as std::ffi::c_char; 8192];
        if unsafe { NKVoiceReadDeviceUID(device.nikodesk_audio_device_id(), output.as_mut_ptr(), output.len() as u32) } != 1 {
            return Err(VoiceError::Device("Audio device identity is unavailable".into()));
        }
        let uid = unsafe { CStr::from_ptr(output.as_ptr()) }.to_owned();
        Ok(Self { device, uid })
    }
    fn verify(&self) -> Result<(), VoiceError> {
        if unsafe { NKVoiceDeviceMatches(self.device.nikodesk_audio_device_id(), self.uid.as_ptr()) } != 1 {
            return Err(VoiceError::Device("Approved audio device changed or disappeared".into()));
        }
        Ok(())
    }
    fn uid_string(&self) -> Result<String, VoiceError> {
        self.uid.to_str().map(str::to_owned).map_err(|_| VoiceError::Device("Invalid audio device UID".into()))
    }
}
pub struct DeviceSnapshot { generation: u64, devices: Vec<FrozenDevice>, infos: Vec<DeviceInfo> }

/// Exact enumerated device objects are held for this local approval snapshot.
/// Names are display-only; neither enumerate nor select opens an AudioUnit.
impl DeviceSnapshot {
    pub fn enumerate() -> Result<Self, VoiceError> {
        if authorization_status() == -2 { return Err(VoiceError::PermissionDenied); }
        let generation = NEXT_SNAPSHOT.fetch_update(Ordering::Relaxed, Ordering::Relaxed,
            |value| value.checked_add(1)).map_err(|_| VoiceError::Busy)?;
        let host = CoreAudioHost::new().map_err(device_error)?;
        let mut devices = Vec::new();
        let mut infos = Vec::new();
        for device in host.devices().map_err(device_error)? {
            if devices.len() >= 128 { return Err(VoiceError::Unsupported); }
            let device = FrozenDevice::freeze(device)?;
            let label = device.device.name().map_err(device_error)?;
            device.verify()?;
            infos.push(DeviceInfo { token: DeviceToken { snapshot: generation, index: devices.len() }, label, uid: device.uid_string()? });
            devices.push(device);
        }
        Ok(Self { generation, devices, infos })
    }
    pub fn devices(&self) -> &[DeviceInfo] { &self.infos }
    pub fn select(&self, capture: DeviceToken, playback: DeviceToken,
        capture_channels: u16, playback_channels: u16) -> Result<MacBackend, VoiceError> {
        if capture.snapshot != self.generation || playback.snapshot != self.generation {
            return Err(VoiceError::StaleBinding);
        }
        if !(1..=2).contains(&capture_channels) || !(1..=2).contains(&playback_channels) {
            return Err(VoiceError::Unsupported);
        }
        let capture = self.devices.get(capture.index).ok_or(VoiceError::StaleBinding)?.clone();
        let playback = self.devices.get(playback.index).ok_or(VoiceError::StaleBinding)?.clone();
        capture.verify()?; playback.verify()?;
        Ok(MacBackend { capture, playback, capture_channels, playback_channels })
    }
}

/// Does not request TCC. The existing local UI is the sole requestAccess entry.
pub fn authorization_status() -> i32 { unsafe { NKVoiceMicrophoneAuthorization() } }
fn permission() -> Result<(), VoiceError> {
    if crate::nikodesk::background::is_system_worker() || authorization_status() != 1 {
        return Err(VoiceError::PermissionDenied);
    }
    Ok(())
}
fn device_error(error: impl std::fmt::Display) -> VoiceError { VoiceError::Device(error.to_string()) }

pub struct MacBackend {
    capture: FrozenDevice,
    playback: FrozenDevice,
    capture_channels: u16,
    playback_channels: u16,
}
struct Lease { devices: Vec<String> }
impl Lease {
    fn new(capture: &FrozenDevice, playback: &FrozenDevice) -> Result<Self, VoiceError> {
        let capture = capture.uid_string()?; let playback = playback.uid_string()?;
        let mut leases = LEASES.lock().unwrap();
        if leases.contains(&capture) || leases.contains(&playback) { return Err(VoiceError::Busy); }
        let mut devices = vec![capture.clone()];
        if capture != playback { devices.push(playback); }
        leases.extend(devices.iter().cloned());
        Ok(Self { devices })
    }
}
impl Drop for Lease {
    fn drop(&mut self) { LEASES.lock().unwrap().retain(|device| !self.devices.contains(device)); }
}
struct MacDriver {
    // Fields drop in declaration order: native streams before exclusive lease.
    capture: CoreAudioStream,
    playback: CoreAudioStream,
    capture_device: FrozenDevice,
    playback_device: FrozenDevice,
    _lease: Lease,
}
impl super::sealed::Sealed for MacBackend {}
impl VoiceBackend for MacBackend {
    fn physical_device_provider(&self) -> bool { true }
    fn open(self, io: MediaIo) -> Result<Box<dyn VoiceDriver>, VoiceError> {
        permission()?; self.capture.verify()?; self.playback.verify()?;
        let lease = Lease::new(&self.capture, &self.playback)?;
        let input_io = io.clone(); let input_error = io.clone();
        let channels = self.capture_channels as usize;
        let capture = io.execute(|| { self.capture.verify()?; self.capture.device.build_input_stream(&config(self.capture_channels),
            move |samples: &[f32], _| match input_io.capture(samples, channels) {
                Ok(()) | Err(VoiceError::Busy) | Err(VoiceError::Closed) => (),
                Err(error) => input_io.fail(error),
            }, move |error| input_error.fail(device_error(error)), None).map_err(device_error) })?;
        self.capture.verify()?;
        let output_io = io.clone(); let output_error = io.clone();
        let channels = self.playback_channels as usize;
        let playback = io.execute(|| { self.playback.verify()?; self.playback.device.build_output_stream(&config(self.playback_channels),
            move |samples: &mut [f32], _| output_io.render(samples, channels),
            move |error| output_error.fail(device_error(error)), None).map_err(device_error) })?;
        self.capture.verify()?; self.playback.verify()?;
        let driver = MacDriver { capture, playback, capture_device: self.capture,
            playback_device: self.playback, _lease: lease };
        // A partly started driver remains owned through native Stop failures.
        if let Err(error) = io.execute(|| {
            driver.check_permission()?; driver.playback.play().map_err(device_error)?; driver.check_permission()
        }).and_then(|_| io.execute(|| {
            driver.check_permission()?; driver.capture.play().map_err(device_error)?; driver.check_permission()
        })) {
            io.fail(error);
        }
        Ok(Box::new(driver))
    }
}
fn config(channels: u16) -> StreamConfig {
    StreamConfig { channels, sample_rate: SampleRate(SAMPLE_RATE), buffer_size: BufferSize::Default }
}
impl VoiceDriver for MacDriver {
    fn stop(&mut self) -> Result<(), VoiceError> {
        // Pinned CoreAudio CPAL calls AudioUnitStop synchronously; unlike its
        // Windows command-queue pause, successful return is a native stop.
        let capture = self.capture.pause().map_err(device_error);
        let playback = self.playback.pause().map_err(device_error);
        capture.and(playback)
    }
    fn check_permission(&self) -> Result<(), VoiceError> {
        permission()?; self.capture_device.verify()?; self.playback_device.verify()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn nikodesk_voice_mac_snapshot_never_resolves_old_or_missing_tokens() {
        let snapshot = DeviceSnapshot { generation: 7, devices: vec![], infos: vec![] };
        let old = DeviceToken { snapshot: 6, index: 0 };
        let current = DeviceToken { snapshot: 7, index: 0 };
        assert!(matches!(snapshot.select(old, current, 1, 2), Err(VoiceError::StaleBinding)));
        assert!(matches!(snapshot.select(current, current, 1, 2), Err(VoiceError::StaleBinding)));
        assert!(matches!(snapshot.select(current, current, 0, 2), Err(VoiceError::Unsupported)));
    }
    #[test]
    fn nikodesk_voice_mac_permission_native_rejects_unbundled_test_process() {
        // The native UID/bundle guard rejects this harness before querying TCC.
        assert_eq!(authorization_status(), -2);
    }
    #[test]
    fn nikodesk_voice_mac_uid_native_rejects_unknown_and_invalid_buffers() {
        let mut output = [7 as std::ffi::c_char; 16];
        assert_eq!(unsafe { NKVoiceReadDeviceUID(0, output.as_mut_ptr(), 16) }, 0);
        assert_eq!(output[0], 0);
        assert_eq!(unsafe { NKVoiceReadDeviceUID(0, std::ptr::null_mut(), 0) }, 0);
        assert_eq!(unsafe { NKVoiceDeviceMatches(0, std::ptr::null()) }, 0);
        let expected = CString::new("approved-device").unwrap();
        assert_eq!(unsafe { NKVoiceDeviceMatches(0, expected.as_ptr()) }, 0);
    }
    #[test]
    fn nikodesk_voice_mac_actual_native_uid_comparison_is_exact() {
        let approved = CString::new("approved-uid").unwrap();
        let different = CString::new("approved-uid-reused-object-id").unwrap();
        let empty = CString::new("").unwrap();
        assert_eq!(unsafe { NKVoiceUIDEquals(approved.as_ptr(), approved.as_ptr()) }, 1);
        assert_eq!(unsafe { NKVoiceUIDEquals(approved.as_ptr(), different.as_ptr()) }, 0);
        assert_eq!(unsafe { NKVoiceUIDEquals(empty.as_ptr(), empty.as_ptr()) }, 0);
        assert_eq!(unsafe { NKVoiceUIDEquals(std::ptr::null(), approved.as_ptr()) }, 0);
    }
}
