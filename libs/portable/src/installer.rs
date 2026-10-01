//! A separate, ordinary-user bootstrap. Only the real GUI may request installation.
#[cfg(test)]
use crate::bin_reader::BinaryData;
use crate::bin_reader::BinaryReader;
use std::{
    collections::BTreeSet,
    fs::{self, OpenOptions},
    io::{Cursor, Read, Write},
    path::{Path, PathBuf},
    process::Command,
    time::{SystemTime, UNIX_EPOCH},
};

const MAX_FILE: u64 = 512 * 1024 * 1024;
const MAX_TOTAL: u64 = 2 * 1024 * 1024 * 1024;
const MAX_ENTRIES: usize = 8192;
const REQUIRED: [&str; 6] = [
    "nikodesk.exe",
    "nikodesk-host.exe",
    "nikodesk-setup.exe",
    "setup-release.json",
    "librustdesk.dll",
    "flutter_windows.dll",
];

fn relative_path(text: &str) -> Result<PathBuf, String> {
    let normalized = text.replace('\\', "/");
    let normalized = normalized.strip_prefix("./").unwrap_or(&normalized);
    if normalized.is_empty() || normalized.len() > 1024 {
        return Err("Invalid installer path".into());
    }
    let mut result = PathBuf::new();
    for part in normalized.split('/') {
        let stem = part.split('.').next().unwrap_or("").to_ascii_uppercase();
        if part.is_empty()
            || part == "."
            || part == ".."
            || part.ends_with(['.', ' '])
            || part
                .chars()
                .any(|c| c.is_control() || ":\"<>|?*".contains(c))
            || matches!(stem.as_str(), "CON" | "PRN" | "AUX" | "NUL" | "CLOCK$")
            || (stem.len() == 4
                && (stem.starts_with("COM") || stem.starts_with("LPT"))
                && matches!(stem.as_bytes()[3], b'1'..=b'9'))
        {
            return Err("Unsafe installer path".into());
        }
        result.push(part);
    }
    Ok(result)
}

fn validate(reader: &BinaryReader) -> Result<(), String> {
    if relative_path(&reader.exe)? != Path::new("NikoDesk.exe")
        || reader.files.is_empty()
        || reader.files.len() > MAX_ENTRIES
    {
        return Err("The installer does not contain the complete NikoDesk application".into());
    }
    let mut paths = BTreeSet::new();
    let mut directories = BTreeSet::new();
    for file in &reader.files {
        let path = relative_path(&file.path)?;
        let key = path.to_string_lossy().replace('\\', "/").to_lowercase();
        if !paths.insert(key)
            || file.md5_code.len() != 32
            || !file
                .md5_code
                .iter()
                .all(|v| v.is_ascii_digit() || (b'a'..=b'f').contains(v))
        {
            return Err("Duplicate installer file or invalid content record".into());
        }
        let mut parent = path.parent();
        while let Some(path) = parent.filter(|p| !p.as_os_str().is_empty()) {
            directories.insert(path.to_string_lossy().replace('\\', "/").to_lowercase());
            parent = path.parent();
        }
    }
    if paths.intersection(&directories).next().is_some()
        || REQUIRED.iter().any(|name| !paths.contains(*name))
    {
        return Err("Incomplete or conflicting installer content".into());
    }
    Ok(())
}

fn ordinary_directory(path: &Path) -> Result<(), String> {
    let metadata = fs::symlink_metadata(path).map_err(|_| "Cannot read installer directory")?;
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        if metadata.file_attributes() & 0x400 != 0 {
            return Err("Installer directory is a reparse point".into());
        }
    }
    if !metadata.is_dir() || metadata.file_type().is_symlink() {
        return Err("Installer directory must be an ordinary local directory".into());
    }
    Ok(())
}

fn ensure_directories(path: &Path) -> Result<(), String> {
    if let Some(parent) = path.parent().filter(|p| !p.as_os_str().is_empty()) {
        ensure_directories(parent)?;
    }
    match fs::create_dir(path) {
        Ok(()) => ordinary_directory(path),
        Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => ordinary_directory(path),
        Err(_) => {
            Err("Cannot create installer directory. Check disk space and permissions.".into())
        }
    }
}

fn new_directory(base: &Path) -> Result<PathBuf, String> {
    ensure_directories(base)?;
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| "Cannot obtain installer timestamp")?
        .as_nanos();
    for attempt in 0..16 {
        let path = base.join(format!("package-{}-{now}-{attempt}", std::process::id()));
        match fs::create_dir(&path) {
            Ok(()) => {
                ordinary_directory(&path)?;
                return Ok(path);
            }
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(_) => return Err("Cannot create a new installer workspace".into()),
        }
    }
    Err("Cannot allocate an independent installer workspace".into())
}

fn extract(reader: &BinaryReader, directory: &Path) -> Result<(), String> {
    validate(reader)?;
    ordinary_directory(directory)?;
    let mut total = 0u64;
    for file in &reader.files {
        let remaining = MAX_FILE.min(MAX_TOTAL.saturating_sub(total));
        let mut decoder =
            brotli::Decompressor::new(Cursor::new(file.raw), 4096).take(remaining + 1);
        let mut bytes = Vec::new();
        decoder
            .read_to_end(&mut bytes)
            .map_err(|_| "Installer content could not be decompressed")?;
        if bytes.len() as u64 > remaining
            || format!("{:x}", md5::compute(&bytes)).as_bytes() != file.md5_code
        {
            return Err("Installer content is damaged or exceeds its size limit".into());
        }
        total += bytes.len() as u64;
        let destination = directory.join(relative_path(&file.path)?);
        if let Some(parent) = destination.parent() {
            ensure_directories(parent)?;
        }
        let mut output = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&destination)
            .map_err(|_| "Cannot create installer file; existing files are preserved")?;
        output
            .write_all(&bytes)
            .and_then(|_| output.flush())
            .map_err(|_| "Could not write installer content. Check disk space and permissions.")?;
    }
    Ok(())
}

fn launch_command(directory: &Path) -> Command {
    let mut command = Command::new(directory.join("NikoDesk.exe"));
    command
        .current_dir(directory)
        .env("NIKODESK_SETUP_ASSISTANT", "1");
    command
}

#[cfg(windows)]
pub(super) fn run() -> Result<(), String> {
    if std::env::args_os().len() != 1 {
        return Err(
            "Open the NikoDesk installer directly; command-line installation is unsupported".into(),
        );
    }
    let class: Vec<_> = "FLUTTER_RUNNER_WIN32_WINDOW"
        .encode_utf16()
        .chain(Some(0))
        .collect();
    let title: Vec<_> = "NikoDesk".encode_utf16().chain(Some(0)).collect();
    if !unsafe { winapi::um::winuser::FindWindowW(class.as_ptr(), title.as_ptr()) }.is_null() {
        return Err("请先关闭正在运行的 NikoDesk，再打开安装程序。\nClose the running NikoDesk client, then open this installer again.".into());
    }
    let reader = BinaryReader::installer_embedded()?;
    validate(&reader)?;
    let base = dirs::data_local_dir()
        .ok_or("Cannot locate the current user's application data")?
        .join("NikoDeskInstallers");
    let directory = new_directory(&base)?;
    extract(&reader, &directory)?;
    // Keep this new directory for explicit retry; never overwrite or delete a running client.
    let status = launch_command(&directory)
        .status()
        .map_err(|_| "Could not open NikoDesk. Close the existing client and try again.")?;
    if !status.success() {
        return Err("NikoDesk could not start. Close the existing client and try again.".into());
    }
    Ok(())
}

#[cfg(not(windows))]
pub(super) fn run() -> Result<(), String> {
    Err("The NikoDesk installer requires Windows".into())
}

#[cfg(test)]
mod tests {
    use super::*;
    fn file(path: &str, content: &[u8]) -> BinaryData {
        let mut compressed = Vec::new();
        {
            let mut encoder = brotli::CompressorWriter::new(&mut compressed, 4096, 3, 22);
            encoder.write_all(content).unwrap();
        }
        BinaryData {
            path: path.into(),
            raw: Box::leak(compressed.into_boxed_slice()),
            md5_code: Box::leak(
                format!("{:x}", md5::compute(content))
                    .into_bytes()
                    .into_boxed_slice(),
            ),
        }
    }
    fn reader() -> BinaryReader {
        let mut files: Vec<_> = REQUIRED
            .iter()
            .map(|name| file(name, name.as_bytes()))
            .collect();
        files[0].path = "./NikoDesk.exe".into();
        files.push(file(
            "./data/flutter_assets/test.txt",
            b"actual brotli roundtrip",
        ));
        BinaryReader {
            files,
            exe: "./NikoDesk.exe".into(),
            package_paths: Vec::new(),
        }
    }
    #[test]
    fn complete_package_extracts_in_new_directory_and_only_prepares_ordinary_gui() {
        let base = std::env::temp_dir()
            .canonicalize()
            .unwrap()
            .join(format!("niko-installer-test-{}", std::process::id()));
        let first = new_directory(&base).unwrap();
        let second = new_directory(&base).unwrap();
        assert_ne!(first, second);
        extract(&reader(), &first).unwrap();
        assert_eq!(
            fs::read(first.join("data/flutter_assets/test.txt")).unwrap(),
            b"actual brotli roundtrip"
        );
        let command = launch_command(&first);
        assert_eq!(command.get_program(), first.join("NikoDesk.exe"));
        assert_eq!(command.get_args().count(), 0);
        assert!(command
            .get_envs()
            .any(|(key, value)| key == "NIKODESK_SETUP_ASSISTANT" && value == Some("1".as_ref())));
        fs::remove_dir_all(base).unwrap();
    }
    #[test]
    fn existing_file_or_corrupt_content_never_becomes_a_successful_extraction() {
        let base = std::env::temp_dir()
            .canonicalize()
            .unwrap()
            .join(format!("niko-installer-fail-{}", std::process::id()));
        let directory = new_directory(&base).unwrap();
        fs::write(directory.join("NikoDesk.exe"), b"preserve existing").unwrap();
        assert!(extract(&reader(), &directory).is_err());
        assert_eq!(
            fs::read(directory.join("NikoDesk.exe")).unwrap(),
            b"preserve existing"
        );
        let other = new_directory(&base).unwrap();
        let mut damaged = reader();
        damaged.files[0].raw = b"broken stream";
        assert!(extract(&damaged, &other).is_err());
        assert!(!other.join("NikoDesk.exe").exists());
        fs::remove_dir_all(base).unwrap();
    }
    #[test]
    fn unsafe_paths_duplicate_files_missing_setup_and_file_directory_collision_refuse() {
        for path in [
            "../escape",
            "/absolute",
            "C:relative",
            "C:/absolute",
            "\\\\host\\share",
            "NUL.txt",
            "a./b",
            "a//b",
            "a:b",
        ] {
            assert!(relative_path(path).is_err(), "{path}");
        }
        let mut duplicate = reader();
        duplicate.files.push(file("nikodesk.EXE", b"shadow"));
        assert!(validate(&duplicate).is_err());
        let mut missing = reader();
        missing.files.retain(|f| f.path != "nikodesk-setup.exe");
        assert!(validate(&missing).is_err());
        let mut conflict = reader();
        conflict.files.push(file("data", b"conflict"));
        assert!(validate(&conflict).is_err());
    }
    #[cfg(unix)]
    #[test]
    fn installer_refuses_a_symlink_directory() {
        let base = std::env::temp_dir()
            .canonicalize()
            .unwrap()
            .join(format!("niko-installer-link-{}", std::process::id()));
        let directory = new_directory(&base).unwrap();
        let link = base.join("link");
        std::os::unix::fs::symlink(directory, &link).unwrap();
        assert!(new_directory(&link).is_err());
        fs::remove_dir_all(base).unwrap();
    }
}
