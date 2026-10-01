#![cfg_attr(all(not(debug_assertions), windows), windows_subsystem = "windows")]

#[cfg(windows)]
#[path = "install/mod.rs"]
mod install;

#[cfg(windows)]
fn main() {
    let result = (|| -> hbb_common::anyhow::Result<()> {
        let runtime = hbb_common::tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()?;
        runtime.block_on(install::broker::run(std::env::args_os().skip(1).collect()))
    })();
    if result.is_err() {
        eprintln!("NikoDesk setup did not complete; inspect its original local recovery state.");
        std::process::exit(1);
    }
}

#[cfg(not(windows))]
fn main() {
    eprintln!("NikoDesk setup is supported on Windows only.");
    std::process::exit(1);
}
