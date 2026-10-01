use super::ResultType;
use hbb_common::{
    anyhow::{anyhow, bail},
    sodiumoxide::utils::memzero,
};
use windows::{
    core::{PCWSTR, PWSTR},
    Win32::Security::Credentials::*,
};

fn target(account: &str) -> Vec<u16> {
    format!("NikoDesk/controller-credentials/v1/{account}\0")
        .encode_utf16()
        .collect()
}
fn missing(error: &windows::core::Error) -> bool {
    error.code().0 as u32 == 0x80070490
}
struct Credential(*mut CREDENTIALW);
impl Drop for Credential {
    fn drop(&mut self) {
        unsafe {
            if !self.0.is_null() {
                let value = &mut *self.0;
                if !value.CredentialBlob.is_null() && value.CredentialBlobSize <= 4096 {
                    memzero(std::slice::from_raw_parts_mut(
                        value.CredentialBlob,
                        value.CredentialBlobSize as usize,
                    ));
                }
                CredFree(self.0.cast());
            }
        }
    }
}
pub(super) fn read(account: &str) -> ResultType<Option<Vec<u8>>> {
    let name = target(account);
    let mut pointer = std::ptr::null_mut();
    match unsafe { CredReadW(PCWSTR(name.as_ptr()), CRED_TYPE_GENERIC, None, &mut pointer) } {
        Err(error) if missing(&error) => return Ok(None),
        Err(_) => bail!("secure_credentials_unavailable"),
        Ok(()) => {}
    }
    let guard = Credential(pointer);
    if guard.0.is_null() {
        bail!("secure_credentials_invalid");
    }
    let credential = unsafe { &*guard.0 };
    if credential.Type != CRED_TYPE_GENERIC
        || credential.CredentialBlobSize > 4096
        || credential.CredentialBlob.is_null()
    {
        bail!("secure_credentials_invalid");
    }
    Ok(Some(
        unsafe {
            std::slice::from_raw_parts(
                credential.CredentialBlob,
                credential.CredentialBlobSize as usize,
            )
        }
        .to_vec(),
    ))
}
pub(super) fn write(account: &str, bytes: &[u8]) -> ResultType<()> {
    let mut name = target(account);
    let mut user: Vec<_> = "NikoDesk\0".encode_utf16().collect();
    let mut blob = bytes.to_vec();
    let credential = CREDENTIALW {
        Type: CRED_TYPE_GENERIC,
        TargetName: PWSTR(name.as_mut_ptr()),
        UserName: PWSTR(user.as_mut_ptr()),
        CredentialBlobSize: blob.len() as u32,
        CredentialBlob: blob.as_mut_ptr(),
        Persist: CRED_PERSIST_LOCAL_MACHINE,
        ..Default::default()
    };
    let result = unsafe { CredWriteW(&credential, 0) };
    memzero(&mut blob);
    result.map_err(|_| anyhow!("secure_credentials_unavailable"))
}
pub(super) fn delete(account: &str) -> ResultType<()> {
    let name = target(account);
    match unsafe { CredDeleteW(PCWSTR(name.as_ptr()), CRED_TYPE_GENERIC, None) } {
        Ok(()) => Ok(()),
        Err(error) if missing(&error) => Ok(()),
        Err(_) => Err(anyhow!("secure_credentials_unavailable")),
    }
}
