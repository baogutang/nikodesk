//! Dedicated setup transactions. Ordinary client/remote IPC cannot mint an
//! approval. The dedicated setup requires fixed compile-time pins and a real
//! kernel-bound local caller plus its own native confirmation.
pub(crate) mod approval;
pub(crate) mod broker_origin;
pub(crate) mod embedded_release;
pub(crate) mod policy;
pub(crate) mod profile;
pub(crate) mod transaction;
pub(crate) mod update_policy;
pub(crate) mod recovery_policy;
#[cfg(windows)]
pub(crate) mod windows;
pub(crate) mod wire;

#[cfg(windows)]
pub(crate) mod broker;
#[cfg(windows)]
pub(crate) mod local_ui;
