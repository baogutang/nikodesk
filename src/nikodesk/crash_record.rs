//! Local crash records and a redacted diagnostics bundle. Nothing here sends
//! anything anywhere: the user saves the bundle themselves.
use hbb_common::{config::Config, log};
use std::{
    fs,
    io::{Read, Seek, SeekFrom, Write},
    path::{Path, PathBuf},
    time::{SystemTime, UNIX_EPOCH},
};

const MARKER: &str = "nikodesk-crash-marker.json";
const SEEN: &str = "nikodesk-crash-marker.seen.json";
const LOG_TAIL_BYTES: u64 = 192 * 1024;
const REPORT_HEAD_BYTES: usize = 8 * 1024;
const MAX_REPORTS: usize = 3;

fn marker_path(name: &str) -> PathBuf {
    Config::file().with_file_name(name)
}

/// Records every Rust panic in the log file and in a small marker the app
/// shows once at its next start. Panics used to reach only stderr, which a
/// desktop app throws away.
pub(crate) fn install() {
    static ONCE: std::sync::Once = std::sync::Once::new();
    ONCE.call_once(|| {
        let previous = std::panic::take_hook();
        std::panic::set_hook(Box::new(move |info| {
            record(info);
            previous(info);
        }));
    });
}

fn record(info: &std::panic::PanicHookInfo) {
    let message = info
        .payload()
        .downcast_ref::<&str>()
        .map(|text| text.to_string())
        .or_else(|| info.payload().downcast_ref::<String>().cloned())
        .unwrap_or_default();
    let location = info
        .location()
        .map(|at| format!("{}:{}", at.file(), at.line()))
        .unwrap_or_default();
    let thread = std::thread::current()
        .name()
        .unwrap_or("unnamed")
        .to_owned();
    let message: String = redact(&message).chars().take(512).collect();
    log::error!("panic in thread {thread} at {location}: {message}");
    let marker = serde_json::json!({
        "time": SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_or(0, |elapsed| elapsed.as_secs()),
        "core": crate::VERSION,
        "thread": thread,
        "location": location,
        "message": message,
    });
    // No locks are taken here: the panic may have happened while one was held.
    let _ = write_private(&marker_path(MARKER), marker.to_string().as_bytes());
}

fn write_private(path: &Path, contents: &[u8]) -> std::io::Result<()> {
    let temporary = path.with_extension("json.tmp");
    let mut options = fs::OpenOptions::new();
    options.write(true).create(true).truncate(true);
    #[cfg(unix)]
    std::os::unix::fs::OpenOptionsExt::mode(&mut options, 0o600);
    let mut file = options.open(&temporary)?;
    file.write_all(contents)?;
    file.sync_all()?;
    fs::rename(temporary, path)
}

/// The marker of an unseen crash, once: it is kept as "seen" for the
/// diagnostics bundle. Empty when there is none.
pub fn take_marker() -> String {
    let path = marker_path(MARKER);
    let Ok(contents) = fs::read_to_string(&path) else {
        return String::new();
    };
    let _ = fs::rename(&path, marker_path(SEEN));
    if contents.len() > 4096 {
        return String::new();
    }
    contents
}

/// IPv4 and IPv6 addresses, long digit runs (device IDs) and UUIDs.
pub(crate) fn redact(text: &str) -> String {
    use std::sync::OnceLock;
    static PATTERNS: OnceLock<Vec<(hbb_common::regex::Regex, &str)>> = OnceLock::new();
    let patterns = PATTERNS.get_or_init(|| {
        [
            (
                r"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b",
                "<uuid>",
            ),
            (r"\b(?:\d{1,3}\.){3}\d{1,3}(?::\d{1,5})?\b", "<ip>"),
            // Full and "::" shortened IPv6, without touching times (13:02:53)
            // or Rust paths (std::sync).
            (r"(?i)\b(?:[0-9a-f]{1,4}:){7}[0-9a-f]{1,4}\b", "<ip6>"),
            (
                r"(?i)\b(?:[0-9a-f]{1,4}:){1,6}:(?:[0-9a-f]{1,4}:){0,5}[0-9a-f]{1,4}\b",
                "<ip6>",
            ),
            (r"\b\d{8,12}\b", "<id>"),
        ]
        .into_iter()
        .filter_map(|(pattern, replacement)| {
            hbb_common::regex::Regex::new(pattern).ok().map(|re| (re, replacement))
        })
        .collect()
    });
    let mut text = text.to_owned();
    for (pattern, replacement) in patterns {
        text = pattern.replace_all(&text, *replacement).into_owned();
    }
    text
}

fn tail(path: &Path, bytes: u64) -> Option<String> {
    let mut file = fs::File::open(path).ok()?;
    let length = file.metadata().ok()?.len();
    file.seek(SeekFrom::Start(length.saturating_sub(bytes))).ok()?;
    let mut buffer = Vec::new();
    file.take(bytes).read_to_end(&mut buffer).ok()?;
    let text = String::from_utf8_lossy(&buffer);
    // Start at a whole line.
    let text = match text.find('\n') {
        Some(index) if length > bytes => &text[index + 1..],
        _ => &text[..],
    };
    Some(redact(text))
}

/// The newest log file of the main process and of each component directory
/// (connection manager, background agent).
fn logs() -> serde_json::Map<String, serde_json::Value> {
    let root = Config::log_path();
    let mut found = serde_json::Map::new();
    let mut directories = vec![root.clone()];
    if let Ok(entries) = fs::read_dir(&root) {
        directories.extend(
            entries
                .flatten()
                .map(|entry| entry.path())
                .filter(|path| path.is_dir()),
        );
    }
    for directory in directories {
        let newest = fs::read_dir(&directory).ok().and_then(|entries| {
            entries
                .flatten()
                .map(|entry| entry.path())
                .filter(|path| path.extension().is_some_and(|ext| ext == "log"))
                .max_by_key(|path| fs::metadata(path).and_then(|m| m.modified()).ok())
        });
        let Some(newest) = newest else { continue };
        let name = newest
            .strip_prefix(&root)
            .unwrap_or(&newest)
            .to_string_lossy()
            .into_owned();
        if let Some(text) = tail(&newest, LOG_TAIL_BYTES) {
            found.insert(name, text.into());
        }
    }
    found
}

/// Heads of the newest macOS crash reports of this app only.
fn crash_reports() -> Vec<serde_json::Value> {
    #[cfg(target_os = "macos")]
    {
        let directory = PathBuf::from(std::env::var("HOME").unwrap_or_default())
            .join("Library/Logs/DiagnosticReports");
        let mut reports: Vec<PathBuf> = fs::read_dir(directory)
            .map(|entries| {
                entries
                    .flatten()
                    .map(|entry| entry.path())
                    .filter(|path| {
                        path.file_name()
                            .and_then(|name| name.to_str())
                            .is_some_and(|name| {
                                (name.starts_with("NikoDesk-") || name.starts_with("NikoDesk_"))
                                    && (name.ends_with(".ips") || name.ends_with(".crash"))
                            })
                    })
                    .collect()
            })
            .unwrap_or_default();
        reports.sort_by_key(|path| {
            std::cmp::Reverse(fs::metadata(path).and_then(|m| m.modified()).ok())
        });
        return reports
            .into_iter()
            .take(MAX_REPORTS)
            .filter_map(|path| {
                let text = fs::read(&path).ok()?;
                let head = String::from_utf8_lossy(&text[..text.len().min(REPORT_HEAD_BYTES)])
                    .into_owned();
                Some(serde_json::json!({
                    "name": path.file_name()?.to_string_lossy(),
                    "head": redact(&head),
                }))
            })
            .collect();
    }
    #[allow(unreachable_code)]
    Vec::new()
}

/// Everything the diagnostics bundle needs from the native side, as JSON.
pub fn bundle() -> String {
    let marker = |name| {
        fs::read_to_string(marker_path(name))
            .ok()
            .and_then(|text| serde_json::from_str::<serde_json::Value>(&text).ok())
    };
    serde_json::json!({
        "core": crate::VERSION,
        "buildDate": crate::BUILD_DATE,
        "os": std::env::consts::OS,
        "arch": std::env::consts::ARCH,
        "osVersion": hbb_common::sysinfo::System::new().long_os_version(),
        "crashMarker": marker(MARKER).or_else(|| marker(SEEN)),
        "crashReports": crash_reports(),
        "logs": logs(),
        "redaction": "IPv4/IPv6 addresses, UUIDs and 8-12 digit numbers (device IDs) are replaced.",
    })
    .to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn addresses_ids_and_uuids_are_removed() {
        let text = "from 192.168.31.126:51600 to fe80::1c2b:3a4d:5e6f:7a8b id 148660849 \
                    uuid dcc7dec1-92e7-47ef-be1e-0123456789ab at 3.1ms of 1920x1080";
        let clean = redact(text);
        assert!(!clean.contains("192.168"));
        assert!(!clean.contains("fe80"));
        assert!(!clean.contains("148660849"));
        assert!(!clean.contains("dcc7dec1"));
        assert!(clean.contains("3.1ms of 1920x1080"));
        let kept = "[2026-10-17 13:02:53.606980 +08:00] INFO [src/server/connection.rs:5425] std::sync";
        assert_eq!(redact(kept), kept);
    }

    #[test]
    fn a_log_tail_starts_at_a_whole_line_and_is_redacted() {
        let directory = std::env::temp_dir().join(format!("niko-tail-{}", std::process::id()));
        fs::create_dir_all(&directory).unwrap();
        let path = directory.join("a.log");
        fs::write(&path, "first line 10.0.0.1\nsecond line\nthird 10.0.0.2\n").unwrap();
        let text = tail(&path, 20).unwrap();
        assert!(!text.starts_with("line"));
        assert!(text.contains("<ip>"));
        fs::remove_dir_all(directory).unwrap();
    }
}
