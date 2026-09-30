use std::collections::HashMap;

struct State<K> {
    generation: u64,
    enabled: bool,
    held: Vec<K>,
}

/// A held remote key/button reserves OS input for its session. This also
/// excludes another session using a different encoding of the same key.
pub(super) struct Registry<K> {
    sessions: HashMap<u64, State<K>>,
    owner: Option<u64>,
}

impl<K> Default for Registry<K> {
    fn default() -> Self {
        Self {
            sessions: HashMap::new(),
            owner: None,
        }
    }
}

impl<K> Registry<K> {
    pub fn add(&mut self, id: u64, enabled: bool) {
        self.sessions.insert(
            id,
            State {
                generation: 0,
                enabled,
                held: vec![],
            },
        );
    }

    pub fn ticket(&self, id: u64) -> Option<u64> {
        self.sessions
            .get(&id)
            .filter(|state| state.enabled)
            .map(|state| state.generation)
    }

    pub fn close_all(&mut self) -> Vec<K> {
        self.owner = None;
        std::mem::take(&mut self.sessions)
            .into_values()
            .flat_map(|state| state.held)
            .collect()
    }

    /// The caller must retain its registry lock while releasing these inputs.
    pub fn permission(&mut self, id: u64, enabled: bool, close: bool) -> Vec<K> {
        let Some(state) = self.sessions.get_mut(&id) else {
            return vec![];
        };
        let mut release = vec![];
        if !enabled || close {
            state.generation = state.generation.wrapping_add(1);
            release = std::mem::take(&mut state.held);
            if self.owner == Some(id) {
                self.owner = None;
            }
        }
        state.enabled = enabled && !close;
        if close {
            self.sessions.remove(&id);
        }
        release
    }

    pub fn accept(
        &mut self,
        id: u64,
        generation: u64,
        held: Option<(K, bool)>,
        same_key: impl Fn(&K, &K) -> bool,
    ) -> bool {
        if self.ticket(id) != Some(generation) || self.owner.is_some_and(|owner| owner != id) {
            return false;
        }
        if let Some((key, down)) = held {
            let Some(state) = self.sessions.get_mut(&id) else {
                return false;
            };
            let index = state.held.iter().position(|old| same_key(old, &key));
            if down {
                if index.is_none() {
                    if state.held.len() >= 256 {
                        return false;
                    }
                    state.held.push(key);
                }
                self.owner = Some(id);
            } else if let Some(index) = index {
                state.held.remove(index);
                if state.held.is_empty() {
                    self.owner = None;
                }
            } else {
                return false;
            }
        }
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{mpsc, Arc, Mutex, TryLockError};

    fn send(
        states: &mut Registry<&'static str>,
        id: u64,
        ticket: u64,
        key: Option<(&'static str, bool)>,
    ) -> bool {
        states.accept(id, ticket, key, |a, b| a == b)
    }

    #[test]
    fn nikodesk_windows_worker_close_drains_owned_inputs_and_all_old_tickets() {
        let mut states = Registry::default();
        states.add(1, true);
        states.add(2, true);
        assert!(send(&mut states, 1, 0, Some(("shift", true))));
        assert!(send(&mut states, 1, 0, Some(("mouse-left", true))));
        assert_eq!(states.close_all(), vec!["shift", "mouse-left"]);
        for id in [1, 2] {
            assert_eq!(states.ticket(id), None);
            assert!(!send(&mut states, id, 0, None));
            states.permission(id, true, false);
            assert_eq!(states.ticket(id), None);
        }
        assert!(states.close_all().is_empty());
    }

    #[test]
    fn nikodesk_windows_input_starts_without_permission() {
        let mut states = Registry::<&str>::default();
        states.add(1, false);
        assert_eq!(states.ticket(1), None);
        assert!(!send(&mut states, 1, 0, None));
        states.permission(1, true, false);
        assert!(send(&mut states, 1, 0, None));
    }

    #[test]
    fn nikodesk_windows_revoke_discards_queued_keys_mouse_and_pointer() {
        let mut states = Registry::default();
        states.add(1, true);
        assert!(send(&mut states, 1, 0, Some(("A", true))));
        assert!(send(&mut states, 1, 0, Some(("mouse-left", true))));
        assert_eq!(states.permission(1, false, false), vec!["A", "mouse-left"]);
        assert!(!send(&mut states, 1, 0, Some(("queued-B", true))));
        assert!(!send(&mut states, 1, 0, Some(("queued-mouse", true))));
        assert!(!send(&mut states, 1, 0, None));
        assert!(states.permission(1, false, false).is_empty());
    }

    #[test]
    fn nikodesk_windows_regrant_rejects_old_generation() {
        let mut states = Registry::default();
        states.add(1, true);
        states.permission(1, false, false);
        states.permission(1, true, false);
        let ticket = states.ticket(1).unwrap();
        assert_ne!(ticket, 0);
        assert!(!send(&mut states, 1, 0, Some(("old", true))));
        assert!(send(&mut states, 1, ticket, Some(("new", true))));
        assert_eq!(states.permission(1, false, false), vec!["new"]);
    }

    #[test]
    fn nikodesk_windows_close_releases_only_its_session_and_cannot_reopen() {
        let mut states = Registry::default();
        states.add(1, true);
        states.add(2, true);
        assert!(send(&mut states, 1, 0, Some(("shift-map", true))));
        assert!(!send(&mut states, 2, 0, Some(("shift-legacy", false))));
        assert!(!send(&mut states, 2, 0, Some(("shift-legacy", true))));
        assert!(states.permission(2, false, true).is_empty());
        assert_eq!(states.permission(1, false, true), vec!["shift-map"]);
        assert!(states.permission(1, true, false).is_empty());
        assert_eq!(states.ticket(1), None);
        assert!(!send(&mut states, 1, 0, None));
    }

    #[test]
    fn nikodesk_windows_revoke_other_session_never_releases_owner() {
        let mut states = Registry::default();
        states.add(1, true);
        states.add(2, true);
        assert!(send(&mut states, 1, 0, Some(("control", true))));
        assert!(states.permission(2, false, false).is_empty());
        states.permission(2, true, false);
        let ticket = states.ticket(2).unwrap();
        assert!(!send(&mut states, 2, ticket, None));
        assert_eq!(states.permission(1, false, false), vec!["control"]);
        let ticket = states.ticket(2).unwrap();
        assert!(send(&mut states, 2, ticket, Some(("mouse-right", true))));
        assert!(states.permission(1, false, true).is_empty());
        assert_eq!(states.permission(2, false, true), vec!["mouse-right"]);
    }

    #[test]
    fn nikodesk_windows_repeat_unowned_release_and_ownership_handoff() {
        let mut states = Registry::default();
        states.add(1, true);
        states.add(2, true);
        assert!(!send(&mut states, 1, 0, Some(("unknown", false))));
        assert!(send(&mut states, 1, 0, Some(("A", true))));
        assert!(send(&mut states, 1, 0, Some(("A", true))));
        assert!(!send(&mut states, 2, 0, None));
        assert!(send(&mut states, 1, 0, Some(("A", false))));
        assert!(send(&mut states, 2, 0, Some(("B", true))));
        assert!(states.permission(1, false, true).is_empty());
        assert_eq!(states.permission(2, false, true), vec!["B"]);
    }

    #[test]
    fn nikodesk_windows_held_input_is_bounded() {
        let mut states = Registry::default();
        states.add(1, true);
        for key in 0..256 {
            assert!(states.accept(1, 0, Some((key, true)), |a, b| a == b));
        }
        assert!(!states.accept(1, 0, Some((256, true)), |a, b| a == b));
        assert_eq!(states.permission(1, false, true).len(), 256);
    }

    #[test]
    fn nikodesk_windows_execution_lock_orders_revoke_after_active_dispatch() {
        let states = Arc::new(Mutex::new(Registry::<&str>::default()));
        states.lock().unwrap().add(1, true);
        let (started_tx, started_rx) = mpsc::channel();
        let (finish_tx, finish_rx) = mpsc::channel();
        let worker_states = states.clone();
        let worker = std::thread::spawn(move || {
            let mut state = worker_states.lock().unwrap();
            assert!(send(&mut state, 1, 0, Some(("A", true))));
            started_tx.send(()).unwrap();
            finish_rx.recv().unwrap();
        });
        started_rx.recv().unwrap();
        assert!(matches!(states.try_lock(), Err(TryLockError::WouldBlock)));
        finish_tx.send(()).unwrap();
        worker.join().unwrap();
        let mut state = states.lock().unwrap();
        assert_eq!(state.permission(1, false, false), vec!["A"]);
        state.permission(1, true, false);
        assert!(!send(&mut state, 1, 0, Some(("queued", true))));
    }
}
