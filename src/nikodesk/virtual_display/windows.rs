//! Connection-owned screens on the signed Amyuni driver that upstream bundles.
//! The driver is machine-wide and its monitors are interchangeable, so this
//! module never removes more monitors than it plugged in itself.
use crate::virtual_display_manager::amyuni_idd;
use std::{
    sync::atomic::{AtomicUsize, Ordering},
    time::{Duration, Instant},
};

static OWNED: AtomicUsize = AtomicUsize::new(0);

fn os_supported() -> bool {
    base::platform::windows::is_windows_version_or_greater(10, 0, 19041, 0, 0)
}
pub(super) fn supported() -> bool {
    os_supported()
        && if crate::nikodesk::background::is_system_worker() {
            crate::nikodesk::background::worker_active()
        } else {
            // Plugging a monitor needs Administrator access. Read the actual
            // token; this path never raises UAC or starts another process.
            crate::platform::windows::is_elevated(None).unwrap_or(false)
        }
}
pub(super) struct Screen {
    plugged: bool,
    // How many Amyuni monitors must exist for this screen to be one of them.
    rank: usize,
    // Once a plug-out was sent: the monitor count that confirms it took effect.
    removal_target: Option<usize>,
}
impl Screen {
    pub(super) fn create(slot: u32) -> Result<Self, &'static str> {
        if !os_supported() {
            return Err("backend_unavailable");
        }
        if !supported() {
            return Err("background_service_required");
        }
        if !(1..=4).contains(&slot) {
            return Err("invalid_display_slot");
        }
        // Installs the bundled driver on first use, exactly as upstream does.
        if let Err(error) = amyuni_idd::plug_in_monitor() {
            hbb_common::log::error!("Failed to plug in a virtual display: {error}");
            return Err("virtual_display_driver_unavailable");
        }
        let rank = OWNED.fetch_add(1, Ordering::AcqRel) + 1;
        Ok(Self {
            plugged: true,
            rank,
            removal_target: None,
        })
    }
    pub(super) fn probe() -> Result<(), &'static str> {
        let mut screen = Self::create(1)?;
        let deadline = Instant::now() + Duration::from_secs(5);
        while !screen.online() && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(50));
        }
        let seen = screen.online();
        let deadline = Instant::now() + Duration::from_secs(5);
        while screen.remove().is_err() {
            if Instant::now() >= deadline {
                return Err("cleanup_pending");
            }
            std::thread::sleep(Duration::from_millis(50));
        }
        if seen {
            Ok(())
        } else {
            Err("display_creation_unconfirmed")
        }
    }
    pub(super) fn online(&self) -> bool {
        // Removing an earlier screen lowers what the remaining ones can require.
        self.plugged
            && self.removal_target.is_none()
            && amyuni_idd::get_monitor_count() >= self.rank.min(OWNED.load(Ordering::Acquire))
    }
    pub(super) fn remove(&mut self) -> Result<(), &'static str> {
        if !self.plugged {
            return Ok(());
        }
        let target = match self.removal_target {
            Some(target) => target,
            None => {
                let count = amyuni_idd::get_monitor_count();
                // force_all also removes the only display of a headless machine;
                // index 0 still limits the request to a single monitor.
                if count > 0 && amyuni_idd::plug_out_monitor(0, true, false).is_err() {
                    return Err("cleanup_pending");
                }
                let target = count.saturating_sub(1);
                self.removal_target = Some(target);
                target
            }
        };
        if amyuni_idd::get_monitor_count() > target {
            return Err("cleanup_pending");
        }
        self.plugged = false;
        let _ = OWNED.fetch_update(Ordering::AcqRel, Ordering::Acquire, |value| {
            value.checked_sub(1)
        });
        Ok(())
    }
}
impl Drop for Screen {
    fn drop(&mut self) {
        let _ = self.remove();
    }
}
