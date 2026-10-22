//! Installing a verified update as root (C13). The app downloads the release,
//! checks its signed manifest and unpacks the bundle in the user's staging
//! directory. Here that bundle is first copied into the root-owned work
//! directory, where the user can no longer change it, and only that copy is
//! checked (fixed certificate, bundle identifier, a newer version) and moved
//! into place. The replaced app is kept to restore after a failed check and
//! for one manual rollback.
//!
//! Root only renames entries inside /Applications and its own directory and
//! only writes inside its own directory, so a planted symbolic link can make
//! a step fail but cannot redirect a write.
use crate::{bundle_allowed, BUNDLE_ID, REQUIREMENT};
use std::{
    fs,
    os::unix::fs::{DirBuilderExt, MetadataExt},
    path::{Path, PathBuf},
    process::Command,
};

const APP: &str = "NikoDesk.app";

/// `CFBundleShortVersionString` (three numbers) then `CFBundleVersion`.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub struct Version(Vec<u64>);

impl Version {
    pub fn parse(short: &str, build: &str) -> Option<Self> {
        let mut parts = short
            .trim()
            .split('.')
            .map(|part| part.parse().ok())
            .collect::<Option<Vec<u64>>>()?;
        if parts.len() != 3 {
            return None;
        }
        parts.push(build.trim().parse().ok()?);
        Some(Self(parts))
    }
}

impl std::fmt::Display for Version {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self.0.as_slice() {
            [major, minor, patch, build] => write!(f, "{major}.{minor}.{patch}+{build}"),
            _ => write!(f, "unknown"),
        }
    }
}

/// What a bundle must pass before it is installed or run by root.
pub type Check<'a> = &'a dyn Fn(&Path) -> Result<Version, &'static str>;

/// The production check: the NikoDesk identifier, the fixed certificate over
/// every nested executable, and a readable version.
pub fn check_bundle(bundle: &Path) -> Result<Version, &'static str> {
    if info_value(bundle, "CFBundleIdentifier").as_deref() != Some(BUNDLE_ID) {
        return Err("bundle_id_mismatch");
    }
    if !bundle_allowed(bundle, REQUIREMENT) {
        return Err("signature_not_allowed");
    }
    version(bundle).ok_or("version_unreadable")
}

pub fn version(bundle: &Path) -> Option<Version> {
    Version::parse(
        &info_value(bundle, "CFBundleShortVersionString")?,
        &info_value(bundle, "CFBundleVersion")?,
    )
}

fn info_value(bundle: &Path, key: &str) -> Option<String> {
    let output = Command::new("/usr/bin/plutil")
        .args(["-extract", key, "raw", "-o", "-"])
        .arg(bundle.join("Contents/Info.plist"))
        .output()
        .ok()?;
    output
        .status
        .success()
        .then(|| String::from_utf8_lossy(&output.stdout).trim().to_owned())
}

/// The bundle the app staged: an absolute path to a `NikoDesk.app` directory
/// owned by the caller and reached without symbolic links.
pub fn staged(path: &str, owner: u32) -> Result<PathBuf, &'static str> {
    let path = Path::new(path);
    if !path.is_absolute() || path.file_name() != Some(APP.as_ref()) {
        return Err("staged_path_invalid");
    }
    let meta = fs::symlink_metadata(path).map_err(|_| "staged_missing")?;
    if !meta.is_dir() || path.canonicalize().ok().as_deref() != Some(path) {
        return Err("staged_path_invalid");
    }
    if meta.uid() != owner {
        return Err("staged_owner_mismatch");
    }
    Ok(path.to_path_buf())
}

/// The work directory and its parent, owned by this process's user and not
/// writable by anyone else; leftovers of an interrupted run are removed.
fn prepare(work: &Path) -> Result<(), &'static str> {
    fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(work)
        .map_err(|_| "work_dir_failed")?;
    let euid = unsafe { libc::geteuid() };
    for dir in [Some(work), work.parent()].into_iter().flatten() {
        let meta = fs::symlink_metadata(dir).map_err(|_| "work_dir_failed")?;
        if !meta.is_dir() || meta.uid() != euid || meta.mode() & 0o022 != 0 {
            return Err("work_dir_unsafe");
        }
    }
    for leftover in ["incoming", "failed", "verified", "retired"] {
        remove(&work.join(leftover))?;
    }
    Ok(())
}

fn remove(path: &Path) -> Result<(), &'static str> {
    match fs::symlink_metadata(path) {
        Err(_) => Ok(()),
        Ok(meta) if meta.is_dir() => fs::remove_dir_all(path).map_err(|_| "cleanup_failed"),
        Ok(_) => fs::remove_file(path).map_err(|_| "cleanup_failed"),
    }
}

/// `to` must not exist. ditto keeps what a code signature covers: extended
/// attributes, symbolic links and permissions.
fn copy(from: &Path, to: &Path) -> Result<(), &'static str> {
    if let Some(parent) = to.parent() {
        fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(parent)
            .map_err(|_| "copy_failed")?;
    }
    let status = Command::new("/usr/bin/ditto")
        .arg(from)
        .arg(to)
        .status()
        .map_err(|_| "copy_failed")?;
    if !status.success() {
        return Err("copy_failed");
    }
    seal(to)
}

/// As root, ditto keeps the owner of the source, so a copy of the user's
/// files would stay theirs; a file can be opened by its inode number without
/// passing the root-only directory. Root takes the copy over, and nobody else
/// may write to it. Symbolic links are not followed.
fn seal(path: &Path) -> Result<(), &'static str> {
    if unsafe { libc::geteuid() } != 0 {
        return Ok(());
    }
    for (tool, args) in [("/usr/sbin/chown", ["-R", "-h", "root:wheel"]), ("/bin/chmod", ["-R", "-h", "go-w"])] {
        let status = Command::new(tool).args(args).arg(path).status().map_err(|_| "seal_failed")?;
        if !status.success() {
            return Err("seal_failed");
        }
    }
    Ok(())
}

fn slot(work: &Path, name: &str) -> PathBuf {
    work.join(name).join(APP)
}

/// Installs `staged` at `target`. Any failure leaves `target` as it was. On
/// success a checked copy of the new app is left in `verified` for
/// [`replace_service_copy`].
pub fn install(staged: &Path, target: &Path, work: &Path, check: Check) -> Result<Version, &'static str> {
    prepare(work)?;
    let incoming = slot(work, "incoming");
    copy(staged, &incoming)?;
    let new = check(&incoming)?;
    let current = version(target).ok_or("installed_version_unreadable")?;
    if new <= current {
        return Err("not_newer");
    }
    let verified = slot(work, "verified");
    copy(&incoming, &verified)?;
    if check(&verified)? != new {
        return Err("copy_mismatch");
    }
    swap_in(&incoming, target, work, check, &new)?;
    Ok(new)
}

/// Moves `incoming` to `target`, keeping the replaced bundle as `previous`.
fn swap_in(incoming: &Path, target: &Path, work: &Path, check: Check, expected: &Version) -> Result<(), &'static str> {
    let previous = slot(work, "previous");
    remove(&previous)?;
    fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(previous.parent().ok_or("work_dir_failed")?)
        .map_err(|_| "work_dir_failed")?;
    fs::rename(target, &previous).map_err(|_| "swap_failed")?;
    if fs::rename(incoming, target).is_err() {
        let _ = fs::rename(&previous, target);
        return Err("swap_failed");
    }
    match check(target) {
        Ok(version) if &version == expected => Ok(()),
        _ => {
            let failed = slot(work, "failed");
            let _ = fs::DirBuilder::new().recursive(true).mode(0o700).create(work.join("failed"));
            if fs::rename(target, &failed).is_ok() {
                let _ = fs::rename(&previous, target);
            }
            Err("installed_check_failed_restored")
        }
    }
}

/// Puts the app kept by the last install back at `target`; the app it
/// replaces is dropped.
pub fn restore(target: &Path, work: &Path, check: Check) -> Result<Version, &'static str> {
    prepare(work)?;
    let previous = slot(work, "previous");
    if !fs::symlink_metadata(&previous).is_ok_and(|meta| meta.is_dir()) {
        return Err("previous_missing");
    }
    let version = check(&previous)?;
    let failed = slot(work, "failed");
    fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(work.join("failed"))
        .map_err(|_| "work_dir_failed")?;
    fs::rename(target, &failed).map_err(|_| "swap_failed")?;
    if fs::rename(&previous, target).is_err() {
        let _ = fs::rename(&failed, target);
        return Err("swap_failed");
    }
    let _ = remove(&work.join("failed"));
    Ok(version)
}

/// Replaces root's copy with `verified` (inside the work directory, already
/// checked). The copy may be the one running this process; renaming a
/// running program's bundle does not affect it.
pub fn replace_service_copy(verified: &Path, service_app: &Path, work: &Path) -> Result<(), &'static str> {
    let retired = slot(work, "retired");
    remove(&retired)?;
    fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(work.join("retired"))
        .map_err(|_| "work_dir_failed")?;
    let had_copy = fs::symlink_metadata(service_app).is_ok();
    if had_copy {
        fs::rename(service_app, &retired).map_err(|_| "service_swap_failed")?;
    }
    if fs::rename(verified, service_app).is_err() {
        if had_copy {
            let _ = fs::rename(&retired, service_app);
        }
        return Err("service_swap_failed");
    }
    let _ = remove(&work.join("retired"));
    Ok(())
}

/// Brings root's copy up to the app in `installed` (after an update the user
/// installed by hand), never back to an older version.
pub fn sync(installed: &Path, service_app: &Path, work: &Path, check: Check) -> Result<Option<Version>, &'static str> {
    prepare(work)?;
    let verified = slot(work, "verified");
    copy(installed, &verified)?;
    let new = check(&verified)?;
    if version(service_app).is_some_and(|current| new <= current) {
        let _ = remove(&work.join("verified"));
        return Ok(None);
    }
    replace_service_copy(&verified, service_app, work)?;
    Ok(Some(new))
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Scratch(PathBuf);

    impl Scratch {
        fn new(name: &str) -> Self {
            let base = std::env::temp_dir()
                .canonicalize()
                .unwrap()
                .join(format!("niko-update-{name}-{}", std::process::id()));
            let _ = fs::remove_dir_all(&base);
            fs::create_dir_all(&base).unwrap();
            Self(base)
        }
        fn path(&self, rest: &str) -> PathBuf {
            self.0.join(rest)
        }
    }

    impl Drop for Scratch {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    /// A fake bundle: an Info.plist with the version and a marker file that
    /// stands for a valid signature.
    fn bundle(at: &Path, short: &str, build: u32, signed: bool) {
        fs::create_dir_all(at.join("Contents/MacOS")).unwrap();
        fs::write(
            at.join("Contents/Info.plist"),
            format!(
                r#"<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>io.nikodesk.macos</string>
<key>CFBundleShortVersionString</key><string>{short}</string>
<key>CFBundleVersion</key><string>{build}</string>
</dict></plist>"#
            ),
        )
        .unwrap();
        fs::write(at.join("Contents/MacOS/NikoDesk"), format!("{short}+{build}")).unwrap();
        if signed {
            fs::write(at.join("Contents/signed"), "").unwrap();
        }
    }

    fn fake_check(bundle: &Path) -> Result<Version, &'static str> {
        if !bundle.join("Contents/signed").exists() {
            return Err("signature_not_allowed");
        }
        version(bundle).ok_or("version_unreadable")
    }

    fn running(target: &Path) -> String {
        fs::read_to_string(target.join("Contents/MacOS/NikoDesk")).unwrap()
    }

    #[test]
    fn versions_compare_by_number_then_build() {
        let v = |s, b| Version::parse(s, b).unwrap();
        assert!(v("1.0.11", "22") < v("2.0.0", "23"));
        assert!(v("1.0.9", "30") < v("1.0.10", "21"));
        assert!(v("2.0.0", "23") < v("2.0.0", "24"));
        assert_eq!(v("2.0.0", "23").to_string(), "2.0.0+23");
        assert!(Version::parse("2.0", "1").is_none());
        assert!(Version::parse("2.0.0", "x").is_none());
    }

    #[test]
    fn a_newer_signed_bundle_replaces_the_app_and_the_old_one_can_be_restored() {
        let scratch = Scratch::new("ok");
        let (staged, target, work) = (scratch.path("stage/NikoDesk.app"), scratch.path("Applications/NikoDesk.app"), scratch.path("root/update"));
        bundle(&target, "1.0.11", 22, true);
        bundle(&staged, "2.0.0", 23, true);
        let installed = install(&staged, &target, &work, &fake_check).unwrap();
        assert_eq!(installed.to_string(), "2.0.0+23");
        assert_eq!(running(&target), "2.0.0+23");
        assert!(slot(&work, "verified").exists(), "a checked copy is left for root's copy");
        assert!(staged.exists(), "the staged bundle is copied, never moved");
        let restored = restore(&target, &work, &fake_check).unwrap();
        assert_eq!(restored.to_string(), "1.0.11+22");
        assert_eq!(running(&target), "1.0.11+22");
        assert_eq!(restore(&target, &work, &fake_check), Err("previous_missing"), "only one step back");
    }

    #[test]
    fn unsigned_older_or_unreadable_bundles_leave_the_app_alone() {
        let scratch = Scratch::new("refuse");
        let (staged, target, work) = (scratch.path("stage/NikoDesk.app"), scratch.path("Applications/NikoDesk.app"), scratch.path("root/update"));
        bundle(&target, "2.0.0", 23, true);
        bundle(&staged, "2.1.0", 30, false);
        assert_eq!(install(&staged, &target, &work, &fake_check), Err("signature_not_allowed"));
        fs::remove_dir_all(&staged).unwrap();
        bundle(&staged, "2.0.0", 23, true);
        assert_eq!(install(&staged, &target, &work, &fake_check), Err("not_newer"));
        fs::remove_dir_all(&staged).unwrap();
        bundle(&staged, "1.0.11", 22, true);
        assert_eq!(install(&staged, &target, &work, &fake_check), Err("not_newer"));
        assert_eq!(running(&target), "2.0.0+23");
        assert!(!slot(&work, "previous").exists());
    }

    #[test]
    fn a_failed_check_after_the_swap_puts_the_old_app_back() {
        let scratch = Scratch::new("rollback");
        let (staged, target, work) = (scratch.path("stage/NikoDesk.app"), scratch.path("Applications/NikoDesk.app"), scratch.path("root/update"));
        bundle(&target, "1.0.11", 22, true);
        bundle(&staged, "2.0.0", 23, true);
        let at_target = target.clone();
        // Passes in the work directory, fails once it is at the target.
        let check = move |bundle: &Path| {
            if bundle == at_target.as_path() {
                Err("signature_not_allowed")
            } else {
                fake_check(bundle)
            }
        };
        assert_eq!(install(&staged, &target, &work, &check), Err("installed_check_failed_restored"));
        assert_eq!(running(&target), "1.0.11+22");
    }

    #[test]
    fn root_copy_follows_hand_installs_but_never_goes_back() {
        let scratch = Scratch::new("sync");
        let (installed, service, work) = (scratch.path("Applications/NikoDesk.app"), scratch.path("root/service/NikoDesk.app"), scratch.path("root/update"));
        bundle(&installed, "2.0.0", 23, true);
        bundle(&service, "1.0.11", 22, true);
        assert_eq!(sync(&installed, &service, &work, &fake_check).unwrap().unwrap().to_string(), "2.0.0+23");
        assert_eq!(running(&service), "2.0.0+23");
        assert_eq!(sync(&installed, &service, &work, &fake_check), Ok(None));
        fs::remove_dir_all(&installed).unwrap();
        bundle(&installed, "1.0.11", 22, true);
        assert_eq!(sync(&installed, &service, &work, &fake_check), Ok(None), "no downgrade");
        assert_eq!(running(&service), "2.0.0+23");
        fs::remove_dir_all(&installed).unwrap();
        bundle(&installed, "3.0.0", 40, false);
        assert_eq!(sync(&installed, &service, &work, &fake_check), Err("signature_not_allowed"));
        assert_eq!(running(&service), "2.0.0+23");
    }

    #[test]
    fn staged_paths_must_be_plain_owned_bundles() {
        let scratch = Scratch::new("staged");
        let owner = unsafe { libc::geteuid() };
        let real = scratch.path("stage/NikoDesk.app");
        bundle(&real, "2.0.0", 23, true);
        assert!(staged(real.to_str().unwrap(), owner).is_ok());
        assert_eq!(staged("relative/NikoDesk.app", owner), Err("staged_path_invalid"));
        assert_eq!(staged(scratch.path("stage").to_str().unwrap(), owner), Err("staged_path_invalid"));
        let link_dir = scratch.path("link");
        std::os::unix::fs::symlink(scratch.path("stage"), &link_dir).unwrap();
        assert_eq!(staged(link_dir.join("NikoDesk.app").to_str().unwrap(), owner), Err("staged_path_invalid"));
        assert_eq!(staged(real.to_str().unwrap(), owner + 1), Err("staged_owner_mismatch"));
    }

    #[test]
    fn a_work_directory_others_can_write_is_refused() {
        let scratch = Scratch::new("unsafe");
        let work = scratch.path("root/update");
        prepare(&work).unwrap();
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(scratch.path("root"), fs::Permissions::from_mode(0o777)).unwrap();
        assert_eq!(prepare(&work), Err("work_dir_unsafe"));
    }
}
