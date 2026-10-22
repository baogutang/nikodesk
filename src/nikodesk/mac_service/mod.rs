//! The privileged service of phase 3 (docs/PHASE3-DESIGN.md in the
//! workspace): a root launchd daemon that only installs verified updates and
//! removes the service, and a launchd agent that runs the core in each
//! signed-in desktop (replacing the user-level agent) and, once supported, in
//! the login window. Callers of the daemon are checked by
//! the audit token of their socket against the fixed NikoDesk certificate.
pub(crate) mod daemon;
mod plist;

pub(crate) use plist::*;
use hbb_common::{bail, libc, ResultType};
use serde_derive::{Deserialize, Serialize};
use std::{
    ffi::{c_char, CStr, CString},
    io::{BufRead, BufReader, Write},
    os::{fd::RawFd, unix::net::UnixStream},
    path::{Path, PathBuf},
    time::Duration,
};

/// Signed by the fixed NikoDesk certificate (scripts/macos-signing-setup.sh)
/// and the app's own identifier.
pub(crate) const REQUIREMENT: &str = "identifier \"io.nikodesk.macos\" and certificate leaf = H\"7C5F3E1E513BDCD4DEF443C7D71FE98FF07392A9\"";

extern "C" {
    fn NikoPeerAllowed(fd: i32, requirement: *const c_char, euid: *mut u32, path: *mut c_char, length: usize) -> i32;
    fn NikoBundleAllowed(path: *const c_char, requirement: *const c_char) -> i32;
    fn NikoLaunchSocket(name: *const c_char) -> i32;
    fn NikoLoginWindowProbe(out: *mut c_char, length: usize) -> bool;
    #[cfg(test)]
    fn NikoSelfCdhashRequirement(out: *mut c_char, length: usize) -> bool;
}

#[derive(Debug)]
pub(crate) struct Peer {
    pub(crate) euid: u32,
    pub(crate) path: String,
}

/// Who is on the other end of `fd`, if its code meets `requirement`. The
/// error is the native reason code: 1 no audit token, 2 no code, 3 bad
/// requirement, 4 requirement not met.
pub(crate) fn check_peer(fd: RawFd, requirement: &str) -> Result<Peer, (i32, String)> {
    let requirement = CString::new(requirement).map_err(|_| (3, String::new()))?;
    let mut euid = u32::MAX;
    let mut path = [0 as c_char; 1024];
    let code = unsafe { NikoPeerAllowed(fd, requirement.as_ptr(), &mut euid, path.as_mut_ptr(), path.len()) };
    let path = unsafe { CStr::from_ptr(path.as_ptr()) }.to_string_lossy().into_owned();
    if code == 0 {
        Ok(Peer { euid, path })
    } else {
        Err((code, path))
    }
}

/// Whether the bundle at `path`, with everything nested in it, is validly
/// signed and meets the requirement.
pub(crate) fn bundle_allowed(path: &Path, requirement: &str) -> bool {
    let (Ok(path), Ok(requirement)) = (
        CString::new(path.as_os_str().as_encoded_bytes()),
        CString::new(requirement),
    ) else {
        return false;
    };
    unsafe { NikoBundleAllowed(path.as_ptr(), requirement.as_ptr()) == 0 }
}

pub(crate) fn launch_socket(name: &str) -> Option<RawFd> {
    let name = CString::new(name).ok()?;
    let fd = unsafe { NikoLaunchSocket(name.as_ptr()) };
    (fd >= 0).then_some(fd)
}

/// What a root agent in the login window may do (screen capture, input,
/// secure input), appended once per start to the service log directory with
/// the screen capture result of ScreenCaptureKit as well.
pub(crate) fn probe_login_window() {
    let mut out = [0 as c_char; 2048];
    let native = if unsafe { NikoLoginWindowProbe(out.as_mut_ptr(), out.len()) } {
        unsafe { CStr::from_ptr(out.as_ptr()) }.to_string_lossy().into_owned()
    } else {
        "{}".to_owned()
    };
    let sck = scrap::Display::primary()
        .map_err(|error| error.to_string())
        .and_then(|display| {
            scrap::nikodesk_sck::SckCapturer::new(&display, false)
                .map(|_| format!("{}x{}", display.width(), display.height()))
                .map_err(|error| error.to_string())
        });
    let line = format!(
        "{} probe={native} sck={}",
        hbb_common::chrono::Local::now().to_rfc3339(),
        match sck { Ok(size) => format!("started {size}"), Err(error) => error },
    );
    daemon::append_log("loginwindow-probe.log", &line);
}

#[derive(Debug, Serialize, Deserialize, PartialEq)]
pub(crate) struct Request {
    pub(crate) op: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub(crate) bundle: String,
}

#[derive(Debug, Serialize, Deserialize, PartialEq)]
pub(crate) struct Response {
    pub(crate) ok: bool,
    pub(crate) code: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub(crate) detail: String,
}

impl Response {
    pub(crate) fn ok(code: &str) -> Self {
        Self { ok: true, code: code.into(), detail: String::new() }
    }
    pub(crate) fn error(code: &str) -> Self {
        Self { ok: false, code: code.into(), detail: String::new() }
    }
}

/// One request to the daemon and its answer.
pub(crate) fn request(request: &Request) -> ResultType<Response> {
    let mut stream = UnixStream::connect(SOCKET_PATH)?;
    stream.set_read_timeout(Some(Duration::from_secs(120)))?;
    stream.set_write_timeout(Some(Duration::from_secs(5)))?;
    let mut line = serde_json::to_string(request)?;
    line.push('\n');
    stream.write_all(line.as_bytes())?;
    let mut answer = String::new();
    BufReader::new(stream).take_line(&mut answer)?;
    Ok(serde_json::from_str(answer.trim())?)
}

trait TakeLine {
    fn take_line(&mut self, out: &mut String) -> std::io::Result<()>;
}

impl<R: BufRead> TakeLine for R {
    /// At most 16 KiB, so a misbehaving peer cannot make either side buffer
    /// without bound.
    fn take_line(&mut self, out: &mut String) -> std::io::Result<()> {
        use std::io::Read;
        let mut limited = self.take(16 * 1024);
        limited.read_line(out)?;
        if !out.ends_with('\n') {
            return Err(std::io::Error::new(std::io::ErrorKind::InvalidData, "line_too_long_or_cut"));
        }
        Ok(())
    }
}

/// Both jobs are on disk.
pub(crate) fn installed() -> bool {
    Path::new(&daemon_path()).exists() && Path::new(&agent_path()).exists()
}

pub(crate) fn state_json() -> String {
    let installed = installed();
    let app_signed = running_bundle().is_ok_and(|(bundle, _)| bundle_allowed(&bundle, REQUIREMENT));
    let reachable = installed
        && request(&Request { op: "status".into(), bundle: String::new() }).is_ok_and(|response| response.ok);
    serde_json::json!({ "installed": installed, "app_signed": app_signed, "reachable": reachable }).to_string()
}

/// The `.app` that contains the running executable.
fn running_bundle() -> ResultType<(PathBuf, PathBuf)> {
    let executable = std::env::current_exe()?.canonicalize()?;
    let Some(bundle) = executable.ancestors().nth(3).map(Path::to_path_buf) else {
        bail!("not_in_app_bundle");
    };
    if bundle.extension().and_then(|e| e.to_str()) != Some("app") {
        bail!("not_in_app_bundle");
    }
    Ok((bundle, executable))
}

/// Installs both jobs after the system administrator prompt. Refuses an app
/// not signed with the fixed certificate: the jobs would start it as root
/// (daemon) and in the login window (agent).
pub(crate) fn install() -> ResultType<()> {
    let (bundle, executable) = running_bundle()?;
    if !bundle_allowed(&bundle, REQUIREMENT) {
        bail!("app_not_signed_with_nikodesk_certificate");
    }
    let Some(executable) = executable.to_str() else {
        bail!("app_path_not_utf8");
    };
    let uid = unsafe { libc::getuid() };
    let steps = install_steps(executable, uid);
    run_admin(&steps, "NikoDesk wants to install its background service for the login window.")
}

/// Removes both jobs through the daemon (no password), or after the
/// administrator prompt if the daemon cannot be reached.
pub(crate) fn uninstall() -> ResultType<()> {
    match request(&Request { op: "uninstall".into(), bundle: String::new() }) {
        Ok(response) if response.ok => Ok(()),
        _ => {
            let uid = unsafe { libc::getuid() };
            run_admin(&uninstall_steps(uid), "NikoDesk wants to remove its background service.")
        }
    }
}

fn run_admin(steps: &str, prompt: &str) -> ResultType<()> {
    let status = std::process::Command::new("/usr/bin/osascript")
        .arg("-e")
        .arg(admin_script(steps, prompt))
        .status()?;
    if !status.success() {
        bail!("administrator_step_failed_or_cancelled");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::fd::AsRawFd;

    fn self_requirement() -> String {
        let mut out = [0 as c_char; 256];
        assert!(unsafe { NikoSelfCdhashRequirement(out.as_mut_ptr(), out.len()) });
        unsafe { CStr::from_ptr(out.as_ptr()) }.to_string_lossy().into_owned()
    }

    #[test]
    fn a_caller_is_checked_by_its_signature_not_its_process_id() {
        let (ours, theirs) = UnixStream::pair().unwrap();
        // The other end is this test process: it meets a requirement naming its
        // own code directory hash...
        let peer = check_peer(ours.as_raw_fd(), &self_requirement()).expect("own cdhash");
        assert_eq!(peer.euid, unsafe { libc::geteuid() });
        assert!(!peer.path.is_empty());
        // ...but is not signed with the NikoDesk certificate.
        let (code, _) = check_peer(ours.as_raw_fd(), REQUIREMENT).unwrap_err();
        assert_eq!(code, 4);
        assert_eq!(check_peer(ours.as_raw_fd(), "not a requirement").unwrap_err().0, 3);
        drop(theirs);
    }

    #[test]
    fn requests_and_answers_are_single_bounded_lines() {
        let request = Request { op: "status".into(), bundle: String::new() };
        assert_eq!(serde_json::to_string(&request).unwrap(), r#"{"op":"status"}"#);
        let mut answer = String::new();
        let long = format!("{}\n", "x".repeat(20 * 1024));
        assert!(BufReader::new(long.as_bytes()).take_line(&mut answer).is_err());
        let mut answer = String::new();
        BufReader::new(&b"{\"ok\":true,\"code\":\"ready\"}\n"[..]).take_line(&mut answer).unwrap();
        assert_eq!(serde_json::from_str::<Response>(answer.trim()).unwrap(), Response::ok("ready"));
    }

    #[test]
    fn the_login_window_probe_reports_permissions_without_names() {
        let mut out = [0 as c_char; 2048];
        assert!(unsafe { NikoLoginWindowProbe(out.as_mut_ptr(), out.len()) });
        let json: serde_json::Value =
            serde_json::from_str(&unsafe { CStr::from_ptr(out.as_ptr()) }.to_string_lossy()).unwrap();
        for key in ["euid", "screen_capture_preflight", "post_event_preflight", "secure_input", "cg_image"] {
            assert!(json.get(key).is_some(), "{key} missing");
        }
        if let Some(name) = json.get("kCGSSessionUserNameKey") {
            assert_eq!(name, "present");
        }
    }

    #[test]
    fn an_unsigned_bundle_is_refused() {
        assert!(!bundle_allowed(Path::new("/System/Applications/Calculator.app"), REQUIREMENT));
        assert!(!bundle_allowed(Path::new("/nonexistent.app"), REQUIREMENT));
    }
}
