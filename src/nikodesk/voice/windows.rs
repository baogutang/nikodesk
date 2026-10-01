use super::{MediaIo, VoiceBackend, VoiceDriver, VoiceError, SAMPLE_RATE};
use ::windows::{
    core::{Interface, PCWSTR},
    Devices::Enumeration::{DeviceAccessInformation, DeviceAccessStatus, DeviceClass},
    Win32::{
        Media::Audio::{
            self, IAudioCaptureClient, IAudioClient, IAudioRenderClient, IMMDevice,
            IMMDeviceEnumerator, IMMEndpoint, WAVEFORMATEX,
        },
        System::{
            Com::{CoCreateInstance, CoTaskMemFree, CLSCTX_ALL},
            WinRT::{RoInitialize, RoUninitialize, RO_INIT_MULTITHREADED},
        },
    },
};
use std::{
    ptr,
    sync::{
        atomic::{AtomicU64, Ordering},
        Mutex,
    },
};

static NEXT_SNAPSHOT: AtomicU64 = AtomicU64::new(1);
static LEASES: Mutex<Vec<String>> = Mutex::new(Vec::new());
const MAX_NATIVE_FRAMES: usize = 48_000;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Direction {
    Capture,
    Playback,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct DeviceToken {
    snapshot: u64,
    index: usize,
}
#[derive(Clone)]
pub struct DeviceInfo {
    pub token: DeviceToken,
    pub endpoint_id: String,
    pub direction: Direction,
}
pub struct DeviceSnapshot {
    generation: u64,
    infos: Vec<DeviceInfo>,
}
impl DeviceSnapshot {
    /// Enumerates endpoint IDs without Activate, opening streams, choosing a
    /// default endpoint, or requesting microphone privacy access.
    pub fn enumerate() -> Result<Self, VoiceError> {
        ordinary_user()?;
        let _com = ComApartment::new()?;
        let generation = NEXT_SNAPSHOT
            .fetch_update(Ordering::Relaxed, Ordering::Relaxed, |value| {
                value.checked_add(1)
            })
            .map_err(|_| VoiceError::Busy)?;
        let enumerator = enumerator()?;
        let mut infos = Vec::new();
        for (direction, flow) in [
            (Direction::Capture, Audio::eCapture),
            (Direction::Playback, Audio::eRender),
        ] {
            let collection =
                unsafe { enumerator.EnumAudioEndpoints(flow, Audio::DEVICE_STATE_ACTIVE) }
                    .map_err(device_error)?;
            let count = unsafe { collection.GetCount() }.map_err(device_error)?;
            if count > 128 {
                return Err(VoiceError::Unsupported);
            }
            for index in 0..count {
                let device = unsafe { collection.Item(index) }.map_err(device_error)?;
                let endpoint_id = device_id(&device)?;
                infos.push(DeviceInfo {
                    token: DeviceToken {
                        snapshot: generation,
                        index: infos.len(),
                    },
                    endpoint_id,
                    direction,
                });
            }
        }
        Ok(Self { generation, infos })
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
    ) -> Result<WindowsBackend, VoiceError> {
        if capture.snapshot != self.generation || playback.snapshot != self.generation {
            return Err(VoiceError::StaleBinding);
        }
        let capture = self
            .infos
            .get(capture.index)
            .ok_or(VoiceError::StaleBinding)?;
        let playback = self
            .infos
            .get(playback.index)
            .ok_or(VoiceError::StaleBinding)?;
        if capture.direction != Direction::Capture
            || playback.direction != Direction::Playback
            || !(1..=2).contains(&capture_channels)
            || !(1..=2).contains(&playback_channels)
        {
            return Err(VoiceError::Unsupported);
        }
        Ok(WindowsBackend {
            capture_id: capture.endpoint_id.clone(),
            playback_id: playback.endpoint_id.clone(),
            capture_channels,
            playback_channels,
            native_lease: super::owner::reserve_native_lease()?,
        })
    }
}

fn device_error(error: impl std::fmt::Display) -> VoiceError {
    VoiceError::Device(error.to_string())
}
fn ordinary_user() -> Result<(), VoiceError> {
    if crate::nikodesk::background::is_system_worker()
        || crate::platform::is_process_running_as_system(std::process::id())
            .map_err(device_error)?
        || crate::platform::is_elevated(None).map_err(device_error)?
        || !crate::platform::get_current_process_session_id().is_some_and(|id| id != 0)
    {
        return Err(VoiceError::PermissionDenied);
    }
    Ok(())
}
pub fn microphone_authorized() -> Result<bool, VoiceError> {
    Ok(authorization_status_code()? == 1)
}
pub(crate) fn authorization_status_code() -> Result<i32, VoiceError> {
    ordinary_user()?;
    let _com = ComApartment::new()?;
    let info = DeviceAccessInformation::CreateFromDeviceClass(DeviceClass::AudioCapture)
        .map_err(device_error)?;
    Ok(match info.CurrentStatus().map_err(device_error)? {
        DeviceAccessStatus::Allowed => 1,
        DeviceAccessStatus::DeniedByUser => -1,
        DeviceAccessStatus::DeniedBySystem => -3,
        _ => -2,
    })
}
fn permission() -> Result<(), VoiceError> {
    ordinary_user()?;
    if !microphone_authorized()? {
        return Err(VoiceError::PermissionDenied);
    }
    Ok(())
}
struct ComApartment;
impl ComApartment {
    fn new() -> Result<Self, VoiceError> {
        unsafe { RoInitialize(RO_INIT_MULTITHREADED) }.map_err(device_error)?;
        Ok(Self)
    }
}
impl Drop for ComApartment {
    fn drop(&mut self) {
        unsafe {
            RoUninitialize();
        }
    }
}
fn enumerator() -> Result<IMMDeviceEnumerator, VoiceError> {
    unsafe { CoCreateInstance(&Audio::MMDeviceEnumerator, None, CLSCTX_ALL) }.map_err(device_error)
}
fn device_id(device: &IMMDevice) -> Result<String, VoiceError> {
    let id = unsafe { device.GetId() }.map_err(device_error)?;
    let value = unsafe { id.to_string() }.map_err(device_error);
    unsafe {
        CoTaskMemFree(Some(id.0.cast()));
    }
    value
}
fn exact_endpoint(
    enumerator: &IMMDeviceEnumerator,
    id: &str,
    flow: Audio::EDataFlow,
) -> Result<IMMDevice, VoiceError> {
    if id.is_empty() || id.len() > 4096 || id.contains('\0') {
        return Err(VoiceError::Unsupported);
    }
    let wide: Vec<u16> = id.encode_utf16().chain(Some(0)).collect();
    let device = unsafe { enumerator.GetDevice(PCWSTR(wide.as_ptr())) }.map_err(device_error)?;
    let endpoint = device.cast::<IMMEndpoint>().map_err(device_error)?;
    if device_id(&device)? != id
        || unsafe { endpoint.GetDataFlow() }.map_err(device_error)? != flow
        || unsafe { device.GetState() }.map_err(device_error)? != Audio::DEVICE_STATE_ACTIVE
    {
        return Err(VoiceError::Device(
            "Approved endpoint is no longer available".into(),
        ));
    }
    Ok(device)
}
struct Lease {
    ids: [String; 2],
}
impl Lease {
    fn new(ids: [String; 2]) -> Result<Self, VoiceError> {
        let mut leases = LEASES.lock().unwrap();
        if ids.iter().any(|id| leases.contains(id)) {
            return Err(VoiceError::Busy);
        }
        leases.extend(ids.iter().cloned());
        Ok(Self { ids })
    }
}
impl Drop for Lease {
    fn drop(&mut self) {
        LEASES.lock().unwrap().retain(|id| !self.ids.contains(id));
    }
}
pub struct WindowsBackend {
    capture_id: String,
    playback_id: String,
    capture_channels: u16,
    playback_channels: u16,
    native_lease: u64,
}
impl WindowsBackend {
    pub(crate) fn native_lease(&self) -> u64 {
        self.native_lease
    }
}
struct WindowsDriver {
    capture: Option<IAudioClient>,
    playback: Option<IAudioClient>,
    input: Option<IAudioCaptureClient>,
    output: Option<IAudioRenderClient>,
    io: MediaIo,
    capture_channels: usize,
    playback_channels: usize,
    output_frames: u32,
    capture_buffer: Vec<f32>,
    output_buffer: Vec<f32>,
    capture_started: bool,
    playback_started: bool,
    lease: Option<Lease>,
    com: Option<ComApartment>,
    selection: WindowsBackend,
    initialized: bool,
}
fn initialize(client: &IAudioClient, channels: u16) -> Result<(), VoiceError> {
    let format = WAVEFORMATEX {
        wFormatTag: 3,
        nChannels: channels,
        nSamplesPerSec: SAMPLE_RATE,
        nAvgBytesPerSec: SAMPLE_RATE * u32::from(channels) * 4,
        nBlockAlign: channels * 4,
        wBitsPerSample: 32,
        cbSize: 0,
    };
    unsafe {
        client.Initialize(
            Audio::AUDCLNT_SHAREMODE_SHARED,
            Audio::AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM
                | Audio::AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY,
            200_000,
            0,
            &format,
            None,
        )
    }
    .map_err(device_error)?;
    Ok(())
}
impl super::sealed::Sealed for WindowsBackend {}
impl VoiceBackend for WindowsBackend {
    fn physical_device_provider(&self) -> bool {
        true
    }
    fn open(self, io: MediaIo) -> Result<Box<dyn VoiceDriver>, VoiceError> {
        // No Activate/Initialize/Start/lease here. Every acquired handle is
        // assigned in poll before the next fallible native operation.
        let capture_channels = self.capture_channels as usize;
        let playback_channels = self.playback_channels as usize;
        Ok(Box::new(WindowsDriver {
            capture: None,
            playback: None,
            input: None,
            output: None,
            io,
            capture_channels,
            playback_channels,
            output_frames: 0,
            capture_buffer: vec![],
            output_buffer: vec![],
            capture_started: false,
            playback_started: false,
            lease: None,
            com: None,
            selection: self,
            initialized: false,
        }))
    }
}
impl VoiceDriver for WindowsDriver {
    fn check_permission(&self) -> Result<(), VoiceError> {
        permission()
    }
    fn stop(&mut self) -> Result<(), VoiceError> {
        fn stopped(client: Option<&IAudioClient>, started: &mut bool) -> Result<(), VoiceError> {
            let Some(client) = client else {
                return Ok(());
            };
            if *started {
                match unsafe { client.Stop() } {
                    Ok(()) => *started = false,
                    Err(error) if error.code() == Audio::AUDCLNT_E_NOT_INITIALIZED => {
                        *started = false
                    }
                    Err(error) => return Err(device_error(error)),
                }
            }
            match unsafe { client.Reset() } {
                Ok(()) => Ok(()),
                // An Activate succeeded but Initialize failed: there is no
                // initialized stream to Reset. Its COM reference still must
                // be released before the device lease can be returned.
                Err(error) if error.code() == Audio::AUDCLNT_E_NOT_INITIALIZED => Ok(()),
                Err(error) => Err(device_error(error)),
            }
        }
        let capture = stopped(self.capture.as_ref(), &mut self.capture_started);
        let playback = stopped(self.playback.as_ref(), &mut self.playback_started);
        capture.and(playback)?;
        self.input = None;
        self.output = None;
        self.capture = None;
        self.playback = None;
        self.capture_buffer.fill(0.);
        self.output_buffer.fill(0.);
        self.lease = None;
        self.com = None;
        self.initialized = false;
        Ok(())
    }
    fn poll(&mut self) -> Result<(), VoiceError> {
        let io = self.io.clone();
        io.execute(|| {
            if !self.initialized {
                self.prepare()?;
            }
            self.poll_native()
        })
    }
}
impl WindowsDriver {
    fn prepare(&mut self) -> Result<(), VoiceError> {
        permission()?;
        self.com = Some(ComApartment::new()?);
        self.lease = Some(Lease::new([
            self.selection.capture_id.clone(),
            self.selection.playback_id.clone(),
        ])?);
        let enumerator = enumerator()?;
        let device = exact_endpoint(&enumerator, &self.selection.capture_id, Audio::eCapture)?;
        self.capture = Some(
            unsafe { device.Activate::<IAudioClient>(CLSCTX_ALL, None) }.map_err(device_error)?,
        );
        initialize(
            self.capture.as_ref().ok_or(VoiceError::NotReady)?,
            self.selection.capture_channels,
        )?;
        if !self.io.active() {
            return Err(VoiceError::Closed);
        }
        let device = exact_endpoint(&enumerator, &self.selection.playback_id, Audio::eRender)?;
        self.playback = Some(
            unsafe { device.Activate::<IAudioClient>(CLSCTX_ALL, None) }.map_err(device_error)?,
        );
        initialize(
            self.playback.as_ref().ok_or(VoiceError::NotReady)?,
            self.selection.playback_channels,
        )?;
        let capture = self.capture.as_ref().ok_or(VoiceError::NotReady)?;
        let playback = self.playback.as_ref().ok_or(VoiceError::NotReady)?;
        let capture_frames = unsafe { capture.GetBufferSize() }.map_err(device_error)?;
        self.output_frames = unsafe { playback.GetBufferSize() }.map_err(device_error)?;
        if capture_frames == 0
            || capture_frames as usize > MAX_NATIVE_FRAMES
            || self.output_frames == 0
            || self.output_frames as usize > MAX_NATIVE_FRAMES
        {
            return Err(VoiceError::Unsupported);
        }
        self.input =
            Some(unsafe { capture.GetService::<IAudioCaptureClient>() }.map_err(device_error)?);
        self.output =
            Some(unsafe { playback.GetService::<IAudioRenderClient>() }.map_err(device_error)?);
        self.capture_buffer = vec![0.; capture_frames as usize * self.capture_channels];
        self.output_buffer = vec![0.; self.output_frames as usize * self.playback_channels];
        if !self.io.active() {
            return Err(VoiceError::Closed);
        }
        permission()?;
        // Mark the attempt before Start, so even an error cannot bypass Stop.
        self.playback_started = true;
        unsafe { playback.Start() }.map_err(device_error)?;
        if !self.io.active() {
            return Err(VoiceError::Closed);
        }
        permission()?;
        self.capture_started = true;
        unsafe { capture.Start() }.map_err(device_error)?;
        if !self.io.active() {
            return Err(VoiceError::Closed);
        }
        self.initialized = true;
        Ok(())
    }
    fn poll_native(&mut self) -> Result<(), VoiceError> {
        let input = self.input.as_ref().ok_or(VoiceError::NotReady)?;
        let output = self.output.as_ref().ok_or(VoiceError::NotReady)?;
        let playback = self.playback.as_ref().ok_or(VoiceError::NotReady)?;
        // A finite packet bound prevents a producer from keeping the worker
        // inside this loop while cancellation or a stop request is pending.
        for _ in 0..16 {
            if !self.io.active() {
                return Ok(());
            }
            let next = unsafe { input.GetNextPacketSize() }.map_err(device_error)?;
            if next == 0 {
                break;
            }
            let mut data = ptr::null_mut();
            let mut frames = 0;
            let mut flags = 0;
            unsafe { input.GetBuffer(&mut data, &mut frames, &mut flags, None, None) }
                .map_err(device_error)?;
            let samples = frames as usize * self.capture_channels;
            let valid = samples <= self.capture_buffer.len()
                && frames != 0
                && (!data.is_null() || flags & Audio::AUDCLNT_BUFFERFLAGS_SILENT.0 as u32 != 0);
            if valid {
                if flags & Audio::AUDCLNT_BUFFERFLAGS_SILENT.0 as u32 != 0 {
                    self.capture_buffer[..samples].fill(0.);
                } else {
                    // memcpy avoids assuming the WASAPI byte buffer alignment.
                    unsafe {
                        ptr::copy_nonoverlapping(
                            data,
                            self.capture_buffer.as_mut_ptr().cast::<u8>(),
                            samples * 4,
                        );
                    }
                }
            }
            unsafe { input.ReleaseBuffer(frames) }.map_err(device_error)?;
            if !valid {
                return Err(VoiceError::InvalidPcm);
            }
            match self
                .io
                .capture(&self.capture_buffer[..samples], self.capture_channels)
            {
                Ok(()) | Err(VoiceError::Busy) | Err(VoiceError::Closed) => (),
                Err(error) => return Err(error),
            }
        }
        if !self.io.active() {
            return Ok(());
        }
        let padding = unsafe { playback.GetCurrentPadding() }.map_err(device_error)?;
        let frames = self
            .output_frames
            .checked_sub(padding)
            .ok_or(VoiceError::InvalidPcm)?;
        if frames != 0 {
            let data = unsafe { output.GetBuffer(frames) }.map_err(device_error)?;
            let samples = frames as usize * self.playback_channels;
            if data.is_null() {
                unsafe { output.ReleaseBuffer(frames, Audio::AUDCLNT_BUFFERFLAGS_SILENT.0 as u32) }
                    .map_err(device_error)?;
                return Err(VoiceError::Device("Null WASAPI render buffer".into()));
            }
            self.io
                .render_pending(&mut self.output_buffer[..samples], self.playback_channels);
            unsafe {
                ptr::copy_nonoverlapping(
                    self.output_buffer.as_ptr().cast::<u8>(),
                    data,
                    samples * 4,
                );
            }
            unsafe { output.ReleaseBuffer(frames, 0) }.map_err(device_error)?;
            self.io.playback_prepared();
        }
        Ok(())
    }
}
