//! Host/worker checks. Facts here are supplied by kernel/file verification.
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

pub(crate) const HOST_SERVICE: &str = "NikoDeskHost";
pub(crate) const HOST_EXE: &str = "nikodesk-host.exe";
pub(crate) const SYSTEM_SID: &str = "S-1-5-18";

pub(crate) fn allows_storage_ace(mask: u32, trusted_principal: bool, private: bool) -> bool {
    // Generic write/all, delete, owner/DACL changes and filesystem mutation.
    const MUTATING: u32 = 0x500d0156;
    // Machine configuration contains a device private key and password verifier.
    const SECRET_READ: u32 = 0x80000009;
    trusted_principal || mask & MUTATING == 0 && (!private || mask & SECRET_READ == 0)
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Provision {
    pub version: u32,
    pub enabled: bool,
    pub desktop_preauthorized: bool,
    pub consent_id: String,
    pub files: BTreeMap<String, String>,
}
impl Provision {
    pub(crate) fn validate(&self) -> Result<(), &'static str> {
        if self.version != 1 || !self.enabled || !self.desktop_preauthorized {
            return Err("background_not_preauthorized");
        }
        if !hex(&self.consent_id) || self.files.is_empty() || self.files.len() > 256 {
            return Err("invalid_background_provision");
        }
        if !self.files.contains_key(HOST_EXE) {
            return Err("background_executable_not_pinned");
        }
        for (name, hash) in &self.files {
            if name.is_empty()
                || name.len() > 255
                || name.contains(['/', '\\', ':'])
                || name == "."
                || name == ".."
                || name.ends_with(['.', ' '])
                || !hex(hash)
            {
                return Err("invalid_background_file_pin");
            }
        }
        Ok(())
    }
}
pub(crate) fn hex(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|v| v.is_ascii_digit() || (b'a'..=b'f').contains(&v))
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct Binding {
    pub session: u32,
    pub generation: u64,
    pub nonce: [u8; 32],
}
impl Binding {
    pub(crate) fn valid(self) -> bool {
        self.session != 0
            && self.session != u32::MAX
            && self.generation != 0
            && self.nonce != [0; 32]
    }
    pub(crate) fn pipe(self) -> Result<String, &'static str> {
        if !self.valid() {
            return Err("invalid_background_binding");
        }
        let nonce = self
            .nonce
            .iter()
            .map(|v| format!("{v:02x}"))
            .collect::<String>();
        Ok(format!(
            r"\\.\pipe\NikoDeskHost\worker-{}-{}-{nonce}",
            self.session, self.generation
        ))
    }
}

#[derive(Clone, Debug)]
pub(crate) struct ProcessFacts {
    pub pid: u32,
    pub creation: u64,
    pub session: u32,
    pub system: bool,
    pub image_pin_verified: bool,
}
pub(crate) fn allows_worker(peer: &ProcessFacts, created: &ProcessFacts, binding: Binding) -> bool {
    binding.valid()
        && peer.system
        && peer.image_pin_verified
        && peer.pid != 0
        && peer.creation != 0
        && peer.pid == created.pid
        && peer.creation == created.creation
        && peer.session == binding.session
        && created.session == binding.session
        && created.system
        && created.image_pin_verified
}
pub(crate) fn allows_host(peer: &ProcessFacts, parent_pid: u32, parent_creation: u64) -> bool {
    peer.system
        && peer.image_pin_verified
        && peer.session == 0
        && peer.pid == parent_pid
        && peer.pid != 0
        && peer.creation != 0
        && peer.creation == parent_creation
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum WorkerState {
    Pending,
    Granted,
    Running,
    Revoked,
}
pub(crate) struct WorkerAuthorization {
    binding: Binding,
    state: WorkerState,
}
impl WorkerAuthorization {
    pub(crate) fn new(binding: Binding) -> Result<Self, &'static str> {
        if !binding.valid() {
            return Err("invalid_background_binding");
        }
        Ok(Self {
            binding,
            state: WorkerState::Pending,
        })
    }
    pub(crate) fn grant(
        &mut self,
        binding: Binding,
        kernel_peer_verified: bool,
    ) -> Result<(), &'static str> {
        if !kernel_peer_verified || binding != self.binding || self.state != WorkerState::Pending {
            return Err("background_grant_rejected");
        }
        self.state = WorkerState::Granted;
        Ok(())
    }
    pub(crate) fn ready(
        &mut self,
        binding: Binding,
        core_started: bool,
        desktop_selected: bool,
    ) -> Result<(), &'static str> {
        if binding != self.binding
            || self.state != WorkerState::Granted
            || !core_started
            || !desktop_selected
        {
            return Err("background_worker_not_ready");
        }
        self.state = WorkerState::Running;
        Ok(())
    }
    pub(crate) fn revoke(&mut self) {
        self.state = WorkerState::Revoked;
    }
    pub(crate) fn state(&self) -> WorkerState {
        self.state
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn binding() -> Binding {
        Binding {
            session: 1,
            generation: 1,
            nonce: [1; 32],
        }
    }
    fn facts() -> ProcessFacts {
        ProcessFacts {
            pid: 42,
            creation: 9,
            session: 1,
            system: true,
            image_pin_verified: true,
        }
    }
    #[test]
    fn machine_secret_read_and_child_mutation_require_a_trusted_principal() {
        for mask in [0x40000000, 0x10000000, 2, 4, 0x40, 0x40000, 0x80000] {
            assert!(!allows_storage_ace(mask, false, false));
            assert!(allows_storage_ace(mask, true, true));
        }
        assert!(allows_storage_ace(0x120089, false, false));
        assert!(!allows_storage_ace(0x120089, false, true));
        assert!(!allows_storage_ace(0x80000000, false, true));
        assert!(allows_storage_ace(0x120089, true, true));
    }
    #[test]
    fn same_pid_without_creation_session_system_and_file_identity_is_denied() {
        let original = facts();
        assert!(allows_worker(&original, &original, binding()));
        for peer in [
            ProcessFacts {
                creation: 10,
                ..facts()
            },
            ProcessFacts {
                session: 2,
                ..facts()
            },
            ProcessFacts {
                system: false,
                ..facts()
            },
            ProcessFacts {
                image_pin_verified: false,
                ..facts()
            },
        ] {
            assert!(!allows_worker(&peer, &original, binding()));
        }
        assert!(!allows_host(&original, 42, 9));
        assert!(allows_host(
            &ProcessFacts {
                session: 0,
                ..facts()
            },
            42,
            9
        ));
    }
    #[test]
    fn revoke_and_old_generation_never_become_running_via_late_ready() {
        let mut state = WorkerAuthorization::new(binding()).unwrap();
        assert!(state.ready(binding(), true, true).is_err());
        assert!(state.grant(binding(), false).is_err());
        state.grant(binding(), true).unwrap();
        assert!(state.ready(binding(), true, false).is_err());
        assert!(state
            .ready(
                Binding {
                    generation: 2,
                    ..binding()
                },
                true,
                true
            )
            .is_err());
        state.revoke();
        assert!(state.ready(binding(), true, true).is_err());
        assert!(state.grant(binding(), true).is_err());
        assert_eq!(state.state(), WorkerState::Revoked);
    }
    #[test]
    fn launch_binding_and_installer_provision_fail_closed() {
        for binding in [
            Binding {
                session: 0,
                ..binding()
            },
            Binding {
                session: u32::MAX,
                ..binding()
            },
            Binding {
                nonce: [0; 32],
                ..binding()
            },
            Binding {
                generation: 0,
                ..binding()
            },
        ] {
            assert!(binding.pipe().is_err());
        }
        let mut p = Provision {
            version: 1,
            enabled: false,
            desktop_preauthorized: true,
            consent_id: "a".repeat(64),
            files: BTreeMap::from([(HOST_EXE.into(), "b".repeat(64))]),
        };
        assert!(p.validate().is_err());
        p.enabled = true;
        assert!(p.validate().is_ok());
        p.files.insert("../foreign.dll".into(), "b".repeat(64));
        assert!(p.validate().is_err());
    }
}
