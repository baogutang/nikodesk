//! Packet ownership for the Niko-only polling loopback path, with no OS calls.

struct ReleaseGuard<R: FnOnce() -> Result<(), E>, F: FnMut(E), E> {
    release: Option<R>,
    report: F,
}

impl<R: FnOnce() -> Result<(), E>, F: FnMut(E), E> Drop for ReleaseGuard<R, F, E> {
    fn drop(&mut self) {
        if let Some(release) = self.release.take() {
            if let Err(err) = release() {
                (self.report)(err);
            }
        }
    }
}

pub(super) fn with_packet<T, E>(
    read: impl FnOnce() -> Result<T, E>,
    release: impl FnOnce() -> Result<(), E>,
    report_on_unwind: impl FnMut(E),
) -> (Result<T, E>, Result<(), E>) {
    let mut guard = ReleaseGuard {
        release: Some(release),
        report: report_on_unwind,
    };
    let read_result = read();
    let release_result = match guard.release.take() {
        Some(release) => release(),
        None => unreachable!("packet release is consumed only here or during unwind"),
    };
    (read_result, release_result)
}

pub(super) fn aligned_silence(bytes: usize, unsigned_bits: Option<u8>) -> Vec<u64> {
    let equilibrium = match unsigned_bits {
        Some(8) => 0x8080_8080_8080_8080,
        Some(16) => 0x8000_8000_8000_8000,
        Some(32) => 0x8000_0000_8000_0000,
        Some(64) => 0x8000_0000_0000_0000,
        _ => 0,
    };
    vec![equilibrium; bytes / 8 + usize::from(bytes % 8 != 0)]
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        cell::Cell,
        panic::{catch_unwind, AssertUnwindSafe},
    };

    #[test]
    fn successful_packet_releases_exactly_once() {
        let releases = Cell::new(0);
        let result = with_packet(
            || Ok::<_, ()>(42),
            || {
                releases.set(releases.get() + 1);
                Ok(())
            },
            |_| panic!("unexpected unwind failure"),
        );
        assert_eq!(result, (Ok(42), Ok(())));
        assert_eq!(releases.get(), 1);
    }

    #[test]
    fn timestamp_or_validation_failure_still_releases_exactly_once() {
        let releases = Cell::new(0);
        let result = with_packet(
            || Err::<(), _>("read"),
            || {
                releases.set(releases.get() + 1);
                Ok(())
            },
            |_| panic!("unexpected unwind failure"),
        );
        assert_eq!(result, (Err("read"), Ok(())));
        assert_eq!(releases.get(), 1);
    }

    #[test]
    fn release_failure_is_not_retried_or_lost_behind_read_failure() {
        let releases = Cell::new(0);
        let result = with_packet(
            || Err::<(), _>("read"),
            || {
                releases.set(releases.get() + 1);
                Err("release")
            },
            |_| panic!("unexpected unwind failure"),
        );
        assert_eq!(result, (Err("read"), Err("release")));
        assert_eq!(releases.get(), 1);
    }

    #[test]
    fn callback_panic_releases_packet_and_reports_release_failure() {
        let releases = Cell::new(0);
        let reports = Cell::new(0);
        let panic_result = catch_unwind(AssertUnwindSafe(|| {
            let _ = with_packet::<(), _>(
                || panic!("callback failed"),
                || {
                    releases.set(releases.get() + 1);
                    Err("release")
                },
                |err| {
                    assert_eq!(err, "release");
                    reports.set(reports.get() + 1);
                },
            );
        }));
        assert!(panic_result.is_err());
        assert_eq!(releases.get(), 1);
        assert_eq!(reports.get(), 1);
    }

    #[test]
    fn f32_signed_and_unsigned_silence_have_correct_equilibrium_and_alignment() {
        for bytes in [1, 3, 8, 9, 1920] {
            let f32_packet = aligned_silence(bytes, None);
            assert_eq!(f32_packet.as_ptr() as usize % 8, 0);
            assert!(f32_packet.iter().all(|word| *word == 0));
            let u8_packet = aligned_silence(bytes, Some(8));
            assert!(u8_packet
                .iter()
                .flat_map(|word| word.to_le_bytes())
                .all(|byte| byte == 0x80));
            assert!(u8_packet.len() * 8 >= bytes);
        }
        for bits in [16, 32, 64] {
            let packet = aligned_silence(8, Some(bits));
            for chunk in packet[0].to_le_bytes().chunks((bits / 8) as usize) {
                assert_eq!(*chunk.last().unwrap(), 0x80);
                assert!(chunk[..chunk.len() - 1].iter().all(|byte| *byte == 0));
            }
        }
    }
}
