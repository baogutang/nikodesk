use super::ResultType;
use hbb_common::anyhow::anyhow;
use security_framework::passwords::{
    delete_generic_password, get_generic_password, set_generic_password,
};

const SERVICE: &str = "io.nikodesk.controller.credentials.v1";
const MISSING: i32 = -25300; // errSecItemNotFound
pub(super) fn read(account: &str) -> ResultType<Option<Vec<u8>>> {
    match get_generic_password(SERVICE, account) {
        Ok(bytes) => Ok(Some(bytes)),
        Err(error) if error.code() == MISSING => Ok(None),
        Err(_) => Err(anyhow!("secure_credentials_unavailable")),
    }
}
pub(super) fn write(account: &str, bytes: &[u8]) -> ResultType<()> {
    set_generic_password(SERVICE, account, bytes)
        .map_err(|_| anyhow!("secure_credentials_unavailable"))
}
pub(super) fn delete(account: &str) -> ResultType<()> {
    match delete_generic_password(SERVICE, account) {
        Ok(()) => Ok(()),
        Err(error) if error.code() == MISSING => Ok(()),
        Err(_) => Err(anyhow!("secure_credentials_unavailable")),
    }
}
