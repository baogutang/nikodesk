//! The privileged macOS service of NikoDesk (phase 3, docs/PHASE3-DESIGN.md
//! in the workspace), kept apart from the remote-control core so that the
//! code running as root stays small: a launchd daemon that installs verified
//! updates and removes the service, nothing else. It answers only callers
//! signed with the fixed NikoDesk certificate, identified by the audit token
//! of their socket and a challenge (daemon.rs).
//!
//! Root runs only code from a root-owned directory. Installation copies the
//! app there and checks the copy; the daemon runs from it. /Applications is
//! writable by administrator users, so anything root started from there could
//! be replaced by any program running as such a user.
#![cfg(target_os = "macos")]

pub mod daemon;
mod plist;
pub mod update;

pub use plist::*;
use serde::{Deserialize, Serialize};
use std::{
    ffi::{c_char, CStr, CString},
    io::{BufRead, BufReader, Write},
    os::{fd::RawFd, unix::net::UnixStream},
    path::Path,
    time::Duration,
};

/// The NikoDesk app: its identifier and the fixed certificate
/// (scripts/macos-signing-setup.sh).
pub const REQUIREMENT: &str =
    "identifier \"io.nikodesk.macos\" and certificate leaf = H\"7C5F3E1E513BDCD4DEF443C7D71FE98FF07392A9\"";
/// This daemon's executable inside the app.
pub const SERVICE_REQUIREMENT: &str =
    "identifier \"io.nikodesk.service\" and certificate leaf = H\"7C5F3E1E513BDCD4DEF443C7D71FE98FF07392A9\"";

extern "C" {
    fn NikoPeerAllowed(
        token: *const u32,
        requirement: *const c_char,
        euid: *mut u32,
        path: *mut c_char,
        length: usize,
    ) -> i32;
    fn NikoBundleAllowed(path: *const c_char, requirement: *const c_char) -> i32;
    fn NikoLaunchSocket(name: *const c_char) -> i32;
    #[cfg(test)]
    fn NikoSelfCdhashRequirement(out: *mut c_char, length: usize) -> bool;
}

#[derive(Debug)]
pub struct Peer {
    pub euid: u32,
    pub path: String,
    /// The audit token the checks were made with.
    pub token: [u32; 8],
}

/// The audit token of the process that last used the other end of `fd`, as
/// it is now. XNU looks that process up when asked (`last_pid`); it does not
/// keep the token of the process that connected.
pub fn peer_token(fd: RawFd) -> Option<[u32; 8]> {
    let mut token = [0u32; 8];
    let mut size = std::mem::size_of_val(&token) as libc::socklen_t;
    let status = unsafe {
        libc::getsockopt(fd, libc::SOL_LOCAL, libc::LOCAL_PEERTOKEN, token.as_mut_ptr().cast(), &mut size)
    };
    (status == 0 && size as usize == std::mem::size_of_val(&token)).then_some(token)
}

/// Who is on the other end of `fd`, if its code meets `requirement`. The
/// error is the reason code: 1 no audit token, 2 no code, 3 bad requirement,
/// 4 requirement not met.
pub fn check_peer(fd: RawFd, requirement: &str) -> Result<Peer, (i32, String)> {
    let token = peer_token(fd).ok_or((1, String::new()))?;
    let requirement = CString::new(requirement).map_err(|_| (3, String::new()))?;
    let mut euid = u32::MAX;
    let mut path = [0 as c_char; 1024];
    let code =
        unsafe { NikoPeerAllowed(token.as_ptr(), requirement.as_ptr(), &mut euid, path.as_mut_ptr(), path.len()) };
    let path = unsafe { CStr::from_ptr(path.as_ptr()) }.to_string_lossy().into_owned();
    if code == 0 {
        Ok(Peer { euid, path, token })
    } else {
        Err((code, path))
    }
}

/// Whether the code at `path` (a bundle with everything nested in it, or a
/// single executable) is validly signed and meets the requirement.
pub fn bundle_allowed(path: &Path, requirement: &str) -> bool {
    let (Ok(path), Ok(requirement)) = (
        CString::new(path.as_os_str().as_encoded_bytes()),
        CString::new(requirement),
    ) else {
        return false;
    };
    unsafe { NikoBundleAllowed(path.as_ptr(), requirement.as_ptr()) == 0 }
}

pub fn launch_socket(name: &str) -> Option<RawFd> {
    let name = CString::new(name).ok()?;
    let fd = unsafe { NikoLaunchSocket(name.as_ptr()) };
    (fd >= 0).then_some(fd)
}

#[derive(Debug, Default, Serialize, Deserialize, PartialEq)]
pub struct Request {
    pub op: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub bundle: String,
    /// The daemon's challenge for this connection.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub nonce: String,
}

#[derive(Debug, Serialize, Deserialize, PartialEq)]
pub struct Response {
    pub ok: bool,
    pub code: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub detail: String,
}

impl Response {
    pub fn ok(code: &str) -> Self {
        Self { ok: true, code: code.into(), detail: String::new() }
    }
    pub fn error(code: &str) -> Self {
        Self { ok: false, code: code.into(), detail: String::new() }
    }
}

/// One request to the daemon and its answer. The daemon first sends a
/// challenge, which the request carries back. Installing an update copies and
/// checks a whole app, hence the long read timeout.
pub fn request(request: &Request) -> std::io::Result<Response> {
    let stream = UnixStream::connect(SOCKET_PATH)?;
    stream.set_read_timeout(Some(Duration::from_secs(180)))?;
    stream.set_write_timeout(Some(Duration::from_secs(5)))?;
    let mut reader = BufReader::new(&stream);
    let challenge = read_response(&mut reader)?;
    if !challenge.ok || challenge.code != "challenge" {
        return Ok(challenge);
    }
    let answered = Request { op: request.op.clone(), bundle: request.bundle.clone(), nonce: challenge.detail };
    let mut line = serde_json::to_string(&answered)?;
    line.push('\n');
    (&stream).write_all(line.as_bytes())?;
    read_response(&mut reader)
}

fn read_response(reader: &mut impl BufRead) -> std::io::Result<Response> {
    let mut line = String::new();
    reader.take_line(&mut line)?;
    Ok(serde_json::from_str(line.trim())?)
}

pub(crate) trait TakeLine {
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::fd::AsRawFd;

    pub(crate) fn self_requirement() -> String {
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
        let request = Request { op: "status".into(), ..Default::default() };
        assert_eq!(serde_json::to_string(&request).unwrap(), r#"{"op":"status"}"#);
        let mut answer = String::new();
        let long = format!("{}\n", "x".repeat(20 * 1024));
        assert!(BufReader::new(long.as_bytes()).take_line(&mut answer).is_err());
        let mut answer = String::new();
        BufReader::new(&b"{\"ok\":true,\"code\":\"ready\"}\n"[..]).take_line(&mut answer).unwrap();
        assert_eq!(serde_json::from_str::<Response>(answer.trim()).unwrap(), Response::ok("ready"));
    }

    #[test]
    fn an_unsigned_bundle_is_refused() {
        assert!(!bundle_allowed(Path::new("/System/Applications/Calculator.app"), REQUIREMENT));
        assert!(!bundle_allowed(Path::new("/nonexistent.app"), REQUIREMENT));
    }
}
