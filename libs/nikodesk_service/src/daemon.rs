//! The root daemon. launchd starts it at boot and on each connection to its
//! socket; it serves while requests arrive and exits after a short idle
//! time. It only answers callers signed with the fixed certificate, and
//! writes every request to an audit log.
use crate::{
    check_peer, launch_socket, peer_token, service_app, uninstall_steps, update, update_dir, Request, Response,
    TakeLine, AGENT_LABEL, INSTALLED_APP, REQUIREMENT,
};
use std::{
    io::{BufReader, Write},
    os::{
        fd::{AsRawFd, FromRawFd, RawFd},
        unix::net::{UnixListener, UnixStream},
    },
    path::Path,
    time::Duration,
};

const AUDIT_DIR: &str = "/Library/Logs/NikoDesk";
const IDLE: Duration = Duration::from_secs(15);

pub fn main() -> i32 {
    match run() {
        Ok(()) => 0,
        Err(error) => {
            audit(&format!("stopped error={error}"));
            1
        }
    }
}

fn run() -> Result<(), &'static str> {
    if unsafe { libc::geteuid() } != 0 {
        return Err("root_required");
    }
    let Some(fd) = launch_socket("Listener") else {
        // Started at boot with no one waiting: nothing to do.
        return Ok(());
    };
    let listener = unsafe { UnixListener::from_raw_fd(fd) };
    serve(&listener, REQUIREMENT, IDLE);
    Ok(())
}

/// Answers connections until none arrives for `idle`.
fn serve(listener: &UnixListener, requirement: &str, idle: Duration) {
    loop {
        if !readable(listener.as_raw_fd(), idle) {
            return;
        }
        let Ok((stream, _)) = listener.accept() else {
            continue;
        };
        if handle(stream, requirement) {
            return;
        }
    }
}

fn readable(fd: RawFd, timeout: Duration) -> bool {
    let mut poll = libc::pollfd { fd, events: libc::POLLIN, revents: 0 };
    unsafe { libc::poll(&mut poll, 1, timeout.as_millis() as i32) > 0 }
}

/// Serves one request; true when the daemon should stop afterwards.
fn handle(stream: UnixStream, requirement: &str) -> bool {
    let _ = stream.set_read_timeout(Some(Duration::from_secs(5)));
    let _ = stream.set_write_timeout(Some(Duration::from_secs(5)));
    let peer = match check_peer(stream.as_raw_fd(), requirement) {
        Ok(peer) => peer,
        Err((code, path)) => {
            audit(&format!("rejected caller={path:?} reason={code}"));
            reply(&stream, &Response::error("caller_not_allowed"));
            return false;
        }
    };
    // The token is that of the socket's last user when asked, and the socket
    // does not say who wrote what is in it: a program could write a request
    // and then exec the app before the check above. So the request has to
    // carry a challenge sent after that check, and the socket's last user,
    // which every send and receive updates, must still be the process checked
    // (an exec gives it a new token).
    let Some(nonce) = nonce() else {
        reply(&stream, &Response::error("challenge_failed"));
        return false;
    };
    reply(&stream, &Response { ok: true, code: "challenge".into(), detail: nonce.clone() });
    let mut line = String::new();
    let request = match BufReader::new(&stream).take_line(&mut line) {
        Ok(()) => serde_json::from_str::<Request>(line.trim()).ok(),
        Err(_) => None,
    };
    let Some(request) = request else {
        audit(&format!("bad_request caller={:?} euid={}", peer.path, peer.euid));
        reply(&stream, &Response::error("bad_request"));
        return false;
    };
    if request.nonce != nonce || peer_token(stream.as_raw_fd()) != Some(peer.token) {
        audit(&format!("rejected caller={:?} reason=challenge", peer.path));
        reply(&stream, &Response::error("caller_not_allowed"));
        return false;
    }
    let (response, stop) = match request.op.as_str() {
        "status" => (status(), false),
        "install_update" => (install_update(&request.bundle, peer.euid), false),
        "restore_update" => (restore_update(peer.euid), false),
        "sync" => (sync(), false),
        "uninstall" => match remove(peer.euid) {
            Ok(()) => (Response::ok("removed"), true),
            Err(error) => (Response { ok: false, code: "remove_failed".into(), detail: error.into() }, false),
        },
        _ => (Response::error("unsupported"), false),
    };
    audit(&format!(
        "op={} caller={:?} euid={} result={} detail={:?}",
        request.op, peer.path, peer.euid, response.code, response.detail
    ));
    reply(&stream, &response);
    stop
}

/// 128 random bits, as hex.
fn nonce() -> Option<String> {
    let mut bytes = [0u8; 16];
    (unsafe { libc::getentropy(bytes.as_mut_ptr().cast(), bytes.len()) } == 0)
        .then(|| bytes.iter().map(|byte| format!("{byte:02x}")).collect())
}

fn reply(mut stream: &UnixStream, response: &Response) {
    if let Ok(mut line) = serde_json::to_string(response) {
        line.push('\n');
        let _ = stream.write_all(line.as_bytes());
    }
}

fn version_text(bundle: &Path) -> String {
    update::version(bundle).map(|v| v.to_string()).unwrap_or_else(|| "none".into())
}

/// The versions of the app, of root's copy and of the app a restore would
/// put back, e.g. `installed=2.0.0+23 service=2.0.0+23 previous=1.0.11+22`.
fn status() -> Response {
    Response {
        ok: true,
        code: "ready".into(),
        detail: format!(
            "installed={} service={} previous={}",
            version_text(Path::new(INSTALLED_APP)),
            version_text(Path::new(&service_app())),
            version_text(&Path::new(&update_dir()).join("previous/NikoDesk.app"))
        ),
    }
}

fn done(result: Result<String, &'static str>, code: &str) -> Response {
    match result {
        Ok(detail) => Response { ok: true, code: code.into(), detail },
        Err(error) => Response::error(error),
    }
}

/// Installs the update the caller staged, refreshes root's copy from the same
/// checked bundle, and restarts the caller's agent on the new app.
fn install_update(bundle: &str, uid: u32) -> Response {
    let work = update_dir();
    let result = update::staged(bundle, uid)
        .and_then(|staged| update::install(&staged, Path::new(INSTALLED_APP), Path::new(&work), &update::check_bundle))
        .map(|version| {
            let verified = Path::new(&work).join("verified/NikoDesk.app");
            if let Err(error) = update::replace_service_copy(&verified, Path::new(&service_app()), Path::new(&work)) {
                audit(&format!("service_copy_not_refreshed error={error}"));
            }
            restart_agent(uid);
            version.to_string()
        });
    done(result, "installed")
}

fn restore_update(uid: u32) -> Response {
    let result = update::restore(Path::new(INSTALLED_APP), Path::new(&update_dir()), &update::check_bundle).map(|version| {
        restart_agent(uid);
        version.to_string()
    });
    done(result, "restored")
}

/// After an update installed by hand: root's copy follows the app if it is
/// newer and passes the same checks.
fn sync() -> Response {
    let result = update::sync(
        Path::new(INSTALLED_APP),
        Path::new(&service_app()),
        Path::new(&update_dir()),
        &update::check_bundle,
    )
    .map(|synced| synced.map(|v| v.to_string()).unwrap_or_else(|| "current".into()));
    done(result, "synced")
}

/// The agent of that user's desktop, if loaded, starts again from the new app.
fn restart_agent(uid: u32) {
    let _ = std::process::Command::new("/bin/launchctl")
        .args(["kickstart", "-k", &format!("gui/{uid}/{AGENT_LABEL}")])
        .status();
}

/// Unloads the caller's agent and deletes everything the service installed.
/// The daemon's own unload, last in the steps, ends this process.
fn remove(uid: u32) -> Result<(), &'static str> {
    let status = std::process::Command::new("/bin/sh")
        .arg("-c")
        .arg(uninstall_steps(uid))
        .status()
        .map_err(|_| "uninstall_steps_failed")?;
    if !status.success() {
        return Err("uninstall_steps_failed");
    }
    Ok(())
}

/// Appends one timestamped line; root-owned, readable by administrators.
fn audit(line: &str) {
    append_log("service.log", &format!("{} {line}", now()));
}

/// Local time as `2026-10-22T15:04:05+0800`.
fn now() -> String {
    let mut time: libc::time_t = 0;
    let mut parts: libc::tm = unsafe { std::mem::zeroed() };
    let mut out = [0u8; 32];
    let written = unsafe {
        libc::time(&mut time);
        libc::localtime_r(&time, &mut parts);
        libc::strftime(out.as_mut_ptr() as *mut libc::c_char, out.len(), c"%Y-%m-%dT%H:%M:%S%z".as_ptr(), &parts)
    };
    String::from_utf8_lossy(&out[..written]).into_owned()
}

/// Appends a line to a file in the service log directory (root only).
pub fn append_log(name: &str, line: &str) {
    use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
    let _ = std::fs::DirBuilder::new().recursive(true).mode(0o755).create(AUDIT_DIR);
    if let Ok(mut file) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .mode(0o644)
        .custom_flags(libc::O_NOFOLLOW)
        .open(Path::new(AUDIT_DIR).join(name))
    {
        let _ = writeln!(file, "{line}");
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::BufRead;

    fn ask(stream: &UnixStream, request: &str) -> String {
        let mut writer = stream;
        writer.write_all(request.as_bytes()).unwrap();
        let mut answer = String::new();
        BufReader::new(stream).read_line(&mut answer).unwrap();
        answer
    }

    #[test]
    fn an_unsigned_caller_gets_no_service() {
        for request in ["{\"op\":\"status\"}\n", "{\"op\":\"install_update\",\"bundle\":\"/tmp/NikoDesk.app\"}\n"] {
            let (daemon, caller) = UnixStream::pair().unwrap();
            let worker = std::thread::spawn(move || handle(daemon, REQUIREMENT));
            let answer = ask(&caller, request);
            assert!(answer.contains("caller_not_allowed"));
            assert!(!worker.join().unwrap());
        }
    }

    fn challenge(reader: &mut impl BufRead) -> String {
        let mut line = String::new();
        reader.read_line(&mut line).unwrap();
        let challenge = serde_json::from_str::<Response>(line.trim()).unwrap();
        assert_eq!((challenge.ok, challenge.code.as_str(), challenge.detail.len()), (true, "challenge", 32));
        challenge.detail
    }

    #[test]
    fn a_caller_meeting_the_requirement_is_served() {
        let (daemon, caller) = UnixStream::pair().unwrap();
        let requirement = crate::tests::self_requirement();
        let worker = std::thread::spawn(move || handle(daemon, &requirement));
        let nonce = challenge(&mut BufReader::new(&caller));
        let answer = ask(&caller, &format!("{{\"op\":\"nothing\",\"nonce\":\"{nonce}\"}}\n"));
        assert!(answer.contains("\"code\":\"unsupported\""), "{answer}");
        assert!(!worker.join().unwrap());
    }

    #[test]
    fn a_request_that_does_not_answer_the_challenge_is_refused() {
        // Written before the challenge: what a program would leave in the
        // socket before exec'ing the app.
        for request in ["{\"op\":\"status\"}\n", "{\"op\":\"status\",\"nonce\":\"00\"}\n"] {
            let (daemon, caller) = UnixStream::pair().unwrap();
            let requirement = crate::tests::self_requirement();
            let worker = std::thread::spawn(move || handle(daemon, &requirement));
            (&caller).write_all(request.as_bytes()).unwrap();
            let mut reader = BufReader::new(&caller);
            challenge(&mut reader);
            let mut answer = String::new();
            reader.read_line(&mut answer).unwrap();
            assert!(answer.contains("caller_not_allowed"), "{answer}");
            assert!(!worker.join().unwrap());
        }
    }

    #[test]
    fn an_answer_written_by_another_process_is_refused() {
        let (daemon, caller) = UnixStream::pair().unwrap();
        let requirement = crate::tests::self_requirement();
        let worker = std::thread::spawn(move || handle(daemon, &requirement));
        let mut reader = BufReader::new(&caller);
        let nonce = challenge(&mut reader);
        // A child holding the same socket (as after a fork) answers, with the
        // right nonce, while the process that was checked stays silent.
        let status = std::process::Command::new("/usr/bin/printf")
            .args(["%s\n", &format!("{{\"op\":\"nothing\",\"nonce\":\"{nonce}\"}}")])
            .stdout(std::os::fd::OwnedFd::from(caller.try_clone().unwrap()))
            .status()
            .unwrap();
        assert!(status.success());
        // Reading before the daemon has decided would make this process the
        // socket's last user again.
        assert!(!worker.join().unwrap());
        let mut answer = String::new();
        reader.read_line(&mut answer).unwrap();
        assert!(answer.contains("caller_not_allowed"), "{answer}");
    }

    #[test]
    fn the_daemon_stops_when_no_one_connects() {
        let directory = std::env::temp_dir().join(format!("niko-daemon-{}", std::process::id()));
        std::fs::create_dir_all(&directory).unwrap();
        let path = directory.join("s");
        let listener = UnixListener::bind(&path).unwrap();
        let started = std::time::Instant::now();
        serve(&listener, REQUIREMENT, Duration::from_millis(100));
        assert!(started.elapsed() >= Duration::from_millis(100));
        let _ = std::fs::remove_dir_all(&directory);
    }

    #[test]
    fn log_times_are_local_iso_8601() {
        let time = now();
        assert_eq!(time.len(), 24, "{time}");
        assert_eq!(&time[10..11], "T");
    }
}
