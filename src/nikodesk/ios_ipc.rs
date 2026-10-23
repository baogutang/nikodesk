//! iOS runs no NikoDesk service, so the settings calls NikoDesk makes through
//! `crate::ipc` take the path they take on other platforms when no service
//! answers.
use crate::nikodesk::server_settings::{self, Deadline, SaveResult};
use hbb_common::{tokio, ResultType};
use std::collections::HashMap;

pub fn set_niko_option(key: &str, value: &str) -> ResultType<()> {
    let result = crate::nikodesk::set_option(key.to_owned(), value.to_owned());
    if result.is_err() {
        server_settings::reject_snapshot_write();
    }
    result
}

pub fn set_options(value: HashMap<String, String>) -> ResultType<()> {
    crate::nikodesk::save_options_locally(value)
}

pub(crate) async fn save_niko_private_server(json: String, deadline: Deadline) -> String {
    if deadline.check().is_err() {
        return SaveResult::unknown().json();
    }
    let result = tokio::task::spawn_blocking(move || {
        server_settings::save_locally(&json, deadline.wire()).json()
    })
    .await
    .unwrap_or_else(|_| SaveResult::unknown().json());
    crate::ui_interface::refresh_options();
    result
}

pub(crate) async fn patch_niko_option(key: String, value: String, deadline: Deadline) -> String {
    if deadline.check().is_err() {
        return SaveResult::unknown().json();
    }
    let result = tokio::task::spawn_blocking(move || {
        server_settings::patch_locally(&key, &value, deadline.wire()).json()
    })
    .await
    .unwrap_or_else(|_| SaveResult::unknown().json());
    crate::ui_interface::refresh_options();
    result
}
