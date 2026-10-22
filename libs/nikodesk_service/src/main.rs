//! `nikodesk-service`: the root daemon, started by launchd from the
//! root-owned copy of the app (see the library documentation).
fn main() {
    #[cfg(target_os = "macos")]
    std::process::exit(nikodesk_service::daemon::main());
}
