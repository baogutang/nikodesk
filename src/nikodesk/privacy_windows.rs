//! Interactive-desktop privacy screen. The child runs before configuration, IPC,
//! rendezvous or Flutter initialization and owns only its windows and hooks.
//! It restores the local desktop on pipe loss, expired heartbeat, local Esc,
//! monitor changes or a switch away from the interactive Default desktop.
use crate::privacy_mode::{PrivacyMode, PrivacyModeState};
use hbb_common::{anyhow::anyhow, bail, ResultType};
use std::{
    io::{Read, Write},
    process::{Child, Command, Stdio},
    ptr::{null, null_mut},
    sync::{
        atomic::{AtomicBool, AtomicU32, Ordering},
        mpsc::{self, SyncSender},
        Arc, Mutex,
    },
    time::{Duration, Instant},
};
use winapi::{
    shared::{minwindef::*, windef::*},
    um::{
        fileapi::GetFileType,
        libloaderapi::GetModuleHandleW,
        processenv::GetStdHandle,
        processthreadsapi::{GetCurrentProcess, GetCurrentProcessId, GetCurrentThreadId, OpenProcessToken, ProcessIdToSessionId},
        handleapi::CloseHandle,
        securitybaseapi::GetTokenInformation,
        winnt::{TokenUser, TOKEN_QUERY, TOKEN_USER},
        winbase::WTSGetActiveConsoleSessionId,
        winbase::{STD_INPUT_HANDLE, STD_OUTPUT_HANDLE},
        wingdi::{GetStockObject, SetBkMode, SetTextColor, BLACK_BRUSH, TRANSPARENT},
        winuser::*,
    },
};

pub const IMPL: &str = crate::privacy_mode::PRIVACY_MODE_IMPL_WIN_EXCLUDE_FROM_CAPTURE;
const ARG: &str = "--niko-privacy-screen";
const LEASE: Duration = Duration::from_secs(5);
const WDA_EXCLUDE: DWORD = 0x11;
const STOP: UINT = WM_APP + 0x351;
const UNLOCK: UINT = WM_APP + 0x352;
static WINDOW_THREAD: AtomicU32 = AtomicU32::new(0);

#[link(name = "dwmapi")]
extern "system" {
    fn DwmIsCompositionEnabled(enabled: *mut BOOL) -> i32;
}

fn wide(value: &str) -> Vec<u16> {
    value.encode_utf16().chain(Some(0)).collect()
}

pub fn supported() -> bool {
    let mut composing = 0;
    let system = system_token();
    let role = if system {
        crate::nikodesk::background::is_system_worker()
            && crate::nikodesk::background::worker_input_ready()
            && executable_is("nikodesk-host.exe") && active_console_session()
    } else { !crate::nikodesk::background::is_system_worker() && executable_is("NikoDesk.exe") };
    role && base::platform::windows::is_windows_version_or_greater(10, 0, 19041, 0, 0)
        && default_desktop()
        && unsafe { DwmIsCompositionEnabled(&mut composing) >= 0 && composing != 0 }
}

fn executable_is(name: &str) -> bool {
    std::env::current_exe().ok().and_then(|path| path.file_name().map(|n| n.to_owned()))
        .is_some_and(|actual| actual.to_string_lossy().eq_ignore_ascii_case(name))
}
fn system_token() -> bool {
    unsafe {
        let mut token = null_mut();
        if OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token) == 0 { return false; }
        let mut needed = 0;
        GetTokenInformation(token, TokenUser, null_mut(), 0, &mut needed);
        if needed < std::mem::size_of::<TOKEN_USER>() as u32 || needed > 4096 {
            CloseHandle(token); return false;
        }
        let mut buffer = vec![0_usize; (needed as usize + std::mem::size_of::<usize>() - 1) / std::mem::size_of::<usize>()];
        let valid = GetTokenInformation(token, TokenUser, buffer.as_mut_ptr().cast(), needed, &mut needed) != 0;
        let system = if valid {
            let sid = (*(buffer.as_ptr().cast::<TOKEN_USER>())).User.Sid;
            !sid.is_null() && winapi::um::securitybaseapi::IsWellKnownSid(sid, winapi::um::winnt::WinLocalSystemSid) != 0
        } else { false };
        CloseHandle(token);
        system
    }
}
fn active_console_session() -> bool {
    let mut session = 0;
    unsafe { ProcessIdToSessionId(GetCurrentProcessId(), &mut session) != 0
        && session != 0 && session != u32::MAX && session == WTSGetActiveConsoleSessionId() }
}
fn helper_supported() -> bool {
    // The child never selects the server/worker role or loads machine keys.
    // Only its inherited pipes and bounded lease control the cover. It cannot
    // darken Winlogon or UAC desktops.
    let role = if system_token() { executable_is("nikodesk-host.exe") && active_console_session() }
        else { executable_is("NikoDesk.exe") };
    let mut composing = 0;
    role && default_desktop() && base::platform::windows::is_windows_version_or_greater(10, 0, 19041, 0, 0)
        && unsafe { DwmIsCompositionEnabled(&mut composing) >= 0 && composing != 0 }
}

// Called only by the one authenticated desktop connection that owns the mode.
pub fn heartbeat(conn_id: i32, permitted: bool) -> bool {
    crate::privacy_mode::nikodesk_heartbeat(conn_id, permitted)
}

struct Screen {
    conn_id: i32,
    child: Child,
    heartbeat: SyncSender<Instant>,
    alive: Arc<AtomicBool>,
    last_ack: Arc<Mutex<Instant>>,
}

impl Screen {
    fn spawn(conn_id: i32) -> ResultType<Self> {
        if !supported() || !default_desktop() { bail!("Privacy screen requires the interactive Windows desktop (Windows 10 2004 or later)."); }
        let mut child = Command::new(std::env::current_exe()?)
            .arg(ARG).stdin(Stdio::piped()).stdout(Stdio::piped())
            .stderr(Stdio::null()).spawn()?;
        let Some(mut input) = child.stdin.take() else { let _ = child.kill(); bail!("Privacy screen control pipe is unavailable"); };
        let Some(mut output) = child.stdout.take() else { let _ = child.kill(); bail!("Privacy screen response pipe is unavailable"); };
        let (ready_tx, ready_rx) = mpsc::sync_channel(1);
        let (heartbeat, incoming) = mpsc::sync_channel::<Instant>(1);
        let alive = Arc::new(AtomicBool::new(false));
        let last_ack = Arc::new(Mutex::new(Instant::now()));
        let live = alive.clone();
        let ack = last_ack.clone();
        // Own the two inherited pipes in one thread. A blocked pipe never blocks
        // the remote connection; stale queued heartbeats are never replayed.
        std::thread::spawn(move || {
            let mut byte = [0; 1];
            let ready = input.write_all(b"NPS1").and_then(|_| output.read_exact(&mut byte)).is_ok()
                && byte == *b"R";
            live.store(ready, Ordering::Release);
            let _ = ready_tx.try_send(ready);
            if !ready { return; }
            while let Ok(issued) = incoming.recv() {
                if issued.elapsed() > Duration::from_secs(2)
                    || input.write_all(b"H").and_then(|_| output.read_exact(&mut byte)).is_err()
                    || byte != *b"A" { break; }
                if let Ok(mut current) = ack.lock() { *current = Instant::now(); }
            }
            live.store(false, Ordering::Release);
        });
        let mut screen = Self { conn_id, child, heartbeat, alive, last_ack };
        if ready_rx.recv_timeout(Duration::from_secs(4)) != Ok(true) {
            let _ = screen.stop();
            bail!("Privacy screen could not cover every monitor or block local input");
        }
        Ok(screen)
    }

    fn renew(&mut self, permitted: bool) -> bool {
        if !permitted || !self.alive.load(Ordering::Acquire)
            || self.last_ack.lock().map_or(true, |ack| ack.elapsed() > Duration::from_secs(3))
            || !matches!(self.child.try_wait(), Ok(None)) {
            let _ = self.stop();
            return false;
        }
        match self.heartbeat.try_send(Instant::now()) {
            Ok(()) | Err(mpsc::TrySendError::Full(_)) => true,
            Err(_) => { let _ = self.stop(); false },
        }
    }

    fn stop(&mut self) -> ResultType<()> {
        self.alive.store(false, Ordering::Release);
        if self.child.try_wait()?.is_some() { return Ok(()); }
        self.child.kill()?;
        let deadline = Instant::now() + Duration::from_secs(2);
        while Instant::now() < deadline {
            if self.child.try_wait()?.is_some() { return Ok(()); }
            std::thread::sleep(Duration::from_millis(10));
        }
        bail!("Privacy screen process termination has not been confirmed");
    }
}

impl Drop for Screen {
    fn drop(&mut self) { let _ = self.stop(); }
}

pub struct PrivacyModeImpl { screen: Option<Screen> }
impl PrivacyModeImpl { pub fn new(_: &str) -> Self { Self { screen: None } } }
impl PrivacyMode for PrivacyModeImpl {
    fn is_async_privacy_mode(&self) -> bool { false }
    fn init(&self) -> ResultType<()> { Ok(()) }
    fn clear(&mut self) { let _ = self.turn_off_privacy(0, None); }
    fn turn_on_privacy(&mut self, conn_id: i32) -> ResultType<bool> {
        if conn_id <= 0 { bail!("Privacy screen requires an authenticated connection"); }
        if self.check_on_conn_id(conn_id)? { return Ok(true); }
        self.turn_off_privacy(0, None)?;
        self.screen = Some(Screen::spawn(conn_id)?);
        Ok(true)
    }
    fn turn_off_privacy(&mut self, conn_id: i32, _: Option<PrivacyModeState>) -> ResultType<()> {
        // Retain the actual owner until process exit is confirmed, even when a
        // heartbeat has stopped reporting the screen as active.
        if let Some(screen) = self.screen.as_mut() {
            if conn_id != 0 && conn_id != screen.conn_id { bail!(crate::privacy_mode::TURN_OFF_OTHER_ID); }
            screen.stop()?;
        }
        self.screen = None;
        Ok(())
    }
    fn pre_conn_id(&self) -> i32 {
        self.screen.as_ref().filter(|s| s.alive.load(Ordering::Acquire)).map_or(0, |s| s.conn_id)
    }
    fn get_impl_key(&self) -> &str { IMPL }
    fn nikodesk_heartbeat(&mut self, conn_id: i32, permitted: bool) -> bool {
        let Some(screen) = self.screen.as_mut().filter(|s| s.conn_id == conn_id) else { return false; };
        if screen.renew(permitted) { return false; }
        // Notify this owner once; termination failure retains its cleanup owner.
        if screen.stop().is_ok() { self.screen = None; }
        true
    }
}
impl Drop for PrivacyModeImpl { fn drop(&mut self) { self.clear(); } }

fn default_desktop() -> bool {
    unsafe {
        let desktop = OpenInputDesktop(0, 0, DESKTOP_READOBJECTS);
        if desktop.is_null() { return false; }
        let mut name = [0_u16; 64];
        let mut needed = 0;
        let ok = GetUserObjectInformationW(desktop.cast(), UOI_NAME as i32, name.as_mut_ptr().cast(),
            std::mem::size_of_val(&name) as DWORD, &mut needed) != 0;
        CloseDesktop(desktop);
        ok && needed <= std::mem::size_of_val(&name) as DWORD
            && String::from_utf16(&name[..name.iter().position(|c| *c == 0).unwrap_or(name.len())])
                .is_ok_and(|name| name.eq_ignore_ascii_case("default"))
    }
}

unsafe extern "system" fn monitors(_: HMONITOR, _: HDC, rect: *mut RECT, data: LPARAM) -> BOOL {
    let output = &mut *(data as *mut Vec<RECT>);
    if rect.is_null() || output.len() >= 32 { return 0; }
    let rect = *rect;
    if rect.right <= rect.left || rect.bottom <= rect.top { return 0; }
    output.push(rect);
    1
}
fn monitor_rects() -> ResultType<Vec<RECT>> {
    let mut rects: Vec<RECT> = Vec::new();
    if unsafe { EnumDisplayMonitors(null_mut(), null(), Some(monitors), &mut rects as *mut _ as LPARAM) } == 0
        || rects.is_empty() { bail!("Cannot enumerate all privacy screen monitors"); }
    Ok(rects)
}
fn same_monitors(a: &[RECT], b: &[RECT]) -> bool {
    a.len() == b.len() && a.iter().zip(b).all(|(a,b)|
        (a.left,a.top,a.right,a.bottom) == (b.left,b.top,b.right,b.bottom))
}

unsafe extern "system" fn keyboard(code: i32, event: WPARAM, data: LPARAM) -> LRESULT {
    if code >= 0 && data != 0 {
        let input = &*(data as *const KBDLLHOOKSTRUCT);
        if input.flags & LLKHF_INJECTED != 0 && input.dwExtraInfo == enigo::ENIGO_INPUT_EXTRA_VALUE {
            return CallNextHookEx(null_mut(), code, event, data);
        }
        if input.flags & LLKHF_INJECTED == 0 && crate::nikodesk::privacy_style::unlock_windows::allows_keyboard(){
            return CallNextHookEx(null_mut(),code,event,data);
        }
        if input.flags & LLKHF_INJECTED == 0 && input.vkCode == VK_ESCAPE as DWORD
            && (event == WM_KEYDOWN as WPARAM || event == WM_SYSKEYDOWN as WPARAM) {
            PostThreadMessageW(WINDOW_THREAD.load(Ordering::Acquire), UNLOCK, 0, 0);
            return 1;
        }
        return 1;
    }
    CallNextHookEx(null_mut(), code, event, data)
}
unsafe extern "system" fn mouse(code: i32, event: WPARAM, data: LPARAM) -> LRESULT {
    if code >= 0 && data != 0 {
        let input = &*(data as *const MSLLHOOKSTRUCT);
        if input.flags & LLMHF_INJECTED == 0 && crate::nikodesk::privacy_style::unlock_windows::allows_mouse(input.pt){
            return CallNextHookEx(null_mut(),code,event,data);
        }
        if input.flags & LLMHF_INJECTED == 0 || input.dwExtraInfo != enigo::ENIGO_INPUT_EXTRA_VALUE { return 1; }
    }
    CallNextHookEx(null_mut(), code, event, data)
}
unsafe extern "system" fn window(hwnd: HWND, event: UINT, w: WPARAM, l: LPARAM) -> LRESULT {
    match event {
        WM_MOUSEACTIVATE => MA_NOACTIVATE as LRESULT,
        WM_PAINT => {
            let mut paint: PAINTSTRUCT = std::mem::zeroed();
            let dc = BeginPaint(hwnd, &mut paint);
            let mut rect: RECT = std::mem::zeroed();
            GetClientRect(hwnd, &mut rect);
            if crate::nikodesk::privacy_style::windows::paint(dc,&rect) {
                EndPaint(hwnd,&paint);return 0;
            }
            FillRect(dc, &rect, GetStockObject(BLACK_BRUSH as i32).cast());
            SetBkMode(dc, TRANSPARENT as i32);
            SetTextColor(dc, 0x00dddddd);
            crate::nikodesk::privacy_style::windows::paint_status(dc,&rect);
            EndPaint(hwnd, &paint);
            0
        }
        WM_DISPLAYCHANGE | WM_CLOSE | WM_ENDSESSION => { PostThreadMessageW(WINDOW_THREAD.load(Ordering::Acquire), STOP, 0, 0); 0 }
        _ => DefWindowProcW(hwnd, event, w, l),
    }
}

struct Windows { windows: Vec<HWND>, keyboard: HHOOK, mouse: HHOOK }
impl Drop for Windows {
    fn drop(&mut self) {
        crate::nikodesk::privacy_style::unlock_windows::close();
        unsafe {
            if !self.keyboard.is_null() { UnhookWindowsHookEx(self.keyboard); }
            if !self.mouse.is_null() { UnhookWindowsHookEx(self.mouse); }
            for hwnd in self.windows.drain(..) { DestroyWindow(hwnd); }
            WINDOW_THREAD.store(0, Ordering::Release);
        }
    }
}

fn cover(rects: &[RECT]) -> ResultType<Windows> {
    let mut result = Windows { windows: Vec::new(), keyboard: null_mut(), mouse: null_mut() };
    unsafe {
        let instance = GetModuleHandleW(null());
        let class = wide("NikoDeskPrivacyScreenV1");
        let definition = WNDCLASSW { style: 0, lpfnWndProc: Some(window), cbClsExtra: 0, cbWndExtra: 0,
            hInstance: instance, hIcon: null_mut(), hCursor: null_mut(),
            hbrBackground: GetStockObject(BLACK_BRUSH as i32).cast(), lpszMenuName: null(), lpszClassName: class.as_ptr() };
        if RegisterClassW(&definition) == 0 { bail!("Cannot register privacy screen windows"); }
        WINDOW_THREAD.store(GetCurrentThreadId(), Ordering::Release);
        for rect in rects {
            let hwnd = CreateWindowExW(WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_LAYERED | WS_EX_TRANSPARENT,
                class.as_ptr(), wide("NikoDesk Privacy screen").as_ptr(), WS_POPUP,
                rect.left, rect.top, rect.right - rect.left, rect.bottom - rect.top,
                null_mut(), null_mut(), instance, null_mut());
            if hwnd.is_null() { bail!("Cannot create every privacy screen window"); }
            result.windows.push(hwnd);
            let mut affinity = 0;
            if SetLayeredWindowAttributes(hwnd, 0, 255, LWA_ALPHA) == 0
                || SetWindowDisplayAffinity(hwnd, WDA_EXCLUDE) == 0
                || GetWindowDisplayAffinity(hwnd, &mut affinity) == 0 || affinity != WDA_EXCLUDE {
                bail!("Windows capture exclusion is unavailable; privacy screen was cancelled");
            }
        }
        result.keyboard = SetWindowsHookExW(WH_KEYBOARD_LL, Some(keyboard), instance, 0);
        result.mouse = SetWindowsHookExW(WH_MOUSE_LL, Some(mouse), instance, 0);
        if result.keyboard.is_null() || result.mouse.is_null() { bail!("Cannot block local privacy screen input"); }
        for hwnd in &result.windows { ShowWindow(*hwnd, SW_SHOWNOACTIVATE); UpdateWindow(*hwnd); }
        if result.windows.iter().any(|hwnd| IsWindowVisible(*hwnd) == 0) { bail!("Not every privacy screen window became visible"); }
    }
    Ok(result)
}

/// Runs synchronously before *any* ordinary core initialization. No extra CLI
/// arguments, files, server credentials or shared desktop service are accepted.
pub fn helper_entry() -> Option<i32> {
    let arguments = std::env::args().skip(1).collect::<Vec<_>>();
    if arguments.first().map(String::as_str) != Some(ARG) { return None; }
    Some(if arguments.len() == 1 && helper().is_ok() { 0 } else { 1 })
}
fn helper() -> ResultType<()> {
    unsafe {
        if GetFileType(GetStdHandle(STD_INPUT_HANDLE)) != 3 || GetFileType(GetStdHandle(STD_OUTPUT_HANDLE)) != 3 {
            bail!("Privacy screen requires inherited control pipes");
        }
    }
    if !helper_supported() { bail!("Interactive privacy screen is unavailable"); }
    let system = system_token();
    let (frames, incoming) = mpsc::sync_channel(1);
    // Read the initial frame on a separate thread too: a manual/incomplete
    // invocation cannot wait forever without displaying any local UI.
    std::thread::spawn(move || {
        let mut input = std::io::stdin().lock();
        let mut header = [0; 4];
        if input.read_exact(&mut header).is_err() || &header != b"NPS1" { return; }
        if frames.send(Instant::now()).is_err() { return; }
        let mut heartbeat = [0; 1];
        while input.read_exact(&mut heartbeat).is_ok() && &heartbeat == b"H" {
            if frames.send(Instant::now()).is_err() { return; }
        }
    });
    incoming.recv_timeout(Duration::from_secs(3)).map_err(|_| anyhow!("Privacy screen startup expired"))?;
    let rects = monitor_rects()?;
    let cover = cover(&rects)?;
    let mut output = std::io::stdout().lock();
    output.write_all(b"R")?;
    output.flush()?;
    let mut lease = Instant::now();
    loop {
        match incoming.try_recv() {
            Ok(issued) if issued.elapsed() < Duration::from_secs(2) => {
                lease = issued;
                output.write_all(b"A")?;
                output.flush()?;
            }
            Ok(_) | Err(mpsc::TryRecvError::Disconnected) => break,
            Err(mpsc::TryRecvError::Empty) => {},
        }
        if lease.elapsed() > LEASE || !default_desktop() || (system && !active_console_session())
            || !same_monitors(&rects, &monitor_rects()?) { break; }
        if crate::nikodesk::privacy_style::unlock_windows::tick(){break;}
        unsafe {
            let mut composing = 0;
            if DwmIsCompositionEnabled(&mut composing) < 0 || composing == 0 { break; }
            let mut msg: MSG = std::mem::zeroed();
            while PeekMessageW(&mut msg, null_mut(), 0, 0, PM_REMOVE) != 0 {
                if msg.message == STOP || msg.message == WM_QUIT { return Ok(()); }
                if msg.message==UNLOCK{let _=crate::nikodesk::privacy_style::unlock_windows::show();continue;}
                if crate::nikodesk::privacy_style::unlock_windows::dispatch_key(&msg){continue;}
                TranslateMessage(&msg);
                DispatchMessageW(&msg);
            }
            for hwnd in &cover.windows {
                let mut affinity = 0;
                if GetWindowDisplayAffinity(*hwnd, &mut affinity) == 0 || affinity != WDA_EXCLUDE {
                    bail!("Privacy screen capture exclusion changed");
                }
                if SetWindowPos(*hwnd, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE) == 0 {
                    bail!("Privacy screen could not retain monitor coverage");
                }
            }
            crate::nikodesk::privacy_style::unlock_windows::raise();
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    Ok(())
}

/// The wallpaper variant shares the same monitor coverage, capture affinity,
/// physical-input hooks and emergency Esc path as the black privacy helper.
pub(crate) fn run_styled_helper()->ResultType<()> {
    use crate::nikodesk::privacy_style::{helper::{self,Input},windows};
    unsafe{
        if GetFileType(GetStdHandle(STD_INPUT_HANDLE))!=3 || GetFileType(GetStdHandle(STD_OUTPUT_HANDLE))!=3 {
            bail!("helper_pipe_required");
        }
    }
    if !helper_supported(){bail!("style_unsupported");}
    let receiver=helper::incoming();let style=helper::initial(&receiver)?;
    windows::set(style)?;let _renderer=windows::Cleanup;windows::tick(0.)?;
    let rects=monitor_rects()?;let cover=cover(&rects)?;
    windows::tick(0.)?;helper::respond(b'R')?;
    let system=system_token();let mut lease=Instant::now();let started=Instant::now();
    loop {
        let mut acknowledge=false;
        match receiver.try_recv(){
            Ok(frame) if frame.issued().elapsed()<Duration::from_secs(2)=>{
                lease=frame.issued();
                match frame{Input::Style(_,next)=>{windows::set(next)?;windows::tick(started.elapsed().as_secs_f32())?;},
                    Input::Unlock(_)=>{let _=crate::nikodesk::privacy_style::unlock_windows::show();},
                    Input::Show(_)|Input::Heartbeat(_)=>{},Input::Ready(_,_)=>bail!("invalid_frame")}
                acknowledge=true;
            }
            Ok(_)|Err(mpsc::TryRecvError::Disconnected)=>break,
            Err(mpsc::TryRecvError::Empty)=>{},
        }
        if lease.elapsed()>LEASE || !default_desktop() || system && !active_console_session()
            || !same_monitors(&rects,&monitor_rects()?){break;}
        if crate::nikodesk::privacy_style::unlock_windows::tick(){break;}
        windows::tick(started.elapsed().as_secs_f32())?;
        unsafe {
            let mut composing=0;
            if DwmIsCompositionEnabled(&mut composing)<0 || composing==0 {break;}
            let mut message:MSG=std::mem::zeroed();
            while PeekMessageW(&mut message,null_mut(),0,0,PM_REMOVE)!=0{
                if message.message==STOP || message.message==WM_QUIT{return Ok(());}
                if message.message==UNLOCK{let _=crate::nikodesk::privacy_style::unlock_windows::show();continue;}
                if crate::nikodesk::privacy_style::unlock_windows::dispatch_key(&message){continue;}
                TranslateMessage(&message);DispatchMessageW(&message);
            }
            for hwnd in &cover.windows{
                let mut affinity=0;
                if GetWindowDisplayAffinity(*hwnd,&mut affinity)==0 || affinity!=WDA_EXCLUDE
                    || SetWindowPos(*hwnd,HWND_TOPMOST,0,0,0,0,SWP_NOMOVE|SWP_NOSIZE|SWP_NOACTIVATE)==0 {
                    bail!("monitor_cover_changed");
                }
                InvalidateRect(*hwnd,null(),0);UpdateWindow(*hwnd);
            }
            crate::nikodesk::privacy_style::unlock_windows::raise();
        }
        if acknowledge{windows::tick(started.elapsed().as_secs_f32())?;helper::respond(b'A')?;}
        std::thread::sleep(Duration::from_millis(33));
    }
    Ok(())
}
