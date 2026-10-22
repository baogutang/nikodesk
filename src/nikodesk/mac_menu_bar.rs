//! The menu bar icon. Whichever process holds the core lease (the window app
//! or the background agent) shows it, so there is one icon while a core runs.
use hbb_common::{
    config::{self, Config, LocalConfig},
    log,
};
use std::{
    collections::HashSet,
    ffi::{c_void, CString},
    os::raw::{c_char, c_long},
    path::PathBuf,
    time::Duration,
};

const ICON: &[u8] = include_bytes!("../../res/nikodesk-tray.png");
const SEPARATOR: c_long = -1;
const STATUS: c_long = 0;
const COPY_ID: c_long = 1;
const OPEN: c_long = 2;
const QUIT: c_long = 3;

extern "C" {
    fn NikoMenuBarStart(
        png: *const u8,
        length: usize,
        fill: extern "C" fn(*mut c_void),
        choose: extern "C" fn(c_long),
    );
    fn NikoMenuBarAppend(menu: *mut c_void, title: *const c_char, tag: c_long, enabled: bool);
    fn NikoMenuBarSetState(online: bool, busy: bool, tooltip: *const c_char);
    fn NikoMenuBarCopy(text: *const c_char);
    fn NikoMenuBarConfirm(
        title: *const c_char,
        message: *const c_char,
        accept: *const c_char,
        cancel: *const c_char,
    ) -> bool;
    fn NikoMenuBarQuit();
}

#[derive(Clone, Debug, PartialEq)]
struct State {
    /// `config::get_online_state()`: above 0 registered with the ID server,
    /// 0 still connecting, below 0 failed.
    online: i64,
    sessions: usize,
    id: String,
    english: bool,
    /// The background agent is restarted by launchd and serves unattended
    /// access; quitting it is left to the service settings.
    agent: bool,
}

pub(crate) fn start() {
    // Upstream's `--server` process draws its own tray icon.
    if crate::is_server() {
        return;
    }
    unsafe { NikoMenuBarStart(ICON.as_ptr(), ICON.len(), fill, choose) };
    if let Err(error) = std::thread::Builder::new()
        .name("niko-menu-bar".into())
        .spawn(watch)
    {
        log::error!("Menu bar state thread failed: {error}");
    }
}

fn state() -> State {
    let language = LocalConfig::get_option("lang");
    State {
        online: config::get_online_state(),
        sessions: sessions(),
        id: Config::get_id_or(String::new()),
        english: !language.is_empty() && !language.starts_with("zh"),
        agent: super::mac_background::selected(),
    }
}

/// Peers with an authorized connection. The connection a reconnecting peer
/// left behind keeps its session key until it times out, so it is not
/// counted twice.
fn sessions() -> usize {
    crate::server::AUTHED_CONNS
        .lock()
        .map(|conns| {
            conns
                .iter()
                .map(|conn| &conn.session_key)
                .collect::<HashSet<_>>()
                .len()
        })
        .unwrap_or(0)
}

fn watch() {
    let mut shown = None;
    loop {
        let state = state();
        let next = (state.online > 0, state.sessions > 0, tooltip(&state));
        if shown.as_ref() != Some(&next) {
            if let Ok(tip) = CString::new(next.2.as_str()) {
                unsafe { NikoMenuBarSetState(next.0, next.1, tip.as_ptr()) };
            }
            shown = Some(next);
        }
        std::thread::sleep(Duration::from_secs(1));
    }
}

fn text(state: &State, chinese: &str, english: &str) -> String {
    if state.english { english } else { chinese }.to_owned()
}

fn status(state: &State) -> String {
    match state.sessions {
        0 if state.online > 0 => text(state, "可被远程连接", "Ready for remote connections"),
        0 if state.online == 0 => text(state, "正在连接服务器…", "Connecting to the server…"),
        0 => text(state, "未连接服务器", "Not connected to the server"),
        1 if state.english => "1 remote connection".to_owned(),
        n if state.english => format!("{n} remote connections"),
        n => format!("{n} 个远程连接进行中"),
    }
}

fn tooltip(state: &State) -> String {
    format!("NikoDesk · {}", status(state))
}

/// The grouping of the window app's `formatID`: "1 234 567 890".
fn format_id(id: &str) -> String {
    if id.is_empty() || !id.bytes().all(|b| b.is_ascii_digit()) {
        return id.to_owned();
    }
    let head = match id.len() % 3 {
        0 => 3,
        n => n,
    }
    .min(id.len());
    let mut out = id[..head].to_owned();
    for group in id.as_bytes()[head..].chunks(3) {
        out.push(' ');
        out.push_str(&String::from_utf8_lossy(group));
    }
    out
}

fn items(state: &State) -> Vec<(c_long, String)> {
    let mut items = vec![(STATUS, status(state)), (SEPARATOR, String::new())];
    if !state.id.is_empty() {
        let label = text(state, "复制本机 ID", "Copy ID");
        items.push((COPY_ID, format!("{label}  {}", format_id(&state.id))));
    }
    items.push((OPEN, text(state, "打开 NikoDesk", "Open NikoDesk")));
    if !state.agent {
        items.push((SEPARATOR, String::new()));
        items.push((QUIT, text(state, "退出 NikoDesk", "Quit NikoDesk")));
    }
    items
}

extern "C" fn fill(menu: *mut c_void) {
    for (tag, title) in items(&state()) {
        if let Ok(title) = CString::new(title) {
            unsafe { NikoMenuBarAppend(menu, title.as_ptr(), tag, tag > STATUS) };
        }
    }
}

extern "C" fn choose(tag: c_long) {
    match tag {
        COPY_ID => {
            if let Ok(id) = CString::new(Config::get_id_or(String::new())) {
                unsafe { NikoMenuBarCopy(id.as_ptr()) };
            }
        }
        OPEN => open_main_window(),
        QUIT => quit(),
        _ => {}
    }
}

/// Quitting the window app ends the sessions it serves, so ask first while
/// there are any.
fn quit() {
    let state = state();
    if state.sessions > 0 {
        let title = text(&state, "退出 NikoDesk？", "Quit NikoDesk?");
        let message = if state.english {
            format!("{} active remote connection(s) will be disconnected.", state.sessions)
        } else {
            format!("正在进行的 {} 个远程连接会断开。", state.sessions)
        };
        let accept = text(&state, "退出", "Quit");
        let cancel = text(&state, "取消", "Cancel");
        let (Ok(title), Ok(message), Ok(accept), Ok(cancel)) = (
            CString::new(title),
            CString::new(message),
            CString::new(accept),
            CString::new(cancel),
        ) else {
            return;
        };
        let confirmed = unsafe {
            NikoMenuBarConfirm(title.as_ptr(), message.as_ptr(), accept.as_ptr(), cancel.as_ptr())
        };
        if !confirmed {
            return;
        }
    }
    log::info!("Quit from the menu bar");
    unsafe { NikoMenuBarQuit() };
}

/// The window app brings its main window forward when its URL channel gets
/// an empty link. Only the agent starts a missing window app: LaunchServices
/// hands an `open` of this bundle to the agent itself, which runs from the
/// same bundle, so a new instance has to be asked for.
pub(crate) fn open_main_window() {
    let agent = super::mac_background::selected();
    let spawned = std::thread::Builder::new()
        .name("niko-open-main".into())
        .spawn(move || {
            if crate::ipc::send_url_scheme(String::new()).is_ok() {
                return;
            }
            if !agent {
                log::warn!("Menu bar could not reach the main window");
                return;
            }
            let Some(bundle) = bundle_path() else {
                log::warn!("Menu bar could not find the application bundle");
                return;
            };
            match std::process::Command::new("/usr/bin/open")
                .arg("-n")
                .arg(bundle)
                .status()
            {
                Ok(status) if status.success() => {}
                Ok(status) => log::warn!("Starting the window app failed: {status}"),
                Err(error) => log::warn!("Starting the window app failed: {error}"),
            }
        });
    if let Err(error) = spawned {
        log::error!("Opening the main window failed: {error}");
    }
}

/// Finder, the Dock and Spotlight reopen the agent when it is the only
/// running instance of the bundle.
pub(crate) extern "C" fn reopen() {
    open_main_window();
}

fn bundle_path() -> Option<PathBuf> {
    let exe = std::env::current_exe().ok()?;
    let bundle = exe.parent()?.parent()?.parent()?;
    (bundle.extension()? == "app").then(|| bundle.to_path_buf())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample(online: i64, sessions: usize, english: bool, agent: bool) -> State {
        State { online, sessions, id: "1234567890".into(), english, agent }
    }

    #[test]
    fn ids_are_grouped_like_the_window_app() {
        assert_eq!(format_id("1234567890"), "1 234 567 890");
        assert_eq!(format_id("123456789"), "123 456 789");
        assert_eq!(format_id("12345678"), "12 345 678");
        assert_eq!(format_id("123"), "123");
        assert_eq!(format_id("12"), "12");
        assert_eq!(format_id(""), "");
        assert_eq!(format_id("niko-mac"), "niko-mac");
    }

    #[test]
    fn the_status_line_follows_the_server_and_the_sessions() {
        assert_eq!(status(&sample(25, 0, false, false)), "可被远程连接");
        assert_eq!(status(&sample(0, 0, false, false)), "正在连接服务器…");
        assert_eq!(status(&sample(-1, 0, false, false)), "未连接服务器");
        assert_eq!(status(&sample(25, 2, false, false)), "2 个远程连接进行中");
        assert_eq!(status(&sample(-1, 1, false, false)), "1 个远程连接进行中");
        assert_eq!(status(&sample(25, 0, true, false)), "Ready for remote connections");
        assert_eq!(status(&sample(25, 1, true, false)), "1 remote connection");
        assert_eq!(status(&sample(25, 3, true, false)), "3 remote connections");
        assert_eq!(tooltip(&sample(25, 0, false, false)), "NikoDesk · 可被远程连接");
    }

    #[test]
    fn the_window_app_offers_quit_and_the_agent_does_not() {
        let app = items(&sample(25, 0, false, false));
        assert_eq!(
            app,
            vec![
                (STATUS, "可被远程连接".to_owned()),
                (SEPARATOR, String::new()),
                (COPY_ID, "复制本机 ID  1 234 567 890".to_owned()),
                (OPEN, "打开 NikoDesk".to_owned()),
                (SEPARATOR, String::new()),
                (QUIT, "退出 NikoDesk".to_owned()),
            ]
        );
        let agent = items(&sample(25, 0, true, true));
        assert_eq!(
            agent,
            vec![
                (STATUS, "Ready for remote connections".to_owned()),
                (SEPARATOR, String::new()),
                (COPY_ID, "Copy ID  1 234 567 890".to_owned()),
                (OPEN, "Open NikoDesk".to_owned()),
            ]
        );
    }

    #[test]
    fn there_is_nothing_to_copy_without_an_id() {
        let mut state = sample(0, 0, false, false);
        state.id.clear();
        assert!(items(&state).iter().all(|(tag, _)| *tag != COPY_ID));
    }

    #[test]
    fn only_the_status_line_is_disabled() {
        // `fill` enables every tag above STATUS; separators are below it.
        for (tag, _) in items(&sample(25, 1, false, false)) {
            assert_eq!(tag > STATUS, [COPY_ID, OPEN, QUIT].contains(&tag));
        }
    }
}
