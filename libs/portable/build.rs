#[cfg(all(windows, feature = "nikodesk"))]
mod version;

fn main() {
    #[cfg(windows)]
    {
        use std::io::Write;
        let mut res = winres::WindowsResource::new();
        #[cfg(feature = "nikodesk")]
        {
            println!("cargo:rerun-if-env-changed=NIKODESK_PRODUCT_VERSION");
            println!("cargo:rerun-if-env-changed=NIKODESK_BUILD_NUMBER");
            println!("cargo:rerun-if-changed=../../flutter/pubspec.yaml");
            println!("cargo:rerun-if-changed=../../flutter/windows/runner/resources/app_icon.ico");
            let explicit = (
                std::env::var("NIKODESK_PRODUCT_VERSION"),
                std::env::var("NIKODESK_BUILD_NUMBER"),
            );
            let declared =
                std::fs::read_to_string("../../flutter/pubspec.yaml").unwrap_or_else(|error| {
                    eprintln!("Cannot read NikoDesk product version: {error}");
                    std::process::exit(1)
                });
            let (name, build) = match &explicit {
                (Ok(name), Ok(build)) => (name.as_str(), build.as_str()),
                (Err(_), Err(_)) => version::pubspec_version(&declared).unwrap_or_else(|error| {
                    eprintln!("{error}");
                    std::process::exit(1)
                }),
                _ => {
                    eprintln!("Supply both NikoDesk product version and build number");
                    std::process::exit(1)
                }
            };
            let (text, numeric) = version::parse_version(name, build).unwrap_or_else(|error| {
                eprintln!("{error}");
                std::process::exit(1)
            });
            res.set_version_info(winres::VersionInfo::FILEVERSION, numeric)
                .set_version_info(winres::VersionInfo::PRODUCTVERSION, numeric)
                .set("FileVersion", &text)
                .set("ProductVersion", &text)
                .set("ProductName", "NikoDesk")
                .set("OriginalFilename", "NikoDesk.exe")
                .set("FileDescription", "NikoDesk Remote Desktop");
            #[cfg(feature = "nikodesk-installer")]
            res.set("FileDescription", "NikoDesk Installation Assistant");
        }
        #[cfg(not(feature = "nikodesk"))]
        res.set_icon("../../res/icon.ico")
            .set_language(winapi::um::winnt::MAKELANGID(
                winapi::um::winnt::LANG_ENGLISH,
                winapi::um::winnt::SUBLANG_ENGLISH_US,
            ))
            .set_manifest_file("../../res/manifest.xml");
        #[cfg(feature = "nikodesk")]
        res.set_icon("../../flutter/windows/runner/resources/app_icon.ico")
            .set_language(winapi::um::winnt::MAKELANGID(
                winapi::um::winnt::LANG_ENGLISH,
                winapi::um::winnt::SUBLANG_ENGLISH_US,
            ))
            .set_manifest_file("nikodesk.manifest");
        match res.compile() {
            Err(e) => {
                write!(std::io::stderr(), "{}", e).unwrap();
                std::process::exit(1);
            }
            Ok(_) => {}
        }
    }
}
