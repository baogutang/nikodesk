//! Durable counters owned by this NikoDesk identity. Each enrolled factor has
//! its own file, so rotating a damaged factor does not discard another's state.
use super::favorites::storage::{Directory, Lock};
use hbb_common::{
    anyhow::{anyhow, Context as _},
    bail,
    sodiumoxide::utils::memcmp,
    ResultType,
};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    collections::BTreeMap,
    path::PathBuf,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};
use totp_rs::{Algorithm, TOTP};

#[derive(Default)]
struct Counters(BTreeMap<[u8; 32], u64>);
pub(crate) fn factor(totp: &TOTP) -> [u8; 32] {
    let mut digest = Sha256::new();
    digest.update(b"NikoDesk TOTP factor v1\0");
    digest.update(&totp.secret);
    digest.update((totp.digits as u64).to_le_bytes());
    digest.finalize().into()
}
impl Counters {
    fn consume(&mut self, totp: &TOTP, code: &str, now: u64) -> bool {
        if totp.algorithm != Algorithm::SHA1
            || totp.step != 30
            || totp.skew > 1
            || ![6, 8].contains(&totp.digits)
            || code.len() != totp.digits
            || !code.bytes().all(|value| value.is_ascii_digit())
        {
            return false;
        }
        let key = factor(totp);
        if !self.0.contains_key(&key) && self.0.len() >= 256 {
            return false;
        }
        let supplied: [u8; 32] = Sha256::digest(code.as_bytes()).into();
        let current = now / totp.step;
        let mut matched = None;
        for step in
            current.saturating_sub(totp.skew as u64)..=current.saturating_add(totp.skew as u64)
        {
            let Some(time) = step.checked_mul(totp.step) else {
                continue;
            };
            let generated: [u8; 32] = Sha256::digest(totp.generate(time).as_bytes()).into();
            if memcmp(&supplied, &generated) {
                matched = Some(step);
            }
        }
        let Some(step) = matched else {
            return false;
        };
        if self.0.get(&key).is_some_and(|previous| step <= *previous) {
            return false;
        }
        self.0.insert(key, step);
        true
    }
}
fn now() -> ResultType<u64> {
    Ok(SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| anyhow!("Two-factor clock is unavailable"))?
        .as_secs())
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Stored {
    version: u8,
    factor: String,
    counter: u64,
}
struct Repository {
    root: PathBuf,
}
impl Repository {
    fn lock(directory: &Directory) -> ResultType<Lock> {
        let started = Instant::now();
        loop {
            match directory.lock("nikodesk-2fa-used.lock") {
                Ok(lock) => return Ok(lock),
                // A cold lock-file lookup may race another process's creation.
                // Retry only before any counter read/write; never a commit.
                Err(error)
                    if error
                        .downcast_ref::<std::io::Error>()
                        .is_some_and(|error| error.kind() == std::io::ErrorKind::NotFound)
                        && started.elapsed() < Duration::from_millis(250) =>
                {
                    std::thread::sleep(Duration::from_millis(5));
                }
                Err(error) => return Err(error.context("two_factor_lock_unavailable")),
            }
        }
    }
    fn name(totp: &TOTP) -> (String, String) {
        let fingerprint = factor(totp)
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect::<String>();
        (format!("nikodesk-2fa-used-{fingerprint}.json"), fingerprint)
    }
    fn read(directory: &Directory, totp: &TOTP) -> ResultType<Option<Stored>> {
        let (name, fingerprint) = Self::name(totp);
        let Some(bytes) = directory.read(&name, 2048)? else {
            return Ok(None);
        };
        let value: Stored =
            serde_json::from_slice(&bytes).map_err(|_| anyhow!("Two-factor counter is invalid"))?;
        if value.version != 1 || value.factor != fingerprint || value.counter > u64::MAX / 30 {
            bail!("Two-factor counter is invalid");
        }
        Ok(Some(value))
    }
    fn status(&self, totp: &TOTP) -> ResultType<()> {
        let directory = Directory::open(&self.root).context("two_factor_directory_unavailable")?;
        // Atomic files let the synchronous settings view read without waiting
        // behind authentication's durable write.
        Self::read(&directory, totp)?;
        Ok(())
    }
    fn consume(
        &self,
        totp: &TOTP,
        code: &str,
        clock: impl FnOnce() -> ResultType<u64>,
    ) -> ResultType<bool> {
        if totp.algorithm != Algorithm::SHA1
            || totp.step != 30
            || totp.skew > 1
            || ![6, 8].contains(&totp.digits)
            || code.len() != totp.digits
            || !code.bytes().all(|value| value.is_ascii_digit())
        {
            return Ok(false);
        }
        let directory = Directory::open(&self.root).context("two_factor_directory_unavailable")?;
        // Coordinate independent processes as well as concurrent connections.
        let _lock = Self::lock(&directory)?;
        let mut book = Counters::default();
        let key = factor(totp);
        if let Some(stored) =
            Self::read(&directory, totp).context("two_factor_counter_unavailable")?
        {
            book.0.insert(key, stored.counter);
        }
        // Time is read after queueing and the disk lock, never at request arrival.
        if !book.consume(totp, code, clock()?) {
            return Ok(false);
        }
        let (name, fingerprint) = Self::name(totp);
        let counter = *book
            .0
            .get(&key)
            .ok_or_else(|| anyhow!("Two-factor counter is unavailable"))?;
        let bytes = serde_json::to_vec(&Stored {
            version: 1,
            factor: fingerprint,
            counter,
        })?;
        // The existing private store flushes, atomically replaces and reads back.
        // A failed/unconfirmed write cannot grant authentication.
        directory
            .replace(&name, &bytes)
            .context("two_factor_counter_commit_unconfirmed")?;
        Ok(true)
    }
}

pub(crate) fn consume(totp: &TOTP, code: &str) -> ResultType<bool> {
    Repository {
        root: super::favorites::application_root()?,
    }
    .consume(totp, code, now)
}
pub(crate) fn status(totp: &TOTP) -> ResultType<()> {
    Repository {
        root: super::favorites::application_root()?,
    }
    .status(totp)
}

/// The network loop never waits on a filesystem lock while holding its runner.
pub(crate) async fn check_login(totp: &TOTP, code: &str) -> ResultType<bool> {
    if code.len() != totp.digits || !code.bytes().all(|byte| byte.is_ascii_digit()) {
        return Ok(false);
    }
    let mut totp = totp.clone();
    let code = code.to_owned();
    hbb_common::tokio::task::spawn_blocking(move || {
        let result = crate::auth_2fa::check_login_code(&totp, &code);
        hbb_common::sodiumoxide::utils::memzero(&mut totp.secret);
        let mut bytes = code.into_bytes();
        hbb_common::sodiumoxide::utils::memzero(&mut bytes);
        result
    })
    .await
    .map_err(|_| anyhow!("Two-factor verification is unavailable"))?
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::nikodesk::favorites::tests::Temp;
    use std::process::{Child, Command, Stdio};
    const TEST_TIME: u64 = 1_800_000_000;
    const TEST_SECRET: &[u8] = b"synthetic-only-durable-totp-fixture";
    fn totp(secret: &[u8]) -> TOTP {
        TOTP::new(
            Algorithm::SHA1,
            6,
            1,
            30,
            secret.to_vec(),
            Some("NikoDesk synthetic test".into()),
            "fixture".into(),
        )
        .unwrap()
    }
    #[test]
    fn code_is_single_use_across_connections_and_a_clock_rollback_cannot_reuse_it() {
        let totp = totp(b"synthetic-only-totp-replay-fixture");
        let mut book = Counters::default();
        let now = 1_800_000_000;
        let code = totp.generate(now);
        assert!(book.consume(&totp, &code, now));
        assert!(!book.consume(&totp, &code, now));
        assert!(book.consume(&totp, &totp.generate(now + 30), now + 30));
        assert!(!book.consume(&totp, &code, now));
        assert!(book.consume(&totp, &totp.generate(now + 60), now + 60));
    }
    #[test]
    fn invalid_code_cannot_advance_a_counter_and_rotated_factors_have_separate_counters() {
        let a = totp(b"synthetic-only-original-totp-fixture");
        let b = totp(b"synthetic-only-replacement-totp-fixture");
        let mut book = Counters::default();
        let now = 1_800_000_000;
        assert!(!book.consume(&a, "invalid", now));
        assert!(book.0.is_empty());
        assert!(book.consume(&a, &a.generate(now), now));
        assert!(book.consume(&b, &b.generate(now), now));
        assert!(!book.consume(&a, &a.generate(now), now));
    }

    fn child(root: &std::path::Path, result: &str, time: u64) -> Child {
        Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "nikodesk::totp_replay::tests::child_fixture",
                "--test-threads=1",
                "--nocapture",
            ])
            .env("NIKO_TOTP_REPLAY_FIXTURE_ROOT", root)
            .env("NIKO_TOTP_REPLAY_FIXTURE_RESULT", result)
            .env("NIKO_TOTP_REPLAY_FIXTURE_TIME", time.to_string())
            .stdout(Stdio::null())
            .stderr(Stdio::inherit())
            .spawn()
            .unwrap()
    }
    #[test]
    fn child_fixture() {
        let Some(root) = std::env::var_os("NIKO_TOTP_REPLAY_FIXTURE_ROOT") else {
            return;
        };
        let result = std::env::var("NIKO_TOTP_REPLAY_FIXTURE_RESULT").unwrap();
        assert!(["one", "two"].contains(&result.as_str()));
        let time = std::env::var("NIKO_TOTP_REPLAY_FIXTURE_TIME")
            .unwrap()
            .parse::<u64>()
            .unwrap();
        let totp = totp(TEST_SECRET);
        let root = PathBuf::from(root);
        let accepted = Repository { root: root.clone() }
            .consume(&totp, &totp.generate(time), || Ok(time))
            .unwrap();
        std::fs::write(
            root.join(format!("result-{result}")),
            if accepted { "1" } else { "0" },
        )
        .unwrap();
    }
    #[test]
    fn an_independent_process_cannot_replay_but_a_new_counter_remains_usable() {
        let temp = Temp::new();
        let factor = totp(TEST_SECRET);
        assert!(Repository {
            root: temp.0.clone()
        }
        .consume(&factor, &factor.generate(TEST_TIME), || Ok(TEST_TIME))
        .unwrap());
        assert!(child(&temp.0, "one", TEST_TIME).wait().unwrap().success());
        assert_eq!(
            std::fs::read_to_string(temp.0.join("result-one")).unwrap(),
            "0"
        );
        assert!(child(&temp.0, "two", TEST_TIME + 30)
            .wait()
            .unwrap()
            .success());
        assert_eq!(
            std::fs::read_to_string(temp.0.join("result-two")).unwrap(),
            "1"
        );
        let recreated = Repository {
            root: temp.0.clone(),
        };
        assert!(!recreated
            .consume(&factor, &factor.generate(TEST_TIME), || Ok(TEST_TIME))
            .unwrap());
        let (name, hash) = Repository::name(&factor);
        let bytes = Directory::open(&temp.0)
            .unwrap()
            .read(&name, 2048)
            .unwrap()
            .unwrap();
        let saved: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(saved["counter"], (TEST_TIME + 30) / 30);
        assert_eq!(saved["factor"], hash);
        assert_eq!(saved.as_object().unwrap().len(), 3);
        assert!(!String::from_utf8(bytes)
            .unwrap()
            .contains(std::str::from_utf8(TEST_SECRET).unwrap()));
    }
    #[test]
    fn two_independent_authentication_processes_accept_one_code_only_once() {
        for _ in 0..8 {
            let temp = Temp::new();
            let mut one = child(&temp.0, "one", TEST_TIME);
            let mut two = child(&temp.0, "two", TEST_TIME);
            let one = one.wait().unwrap();
            let two = two.wait().unwrap();
            assert!(one.success() && two.success(), "child exits: {one} / {two}");
            let mut results = vec![
                std::fs::read_to_string(temp.0.join("result-one")).unwrap(),
                std::fs::read_to_string(temp.0.join("result-two")).unwrap(),
            ];
            results.sort();
            assert_eq!(results, vec!["0", "1"]);
        }
    }
    #[test]
    fn damaged_counter_is_preserved_and_fresh_factor_enrollment_can_recover() {
        let temp = Temp::new();
        let repository = Repository {
            root: temp.0.clone(),
        };
        let original = totp(TEST_SECRET);
        let replacement = totp(b"synthetic-only-fresh-totp-recovery");
        let directory = Directory::open(&temp.0).unwrap();
        let (name, hash) = Repository::name(&original);
        let invalid = [
            b"invalid-json".to_vec(),
            serde_json::to_vec(&serde_json::json!({
            "version":1,"factor":hash,"counter":u64::MAX}))
            .unwrap(),
            serde_json::to_vec(
                &serde_json::json!({"version":1,"factor":"00".repeat(32),"counter":2}),
            )
            .unwrap(),
        ];
        for bytes in invalid {
            directory.replace(&name, &bytes).unwrap();
            assert!(repository.status(&original).is_err());
            assert!(repository
                .consume(&original, &original.generate(TEST_TIME), || Ok(TEST_TIME))
                .is_err());
            assert_eq!(directory.read(&name, 2048).unwrap().unwrap(), bytes);
        }
        let retained = directory.read(&name, 2048).unwrap().unwrap();
        assert!(repository
            .consume(&replacement, &replacement.generate(TEST_TIME), || Ok(
                TEST_TIME
            ))
            .unwrap());
        assert!(repository.status(&replacement).is_ok());
        assert_eq!(directory.read(&name, 2048).unwrap().unwrap(), retained);
    }
    #[test]
    fn malformed_code_does_not_write_and_late_verification_uses_current_time() {
        let temp = Temp::new();
        let repository = Repository {
            root: temp.0.clone(),
        };
        let factor = totp(TEST_SECRET);
        let directory = Directory::open(&temp.0).unwrap();
        let (name, _) = Repository::name(&factor);
        assert!(!repository
            .consume(&factor, "invalid", || Ok(TEST_TIME))
            .unwrap());
        assert!(!directory.exists(&name).unwrap());
        assert!(!repository
            .consume(&factor, &factor.generate(TEST_TIME), || Ok(TEST_TIME + 90))
            .unwrap());
        assert!(!directory.exists(&name).unwrap());
        assert!(repository
            .consume(&factor, &factor.generate(TEST_TIME + 90), || Ok(
                TEST_TIME + 90
            ))
            .unwrap());
    }
    #[cfg(unix)]
    #[test]
    fn storage_write_failure_cannot_grant_authentication_or_erase_last_counter() {
        use std::os::unix::fs::PermissionsExt;
        let temp = Temp::new();
        let repository = Repository {
            root: temp.0.clone(),
        };
        let factor = totp(TEST_SECRET);
        let directory = Directory::open(&temp.0).unwrap();
        let (name, _) = Repository::name(&factor);
        assert!(repository
            .consume(&factor, &factor.generate(TEST_TIME), || Ok(TEST_TIME))
            .unwrap());
        let before = directory.read(&name, 2048).unwrap().unwrap();
        std::fs::set_permissions(&temp.0, std::fs::Permissions::from_mode(0o500)).unwrap();
        let result = repository.consume(&factor, &factor.generate(TEST_TIME + 30), || {
            Ok(TEST_TIME + 30)
        });
        std::fs::set_permissions(&temp.0, std::fs::Permissions::from_mode(0o700)).unwrap();
        assert!(result.is_err());
        assert_eq!(directory.read(&name, 2048).unwrap().unwrap(), before);
        assert!(repository
            .consume(&factor, &factor.generate(TEST_TIME + 30), || Ok(
                TEST_TIME + 30
            ))
            .unwrap());
    }
}
