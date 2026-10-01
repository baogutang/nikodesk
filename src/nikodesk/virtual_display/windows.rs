//! The independent NikoDesk IDD on a new software-device instance.
//! No driver installation, global device enumeration or existing adapter IOCTL.
use std::{collections::HashMap, sync::{atomic::{AtomicUsize, Ordering}, mpsc, Mutex, OnceLock}, time::{Duration, Instant}};
use windows::{core::{GUID, PCWSTR, HRESULT, w}, Win32::{
    Devices::{DeviceAndDriverInstallation::{CM_Get_Device_Interface_List_SizeW, CM_Get_Device_Interface_ListW,
        CM_GET_DEVICE_INTERFACE_LIST_PRESENT, CR_SUCCESS, CM_Get_Device_Interface_PropertyW,
        CM_Locate_DevNodeW, CM_Get_DevNode_PropertyW, CM_LOCATE_DEVNODE_NORMAL},
        Properties::{DEVPKEY_Device_ContainerId, DEVPKEY_Device_InstanceId, DEVPROPTYPE, DEVPROP_TYPE_STRING, DEVPROP_TYPE_GUID},
        Display::{GetDisplayConfigBufferSizes, QueryDisplayConfig, DisplayConfigGetDeviceInfo,
            QDC_ONLY_ACTIVE_PATHS, DISPLAYCONFIG_PATH_INFO, DISPLAYCONFIG_MODE_INFO,
            DISPLAYCONFIG_TARGET_DEVICE_NAME, DISPLAYCONFIG_DEVICE_INFO_HEADER, DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_NAME},
        Enumeration::Pnp::{SwDeviceCreate, SwDeviceClose,
        SwDeviceSetLifetime, SW_DEVICE_CREATE_INFO, HSWDEVICE, SWDeviceLifetimeHandle, SWDeviceCapabilitiesRemovable}},
    Foundation::{CloseHandle, HANDLE, GENERIC_READ, GENERIC_WRITE},
    Storage::FileSystem::{CreateFileW, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL},
    System::IO::DeviceIoControl,
}};

use super::protocol::{self, PLUG_IN, PLUG_OUT};
const INTERFACE: GUID = GUID::from_u128(protocol::INTERFACE_ID);
type Created = Result<Vec<u16>, ()>;
static CALLBACKS: OnceLock<Mutex<HashMap<usize, mpsc::SyncSender<Created>>>> = OnceLock::new();
static NEXT: AtomicUsize = AtomicUsize::new(1);
fn callbacks() -> &'static Mutex<HashMap<usize, mpsc::SyncSender<Created>>> { CALLBACKS.get_or_init(Mutex::default) }
fn wide(value: &str) -> Vec<u16> { value.encode_utf16().chain(Some(0)).collect() }
unsafe extern "system" fn created(_device: HSWDEVICE, result: HRESULT, context: *const std::ffi::c_void, id: PCWSTR) {
    // Only an integer token is passed to Windows. Late/cancelled callbacks never
    // dereference a freed Rust object and cannot signal a later operation.
    let sender = callbacks().lock().ok().and_then(|mut book| book.remove(&(context as usize)));
    let Some(sender) = sender else { return; };
    let mut instance = Vec::new();
    if result.is_ok() && !id.is_null() {
        for index in 0..1024 {
            let value = *id.0.add(index);
            if value == 0 { instance.push(0); break; }
            instance.push(value);
        }
    }
    let valid = instance.last() == Some(&0) && String::from_utf16_lossy(&instance)
        .to_ascii_lowercase().starts_with("swd\\nikodeskvirtualdisplay\\");
    let _ = sender.try_send(if valid { Ok(instance) } else { Err(()) });
}
pub(super) fn supported() -> bool {
    base::platform::windows::is_windows_version_or_greater(10, 0, 19041, 0, 0)
        && if crate::nikodesk::background::is_system_worker() {
            crate::nikodesk::background::worker_active()
        } else {
            // SwDeviceCreate requires Administrator access. Read the actual
            // token; this path never raises UAC or starts another process.
            crate::platform::windows::is_elevated(None).unwrap_or(false)
        }
}
struct Device(usize);
impl Drop for Device { fn drop(&mut self) { unsafe { SwDeviceClose(HSWDEVICE(self.0 as _)); } } }
struct File(usize);
impl File { fn handle(&self) -> HANDLE { HANDLE(self.0 as _) } }
impl Drop for File { fn drop(&mut self) { unsafe { let _ = CloseHandle(self.handle()); } } }
fn interfaces(instance: &[u16]) -> Result<Vec<u16>, &'static str> {
    if instance.len() < 2 || instance.last() != Some(&0) { return Err("invalid_adapter_identity"); }
    unsafe {
        let mut length = 0;
        if CM_Get_Device_Interface_List_SizeW(&mut length, &INTERFACE, PCWSTR(instance.as_ptr()),
            CM_GET_DEVICE_INTERFACE_LIST_PRESENT) != CR_SUCCESS || length > 32768 || length < 2 {
            return Err("virtual_display_driver_unavailable");
        }
        let mut links = vec![0; length as usize];
        if CM_Get_Device_Interface_ListW(&INTERFACE, PCWSTR(instance.as_ptr()), &mut links,
            CM_GET_DEVICE_INTERFACE_LIST_PRESENT) != CR_SUCCESS { return Err("virtual_display_driver_unavailable"); }
        let end = links.iter().position(|value| *value == 0).ok_or("invalid_adapter_identity")?;
        // Reject zero or multiple interfaces instead of selecting an arbitrary adapter.
        if end == 0 || links[end + 1..].iter().any(|value| *value != 0) { return Err("virtual_display_driver_unavailable"); }
        links.truncate(end + 1);
        Ok(links)
    }
}
#[repr(C)]
struct PlugIn { protocol: u32, connector: u32, container: GUID }
fn monitor_present(container: &GUID) -> Result<bool, &'static str> {
    unsafe {
        let mut path_count = 0;
        let mut mode_count = 0;
        if GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS, &mut path_count, &mut mode_count).0 != 0
            || path_count > 64 || mode_count > 256 { return Err("display_query_unconfirmed"); }
        let mut paths = vec![DISPLAYCONFIG_PATH_INFO::default(); path_count as usize];
        let mut modes = vec![DISPLAYCONFIG_MODE_INFO::default(); mode_count as usize];
        if QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS, &mut path_count, paths.as_mut_ptr(), &mut mode_count,
            modes.as_mut_ptr(), None).0 != 0 { return Err("display_query_unconfirmed"); }
        for path in paths.iter().take(path_count as usize) {
            let mut name = DISPLAYCONFIG_TARGET_DEVICE_NAME { header: DISPLAYCONFIG_DEVICE_INFO_HEADER {
                r#type: DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_NAME, size: std::mem::size_of::<DISPLAYCONFIG_TARGET_DEVICE_NAME>() as _,
                adapterId: path.targetInfo.adapterId, id: path.targetInfo.id }, ..Default::default() };
            if DisplayConfigGetDeviceInfo(&mut name.header) != 0 { return Err("display_query_unconfirmed"); }
            let mut instance = [0u16; 1024];
            let mut length = (instance.len() * 2) as u32;
            let mut kind = DEVPROPTYPE::default();
            if CM_Get_Device_Interface_PropertyW(PCWSTR(name.monitorDevicePath.as_ptr()), &DEVPKEY_Device_InstanceId,
                &mut kind, Some(instance.as_mut_ptr().cast()), &mut length, 0) != CR_SUCCESS { continue; }
            if kind != DEVPROP_TYPE_STRING || length < 2 || length as usize > instance.len() * 2
                || instance[(length as usize / 2) - 1] != 0 { return Err("display_query_unconfirmed"); }
            let mut node = 0;
            if CM_Locate_DevNodeW(&mut node, PCWSTR(instance.as_ptr()), CM_LOCATE_DEVNODE_NORMAL) != CR_SUCCESS { continue; }
            let mut actual = GUID::zeroed();
            let mut size = std::mem::size_of::<GUID>() as u32;
            if CM_Get_DevNode_PropertyW(node, &DEVPKEY_Device_ContainerId, &mut kind,
                Some((&mut actual as *mut GUID).cast()), &mut size, 0) != CR_SUCCESS { continue; }
            if kind == DEVPROP_TYPE_GUID && size == std::mem::size_of::<GUID>() as u32 && actual == *container { return Ok(true); }
        }
        Ok(false)
    }
}
pub(super) struct Screen { device: Option<Device>, file: Option<File>, instance: Vec<u16>, plugged: bool, container: GUID }
impl Screen {
    pub(super) fn create(slot: u32) -> Result<Self, &'static str> { Self::connect(slot, true) }
    pub(super) fn probe() -> Result<(), &'static str> {
        let mut adapter = Self::connect(1, false)?;
        let deadline = Instant::now() + Duration::from_secs(2);
        loop {
            if adapter.remove().is_ok() { return Ok(()); }
            if Instant::now() >= deadline { return Err("cleanup_pending"); }
            std::thread::sleep(Duration::from_millis(25));
        }
    }
    fn connect(slot: u32, plug: bool) -> Result<Self, &'static str> {
        if !base::platform::windows::is_windows_version_or_greater(10,0,19041,0,0) {return Err("backend_unavailable");}
        if !supported() { return Err("background_service_required"); }
        if !(1..=4).contains(&slot) { return Err("invalid_display_slot"); }
        let nonce = crate::nikodesk::voice_call::nonce()?;
        let name = wide(&format!("NikoDesk-{slot}-{nonce}"));
        let hardware = wide("NikoDeskIddDriver\0");
        let info = SW_DEVICE_CREATE_INFO { cbSize: std::mem::size_of::<SW_DEVICE_CREATE_INFO>() as _,
            pszInstanceId: PCWSTR(name.as_ptr()), pszzHardwareIds: PCWSTR(hardware.as_ptr()),
            pszDeviceDescription: w!("NikoDesk virtual display adapter"),
            CapabilityFlags: SWDeviceCapabilitiesRemovable.0 as u32, ..Default::default() };
        let token = NEXT.fetch_update(Ordering::AcqRel, Ordering::Acquire, |value| value.checked_add(1))
            .map_err(|_| "worker_failed")?;
        let (sender, receiver) = mpsc::sync_channel(1);
        callbacks().lock().map_err(|_| "worker_failed")?.insert(token, sender);
        let device = unsafe { SwDeviceCreate(w!("NikoDeskVirtualDisplay"), w!("HTREE\\ROOT\\0"),
            &info, None, Some(created), Some(token as *const std::ffi::c_void)) };
        let device = match device {
            Ok(handle) => Device(handle.0 as usize),
            Err(_) => { if let Ok(mut book) = callbacks().lock() { book.remove(&token); } return Err("virtual_display_driver_unavailable"); }
        };
        if unsafe { SwDeviceSetLifetime(HSWDEVICE(device.0 as _), SWDeviceLifetimeHandle) }.is_err() {
            if let Ok(mut book) = callbacks().lock() { book.remove(&token); }
            return Err("virtual_display_driver_unavailable");
        }
        let instance = receiver.recv_timeout(Duration::from_secs(3)).ok().and_then(Result::ok);
        if let Ok(mut book) = callbacks().lock() { book.remove(&token); }
        let instance = instance.ok_or("display_creation_unconfirmed")?;
        let deadline = Instant::now() + Duration::from_secs(3);
        let link = loop {
            match interfaces(&instance) {
                Ok(link) => break link,
                Err(error) if Instant::now() >= deadline => return Err(error),
                Err(_) => std::thread::sleep(Duration::from_millis(25)),
            }
        };
        let file = File(unsafe { CreateFileW(PCWSTR(link.as_ptr()), (GENERIC_READ | GENERIC_WRITE).0,
            windows::Win32::Storage::FileSystem::FILE_SHARE_MODE(0), None, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, None) }
            .map_err(|_| "virtual_display_driver_unavailable")?.0 as usize);
        let container = GUID::from_u128(u128::from_str_radix(&nonce, 16).map_err(|_| "worker_failed")?);
        let mut result = Self { device: Some(device), file: Some(file), instance, plugged: false, container };
        let handle = result.file.as_ref().ok_or("virtual_display_driver_unavailable")?.handle();
        let mut query = protocol::Query::default();
        let mut returned = 0;
        loop {
            unsafe { DeviceIoControl(handle, protocol::QUERY, None, 0, Some((&mut query as *mut protocol::Query).cast()),
                std::mem::size_of::<protocol::Query>() as u32, Some(&mut returned), None) }
                .map_err(|_| "virtual_display_driver_incompatible")?;
            if returned != std::mem::size_of::<protocol::Query>() as u32 { return Err("virtual_display_driver_incompatible"); }
            if query.compatible() { break; }
            if query.protocol != protocol::PROTOCOL || query.magic != protocol::MAGIC || Instant::now() >= deadline {
                return Err("virtual_display_driver_not_ready");
            }
            std::thread::sleep(Duration::from_millis(25));
        }
        if !plug { return Ok(result); }
        let input = PlugIn { protocol: protocol::PROTOCOL, connector: 0, container };
        unsafe { DeviceIoControl(handle, PLUG_IN,
            Some((&input as *const PlugIn).cast()), std::mem::size_of::<PlugIn>() as _, None, 0, None, None) }
            .map_err(|_| "display_creation_unconfirmed")?;
        result.plugged = true;
        Ok(result)
    }
    pub(super) fn online(&self) -> bool { self.plugged && self.device.is_some() && interfaces(&self.instance).is_ok()
        && monitor_present(&self.container) == Ok(true) }
    pub(super) fn remove(&mut self) -> Result<(), &'static str> {
        if self.plugged {
            if let Some(file) = &self.file {
                let index = protocol::PlugOut { protocol: protocol::PROTOCOL, connector: 0 };
                unsafe { DeviceIoControl(file.handle(), PLUG_OUT, Some((&index as *const protocol::PlugOut).cast()),
                    std::mem::size_of::<protocol::PlugOut>() as u32, None, 0, None, None) }.map_err(|_| "cleanup_pending")?;
            }
            self.plugged = false;
        }
        self.file.take();
        self.device.take();
        if interfaces(&self.instance).is_ok() || monitor_present(&self.container) != Ok(false) { Err("cleanup_pending") } else { Ok(()) }
    }
}
impl Drop for Screen { fn drop(&mut self) { let _ = self.remove(); } }
