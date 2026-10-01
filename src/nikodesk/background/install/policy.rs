use hbb_common::anyhow::{self, bail, Result};
use hbb_common::serde_derive::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};

pub const SERVICE: &str = "NikoDeskHost";
pub const HOST: &str = "nikodesk-host.exe";
pub const MAX_PAYLOAD_BYTES: u64 = 512 * 1024 * 1024;
pub const MAX_TOTAL_BYTES: u64 = 2 * 1024 * 1024 * 1024;
pub const RETIRED_PROFILE: &str = "removed-machine-v1.json";
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RetiredMachine {
    pub version: u32,
    pub public_id: String,
    pub namespace: String,
}
impl RetiredMachine {
    pub fn validate(&self) -> Result<()> {
        if self.version != 1 || self.public_id.len() != 10 || self.public_id.starts_with('0')
            || !self.public_id.bytes().all(|value|value.is_ascii_digit())
            || !hex(&self.namespace) || self.namespace=="0".repeat(64) {bail!("removed_machine_record_unconfirmed");}
        Ok(())
    }
}
#[derive(Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all="snake_case")]
pub enum Action { #[default] Install, Stop, Resume, Remove, Upgrade, Repair, RecoverInstall, Configure, ChangePassword }
impl Action {
    pub(crate) fn accepts_session_policies(self) -> bool {
        matches!(self, Self::Install | Self::Configure)
    }
    pub(crate) fn accepts_password(self) -> bool {matches!(self, Self::Install | Self::ChangePassword)}
    pub(crate) fn accepts_start(self) -> bool {matches!(self, Self::Install | Self::Configure | Self::ChangePassword)}
}

pub fn hex(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|v| v.is_ascii_digit() || (b'a'..=b'f').contains(&v))
}

pub fn leaf(value: &str) -> bool {
    if value.is_empty()
        || value.len() > 255
        || !value.is_ascii()
        || value.contains(['/', '\\', ':', '"', '<', '>', '|', '?', '*'])
        || value.bytes().any(|v| v <= 32)
        || value.starts_with('.')
        || value.ends_with(['.', ' '])
    {
        return false;
    }
    let stem = value.split('.').next().unwrap_or("").to_ascii_uppercase();
    !matches!(stem.as_str(), "CON" | "PRN" | "AUX" | "NUL" | "CLOCK$")
        && !(stem.len() == 4
            && (stem.starts_with("COM") || stem.starts_with("LPT"))
            && matches!(stem.as_bytes()[3], b'1'..=b'9'))
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PayloadEntry {
    pub sha256: String,
    pub length: u64,
}

/// This manifest must be embedded in a separately authenticated setup binary.
/// A manifest read beside an untrusted download is never a trust anchor.
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ReleaseManifest {
    pub version: String,
    pub build: u32,
    pub files: BTreeMap<String, PayloadEntry>,
}
impl ReleaseManifest {
    pub fn validate(&self) -> Result<()> {
        if self.version.is_empty()
            || self.version.len() > 32
            || self.build == 0
            || !self.files.contains_key(HOST)
            || self.files.is_empty()
            || self.files.len() > 256
        {
            bail!("invalid_release_manifest");
        }
        let mut names = BTreeSet::new();
        let mut total = 0u64;
        for (name, pin) in &self.files {
            total = total
                .checked_add(pin.length)
                .ok_or_else(|| anyhow::anyhow!("payload_overflow"))?;
            if !leaf(name)
                || !hex(&pin.sha256)
                || pin.length == 0
                || pin.length > MAX_PAYLOAD_BYTES
                || !names.insert(name.to_ascii_lowercase())
                || total > MAX_TOTAL_BYTES
            {
                bail!("invalid_payload_pin");
            }
        }
        Ok(())
    }
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Provision {
    pub version: u32,
    pub enabled: bool,
    pub desktop_preauthorized: bool,
    pub consent_id: String,
    pub files: BTreeMap<String, String>,
}
impl Provision {
    pub fn from_manifest(
        manifest: &ReleaseManifest,
        consent: &LocalConsent,
        enabled: bool,
    ) -> Self {
        Self {
            version: 1,
            enabled,
            desktop_preauthorized: true,
            consent_id: consent.id.clone(),
            files: manifest
                .files
                .iter()
                .map(|(n, p)| (n.clone(), p.sha256.clone()))
                .collect(),
        }
    }
}

/// Passed only by a real local setup consent action. It is not permission to run
/// from ordinary client IPC, a remote message, or an automatic update callback.
pub struct LocalConsent {
    id: String,
    pub start_after_commit: bool,
    pub allow_virtual_display: bool,
    pub lock_on_disconnect: bool,
    pub allow_privacy: bool,
    pub allow_remote_restart: bool,
    pub action: Action,
}
impl LocalConsent {
    pub fn from_explicit_local_action(
        id: String,
        desktop: bool,
        machine_identity: bool,
        start_after_commit: bool,
    ) -> Result<Self> {
        if !hex(&id) || !desktop || !machine_identity {
            bail!("explicit_setup_consent_required");
        }
        Ok(Self {
            id,
            start_after_commit,
            allow_virtual_display: false,
            lock_on_disconnect: false,
            allow_privacy: false,
            allow_remote_restart: false,
            action: Action::Install,
        })
    }
    pub(super) fn with_session_policies(mut self, virtual_display: bool, lock: bool) -> Self {
        self.allow_virtual_display = virtual_display;
        self.lock_on_disconnect = lock;
        self
    }
    pub fn id(&self) -> &str {
        &self.id
    }
    pub(super) fn with_privacy_policy(mut self, allow: bool) -> Self { self.allow_privacy = allow; self }
    pub(super) fn with_restart_policy(mut self, allow: bool) -> Self { self.allow_remote_restart = allow; self }
    pub(super) fn with_action(mut self, action: Action) -> Self { self.action = action; self }
}

#[derive(Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct FileIdentity {
    pub volume: u32,
    pub high: u32,
    pub low: u32,
}
pub fn checked_file_identity(
    attributes: u32,
    links: u32,
    directory: bool,
    volume: u32,
    high: u32,
    low: u32,
) -> Result<FileIdentity> {
    if attributes & 0x400 != 0
        || (attributes & 0x10 != 0) != directory
        || !directory && links != 1
        || high == 0 && low == 0
    {
        bail!("reparse_hardlink_type_or_file_id_rejected");
    }
    Ok(FileIdentity { volume, high, low })
}

#[cfg(test)]
mod tests {
    use super::*;
    fn manifest() -> ReleaseManifest {
        ReleaseManifest {
            version: "1.1.0".into(),
            build: 6,
            files: BTreeMap::from([(
                HOST.into(),
                PayloadEntry {
                    sha256: "b".repeat(64),
                    length: 100,
                },
            )]),
        }
    }
    #[test]
    fn unsafe_win32_names_and_case_collisions_are_rejected() {
        for name in [
            "../x", "x/y", "x\\y", "a:b", "NUL.dll", "con", "COM1.exe", "CON .exe", "LPT9", "a.",
            "a ", ".private", "a\0b",
        ] {
            assert!(!leaf(name));
        }
        let mut m = manifest();
        m.files
            .insert("NIKODESK-HOST.EXE".into(), m.files[HOST].clone());
        assert!(m.validate().is_err());
        assert!(leaf("libvpx.dll"));
    }
    #[test]
    fn manifest_limits_and_exact_host_pin_are_mandatory() {
        let mut m = manifest();
        assert!(m.validate().is_ok());
        m.files.get_mut(HOST).unwrap().length = MAX_PAYLOAD_BYTES + 1;
        assert!(m.validate().is_err());
        m = manifest();
        m.files.get_mut(HOST).unwrap().sha256 = "A".repeat(64);
        assert!(m.validate().is_err());
        m = manifest();
        m.files.clear();
        assert!(m.validate().is_err());
    }
    #[test]
    fn consent_is_explicit_and_disabled_provision_does_not_enable_host() {
        assert!(
            LocalConsent::from_explicit_local_action("a".repeat(64), false, true, true).is_err()
        );
        assert!(
            LocalConsent::from_explicit_local_action("a".repeat(64), true, false, true).is_err()
        );
        let c =
            LocalConsent::from_explicit_local_action("a".repeat(64), true, true, false).unwrap();
        let p = Provision::from_manifest(&manifest(), &c, false);
        assert!(!p.enabled);
        assert_eq!(p.files.len(), 1);
    }
    #[test]
    fn removal_receipt_contains_only_a_retired_public_identity_and_closed_schema() {
        let receipt=RetiredMachine{version:1,public_id:"1234567890".into(),namespace:"a".repeat(64)};
        assert!(receipt.validate().is_ok());
        let mut json=serde_json::to_value(&receipt).unwrap();
        assert_eq!(json.as_object().unwrap().len(),3);
        json["private_key"]="not permitted".into();
        assert!(serde_json::from_value::<RetiredMachine>(json).is_err());
        for id in ["", "0123456789", "123abc7890"] {
            assert!(RetiredMachine{version:1,public_id:id.into(),namespace:"a".repeat(64)}.validate().is_err());
        }
    }
    #[test]
    fn production_file_fact_policy_rejects_reparse_hardlinks_and_unconfirmed_identity() {
        assert!(checked_file_identity(0x80, 1, false, 3, 1, 2).is_ok());
        assert!(checked_file_identity(0x10, 2, true, 3, 1, 2).is_ok());
        for (attrs, links, dir, high, low) in [
            (0x480, 1, false, 1, 2),
            (0x80, 2, false, 1, 2),
            (0x10, 1, false, 1, 2),
            (0x80, 1, true, 1, 2),
            (0x80, 1, false, 0, 0),
        ] {
            assert!(checked_file_identity(attrs, links, dir, 3, high, low).is_err());
        }
    }
}
