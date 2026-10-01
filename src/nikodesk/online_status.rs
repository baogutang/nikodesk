//! Read-only observations from real private rendezvous replies, shared by UI engines.
use super::{server_scope, server_settings};
use hbb_common::serde_derive::Deserialize;
use std::{
    collections::BTreeMap,
    sync::{Mutex, OnceLock},
    time::{Duration, Instant},
};

#[derive(Clone, Copy)]
struct Observation {
    online: bool,
    sequence: u64,
    received: Instant,
}
#[derive(Default)]
struct Book {
    sequence: u64,
    peers: BTreeMap<(String, String), Observation>,
}
static BOOK: OnceLock<Mutex<Book>> = OnceLock::new();
fn book() -> &'static Mutex<Book> {
    BOOK.get_or_init(Mutex::default)
}
fn peer(value: &str) -> bool {
    (6..=16).contains(&value.len()) && value.bytes().all(|b| b.is_ascii_digit())
}
fn scope(value: &str) -> bool {
    super::background::install::policy::hex(value) && value.bytes().any(|b| b != b'0')
}

impl Book {
    fn observe(
        &mut self,
        namespace: &str,
        onlines: &[String],
        offlines: &[String],
        received: Instant,
    ) -> Option<()> {
        if !scope(namespace) || onlines.len() + offlines.len() > 4096 {
            return None;
        }
        let mut states = BTreeMap::new();
        for (ids, online) in [(onlines, true), (offlines, false)] {
            for id in ids {
                if !peer(id) || states.insert(id.clone(), online).is_some() {
                    return None;
                }
            }
        }
        self.sequence = self.sequence.checked_add(1)?;
        self.peers.retain(|(scope, _), entry| {
            scope == namespace
                && received.saturating_duration_since(entry.received) < Duration::from_secs(15)
        });
        for (id, online) in states {
            self.peers.insert(
                (namespace.into(), id),
                Observation {
                    online,
                    sequence: self.sequence,
                    received,
                },
            );
        }
        while self.peers.len() > 4096 {
            let oldest = self
                .peers
                .iter()
                .min_by_key(|(_, entry)| entry.sequence)
                .map(|(key, _)| key.clone())?;
            self.peers.remove(&oldest);
        }
        Some(())
    }
    fn status(&self, namespace: &str, id: &str, now: Instant) -> (&'static str, u64) {
        match self.peers.get(&(namespace.into(), id.into())) {
            Some(entry)
                if now.saturating_duration_since(entry.received) < Duration::from_secs(15) =>
            {
                (
                    if entry.online { "online" } else { "offline" },
                    entry.sequence,
                )
            }
            Some(entry) => ("unknown", entry.sequence),
            None => ("unknown", 0),
        }
    }
}
// Called only by the existing native reply callback after its originating
// private-server namespace has been checked against the current configuration.
pub(crate) fn observe(namespace: &str, onlines: &[String], offlines: &[String]) {
    if let Ok(mut book) = book().lock() {
        let _ = book.observe(namespace, onlines, offlines, Instant::now());
    }
}
pub(crate) fn status(selector: &str) -> String {
    #[derive(Deserialize)]
    #[serde(deny_unknown_fields)]
    struct Selector {
        namespace: String,
        peer_id: String,
    }
    if selector.len() > 256 {
        return String::new();
    }
    let Ok(selector) = serde_json::from_str::<Selector>(selector) else {
        return String::new();
    };
    if !scope(&selector.namespace) || !peer(&selector.peer_id) {
        return String::new();
    }
    server_settings::with_verified_options(|options| {
        if server_scope::namespace_from_options(options).as_deref() != Some(&selector.namespace)
            || options.get("stop-service").map(String::as_str) == Some("Y")
        {
            hbb_common::bail!("online_private_server_changed");
        }
        let book = book()
            .lock()
            .map_err(|_| hbb_common::anyhow::anyhow!("online_state_unconfirmed"))?;
        let (state, sequence) = book.status(&selector.namespace, &selector.peer_id, Instant::now());
        Ok(serde_json::json!({"schema":1,"namespace":selector.namespace,"peer_id":selector.peer_id,
            "state":state,"observation":sequence.to_string()}).to_string())
    })
    .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn real_reply_observations_expire_and_do_not_cross_private_servers() {
        let mut book = Book::default();
        let now = Instant::now();
        let id = "123456789".to_owned();
        let first = "a".repeat(64);
        let second = "b".repeat(64);
        book.observe(&first, &[id.clone()], &[], now).unwrap();
        assert_eq!(book.status(&first, &id, now), ("online", 1));
        assert_eq!(
            book.status(&first, &id, now + Duration::from_secs(15)),
            ("unknown", 1)
        );
        book.observe(&second, &[], &[id.clone()], now).unwrap();
        assert_eq!(book.status(&first, &id, now), ("unknown", 0));
        assert_eq!(book.status(&second, &id, now), ("offline", 2));
    }
    #[test]
    fn conflicting_or_unattributed_results_cannot_replace_a_confirmed_observation() {
        let mut book = Book::default();
        let now = Instant::now();
        let id = "123456789".to_owned();
        let scope = "a".repeat(64);
        book.observe(&scope, &[id.clone()], &[], now).unwrap();
        assert!(book
            .observe(&scope, &[id.clone()], &[id.clone()], now)
            .is_none());
        assert!(book.observe("public", &[], &[id.clone()], now).is_none());
        assert_eq!(book.status(&scope, &id, now), ("online", 1));
    }
}
