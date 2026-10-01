use super::{Reply, Request};
use std::{
    fs::{File, OpenOptions},
    io::{Read, Seek, SeekFrom},
    os::windows::{
        fs::{MetadataExt, OpenOptionsExt},
        io::AsRawHandle,
    },
    path::{Path, PathBuf},
    sync::{Mutex, OnceLock},
    thread::JoinHandle,
};
use windows::{
    core::{w, BOOL, PCWSTR},
    Win32::{
        Devices::DeviceAndDriverInstallation::{DiInstallDriverW, DIINSTALLDRIVER_FLAGS},
        Foundation::{HANDLE, HWND},
        Security::{
            Cryptography::Catalog::{
                CryptCATAdminAcquireContext2, CryptCATAdminCalcHashFromFileHandle2,
                CryptCATAdminReleaseContext,
            },
            WinTrust::*,
        },
        Storage::FileSystem::{
            FILE_FLAG_BACKUP_SEMANTICS, FILE_FLAG_OPEN_REPARSE_POINT, FILE_READ_ATTRIBUTES,
            FILE_SHARE_READ, FILE_SHARE_WRITE,
        },
        System::Threading::GetCurrentProcessId,
        UI::WindowsAndMessaging::{
            GetForegroundWindow, GetWindowThreadProcessId, IsWindowVisible, MessageBoxW, IDYES,
            MB_DEFBUTTON2, MB_ICONWARNING, MB_YESNO,
        },
    },
};
const INF: &[u8] = include_bytes!("../../../libs/nikodesk_idd/NikoDeskIddDriver.inf");
type Result<T> = std::result::Result<T, &'static str>;
struct Job {
    reply: Reply,
    task: Option<JoinHandle<()>>,
}
static JOB: OnceLock<Mutex<Option<Job>>> = OnceLock::new();
fn job() -> &'static Mutex<Option<Job>> {
    JOB.get_or_init(Mutex::default)
}
fn wide(path: &Path) -> Vec<u16> {
    path.as_os_str().encode_wide().chain(Some(0)).collect()
}
use std::os::windows::ffi::OsStrExt;
fn scope(namespace: &str) -> bool {
    crate::nikodesk::server_scope::current().is_some_and(|current| current.namespace() == namespace)
}
fn os_supported() -> bool {
    base::platform::windows::is_windows_version_or_greater(10, 0, 19041, 0, 0)
}
fn elevated() -> bool {
    crate::platform::windows::is_elevated(None).unwrap_or(false)
}
fn foreground() -> Result<HWND> {
    if crate::nikodesk::background::is_system_worker() {
        return Err("local_ui_required");
    }
    let hwnd = unsafe { GetForegroundWindow() };
    let mut pid = 0;
    unsafe {
        GetWindowThreadProcessId(hwnd, Some(&mut pid));
    }
    if hwnd.0.is_null()
        || pid != unsafe { GetCurrentProcessId() }
        || !unsafe { IsWindowVisible(hwnd) }.as_bool()
    {
        return Err("local_ui_required");
    }
    Ok(hwnd)
}
fn update(id: &str, phase: &str, reason: &str, ok: bool) {
    if let Ok(mut current) = job().lock() {
        if let Some(current) = current.as_mut().filter(|value| value.reply.job_id == id) {
            current.reply.phase = phase.into();
            current.reply.reason = reason.into();
            current.reply.ok = ok;
        }
    }
}
pub(super) fn command(request: Request) -> Reply {
    let mut empty = Reply::empty(&request.namespace, "unchecked");
    empty.os_supported = os_supported();
    empty.elevated = elevated();
    if !scope(&request.namespace) {
        empty.reason = "scope_changed".into();
        return empty;
    }
    let Ok(mut guard) = job().lock() else {
        empty.reason = "unconfirmed".into();
        return empty;
    };
    if let Some(current) = guard.as_mut() {
        if current.task.as_ref().is_some_and(JoinHandle::is_finished) {
            if let Some(task) = current.task.take() {
                current.reply.joined = task.join().is_ok();
                if !current.reply.joined {
                    current.reply.ok = false;
                    current.reply.phase = "failed".into();
                    current.reply.reason = "unconfirmed".into();
                }
            }
        }
        if current.reply.namespace != request.namespace && request.action == "status" {
            if current.task.is_some() {
                empty.reason = "another_scope_busy".into();
            }
            return empty;
        }
        if request.action == "status" || current.task.is_some() {
            return current.reply.clone();
        }
    }
    if request.action == "status" {
        return empty;
    }
    if !empty.os_supported {
        empty.reason = "os_unsupported".into();
        return empty;
    }
    if !empty.elevated {
        empty.reason = "administrator_required".into();
        return empty;
    }
    if foreground().is_err() {
        empty.reason = "local_ui_required".into();
        return empty;
    }
    if crate::nikodesk::virtual_display::has_screens() {
        empty.reason = "active_displays".into();
        return empty;
    }
    let id = hbb_common::uuid::Uuid::new_v4().to_string();
    empty.job_id = id.clone();
    empty.phase = "checking".into();
    empty.reason = "".into();
    *guard = Some(Job {
        reply: empty.clone(),
        task: None,
    });
    let task = std::thread::Builder::new()
        .name("niko-local-display-driver".into())
        .spawn(move || {
            let result = run(&id, &request);
            match result {
                Ok(()) => update(&id, "ready", "", true),
                Err("restart_required") => {
                    update(&id, "restart_required", "restart_required", false)
                }
                Err(error) => update(&id, "failed", error, false),
            }
        });
    match task {
        Ok(task) => {
            if let Some(value) = guard.as_mut() {
                value.task = Some(task);
            }
        }
        Err(_) => {
            if let Some(value) = guard.as_mut() {
                value.reply.phase = "failed".into();
                value.reply.reason = "unconfirmed".into();
                value.reply.joined = true;
            }
        }
    }
    guard
        .as_ref()
        .map(|value| value.reply.clone())
        .unwrap_or(empty)
}

fn run(id: &str, request: &Request) -> Result<()> {
    // Package pins survive the native confirmation and installation. Selecting
    // a package grants no trust; the catalog covers both the exact INF and DLL.
    let package = if request.action == "install" {
        Some(Package::open(Path::new(&request.inf_path))?)
    } else {
        None
    };
    if !scope(&request.namespace) {
        return Err("scope_changed");
    }
    update(id, "awaiting_confirmation", "", false);
    let hwnd = foreground()?;
    let body = if let Some(package) = &package {
        format!("将安装／修复 NikoDesk 独立虚拟屏驱动。Windows 会写入驱动存储并验证系统加载策略。可能暂时中断 NikoDesk 虚拟屏；不会移除 RustDesk 或其他厂商的驱动。\r\n\r\n已核验签名目录覆盖 INF 和 DLL。\r\n路径：{}\r\n\r\n是否继续？", package.inf.display())
    } else {
        "将临时创建一个 NikoDesk 独立适配器，核验驱动协议及就绪状态后移除。不创建屏幕、不安装驱动。是否继续？".into()
    };
    let text = wide(Path::new(&body));
    if unsafe {
        MessageBoxW(
            Some(hwnd),
            PCWSTR(text.as_ptr()),
            w!("NikoDesk — 虚拟屏驱动"),
            MB_YESNO | MB_DEFBUTTON2 | MB_ICONWARNING,
        )
    } != IDYES
    {
        return Err("declined");
    }
    foreground()?;
    if !scope(&request.namespace) {
        return Err("scope_changed");
    }
    if crate::nikodesk::virtual_display::has_screens() {
        return Err("active_displays");
    }
    let _maintenance = crate::nikodesk::virtual_display::begin_driver_maintenance()?;
    if let Some(package) = &package {
        update(id, "installing", "", false);
        let mut reboot = BOOL(0);
        // No FORCE_INF, global uninstall, arbitrary executable, certificate import,
        // automatic elevation, or test-signing change. The exact INF has only our ID.
        unsafe {
            DiInstallDriverW(
                Some(hwnd),
                PCWSTR(wide(&package.inf).as_ptr()),
                DIINSTALLDRIVER_FLAGS(0),
                Some(&mut reboot),
            )
        }
        .map_err(|_| "installation_unconfirmed")?;
        if reboot.as_bool() {
            return Err("restart_required");
        }
    }
    update(id, "probing", "", false);
    crate::nikodesk::virtual_display::probe_driver()
}

struct Package {
    inf: PathBuf,
    _parents: Vec<File>,
    _files: Vec<File>,
}
fn bounded(file: &mut File, limit: u64) -> Result<Vec<u8>> {
    if file.metadata().map_err(|_| "package_unreadable")?.len() > limit {
        return Err("package_invalid");
    }
    file.seek(SeekFrom::Start(0))
        .map_err(|_| "package_unreadable")?;
    let mut bytes = Vec::new();
    file.take(limit + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| "package_unreadable")?;
    if bytes.len() as u64 > limit {
        return Err("package_invalid");
    }
    Ok(bytes)
}
impl Package {
    fn open(inf: &Path) -> Result<Self> {
        let root = inf.parent().ok_or("package_invalid")?;
        let mut parents = Vec::new();
        for path in root.ancestors() {
            let file = OpenOptions::new()
                .access_mode(FILE_READ_ATTRIBUTES.0)
                .share_mode((FILE_SHARE_READ | FILE_SHARE_WRITE).0)
                .custom_flags((FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT).0)
                .open(path)
                .map_err(|_| "package_unreadable")?;
            if file
                .metadata()
                .map_err(|_| "package_unreadable")?
                .file_attributes()
                & 0x400
                != 0
            {
                return Err("package_alias_rejected");
            }
            parents.push(file);
        }
        let mut files = Vec::new();
        for name in [
            "NikoDeskIddDriver.inf",
            "NikoDeskIddDriver.dll",
            "NikoDeskIddDriver.cat",
        ] {
            let file = OpenOptions::new()
                .read(true)
                .share_mode(FILE_SHARE_READ.0)
                .custom_flags(FILE_FLAG_OPEN_REPARSE_POINT.0)
                .open(root.join(name))
                .map_err(|_| "signed_package_missing")?;
            let meta = file.metadata().map_err(|_| "package_unreadable")?;
            if !meta.is_file() || meta.file_attributes() & 0x400 != 0 {
                return Err("package_alias_rejected");
            }
            files.push(file);
        }
        if bounded(&mut files[0], 65536)? != INF {
            return Err("foreign_or_changed_inf");
        }
        let dll = bounded(&mut files[1], 64 * 1024 * 1024)?;
        if dll.get(..2) != Some(b"MZ") {
            return Err("package_architecture");
        }
        let offset = dll
            .get(0x3c..0x40)
            .and_then(|bytes| bytes.try_into().ok())
            .map(u32::from_le_bytes)
            .ok_or("package_architecture")? as usize;
        if dll.get(offset..offset.saturating_add(6)) != Some(&[b'P', b'E', 0, 0, 0x64, 0x86][..]) {
            return Err("package_architecture");
        }
        bounded(&mut files[2], 16 * 1024 * 1024)?;
        let cat = root.join("NikoDeskIddDriver.cat");
        for (file, name) in files
            .iter()
            .zip(["NikoDeskIddDriver.inf", "NikoDeskIddDriver.dll"])
        {
            catalog_member(file, &root.join(name), &cat)?;
        }
        Ok(Self {
            inf: inf.into(),
            _parents: parents,
            _files: files,
        })
    }
}
struct CatalogAdmin(isize);
impl Drop for CatalogAdmin {
    fn drop(&mut self) {
        unsafe {
            let _ = CryptCATAdminReleaseContext(self.0, 0);
        }
    }
}
fn catalog_member(file: &File, path: &Path, catalog: &Path) -> Result<()> {
    let mut admin = 0;
    unsafe { CryptCATAdminAcquireContext2(&mut admin, None, w!("SHA256"), None, None) }
        .map_err(|_| "catalog_trust_unconfirmed")?;
    let admin = CatalogAdmin(admin);
    let mut size = 0;
    let handle = HANDLE(file.as_raw_handle());
    let mut read = file;
    read.seek(SeekFrom::Start(0))
        .map_err(|_| "catalog_trust_unconfirmed")?;
    unsafe { CryptCATAdminCalcHashFromFileHandle2(admin.0, handle, &mut size, None, None) }
        .map_err(|_| "catalog_trust_unconfirmed")?;
    if size != 32 {
        return Err("catalog_trust_unconfirmed");
    }
    let mut hash = vec![0; size as usize];
    read.seek(SeekFrom::Start(0))
        .map_err(|_| "catalog_trust_unconfirmed")?;
    unsafe {
        CryptCATAdminCalcHashFromFileHandle2(
            admin.0,
            handle,
            &mut size,
            Some(hash.as_mut_ptr()),
            None,
        )
    }
    .map_err(|_| "catalog_trust_unconfirmed")?;
    let tag = hash
        .iter()
        .map(|value| format!("{value:02X}"))
        .collect::<String>();
    let (tag, member, cat) = (wide(Path::new(&tag)), wide(path), wide(catalog));
    let mut info = WINTRUST_CATALOG_INFO {
        cbStruct: std::mem::size_of::<WINTRUST_CATALOG_INFO>() as u32,
        pcwszCatalogFilePath: PCWSTR(cat.as_ptr()),
        pcwszMemberTag: PCWSTR(tag.as_ptr()),
        pcwszMemberFilePath: PCWSTR(member.as_ptr()),
        hMemberFile: handle,
        pbCalculatedFileHash: hash.as_mut_ptr(),
        cbCalculatedFileHash: size,
        hCatAdmin: admin.0,
        ..Default::default()
    };
    let mut data = WINTRUST_DATA {
        cbStruct: std::mem::size_of::<WINTRUST_DATA>() as u32,
        dwUIChoice: WTD_UI_NONE,
        fdwRevocationChecks: WTD_REVOKE_WHOLECHAIN,
        dwUnionChoice: WTD_CHOICE_CATALOG,
        Anonymous: WINTRUST_DATA_0 {
            pCatalog: &mut info,
        },
        dwStateAction: WTD_STATEACTION_VERIFY,
        dwProvFlags: WTD_CACHE_ONLY_URL_RETRIEVAL | WTD_REVOCATION_CHECK_CHAIN_EXCLUDE_ROOT,
        ..Default::default()
    };
    let mut action = WINTRUST_ACTION_GENERIC_VERIFY_V2;
    let status = unsafe {
        WinVerifyTrust(
            HWND::default(),
            &mut action,
            (&mut data as *mut WINTRUST_DATA).cast(),
        )
    };
    let non_test = unsafe {
        let provider = WTHelperProvDataFromStateData(data.hWVTStateData);
        if provider.is_null() {
            false
        } else {
            let signer = WTHelperGetProvSignerFromChain(provider, 0, false, 0);
            if signer.is_null() {
                false
            } else {
                let cert = WTHelperGetProvCertFromChain(signer, 0);
                !cert.is_null() && !(*cert).fTestCert.as_bool() && !(*cert).fSelfSigned.as_bool()
            }
        }
    };
    data.dwStateAction = WTD_STATEACTION_CLOSE;
    let closed = unsafe {
        WinVerifyTrust(
            HWND::default(),
            &mut action,
            (&mut data as *mut WINTRUST_DATA).cast(),
        )
    };
    if status != 0 || closed != 0 || !non_test {
        return Err("catalog_trust_unconfirmed");
    }
    Ok(())
}
