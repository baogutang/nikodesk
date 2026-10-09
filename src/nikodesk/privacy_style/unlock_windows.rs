//! Local-only password entry. Capture affinity covers the prompt as well as
//! the wallpaper; credentials never enter the helper pipes or session messages.
use hbb_common::{anyhow::anyhow, ResultType};
use std::{
    ptr::{null, null_mut},
    sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering},
    time::{Duration, Instant},
};
use winapi::{
    shared::{minwindef::*, windef::*},
    um::{
        handleapi::CloseHandle,
        libloaderapi::GetModuleHandleW,
        processthreadsapi::{GetCurrentProcessId, ProcessIdToSessionId},
        winbase::{LogonUserW, LOGON32_LOGON_NETWORK, LOGON32_PROVIDER_DEFAULT},
        wingdi::{GetStockObject, DEFAULT_GUI_FONT},
        winuser::*,
    },
};
#[link(name = "Wtsapi32")]
extern "system" {
    fn WTSQuerySessionInformationW(
        server: winapi::um::winnt::HANDLE,
        session: DWORD,
        kind: u32,
        text: *mut *mut u16,
        length: *mut DWORD,
    ) -> BOOL;
    fn WTSFreeMemory(memory: *mut std::ffi::c_void);
}
#[link(name = "kernel32")]
extern "system" {
    fn GetUserDefaultUILanguage() -> u16;
}
pub(crate) fn text(zh: &'static str, en: &'static str) -> &'static str {
    if unsafe { GetUserDefaultUILanguage() & 0x03ff } == 0x04 {
        zh
    } else {
        en
    }
}

const SUBMIT: usize = 101;
const CANCEL: usize = 102;
const PASSWORD: i32 = 103;
const FEEDBACK: i32 = 104;
static PROMPT: AtomicUsize = AtomicUsize::new(0);
static VERIFYING: AtomicBool = AtomicBool::new(false);
static RESULT: AtomicU64 = AtomicU64::new(0);
static GENERATION: AtomicU64 = AtomicU64::new(0);
static RETRY: std::sync::Mutex<Option<Instant>> = std::sync::Mutex::new(None);
fn wide(value: &str) -> Vec<u16> {
    value.encode_utf16().chain(Some(0)).collect()
}
fn clear_password(password: &mut [u16]) {
    for unit in password.iter_mut() {
        unsafe {
            std::ptr::write_volatile(unit, 0);
        }
    }
    std::sync::atomic::compiler_fence(Ordering::SeqCst);
}
pub(crate) fn close() {
    GENERATION.fetch_add(1, Ordering::AcqRel);
    let hwnd = PROMPT.swap(0, Ordering::AcqRel) as HWND;
    if !hwnd.is_null() {
        unsafe {
            SetWindowTextW(GetDlgItem(hwnd, PASSWORD), wide("").as_ptr());
            DestroyWindow(hwnd);
        }
    }
    RESULT.store(0, Ordering::Release);
}
pub(crate) unsafe fn allows_keyboard() -> bool {
    let hwnd = PROMPT.load(Ordering::Acquire) as HWND;
    !hwnd.is_null() && GetForegroundWindow() == hwnd
}
pub(crate) unsafe fn allows_mouse(point: POINT) -> bool {
    let hwnd = PROMPT.load(Ordering::Acquire) as HWND;
    let mut rect: RECT = std::mem::zeroed();
    !hwnd.is_null() && GetWindowRect(hwnd, &mut rect) != 0 && PtInRect(&rect, point) != 0
}
unsafe fn session_value(session: DWORD, kind: u32) -> Option<Vec<u16>> {
    let mut text = null_mut();
    let mut length = 0;
    if WTSQuerySessionInformationW(null_mut(), session, kind, &mut text, &mut length) == 0 {
        return None;
    }
    let value = if !text.is_null() && length >= 2 && length <= 2048 {
        let units = std::slice::from_raw_parts(text, (length / 2) as usize);
        let end = units.iter().position(|v| *v == 0).unwrap_or(units.len());
        let mut value = units[..end].to_vec();
        value.push(0);
        Some(value)
    } else {
        None
    };
    WTSFreeMemory(text.cast());
    value
}
fn verify_password(password: &[u16]) -> bool {
    unsafe {
        let mut session = 0;
        if ProcessIdToSessionId(GetCurrentProcessId(), &mut session) == 0 {
            return false;
        }
        let Some(user) = session_value(session, 5) else {
            return false;
        }; // WTSUserName
        let Some(domain) = session_value(session, 7) else {
            return false;
        }; // WTSDomainName
        if user.len() < 2 {
            return false;
        }
        let mut token = null_mut();
        let accepted = LogonUserW(
            user.as_ptr(),
            domain.as_ptr(),
            password.as_ptr(),
            LOGON32_LOGON_NETWORK,
            LOGON32_PROVIDER_DEFAULT,
            &mut token,
        ) != 0;
        if !token.is_null() {
            CloseHandle(token);
        }
        accepted
    }
}
unsafe fn submit(hwnd: HWND) {
    if VERIFYING.load(Ordering::Acquire) {
        return;
    }
    if RETRY
        .lock()
        .ok()
        .is_some_and(|retry| retry.is_some_and(|until| Instant::now() < until))
    {
        SetWindowTextW(
            GetDlgItem(hwnd, FEEDBACK),
            wide(text("请稍后再试。", "Wait before retrying.")).as_ptr(),
        );
        return;
    }
    let edit = GetDlgItem(hwnd, PASSWORD);
    let length = GetWindowTextLengthW(edit);
    if length <= 0 || length > 512 {
        SetWindowTextW(
            GetDlgItem(hwnd, FEEDBACK),
            wide(text(
                "请输入系统登录密码。",
                "Enter the system login password.",
            ))
            .as_ptr(),
        );
        return;
    }
    let mut password = vec![0u16; length as usize + 1];
    let copied = GetWindowTextW(edit, password.as_mut_ptr(), password.len() as i32);
    SetWindowTextW(edit, wide("").as_ptr());
    if copied != length {
        clear_password(&mut password);
        return;
    }
    VERIFYING.store(true, Ordering::Release);
    EnableWindow(edit, 0);
    EnableWindow(GetDlgItem(hwnd, SUBMIT as i32), 0);
    SetWindowTextW(
        GetDlgItem(hwnd, FEEDBACK),
        wide(text("正在验证…", "Verifying…")).as_ptr(),
    );
    let generation = GENERATION.load(Ordering::Acquire);
    std::thread::spawn(move || {
        let accepted = verify_password(&password);
        clear_password(&mut password);
        RESULT.store(
            (generation << 2) | if accepted { 1 } else { 2 },
            Ordering::Release,
        );
        VERIFYING.store(false, Ordering::Release);
    });
}
unsafe extern "system" fn dialog(hwnd: HWND, event: UINT, w: WPARAM, l: LPARAM) -> LRESULT {
    match event {
        WM_COMMAND => {
            match w & 0xffff {
                SUBMIT => submit(hwnd),
                CANCEL => close(),
                _ => {}
            };
            0
        }
        WM_CLOSE => {
            close();
            0
        }
        _ => DefWindowProcW(hwnd, event, w, l),
    }
}
pub(crate) fn show() -> ResultType<()> {
    unsafe {
        let existing = PROMPT.load(Ordering::Acquire) as HWND;
        if !existing.is_null() {
            SetForegroundWindow(existing);
            SetFocus(GetDlgItem(existing, PASSWORD));
            return Ok(());
        }
        if VERIFYING.load(Ordering::Acquire) {
            return Ok(());
        }
        let instance = GetModuleHandleW(null());
        let class = wide("NikoDeskLocalPrivacyUnlock");
        let definition = WNDCLASSW {
            style: 0,
            lpfnWndProc: Some(dialog),
            cbClsExtra: 0,
            cbWndExtra: 0,
            hInstance: instance,
            hIcon: null_mut(),
            hCursor: LoadCursorW(null_mut(), IDC_ARROW),
            hbrBackground: (COLOR_WINDOW + 1) as _,
            lpszMenuName: null(),
            lpszClassName: class.as_ptr(),
        };
        if RegisterClassW(&definition) == 0 && winapi::um::errhandlingapi::GetLastError() != 1410 {
            return Err(anyhow!("local_password_window_unavailable"));
        }
        let screen = GetSystemMetrics(SM_CXSCREEN);
        let height = GetSystemMetrics(SM_CYSCREEN);
        let hwnd = CreateWindowExW(
            WS_EX_TOPMOST | WS_EX_TOOLWINDOW,
            class.as_ptr(),
            wide(text("退出隐私屏", "Exit privacy screen")).as_ptr(),
            WS_POPUP | WS_CAPTION,
            (screen - 480) / 2,
            (height - 260) / 2,
            480,
            260,
            null_mut(),
            null_mut(),
            instance,
            null_mut(),
        );
        if hwnd.is_null() {
            return Err(anyhow!("local_password_window_unavailable"));
        }
        let mut affinity = 0;
        if SetWindowDisplayAffinity(hwnd, 0x11) == 0
            || GetWindowDisplayAffinity(hwnd, &mut affinity) == 0
            || affinity != 0x11
        {
            DestroyWindow(hwnd);
            return Err(anyhow!("local_password_capture_exclusion_unavailable"));
        }
        GENERATION.fetch_add(1, Ordering::AcqRel);
        RESULT.store(0, Ordering::Release);
        PROMPT.store(hwnd as usize, Ordering::Release);
        let font = GetStockObject(DEFAULT_GUI_FONT as i32);
        let controls = [
            (
                "STATIC",
                text(
                    "请输入当前 Windows 账户的系统登录密码（不是 PIN）。",
                    "Enter this Windows account's login password, not its PIN.",
                ),
                0,
                20,
                16,
                440,
                34,
                0,
            ),
            (
                "EDIT",
                "",
                WS_BORDER | ES_PASSWORD | ES_AUTOHSCROLL | WS_TABSTOP,
                20,
                64,
                440,
                30,
                PASSWORD,
            ),
            ("STATIC", "", 0, 20, 106, 440, 38, FEEDBACK),
            (
                "BUTTON",
                text("保持隐私屏", "Keep privacy on"),
                WS_TABSTOP,
                148,
                164,
                144,
                32,
                CANCEL as i32,
            ),
            (
                "BUTTON",
                text("验证并退出", "Verify and exit"),
                WS_TABSTOP | BS_DEFPUSHBUTTON,
                306,
                164,
                154,
                32,
                SUBMIT as i32,
            ),
        ];
        for (kind, text, style, x, y, width, height, id) in controls {
            let control = CreateWindowExW(
                0,
                wide(kind).as_ptr(),
                wide(text).as_ptr(),
                WS_CHILD | WS_VISIBLE | style,
                x,
                y,
                width,
                height,
                hwnd,
                id as _,
                instance,
                null_mut(),
            );
            if control.is_null() {
                close();
                return Err(anyhow!("local_password_window_unavailable"));
            }
            SendMessageW(control, WM_SETFONT, font as WPARAM, 1);
        }
        SendMessageW(GetDlgItem(hwnd, PASSWORD), EM_SETLIMITTEXT as UINT, 512, 0);
        ShowWindow(hwnd, SW_SHOW);
        SetForegroundWindow(hwnd);
        SetFocus(GetDlgItem(hwnd, PASSWORD));
    }
    Ok(())
}
pub(crate) fn tick() -> bool {
    let result = RESULT.swap(0, Ordering::AcqRel);
    if result >> 2 != GENERATION.load(Ordering::Acquire) {
        return false;
    }
    match result & 3 {
        1 => true,
        2 => {
            VERIFYING.store(false, Ordering::Release);
            if let Ok(mut retry) = RETRY.lock() {
                *retry = Some(Instant::now() + Duration::from_secs(3));
            }
            unsafe {
                let hwnd = PROMPT.load(Ordering::Acquire) as HWND;
                if !hwnd.is_null() {
                    EnableWindow(GetDlgItem(hwnd, PASSWORD), 1);
                    EnableWindow(GetDlgItem(hwnd, SUBMIT as i32), 1);
                    SetWindowTextW(
                        GetDlgItem(hwnd, FEEDBACK),
                        wide(text(
                            "密码未通过验证，请重试。",
                            "Password verification failed. Retry.",
                        ))
                        .as_ptr(),
                    );
                    SetFocus(GetDlgItem(hwnd, PASSWORD));
                }
            }
            false
        }
        _ => false,
    }
}
pub(crate) unsafe fn raise() {
    let hwnd = PROMPT.load(Ordering::Acquire) as HWND;
    if !hwnd.is_null() {
        SetWindowPos(
            hwnd,
            HWND_TOPMOST,
            0,
            0,
            0,
            0,
            SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE,
        );
    }
}
pub(crate) unsafe fn dispatch_key(message: &MSG) -> bool {
    let hwnd = PROMPT.load(Ordering::Acquire) as HWND;
    if hwnd.is_null() {
        return false;
    }
    if message.message == WM_KEYDOWN && message.wParam == VK_ESCAPE as WPARAM {
        close();
        return true;
    }
    if message.message == WM_KEYDOWN && message.wParam == VK_RETURN as WPARAM {
        submit(hwnd);
        return true;
    }
    IsDialogMessageW(hwnd, message as *const _ as *mut _) != 0
}
