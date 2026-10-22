//! The app's side of the privileged service of phase 3 (docs/PHASE3-DESIGN.md
//! in the workspace). The daemon itself is the separate `nikodesk-service`
//! executable (libs/nikodesk_service), so no root process loads this core.
use hbb_common::{bail, libc, ResultType};
use nikodesk_service::{bundle_allowed, request, Request, Response, INSTALLED_APP, REQUIREMENT};
use std::{
    ffi::{c_char, CStr},
    path::{Path, PathBuf},
};

extern "C" {
    fn NikoLoginWindowProbe(out: *mut c_char, length: usize) -> bool;
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
    nikodesk_service::daemon::append_log("loginwindow-probe.log", &line);
}

/// Both jobs are on disk.
pub(crate) fn installed() -> bool {
    Path::new(&nikodesk_service::daemon_path()).exists() && Path::new(&nikodesk_service::agent_path()).exists()
}

/// `installed`, `app_signed` (the running app carries the fixed certificate),
/// `in_applications` (only /Applications/NikoDesk.app can be serviced),
/// `reachable` and the daemon's `versions` line.
pub(crate) fn state_json() -> String {
    let installed = installed();
    let running = running_bundle().ok();
    let app_signed = running.as_ref().is_some_and(|(bundle, _)| bundle_allowed(bundle, REQUIREMENT));
    let in_applications = running.as_ref().is_some_and(|(bundle, _)| bundle == Path::new(INSTALLED_APP));
    let status = installed.then(|| call("status", "")).filter(|response| response.ok);
    serde_json::json!({
        "installed": installed,
        "app_signed": app_signed,
        "in_applications": in_applications,
        "reachable": status.is_some(),
        "versions": status.map(|response| response.detail).unwrap_or_default(),
    })
    .to_string()
}

/// One daemon operation the app may ask for; the answer as JSON.
pub(crate) fn call_json(op: &str, bundle: &str) -> String {
    serde_json::to_string(&call(op, bundle)).unwrap_or_default()
}

fn call(op: &str, bundle: &str) -> Response {
    if !matches!(op, "status" | "install_update" | "restore_update" | "sync") {
        return Response::error("unsupported");
    }
    request(&Request { op: op.into(), bundle: bundle.into(), ..Default::default() }).unwrap_or_else(|_| Response::error("unreachable"))
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

/// Installs the service after the system administrator prompt. Refuses an
/// app outside /Applications or not signed with the fixed certificate: root
/// runs a checked copy of it, and only that location is updated.
pub(crate) fn install() -> ResultType<()> {
    let (bundle, _) = running_bundle()?;
    if bundle != Path::new(INSTALLED_APP) {
        bail!("app_not_in_applications");
    }
    if !bundle_allowed(&bundle, REQUIREMENT) {
        bail!("app_not_signed_with_nikodesk_certificate");
    }
    let uid = unsafe { libc::getuid() };
    run_admin(
        &nikodesk_service::install_steps(uid),
        "NikoDesk wants to install its background service.",
    )
}

/// Removes the service through the daemon (no password), or after the
/// administrator prompt if the daemon cannot be reached.
pub(crate) fn uninstall() -> ResultType<()> {
    match request(&Request { op: "uninstall".into(), ..Default::default() }) {
        Ok(response) if response.ok => Ok(()),
        _ => {
            let uid = unsafe { libc::getuid() };
            run_admin(&nikodesk_service::uninstall_steps(uid), "NikoDesk wants to remove its background service.")
        }
    }
}

fn run_admin(steps: &str, prompt: &str) -> ResultType<()> {
    let status = std::process::Command::new("/usr/bin/osascript")
        .arg("-e")
        .arg(nikodesk_service::admin_script(steps, prompt))
        .status()?;
    if !status.success() {
        bail!("administrator_step_failed_or_cancelled");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

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
    fn the_app_may_only_ask_for_its_own_operations() {
        assert_eq!(call("uninstall", "").code, "unsupported", "removal goes through uninstall()");
        assert_eq!(call("anything", "").code, "unsupported");
        let state: serde_json::Value = serde_json::from_str(&state_json()).unwrap();
        for key in ["installed", "app_signed", "in_applications", "reachable", "versions"] {
            assert!(state.get(key).is_some(), "{key} missing");
        }
    }
}
