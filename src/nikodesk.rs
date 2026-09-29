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

#[cfg(not(target_os = "macos"))]
fn initialize_inner() -> ResultType<()> {
    bail!("NikoDesk isolation is currently supported only on macOS")
}

#[cfg(target_os = "macos")]
fn initialize_inner() -> ResultType<()> {
    if unsafe { hbb_common::libc::geteuid() } == 0 {
        bail!("NikoDesk must run as the current user, without elevation");
    }
    *config::APP_NAME.write().unwrap() = "NikoDesk".to_owned();
    *config::ORG.write().unwrap() = "io.nikodesk".to_owned();
    sodiumoxide::init().map_err(|_| anyhow!("Cannot initialize identity cryptography"))?;
    install_policy();
    let path = Config::file();
    if !path.is_absolute() || path.file_name().and_then(|x| x.to_str()) != Some("NikoDesk.toml") {
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
        "enable-privacy-mode",
        "enable-block-input",
        "allow-remote-config-modification",
        "allow-insecure-tls-fallback",
        "allow-hide-cm",
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
    if key == "stop-service" && value.is_empty() {
        value = "N".into();
    }
    let mut options = Config::get_options();
    options.insert(key, value);
    crate::ipc::set_options(options)?;
    crate::ui_interface::refresh_options();
    Ok(())
}

pub fn settings_json() -> String {
    if SETTINGS_SAVE_FAILED.load(Ordering::SeqCst) || SETTINGS_WRITING.load(Ordering::SeqCst) {
        // The existing void FFI setter is followed by a JSON readback. Invalid
        // JSON makes persistence failure observable rather than reporting success.
        return String::new();
    }
    serde_json::to_string(&Config::get_options()).unwrap_or_default()
}

pub fn settings_save_failed() -> bool {
    SETTINGS_SAVE_FAILED.load(Ordering::SeqCst)
}

pub fn stop_after_settings_failure() {
    SETTINGS_SAVE_FAILED.store(true, Ordering::SeqCst);
    Config::set_option("stop-service".into(), "Y".into());
    crate::rendezvous_mediator::RendezvousMediator::restart();
}

/// Upstream setters log filesystem failures and return (). Confirm the exact
/// purified options on disk before allowing the private-server guard to reopen.
pub fn save_options_locally(mut options: HashMap<String, String>) -> ResultType<()> {
    initialize()?;
    let _lock = SETTINGS_WRITE_LOCK.lock().unwrap();
    SETTINGS_WRITING.store(true, Ordering::SeqCst);
    let result = (|| {
        prepare_options(&mut options)?;
        let mut saved_options = options.clone();
        let forced = config::OVERWRITE_SETTINGS.read().unwrap();
        let defaults = config::DEFAULT_SETTINGS.read().unwrap();
        saved_options
            .retain(|key, value| !forced.contains_key(key) && defaults.get(key) != Some(value));
        drop(defaults);
        drop(forced);
        // Retry the fallible write even if an earlier failed store left the
        // upstream in-memory value unchanged.
        write_options_file(&config::Config2::file(), &saved_options)?;
        Config::set_options(options);
        verify_options_file(&config::Config2::file(), &config::Config2::get().options)
    })();
    if result.is_err() {
        stop_after_settings_failure();
    } else {
        SETTINGS_SAVE_FAILED.store(false, Ordering::SeqCst);
    }
    SETTINGS_WRITING.store(false, Ordering::SeqCst);
    result
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

#[cfg(not(unix))]
fn write_options_file(_: &std::path::Path, _: &HashMap<String, String>) -> ResultType<()> {
    bail!("NikoDesk settings isolation is not supported on this platform")
}

#[cfg(not(unix))]
fn verify_options_file(_: &std::path::Path, _: &HashMap<String, String>) -> ResultType<()> {
    bail!("NikoDesk settings isolation is not supported on this platform")
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
