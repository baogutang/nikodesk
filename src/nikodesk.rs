//! NikoDesk's local identity and private-server policy. This module is feature gated.
use hbb_common::{
    anyhow::{anyhow, Context},
    bail,
    config::{self, Config},
    rand::{self, Rng},
    sodiumoxide::{self, base64, crypto::sign},
    toml, ResultType,
};
use serde::{Deserialize, Serialize};
use std::{
    collections::HashMap,
    net::IpAddr,
    sync::{
        atomic::{AtomicBool, Ordering},
        Mutex, OnceLock,
    },
};

static INITIALIZED: OnceLock<Result<(), String>> = OnceLock::new();
static SETTINGS_WRITING: AtomicBool = AtomicBool::new(false);
static SETTINGS_SAVE_FAILED: AtomicBool = AtomicBool::new(false);
static SETTINGS_WRITE_LOCK: Mutex<()> = Mutex::new(());

#[path = "nikodesk/server_settings.rs"]
pub mod server_settings;

#[path = "nikodesk/server_scope.rs"]
pub mod server_scope;

#[path = "nikodesk/connection_snapshot.rs"]
pub mod connection_snapshot;
#[path = "nikodesk/online_status.rs"]
pub(crate) mod online_status;
#[path = "nikodesk/online_query.rs"]
pub(crate) mod online_query;
pub(crate) mod totp_replay;
pub(crate) mod session_audit;
pub(crate) mod capability_audit;
pub(crate) mod virtual_driver;

#[path = "nikodesk/favorites.rs"]
pub mod favorites;
#[path = "nikodesk/peer_migration.rs"]
pub mod peer_migration;
#[cfg(not(any(target_os="android",target_os="ios")))]
#[path = "nikodesk/cm_peer.rs"]
pub(crate) mod cm_peer;
pub(crate) mod cm_permissions;
#[path = "nikodesk/connection_capabilities.rs"]
pub(crate) mod connection_capabilities;
#[path = "nikodesk/camera_flow.rs"]
pub(crate) mod camera_flow;
#[path = "nikodesk/camera_probe.rs"]
pub(crate) mod camera_probe;
#[cfg(any(target_os = "macos", target_os = "windows"))]
#[path = "nikodesk/owned_camera.rs"]
pub(crate) mod owned_camera;
#[cfg(any(target_os = "windows", test))]
#[path = "nikodesk/windows_compatibility.rs"]
pub(crate) mod windows_compatibility;
#[cfg(not(any(target_os = "android", target_os = "ios")))]
#[path = "nikodesk/owned_terminal.rs"]
pub(crate) mod owned_terminal;
#[path = "nikodesk/capability_state.rs"]
pub(crate) mod capability_state;
#[path = "nikodesk/capability_policy.rs"]
pub(crate) mod capability_policy;
#[path = "nikodesk/capability_policy_api.rs"]
pub(crate) mod capability_policy_api;
#[path = "nikodesk/background/mod.rs"]
pub mod background;
#[cfg(feature = "flutter")]
#[path = "nikodesk/unattended_install.rs"]
pub(crate) mod unattended_install;
#[cfg(feature = "flutter")]
#[path = "nikodesk/session_power.rs"]
pub(crate) mod session_power;
#[cfg(any(target_os = "macos", target_os = "windows"))]
#[path = "nikodesk/auto_lock.rs"]
pub(crate) mod auto_lock;
#[path = "nikodesk/wol_proxy.rs"]
pub(crate) mod wol_proxy;
#[path = "nikodesk/credentials.rs"]
pub(crate) mod credentials;

#[cfg(windows)]
#[path = "nikodesk/privacy_windows.rs"]
pub(crate) mod privacy_windows;
#[cfg(any(target_os = "macos", target_os = "windows"))]
#[path = "nikodesk/virtual_display.rs"]
pub(crate) mod virtual_display;
#[cfg(target_os = "macos")]
#[path = "nikodesk/mac_background.rs"]
pub(crate) mod mac_background;
#[cfg(not(any(target_os = "android", target_os = "ios")))]
#[path = "nikodesk/terminal_cleanup.rs"]
pub(crate) mod terminal_cleanup;
#[path = "nikodesk/tunnel_endpoint.rs"]
pub(crate) mod tunnel_endpoint;
#[path = "nikodesk/tunnel_transport.rs"]
pub(crate) mod tunnel_transport;
#[path = "nikodesk/tunnel_flow.rs"]
pub(crate) mod tunnel_flow;
#[path = "nikodesk/tunnel_wire.rs"]
pub(crate) mod tunnel_wire;
#[path = "nikodesk/tunnel_actor.rs"]
pub(crate) mod tunnel_actor;
#[path = "nikodesk/video_metrics.rs"]
pub(crate) mod video_metrics;
#[path = "nikodesk/voice/mod.rs"]
pub(crate) mod voice;
#[path = "nikodesk/voice_wire.rs"]
pub(crate) mod voice_wire;
#[path = "nikodesk/voice_policy.rs"]
pub(crate) mod voice_policy;
#[path = "nikodesk/voice_flow.rs"]
pub(crate) mod voice_flow;
#[path = "nikodesk/voice_runtime.rs"]
pub(crate) mod voice_runtime;
#[path = "nikodesk/voice_call.rs"]
pub(crate) mod voice_call;
#[path = "nikodesk/voice_start.rs"]
pub(crate) mod voice_start;
#[cfg(feature="flutter")]
#[path = "nikodesk/voice_session.rs"]
pub(crate) mod voice_session;
#[cfg(feature = "flutter")]
#[path = "nikodesk/voice_bridge.rs"]
pub(crate) mod voice_bridge;

pub fn initialize() -> ResultType<()> {
    INITIALIZED
        .get_or_init(|| initialize_inner().map_err(|e| e.to_string()))
        .clone()
        .map_err(|e| anyhow!(e))
}

pub fn initialize_or_exit() {
    if let Err(err) = initialize() {
        eprintln!("NikoDesk stopped: {err}");
        std::process::exit(1);
    }
}

/// Dedicated worker bootstrap. Callers must already have a kernel-verified,
/// protected installation/SCM grant; the ordinary initialize stays non-elevated.
#[cfg(windows)]
pub(crate) fn initialize_system_desktop_worker(root: std::path::PathBuf) -> ResultType<()> {
    if !background::is_system_worker() { bail!("Not a granted system desktop worker"); }
    let profile = background::read_machine_runtime(&root)?;
    let id = profile.public_id().to_owned();
    let public_key = profile.public_key().to_vec();
    Config::initialize_trusted_machine_runtime(root, profile)?;
    INITIALIZED.get_or_init(|| (|| -> ResultType<()> {
        *config::APP_NAME.write().unwrap() = "NikoDesk".into();
        sodiumoxide::init().map_err(|_| anyhow!("Cannot initialize machine cryptography"))?;
        install_policy();
        {
            let mut hard = config::HARD_SETTINGS.write().unwrap();
            hard.insert("conn-type".into(), "incoming".into());
        }
        {
            let mut forced = config::OVERWRITE_SETTINGS.write().unwrap();
            for key in ["enable-clipboard", "enable-file-transfer", "enable-audio", "enable-remote-printer", "enable-record-session", "enable-trusted-devices", "allow-remote-config-modification"] {
                forced.insert(key.into(), "N".into());
            }
            forced.insert("approve-mode".into(), "password".into());
            forced.insert("verification-method".into(), "use-permanent-password".into());
        }
        let loaded = Config::get();
        if loaded.id != id || Config::get_key_pair().1 != public_key {
            bail!("Machine identity did not match the provisioned file");
        }
        if !Config::has_local_permanent_password() { bail!("Machine desktop verifier has not been provisioned"); }
        validate_server_values(&Config::get_option("custom-rendezvous-server"), &Config::get_option("relay-server"), &Config::get_option("key"))?;
        if Config::get_option("stop-service") != "N" { bail!("Machine background policy is paused"); }
        Ok(())
    })().map_err(|error| error.to_string())).clone().map_err(|error| anyhow!(error))
}

/// Keys the configuration directory, log directory and IPC path.
pub(crate) fn app_name() -> ResultType<String> {
    // Local end-to-end tests run extra, fully separate identities on one
    // machine. Only builds that opt into the feature honour the variable, and
    // an invalid value stops the process instead of using the real identity.
    #[cfg(feature = "nikodesk-dev-profile")]
    if let Ok(profile) = std::env::var("NIKODESK_DEV_PROFILE") {
        if !(1..=16).contains(&profile.len())
            || !profile
                .bytes()
                .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit())
        {
            bail!("Invalid NIKODESK_DEV_PROFILE");
        }
        return Ok(format!("NikoDesk-{profile}"));
    }
    Ok("NikoDesk".to_owned())
}

/// Local end-to-end runs have nobody at the controlled side to click. In a
/// development profile, NIKODESK_DEV_AUTO_APPROVE names the capabilities the
/// real connection manager may approve by itself; the decision still travels
/// its normal verified path. Never compiled into a packaged build.
#[cfg(feature = "nikodesk-dev-profile")]
pub(crate) fn dev_auto_approves(kind: &str, request: &str) -> bool {
    // A request stays pending across several status updates; answer it once,
    // as a person clicking the button would.
    static ANSWERED: std::sync::Mutex<Vec<String>> = std::sync::Mutex::new(Vec::new());
    if std::env::var("NIKODESK_DEV_PROFILE").is_err()
        || !std::env::var("NIKODESK_DEV_AUTO_APPROVE")
            .is_ok_and(|kinds| kinds.split(',').any(|value| value == kind))
    {
        return false;
    }
    let Ok(mut answered) = ANSWERED.lock() else {
        return false;
    };
    let key = format!("{kind}/{request}");
    if answered.contains(&key) {
        return false;
    }
    answered.push(key);
    true
}

/// Where the controlled side spends its time per frame, for local measurement
/// runs. Logged every five seconds while frames flow; development builds only.
#[cfg(feature = "nikodesk-dev-profile")]
#[derive(Default)]
pub(crate) struct DevVideoStages {
    frames: u32,
    capture: std::time::Duration,
    convert: std::time::Duration,
    encode: std::time::Duration,
    since: Option<std::time::Instant>,
}
#[cfg(feature = "nikodesk-dev-profile")]
impl DevVideoStages {
    /// `capture` includes waiting for the screen to change.
    pub(crate) fn add(
        &mut self,
        capture: std::time::Duration,
        convert: std::time::Duration,
        encode: std::time::Duration,
    ) {
        self.frames += 1;
        self.capture += capture;
        self.convert += convert;
        self.encode += encode;
        let since = *self.since.get_or_insert_with(std::time::Instant::now);
        if since.elapsed() >= std::time::Duration::from_secs(5) {
            let average = |total: std::time::Duration| total.as_secs_f64() * 1000. / self.frames as f64;
            hbb_common::log::info!(
                "dev video stages: frames={} in {:.1}s, wait+capture={:.1}ms convert={:.1}ms encode+send={:.1}ms",
                self.frames,
                since.elapsed().as_secs_f64(),
                average(self.capture),
                average(self.convert),
                average(self.encode),
            );
            *self = Self::default();
        }
    }
}

#[cfg(not(any(target_os = "macos", target_os = "windows", target_os = "android")))]
fn initialize_inner() -> ResultType<()> {
    bail!("NikoDesk isolation is not supported on this platform")
}

#[cfg(any(target_os = "macos", target_os = "windows", target_os = "android"))]
fn initialize_inner() -> ResultType<()> {
    #[cfg(unix)]
    if unsafe { hbb_common::libc::geteuid() } == 0 {
        bail!("NikoDesk must run as the current user, without elevation");
    }
    #[cfg(windows)]
    if crate::platform::is_elevated(None)? {
        bail!("NikoDesk must run as the current user, without elevation");
    }
    #[cfg(target_os = "android")]
    validate_android_directory(&config::APP_DIR.read().unwrap())?;
    let name = app_name()?;
    *config::APP_NAME.write().unwrap() = name.clone();
    #[cfg(target_os = "macos")]
    {
        *config::ORG.write().unwrap() = "io.nikodesk".to_owned();
    }
    sodiumoxide::init().map_err(|_| anyhow!("Cannot initialize identity cryptography"))?;
    install_policy();
    let path = Config::file();
    if !path.is_absolute()
        || path.file_name().and_then(|x| x.to_str()) != Some(format!("{name}.toml").as_str())
    {
        bail!("Cannot resolve the isolated NikoDesk configuration directory");
    }
    // Keep the OS lock until this library's lazy Config and key cache are initialized.
    let (_lock, identity) = identity_file::prepare(&path)?;
    let expected_id = identity.validated_id()?;
    let loaded = Config::get();
    if loaded.id != expected_id || Config::get_key_pair() != identity.key_pair {
        bail!("NikoDesk identity failed to load; preserving the identity file");
    }
    let persisted = identity_file::read(&path)?;
    if persisted.validated_id()? != expected_id || persisted.enc_id.is_empty() {
        bail!("NikoDesk identity could not be safely persisted");
    }
    Ok(())
}

fn install_policy() {
    let mut hard = config::HARD_SETTINGS.write().unwrap();
    #[cfg(target_os = "android")]
    hard.insert("conn-type".into(), "outgoing".into());
    for key in [
        "disable-installation",
        "disable-tcp-listen",
        "disable-account",
        "disable-ab",
    ] {
        hard.insert(key.into(), "Y".into());
    }
    drop(hard);
    let mut forced = config::OVERWRITE_SETTINGS.write().unwrap();
    for key in [
        "enable-lan-discovery",
        "direct-server",
        "allow-auto-update",
        "enable-terminal",
        "enable-tunnel",
        "enable-camera",
        "enable-remote-restart",
        "enable-block-input",
        "allow-remote-config-modification",
        "allow-insecure-tls-fallback",
        "allow-hide-cm",
        "enable-trusted-devices",
    ] {
        forced.insert(key.into(), "N".into());
    }
    drop(forced);
    let mut local = config::OVERWRITE_LOCAL_SETTINGS.write().unwrap();
    for key in ["enable-check-update", "enable-webrtc", "enable-ipv6-punch"] {
        local.insert(key.into(), "N".into());
    }
    drop(local);
    let mut defaults = config::DEFAULT_SETTINGS.write().unwrap();
    for (key, value) in [
        ("stop-service", "Y"),
        ("access-mode", "custom"),
        ("approve-mode", "click"),
        ("verification-method", "use-temporary-password"),
        ("temporary-password-length", "10"),
        // Accepting a session grants the basics a user expects from remote
        // control (ToDesk parity): keyboard/mouse, clipboard and file
        // transfer. Audio stays off by default; everything remains
        // per-session, visible and revocable in the confirmation window.
        ("enable-keyboard", "Y"),
        ("enable-clipboard", "Y"),
        ("enable-file-transfer", "Y"),
        ("enable-file-copy-paste", "N"),
        ("enable-audio", "N"),
        ("enable-privacy-mode", "N"),
        ("nikodesk-allow-virtual-display", "N"),
    ] {
        defaults.insert(key.into(), value.into());
    }
}

pub fn validate_remote_id(id: &str) -> ResultType<()> {
    if !(6..=16).contains(&id.len()) || !id.bytes().all(|c| c.is_ascii_digit()) {
        bail!("NikoDesk supports numeric device IDs on the configured private server only");
    }
    Ok(())
}

pub fn validate_active_private_server() -> ResultType<()> {
    validate_private_server()?;
    if Config::get_option("stop-service") != "N" {
        bail!("NikoDesk is paused");
    }
    Ok(())
}

pub fn validate_connection_credentials(password: &str) -> ResultType<()> {
    if password.trim().is_empty() {
        bail!("Enter the remote device password before connecting");
    }
    Ok(())
}

pub fn validate_server_address(address: &str) -> ResultType<()> {
    if address.is_empty()
        || address.trim() != address
        || address.contains(['/', '@', '?', '#', '\\'])
    {
        bail!("Enter a server host or host:port without a URL scheme or path");
    }
    let (host, port) = if let Some(tail) = address.strip_prefix('[') {
        let (host, tail) = tail
            .split_once(']')
            .ok_or_else(|| anyhow!("Invalid IPv6 server address"))?;
        if !matches!(host.parse::<IpAddr>(), Ok(IpAddr::V6(_))) {
            bail!("Invalid IPv6 server address");
        }
        (
            host,
            if tail.is_empty() {
                None
            } else {
                Some(
                    tail.strip_prefix(':')
                        .ok_or_else(|| anyhow!("Invalid server port"))?,
                )
            },
        )
    } else if address.matches(':').count() > 1 {
        bail!("Enclose IPv6 server addresses in brackets");
    } else {
        address
            .split_once(':')
            .map_or((address, None), |(h, p)| (h, Some(p)))
    };
    if let Some(port) = port {
        if port.parse::<u16>().ok().filter(|p| *p > 0).is_none()
            || !port.bytes().all(|c| c.is_ascii_digit())
        {
            bail!("Server port must be between 1 and 65535");
        }
    }
    match host.parse::<IpAddr>() {
        Ok(ip) if ip.is_unspecified() || ip.is_multicast() => bail!("Invalid server address"),
        Ok(_) => {}
        Err(_) => {
            if host.is_empty()
                || host.len() > 253
                || host.ends_with('.')
                || !host.is_ascii()
                || host.split('.').any(|part| {
                    part.is_empty()
                        || part.len() > 63
                        || part.starts_with('-')
                        || part.ends_with('-')
                        || !part.bytes().all(|c| c.is_ascii_alphanumeric() || c == b'-')
                })
            {
                bail!("Invalid server hostname");
            }
            let host = host.to_ascii_lowercase();
            if host == "rustdesk.com" || host.ends_with(".rustdesk.com") || host == "public" {
                bail!("Public RustDesk rendezvous services are disabled in NikoDesk");
            }
        }
    }
    Ok(())
}

fn validate_server_values(server: &str, relay: &str, key: &str) -> ResultType<()> {
    validate_server_address(server)?;
    if !relay.is_empty() {
        validate_server_address(relay)?;
    }
    let decoded = base64::decode(key, base64::Variant::Original)
        .map_err(|_| anyhow!("The server public key must be Base64 encoded"))?;
    if decoded.len() != sign::PUBLICKEYBYTES || decoded.iter().all(|b| *b == 0) {
        bail!("The server public key must be a nonzero 32-byte key");
    }
    Ok(())
}

pub fn validate_private_server() -> ResultType<()> {
    if !matches!(INITIALIZED.get(), Some(Ok(()))) {
        bail!("NikoDesk identity is not initialized");
    }
    if SETTINGS_WRITING.load(Ordering::SeqCst) || SETTINGS_SAVE_FAILED.load(Ordering::SeqCst) {
        bail!("NikoDesk server settings have not been confirmed on disk");
    }
    validate_server_values(
        &Config::get_option("custom-rendezvous-server"),
        &Config::get_option("relay-server"),
        &Config::get_option("key"),
    )
}

pub fn rendezvous_servers() -> Vec<String> {
    if validate_private_server().is_err() {
        return Vec::new();
    }
    vec![Config::get_option("custom-rendezvous-server")]
}

pub fn rendezvous_server() -> String {
    rendezvous_servers()
        .first()
        .map(|s| crate::check_port(s, config::RENDEZVOUS_PORT))
        .unwrap_or_default()
}

// Incomplete configurations remain savable so clearing the server immediately pauses service.
pub fn prepare_options(options: &mut HashMap<String, String>) -> ResultType<()> {
    let value = |key| options.get(key).map(String::as_str).unwrap_or_default();
    let server = value("custom-rendezvous-server");
    let relay = value("relay-server");
    let key = value("key");
    if !server.is_empty() {
        validate_server_address(server)?;
    }
    if !relay.is_empty() {
        validate_server_address(relay)?;
    }
    if !key.is_empty() {
        validate_server_values(
            if server.is_empty() {
                "localhost"
            } else {
                server
            },
            relay,
            key,
        )?;
    }
    if server.is_empty() || key.is_empty() {
        options.insert("stop-service".into(), "Y".into());
    } else if value("stop-service").is_empty() {
        // Upstream uses empty for enabled; NikoDesk's default is stopped.
        options.insert("stop-service".into(), "N".into());
    }
    Ok(())
}

pub fn set_option(key: String, mut value: String) -> ResultType<()> {
    initialize()?;
    if key == "nikodesk-two-factor-status" {bail!("Two-factor status is read-only");}
    if key == "stop-service" && value.is_empty() {
        value = "N".into();
    }
    server_settings::patch(key, value)?;
    crate::ui_interface::refresh_options();
    Ok(())
}

pub fn settings_json() -> String {
    let _lock = SETTINGS_WRITE_LOCK.lock().unwrap();
    if SETTINGS_SAVE_FAILED.load(Ordering::SeqCst) || SETTINGS_WRITING.load(Ordering::SeqCst) {
        // The existing void FFI setter is followed by a JSON readback. Invalid
        // JSON makes persistence failure observable rather than reporting success.
        return String::new();
    }
    let mut options = Config::get_options();
    let namespace = server_scope::namespace_from_options(&options).unwrap_or_default();
    options.insert("nikodesk-server-namespace".into(), namespace);
    serde_json::to_string(&options).unwrap_or_default()
}

pub fn settings_save_failed() -> bool {
    SETTINGS_SAVE_FAILED.load(Ordering::SeqCst)
}

pub fn stop_after_settings_failure() {
    SETTINGS_SAVE_FAILED.store(true, Ordering::SeqCst);
    let mut options = Config::get_options();
    options.insert("stop-service".into(), "Y".into());
    Config::replace_options_cache_without_store(purified_options(options));
    crate::rendezvous_mediator::RendezvousMediator::restart();
}

pub fn save_options_locally(_options: HashMap<String, String>) -> ResultType<()> {
    server_settings::reject_snapshot_write();
    bail!("NikoDesk requires a single-option patch or a private-server transaction")
}

fn purified_options(mut options: HashMap<String, String>) -> HashMap<String, String> {
    let forced = config::OVERWRITE_SETTINGS.read().unwrap();
    let defaults = config::DEFAULT_SETTINGS.read().unwrap();
    options.retain(|key, value| key != "nikodesk-server-namespace"
        && !forced.contains_key(key) && defaults.get(key) != Some(value));
    options
}

fn read_options_file(path: &std::path::Path) -> ResultType<HashMap<String, String>> {
    #[cfg(unix)]
    let contents = read_settings_file(path)?;
    #[cfg(windows)]
    let contents = identity_file::read_private_file(path, 1024 * 1024)?;
    #[derive(Deserialize)]
    struct OptionsFile {
        #[serde(default)]
        options: HashMap<String, String>,
    }
    let saved: OptionsFile = toml::from_str(&contents)
        .map_err(|_| anyhow!("NikoDesk settings could not be read back"))?;
    Ok(saved.options)
}

#[cfg(unix)]
fn read_settings_file(path: &std::path::Path) -> ResultType<String> {
    use std::{fs::OpenOptions, io::Read, os::unix::fs::OpenOptionsExt};
    let mut file = OpenOptions::new()
        .read(true)
        .custom_flags(hbb_common::libc::O_NOFOLLOW)
        .open(path)?;
    identity_file::check_metadata(&file.metadata()?, false)?;
    if file.metadata()?.len() > 1024 * 1024 {
        bail!("NikoDesk settings file is too large");
    }
    let mut contents = String::new();
    file.read_to_string(&mut contents)?;
    file.sync_all()?;
    Ok(contents)
}

#[cfg(unix)]
fn write_options_file(path: &std::path::Path, options: &HashMap<String, String>) -> ResultType<()> {
    let mut stored: toml::Value = match std::fs::symlink_metadata(path) {
        Ok(_) => toml::from_str(&read_settings_file(path)?)
            .map_err(|_| anyhow!("NikoDesk settings file is damaged; original file preserved"))?,
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => {
            toml::Value::Table(Default::default())
        }
        Err(err) => return Err(err.into()),
    };
    stored
        .as_table_mut()
        .ok_or_else(|| anyhow!("Invalid NikoDesk settings file"))?
        .insert("options".into(), toml::Value::try_from(options)?);
    // Preserve serialized proxy/PIN fields instead of writing decrypted values
    // from Config2::get() while saving unrelated server options.
    config::store_path(path.to_path_buf(), &stored)?;
    verify_options_file(path, options)
}

#[cfg(unix)]
fn verify_options_file(
    path: &std::path::Path,
    expected: &HashMap<String, String>,
) -> ResultType<()> {
    let contents = read_settings_file(path)?;
    #[derive(Deserialize)]
    struct OptionsFile {
        #[serde(default)]
        options: HashMap<String, String>,
    }
    let saved: OptionsFile = toml::from_str(&contents)
        .map_err(|_| anyhow!("NikoDesk settings could not be read back"))?;
    if saved.options != *expected {
        bail!("NikoDesk settings did not persist; service remains stopped");
    }
    if let Some(parent) = path.parent() {
        std::fs::File::open(parent)?.sync_all()?;
    }
    Ok(())
}

#[cfg(windows)]
fn write_options_file(path: &std::path::Path, options: &HashMap<String, String>) -> ResultType<()> {
    let mut stored: toml::Value = match std::fs::symlink_metadata(path) {
        Ok(_) => toml::from_str(&identity_file::read_private_file(path, 1024 * 1024)?)
            .map_err(|_| anyhow!("NikoDesk settings file is damaged; original file preserved"))?,
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => {
            toml::Value::Table(Default::default())
        }
        Err(err) => return Err(err.into()),
    };
    stored.as_table_mut().ok_or_else(|| anyhow!("Invalid NikoDesk settings file"))?
        .insert("options".into(), toml::Value::try_from(options)?);
    identity_file::write_private_file(path, toml::to_string(&stored)?.as_bytes())?;
    verify_options_file(path, options)
}

#[cfg(windows)]
fn verify_options_file(path: &std::path::Path, expected: &HashMap<String, String>) -> ResultType<()> {
    let saved: toml::Value = toml::from_str(&identity_file::read_private_file(path, 1024 * 1024)?)?;
    let options: HashMap<String, String> = saved.get("options")
        .ok_or_else(|| anyhow!("NikoDesk settings did not persist"))?.clone().try_into()?;
    if options != *expected {
        bail!("NikoDesk settings did not persist; service remains stopped");
    }
    Ok(())
}

#[cfg(target_os = "android")]
pub fn initialize_android(app_dir: &str) -> ResultType<()> {
    validate_android_directory(app_dir)?;
    let mut configured = config::APP_DIR
        .write()
        .map_err(|_| anyhow!("NikoDesk's Android configuration directory lock is poisoned"))?;
    if !configured.is_empty() && configured.as_str() != app_dir {
        bail!("NikoDesk's Android configuration directory cannot change while running");
    }
    *configured = app_dir.into();
    drop(configured);
    initialize()
}

#[cfg(any(target_os = "android", test))]
fn validate_android_directory(app_dir: &str) -> ResultType<()> {
    let components = app_dir.split('/').collect::<Vec<_>>();
    let package = match components.as_slice() {
        ["", "data", "user", user, package, "app_flutter"]
            if user.bytes().all(|c| c.is_ascii_digit()) && user.parse::<u32>().is_ok() => *package,
        ["", "data", "data", package, "app_flutter"] => *package,
        _ => bail!("NikoDesk configuration must remain in its private Android app storage"),
    };
    if !["io.nikodesk.android", "io.nikodesk.android.dev"].contains(&package) {
        bail!("NikoDesk requires its own Android application sandbox");
    }
    Ok(())
}

pub fn is_saved_password_option(key: &str) -> bool {
    matches!(key, "os-password" | "rdp_password")
}

pub fn clear_saved_credentials(password: &mut Vec<u8>, options: &mut HashMap<String, String>) {
    password.clear();
    options.retain(|key, _| !is_saved_password_option(key));
}

pub fn validate_cli_args(args: impl IntoIterator<Item = String>) -> ResultType<()> {
    for arg in args {
        if arg.starts_with("--")
            && ![
                "--version",
                "--build-date",
                "--check-hwcodec-config",
                "--get-id",
                "--no-server",
                "--server",
                "--tray",
                "--cm",
                "--connect",
                "--play",
                "--file-transfer",
                "--view-camera",
                "--port-forward",
                "--terminal",
                "--rdp",
                "--switch_uuid",
                "--force_relay",
                "--texture-render",
                "--cm-no-ui",
                "--nikodesk-background-agent",
            ]
            .contains(&arg.as_str())
        {
            bail!("This command is disabled in the NikoDesk user-space build");
        }
        if arg == "-gtk-sudo" {
            bail!("NikoDesk does not support elevation");
        }
    }
    Ok(())
}

#[derive(Deserialize, Serialize)]
struct Identity {
    #[serde(default, skip_serializing_if = "String::is_empty")]
    id: String,
    #[serde(default)]
    enc_id: String,
    key_pair: (Vec<u8>, Vec<u8>),
}

impl Identity {
    fn validate_keys(&self) -> ResultType<()> {
        let secret = sign::SecretKey::from_slice(&self.key_pair.0)
            .ok_or_else(|| anyhow!("Invalid NikoDesk identity key"))?;
        let public = sign::PublicKey::from_slice(&self.key_pair.1)
            .ok_or_else(|| anyhow!("Invalid NikoDesk identity key"))?;
        if !sign::verify_detached(
            &sign::sign_detached(b"NikoDesk identity validation", &secret),
            b"NikoDesk identity validation",
            &public,
        ) {
            bail!("NikoDesk identity key pair does not match");
        }
        Ok(())
    }

    fn validated_id(&self) -> ResultType<String> {
        self.validate_keys()?;
        let id = if self.enc_id.is_empty() {
            self.id.clone()
        } else {
            if !self.enc_id.starts_with("00")
                || base64::decode(&self.enc_id[2..], base64::Variant::Original).is_err()
            {
                bail!("NikoDesk identity encryption is damaged; original file preserved");
            }
            let (id, decrypted, _) =
                hbb_common::password_security::decrypt_str_or_original(&self.enc_id, "00");
            if !decrypted {
                bail!("NikoDesk identity cannot be decrypted; original file preserved");
            }
            id
        };
        validate_remote_id(&id)?;
        Ok(id)
    }
}

#[cfg(unix)]
mod identity_file {
    use super::*;
    use hbb_common::libc;
    use std::{
        fs::{self, File, OpenOptions},
        io::{Read, Write},
        os::{
            fd::AsRawFd,
            unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt},
        },
        path::Path,
    };

    pub(super) struct Lock(File);
    impl Drop for Lock {
        fn drop(&mut self) {
            unsafe {
                libc::flock(self.0.as_raw_fd(), libc::LOCK_UN);
            }
        }
    }

    pub(super) fn check_metadata(meta: &fs::Metadata, directory: bool) -> ResultType<()> {
        if meta.uid() != unsafe { libc::geteuid() }
            || meta.mode() & 0o077 != 0
            || if directory {
                !meta.is_dir()
            } else {
                !meta.is_file() || meta.nlink() != 1
            }
        {
            bail!(
                "NikoDesk identity path must be private, owned by the current user, and not a link"
            );
        }
        Ok(())
    }

    pub(super) fn read(path: &Path) -> ResultType<Identity> {
        let mut file = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW)
            .open(path)?;
        let meta = file.metadata()?;
        check_metadata(&meta, false)?;
        if meta.len() > 128 * 1024 {
            bail!("NikoDesk identity file is too large");
        }
        let mut content = String::new();
        file.read_to_string(&mut content)?;
        let identity: Identity = toml::from_str(&content)
            .map_err(|_| anyhow!("NikoDesk identity file is damaged; original file preserved"))?;
        identity.validate_keys()?;
        Ok(identity)
    }

    pub(super) fn prepare(path: &Path) -> ResultType<(Lock, Identity)> {
        let dir = path
            .parent()
            .ok_or_else(|| anyhow!("Invalid identity path"))?;
        match fs::symlink_metadata(dir) {
            Ok(meta) => check_metadata(&meta, true)?,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                match fs::DirBuilder::new().mode(0o700).create(dir) {
                    Ok(()) => {}
                    Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {}
                    Err(e) => return Err(e.into()),
                }
                check_metadata(&fs::symlink_metadata(dir)?, true)?;
            }
            Err(e) => return Err(e.into()),
        }
        let lock_file = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW)
            .open(dir.join("identity.lock"))?;
        check_metadata(&lock_file.metadata()?, false)?;
        if unsafe { libc::flock(lock_file.as_raw_fd(), libc::LOCK_EX) } != 0 {
            return Err(std::io::Error::last_os_error().into());
        }
        let lock = Lock(lock_file);
        match fs::symlink_metadata(path) {
            Ok(_) => return Ok((lock, read(path)?)),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => return Err(e.into()),
        }
        let (pk, sk) = sign::gen_keypair();
        let identity = Identity {
            id: rand::thread_rng()
                .gen_range(1_000_000_000u32..2_000_000_000)
                .to_string(),
            enc_id: String::new(),
            key_pair: (sk.0.to_vec(), pk.0.to_vec()),
        };
        let temp_path = dir.join(format!(
            ".identity-{}.tmp",
            hbb_common::uuid::Uuid::new_v4()
        ));
        let result = (|| -> ResultType<()> {
            let mut file = OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(0o600)
                .custom_flags(libc::O_NOFOLLOW)
                .open(&temp_path)?;
            file.write_all(
                toml::to_string(&identity)
                    .context("Cannot serialize NikoDesk identity")?
                    .as_bytes(),
            )?;
            file.sync_all()?;
            fs::rename(&temp_path, path)?;
            File::open(dir)?.sync_all()?;
            Ok(())
        })();
        if result.is_err() {
            let _ = fs::remove_file(&temp_path);
        }
        result?;
        Ok((lock, identity))
    }
}

#[cfg(windows)]
#[path = "nikodesk/windows.rs"]
mod identity_file;

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::{
        fs,
        os::unix::fs::{symlink, PermissionsExt},
        path::PathBuf,
        sync::{Arc, Barrier},
    };
    struct Temp(PathBuf);
    impl Temp {
        fn new() -> Self {
            let p = std::env::temp_dir().join(format!(
                "nikodesk-identity-test-{}",
                hbb_common::uuid::Uuid::new_v4()
            ));
            fs::create_dir(&p).unwrap();
            fs::set_permissions(&p, fs::Permissions::from_mode(0o700)).unwrap();
            Self(p)
        }
    }
    impl Drop for Temp {
        fn drop(&mut self) {
            fs::remove_dir_all(&self.0).unwrap();
        }
    }

    #[test]
    fn android_directory_requires_the_nikodesk_private_sandbox() {
        for directory in [
            "/data/user/0/io.nikodesk.android/app_flutter",
            "/data/user/0/io.nikodesk.android.dev/app_flutter",
            "/data/user/10/io.nikodesk.android/app_flutter",
            "/data/user/12/io.nikodesk.android.dev/app_flutter",
            "/data/data/io.nikodesk.android/app_flutter",
            "/data/data/io.nikodesk.android.dev/app_flutter",
        ] {
            assert!(validate_android_directory(directory).is_ok());
        }
        for directory in [
            "", "app_flutter", "/sdcard/Android/data/io.nikodesk.android/files",
            "/data/user/0/com.carriez.flutter_hbb/app_flutter",
            "/data/user/0/io.nikodesk.android/app_flutter/../../other",
            "/data/user/0/com.carriez.flutter_hbb/io.nikodesk.android/app_flutter",
            "/data/data/com.carriez.flutter_hbb/io.nikodesk.android/app_flutter",
            "/data/user/0/io.nikodesk.android/app_flutter/extra",
            "/data/user/0/io.nikodesk.android/app_flutter/",
            "/data/user/0/io.nikodesk.android/./app_flutter",
            "/data/user/0/io.nikodesk.android/../app_flutter",
            "/data/user//io.nikodesk.android/app_flutter",
            "/data/user/+0/io.nikodesk.android/app_flutter",
            "/data/user/-1/io.nikodesk.android/app_flutter",
            "/data/user/name/io.nikodesk.android/app_flutter",
            "/data/user/4294967296/io.nikodesk.android/app_flutter",
            "/data/user/0/io.nikodesk.android.extra/app_flutter",
            "/data/user/0/io.nikodesk.android.dev.extra/app_flutter",
        ] {
            assert!(validate_android_directory(directory).is_err());
        }
    }

    #[test]
    fn private_server_validation_rejects_bypasses() {
        for host in [
            "",
            "https://nas.local",
            "nas/path",
            "x@nas",
            "nas:0",
            "nas:65536",
            "rs-ny.rustdesk.com",
            "PUBLIC",
            "[::]",
            " nas",
            "nas.",
        ] {
            assert!(validate_server_address(host).is_err(), "{host}");
        }
        for host in ["nas.local", "192.168.1.8:21116", "[fd00::1]:21116"] {
            assert!(validate_server_address(host).is_ok(), "{host}");
        }
        for id in [
            "1.2.3.4",
            "123456@public",
            "nas:21118",
            "123456/r",
            " 123456",
            "１２３４５６",
        ] {
            assert!(validate_remote_id(id).is_err());
        }
        assert!(validate_remote_id("1234567890").is_ok());
        let key = base64::encode([1u8; 32], base64::Variant::Original);
        assert!(validate_server_values("nas.local", "", &key).is_ok());
        for key in [
            "",
            "bad",
            &base64::encode([0u8; 32], base64::Variant::Original),
            &base64::encode([1u8; 31], base64::Variant::Original),
        ] {
            assert!(validate_server_values("nas.local", "", key).is_err());
        }
    }

    #[test]
    fn connection_credentials_reject_blank_values_without_returning_secrets() {
        for password in ["", " ", "\t\r\n"] {
            assert!(validate_connection_credentials(password).is_err());
        }
        assert!(validate_connection_credentials(" synthetic-secret ").is_ok());
        assert!(!validate_connection_credentials("").unwrap_err().to_string().contains("synthetic-secret"));
    }

    #[test]
    fn private_config_clearing_stops_and_explicit_enable_survives() {
        let mut opts = HashMap::from([("stop-service".into(), "N".into())]);
        prepare_options(&mut opts).unwrap();
        assert_eq!(opts["stop-service"], "Y");
        opts.insert("custom-rendezvous-server".into(), "nas.local".into());
        opts.insert(
            "key".into(),
            base64::encode([1u8; 32], base64::Variant::Original),
        );
        opts.insert("stop-service".into(), "".into());
        prepare_options(&mut opts).unwrap();
        assert_eq!(opts["stop-service"], "N");
        opts.insert("stop-service".into(), "Y".into());
        prepare_options(&mut opts).unwrap();
        assert_eq!(opts["stop-service"], "Y");
    }

    #[test]
    fn nikodesk_settings_readback_rejects_stale_and_missing_disk_state() {
        let temp = Temp::new();
        let path = temp.0.join("NikoDesk2.toml");
        let enabled = HashMap::from([("stop-service".into(), "N".into())]);
        assert!(verify_options_file(&path, &enabled).is_err());
        fs::write(&path, "[options]\nstop-service = 'Y'\n").unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();
        // Models a setter which updates memory but silently fails its write.
        assert!(verify_options_file(&path, &enabled).is_err());
        fs::write(&path, "[options]\nstop-service = 'N'\n").unwrap();
        verify_options_file(&path, &enabled).unwrap();
        let stopped = HashMap::from([("stop-service".into(), "Y".into())]);
        assert!(verify_options_file(&path, &stopped).is_err());
    }

    #[test]
    fn nikodesk_settings_readback_rejects_corruption_and_symlink() {
        let temp = Temp::new();
        let path = temp.0.join("NikoDesk2.toml");
        fs::write(&path, "[options]\nkey = [\n").unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();
        assert!(verify_options_file(&path, &HashMap::new()).is_err());
        let link = temp.0.join("linked.toml");
        symlink(&path, &link).unwrap();
        assert!(verify_options_file(&link, &HashMap::new()).is_err());
    }

    #[test]
    fn nikodesk_fallible_settings_write_preserves_serialized_fields_and_retries() {
        let temp = Temp::new();
        let path = temp.0.join("NikoDesk2.toml");
        fs::write(
            &path,
            "unlock_pin = 'encrypted-placeholder'\n[options]\nstop-service = 'Y'\n",
        )
        .unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();
        let enabled = HashMap::from([("stop-service".into(), "N".into())]);
        write_options_file(&path, &enabled).unwrap();
        write_options_file(&path, &enabled).unwrap();
        let saved: toml::Value = toml::from_str(&fs::read_to_string(&path).unwrap()).unwrap();
        assert_eq!(saved["unlock_pin"].as_str(), Some("encrypted-placeholder"));
        verify_options_file(&path, &enabled).unwrap();
        let bad_path = temp.0.join("directory.toml");
        fs::create_dir(&bad_path).unwrap();
        assert!(write_options_file(&bad_path, &enabled).is_err());
    }

    #[test]
    fn concurrent_initialization_reuses_one_private_identity() {
        sodiumoxide::init().unwrap();
        let temp = Temp::new();
        let barrier = Arc::new(Barrier::new(8));
        let jobs: Vec<_> = (0..8)
            .map(|_| {
                let path = temp.0.join("NikoDesk.toml");
                let barrier = barrier.clone();
                std::thread::spawn(move || {
                    barrier.wait();
                    let (_lock, identity) = identity_file::prepare(&path).unwrap();
                    assert!((1_000_000_000..2_000_000_000)
                        .contains(&identity.id.parse::<u32>().unwrap()));
                    (identity.id, identity.key_pair)
                })
            })
            .collect();
        let identities: Vec<_> = jobs.into_iter().map(|j| j.join().unwrap()).collect();
        assert!(identities.windows(2).all(|p| p[0] == p[1]));
        assert_eq!(
            fs::metadata(temp.0.join("NikoDesk.toml"))
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
    }

    #[test]
    fn damaged_and_symlink_identities_are_preserved_and_rejected() {
        let temp = Temp::new();
        let path = temp.0.join("NikoDesk.toml");
        fs::write(&path, "damaged = [").unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();
        assert!(identity_file::prepare(&path).is_err());
        assert_eq!(fs::read_to_string(&path).unwrap(), "damaged = [");
        fs::remove_file(&path).unwrap();
        let target = temp.0.join("other");
        fs::write(&target, "untouched").unwrap();
        symlink(&target, &path).unwrap();
        assert!(identity_file::prepare(&path).is_err());
        assert_eq!(fs::read_to_string(&target).unwrap(), "untouched");
    }
    #[test]
    fn subprocess_identity_writer() {
        let Some(dir) = std::env::var_os("NIKODESK_TEST_IDENTITY_DIR") else {
            return;
        };
        sodiumoxide::init().unwrap();
        let path = PathBuf::from(dir);
        let (_lock, identity) = identity_file::prepare(&path.join("NikoDesk.toml")).unwrap();
        let output = path.join(format!("child-{}", std::process::id()));
        fs::write(output, identity.id).unwrap();
    }

    #[test]
    fn separate_processes_share_one_identity_without_replacing_it() {
        let temp = Temp::new();
        let children: Vec<_> = (0..4)
            .map(|_| {
                std::process::Command::new(std::env::current_exe().unwrap())
                    .args(["--exact", "nikodesk::tests::subprocess_identity_writer"])
                    .env("NIKODESK_TEST_IDENTITY_DIR", &temp.0)
                    .stdout(std::process::Stdio::null())
                    .stderr(std::process::Stdio::null())
                    .spawn()
                    .unwrap()
            })
            .collect();
        for mut child in children {
            assert!(child.wait().unwrap().success());
        }
        let (_lock, identity) = identity_file::prepare(&temp.0.join("NikoDesk.toml")).unwrap();
        let outputs: Vec<_> = fs::read_dir(&temp.0)
            .unwrap()
            .filter_map(|e| {
                let e = e.unwrap();
                e.file_name()
                    .to_string_lossy()
                    .starts_with("child-")
                    .then(|| fs::read_to_string(e.path()).unwrap())
            })
            .collect();
        assert_eq!(outputs.len(), 4);
        assert!(outputs.iter().all(|id| id == &identity.id));
    }

    #[test]
    fn mismatched_keys_and_broken_encryption_are_rejected() {
        sodiumoxide::init().unwrap();
        let (pk, sk) = sign::gen_keypair();
        let (other_pk, _) = sign::gen_keypair();
        let mut identity = Identity {
            id: String::new(),
            enc_id: "invalid".into(),
            key_pair: (sk.0.to_vec(), pk.0.to_vec()),
        };
        assert!(identity.validated_id().is_err());
        identity.enc_id.clear();
        identity.id = "1234567890".into();
        identity.key_pair.1 = other_pk.0.to_vec();
        assert!(identity.validate_keys().is_err());
    }

    #[test]
    fn identity_file_rejects_group_readable_files_and_hardlinks() {
        sodiumoxide::init().unwrap();
        let temp = Temp::new();
        let path = temp.0.join("NikoDesk.toml");
        let (lock, _) = identity_file::prepare(&path).unwrap();
        drop(lock);
        fs::set_permissions(&path, fs::Permissions::from_mode(0o640)).unwrap();
        assert!(identity_file::prepare(&path).is_err());
        fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();
        fs::hard_link(&path, temp.0.join("copy")).unwrap();
        assert!(identity_file::prepare(&path).is_err());
    }

    #[test]
    fn management_commands_cannot_reach_services_or_import_old_identity() {
        for arg in [
            "--write-plists",
            "--install-service",
            "--uninstall-service",
            "--service",
            "--elevate",
            "--run-as-system",
            "--update",
            "--import-config",
            "--config",
            "--set-id",
            "--password",
            "--option",
            "-gtk-sudo",
        ] {
            assert!(validate_cli_args([arg.to_owned()]).is_err(), "{arg}");
        }
        assert!(validate_cli_args(["--server".to_owned()]).is_ok());
        assert!(validate_cli_args(["--cm".to_owned()]).is_ok());
    }

    #[test]
    fn saved_credentials_are_removed_without_losing_session_preferences() {
        let mut password = vec![1, 2, 3];
        let mut options = HashMap::from([
            ("os-password".into(), "test-os-secret".into()),
            ("rdp_password".into(), "test-rdp-secret".into()),
            ("view-style".into(), "original".into()),
            ("alias".into(), "Office".into()),
        ]);
        clear_saved_credentials(&mut password, &mut options);
        assert!(password.is_empty());
        assert!(!options.contains_key("os-password"));
        assert!(!options.contains_key("rdp_password"));
        assert_eq!(options["view-style"], "original");
        assert_eq!(options["alias"], "Office");
    }
}
