//! Actual Windows 0.61 SDK path. All source/reader COM references stay in this
//! MTA worker. Only copied CPU bytes and plain metadata cross its boundary.
use super::{
    layout::{self, Color, OwnedFrame, Pixels},
    model::{validate_id, NativeFormatKey},
    state::Shared,
    CameraAuthorization, CameraDevice, CameraFormat, CaptureSelection, Code, Failure, Job, Owner,
    Payload,
};
use std::{ffi::c_void, mem, ptr, slice, sync::Arc, time::Duration};
use windows::{
    core::{implement, Interface, Ref, GUID, HRESULT, HSTRING, PCSTR, PCWSTR, PWSTR},
    Devices::Enumeration::{DeviceAccessInformation, DeviceAccessStatus, DeviceClass},
    Win32::{
        Foundation::{CloseHandle, FreeLibrary, HANDLE, HMODULE},
        Media::MediaFoundation::*,
        Security::*,
        System::{
            Com::CoTaskMemFree,
            LibraryLoader::{GetProcAddress, LoadLibraryExW, LOAD_LIBRARY_SEARCH_SYSTEM32},
            RemoteDesktop::ProcessIdToSessionId,
            Threading::{GetCurrentProcess, GetCurrentProcessId, OpenProcessToken},
            WinRT::{RoInitialize, RoUninitialize, RO_INIT_MULTITHREADED},
        },
    },
};

fn error(e: windows::core::Error) -> Failure {
    Failure {
        code: Code::Native,
        hresult: e.code().0,
    }
}
fn hr(value: HRESULT) -> Result<(), Failure> {
    value.ok().map_err(error)
}
struct Apartment;
impl Apartment {
    fn new() -> Result<Self, Failure> {
        unsafe { RoInitialize(RO_INIT_MULTITHREADED) }.map_err(error)?;
        Ok(Self)
    }
}
impl Drop for Apartment {
    fn drop(&mut self) {
        unsafe {
            RoUninitialize();
        }
    }
}
struct Handle(HANDLE);
impl Drop for Handle {
    fn drop(&mut self) {
        let _ = unsafe { CloseHandle(self.0) };
    }
}

fn ordinary_user() -> Result<(), Failure> {
    let mut handle = HANDLE::default();
    unsafe { OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut handle) }.map_err(error)?;
    let handle = Handle(handle);
    let mut length = 0;
    let mut elevated = TOKEN_ELEVATION::default();
    unsafe {
        GetTokenInformation(
            handle.0,
            TokenElevation,
            Some((&mut elevated as *mut TOKEN_ELEVATION).cast()),
            mem::size_of::<TOKEN_ELEVATION>() as u32,
            &mut length,
        )
    }
    .map_err(error)?;
    if elevated.TokenIsElevated != 0 {
        return Err(Failure::new(Code::OrdinaryUser));
    }
    // Aligned allocation, not Vec<u8> cast to a TOKEN_USER. Size discovery is
    // expected to fail with insufficient buffer; only a bounded size is used.
    let _ = unsafe { GetTokenInformation(handle.0, TokenUser, None, 0, &mut length) };
    if length < mem::size_of::<TOKEN_USER>() as u32 || length > 4096 {
        return Err(Failure::new(Code::OrdinaryUser));
    }
    let mut buffer =
        vec![0usize; (length as usize + mem::size_of::<usize>() - 1) / mem::size_of::<usize>()];
    unsafe {
        GetTokenInformation(
            handle.0,
            TokenUser,
            Some(buffer.as_mut_ptr().cast()),
            length,
            &mut length,
        )
    }
    .map_err(error)?;
    let user = unsafe { &*buffer.as_ptr().cast::<TOKEN_USER>() };
    if user.User.Sid.0.is_null()
        || [WinLocalSystemSid, WinLocalServiceSid, WinNetworkServiceSid]
            .iter()
            .any(|sid| unsafe { IsWellKnownSid(user.User.Sid, *sid) }.as_bool())
    {
        return Err(Failure::new(Code::OrdinaryUser));
    }
    let mut session = 0;
    unsafe { ProcessIdToSessionId(GetCurrentProcessId(), &mut session) }.map_err(error)?;
    if session == 0 {
        return Err(Failure::new(Code::OrdinaryUser));
    }
    Ok(())
}
fn status_in_mta() -> Result<CameraAuthorization, Failure> {
    ordinary_user()?;
    let status = DeviceAccessInformation::CreateFromDeviceClass(DeviceClass::VideoCapture)
        .and_then(|info| info.CurrentStatus())
        .map_err(|e| Failure {
            code: Code::Permission,
            hresult: e.code().0,
        })?;
    Ok(match status {
        DeviceAccessStatus::Allowed => CameraAuthorization::Authorized,
        DeviceAccessStatus::DeniedByUser => CameraAuthorization::Denied,
        DeviceAccessStatus::DeniedBySystem => CameraAuthorization::Restricted,
        _ => CameraAuthorization::NotDetermined,
    })
}
fn permission(id: &str) -> Result<(), Failure> {
    if status_in_mta()? != CameraAuthorization::Authorized {
        return Err(Failure::new(Code::Permission));
    }
    let status = DeviceAccessInformation::CreateFromId(&HSTRING::from(id))
        .and_then(|info| info.CurrentStatus())
        .map_err(|e| Failure {
            code: Code::Permission,
            hresult: e.code().0,
        })?;
    if status != DeviceAccessStatus::Allowed {
        return Err(Failure::new(Code::Permission));
    }
    Ok(())
}
pub(super) fn authorization_status() -> Result<CameraAuthorization, Failure> {
    // No RequestAccess call. This isolated thread cannot collide with a UI STA.
    std::thread::Builder::new()
        .name("NikoCameraPermission".into())
        .spawn(|| {
            let _apartment = Apartment::new()?;
            status_in_mta()
        })
        .map_err(|_| Failure::new(Code::Native))?
        .join()
        .map_err(|_| Failure::new(Code::Native))?
}

type Startup = unsafe extern "system" fn(u32, u32) -> HRESULT;
type Shutdown = unsafe extern "system" fn() -> HRESULT;
type Attributes = unsafe extern "system" fn(*mut *mut c_void, u32) -> HRESULT;
type EnumSources =
    unsafe extern "system" fn(*mut c_void, *mut *mut Option<IMFActivate>, *mut u32) -> HRESULT;
type CreateSource = unsafe extern "system" fn(*mut c_void, *mut *mut c_void) -> HRESULT;
type CreateReader =
    unsafe extern "system" fn(*mut c_void, *mut c_void, *mut *mut c_void) -> HRESULT;
type GetStride = unsafe extern "system" fn(u32, u32, *mut i32) -> HRESULT;
struct Module(HMODULE);
impl Module {
    fn load(name: &str) -> Result<Self, Failure> {
        let wide = name.encode_utf16().chain(Some(0)).collect::<Vec<_>>();
        unsafe { LoadLibraryExW(PCWSTR(wide.as_ptr()), None, LOAD_LIBRARY_SEARCH_SYSTEM32) }
            .map(Self)
            .map_err(|e| Failure {
                code: Code::MediaUnavailable,
                hresult: e.code().0,
            })
    }
    fn address(
        &self,
        name: &'static [u8],
    ) -> Result<unsafe extern "system" fn() -> isize, Failure> {
        unsafe { GetProcAddress(self.0, PCSTR(name.as_ptr())) }
            .ok_or_else(|| Failure::new(Code::MediaUnavailable))
    }
}
impl Drop for Module {
    fn drop(&mut self) {
        let _ = unsafe { FreeLibrary(self.0) };
    }
}
struct Runtime {
    shutdown: Shutdown,
    attributes: Attributes,
    enumerate: EnumSources,
    source: CreateSource,
    reader: CreateReader,
    stride: GetStride,
    // Drop only after COM source/reader/callback references have been released.
    _modules: [Module; 3],
    _apartment: Apartment,
}
impl Runtime {
    fn new() -> Result<Self, Failure> {
        let apartment = Apartment::new()?;
        ordinary_user()?;
        let modules = [
            Module::load("mfplat.dll")?,
            Module::load("mf.dll")?,
            Module::load("mfreadwrite.dll")?,
        ];
        // No MF top-level SDK function is called: all optional exports are
        // resolved from System32. MF COM vtables/constants add no DLL imports.
        let startup: Startup = unsafe { mem::transmute(modules[0].address(b"MFStartup\0")?) };
        let shutdown = unsafe { mem::transmute(modules[0].address(b"MFShutdown\0")?) };
        let attributes = unsafe { mem::transmute(modules[0].address(b"MFCreateAttributes\0")?) };
        let stride =
            unsafe { mem::transmute(modules[0].address(b"MFGetStrideForBitmapInfoHeader\0")?) };
        let enumerate = unsafe { mem::transmute(modules[1].address(b"MFEnumDeviceSources\0")?) };
        let source = unsafe { mem::transmute(modules[1].address(b"MFCreateDeviceSource\0")?) };
        let reader = unsafe {
            mem::transmute(modules[2].address(b"MFCreateSourceReaderFromMediaSource\0")?)
        };
        hr(unsafe { startup(MF_VERSION, MFSTARTUP_FULL) })?;
        Ok(Self {
            shutdown,
            attributes,
            enumerate,
            source,
            reader,
            stride,
            _modules: modules,
            _apartment: apartment,
        })
    }
    fn attributes(&self, capacity: u32) -> Result<IMFAttributes, Failure> {
        let mut raw = ptr::null_mut();
        hr(unsafe { (self.attributes)(&mut raw, capacity) })?;
        if raw.is_null() {
            return Err(Failure::new(Code::Native));
        }
        Ok(unsafe { IMFAttributes::from_raw(raw) })
    }
    fn shutdown(&self) -> Result<(), Failure> {
        hr(unsafe { (self.shutdown)() })
    }
    fn source(&self, id: &str) -> Result<IMFMediaSource, Failure> {
        permission(id)?;
        let attributes = self.attributes(2)?;
        let wide = id.encode_utf16().chain(Some(0)).collect::<Vec<_>>();
        unsafe {
            attributes
                .SetGUID(
                    &MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE,
                    &MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_GUID,
                )
                .map_err(error)?;
            attributes
                .SetString(
                    &MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_SYMBOLIC_LINK,
                    PCWSTR(wide.as_ptr()),
                )
                .map_err(error)?;
        }
        let mut raw = ptr::null_mut();
        hr(unsafe { (self.source)(attributes.as_raw(), &mut raw) })?;
        if raw.is_null() {
            return Err(Failure::new(Code::Native));
        }
        Ok(unsafe { IMFMediaSource::from_raw(raw) })
    }
    fn reader(
        &self,
        source: &IMFMediaSource,
        callback: &IMFSourceReaderCallback,
    ) -> Result<IMFSourceReader, Failure> {
        let attrs = self.attributes(4)?;
        unsafe {
            attrs
                .SetUnknown(&MF_SOURCE_READER_ASYNC_CALLBACK, callback)
                .map_err(error)?;
            attrs
                .SetUINT32(&MF_READWRITE_DISABLE_CONVERTERS, 1)
                .map_err(error)?;
            attrs
                .SetUINT32(&MF_SOURCE_READER_DISABLE_DXVA, 1)
                .map_err(error)?;
            attrs
                .SetUINT32(&MF_SOURCE_READER_DISCONNECT_MEDIASOURCE_ON_SHUTDOWN, 1)
                .map_err(error)?;
        }
        let mut raw = ptr::null_mut();
        hr(unsafe { (self.reader)(source.as_raw(), attrs.as_raw(), &mut raw) })?;
        if raw.is_null() {
            return Err(Failure::new(Code::Native));
        }
        Ok(unsafe { IMFSourceReader::from_raw(raw) })
    }
}

struct TaskString(PWSTR);
impl Drop for TaskString {
    fn drop(&mut self) {
        unsafe {
            CoTaskMemFree(Some(self.0 .0.cast()));
        }
    }
}
fn string(attrs: &IMFAttributes, key: &GUID) -> Result<String, Failure> {
    let mut raw = PWSTR::null();
    let mut length = 0;
    unsafe { attrs.GetAllocatedString(key, &mut raw, &mut length) }.map_err(error)?;
    let owned = TaskString(raw);
    if length == 0 || length > 4096 || raw.is_null() {
        return Err(Failure::new(Code::InvalidDevice));
    }
    let chars = unsafe { slice::from_raw_parts(owned.0 .0, length as usize) };
    let result = String::from_utf16(chars).map_err(|_| Failure::new(Code::InvalidDevice))?;
    if result.contains('\0') {
        return Err(Failure::new(Code::InvalidDevice));
    }
    Ok(result)
}
struct Activations {
    ptr: *mut Option<IMFActivate>,
    count: u32,
}
impl Drop for Activations {
    fn drop(&mut self) {
        if !self.ptr.is_null() {
            // MF guarantees a count-sized CoTaskMem array, each entry AddRef'd.
            for entry in unsafe { slice::from_raw_parts_mut(self.ptr, self.count as usize) } {
                entry.take();
            }
            unsafe {
                CoTaskMemFree(Some(self.ptr.cast()));
            }
        }
    }
}
fn enumerate(runtime: &Runtime) -> Result<Vec<CameraDevice>, Failure> {
    let attrs = runtime.attributes(1)?;
    unsafe {
        attrs.SetGUID(
            &MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE,
            &MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_GUID,
        )
    }
    .map_err(error)?;
    let mut array = Activations {
        ptr: ptr::null_mut(),
        count: 0,
    };
    hr(unsafe { (runtime.enumerate)(attrs.as_raw(), &mut array.ptr, &mut array.count) })?;
    if array.count > 64 || (array.count != 0 && array.ptr.is_null()) {
        return Err(Failure::new(Code::InvalidDevice));
    }
    let mut devices = Vec::new();
    if array.count != 0 {
        for activation in unsafe { slice::from_raw_parts(array.ptr, array.count as usize) } {
            let activation = activation
                .as_ref()
                .ok_or_else(|| Failure::new(Code::InvalidDevice))?;
            // Attribute reads only. No ActivateObject/Camera::new/default device.
            devices.push(CameraDevice {
                unique_id: string(
                    activation,
                    &MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_SYMBOLIC_LINK,
                )?,
                name: string(activation, &MF_DEVSOURCE_ATTRIBUTE_FRIENDLY_NAME)?,
                formats: Vec::new(),
            });
            validate_id(
                &devices
                    .last()
                    .ok_or_else(|| Failure::new(Code::InvalidDevice))?
                    .unique_id,
                1,
            )?;
        }
    }
    Ok(devices)
}
/// Canonical complete native attribute identity: sorted GUID keys plus exact
/// typed values. IUnknown/oversized attributes are rejected rather than silently
/// omitted (MFGetAttributesAsBlob would omit IUnknown values).
fn attribute_identity(attrs: &IMFAttributes) -> Result<Vec<u8>, Failure> {
    let count = unsafe { attrs.GetCount() }.map_err(error)?;
    if count > 64 {
        return Err(Failure::new(Code::UnsupportedFormat));
    }
    let mut keys = Vec::with_capacity(count as usize);
    for i in 0..count {
        let mut key = GUID::zeroed();
        unsafe { attrs.GetItemByIndex(i, &mut key, None) }.map_err(error)?;
        keys.push(key);
    }
    keys.sort_by_key(GUID::to_u128);
    let mut result = Vec::new();
    for key in keys {
        let kind = unsafe { attrs.GetItemType(&key) }.map_err(error)?;
        let value = unsafe {
            match kind {
                MF_ATTRIBUTE_UINT32 => attrs.GetUINT32(&key).map_err(error)?.to_le_bytes().to_vec(),
                MF_ATTRIBUTE_UINT64 => attrs.GetUINT64(&key).map_err(error)?.to_le_bytes().to_vec(),
                MF_ATTRIBUTE_DOUBLE => attrs
                    .GetDouble(&key)
                    .map_err(error)?
                    .to_bits()
                    .to_le_bytes()
                    .to_vec(),
                MF_ATTRIBUTE_GUID => attrs
                    .GetGUID(&key)
                    .map_err(error)?
                    .to_u128()
                    .to_le_bytes()
                    .to_vec(),
                MF_ATTRIBUTE_STRING => {
                    let length = attrs.GetStringLength(&key).map_err(error)?;
                    if length > 1024 {
                        return Err(Failure::new(Code::UnsupportedFormat));
                    }
                    let mut wide = vec![0u16; length as usize + 1];
                    let mut actual = 0;
                    attrs
                        .GetString(&key, &mut wide, Some(&mut actual))
                        .map_err(error)?;
                    if actual != length {
                        return Err(Failure::new(Code::Stale));
                    }
                    wide[..length as usize]
                        .iter()
                        .flat_map(|c| c.to_le_bytes())
                        .collect()
                }
                MF_ATTRIBUTE_BLOB => {
                    let length = attrs.GetBlobSize(&key).map_err(error)?;
                    if length > 2048 {
                        return Err(Failure::new(Code::UnsupportedFormat));
                    }
                    let mut bytes = vec![0; length as usize];
                    let mut actual = 0;
                    attrs
                        .GetBlob(&key, &mut bytes, Some(&mut actual))
                        .map_err(error)?;
                    if actual != length {
                        return Err(Failure::new(Code::Stale));
                    }
                    bytes
                }
                _ => return Err(Failure::new(Code::UnsupportedFormat)),
            }
        };
        result.extend_from_slice(&key.to_u128().to_le_bytes());
        result.extend_from_slice(&kind.0.to_le_bytes());
        result.extend_from_slice(&(value.len() as u32).to_le_bytes());
        result.extend_from_slice(&value);
        if result.len() > 2048 {
            return Err(Failure::new(Code::UnsupportedFormat));
        }
    }
    Ok(result)
}
fn key(
    runtime: &Runtime,
    media_type: &IMFMediaType,
    stream: u32,
    stream_id: u32,
) -> Result<NativeFormatKey, Failure> {
    unsafe {
        if media_type.GetGUID(&MF_MT_MAJOR_TYPE).map_err(error)? != MFMediaType_Video {
            return Err(Failure::new(Code::UnsupportedFormat));
        }
        let subtype = media_type.GetGUID(&MF_MT_SUBTYPE).map_err(error)?;
        let size = media_type.GetUINT64(&MF_MT_FRAME_SIZE).map_err(error)?;
        let (width, height) = ((size >> 32) as u32, size as u32);
        layout::dimensions(width, height)?;
        let fps = media_type.GetUINT64(&MF_MT_FRAME_RATE).map_err(error)?;
        let (fps_num, fps_den) = ((fps >> 32) as u32, fps as u32);
        if fps_num == 0 || fps_den == 0 || u64::from(fps_num) > 60 * u64::from(fps_den) {
            return Err(Failure::new(Code::UnsupportedFormat));
        }
        let pixels = if subtype == MFVideoFormat_RGB32 {
            Pixels::Bgrx
        } else if subtype == MFVideoFormat_ARGB32 {
            Pixels::Bgra
        } else if subtype == MFVideoFormat_NV12 {
            Pixels::Nv12
        } else if subtype == MFVideoFormat_YUY2 {
            Pixels::Yuy2
        } else {
            return Err(Failure::new(Code::UnsupportedFormat));
        };
        let interlace = media_type.GetUINT32(&MF_MT_INTERLACE_MODE).map_err(error)?;
        if interlace != MFVideoInterlace_Progressive.0 as u32 {
            return Err(Failure::new(Code::UnsupportedFormat));
        }
        let pixel_aspect = media_type
            .GetUINT64(&MF_MT_PIXEL_ASPECT_RATIO)
            .map_err(error)?;
        if pixel_aspect >> 32 == 0
            || pixel_aspect as u32 == 0
            || pixel_aspect >> 32 != u64::from(pixel_aspect as u32)
            || media_type.GetUINT32(&MF_MT_VIDEO_ROTATION).unwrap_or(0) != 0
        {
            return Err(Failure::new(Code::UnsupportedFormat));
        }
        let matrix = media_type.GetUINT32(&MF_MT_YUV_MATRIX).unwrap_or(0);
        let range = media_type
            .GetUINT32(&MF_MT_VIDEO_NOMINAL_RANGE)
            .unwrap_or(0);
        let color = if matches!(pixels, Pixels::Nv12 | Pixels::Yuy2) {
            // Unknown chroma conversion is deliberately not guessed from size.
            Some(match (matrix, range) {
                (2, 2) => Color::Bt601Limited,
                (2, 1) => Color::Bt601Full,
                (1, 2) => Color::Bt709Limited,
                (1, 1) => Color::Bt709Full,
                _ => return Err(Failure::new(Code::UnsupportedFormat)),
            })
        } else {
            None
        };
        let stride = match media_type.GetUINT32(&MF_MT_DEFAULT_STRIDE) {
            Ok(value) => value as i32,
            Err(_) => {
                let mut stride = 0;
                hr((runtime.stride)(subtype.data1, width, &mut stride))?;
                stride
            }
        };
        let minimum = width as i64
            * match pixels {
                Pixels::Bgra | Pixels::Bgrx => 4,
                Pixels::Yuy2 => 2,
                Pixels::Nv12 => 1,
            };
        if i64::from(stride).abs() < minimum || (pixels == Pixels::Nv12 && stride <= 0) {
            return Err(Failure::new(Code::InvalidLayout));
        }
        Ok(NativeFormatKey {
            stream,
            stream_id,
            subtype: subtype.to_u128(),
            width,
            height,
            fps_num,
            fps_den,
            stride,
            pixels,
            color,
            matrix,
            range,
            interlace,
            pixel_aspect,
            attributes: attribute_identity(media_type)?,
        })
    }
}
fn native_types(
    runtime: &Runtime,
    source: &IMFMediaSource,
    shared: &Shared,
) -> Result<Vec<(NativeFormatKey, IMFMediaType)>, Failure> {
    let pd = unsafe { source.CreatePresentationDescriptor() }.map_err(error)?;
    let count = unsafe { pd.GetStreamDescriptorCount() }.map_err(error)?;
    if count == 0 || count > 32 {
        return Err(Failure::new(Code::InvalidFormat));
    }
    let mut types = Vec::new();
    for stream in 0..count {
        let mut selected = false.into();
        let mut sd = None;
        unsafe { pd.GetStreamDescriptorByIndex(stream, &mut selected, &mut sd) }.map_err(error)?;
        let sd = sd.ok_or_else(|| Failure::new(Code::Native))?;
        let stream_id = unsafe { sd.GetStreamIdentifier() }.map_err(error)?;
        let handler = unsafe { sd.GetMediaTypeHandler() }.map_err(error)?;
        let count = unsafe { handler.GetMediaTypeCount() }.map_err(error)?;
        if count > 512 {
            return Err(Failure::new(Code::InvalidFormat));
        }
        for index in 0..count {
            if !shared.open() {
                return Err(Failure::new(Code::Closed));
            }
            let mt = unsafe { handler.GetMediaTypeByIndex(index) }.map_err(error)?;
            match key(runtime, &mt, stream, stream_id) {
                Ok(k) => {
                    if !types.iter().any(|(old, _)| *old == k) {
                        types.push((k, mt));
                    }
                }
                Err(Failure {
                    code: Code::UnsupportedFormat,
                    ..
                }) => (),
                Err(e) => return Err(e),
            }
            if types.len() > 512 {
                return Err(Failure::new(Code::InvalidFormat));
            }
        }
    }
    Ok(types)
}

#[implement(IMFSourceReaderCallback)]
struct ReaderCallback {
    shared: Arc<Shared>,
    format: NativeFormatKey,
    epoch: u64,
}
impl Drop for ReaderCallback {
    fn drop(&mut self) {
        // Actual final COM Release, distinct from OnFlush/callback return.
        self.shared.state.lock().unwrap().callback_released = true;
        self.shared.changed.notify_all();
    }
}
impl IMFSourceReaderCallback_Impl for ReaderCallback_Impl {
    fn OnReadSample(
        &self,
        status: HRESULT,
        stream: u32,
        flags: u32,
        timestamp: i64,
        sample: Ref<'_, IMFSample>,
    ) -> windows::core::Result<()> {
        let _inflight = self.shared.callback();
        self.shared.state.lock().unwrap().pending_read = false;
        if !self.shared.open() {
            return Ok(());
        }
        let fatal = MF_SOURCE_READERF_ERROR.0
            | MF_SOURCE_READERF_ENDOFSTREAM.0
            | MF_SOURCE_READERF_NATIVEMEDIATYPECHANGED.0
            | MF_SOURCE_READERF_CURRENTMEDIATYPECHANGED.0
            | MF_SOURCE_READERF_NEWSTREAM.0;
        if status.is_err()
            || flags & fatal as u32 != 0
            || stream != self.format.stream
            || timestamp < 0
        {
            self.shared.fail(Failure {
                code: Code::Native,
                hresult: status.0,
            });
            return Ok(());
        }
        if let Some(sample) = sample.as_ref() {
            match read_frame(sample, &self.format, self.epoch, &self.shared) {
                Ok(frame) => self.shared.publish(frame),
                Err(error) => self.shared.fail(error),
            }
        }
        // STREAMTICK/no sample is not readiness. The worker schedules the next
        // request after this callback returns; callbacks never own the reader.
        Ok(())
    }
    fn OnFlush(&self, index: u32) -> windows::core::Result<()> {
        let _inflight = self.shared.callback();
        if index == self.format.stream || index == MF_SOURCE_READER_ALL_STREAMS.0 as u32 {
            self.shared.flushed();
        }
        Ok(())
    }
    fn OnEvent(&self, _index: u32, event: Ref<'_, IMFMediaEvent>) -> windows::core::Result<()> {
        let _inflight = self.shared.callback();
        if let Some(event) = event.as_ref() {
            let event_type = unsafe { event.GetType() };
            if matches!(event_type, Ok(value) if value == MEError.0 as u32 || value == MEVideoCaptureDeviceRemoved.0 as u32
                || value == MEVideoCaptureDevicePreempted.0 as u32)
            {
                self.shared.fail(Failure::new(Code::Closed));
            }
            match unsafe { event.GetStatus() } {
                Ok(status) if status.is_err() => self.shared.fail(Failure {
                    code: Code::Native,
                    hresult: status.0,
                }),
                Err(e) => self.shared.fail(error(e)),
                _ => (),
            }
        }
        Ok(())
    }
}

enum Lock {
    TwoD(IMF2DBuffer2),
    Basic(IMFMediaBuffer),
}
fn unlock(lock: &Lock) -> Result<(), Failure> {
    match lock {
        Lock::TwoD(b) => unsafe { b.Unlock2D() },
        Lock::Basic(b) => unsafe { b.Unlock() },
    }
    .map_err(error)
}
fn buffer_lock<'a>(
    lock: Lock,
    shared: &'a Shared,
) -> super::lease::ReleaseGuard<Lock, fn(&Lock) -> Result<(), Failure>, impl Fn() + 'a> {
    super::lease::ReleaseGuard::new(
        lock,
        unlock as fn(&Lock) -> Result<(), Failure>,
        move || {
            shared.state.lock().unwrap().buffer_uncertain = true;
            shared.fail(Failure::new(Code::Native));
        },
    )
}
fn read_frame(
    sample: &IMFSample,
    format: &NativeFormatKey,
    epoch: u64,
    shared: &Shared,
) -> Result<OwnedFrame, Failure> {
    if unsafe { sample.GetBufferCount() }.map_err(error)? != 1 {
        return Err(Failure::new(Code::InvalidLayout));
    }
    let buffer = unsafe { sample.GetBufferByIndex(0) }.map_err(error)?;
    let mut scanline = ptr::null_mut();
    let mut start = ptr::null_mut();
    let mut length = 0;
    let pitch;
    let mut lock;
    if let Ok(two_d) = buffer.cast::<IMF2DBuffer2>() {
        let mut stride = 0;
        unsafe {
            two_d.Lock2DSize(
                MF2DBuffer_LockFlags_Read,
                &mut scanline,
                &mut stride,
                &mut start,
                &mut length,
            )
        }
        .map_err(error)?;
        pitch = stride;
        lock = buffer_lock(Lock::TwoD(two_d), shared);
    } else {
        let mut maximum = 0;
        unsafe { buffer.Lock(&mut start, Some(&mut maximum), Some(&mut length)) }.map_err(error)?;
        lock = buffer_lock(Lock::Basic(buffer.clone()), shared);
        pitch = format.stride;
        if length > maximum {
            lock.finish()?;
            return Err(Failure::new(Code::InvalidLayout));
        }
        scanline = start;
        if pitch < 0 {
            let offset = i64::from(pitch)
                .abs()
                .checked_mul(i64::from(format.height - 1));
            if let Some(offset) = offset.filter(|n| *n < i64::from(length)) {
                scanline = start.wrapping_add(offset as usize);
            } else {
                lock.finish()?;
                return Err(Failure::new(Code::InvalidLayout));
            }
        }
    }
    let result = (|| {
        if start.is_null()
            || scanline.is_null()
            || length == 0
            || length as usize > layout::MAX_BYTES
        {
            return Err(Failure::new(Code::InvalidLayout));
        }
        let first = (scanline as usize)
            .checked_sub(start as usize)
            .filter(|n| *n < length as usize)
            .ok_or_else(|| Failure::new(Code::InvalidLayout))?;
        let bytes = unsafe { slice::from_raw_parts(start, length as usize) };
        layout::normalize(
            bytes,
            first,
            pitch,
            format.width,
            format.height,
            format.pixels,
            format.color,
            epoch,
        )
    })();
    lock.finish()?;
    result
}

fn capture(
    runtime: &Runtime,
    source: &IMFMediaSource,
    selection: &CaptureSelection,
    shared: &Arc<Shared>,
    reader_owner: &mut Option<IMFSourceReader>,
    callback_owner: &mut Option<IMFSourceReaderCallback>,
) -> Result<(), Failure> {
    permission(&selection.unique_id)?;
    let types = native_types(runtime, source, shared)?;
    let (_, media_type) = types
        .into_iter()
        .find(|(key, _)| *key == selection.format.key)
        .ok_or_else(|| Failure::new(Code::Stale))?;
    shared.state.lock().unwrap().callback_attached = true;
    let callback: IMFSourceReaderCallback = ReaderCallback {
        shared: shared.clone(),
        format: selection.format.key.clone(),
        epoch: selection.epoch,
    }
    .into();
    *callback_owner = Some(callback.clone());
    *reader_owner = Some(shared.execute(|| runtime.reader(source, &callback))?);
    let reader = reader_owner
        .as_ref()
        .ok_or_else(|| Failure::new(Code::Native))?;
    let stream = selection.format.key.stream;
    shared.execute(|| unsafe {
        reader
            .SetStreamSelection(MF_SOURCE_READER_ALL_STREAMS.0 as u32, false)
            .map_err(error)?;
        reader
            .SetCurrentMediaType(stream, None, &media_type)
            .map_err(error)?;
        reader.SetStreamSelection(stream, true).map_err(error)?;
        Ok(())
    })?;
    let current = unsafe { reader.GetCurrentMediaType(stream) }.map_err(error)?;
    let mut current_key = key(runtime, &current, stream, selection.format.key.stream_id)?;
    // The reader may add attributes, but must preserve every selected native
    // key/value. A conversion/type change is never accepted as a fallback.
    if !unsafe { media_type.Compare(&current, MF_ATTRIBUTES_MATCH_OUR_ITEMS) }
        .map_err(error)?
        .as_bool()
    {
        return Err(Failure::new(Code::Stale));
    }
    current_key.attributes = selection.format.key.attributes.clone();
    if current_key != selection.format.key {
        return Err(Failure::new(Code::Stale));
    }
    let mut last_permission = std::time::Instant::now() - Duration::from_secs(1);
    while shared.open() {
        if last_permission.elapsed() >= Duration::from_millis(250) {
            permission(&selection.unique_id)?;
            last_permission = std::time::Instant::now();
        }
        if shared.begin_read() {
            permission(&selection.unique_id)?;
            if !shared.open() {
                shared.state.lock().unwrap().pending_read = false;
                break;
            }
            // No default index, conversion or resolution/fps fallback. In async
            // mode all output arguments must be NULL (SDK contract).
            shared.execute(|| {
                unsafe { reader.ReadSample(stream, 0, None, None, None, None) }.map_err(error)
            })?;
        }
        let state = shared.state.lock().unwrap();
        let _ = shared
            .changed
            .wait_timeout(state, Duration::from_millis(10))
            .unwrap();
    }
    Ok(())
}

pub(super) fn run(job: Job, shared: Arc<Shared>, owner: Arc<Owner>) {
    let runtime = match Runtime::new() {
        Ok(runtime) => runtime,
        Err(error) => {
            shared.fail(error);
            let mut s = shared.state.lock().unwrap();
            s.shutdown_ack = true;
            s.runtime_ack = true;
            s.finished = true;
            shared.changed.notify_all();
            return;
        }
    };
    let mut source: Option<IMFMediaSource> = None;
    let mut reader = None;
    let mut callback = None;
    let outcome = std::panic::catch_unwind(std::panic::AssertUnwindSafe(
        || -> Result<Option<Payload>, Failure> {
            if !shared.open() {
                return Err(Failure::new(Code::Closed));
            }
            match job {
                Job::Devices => Ok(Some(Payload::Devices(enumerate(&runtime)?))),
                Job::Probe { id, epoch } => {
                    validate_id(&id, epoch)?;
                    permission(&id)?;
                    let device = enumerate(&runtime)?
                        .into_iter()
                        .find(|d| d.unique_id == id)
                        .ok_or_else(|| Failure::new(Code::InvalidDevice))?;
                    source = Some(shared.execute(|| runtime.source(&id))?);
                    let native = source.as_ref().ok_or_else(|| Failure::new(Code::Native))?;
                    let formats = native_types(&runtime, native, &shared)?
                        .into_iter()
                        .map(|(key, _)| CameraFormat {
                            width: key.width,
                            height: key.height,
                            key,
                            device_id: id.clone(),
                            epoch,
                        })
                        .collect();
                    Ok(Some(Payload::Probe(CameraDevice { formats, ..device })))
                }
                Job::Capture(selection) => {
                    selection.validate_native()?;
                    permission(&selection.unique_id)?;
                    if !enumerate(&runtime)?
                        .iter()
                        .any(|d| d.unique_id == selection.unique_id)
                    {
                        return Err(Failure::new(Code::InvalidDevice));
                    }
                    source = Some(shared.execute(|| runtime.source(&selection.unique_id))?);
                    capture(
                        &runtime,
                        source.as_ref().ok_or_else(|| Failure::new(Code::Native))?,
                        &selection,
                        &shared,
                        &mut reader,
                        &mut callback,
                    )?;
                    Ok(None)
                }
            }
        },
    ))
    .unwrap_or_else(|_| Err(Failure::new(Code::Native)));
    match outcome {
        Ok(Some(payload)) => {
            *owner.result.lock().unwrap() = Some(Ok(payload));
        }
        Ok(None) => (),
        Err(error) => {
            *owner.result.lock().unwrap() = Some(Err(error));
            shared.fail(error);
        }
    }
    shared.cancel();
    // Failure/timeout means retain this MTA, its COM refs and DLLs. A registry
    // owner prevents replacement. No thread termination or COM cross-thread drop.
    if let Some(reader) = reader.as_ref() {
        let mut requested = false;
        loop {
            if !requested {
                {
                    let mut s = shared.state.lock().unwrap();
                    s.flush_requested = true;
                    s.flush_ack = false;
                }
                match unsafe { reader.Flush(MF_SOURCE_READER_ALL_STREAMS.0 as u32) } {
                    Ok(()) => requested = true,
                    Err(e) => {
                        shared.fail(error(e));
                    }
                }
            }
            let state = shared.state.lock().unwrap();
            if requested && state.drained() && !state.buffer_uncertain {
                break;
            }
            let _ = shared
                .changed
                .wait_timeout(state, Duration::from_millis(250))
                .unwrap();
        }
    }
    if let Some(source) = source.as_ref() {
        loop {
            match unsafe { source.Shutdown() } {
                Ok(()) => break,
                Err(e) if e.code() == MF_E_SHUTDOWN => break,
                Err(e) => {
                    shared.fail(error(e));
                    let state = shared.state.lock().unwrap();
                    let _ = shared
                        .changed
                        .wait_timeout(state, Duration::from_millis(250))
                        .unwrap();
                }
            }
        }
    }
    shared.state.lock().unwrap().shutdown_ack = true;
    drop(reader);
    drop(source);
    drop(callback);
    loop {
        let state = shared.state.lock().unwrap();
        if (!state.callback_attached || state.callback_released) && state.callbacks == 0 {
            break;
        }
        let _ = shared
            .changed
            .wait_timeout(state, Duration::from_millis(250))
            .unwrap();
    }
    loop {
        match runtime.shutdown() {
            Ok(()) => break,
            Err(e) => {
                shared.fail(e);
                let state = shared.state.lock().unwrap();
                let _ = shared
                    .changed
                    .wait_timeout(state, Duration::from_millis(250))
                    .unwrap();
            }
        }
    }
    drop(runtime);
    let mut state = shared.state.lock().unwrap();
    state.runtime_ack = true;
    state.finished = true;
    shared.changed.notify_all();
}
