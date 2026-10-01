//! Offline NikoDesk machine profiles. This codec is not an installation grant:
//! the caller must revalidate its broker-bound local approval before committing.
use super::permanent_password::{
    compute_permanent_password_h1, constant_time_eq_32,
    decode_permanent_password_h1_from_storage_with_explicit_key,
    encode_permanent_password_encrypted_storage_from_h1_with_explicit_key, DEFAULT_SALT_LEN,
};
use crate::password_security::symmetric_crypt_with_explicit_key;
use anyhow::{anyhow, bail, Result};
use rand::RngCore;
use serde_derive::{Deserialize, Serialize};
use sodiumoxide::{
    base64,
    crypto::{secretbox, sign},
    utils::memzero,
};
use std::{collections::BTreeMap, net::IpAddr};

const IDENTITY_FILE: &str = "NikoDesk.toml";
const SETTINGS_FILE: &str = "NikoDesk2.toml";
const MAX_FILE_BYTES: usize = 128 * 1024;
const IDENTITY_PROOF: &[u8] = b"NikoDesk identity validation";

/// Opaque OS-derived context; never substitutes an existing device public key.
pub struct MachineEncryptionContext(secretbox::Key);

impl MachineEncryptionContext {
    pub(super) fn crypt(&self, data: &[u8], encrypt: bool) -> std::result::Result<Vec<u8>, ()> {
        symmetric_crypt_with_explicit_key(data, encrypt, &self.0)
    }

    #[cfg(test)]
    pub(super) fn fixture() -> Self {
        Self::from_uid_bytes(b"fixture-machine-context-1234567890123456789".to_vec()).unwrap()
    }

    #[cfg(test)]
    pub(super) fn fixture_other() -> Self {
        Self::from_uid_bytes(b"other-fixture-machine-context-1234567890".to_vec()).unwrap()
    }

    pub fn from_os_machine_uid() -> Result<Self> {
        #[cfg(not(any(target_os = "android", target_os = "ios")))]
        {
            Self::from_lookup(machine_uid::get().map(String::into_bytes).map_err(|_| ()))
        }
        #[cfg(any(target_os = "android", target_os = "ios"))]
        {
            bail!("machine_context_unsupported");
        }
    }

    fn from_lookup(uid: std::result::Result<Vec<u8>, ()>) -> Result<Self> {
        Self::from_uid_bytes(uid.map_err(|_| anyhow!("machine_context_unavailable"))?)
    }

    fn from_uid_bytes(mut uid: Vec<u8>) -> Result<Self> {
        let valid = !uid.is_empty()
            && uid.len() <= 4096
            && !uid.contains(&0)
            && !uid.iter().all(u8::is_ascii_whitespace);
        if !valid {
            memzero(&mut uid);
            bail!("machine_context_unavailable");
        }
        // Exactly the key derivation in symmetric_crypt, without get_uuid().
        let mut key = secretbox::Key([0; secretbox::KEYBYTES]);
        let len = uid.len().min(secretbox::KEYBYTES);
        key.0[..len].copy_from_slice(&uid[..len]);
        memzero(&mut uid);
        Ok(Self(key))
    }
}

/// Only fresh generation is public. There is no import-from-user-key API.
pub struct FreshMachineIdentity {
    id: String,
    public: sign::PublicKey,
    secret: sign::SecretKey,
}

impl FreshMachineIdentity {
    pub fn generate() -> Result<Self> {
        sodiumoxide::init().map_err(|_| anyhow!("machine_crypto_unavailable"))?;
        let mut seed = sign::Seed([0; sign::SEEDBYTES]);
        random(&mut seed.0)?;
        let (public, secret) = sign::keypair_from_seed(&seed);
        let mut id_bytes = [0; 4];
        for _ in 0..128 {
            random(&mut id_bytes)?;
            let value = u32::from_le_bytes(id_bytes);
            if value < 4_000_000_000 {
                let identity = Self {
                    id: (1_000_000_000 + value % 1_000_000_000).to_string(),
                    public,
                    secret,
                };
                identity.verify_pair()?;
                return Ok(identity);
            }
        }
        bail!("machine_random_unavailable");
    }

    pub fn public_id(&self) -> &str {
        &self.id
    }
    pub fn public_key(&self) -> &[u8] {
        &self.public.0
    }

    fn verify_pair(&self) -> Result<()> {
        if self.id.len() != 10
            || !self.id.bytes().all(|b| b.is_ascii_digit())
            || !sign::verify_detached(
                &sign::sign_detached(IDENTITY_PROOF, &self.secret),
                IDENTITY_PROOF,
                &self.public,
            )
        {
            bail!("invalid_machine_identity");
        }
        Ok(())
    }
}

/// Password comes from an explicit local UI entry, never a hash or CLI argument.
pub struct MachineUnattendedPassword(Vec<u8>);
impl MachineUnattendedPassword {
    pub fn from_explicit_user_entry(value: String) -> Result<Self> {
        let secret = Self(value.into_bytes());
        let value = std::str::from_utf8(&secret.0)
            .map_err(|_| anyhow!("explicit_unattended_password_required"))?;
        if value.trim().is_empty() || value.chars().count() > 128 {
            bail!("explicit_unattended_password_required");
        }
        Ok(secret)
    }
}
impl Drop for MachineUnattendedPassword {
    fn drop(&mut self) {
        memzero(&mut self.0);
    }
}

/// Syntax-checked snapshot only. Possession does not prove local authorization,
/// revision freshness, reachability, or that the caller owns this server.
pub struct MachineProfileServer {
    rendezvous: String,
    relay: String,
    public_key: String,
    allow_virtual_display: bool,
    lock_on_disconnect: bool,
    allow_privacy: bool,
    allow_remote_restart: bool,
}
impl MachineProfileServer {
    pub fn new(rendezvous: String, relay: String, public_key: String) -> Result<Self> {
        validate_address(&rendezvous)?;
        if !relay.is_empty() {
            validate_address(&relay)?;
        }
        let decoded = base64::decode(&public_key, base64::Variant::Original)
            .map_err(|_| anyhow!("invalid_machine_server_key"))?;
        if decoded.len() != sign::PUBLICKEYBYTES || decoded.iter().all(|b| *b == 0) {
            bail!("invalid_machine_server_key");
        }
        Ok(Self {
            rendezvous,
            relay,
            public_key,
            allow_virtual_display: false,
            lock_on_disconnect: false,
            allow_privacy: false,
            allow_remote_restart: false,
        })
    }

    /// Only the locally confirmed installer supplies these optional policies.
    /// No password, server destination, or remote authorization is changed.
    pub fn with_session_policies(mut self, allow_virtual_display: bool, lock_on_disconnect: bool) -> Self {
        self.allow_virtual_display = allow_virtual_display;
        self.lock_on_disconnect = lock_on_disconnect;
        self
    }

    fn options(&self) -> BTreeMap<String, String> {
        let mut options = BTreeMap::new();
        options.insert("custom-rendezvous-server".into(), self.rendezvous.clone());
        options.insert("relay-server".into(), self.relay.clone());
        options.insert("key".into(), self.public_key.clone());
        if self.allow_virtual_display { options.insert("nikodesk-allow-virtual-display".into(), "Y".into()); }
        if self.lock_on_disconnect { options.insert("nikodesk-lock-on-last-control".into(), "Y".into()); }
        for (key, value) in [
            ("stop-service", "N"),
            ("conn-type", "incoming"),
            ("access-mode", "custom"),
            ("approve-mode", "password"),
            ("verification-method", "use-permanent-password"),
            ("enable-keyboard", "Y"),
            ("enable-clipboard", "N"),
            ("enable-file-transfer", "N"),
            ("enable-file-copy-paste", "N"),
            ("enable-audio", "N"),
            ("enable-remote-printer", "N"),
            ("enable-record-session", "N"),
            ("enable-trusted-devices", "N"),
            ("allow-remote-config-modification", "N"),
            ("enable-lan-discovery", "N"),
            ("direct-server", "N"),
            ("enable-terminal", "N"),
            ("enable-tunnel", "N"),
            ("enable-camera", "N"),
            ("enable-privacy-mode", "N"),
            ("enable-block-input", "N"),
            ("allow-hide-cm", "N"),
            ("allow-insecure-tls-fallback", "N"),
            ("allow-auto-update", "N"),
            ("enable-remote-restart", "N"),
        ] {
            options.insert(key.into(), value.into());
        }
        if self.allow_privacy { options.insert("enable-privacy-mode".into(), "Y".into()); }
        if self.allow_remote_restart { options.insert("enable-remote-restart".into(), "Y".into()); }
        options
    }
    pub fn with_privacy_policy(mut self, allow: bool) -> Self { self.allow_privacy = allow; self }
    pub fn with_restart_policy(mut self, allow: bool) -> Self { self.allow_remote_restart = allow; self }
}

/// In-memory codec. It never initializes Config, chooses a path, or writes files.
pub struct MachineProfileFactory;
/// Only nonsecret fields may leave inspection of protected machine storage.
pub struct ExistingMachineProfile {
    pub public_id: String,
    pub allow_virtual_display: bool,
    pub lock_on_disconnect: bool,
    pub allow_privacy: bool,
    pub allow_remote_restart: bool,
}
impl MachineProfileFactory {
    /// The caller must prove filesystem ownership and current local consent.
    /// This codec neither chooses paths nor initializes the ordinary Config.
    pub fn inspect_existing(context: &MachineEncryptionContext, files: &BTreeMap<String, Vec<u8>>,
        server: &MachineProfileServer, password: Option<&MachineUnattendedPassword>) -> Result<ExistingMachineProfile> {
        if files.len() != 2 { bail!("invalid_machine_profile_files"); }
        let (mut config, settings) = decode_runtime_fields(context,
            file(files, IDENTITY_FILE)?, file(files, SETTINGS_FILE)?)?;
        let result = (|| {
            if settings.options.get("custom-rendezvous-server") != Some(&server.rendezvous)
                || settings.options.get("relay-server") != Some(&server.relay)
                || settings.options.get("key") != Some(&server.public_key) { bail!("existing_machine_private_server_changed"); }
            if let Some(password) = password {
                let value = std::str::from_utf8(&password.0).map_err(|_|anyhow!("explicit_unattended_password_required"))?;
                let expected = SecretHash(compute_permanent_password_h1(value, &config.salt));
                let stored = SecretHash(decode_permanent_password_h1_from_storage_with_explicit_key(&config.password, &context.0)
                    .ok_or_else(||anyhow!("invalid_machine_profile_verifier"))?);
                if !constant_time_eq_32(&expected.0, &stored.0) { bail!("existing_machine_password_mismatch"); }
            }
            Ok(ExistingMachineProfile { public_id: config.id.clone(),
                allow_virtual_display: settings.options.get("nikodesk-allow-virtual-display").is_some_and(|value| value == "Y"),
                lock_on_disconnect: settings.options.get("nikodesk-lock-on-last-control").is_some_and(|value| value == "Y"),
                allow_privacy: settings.options.get("enable-privacy-mode").is_some_and(|value| value == "Y"),
                allow_remote_restart: settings.options.get("enable-remote-restart").is_some_and(|value| value == "Y") })
        })();
        memzero(&mut config.key_pair.0);
        memzero(&mut config.key_pair.1);
        unsafe { memzero(config.password.as_bytes_mut()); }
        result
    }
    /// Changes only the four explicitly selected session policies. The
    /// identity file, verifier, server and all other settings remain intact.
    /// The native caller still owns local consent, service stop and atomic IO.
    pub fn prepare_policy_update(
        context: &MachineEncryptionContext,
        files: &BTreeMap<String, Vec<u8>>,
        server: &MachineProfileServer,
        allow_virtual_display: bool,
        lock_on_disconnect: bool,
        allow_privacy: bool,
        allow_remote_restart: bool,
    ) -> Result<Vec<u8>> {
        let previous = Self::inspect_existing(context, files, server, None)?;
        let mut settings: SettingsToml = parse(file(files, SETTINGS_FILE)?)?;
        let desired = MachineProfileServer::new(server.rendezvous.clone(), server.relay.clone(), server.public_key.clone())?
            .with_session_policies(allow_virtual_display, lock_on_disconnect)
            .with_privacy_policy(allow_privacy).with_restart_policy(allow_remote_restart).options();
        for key in ["nikodesk-allow-virtual-display", "nikodesk-lock-on-last-control", "enable-privacy-mode", "enable-remote-restart"] {
            if let Some(value) = desired.get(key) {
                settings.options.insert(key.into(), value.clone());
            } else {
                settings.options.remove(key);
            }
        }
        let bytes = serialize(&settings)?;
        let (mut config, actual) = decode_runtime_fields(context, file(files, IDENTITY_FILE)?, &bytes)?;
        let confirmed = config.id == previous.public_id && actual.options.len() == settings.options.len()
            && actual.options.iter().all(|(key, value)| settings.options.get(key) == Some(value));
        memzero(&mut config.key_pair.0);
        memzero(&mut config.key_pair.1);
        unsafe { memzero(config.password.as_bytes_mut()); }
        if !confirmed { bail!("machine_policy_update_unconfirmed"); }
        Ok(bytes)
    }
    /// Rotates only the verifier and its salt. The caller must stop the owned
    /// service and atomically replace the identity file after local approval.
    pub fn prepare_password_update(
        context: &MachineEncryptionContext,
        files: &BTreeMap<String, Vec<u8>>,
        server: &MachineProfileServer,
        password: &MachineUnattendedPassword,
    ) -> Result<Vec<u8>> {
        let previous = Self::inspect_existing(context, files, server, None)?;
        let mut identity: IdentityToml = parse(file(files, IDENTITY_FILE)?)?;
        let mut salt_bytes = [0; 24];
        random(&mut salt_bytes)?;
        let salt = base64::encode(&salt_bytes, base64::Variant::Original);
        memzero(&mut salt_bytes);
        let value = std::str::from_utf8(&password.0)
            .map_err(|_| anyhow!("explicit_unattended_password_required"))?;
        let h1 = SecretHash(compute_permanent_password_h1(value, &salt));
        let encoded = encode_permanent_password_encrypted_storage_from_h1_with_explicit_key(
            &h1.0, &context.0,
        ).ok_or_else(|| anyhow!("machine_password_encoding_failed"))?;
        unsafe { memzero(identity.password.as_bytes_mut()); }
        identity.password = encoded;
        identity.salt = salt;
        let mut bytes = serialize(&identity)?;
        let (mut config, _) = match decode_runtime_fields(context, &bytes, file(files, SETTINGS_FILE)?) {
            Ok(decoded) => decoded,
            Err(error) => {memzero(&mut bytes); return Err(error);}
        };
        let confirmed = config.id == previous.public_id && config.enc_id == identity.enc_id
            && sodiumoxide::utils::memcmp(&config.key_pair.0, &identity.key_pair.0)
            && config.key_pair.1 == identity.key_pair.1
            && decode_permanent_password_h1_from_storage_with_explicit_key(&config.password, &context.0)
                .is_some_and(|stored| {
                    let stored = SecretHash(stored);
                    constant_time_eq_32(&h1.0, &stored.0)
                });
        memzero(&mut config.key_pair.0);
        unsafe { memzero(config.password.as_bytes_mut()); }
        if !confirmed {memzero(&mut bytes); bail!("machine_password_update_unconfirmed");}
        Ok(bytes)
    }
    pub fn prepare(
        context: &MachineEncryptionContext,
        identity: FreshMachineIdentity,
        server: MachineProfileServer,
        password: MachineUnattendedPassword,
    ) -> Result<MachineProfile> {
        sodiumoxide::init().map_err(|_| anyhow!("machine_crypto_unavailable"))?;
        identity.verify_pair()?;
        let mut salt_bytes = [0; 24];
        random(&mut salt_bytes)?;
        let salt = base64::encode(salt_bytes, base64::Variant::Original);
        memzero(&mut salt_bytes);
        let value = std::str::from_utf8(&password.0)
            .map_err(|_| anyhow!("explicit_unattended_password_required"))?;
        let h1 = SecretHash(compute_permanent_password_h1(value, &salt));
        let encoded = encode_permanent_password_encrypted_storage_from_h1_with_explicit_key(
            &h1.0, &context.0,
        )
        .ok_or_else(|| anyhow!("machine_password_encoding_failed"))?;
        let enc_id = "00".to_owned()
            + &base64::encode(
                symmetric_crypt_with_explicit_key(identity.id.as_bytes(), true, &context.0)
                    .map_err(|_| anyhow!("machine_identity_encoding_failed"))?,
                base64::Variant::Original,
            );
        let config = IdentityToml {
            id: String::new(),
            enc_id,
            password: encoded,
            salt: salt.clone(),
            key_pair: (identity.secret.0.to_vec(), identity.public.0.to_vec()),
            key_confirmed: false,
            keys_confirmed: BTreeMap::new(),
        };
        let options = server.options();
        let settings = SettingsToml {
            rendezvous_server: String::new(),
            nat_type: 0,
            serial: 0,
            unlock_pin: String::new(),
            trusted_devices: String::new(),
            socks: None,
            options: options.clone(),
        };
        let mut files = BTreeMap::new();
        files.insert(SETTINGS_FILE.into(), serialize(&settings)?);
        files.insert(IDENTITY_FILE.into(), serialize(&config)?);
        let profile = MachineProfile {
            files,
            identity,
            h1,
            salt,
            options,
        };
        profile.verify_readback(context, profile.files())?;
        Ok(profile)
    }
}

/// Files contain a private machine identity; no Debug/Clone or secret getters.
pub struct MachineProfile {
    files: BTreeMap<String, Vec<u8>>,
    identity: FreshMachineIdentity,
    h1: SecretHash,
    salt: String,
    options: BTreeMap<String, String>,
}
impl MachineProfile {
    pub fn files(&self) -> &BTreeMap<String, Vec<u8>> {
        &self.files
    }
    pub fn public_id(&self) -> &str {
        self.identity.public_id()
    }
    pub fn public_key(&self) -> &[u8] {
        self.identity.public_key()
    }

    /// Caller supplies bytes read through its already-verified native handles.
    /// No Config decoder fallback or filesystem access is permitted here.
    pub fn verify_readback(
        &self,
        context: &MachineEncryptionContext,
        files: &BTreeMap<String, Vec<u8>>,
    ) -> Result<()> {
        if files.len() != 2 {
            bail!("invalid_machine_profile_files");
        }
        let config: IdentityToml = parse(file(files, IDENTITY_FILE)?)?;
        let settings: SettingsToml = parse(file(files, SETTINGS_FILE)?)?;
        if !config.id.is_empty()
            || config.key_confirmed
            || !config.keys_confirmed.is_empty()
            || config.salt != self.salt
            || config.salt.len() != DEFAULT_SALT_LEN
            || config.key_pair.0.len() != sign::SECRETKEYBYTES
            || config.key_pair.1 != self.identity.public.0
            || !sodiumoxide::utils::memcmp(&config.key_pair.0, &self.identity.secret.0)
        {
            bail!("invalid_machine_profile_identity");
        }
        let secret = sign::SecretKey::from_slice(&config.key_pair.0)
            .ok_or_else(|| anyhow!("invalid_machine_profile_identity"))?;
        let public = sign::PublicKey::from_slice(&config.key_pair.1)
            .ok_or_else(|| anyhow!("invalid_machine_profile_identity"))?;
        if !sign::verify_detached(
            &sign::sign_detached(IDENTITY_PROOF, &secret),
            IDENTITY_PROOF,
            &public,
        ) {
            bail!("invalid_machine_profile_identity");
        }
        let enc_id = config
            .enc_id
            .strip_prefix("00")
            .ok_or_else(|| anyhow!("invalid_machine_profile_identity"))?;
        let payload = base64::decode(enc_id, base64::Variant::Original)
            .map_err(|_| anyhow!("invalid_machine_profile_identity"))?;
        require_current_payload(&payload)?;
        let mut id = symmetric_crypt_with_explicit_key(&payload, false, &context.0)
            .map_err(|_| anyhow!("invalid_machine_profile_identity"))?;
        let id_matches = id == self.identity.id.as_bytes();
        memzero(&mut id);
        if !id_matches {
            bail!("invalid_machine_profile_identity");
        }
        let encoded = config
            .password
            .strip_prefix("01")
            .ok_or_else(|| anyhow!("invalid_machine_profile_verifier"))?;
        let payload = base64::decode(encoded, base64::Variant::Original)
            .map_err(|_| anyhow!("invalid_machine_profile_verifier"))?;
        require_current_payload(&payload)?;
        let h1 = SecretHash(
            decode_permanent_password_h1_from_storage_with_explicit_key(
                &config.password,
                &context.0,
            )
            .ok_or_else(|| anyhow!("invalid_machine_profile_verifier"))?,
        );
        if !constant_time_eq_32(&h1.0, &self.h1.0) {
            bail!("invalid_machine_profile_verifier");
        }
        if settings.options != self.options
            || !settings.rendezvous_server.is_empty()
            || settings.nat_type != 0
            || settings.serial != 0
            || !settings.unlock_pin.is_empty()
            || !settings.trusted_devices.is_empty()
            || settings.socks.is_some()
        {
            bail!("invalid_machine_profile_options");
        }
        Ok(())
    }
}
impl Drop for MachineProfile {
    fn drop(&mut self) {
        for bytes in self.files.values_mut() {
            memzero(bytes);
        }
    }
}

struct SecretHash([u8; 32]);
impl Drop for SecretHash {
    fn drop(&mut self) {
        memzero(&mut self.0);
    }
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct IdentityToml {
    #[serde(default, skip_serializing_if = "String::is_empty")]
    id: String,
    enc_id: String,
    password: String,
    salt: String,
    key_pair: (Vec<u8>, Vec<u8>),
    key_confirmed: bool,
    keys_confirmed: BTreeMap<String, bool>,
}
impl Drop for IdentityToml {
    fn drop(&mut self) {
        memzero(&mut self.key_pair.0);
    }
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct SettingsToml {
    rendezvous_server: String,
    nat_type: i32,
    serial: i32,
    unlock_pin: String,
    trusted_devices: String,
    #[serde(default)]
    socks: Option<toml::Value>,
    options: BTreeMap<String, String>,
}

fn random(bytes: &mut [u8]) -> Result<()> {
    if rand::rngs::OsRng.try_fill_bytes(bytes).is_err() {
        memzero(bytes);
        bail!("machine_random_unavailable");
    }
    Ok(())
}
fn serialize<T: serde::Serialize>(value: &T) -> Result<Vec<u8>> {
    toml::to_string(value)
        .map(String::into_bytes)
        .map_err(|_| anyhow!("machine_profile_encoding_failed"))
}
fn file<'a>(files: &'a BTreeMap<String, Vec<u8>>, name: &str) -> Result<&'a [u8]> {
    let bytes = files
        .get(name)
        .ok_or_else(|| anyhow!("invalid_machine_profile_files"))?;
    if bytes.is_empty() || bytes.len() > MAX_FILE_BYTES {
        bail!("invalid_machine_profile_files");
    }
    Ok(bytes)
}
fn parse<T: serde::de::DeserializeOwned>(bytes: &[u8]) -> Result<T> {
    let text = std::str::from_utf8(bytes).map_err(|_| anyhow!("invalid_machine_profile_format"))?;
    toml::from_str(text).map_err(|_| anyhow!("invalid_machine_profile_format"))
}
fn require_current_payload(bytes: &[u8]) -> Result<()> {
    if bytes.first() != Some(&1) || bytes.len() < 1 + secretbox::NONCEBYTES + secretbox::MACBYTES {
        bail!("invalid_machine_profile_ciphertext");
    }
    Ok(())
}

/// Startup accepts only current storage, without Config's permissive/default
/// decoder. File ACLs, caller authorization and private-server ownership remain
/// the native caller's responsibility.
pub(super) fn decode_runtime_fields(
    context: &MachineEncryptionContext,
    identity_bytes: &[u8],
    settings_bytes: &[u8],
) -> Result<(super::Config, super::Config2)> {
    sodiumoxide::init().map_err(|_| anyhow!("machine_crypto_unavailable"))?;
    if [identity_bytes, settings_bytes]
        .iter()
        .any(|bytes| bytes.is_empty() || bytes.len() > MAX_FILE_BYTES)
    {
        bail!("invalid_machine_profile_files");
    }
    let identity: IdentityToml = parse(identity_bytes)?;
    let settings: SettingsToml = parse(settings_bytes)?;
    if !identity.id.is_empty()
        || identity.salt.len() != DEFAULT_SALT_LEN
        || identity.key_pair.0.len() != sign::SECRETKEYBYTES
        || identity.key_pair.1.len() != sign::PUBLICKEYBYTES
        || identity.keys_confirmed.len() > 256
        || identity.keys_confirmed.keys().any(|host| {
            host.is_empty() || host.len() > 320 || host.trim() != host
                || host.chars().any(char::is_control)
        })
    {
        bail!("invalid_machine_profile_identity");
    }
    let salt = base64::decode(&identity.salt, base64::Variant::Original)
        .map_err(|_| anyhow!("invalid_machine_profile_identity"))?;
    if salt.len() != 24 || base64::encode(&salt, base64::Variant::Original) != identity.salt {
        bail!("invalid_machine_profile_identity");
    }
    let secret = sign::SecretKey::from_slice(&identity.key_pair.0)
        .ok_or_else(|| anyhow!("invalid_machine_profile_identity"))?;
    let public = sign::PublicKey::from_slice(&identity.key_pair.1)
        .ok_or_else(|| anyhow!("invalid_machine_profile_identity"))?;
    if !sign::verify_detached(
        &sign::sign_detached(IDENTITY_PROOF, &secret), IDENTITY_PROOF, &public,
    ) {
        bail!("invalid_machine_profile_identity");
    }
    let encoded_id = identity.enc_id.strip_prefix("00")
        .ok_or_else(|| anyhow!("invalid_machine_profile_identity"))?;
    let payload = base64::decode(encoded_id, base64::Variant::Original)
        .map_err(|_| anyhow!("invalid_machine_profile_identity"))?;
    require_current_payload(&payload)?;
    let mut id_bytes = context.crypt(&payload, false)
        .map_err(|_| anyhow!("invalid_machine_profile_identity"))?;
    let valid_id = id_bytes.len() == 10 && id_bytes.iter().all(u8::is_ascii_digit);
    let id = if valid_id { String::from_utf8(id_bytes.clone()).ok() } else { None };
    memzero(&mut id_bytes);
    let id = id.ok_or_else(|| anyhow!("invalid_machine_profile_identity"))?;
    let encoded_password = identity.password.strip_prefix("01")
        .ok_or_else(|| anyhow!("invalid_machine_profile_verifier"))?;
    let payload = base64::decode(encoded_password, base64::Variant::Original)
        .map_err(|_| anyhow!("invalid_machine_profile_verifier"))?;
    require_current_payload(&payload)?;
    let _verified_h1 = SecretHash(
        decode_permanent_password_h1_from_storage_with_explicit_key(&identity.password, &context.0)
            .ok_or_else(|| anyhow!("invalid_machine_profile_verifier"))?,
    );
    let rendezvous = settings.options.get("custom-rendezvous-server")
        .ok_or_else(|| anyhow!("invalid_machine_profile_options"))?;
    let relay = settings.options.get("relay-server")
        .ok_or_else(|| anyhow!("invalid_machine_profile_options"))?;
    let key = settings.options.get("key")
        .ok_or_else(|| anyhow!("invalid_machine_profile_options"))?;
    let optional_policy = |key: &str| -> Result<bool> {
        match settings.options.get(key).map(String::as_str) {
            None | Some("N") => Ok(false), Some("Y") => Ok(true),
            _ => Err(anyhow!("invalid_machine_profile_options")),
        }
    };
    let allow_virtual_display = optional_policy("nikodesk-allow-virtual-display")?;
    let lock_on_disconnect = optional_policy("nikodesk-lock-on-last-control")?;
    let allow_privacy = optional_policy("enable-privacy-mode")?;
    let allow_remote_restart = optional_policy("enable-remote-restart")?;
    let server = MachineProfileServer::new(rendezvous.clone(), relay.clone(), key.clone())?
        .with_session_policies(allow_virtual_display, lock_on_disconnect).with_privacy_policy(allow_privacy)
        .with_restart_policy(allow_remote_restart);
    let mut options = settings.options.clone();
    for key in ["nikodesk-allow-virtual-display", "nikodesk-lock-on-last-control"] {
        if options.get(key).is_some_and(|value| value == "N") { options.remove(key); }
    }
    if let Some(servers) = options.remove("rendezvous-servers") {
        // The mediator can persist ConfigureUpdate; it cannot introduce a new
        // destination into this fixed machine profile on its next startup.
        let list: Vec<_> = if servers.is_empty() { Vec::new() } else { servers.split(',').collect() };
        if list.len() > 16 || list.iter().any(|address| !same_rendezvous(address, rendezvous)) {
            bail!("invalid_machine_profile_options");
        }
    }
    if options != server.options()
        || !(0..=2).contains(&settings.nat_type)
        || settings.serial < 0
        || (!settings.rendezvous_server.is_empty()
            && !same_rendezvous(&settings.rendezvous_server, rendezvous))
        || !settings.unlock_pin.is_empty()
        || !settings.trusted_devices.is_empty()
        || settings.socks.is_some()
    {
        bail!("invalid_machine_profile_options");
    }
    Ok((
        super::Config {
            id,
            enc_id: identity.enc_id.clone(),
            password: identity.password.clone(),
            salt: identity.salt.clone(),
            key_pair: identity.key_pair.clone(),
            key_confirmed: identity.key_confirmed,
            keys_confirmed: identity.keys_confirmed.iter().map(|(k, v)| (k.clone(), *v)).collect(),
        },
        super::Config2 {
            rendezvous_server: settings.rendezvous_server,
            nat_type: settings.nat_type,
            serial: settings.serial,
            unlock_pin: settings.unlock_pin,
            trusted_devices: settings.trusted_devices,
            socks: None,
            options: settings.options.into_iter().collect(),
        },
    ))
}

fn same_rendezvous(candidate: &str, approved: &str) -> bool {
    if validate_address(candidate).is_err() { return false; }
    let with_port = |address: &str| {
        if address.starts_with('[') {
            if address.ends_with(']') { format!("{address}:21116") } else { address.to_owned() }
        } else if address.contains(':') {
            address.to_owned()
        } else {
            format!("{address}:21116")
        }
    };
    with_port(candidate) == with_port(approved)
}

fn validate_address(address: &str) -> Result<()> {
    if address.is_empty()
        || address.len() > 320
        || address.trim() != address
        || address.contains(['/', '@', '?', '#', '\\'])
    {
        bail!("invalid_machine_server_address");
    }
    let (host, port) = if let Some(tail) = address.strip_prefix('[') {
        let (host, tail) = tail
            .split_once(']')
            .ok_or_else(|| anyhow!("invalid_machine_server_address"))?;
        if !matches!(host.parse::<IpAddr>(), Ok(IpAddr::V6(_))) {
            bail!("invalid_machine_server_address");
        }
        (
            host,
            if tail.is_empty() {
                None
            } else {
                Some(
                    tail.strip_prefix(':')
                        .ok_or_else(|| anyhow!("invalid_machine_server_address"))?,
                )
            },
        )
    } else if address.matches(':').count() > 1 {
        bail!("invalid_machine_server_address");
    } else {
        address
            .split_once(':')
            .map_or((address, None), |(h, p)| (h, Some(p)))
    };
    if let Some(port) = port {
        if !port.bytes().all(|b| b.is_ascii_digit())
            || port.parse::<u16>().ok().filter(|p| *p > 0).is_none()
        {
            bail!("invalid_machine_server_address");
        }
    }
    match host.parse::<IpAddr>() {
        Ok(ip) if ip.is_unspecified() || ip.is_multicast() => {
            bail!("invalid_machine_server_address");
        }
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
                        || !part.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
                })
            {
                bail!("invalid_machine_server_address");
            }
            let lower = host.to_ascii_lowercase();
            if lower == "public" || lower == "rustdesk.com" || lower.ends_with(".rustdesk.com") {
                bail!("public_machine_server_forbidden");
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn context() -> MachineEncryptionContext {
        MachineEncryptionContext::from_uid_bytes(
            b"fixture-machine-context-1234567890123456789".to_vec(),
        )
        .unwrap()
    }
    fn server() -> MachineProfileServer {
        MachineProfileServer::new(
            "nas.fixture.local:21116".into(),
            "relay.fixture.local:21117".into(),
            base64::encode([7; 32], base64::Variant::Original),
        )
        .unwrap()
    }
    fn profile() -> MachineProfile {
        MachineProfileFactory::prepare(
            &context(),
            FreshMachineIdentity::generate().unwrap(),
            server(),
            MachineUnattendedPassword::from_explicit_user_entry("fixture-only password".into())
                .unwrap(),
        )
        .unwrap()
    }
    fn identity(files: &BTreeMap<String, Vec<u8>>) -> IdentityToml {
        parse(file(files, IDENTITY_FILE).unwrap()).unwrap()
    }
    fn change_identity(
        profile: &MachineProfile,
        change: impl FnOnce(&mut IdentityToml),
    ) -> BTreeMap<String, Vec<u8>> {
        let mut files = profile.files().clone();
        let mut config = identity(&files);
        change(&mut config);
        files.insert(IDENTITY_FILE.into(), serialize(&config).unwrap());
        files
    }

    #[test]
    fn machine_profile_fresh_keys_have_real_matching_signatures() {
        let a = FreshMachineIdentity::generate().unwrap();
        let b = FreshMachineIdentity::generate().unwrap();
        assert!(a.verify_pair().is_ok() && b.verify_pair().is_ok());
        assert!(a.public_key() != b.public_key());
        assert!((1_000_000_000..2_000_000_000).contains(&a.id.parse::<u32>().unwrap()));
    }
    #[test]
    fn machine_profile_optional_policies_roundtrip_without_enabling_other_capabilities() {
        for (screens, lock, privacy) in [(false, false, false), (true, false, false), (false, true, false), (true, true, true)] {
            let profile = MachineProfileFactory::prepare(&context(), FreshMachineIdentity::generate().unwrap(),
                server().with_session_policies(screens, lock).with_privacy_policy(privacy),
                MachineUnattendedPassword::from_explicit_user_entry("fixture-only".into()).unwrap()).unwrap();
            profile.verify_readback(&context(), profile.files()).unwrap();
            let (_, settings) = decode_runtime_fields(&context(),
                file(profile.files(), IDENTITY_FILE).unwrap(), file(profile.files(), SETTINGS_FILE).unwrap()).unwrap();
            assert_eq!(settings.options.get("nikodesk-allow-virtual-display").map(String::as_str), screens.then_some("Y"));
            assert_eq!(settings.options.get("nikodesk-lock-on-last-control").map(String::as_str), lock.then_some("Y"));
            assert_eq!(settings.options.get("enable-privacy-mode").map(String::as_str), Some(if privacy {"Y"} else {"N"}));
            assert!(settings.options.get("nikodesk-allow-voice-requests").is_none());
        }
    }
    #[test]
    fn machine_profile_unknown_policy_values_and_extra_permissions_are_rejected() {
        let profile = profile();
        for (key, value) in [("nikodesk-allow-virtual-display", "true"),
            ("nikodesk-lock-on-last-control", "1"), ("enable-privacy-mode", "true"), ("nikodesk-allow-voice-requests", "Y")] {
            let mut settings: SettingsToml = parse(file(profile.files(), SETTINGS_FILE).unwrap()).unwrap();
            settings.options.insert(key.into(), value.into());
            assert!(decode_runtime_fields(&context(), file(profile.files(), IDENTITY_FILE).unwrap(),
                &serialize(&settings).unwrap()).is_err());
        }
    }
    #[test]
    fn existing_profile_preserves_identity_and_requires_original_password_server_and_context() {
        let profile = profile();
        let password = MachineUnattendedPassword::from_explicit_user_entry("fixture-only password".into()).unwrap();
        let actual = MachineProfileFactory::inspect_existing(&context(),profile.files(),&server(),Some(&password)).unwrap();
        assert_eq!(actual.public_id, profile.public_id());
        assert!(!actual.allow_privacy && !actual.allow_virtual_display && !actual.lock_on_disconnect);
        let wrong = MachineUnattendedPassword::from_explicit_user_entry("other password".into()).unwrap();
        assert!(MachineProfileFactory::inspect_existing(&context(),profile.files(),&server(),Some(&wrong)).is_err());
        let other_server = MachineProfileServer::new("other.fixture.local:21116".into(),
            "relay.fixture.local:21117".into(),base64::encode([7;32],base64::Variant::Original)).unwrap();
        assert!(MachineProfileFactory::inspect_existing(&context(),profile.files(),&other_server,None).is_err());
        let other_context = MachineEncryptionContext::from_uid_bytes(b"different-machine-fixture".to_vec()).unwrap();
        assert!(MachineProfileFactory::inspect_existing(&other_context,profile.files(),&server(),None).is_err());
        assert_eq!(MachineProfileFactory::inspect_existing(&context(),profile.files(),&server(),None).unwrap().public_id,actual.public_id);
    }
    #[test]
    fn machine_profile_rejects_mismatched_fresh_key_material() {
        let mut identity = FreshMachineIdentity::generate().unwrap();
        identity.public.0[0] ^= 1;
        assert!(MachineProfileFactory::prepare(
            &context(),
            identity,
            server(),
            MachineUnattendedPassword::from_explicit_user_entry("fixture-only".into()).unwrap()
        )
        .is_err());
    }
    #[test]
    fn machine_policy_update_preserves_identity_verifier_server_and_runtime_fields() {
        let profile = profile();
        let mut files = profile.files().clone();
        let original_identity = files[IDENTITY_FILE].clone();
        let password = MachineUnattendedPassword::from_explicit_user_entry("fixture-only password".into()).unwrap();
        let mut settings: SettingsToml = parse(&files[SETTINGS_FILE]).unwrap();
        settings.serial = 17;
        settings.nat_type = 2;
        settings.rendezvous_server = "nas.fixture.local:21116".into();
        files.insert(SETTINGS_FILE.into(), serialize(&settings).unwrap());
        for (screens, lock, privacy, restart) in [(true, false, true, true), (false, true, false, false), (false, false, false, false)] {
            let bytes = MachineProfileFactory::prepare_policy_update(&context(), &files, &server(), screens, lock, privacy, restart).unwrap();
            files.insert(SETTINGS_FILE.into(), bytes);
            assert_eq!(files[IDENTITY_FILE], original_identity);
            let actual = MachineProfileFactory::inspect_existing(&context(), &files, &server(), Some(&password)).unwrap();
            assert_eq!(actual.public_id, profile.public_id());
            assert_eq!((actual.allow_virtual_display, actual.lock_on_disconnect, actual.allow_privacy, actual.allow_remote_restart), (screens, lock, privacy, restart));
            let stored: SettingsToml = parse(&files[SETTINGS_FILE]).unwrap();
            assert_eq!((stored.serial, stored.nat_type), (17, 2));
            assert_eq!(stored.rendezvous_server, "nas.fixture.local:21116");
        }
        let other_server = MachineProfileServer::new("other.fixture.local:21116".into(),
            "relay.fixture.local:21117".into(),base64::encode([7;32],base64::Variant::Original)).unwrap();
        assert!(MachineProfileFactory::prepare_policy_update(&context(), &files, &other_server, true, true, true, true).is_err());
        let other_context = MachineEncryptionContext::from_uid_bytes(b"different-machine-fixture".to_vec()).unwrap();
        assert!(MachineProfileFactory::prepare_policy_update(&other_context, &files, &server(), true, true, true, true).is_err());
    }
    #[test]
    fn password_rotation_preserves_device_keys_and_policies_and_invalidates_the_previous_verifier() {
        let profile = MachineProfileFactory::prepare(&context(), FreshMachineIdentity::generate().unwrap(),
            server().with_session_policies(true, true).with_privacy_policy(true).with_restart_policy(true),
            MachineUnattendedPassword::from_explicit_user_entry("original fixture secret".into()).unwrap()).unwrap();
        let before: IdentityToml = parse(file(profile.files(), IDENTITY_FILE).unwrap()).unwrap();
        let old_h1 = SecretHash(compute_permanent_password_h1("original fixture secret", &before.salt));
        for value in ["replacement fixture secret", "original fixture secret"] {
            let password = MachineUnattendedPassword::from_explicit_user_entry(value.into()).unwrap();
            let bytes = MachineProfileFactory::prepare_password_update(&context(), profile.files(), &server(), &password).unwrap();
            let after: IdentityToml = parse(&bytes).unwrap();
            assert!(after.enc_id == before.enc_id && after.key_pair == before.key_pair);
            assert!(after.key_confirmed == before.key_confirmed && after.keys_confirmed == before.keys_confirmed);
            assert!(after.salt != before.salt && after.password != before.password);
            let stored = SecretHash(decode_permanent_password_h1_from_storage_with_explicit_key(&after.password, &context().0).unwrap());
            assert!(!constant_time_eq_32(&stored.0, &old_h1.0));
            let mut files = profile.files().clone(); files.insert(IDENTITY_FILE.into(), bytes);
            let actual = MachineProfileFactory::inspect_existing(&context(), &files, &server(), Some(&password)).unwrap();
            assert_eq!(actual.public_id, profile.public_id());
            assert!(actual.allow_virtual_display && actual.lock_on_disconnect && actual.allow_privacy && actual.allow_remote_restart);
            assert!(file(&files, SETTINGS_FILE).unwrap() == file(profile.files(), SETTINGS_FILE).unwrap());
            if value != "original fixture secret" {
                let old = MachineUnattendedPassword::from_explicit_user_entry("original fixture secret".into()).unwrap();
                assert!(MachineProfileFactory::inspect_existing(&context(), &files, &server(), Some(&old)).is_err());
            }
            for bytes in files.values_mut() {memzero(bytes);}
        }
        let password = MachineUnattendedPassword::from_explicit_user_entry("fixture replacement".into()).unwrap();
        let other_server = MachineProfileServer::new("other.fixture.local:21116".into(),
            "relay.fixture.local:21117".into(),base64::encode([7;32],base64::Variant::Original)).unwrap();
        assert!(MachineProfileFactory::prepare_password_update(&context(),profile.files(),&other_server,&password).is_err());
        let other_context = MachineEncryptionContext::from_uid_bytes(b"other-fixture-machine-context".to_vec()).unwrap();
        assert!(MachineProfileFactory::prepare_password_update(&other_context,profile.files(),&server(),&password).is_err());
    }
    #[test]
    fn machine_profile_empty_context_never_falls_back_to_config() {
        assert!(MachineEncryptionContext::from_lookup(Err(())).is_err());
        for uid in [Vec::new(), b" \t\n".to_vec(), vec![0; 32], vec![b'a'; 4097]] {
            assert!(MachineEncryptionContext::from_uid_bytes(uid).is_err());
        }
    }
    #[test]
    fn machine_profile_context_matches_original_padding_and_truncation() {
        let short = MachineEncryptionContext::from_uid_bytes(b"fixture".to_vec()).unwrap();
        assert!(short.0 .0[..7] == *b"fixture" && short.0 .0[7..].iter().all(|b| *b == 0));
        let long = MachineEncryptionContext::from_uid_bytes(vec![b'a'; 64]).unwrap();
        assert!(long.0 .0 == [b'a'; 32]);
    }
    #[test]
    fn machine_profile_password_requires_explicit_nonempty_bounded_entry() {
        for value in [
            String::new(),
            " \t".into(),
            "x".repeat(129),
            "密".repeat(129),
        ] {
            assert!(MachineUnattendedPassword::from_explicit_user_entry(value).is_err());
        }
        assert!(MachineUnattendedPassword::from_explicit_user_entry("密".repeat(128)).is_ok());
    }
    #[test]
    fn machine_profile_roundtrip_uses_actual_config_serde_schema() {
        let profile = profile();
        assert!(profile.verify_readback(&context(), profile.files()).is_ok());
        let config: super::super::Config =
            parse(file(profile.files(), IDENTITY_FILE).unwrap()).unwrap();
        let settings: super::super::Config2 =
            parse(file(profile.files(), SETTINGS_FILE).unwrap()).unwrap();
        assert!(config.id.is_empty() && config.enc_id.starts_with("00"));
        assert!(config.password.starts_with("01") && config.salt.len() == DEFAULT_SALT_LEN);
        assert!(config.key_pair.1 == profile.public_key());
        assert!(settings.options.get("stop-service").map(String::as_str) == Some("N"));
        assert!(settings.options.len() == profile.options.len());
    }
    #[test]
    fn machine_profile_current_ciphertext_has_random_nonce_and_actual_inner_hash() {
        let context = context();
        let h1 = compute_permanent_password_h1("fixture-only", "fixture-salt");
        let a =
            encode_permanent_password_encrypted_storage_from_h1_with_explicit_key(&h1, &context.0)
                .unwrap();
        let b =
            encode_permanent_password_encrypted_storage_from_h1_with_explicit_key(&h1, &context.0)
                .unwrap();
        assert!(a != b);
        let payload = base64::decode(&a[2..], base64::Variant::Original).unwrap();
        assert!(require_current_payload(&payload).is_ok());
        let mut inner = symmetric_crypt_with_explicit_key(&payload, false, &context.0).unwrap();
        assert!(inner.starts_with(b"00") && inner.len() == 46);
        memzero(&mut inner);
        assert!(
            decode_permanent_password_h1_from_storage_with_explicit_key(&a, &context.0) == Some(h1)
        );
    }
    #[test]
    fn machine_profile_wrong_context_and_corrupted_ciphertext_fail_closed() {
        let profile = profile();
        let wrong =
            MachineEncryptionContext::from_uid_bytes(b"another-fixture-machine-context".to_vec())
                .unwrap();
        assert!(profile.verify_readback(&wrong, profile.files()).is_err());
        let files = change_identity(&profile, |c| {
            let mut bytes = base64::decode(&c.password[2..], base64::Variant::Original).unwrap();
            let last = bytes.len() - 1;
            bytes[last] ^= 1;
            c.password = "01".to_owned() + &base64::encode(bytes, base64::Variant::Original);
        });
        assert!(profile.verify_readback(&context(), &files).is_err());
    }
    #[test]
    fn machine_profile_plain_or_raw_hashed_password_is_not_storage() {
        let profile = profile();
        for storage in [
            "fixture-only password".into(),
            "00".to_owned() + &base64::encode([1; 32], base64::Variant::Original),
            "01!!!".into(),
        ] {
            let files = change_identity(&profile, |c| c.password = storage);
            assert!(profile.verify_readback(&context(), &files).is_err());
        }
    }
    #[test]
    fn machine_profile_literal_hash_shaped_user_password_is_rehashed() {
        let value = "00".to_owned() + &base64::encode([1; 32], base64::Variant::Original);
        let profile = MachineProfileFactory::prepare(
            &context(),
            FreshMachineIdentity::generate().unwrap(),
            server(),
            MachineUnattendedPassword::from_explicit_user_entry(value.clone()).unwrap(),
        )
        .unwrap();
        let c = identity(profile.files());
        let stored =
            decode_permanent_password_h1_from_storage_with_explicit_key(&c.password, &context().0)
                .unwrap();
        assert!(stored == compute_permanent_password_h1(&value, &c.salt));
        assert!(stored != [1; 32]);
    }
    #[test]
    fn machine_profile_no_legacy_zero_nonce_payload_is_accepted() {
        let profile = profile();
        let files = change_identity(&profile, |c| {
            let legacy = secretbox::seal(
                b"legacy-fixture",
                &secretbox::Nonce([0; secretbox::NONCEBYTES]),
                &context().0,
            );
            c.password = "01".to_owned() + &base64::encode(legacy, base64::Variant::Original);
        });
        assert!(profile.verify_readback(&context(), &files).is_err());
    }
    #[test]
    fn machine_profile_legacy_mac_that_looks_like_v1_still_fails_closed() {
        let profile = profile();
        let inner = super::super::permanent_password::encode_permanent_password_storage_from_h1(
            &profile.h1.0,
        );
        // A legacy MAC can begin with the v1 tag; length/tag checks alone are
        // insufficient. Find an actual authenticated fixture, not fake bytes.
        let fixture = (0..65536)
            .find_map(|index| {
                let context = MachineEncryptionContext::from_uid_bytes(
                    format!("fixture-legacy-context-{index:05}").into_bytes(),
                )
                .unwrap();
                let cipher = secretbox::seal(
                    inner.as_bytes(),
                    &secretbox::Nonce([0; secretbox::NONCEBYTES]),
                    &context.0,
                );
                (cipher.first() == Some(&1)).then_some((context, cipher))
            })
            .unwrap();
        assert!(require_current_payload(&fixture.1).is_ok());
        assert!(secretbox::open(
            &fixture.1,
            &secretbox::Nonce([0; secretbox::NONCEBYTES]),
            &fixture.0 .0
        )
        .is_ok());
        let files = change_identity(&profile, |config| {
            config.enc_id = "00".to_owned()
                + &base64::encode(
                    symmetric_crypt_with_explicit_key(
                        profile.public_id().as_bytes(),
                        true,
                        &fixture.0 .0,
                    )
                    .unwrap(),
                    base64::Variant::Original,
                );
            config.password =
                "01".to_owned() + &base64::encode(&fixture.1, base64::Variant::Original);
        });
        assert!(profile.verify_readback(&fixture.0, &files).is_err());
    }
    #[test]
    fn machine_profile_id_key_and_salt_replacement_are_rejected() {
        let profile = profile();
        let id = change_identity(&profile, |c| c.id = "1234567890".into());
        let key = change_identity(&profile, |c| c.key_pair.0[0] ^= 1);
        let salt = change_identity(&profile, |c| c.salt.replace_range(..1, "!"));
        for files in [id, key, salt] {
            assert!(profile.verify_readback(&context(), &files).is_err());
        }
    }
    #[test]
    fn machine_profile_wrong_hash_under_correct_key_is_rejected() {
        let profile = profile();
        let files = change_identity(&profile, |c| {
            c.password = encode_permanent_password_encrypted_storage_from_h1_with_explicit_key(
                &[6; 32],
                &context().0,
            )
            .unwrap()
        });
        assert!(profile.verify_readback(&context(), &files).is_err());
    }
    #[test]
    fn machine_profile_private_server_and_stop_service_options_are_exact() {
        let profile = profile();
        for key in [
            "stop-service",
            "custom-rendezvous-server",
            "relay-server",
            "key",
            "enable-audio",
            "conn-type",
        ] {
            let mut files = profile.files().clone();
            let mut settings: SettingsToml = parse(file(&files, SETTINGS_FILE).unwrap()).unwrap();
            settings
                .options
                .insert(key.into(), "changed-fixture".into());
            files.insert(SETTINGS_FILE.into(), serialize(&settings).unwrap());
            assert!(profile.verify_readback(&context(), &files).is_err());
        }
    }
    #[test]
    fn machine_profile_unknown_settings_proxy_and_bad_shape_are_rejected() {
        let profile = profile();
        let mut files = profile.files().clone();
        let mut unknown = b"unknown = true\n".to_vec();
        unknown.extend_from_slice(files.get(IDENTITY_FILE).unwrap());
        files.insert(IDENTITY_FILE.into(), unknown);
        assert!(profile.verify_readback(&context(), &files).is_err());
        let mut files = profile.files().clone();
        let mut settings: SettingsToml = parse(file(&files, SETTINGS_FILE).unwrap()).unwrap();
        settings.socks = Some(toml::Value::String("proxy-fixture".into()));
        files.insert(SETTINGS_FILE.into(), serialize(&settings).unwrap());
        assert!(profile.verify_readback(&context(), &files).is_err());
        let mut files = profile.files().clone();
        files.insert("RustDesk.toml".into(), Vec::new());
        assert!(profile.verify_readback(&context(), &files).is_err());
        let mut files = profile.files().clone();
        files.remove(SETTINGS_FILE);
        assert!(profile.verify_readback(&context(), &files).is_err());
    }
    #[test]
    fn machine_profile_unbounded_invalid_utf8_and_duplicate_toml_fail_closed() {
        let profile = profile();
        for bytes in [vec![0; MAX_FILE_BYTES + 1], vec![255], Vec::new()] {
            let mut files = profile.files().clone();
            files.insert(IDENTITY_FILE.into(), bytes);
            assert!(profile.verify_readback(&context(), &files).is_err());
        }
        let mut files = profile.files().clone();
        let mut duplicate = b"enc_id = \"duplicate\"\n".to_vec();
        duplicate.extend_from_slice(files.get(IDENTITY_FILE).unwrap());
        files.insert(IDENTITY_FILE.into(), duplicate);
        assert!(profile.verify_readback(&context(), &files).is_err());
    }
    #[test]
    fn machine_profile_public_and_invalid_server_addresses_are_rejected() {
        for address in [
            "",
            " public",
            "public",
            "RustDesk.COM",
            "x.rustdesk.com:21116",
            "https://nas.local",
            "nas.local/",
            "nas.local:0",
            "nas.local:65536",
            "[::]",
            "0.0.0.0",
            "224.0.0.1",
            "bad..host",
            "::1",
            "nas.local:abc",
        ] {
            assert!(MachineProfileServer::new(
                address.into(),
                String::new(),
                base64::encode([7; 32], base64::Variant::Original)
            )
            .is_err());
        }
        for address in [
            "nas.fixture.local:21116",
            "192.0.2.1",
            "[2001:db8::1]:21116",
        ] {
            assert!(MachineProfileServer::new(
                address.into(),
                String::new(),
                base64::encode([7; 32], base64::Variant::Original)
            )
            .is_ok());
        }
    }
    #[test]
    fn machine_profile_server_key_and_relay_are_checked_without_dns() {
        for key in [
            String::new(),
            "!!!".into(),
            base64::encode([0; 32], base64::Variant::Original),
            base64::encode([1; 31], base64::Variant::Original),
        ] {
            assert!(
                MachineProfileServer::new("nas.fixture.local".into(), String::new(), key).is_err()
            );
        }
        assert!(MachineProfileServer::new(
            "nas.fixture.local".into(),
            "public".into(),
            base64::encode([7; 32], base64::Variant::Original)
        )
        .is_err());
    }
}
