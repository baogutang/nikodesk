use super::{MediaIo, VoiceBackend, VoiceDriver, VoiceError, SAMPLE_RATE};
use std::{ptr, sync::{atomic::{AtomicU64, Ordering}, Mutex}};
use ::windows::{core::{Interface, PCWSTR}, Devices::Enumeration::{DeviceAccessInformation,
    DeviceAccessStatus, DeviceClass}, Win32::{Media::Audio::{self, IAudioCaptureClient, IAudioClient,
    IAudioRenderClient, IMMDevice, IMMDeviceEnumerator, IMMEndpoint, WAVEFORMATEX}, System::{
        Com::{CoCreateInstance, CoTaskMemFree, CLSCTX_ALL},
        WinRT::{RoInitialize, RoUninitialize, RO_INIT_MULTITHREADED}}}};

static NEXT_SNAPSHOT: AtomicU64 = AtomicU64::new(1);
static LEASES: Mutex<Vec<String>> = Mutex::new(Vec::new());
const MAX_NATIVE_FRAMES: usize = 48_000;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Direction { Capture, Playback }
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct DeviceToken { snapshot: u64, index: usize }
pub struct DeviceInfo { pub token: DeviceToken, pub endpoint_id: String, pub direction: Direction }
pub struct DeviceSnapshot { generation: u64, infos: Vec<DeviceInfo> }
impl DeviceSnapshot {
    /// Enumerates endpoint IDs without Activate, opening streams, choosing a
    /// default endpoint, or requesting microphone privacy access.
    pub fn enumerate() -> Result<Self, VoiceError> {
        ordinary_user()?;
        let _com = ComApartment::new()?;
        let generation = NEXT_SNAPSHOT.fetch_update(Ordering::Relaxed, Ordering::Relaxed,
            |value| value.checked_add(1)).map_err(|_| VoiceError::Busy)?;
        let enumerator = enumerator()?;
        let mut infos = Vec::new();
        for (direction, flow) in [(Direction::Capture, Audio::eCapture), (Direction::Playback, Audio::eRender)] {
            let collection = unsafe { enumerator.EnumAudioEndpoints(flow, Audio::DEVICE_STATE_ACTIVE) }.map_err(device_error)?;
            let count = unsafe { collection.GetCount() }.map_err(device_error)?;
            if count > 128 { return Err(VoiceError::Unsupported); }
            for index in 0..count {
                let device = unsafe { collection.Item(index) }.map_err(device_error)?;
                let endpoint_id = device_id(&device)?;
                infos.push(DeviceInfo { token: DeviceToken { snapshot: generation, index: infos.len() }, endpoint_id, direction });
            }
        }
        Ok(Self { generation, infos })
    }
    pub fn devices(&self) -> &[DeviceInfo] { &self.infos }
    pub fn select(&self, capture: DeviceToken, playback: DeviceToken,
        capture_channels: u16, playback_channels: u16) -> Result<WindowsBackend, VoiceError> {
        if capture.snapshot != self.generation || playback.snapshot != self.generation { return Err(VoiceError::StaleBinding); }
        let capture = self.infos.get(capture.index).ok_or(VoiceError::StaleBinding)?;
        let playback = self.infos.get(playback.index).ok_or(VoiceError::StaleBinding)?;
        if capture.direction != Direction::Capture || playback.direction != Direction::Playback
            || !(1..=2).contains(&capture_channels) || !(1..=2).contains(&playback_channels) {
            return Err(VoiceError::Unsupported);
        }
        Ok(WindowsBackend { capture_id: capture.endpoint_id.clone(), playback_id: playback.endpoint_id.clone(),
            capture_channels, playback_channels })
    }
}

fn device_error(error: impl std::fmt::Display) -> VoiceError { VoiceError::Device(error.to_string()) }
fn ordinary_user() -> Result<(), VoiceError> {
    if crate::nikodesk::background::is_system_worker()
        || crate::platform::is_process_running_as_system(std::process::id()).map_err(device_error)?
        || crate::platform::is_elevated(None).map_err(device_error)?
        || !crate::platform::get_current_process_session_id().is_some_and(|id| id != 0) {
        return Err(VoiceError::PermissionDenied);
    }
    Ok(())
}
pub fn microphone_authorized() -> Result<bool, VoiceError> {
    let _com = ComApartment::new()?;
    let info = DeviceAccessInformation::CreateFromDeviceClass(DeviceClass::AudioCapture).map_err(device_error)?;
    Ok(info.CurrentStatus().map_err(device_error)? == DeviceAccessStatus::Allowed)
}
fn permission() -> Result<(), VoiceError> {
    ordinary_user()?;
    if !microphone_authorized()? { return Err(VoiceError::PermissionDenied); }
    Ok(())
}
struct ComApartment;
impl ComApartment {
    fn new() -> Result<Self, VoiceError> {
        unsafe { RoInitialize(RO_INIT_MULTITHREADED) }.map_err(device_error)?;
        Ok(Self)
    }
}
impl Drop for ComApartment { fn drop(&mut self) { unsafe { RoUninitialize(); } } }
fn enumerator() -> Result<IMMDeviceEnumerator, VoiceError> {
    unsafe { CoCreateInstance(&Audio::MMDeviceEnumerator, None, CLSCTX_ALL) }.map_err(device_error)
}
fn device_id(device: &IMMDevice) -> Result<String, VoiceError> {
    let id = unsafe { device.GetId() }.map_err(device_error)?;
    let value = unsafe { id.to_string() }.map_err(device_error);
    unsafe { CoTaskMemFree(Some(id.0.cast())); }
    value
}
fn exact_endpoint(enumerator: &IMMDeviceEnumerator, id: &str, flow: Audio::EDataFlow) -> Result<IMMDevice, VoiceError> {
    if id.is_empty() || id.len() > 4096 || id.contains('\0') { return Err(VoiceError::Unsupported); }
    let wide: Vec<u16> = id.encode_utf16().chain(Some(0)).collect();
    let device = unsafe { enumerator.GetDevice(PCWSTR(wide.as_ptr())) }.map_err(device_error)?;
    let endpoint = device.cast::<IMMEndpoint>().map_err(device_error)?;
    if device_id(&device)? != id || unsafe { endpoint.GetDataFlow() }.map_err(device_error)? != flow
        || unsafe { device.GetState() }.map_err(device_error)? != Audio::DEVICE_STATE_ACTIVE {
        return Err(VoiceError::Device("Approved endpoint is no longer available".into()));
    }
    Ok(device)
}
struct Lease { ids: [String; 2] }
impl Lease {
    fn new(ids: [String; 2]) -> Result<Self, VoiceError> {
        let mut leases = LEASES.lock().unwrap();
        if ids.iter().any(|id| leases.contains(id)) { return Err(VoiceError::Busy); }
        leases.extend(ids.iter().cloned());
        Ok(Self { ids })
    }
}
impl Drop for Lease { fn drop(&mut self) { LEASES.lock().unwrap().retain(|id| !self.ids.contains(id)); } }
pub struct WindowsBackend { capture_id: String, playback_id: String, capture_channels: u16, playback_channels: u16 }
struct WindowsDriver {
    capture: IAudioClient,
    playback: IAudioClient,
    input: IAudioCaptureClient,
    output: IAudioRenderClient,
    io: MediaIo,
    capture_channels: usize,
    playback_channels: usize,
    output_frames: u32,
    capture_buffer: Vec<f32>,
    output_buffer: Vec<f32>,
    capture_started: bool,
    playback_started: bool,
    _lease: Lease,
    _com: ComApartment,
}
fn initialize(device: &IMMDevice, channels: u16) -> Result<IAudioClient, VoiceError> {
    let client = unsafe { device.Activate::<IAudioClient>(CLSCTX_ALL, None) }.map_err(device_error)?;
    let format = WAVEFORMATEX { wFormatTag: 3, nChannels: channels, nSamplesPerSec: SAMPLE_RATE,
        nAvgBytesPerSec: SAMPLE_RATE * u32::from(channels) * 4, nBlockAlign: channels * 4, wBitsPerSample: 32, cbSize: 0 };
    unsafe { client.Initialize(Audio::AUDCLNT_SHAREMODE_SHARED,
        Audio::AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM | Audio::AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY,
        200_000, 0, &format, None) }.map_err(device_error)?;
    Ok(client)
}
impl super::sealed::Sealed for WindowsBackend {}
impl VoiceBackend for WindowsBackend {
    fn physical_device_provider(&self) -> bool { true }
    fn open(self, io: MediaIo) -> Result<Box<dyn VoiceDriver>, VoiceError> {
        permission()?;
        let com = ComApartment::new()?;
        let lease = Lease::new([self.capture_id.clone(), self.playback_id.clone()])?;
        let enumerator = enumerator()?;
        let capture = io.execute(|| initialize(&exact_endpoint(&enumerator, &self.capture_id, Audio::eCapture)?, self.capture_channels))?;
        let playback = io.execute(|| initialize(&exact_endpoint(&enumerator, &self.playback_id, Audio::eRender)?, self.playback_channels))?;
        let output_frames = unsafe { playback.GetBufferSize() }.map_err(device_error)?;
        let capture_frames = unsafe { capture.GetBufferSize() }.map_err(device_error)?;
        if output_frames == 0 || output_frames as usize > MAX_NATIVE_FRAMES
            || capture_frames == 0 || capture_frames as usize > MAX_NATIVE_FRAMES { return Err(VoiceError::Unsupported); }
        let input = unsafe { capture.GetService::<IAudioCaptureClient>() }.map_err(device_error)?;
        let output = unsafe { playback.GetService::<IAudioRenderClient>() }.map_err(device_error)?;
        let mut driver = WindowsDriver { capture, playback, input, output, io: io.clone(),
            capture_channels: self.capture_channels as usize, playback_channels: self.playback_channels as usize,
            output_frames, capture_buffer: vec![0.; capture_frames as usize * self.capture_channels as usize],
            output_buffer: vec![0.; output_frames as usize * self.playback_channels as usize],
            capture_started: false, playback_started: false, _lease: lease, _com: com };
        let started = io.execute(|| permission().and_then(|_| unsafe { driver.playback.Start() }.map_err(device_error)))
            .and_then(|_| { driver.playback_started = true; io.execute(|| permission().and_then(|_| unsafe { driver.capture.Start() }.map_err(device_error))) })
            .map(|_| { driver.capture_started = true; });
        if let Err(error) = started { io.fail(error); }
        Ok(Box::new(driver))
    }
}
impl VoiceDriver for WindowsDriver {
    fn check_permission(&self) -> Result<(), VoiceError> { permission() }
    fn stop(&mut self) -> Result<(), VoiceError> {
        let capture = if self.capture_started {
            unsafe { self.capture.Stop() }.map_err(device_error).map(|_| { self.capture_started = false; })
        } else { Ok(()) };
        let playback = if self.playback_started {
            unsafe { self.playback.Stop() }.map_err(device_error).map(|_| { self.playback_started = false; })
        } else { Ok(()) };
        let result = capture.and(playback).and_then(|_| {
            let capture = unsafe { self.capture.Reset() }.map_err(device_error);
            let playback = unsafe { self.playback.Reset() }.map_err(device_error);
            capture.and(playback)
        });
        if result.is_ok() { self.capture_buffer.fill(0.); self.output_buffer.fill(0.); }
        result
    }
    fn poll(&mut self) -> Result<(), VoiceError> {
        let io = self.io.clone();
        io.execute(|| self.poll_native())
    }
}
impl WindowsDriver {
    fn poll_native(&mut self) -> Result<(), VoiceError> {
        // A finite packet bound prevents a producer from keeping the worker
        // inside this loop while cancellation or a stop request is pending.
        for _ in 0..16 {
            if !self.io.active() { return Ok(()); }
            let next = unsafe { self.input.GetNextPacketSize() }.map_err(device_error)?;
            if next == 0 { break; }
            let mut data = ptr::null_mut(); let mut frames = 0; let mut flags = 0;
            unsafe { self.input.GetBuffer(&mut data, &mut frames, &mut flags, None, None) }.map_err(device_error)?;
            let samples = frames as usize * self.capture_channels;
            let valid = samples <= self.capture_buffer.len() && frames != 0
                && (!data.is_null() || flags & Audio::AUDCLNT_BUFFERFLAGS_SILENT.0 as u32 != 0);
            if valid {
                if flags & Audio::AUDCLNT_BUFFERFLAGS_SILENT.0 as u32 != 0 {
                    self.capture_buffer[..samples].fill(0.);
                } else {
                    // memcpy avoids assuming the WASAPI byte buffer alignment.
                    unsafe { ptr::copy_nonoverlapping(data, self.capture_buffer.as_mut_ptr().cast::<u8>(), samples * 4); }
                }
            }
            unsafe { self.input.ReleaseBuffer(frames) }.map_err(device_error)?;
            if !valid { return Err(VoiceError::InvalidPcm); }
            match self.io.capture(&self.capture_buffer[..samples], self.capture_channels) {
                Ok(()) | Err(VoiceError::Busy) | Err(VoiceError::Closed) => (),
                Err(error) => return Err(error),
            }
        }
        if !self.io.active() { return Ok(()); }
        let padding = unsafe { self.playback.GetCurrentPadding() }.map_err(device_error)?;
        let frames = self.output_frames.checked_sub(padding).ok_or(VoiceError::InvalidPcm)?;
        if frames != 0 {
            let data = unsafe { self.output.GetBuffer(frames) }.map_err(device_error)?;
            let samples = frames as usize * self.playback_channels;
            if data.is_null() {
                unsafe { self.output.ReleaseBuffer(frames, Audio::AUDCLNT_BUFFERFLAGS_SILENT.0 as u32) }.map_err(device_error)?;
                return Err(VoiceError::Device("Null WASAPI render buffer".into()));
            }
            self.io.render_pending(&mut self.output_buffer[..samples], self.playback_channels);
            unsafe { ptr::copy_nonoverlapping(self.output_buffer.as_ptr().cast::<u8>(), data, samples * 4); }
            unsafe { self.output.ReleaseBuffer(frames, 0) }.map_err(device_error)?;
            self.io.playback_prepared();
        }
        Ok(())
    }
}
