//! Virtual screens belong to one authenticated connection, never a global driver.
use std::{collections::BTreeMap, sync::{Arc, Mutex, OnceLock, atomic::{AtomicBool, AtomicU64, Ordering}}, time::{Duration, Instant}};
#[cfg(target_os = "macos")]
#[path = "virtual_display/macos.rs"]
mod platform;
#[cfg(target_os = "windows")]
#[path = "virtual_display/windows.rs"]
mod platform;

#[cfg(any(windows, test))]
#[path = "virtual_display/protocol.rs"]
mod protocol;

#[cfg(windows)]
static DRIVER_MAINTENANCE: AtomicBool = AtomicBool::new(false);

static NEXT_LEASE: AtomicU64 = AtomicU64::new(1);
#[derive(Clone)]
pub(crate) struct Owner { connection: i32, namespace: String, nonce: String, lease: u64, revoked: Arc<AtomicBool> }
impl PartialEq for Owner {
    fn eq(&self, other: &Self) -> bool { self.lease == other.lease && self.connection == other.connection
        && self.namespace == other.namespace && self.nonce == other.nonce }
}
impl Eq for Owner {}
impl Owner {
    pub(crate) fn new(connection: i32, namespace: String, nonce: String) -> Option<Self> {
        if connection <= 0 || !super::voice_flow::hex(&namespace, 64, false)
            || !super::voice_flow::hex(&nonce, 32, true) { return None; }
        let lease = NEXT_LEASE.fetch_update(Ordering::AcqRel, Ordering::Acquire, |value| value.checked_add(1)).ok()?;
        Some(Self { connection, namespace, nonce, lease, revoked: Arc::new(AtomicBool::new(false)) })
    }
    fn live(&self) -> bool { !self.revoked.load(Ordering::Acquire) }
}
struct Entry { owner: Owner, screen: platform::Screen, cleanup: bool }
static SCREENS: OnceLock<Mutex<BTreeMap<u32, Entry>>> = OnceLock::new();
static CLEANUP_RUNNING: AtomicBool = AtomicBool::new(false);
fn screens() -> &'static Mutex<BTreeMap<u32, Entry>> { SCREENS.get_or_init(Mutex::default) }
fn ensure_cleanup() -> Result<(), &'static str> {
    if CLEANUP_RUNNING.compare_exchange(false,true,Ordering::AcqRel,Ordering::Acquire).is_err() {return Ok(());}
    if std::thread::Builder::new().name("niko-display-recovery".into()).spawn(|| {
        struct Running;
        impl Drop for Running {fn drop(&mut self) {CLEANUP_RUNNING.store(false,Ordering::Release);}}
        let _running=Running;
        loop {
            std::thread::sleep(Duration::from_millis(250));
            let Ok(mut book)=screens().lock() else {return;};
            let pending=book.iter().filter(|(_,entry)|entry.cleanup || !entry.owner.live())
                .map(|(slot,_)|*slot).collect::<Vec<_>>();
            for slot in pending {
                if book.get_mut(&slot).is_some_and(|entry| {entry.cleanup=true; entry.screen.remove().is_ok()}) {
                    book.remove(&slot);
                }
            }
            if book.is_empty() {
                // Clear the flag before releasing the book lock. A new owner
                // inserted afterwards starts its own recovery worker.
                drop(_running);return;
            }
        }
    }).is_err() {
        CLEANUP_RUNNING.store(false,Ordering::Release);
        return Err("worker_failed");
    }
    Ok(())
}
fn wait_removed(screen: &mut platform::Screen) -> Result<(), &'static str> {
    let deadline = Instant::now() + Duration::from_secs(2);
    loop {
        if screen.remove().is_ok() { return Ok(()); }
        if Instant::now() >= deadline { return Err("cleanup_pending"); }
        std::thread::sleep(Duration::from_millis(25));
    }
}
fn remove_entry(book: &mut BTreeMap<u32, Entry>, slot: u32) -> Result<(), &'static str> {
    let Some(entry) = book.get_mut(&slot) else { return Ok(()); };
    entry.cleanup = true;
    wait_removed(&mut entry.screen)?;
    book.remove(&slot);
    Ok(())
}
pub(crate) fn toggle(owner: &Owner, slot: i32, on: bool) -> Result<(), &'static str> {
    if on && !(1..=4).contains(&slot) || !on && slot != -1 && !(1..=4).contains(&slot) {
        return Err("invalid_display_slot");
    }
    let mut book = screens().lock().map_err(|_| "worker_failed")?;
    #[cfg(windows)]
    if on && DRIVER_MAINTENANCE.load(Ordering::Acquire) { return Err("driver_maintenance_in_progress"); }
    if !on {
        let slots: Vec<_> = book.iter().filter(|(index, entry)| entry.owner == *owner
            && (slot == -1 || **index == slot as u32)).map(|(slot, _)| *slot).collect();
        if slot != -1 && book.get(&(slot as u32)).is_some_and(|entry| entry.owner != *owner) {
            return Err("display_owned_by_another_connection");
        }
        let mut result = Ok(());
        for slot in slots { if let Err(error) = remove_entry(&mut book, slot) { result = Err(error); } }
        return result;
    }
    if let Some(entry) = book.get(&(slot as u32)) {
        return if entry.owner != *owner { Err("display_owned_by_another_connection") }
            else if entry.cleanup || !entry.screen.online() { Err("cleanup_pending") } else { Ok(()) };
    }
    if !owner.live() || hbb_common::config::Config::get_option("nikodesk-allow-virtual-display") != "Y" {
        return Err("virtual_display_not_allowed");
    }
    if !platform::supported() { return Err("backend_unavailable"); }
    let screen = platform::Screen::create(slot as u32)?;
    book.insert(slot as u32, Entry { owner: owner.clone(), screen, cleanup: false });
    if ensure_cleanup().is_err() {
        let _=remove_entry(&mut book,slot as u32);
        return Err("worker_failed");
    }
    let deadline = Instant::now() + Duration::from_secs(2);
    while !book[&(slot as u32)].screen.online() && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(25));
    }
    if !owner.live() || hbb_common::config::Config::get_option("nikodesk-allow-virtual-display") != "Y"
        || !book[&(slot as u32)].screen.online() {
        let _ = remove_entry(&mut book, slot as u32);
        return Err("display_creation_unconfirmed");
    }
    Ok(())
}
pub(crate) fn release(owner: Owner) {
    owner.revoked.store(true, Ordering::Release);
    // The existing resource owner retries asynchronously even with no open UI.
    // A close never waits on WindowServer/a driver in the session dispatcher.
    let _ = ensure_cleanup();
}
pub(crate) fn additions() -> serde_json::Map<String, serde_json::Value> {
    let mut result = serde_json::Map::new();
    let mut active = Vec::new();
    let mut cleanup = Vec::new();
    if let Ok(mut book) = screens().lock() {
        if !book.is_empty() {let _=ensure_cleanup();}
        book.retain(|_, entry| {
            entry.cleanup |= !entry.owner.live();
            !entry.cleanup || entry.screen.remove().is_err()
        });
        for (slot, entry) in book.iter() {
            if entry.cleanup { cleanup.push(*slot); }
            else if entry.screen.online() { active.push(*slot); }
        }
    }
    result.insert("nikodesk_virtual_display".into(), serde_json::json!({
        "schema": 1, "supported": platform::supported(), "active": active, "cleanup": cleanup,
        "allowed": hbb_common::config::Config::get_option("nikodesk-allow-virtual-display") == "Y"
    }));
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn delayed_old_cleanup_cannot_own_a_reauthorized_connections_new_screen() {
        let old = Owner::new(7, "a".repeat(64), "1".repeat(32)).unwrap();
        let captured = old.clone();
        old.revoked.store(true, Ordering::Release);
        assert!(!captured.live());
        let replacement = Owner::new(7, "a".repeat(64), "1".repeat(32)).unwrap();
        assert!(replacement.live());
        assert!(old != replacement);
    }
    #[test]
    fn screen_owner_cannot_be_created_without_an_authenticated_private_binding() {
        assert!(Owner::new(0, "a".repeat(64), "1".repeat(32)).is_none());
        assert!(Owner::new(1, "public".into(), "1".repeat(32)).is_none());
        assert!(Owner::new(1, "a".repeat(64), "0".repeat(32)).is_none());
    }
}

#[cfg(windows)]
pub(crate) fn has_screens() -> bool { screens().lock().map(|book| !book.is_empty()).unwrap_or(true) }
#[cfg(windows)]
pub(crate) fn probe_driver() -> Result<(), &'static str> { platform::Screen::probe() }

#[cfg(windows)]
pub(crate) struct DriverMaintenance;
#[cfg(windows)]
impl Drop for DriverMaintenance { fn drop(&mut self) { DRIVER_MAINTENANCE.store(false,Ordering::Release); } }
#[cfg(windows)]
pub(crate) fn begin_driver_maintenance() -> Result<DriverMaintenance, &'static str> {
    let book = screens().lock().map_err(|_| "active_displays")?;
    if !book.is_empty() || DRIVER_MAINTENANCE.compare_exchange(false,true,Ordering::AcqRel,Ordering::Acquire).is_err() {
        return Err("active_displays");
    }
    Ok(DriverMaintenance)
}
