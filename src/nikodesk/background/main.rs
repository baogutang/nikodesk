#![cfg_attr(all(not(debug_assertions), windows), windows_subsystem = "windows")]
fn main() {
    if let Err(_error) = librustdesk::nikodesk::background::run(std::env::args().skip(1).collect())
    {
        // No machine identity/config content is printed, even on malformed input.
        eprintln!("NikoDesk background startup failed; no background capability was enabled.");
        std::process::exit(1);
    }
}
