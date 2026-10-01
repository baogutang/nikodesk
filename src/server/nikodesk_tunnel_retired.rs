use crate::nikodesk::{connection_capabilities::Identity, tunnel_actor::RetiredObserver, tunnel_transport::{self, RetiredReport}};
use hbb_common::tokio::{self, runtime::Handle, task::JoinHandle};
use std::{collections::BTreeMap, sync::{Mutex, OnceLock}, time::Duration};

#[derive(Default)]
struct Registry {
    observers: Vec<RetiredObserver>,
    pending: BTreeMap<u64, bool>,
    task: Option<JoinHandle<()>>,
}
fn registry() -> &'static Mutex<Registry> {
    static REGISTRY: OnceLock<Mutex<Registry>> = OnceLock::new();
    REGISTRY.get_or_init(|| Mutex::new(Registry::default()))
}
pub(super) fn register(observer: RetiredObserver, runner: Handle) -> Result<(), &'static str> {
    let mut registry = registry().lock().map_err(|_| "tunnel_cleanup_registry_unavailable")?;
    if registry.observers.len() >= 64 { return Err("tunnel_cleanup_registry_full"); }
    if registry.observers.iter().any(|old| old.identity() == observer.identity()) {
        return Err("tunnel_cleanup_duplicate_owner");
    }
    registry.observers.push(observer);
    if registry.task.as_ref().map_or(true, JoinHandle::is_finished) {
        registry.task = Some(runner.spawn(coordinate()));
    }
    Ok(())
}
pub(super) fn unregister(identity: &Identity) {
    if let Ok(mut registry) = registry().lock() {
        let lease = registry.observers.iter().find(|observer| observer.identity() == identity).and_then(RetiredObserver::owner_lease);
        registry.observers.retain(|observer| observer.identity() != identity);
        if let Some(lease) = lease { registry.pending.remove(&lease); }
    }
}
async fn coordinate() {
    let mut timer = tokio::time::interval(Duration::from_millis(50));
    loop {
        timer.tick().await;
        // One reader retains each joined lease until its original Flow has
        // consumed it. A busy owner cannot lose another owner's completion.
        let actual = tunnel_transport::poll_retired().await;
        let work = match registry().lock() {
            Ok(mut registry) => {
                for lease in actual.pending_leases { registry.pending.entry(lease).or_insert(false); }
                for lease in actual.stopped_leases { registry.pending.insert(lease, true); }
                registry.observers.iter().filter_map(|observer| {
                    let lease = observer.owner_lease()?;
                    let stopped = *registry.pending.get(&lease)?;
                    Some((observer.clone(), lease, stopped))
                }).collect::<Vec<_>>()
            },
            Err(_) => return,
        };
        for (observer, lease, stopped) in work {
            let report = RetiredReport { pending_leases: if stopped { vec![] } else { vec![lease] },
                stopped_leases: if stopped { vec![lease] } else { vec![] } };
            if observer.observe(&report).is_ok() {
                if let Ok(mut registry) = registry().lock() { registry.pending.remove(&lease); }
            }
        }
    }
}
