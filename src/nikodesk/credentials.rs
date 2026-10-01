//! Controller credentials never enter PeerConfig or Flutter. Persist only after
//! successful remote authentication and an explicit local remember choice.
use super::server_scope::PeerStorageKey;
use hbb_common::{
    anyhow::{anyhow, bail},
    sodiumoxide::utils::memzero,
    ResultType,
};
use sha2::{Digest, Sha256};

#[cfg(target_os = "macos")]
#[path = "credentials/macos.rs"]
mod platform;
#[cfg(target_os = "windows")]
#[path = "credentials/windows.rs"]
mod platform;
#[cfg(target_os = "android")]
#[path = "credentials/android.rs"]
mod platform;
#[cfg(not(any(target_os = "macos", target_os = "windows", target_os = "android")))]
mod platform {
    pub(super) fn read(_: &str) -> super::ResultType<Option<Vec<u8>>> {
        Ok(None)
    }
    pub(super) fn write(_: &str, _: &[u8]) -> super::ResultType<()> {
        super::bail!("secure_credentials_unsupported")
    }
    pub(super) fn delete(_: &str) -> super::ResultType<()> {
        super::bail!("secure_credentials_unsupported")
    }
}

const MAGIC: &[u8] = b"NIKOCRED1";
const RECORD_LEN: usize = MAGIC.len() + 96;

// A salted authentication hash is still a credential. No Debug/Serialize.
pub(crate) struct StoredCredential {
    password: [u8; 32],
    salt: [u8; 32],
}
impl Drop for StoredCredential {
    fn drop(&mut self) {
        memzero(&mut self.password);
    }
}
impl StoredCredential {
    fn from_bytes(account: &str, bytes: &[u8]) -> ResultType<Self> {
        if bytes.len() != RECORD_LEN
            || &bytes[..MAGIC.len()] != MAGIC
            || bytes[MAGIC.len()..MAGIC.len() + 32] != Sha256::digest(account.as_bytes())[..]
        {
            bail!("secure_credentials_invalid");
        }
        let mut salt = [0; 32];
        let mut password = [0; 32];
        salt.copy_from_slice(&bytes[MAGIC.len() + 32..MAGIC.len() + 64]);
        password.copy_from_slice(&bytes[MAGIC.len() + 64..]);
        if password.iter().all(|byte| *byte == 0) {
            bail!("secure_credentials_invalid");
        }
        Ok(Self { password, salt })
    }
    pub(crate) fn password_for_salt(&self, salt: &str) -> Option<Vec<u8>> {
        (self.salt == Sha256::digest(salt.as_bytes())[..]).then(|| self.password.to_vec())
    }
}

fn account(key: &PeerStorageKey) -> String {
    format!(
        "{:x}",
        Sha256::digest(format!("nikodesk-controller-credential-v1\0{}", key.storage()).as_bytes())
    )
}
pub(crate) fn load(key: &PeerStorageKey) -> ResultType<Option<StoredCredential>> {
    let account = account(key);
    let Some(mut bytes) = platform::read(&account)? else {
        return Ok(None);
    };
    let credential = StoredCredential::from_bytes(&account, &bytes);
    memzero(&mut bytes);
    credential.map(Some)
}
pub(crate) fn save(key: &PeerStorageKey, salt: &str, password: &[u8]) -> ResultType<()> {
    if password.len() != 32 || password.iter().all(|byte| *byte == 0) || salt.is_empty() {
        bail!("secure_credentials_invalid");
    }
    let account = account(key);
    let mut bytes = Vec::with_capacity(RECORD_LEN);
    bytes.extend_from_slice(MAGIC);
    bytes.extend_from_slice(&Sha256::digest(account.as_bytes()));
    bytes.extend_from_slice(&Sha256::digest(salt.as_bytes()));
    bytes.extend_from_slice(password);
    let result = (|| {
        platform::write(&account, &bytes)?;
        let mut observed =
            platform::read(&account)?.ok_or_else(|| anyhow!("secure_credentials_unconfirmed"))?;
        let same = observed == bytes;
        memzero(&mut observed);
        if !same {
            bail!("secure_credentials_unconfirmed");
        }
        Ok(())
    })();
    memzero(&mut bytes);
    result
}
pub(crate) fn delete(key: &PeerStorageKey) -> ResultType<()> {
    let account = account(key);
    platform::delete(&account)?;
    match platform::read(&account)? {
        None => Ok(()),
        Some(mut bytes) => {
            memzero(&mut bytes);
            bail!("secure_credentials_delete_unconfirmed");
        }
    }
}

// Native selectors capture the private namespace even when settings change in
// another window. These existing FFI methods return status, never the secret.
#[derive(serde::Deserialize)]
#[serde(deny_unknown_fields)]
struct Selector {
    schema: u32,
    namespace: String,
    id: String,
}
pub(crate) fn selected(input: &str) -> ResultType<PeerStorageKey> {
    let scope =
        super::server_scope::current().ok_or_else(|| anyhow!("private_scope_unavailable"))?;
    let id = if input.starts_with('{') {
        if input.len() > 256 {
            bail!("credential_selector_invalid");
        }
        let selector: Selector = serde_json::from_str(input)?;
        if selector.schema != 1 || selector.namespace != scope.namespace() {
            bail!("credential_scope_changed");
        }
        selector.id
    } else {
        input.to_owned()
    };
    scope
        .peer_key(&id)
        .ok_or_else(|| anyhow!("credential_selector_invalid"))
}
pub(crate) fn status(input: &str) -> &'static str {
    match selected(input).and_then(|key| load(&key)) {
        Ok(Some(_)) => "present",
        Ok(None) => "missing",
        Err(_) => "unavailable",
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn credential_records_bind_account_and_salt_and_never_accept_truncation() {
        let account = "synthetic-account";
        let mut bytes = MAGIC.to_vec();
        bytes.extend_from_slice(&Sha256::digest(account));
        bytes.extend_from_slice(&Sha256::digest("synthetic-salt"));
        bytes.extend_from_slice(&[7; 32]);
        let credential = StoredCredential::from_bytes(account, &bytes).unwrap();
        assert_eq!(
            credential.password_for_salt("synthetic-salt"),
            Some(vec![7; 32])
        );
        assert!(credential.password_for_salt("different-salt").is_none());
        assert!(StoredCredential::from_bytes("another-account", &bytes).is_err());
        for length in 0..bytes.len() {
            assert!(StoredCredential::from_bytes(account, &bytes[..length]).is_err());
        }
    }
    #[test]
    fn accounts_are_isolated_across_private_servers_and_peers() {
        let a = super::super::server_scope::ServerScope::from_namespace(&"a".repeat(64)).unwrap();
        let b = super::super::server_scope::ServerScope::from_namespace(&"b".repeat(64)).unwrap();
        assert_ne!(
            account(&a.peer_key("123456789").unwrap()),
            account(&b.peer_key("123456789").unwrap())
        );
        assert_ne!(
            account(&a.peer_key("123456789").unwrap()),
            account(&a.peer_key("987654321").unwrap())
        );
    }
}
