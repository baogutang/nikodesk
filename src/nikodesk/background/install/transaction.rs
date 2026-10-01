use hbb_common::anyhow::{self, Result};
use hbb_common::serde_derive::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum Phase {
    Preflight,
    Roots,
    Journal,
    Payload,
    DisabledService,
    Profile,
    Verify,
    Consent,
    AutoStart,
    Started,
    Complete,
    Recovery,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Journal {
    pub version: u32,
    pub transaction: String,
    pub release_sha256: String,
    pub phase: Phase,
}

/// Real platform owns every created file/directory/service. Failure does not
/// discard it: this object remains available for explicit rollback/recovery.
pub trait Platform {
    fn perform(&mut self, phase: Phase) -> Result<()>;
    fn persist_phase(&mut self, phase: Phase) -> Result<()>;
    fn disable_and_confirm_stopped(&mut self) -> Result<()>;
    fn remove_only_owned_artifacts(&mut self) -> Result<()>;
}
pub struct Transaction<P: Platform> {
    platform: P,
    phase: Phase,
    start: bool,
    error: Option<anyhow::Error>,
    recovery_error: Option<anyhow::Error>,
    done: bool,
}
impl<P: Platform> Transaction<P> {
    pub fn new(platform: P, start: bool) -> Self {
        Self {
            platform,
            phase: Phase::Preflight,
            start,
            error: None,
            recovery_error: None,
            done: false,
        }
    }
    pub fn phase(&self) -> Phase {
        self.phase
    }
    pub fn error(&self) -> Option<&anyhow::Error> {
        self.error.as_ref()
    }
    pub fn recovery_error(&self) -> Option<&anyhow::Error> {
        self.recovery_error.as_ref()
    }
    pub(super) fn platform(&self) -> &P { &self.platform }
    fn failed(&mut self, error: anyhow::Error) {
        self.error = Some(error);
        self.phase = Phase::Recovery;
        // On any failure, including journal/StartService/finish failure, close
        // automatic boot execution first. Cleanup ACK is reported separately.
        self.recovery_error = self.platform.disable_and_confirm_stopped().err();
    }
    pub fn advance(&mut self) -> Result<bool> {
        if self.phase == Phase::Recovery {
            anyhow::bail!("installation_recovery_required");
        }
        if self.done {
            return Ok(true);
        }
        if let Err(error) = self.platform.perform(self.phase) {
            self.failed(error);
            return Ok(false);
        }
        if self.phase == Phase::Complete {
            self.done = true;
            return Ok(true);
        }
        let next = match self.phase {
            Phase::Preflight => Phase::Roots,
            Phase::Roots => Phase::Journal,
            Phase::Journal => Phase::Payload,
            Phase::Payload => Phase::DisabledService,
            Phase::DisabledService => Phase::Profile,
            Phase::Profile => Phase::Verify,
            Phase::Verify => Phase::Consent,
            Phase::Consent => Phase::AutoStart,
            Phase::AutoStart if self.start => Phase::Started,
            Phase::AutoStart | Phase::Started => Phase::Complete,
            Phase::Complete | Phase::Recovery => unreachable!(),
        };
        // Persist the completed phase only after its OS action. Crash recovery
        // must also inspect actual OS ownership; journal alone is not authority.
        if self.phase != Phase::Preflight && self.phase != Phase::Roots {
            if let Err(error) = self.platform.persist_phase(self.phase) {
                self.failed(error);
                return Ok(false);
            }
        }
        self.phase = next;
        Ok(false)
    }
    pub(super) fn retry_confirm_stopped(&mut self) -> Result<()> {
        if self.phase != Phase::Recovery {
            anyhow::bail!("installation_not_in_recovery");
        }
        match self.platform.disable_and_confirm_stopped() {
            Ok(()) => {
                self.recovery_error = None;
                Ok(())
            }
            Err(error) => {
                self.recovery_error = Some(error);
                anyhow::bail!("installation_stop_unconfirmed")
            }
        }
    }
    pub fn rollback(&mut self) -> Result<()> {
        self.phase = Phase::Recovery;
        // Disabled/StopPending/request-return is not an exit acknowledgment.
        self.platform.disable_and_confirm_stopped()?;
        self.platform.remove_only_owned_artifacts()?;
        self.error = None;
        self.recovery_error = None;
        self.done = false;
        Ok(())
    }
    pub fn into_platform(self) -> P {
        self.platform
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    struct Trace {
        actions: Vec<Phase>,
        fail: Option<Phase>,
        persist_fail: Option<Phase>,
        stopped: bool,
        removed: bool,
        stop_fail: bool,
    }
    impl Platform for Trace {
        fn perform(&mut self, p: Phase) -> Result<()> {
            self.actions.push(p);
            if self.fail == Some(p) {
                anyhow::bail!("injected_failure");
            }
            Ok(())
        }
        fn persist_phase(&mut self, p: Phase) -> Result<()> {
            if self.persist_fail == Some(p) {
                anyhow::bail!("injected_journal_failure");
            }
            Ok(())
        }
        fn disable_and_confirm_stopped(&mut self) -> Result<()> {
            if self.stop_fail {
                anyhow::bail!("stop_unconfirmed");
            }
            self.stopped = true;
            Ok(())
        }
        fn remove_only_owned_artifacts(&mut self) -> Result<()> {
            assert!(self.stopped);
            self.removed = true;
            Ok(())
        }
    }
    fn trace(fail: Option<Phase>) -> Trace {
        Trace {
            actions: vec![],
            fail,
            persist_fail: None,
            stopped: false,
            removed: false,
            stop_fail: false,
        }
    }
    #[test]
    fn actual_transaction_order_never_enables_before_profile_and_pin_readback() {
        let mut t = Transaction::new(trace(None), true);
        while !t.advance().unwrap() {}
        assert_eq!(
            t.into_platform().actions,
            vec![
                Phase::Preflight,
                Phase::Roots,
                Phase::Journal,
                Phase::Payload,
                Phase::DisabledService,
                Phase::Profile,
                Phase::Verify,
                Phase::Consent,
                Phase::AutoStart,
                Phase::Started,
                Phase::Complete
            ]
        );
    }
    #[test]
    fn every_failure_before_autostart_prevents_start_and_keeps_recovery_reachable() {
        for failure in [
            Phase::Preflight,
            Phase::Roots,
            Phase::Journal,
            Phase::Payload,
            Phase::DisabledService,
            Phase::Profile,
            Phase::Verify,
            Phase::Consent,
            Phase::AutoStart,
        ] {
            let mut t = Transaction::new(trace(Some(failure)), true);
            while t.phase() != Phase::Recovery {
                t.advance().unwrap();
            }
            assert!(t.error().is_some());
            assert!(t.advance().is_err());
            let p = t.into_platform();
            assert!(!p.actions.contains(&Phase::Started));
            assert!(!p.removed);
            assert!(p.stopped);
        }
    }
    #[test]
    fn rollback_requires_real_stop_confirmation_and_can_retry() {
        let mut p = trace(None);
        p.stop_fail = true;
        let mut t = Transaction::new(p, true);
        assert!(t.rollback().is_err());
        assert_eq!(t.phase(), Phase::Recovery);
        assert!(!t.platform.removed);
        t.platform.stop_fail = false;
        t.rollback().unwrap();
        assert!(t.platform.removed);
    }
    #[test]
    fn explicit_no_immediate_start_skips_startservice_but_commits_autostart() {
        let mut t = Transaction::new(trace(None), false);
        while !t.advance().unwrap() {}
        assert!(!t.into_platform().actions.contains(&Phase::Started));
    }
    #[test]
    fn start_and_finish_failure_disable_execution_and_keep_failed_stop_as_recovery() {
        for phase in [Phase::Started, Phase::Complete] {
            let mut p = trace(Some(phase));
            p.stop_fail = true;
            let mut t = Transaction::new(p, true);
            while t.phase() != Phase::Recovery {
                t.advance().unwrap();
            }
            assert!(t.recovery_error().is_some());
            assert!(!t.platform.removed);
        }
    }
    #[test]
    fn journal_write_failure_after_enable_or_start_still_disables_execution() {
        for phase in [
            Phase::Journal,
            Phase::Profile,
            Phase::Consent,
            Phase::AutoStart,
            Phase::Started,
        ] {
            let mut p = trace(None);
            p.persist_fail = Some(phase);
            let mut t = Transaction::new(p, true);
            while t.phase() != Phase::Recovery {
                t.advance().unwrap();
            }
            assert!(t.platform.stopped);
            assert!(!t.platform.removed);
            assert!(t.error().is_some());
        }
    }
    #[test]
    fn retry_stop_keeps_recovery_owner_until_actual_confirmation() {
        let platform = Trace {
            actions: vec![],
            fail: Some(Phase::Preflight),
            persist_fail: None,
            stopped: false,
            removed: false,
            stop_fail: true,
        };
        let mut transaction = Transaction::new(platform, false);
        assert!(transaction.retry_confirm_stopped().is_err());
        assert!(!transaction.advance().unwrap());
        assert_eq!(transaction.phase(), Phase::Recovery);
        assert!(transaction.recovery_error().is_some());
        assert!(transaction.retry_confirm_stopped().is_err());
        assert!(!transaction.platform.stopped && !transaction.platform.removed);
        transaction.platform.stop_fail = false;
        transaction.retry_confirm_stopped().unwrap();
        assert!(transaction.recovery_error().is_none());
        assert!(transaction.platform.stopped && !transaction.platform.removed);
        assert_eq!(transaction.phase(), Phase::Recovery);
    }
}
