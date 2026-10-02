//! Installs and checks the signed Amyuni driver bundled next to the executable.
use super::{Reply, Request};
use std::{
    os::windows::ffi::OsStrExt,
    path::Path,
    sync::{Mutex, OnceLock},
    thread::JoinHandle,
};
use windows::{
    core::{w, PCWSTR},
    Win32::{
        Foundation::HWND,
        System::Threading::GetCurrentProcessId,
        UI::WindowsAndMessaging::{
            GetForegroundWindow, GetWindowThreadProcessId, IsWindowVisible, MessageBoxW, IDYES,
            MB_DEFBUTTON2, MB_ICONWARNING, MB_YESNO,
        },
    },
};
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
fn scope(namespace: &str) -> bool {
    crate::nikodesk::server_scope::current().is_some_and(|current| current.namespace() == namespace)
}
fn os_supported() -> bool {
    base::platform::windows::is_windows_version_or_greater(10, 0, 19041, 0, 0)
}
fn elevated() -> bool {
    crate::platform::windows::is_elevated(None).unwrap_or(false)
}
// Upstream's installer reads the same directory beside the running executable.
fn bundled() -> bool {
    std::env::current_exe().ok().is_some_and(|exe| {
        exe.parent()
            .is_some_and(|folder| folder.join("usbmmidd_v2").join("usbmmIdd.inf").is_file())
    })
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
        .spawn(move || match run(&id, &request) {
            Ok(()) => update(&id, "ready", "", true),
            Err(error) => update(&id, "failed", error, false),
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
    let install = request.action == "install";
    if install && !bundled() {
        return Err("signed_package_missing");
    }
    if !scope(&request.namespace) {
        return Err("scope_changed");
    }
    update(id, "awaiting_confirmation", "", false);
    let hwnd = foreground()?;
    let body = if install {
        "将安装随 NikoDesk 提供的 Amyuni 已签名虚拟屏驱动（USB Mobile Monitor Virtual Display），然后短暂接入一块虚拟屏确认可用。屏幕可能闪烁。该驱动为全机共享，RustDesk 也使用它。是否继续？"
    } else {
        "将短暂接入一块虚拟屏确认驱动可用，随后移除。屏幕可能闪烁；驱动缺失时会先安装随 NikoDesk 提供的已签名驱动。是否继续？"
    };
    let text = wide(Path::new(body));
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
    // Plugging the first monitor installs the driver when it is missing, so the
    // install and the check share one path and one result.
    update(id, if install { "installing" } else { "probing" }, "", false);
    crate::nikodesk::virtual_display::probe_driver()
}
