#[cfg(windows)]
fn build_windows() {
    let file = "src/platform/windows.cc";
    let file2 = "src/platform/windows_delete_test_cert.cc";
    cc::Build::new().file(file).file(file2).compile("windows");
    println!("cargo:rustc-link-lib=WtsApi32");
    println!("cargo:rerun-if-changed={}", file);
    println!("cargo:rerun-if-changed={}", file2);
}

#[cfg(target_os = "macos")]
fn build_mac() {
    let file = "src/platform/macos.mm";
    let mut b = cc::Build::new();
    if std::env::var_os("CARGO_FEATURE_NIKODESK").is_some() {
        b.define("NIKODESK_BUILD", None);
        for file in [
            "src/platform/macos_privacy_gamma.h",
            "src/platform/macos_privacy_watchdog_protocol.h",
            "src/platform/macos_privacy_watchdog_state.h",
            "src/platform/macos_privacy_watchdog_client.h",
            "src/platform/macos_privacy_watchdog_spawn.h",
            "src/platform/macos_privacy_watchdog.cpp",
        ] {
            println!("cargo:rerun-if-changed={}", file);
        }
    }
    if let Ok(os_version::OsVersion::MacOS(v)) = os_version::detect() {
        let v = v.version;
        if v.contains("10.14") {
            b.flag("-DNO_InputMonitoringAuthStatus=1");
        }
    }
    b.flag("-std=c++17").file(file).compile("macos");
    if std::env::var_os("CARGO_FEATURE_NIKODESK").is_some() {
        cc::Build::new().cpp(true).file("src/platform/macos_virtual_display.mm")
            .flag("-std=c++17").flag("-fobjc-arc").flag("-fblocks")
            .compile("nikodesk_virtual_display");
        println!("cargo:rustc-link-lib=framework=CoreGraphics");
        println!("cargo:rerun-if-changed=src/platform/macos_virtual_display.mm");
        println!("cargo:rerun-if-changed=src/platform/macos_virtual_display.h");
        cc::Build::new().cpp(true).file("src/platform/macos_background.mm")
            .flag("-fobjc-arc").compile("nikodesk_macos_background");
        println!("cargo:rustc-link-lib=framework=SystemConfiguration");
        println!("cargo:rustc-link-lib=framework=AppKit");
        println!("cargo:rerun-if-changed=src/platform/macos_background.mm");
        cc::Build::new()
            .cpp(true)
            .file("src/nikodesk/voice/macos_permission.mm")
            .flag("-std=c++17")
            .flag("-fobjc-arc")
            .flag("-fblocks")
            .compile("nikodesk_voice_permission");
        println!("cargo:rustc-link-lib=framework=AVFoundation");
        println!("cargo:rustc-link-lib=framework=Foundation");
        println!("cargo:rustc-link-lib=framework=CoreAudio");
        println!("cargo:rerun-if-changed=src/nikodesk/voice/macos_permission.mm");
        println!("cargo:rerun-if-changed=src/nikodesk/voice/macos_permission.h");
    }
    println!("cargo:rerun-if-changed={}", file);
    println!("cargo:rerun-if-changed=src/platform/macos_privacy_transaction.h");
    println!("cargo:rerun-if-changed=src/platform/macos_privacy_bridge.h");
}

#[cfg(all(windows, feature = "inline"))]
fn build_manifest() {
    use std::io::Write;
    if std::env::var("PROFILE").unwrap() == "release" {
        let mut res = winres::WindowsResource::new();
        res.set_icon("res/icon.ico")
            .set_language(winapi::um::winnt::MAKELANGID(
                winapi::um::winnt::LANG_ENGLISH,
                winapi::um::winnt::SUBLANG_ENGLISH_US,
            ))
            .set_manifest_file("res/manifest.xml");
        match res.compile() {
            Err(e) => {
                write!(std::io::stderr(), "{}", e).unwrap();
                std::process::exit(1);
            }
            Ok(_) => {}
        }
    }
}

// bionic only exports getifaddrs()/freeifaddrs() from API 24, while the jniLibs
// are built against the API 21 sysroot (flutter/ndk_*.sh). webrtc-util calls
// them, so without this the android link fails on undefined symbols.
fn build_android_ifaddrs() {
    let file = "src/platform/android_ifaddrs.c";
    cc::Build::new().file(file).compile("android_ifaddrs");
    println!("cargo:rerun-if-changed={}", file);
}

fn install_android_deps() {
    let target_os = std::env::var("CARGO_CFG_TARGET_OS").unwrap();
    if target_os != "android" {
        return;
    }
    let mut target_arch = std::env::var("CARGO_CFG_TARGET_ARCH").unwrap();
    if target_arch == "x86_64" {
        target_arch = "x64".to_owned();
    } else if target_arch == "x86" {
        target_arch = "x86".to_owned();
    } else if target_arch == "aarch64" {
        target_arch = "arm64".to_owned();
    } else {
        target_arch = "arm".to_owned();
    }
    let target = format!("{}-android", target_arch);
    let vcpkg_root = std::env::var("VCPKG_ROOT").unwrap();
    let mut path: std::path::PathBuf = vcpkg_root.into();
    if let Ok(vcpkg_root) = std::env::var("VCPKG_INSTALLED_ROOT") {
        path = vcpkg_root.into();
    } else {
        path.push("installed");
    }
    path.push(target);
    println!(
        "cargo:rustc-link-search={}",
        path.join("lib").to_str().unwrap()
    );
    println!("cargo:rustc-link-lib=ndk_compat");
    println!("cargo:rustc-link-lib=c++");
    println!("cargo:rustc-link-lib=OpenSLES");
}

fn nikodesk_windows_rc(name: &str, parts: [u16; 4]) -> Result<String, String> {
    let description = match name {
        "nikodesk-host" => "NikoDesk privileged background host",
        "nikodesk-setup" => "NikoDesk local setup",
        _ => return Err("Unsupported NikoDesk resource target".into()),
    };
    let [major, minor, patch, build] = parts;
    let version = format!("{major}.{minor}.{patch}.{build}");
    Ok(format!(r#"1 VERSIONINFO
FILEVERSION {major},{minor},{patch},{build}
PRODUCTVERSION {major},{minor},{patch},{build}
FILEFLAGSMASK 0x3fL
FILEFLAGS 0
FILEOS 0x40004L
FILETYPE 0x1L
FILESUBTYPE 0
BEGIN
    BLOCK "StringFileInfo"
    BEGIN
        BLOCK "040904e4"
        BEGIN
            VALUE "CompanyName", "NikoDesk\0"
            VALUE "FileDescription", "{description}\0"
            VALUE "FileVersion", "{version}\0"
            VALUE "OriginalFilename", "{name}.exe\0"
            VALUE "ProductName", "NikoDesk\0"
            VALUE "ProductVersion", "{version}\0"
        END
    END
    BLOCK "VarFileInfo"
    BEGIN
        VALUE "Translation", 0x0409, 1252
    END
END
"#))
}

fn build_nikodesk_windows_resources() -> Result<(), Box<dyn std::error::Error>> {
    use std::{path::PathBuf, process::Command};
    let root = PathBuf::from(std::env::var_os("CARGO_MANIFEST_DIR").ok_or("Missing manifest root")?);
    let helper = root.join(".github/scripts/product-version.py");
    let pubspec = root.join("flutter/pubspec.yaml");
    let python = std::env::var_os("NIKODESK_BUILD_PYTHON").unwrap_or_else(|| "python".into());
    let version = Command::new(python).arg(&helper).arg("--pubspec").arg(&pubspec).output()?;
    if !version.status.success() { return Err("NikoDesk product version validation failed".into()); }
    let value: hbb_common::serde_json::Value = hbb_common::serde_json::from_slice(&version.stdout)?;
    let name = value.get("version_name").and_then(|v| v.as_str()).ok_or("Missing product version")?;
    let mut parts = name.split('.').map(str::parse::<u16>).collect::<Result<Vec<_>, _>>()?;
    let build = value.get("build_number").and_then(|v| v.as_u64())
        .filter(|v| (1..=65535).contains(v)).ok_or("Invalid product build")?;
    if parts.len() != 3 { return Err("Invalid product version".into()); }
    parts.push(build as u16);
    let parts: [u16; 4] = parts.try_into().map_err(|_| "Invalid product version")?;
    let out = PathBuf::from(std::env::var_os("OUT_DIR").ok_or("Missing build output directory")?);
    let manifest = root.join("res/nikodesk-background.manifest");
    let manifest_name = manifest.to_string_lossy().replace('\\', "/");
    if !manifest.is_file() || manifest_name.contains('"') {
        return Err("NikoDesk background manifest unavailable".into());
    }
    // rc.exe comes from the selected Windows SDK, or its configured PATH. No
    // compiler failure may silently produce an unversioned host/setup binary.
    let rc = std::env::var_os("NIKODESK_WINDOWS_RC").map(PathBuf::from)
        .or_else(|| std::env::var_os("WindowsSdkVerBinPath").map(|p| PathBuf::from(p).join("x64/rc.exe")))
        .unwrap_or_else(|| PathBuf::from("rc.exe"));
    if !rc.file_name().is_some_and(|name| name.to_string_lossy().eq_ignore_ascii_case("rc.exe")) {
        return Err("NikoDesk requires the Windows SDK rc.exe resource compiler".into());
    }
    for bin in ["nikodesk-host", "nikodesk-setup"] {
        let source = out.join(format!("{bin}-version.rc"));
        let resource = out.join(format!("{bin}-version.res"));
        let contents = format!("{}\n1 24 \"{}\"\n", nikodesk_windows_rc(bin, parts)?, manifest_name);
        std::fs::write(&source, contents)?;
        let status = Command::new(&rc).arg("/nologo").arg("/fo").arg(&resource).arg(&source).status()?;
        if !status.success() || std::fs::metadata(&resource)?.len() == 0 {
            return Err("NikoDesk Windows version resource compilation failed".into());
        }
        println!("cargo:rustc-link-arg-bin={bin}={}", resource.display());
    }
    println!("cargo:rerun-if-changed={}", helper.display());
    println!("cargo:rerun-if-changed={}", pubspec.display());
    println!("cargo:rerun-if-changed={}", manifest.display());
    println!("cargo:rerun-if-env-changed=NIKODESK_BUILD_PYTHON");
    println!("cargo:rerun-if-env-changed=NIKODESK_WINDOWS_RC");
    println!("cargo:rerun-if-env-changed=WindowsSdkVerBinPath");
    Ok(())
}

fn main() {
    hbb_common::gen_version();
    install_android_deps();
    #[cfg(all(windows, feature = "inline"))]
    build_manifest();
    #[cfg(windows)]
    build_windows();
    let target_os = std::env::var("CARGO_CFG_TARGET_OS").unwrap();
    if target_os == "windows"
        && std::env::var("CARGO_CFG_TARGET_ENV").as_deref() == Ok("msvc")
        && std::env::var_os("CARGO_FEATURE_NIKODESK").is_some()
    {
        // Restrict pre-main imports as well as runtime loads for this privileged
        // binary. Windows 10 RS1+ and the real MSVC payload need separate checks.
        println!("cargo:rustc-link-arg-bin=nikodesk-host=/DEPENDENTLOADFLAG:0xA00");
        println!("cargo:rustc-link-arg-bin=nikodesk-setup=/DEPENDENTLOADFLAG:0xA00");
        if let Err(error) = build_nikodesk_windows_resources() {
            panic!("NikoDesk Windows resources unavailable: {error}");
        }
    }
    if target_os == "macos" {
        #[cfg(target_os = "macos")]
        build_mac();
        println!("cargo:rustc-link-lib=framework=ApplicationServices");
    }
    if target_os == "android" {
        build_android_ifaddrs();
    }
    println!("cargo:rerun-if-changed=build.rs");
}
