use std::collections::HashMap;

#[derive(Default)]
pub(super) struct ControlSessions {
    connections: HashMap<i32, bool>,
    revision: u64,
}

impl ControlSessions {
    pub(super) fn register(&mut self, id: i32, controls: bool) {
        self.connections.insert(id, controls);
        self.revision = self.revision.wrapping_add(1);
    }

    pub(super) fn permission(&mut self, id: i32, controls: bool) {
        if let Some(old) = self.connections.get_mut(&id) {
            if *old != controls {
                *old = controls;
                self.revision = self.revision.wrapping_add(1);
            }
        }
    }

    pub(super) fn remove(&mut self, id: i32, requested: bool) -> Option<u64> {
        let controlled = self.connections.remove(&id)?;
        if !controlled {
            return None;
        }
        self.revision = self.revision.wrapping_add(1);
        (requested && !self.connections.values().any(|controls| *controls)).then_some(self.revision)
    }

    pub(super) fn pending(&self, ticket: u64) -> bool {
        self.revision == ticket && !self.connections.values().any(|controls| *controls)
    }

    pub(super) fn cancel_pending(&mut self) {
        self.revision = self.revision.wrapping_add(1);
    }
}

pub(super) fn idle_unchanged(before: f64, after: f64, elapsed: f64) -> bool {
    before.is_finite()
        && after.is_finite()
        && elapsed.is_finite()
        && before >= 0.0
        && elapsed >= 0.0
        && after + 0.001 >= before + elapsed
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_last_control_session_can_schedule_and_read_only_does_not_block_it() {
        let mut sessions = ControlSessions::default();
        sessions.register(1, true);
        sessions.register(2, true);
        sessions.register(3, false);
        assert_eq!(sessions.remove(1, true), None);
        let ticket = sessions.remove(2, true).unwrap();
        assert!(sessions.pending(ticket));
        assert_eq!(sessions.remove(3, true), None);
        assert!(sessions.pending(ticket));
        assert_eq!(sessions.remove(2, true), None);
    }

    #[test]
    fn reconnect_or_new_control_permission_cancels_the_old_ticket() {
        let mut sessions = ControlSessions::default();
        sessions.register(1, true);
        let old = sessions.remove(1, true).unwrap();
        sessions.register(2, false);
        assert!(!sessions.pending(old));
        sessions.permission(2, true);
        let new = sessions.remove(2, true).unwrap();
        assert!(sessions.pending(new));
        sessions.register(3, true);
        assert!(!sessions.pending(new));
    }

    #[test]
    fn disabled_controls_and_unrequested_disconnect_never_schedule() {
        let mut sessions = ControlSessions::default();
        sessions.register(1, true);
        sessions.permission(1, false);
        assert_eq!(sessions.remove(1, true), None);
        sessions.permission(99, true); // File and tunnel sessions are never registered.
        sessions.register(2, true);
        assert_eq!(sessions.remove(2, false), None);
    }

    #[test]
    fn local_activity_or_unknown_idle_measurement_cancels() {
        assert!(idle_unchanged(2.0, 7.0, 5.0));
        assert!(!idle_unchanged(2.0, 4.9, 5.0));
        assert!(!idle_unchanged(2.0, f64::NAN, 5.0));
        assert!(!idle_unchanged(-1.0, 5.0, 5.0));
    }
}
