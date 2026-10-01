use super::approval::LocalApprovalGrant;
use hbb_common::{
    anyhow::{anyhow, bail, Result},
    config::{
        MachineEncryptionContext, MachineProfileFactory as SharedFactory, MachineProfileServer,
    },
};
use sha2::{Digest, Sha256};
use std::{collections::BTreeMap, sync::Arc};

pub(super) use hbb_common::config::{
    FreshMachineIdentity as MachineIdentity, MachineUnattendedPassword as UnattendedSecret,
};
pub(super) type MachineProfile = Arc<hbb_common::config::MachineProfile>;

pub(crate) struct ServerInput {
    pub(super) rendezvous: String,
    pub(super) relay: String,
    pub(super) public_key: String,
    pub(super) settings_revision: u64,
}

/// A comparison binding, not an authentication mechanism. Only the actual
/// broker may supply the original grant and refresh its caller/snapshot.
#[derive(PartialEq, Eq)]
struct ApprovalBinding([u8; 32]);
impl ApprovalBinding {
    fn capture(grant: &LocalApprovalGrant) -> Self {
        let mut digest = Sha256::new();
        digest.update(b"NikoDesk install profile binding v1\0");
        for value in [
            grant.origin().pid() as u64,
            grant.origin().creation(),
            grant.origin().settings_generation(),
            grant.server().settings_revision,
            u64::from(grant.consent().start_after_commit),
            u64::from(grant.consent().allow_virtual_display),
            u64::from(grant.consent().lock_on_disconnect),
            u64::from(grant.consent().allow_privacy),
            u64::from(grant.consent().allow_remote_restart),
            grant.consent().action as u64,
        ] {
            digest.update(value.to_le_bytes());
        }
        for value in [
            grant.origin().user_sid(),
            grant.origin().image_sha256(),
            grant.origin().namespace(),
            grant.server().rendezvous.as_str(),
            grant.server().relay.as_str(),
            grant.server().public_key.as_str(),
            grant.consent().id(),
        ] {
            digest.update((value.len() as u64).to_le_bytes());
            digest.update(value.as_bytes());
        }
        Self(digest.finalize().into())
    }
}

/// Concrete product codec; no replaceable fake profile factory is accepted by
/// NativeSetup. It owns the exact original snapshot/context/readback expectation.
pub(crate) struct MachineProfileFactory {
    context: MachineEncryptionContext,
    server: Option<MachineProfileServer>,
    binding: ApprovalBinding,
    expected: Option<MachineProfile>,
}
impl MachineProfileFactory {
    pub(crate) fn from_approved_snapshot(approval: &LocalApprovalGrant) -> Result<Self> {
        let (server, binding) = Self::capture_snapshot(approval)?;
        let context = MachineEncryptionContext::from_os_machine_uid()?;
        Ok(Self {
            context,
            server: Some(server),
            binding,
            expected: None,
        })
    }

    fn capture_snapshot(
        approval: &LocalApprovalGrant,
    ) -> Result<(MachineProfileServer, ApprovalBinding)> {
        approval.revalidate()?;
        let server = MachineProfileServer::new(
            approval.server().rendezvous.clone(),
            approval.server().relay.clone(),
            approval.server().public_key.clone(),
        )?.with_session_policies(approval.consent().allow_virtual_display, approval.consent().lock_on_disconnect)
            .with_privacy_policy(approval.consent().allow_privacy).with_restart_policy(approval.consent().allow_remote_restart);
        Ok((server, ApprovalBinding::capture(approval)))
    }

    pub(super) fn validate_private_server(&self, approval: &LocalApprovalGrant) -> Result<()> {
        approval.revalidate()?;
        if self.binding != ApprovalBinding::capture(approval) {
            bail!("authenticated_install_snapshot_changed");
        }
        Ok(())
    }

    pub(super) fn prepare(
        &mut self,
        identity: MachineIdentity,
        approval: &LocalApprovalGrant,
        password: UnattendedSecret,
    ) -> Result<MachineProfile> {
        self.validate_private_server(approval)?;
        if self.expected.is_some() {
            bail!("machine_profile_already_prepared");
        }
        let server = self
            .server
            .take()
            .ok_or_else(|| anyhow!("machine_profile_snapshot_consumed"))?;
        let profile = Arc::new(SharedFactory::prepare(
            &self.context,
            identity,
            server,
            password,
        )?);
        self.expected = Some(Arc::clone(&profile));
        Ok(profile)
    }

    pub(super) fn verify_readback(
        &self,
        files: &BTreeMap<String, Vec<u8>>,
        approval: &LocalApprovalGrant,
    ) -> Result<String> {
        self.validate_private_server(approval)?;
        let profile = self
            .expected
            .as_ref()
            .ok_or_else(|| anyhow!("existing_machine_profile_requires_verified_expectation"))?;
        profile.verify_readback(&self.context, files)?;
        Ok(profile.public_id().to_owned())
    }
    pub(super) fn verify_existing(&self, files: &BTreeMap<String, Vec<u8>>, approval: &LocalApprovalGrant,
        password: &UnattendedSecret) -> Result<String> {
        self.validate_private_server(approval)?;
        let server = self.server.as_ref().ok_or_else(||anyhow!("machine_profile_snapshot_consumed"))?;
        let actual = SharedFactory::inspect_existing(&self.context, files, server, Some(password))?;
        if actual.allow_virtual_display != approval.consent().allow_virtual_display
            || actual.lock_on_disconnect != approval.consent().lock_on_disconnect
            || actual.allow_privacy != approval.consent().allow_privacy
            || actual.allow_remote_restart != approval.consent().allow_remote_restart { bail!("repeat_machine_policy_mismatch"); }
        Ok(actual.public_id)
    }
}

pub(super) fn wipe(bytes: &mut [u8]) {
    hbb_common::sodiumoxide::utils::memzero(bytes);
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn profile_binding_has_exact_server_revision_and_address() {
        let a = LocalApprovalGrant::fixture();
        let b = LocalApprovalGrant::fixture();
        assert!(ApprovalBinding::capture(&a) == ApprovalBinding::capture(&b));
        let mut other = LocalApprovalGrant::fixture();
        other.server_for_fixture().settings_revision += 1;
        assert!(ApprovalBinding::capture(&a) != ApprovalBinding::capture(&other));
        other = LocalApprovalGrant::fixture();
        other.server_for_fixture().rendezvous.push_str("-other");
        assert!(ApprovalBinding::capture(&a) != ApprovalBinding::capture(&other));
    }
    #[test]
    fn snapshot_capture_uses_actual_shared_server_type_and_rejects_bad_key() {
        let mut fixture = LocalApprovalGrant::fixture();
        assert!(MachineProfileFactory::capture_snapshot(&fixture).is_ok());
        fixture.server_for_fixture().public_key.clear();
        assert!(MachineProfileFactory::capture_snapshot(&fixture).is_err());
    }
    #[test]
    fn optional_machine_policies_are_bound_to_the_actual_local_approval() {
        let original = LocalApprovalGrant::fixture();
        for (screens, lock) in [(true, false), (false, true), (true, true)] {
            let mut changed = LocalApprovalGrant::fixture();
            changed.consent_for_fixture().allow_virtual_display = screens;
            changed.consent_for_fixture().lock_on_disconnect = lock;
            assert!(ApprovalBinding::capture(&original) != ApprovalBinding::capture(&changed));
        }
        let mut changed = LocalApprovalGrant::fixture();
        changed.consent_for_fixture().allow_privacy = true;
        assert!(ApprovalBinding::capture(&original) != ApprovalBinding::capture(&changed));
        changed = LocalApprovalGrant::fixture();
        changed.consent_for_fixture().allow_remote_restart = true;
        assert!(ApprovalBinding::capture(&original) != ApprovalBinding::capture(&changed));
        changed = LocalApprovalGrant::fixture();
        changed.consent_for_fixture().action = super::super::policy::Action::Remove;
        assert!(ApprovalBinding::capture(&original) != ApprovalBinding::capture(&changed));
    }
}
