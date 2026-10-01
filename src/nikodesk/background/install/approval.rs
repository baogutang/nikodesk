//! No Deserialize or production shape-only constructor. A settings JSON or a
//! setup argument can never become authenticated local approval.
use super::{
    policy::{self, LocalConsent},
    profile::ServerInput,
};
use hbb_common::anyhow::{bail, Result};

pub(crate) struct LocalApprovalGrant {
    origin: CallerOrigin,
    server: ServerInput,
    consent: LocalConsent,
    #[cfg(windows)]
    authority: Option<std::sync::Arc<super::broker::BrokerAuthority>>,
    #[cfg(test)]
    fixture_current: bool,
}
pub(crate) struct CallerOrigin {
    pid: u32,
    creation: u64,
    user_sid: String,
    image_sha256: String,
    namespace: String,
    settings_generation: u64,
}
impl CallerOrigin {
    pub(crate) fn pid(&self) -> u32 {
        self.pid
    }
    pub(crate) fn creation(&self) -> u64 {
        self.creation
    }
    pub(crate) fn user_sid(&self) -> &str {
        &self.user_sid
    }
    pub(crate) fn image_sha256(&self) -> &str {
        &self.image_sha256
    }
    pub(crate) fn namespace(&self) -> &str {
        &self.namespace
    }
    pub(crate) fn settings_generation(&self) -> u64 {
        self.settings_generation
    }
}
impl LocalApprovalGrant {
    pub(crate) fn origin(&self) -> &CallerOrigin {
        &self.origin
    }
    pub(crate) fn server(&self) -> &ServerInput {
        &self.server
    }
    pub(crate) fn consent(&self) -> &LocalConsent {
        &self.consent
    }

    /// The real broker must refresh kernel-held caller/snapshot/one-use consent
    /// ownership here. No production authority is available in this batch.
    pub(crate) fn revalidate(&self) -> Result<()> {
        #[cfg(test)]
        if self.fixture_current {
            return self.validate_shape();
        }
        #[cfg(windows)]
        if let Some(authority) = &self.authority {
            self.validate_shape()?;
            return authority.refresh();
        }
        bail!("authenticated_local_install_broker_unavailable");
    }

    #[cfg(windows)]
    pub(super) fn from_confirmed(confirmed: super::broker::ConfirmedApproval) -> Result<Self> {
        let (origin, server, consent, authority) = confirmed.into_parts();
        let grant = Self {
            origin,
            server,
            consent,
            authority: Some(authority),
            #[cfg(test)]
            fixture_current: false,
        };
        grant.validate_shape()?;
        Ok(grant)
    }
    #[cfg(windows)]
    pub(super) fn reviewed_unsigned(&self) -> bool {
        self.authority
            .as_ref()
            .is_some_and(|a| a.reviewed_unsigned())
    }
    #[cfg(windows)]
    pub(super) fn from_kernel_caller(
        caller: &super::broker_origin::VerifiedUiCaller,
    ) -> Result<CallerOrigin> {
        let hex = |bytes: &[u8]| -> String { bytes.iter().map(|b| format!("{b:02x}")).collect() };
        Ok(CallerOrigin {
            pid: caller.pid(),
            creation: caller.creation(),
            user_sid: caller.user_sid_string()?,
            image_sha256: hex(caller.image_sha256()),
            namespace: hex(caller.namespace()),
            settings_generation: caller.settings_generation(),
        })
    }

    fn validate_shape(&self) -> Result<()> {
        let caller = &self.origin;
        if caller.pid == 0
            || caller.creation == 0
            || caller.settings_generation == 0
            || self.server.settings_revision == 0
            || !caller.user_sid.starts_with("S-1-")
            || caller.user_sid.len() > 184
            || matches!(
                caller.user_sid.as_str(),
                "S-1-5-18" | "S-1-5-19" | "S-1-5-20"
            )
            || !policy::hex(&caller.image_sha256)
            || !policy::hex(&caller.namespace)
        {
            bail!("invalid_authenticated_local_approval_shape");
        }
        Ok(())
    }

    #[cfg(test)]
    pub(super) fn server_for_fixture(&mut self) -> &mut ServerInput {
        &mut self.server
    }
    #[cfg(test)]
    pub(super) fn consent_for_fixture(&mut self) -> &mut LocalConsent { &mut self.consent }

    #[cfg(test)]
    pub(super) fn fixture() -> Self {
        Self {
            origin: CallerOrigin {
                pid: 42,
                creation: 9,
                user_sid: "S-1-5-21-1-2-3-1001".into(),
                image_sha256: "b".repeat(64),
                namespace: "c".repeat(64),
                settings_generation: 7,
            },
            server: ServerInput {
                rendezvous: "nas.fixture.local:21116".into(),
                relay: "relay.fixture.local:21117".into(),
                public_key: hbb_common::sodiumoxide::base64::encode(
                    [7; 32],
                    hbb_common::sodiumoxide::base64::Variant::Original,
                ),
                settings_revision: 3,
            },
            consent: LocalConsent::from_explicit_local_action("a".repeat(64), true, true, false)
                .unwrap(),
            #[cfg(windows)]
            authority: None,
            fixture_current: true,
        }
    }
}

/// Until an OS-backed broker exists, an ordinary setup request fails before
/// context acquisition, private key generation, filesystem or SCM actions.
pub(crate) fn require_authenticated_local_broker() -> Result<LocalApprovalGrant> {
    bail!("authenticated_local_install_broker_unavailable");
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn unbound_setup_request_cannot_mint_a_product_grant() {
        assert!(require_authenticated_local_broker().is_err());
    }
    #[test]
    fn service_accounts_or_empty_generations_fail_even_fixture_shape() {
        for sid in ["S-1-5-18", "S-1-5-19", "S-1-5-20", "arbitrary"] {
            let mut grant = LocalApprovalGrant::fixture();
            grant.origin.user_sid = sid.into();
            assert!(grant.revalidate().is_err());
        }
        let mut grant = LocalApprovalGrant::fixture();
        grant.server.settings_revision = 0;
        assert!(grant.revalidate().is_err());
    }
    #[test]
    fn origin_and_snapshot_remain_bound_and_revocation_is_not_shape_authority() {
        let mut grant = LocalApprovalGrant::fixture();
        assert!(grant.origin().pid() == 42 && grant.origin().creation() == 9);
        assert!(grant.origin().settings_generation() == 7 && grant.server().settings_revision == 3);
        grant.fixture_current = false;
        assert!(grant.revalidate().is_err());
    }
}
