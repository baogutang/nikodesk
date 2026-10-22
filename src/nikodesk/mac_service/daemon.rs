//! The root daemon (`NikoDesk --nikodesk-service`). launchd starts it at boot
//! and on each connection to its socket; it serves while requests arrive and
//! exits after a short idle time. It only answers callers signed with the
//! fixed certificate, and writes every request to an audit log.
use super::{check_peer, launch_socket, uninstall_steps, Request, Response, REQUIREMENT};
use hbb_common::{bail, libc, ResultType};
use std::{
    io::{BufReader, Write},
    os::{
        fd::{FromRawFd, RawFd},
        unix::net::{UnixListener, UnixStream},
    },
    time::Duration,
};

const AUDIT_DIR: &str = "/Library/Logs/NikoDesk";
const IDLE: Duration = Duration::from_secs(15);

/// Entry from `core_main`, before any NikoDesk initialization: the daemon
/// needs no configuration and must not create one for root.
pub(crate) fn main() -> i32 {
    match run() {
        Ok(()) => 0,
        Err(error) => {
            audit(&format!("stopped error={error}"));
            1
        }
    }
}

fn run() -> ResultType<()> {
    if unsafe { libc::geteuid() } != 0 {
        bail!("root_required");
    }
    let Some(fd) = launch_socket("Listener") else {
        // Started at boot with no one waiting: nothing to do.
        return Ok(());
    };
    let listener = unsafe { UnixListener::from_raw_fd(fd) };
    serve(&listener, REQUIREMENT, IDLE)
}

/// Answers connections until none arrives for `idle`.
fn serve(listener: &UnixListener, requirement: &str, idle: Duration) -> ResultType<()> {
    use std::os::fd::AsRawFd;
    loop {
        if !readable(listener.as_raw_fd(), idle) {
            return Ok(());
        }
        let Ok((stream, _)) = listener.accept() else {
            continue;
        };
        if handle(stream, requirement) {
            return Ok(());
        }
    }
}

fn readable(fd: RawFd, timeout: Duration) -> bool {
    let mut poll = libc::pollfd { fd, events: libc::POLLIN, revents: 0 };
    unsafe { libc::poll(&mut poll, 1, timeout.as_millis() as i32) > 0 }
}

/// Serves one request; true when the daemon should stop afterwards.
fn handle(stream: UnixStream, requirement: &str) -> bool {
    use super::TakeLine;
    use std::os::fd::AsRawFd;
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
    let (response, stop) = match request.op.as_str() {
        "status" => (Response::ok("ready"), false),
        "uninstall" => match remove(peer.euid) {
            Ok(()) => (Response::ok("removed"), true),
            Err(error) => (Response { ok: false, code: "remove_failed".into(), detail: error.to_string() }, false),
        },
        _ => (Response::error("unsupported"), false),
    };
    audit(&format!(
        "op={} caller={:?} euid={} result={}",
        request.op, peer.path, peer.euid, response.code
    ));
    reply(&stream, &response);
    stop
}

fn reply(mut stream: &UnixStream, response: &Response) {
    if let Ok(mut line) = serde_json::to_string(response) {
        line.push('\n');
        let _ = stream.write_all(line.as_bytes());
    }
}

/// Unloads the caller's agent and deletes both jobs. The daemon's own
/// unload, last in the steps, ends this process.
fn remove(uid: u32) -> ResultType<()> {
    let status = std::process::Command::new("/bin/sh")
        .arg("-c")
        .arg(uninstall_steps(uid))
        .status()?;
    if !status.success() {
        bail!("uninstall_steps_failed");
    }
    Ok(())
}

/// Appends one timestamped line; root-owned, readable by administrators.
fn audit(line: &str) {
    append_log("service.log", &format!("{} {line}", hbb_common::chrono::Local::now().to_rfc3339()));
}

/// Appends a line to a file in the service log directory (root only).
pub(crate) fn append_log(name: &str, line: &str) {
    use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
    let _ = std::fs::DirBuilder::new().recursive(true).mode(0o755).create(AUDIT_DIR);
    if let Ok(mut file) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .mode(0o644)
        .custom_flags(libc::O_NOFOLLOW)
        .open(std::path::Path::new(AUDIT_DIR).join(name))
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
        let (daemon, caller) = UnixStream::pair().unwrap();
        let worker = std::thread::spawn(move || handle(daemon, REQUIREMENT));
        let answer = ask(&caller, "{\"op\":\"status\"}\n");
        assert!(answer.contains("caller_not_allowed"));
        assert!(!worker.join().unwrap());
    }

    #[test]
    fn the_daemon_stops_when_no_one_connects() {
        let directory = std::env::temp_dir().join(format!("niko-daemon-{}", std::process::id()));
        std::fs::create_dir_all(&directory).unwrap();
        let path = directory.join("s");
        let listener = UnixListener::bind(&path).unwrap();
        let started = std::time::Instant::now();
        // No connection: serve returns after the idle time.
        serve(&listener, REQUIREMENT, Duration::from_millis(100)).unwrap();
        assert!(started.elapsed() >= Duration::from_millis(100));
        let _ = std::fs::remove_dir_all(&directory);
    }
}
