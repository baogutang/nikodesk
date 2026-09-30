//! Fallible, disk-based favorites. No upstream LocalConfig cache is written.
use super::server_scope::ServerScope;
use hbb_common::{anyhow::anyhow, bail, ResultType};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    collections::{BTreeMap, BTreeSet},
    path::PathBuf,
};

const FILE: &str = "nikodesk-favorites-v1.json";
const MAX_IDS: usize = 4096;
const MAX_SCOPES: usize = 256;

#[derive(Default, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Document {
    version: u32,
    seeded: bool,
    scopes: BTreeMap<String, BTreeSet<String>>,
}

#[derive(Serialize)]
pub struct Snapshot {
    pub ok: bool,
    pub status: &'static str,
    pub namespace: String,
    pub revision: String,
    pub ids: Vec<String>,
}

pub(crate) struct Repository {
    root: PathBuf,
}

impl Repository {
    pub(crate) fn new(root: PathBuf) -> Self {
        Self { root }
    }

    fn load(&self, directory: &storage::Directory) -> ResultType<Document> {
        let mut document = match directory.read(FILE, 1024 * 1024)? {
            Some(bytes) => serde_json::from_slice::<Document>(&bytes)
                .map_err(|_| anyhow!("invalid_favorites_file"))?,
            None => Document {
                version: 1,
                ..Document::default()
            },
        };
        if document.version != 1 || document.scopes.len() > MAX_SCOPES {
            bail!("invalid_favorites_file");
        }
        for (namespace, ids) in &document.scopes {
            validate_ids(namespace, &ids.iter().cloned().collect::<Vec<_>>())?;
        }
        if !document.seeded {
            if let Some(bytes) = directory.read("NikoDesk_local.toml", 1024 * 1024)? {
                let value: hbb_common::toml::Value = hbb_common::toml::from_str(
                    std::str::from_utf8(&bytes)
                        .map_err(|_| anyhow!("invalid_legacy_favorites_file"))?,
                )
                .map_err(|_| anyhow!("invalid_legacy_favorites_file"))?;
                let favs = value
                    .get("fav")
                    .and_then(|v| v.as_array())
                    .ok_or_else(|| anyhow!("invalid_legacy_favorites_file"))?;
                if favs.len() > MAX_IDS {
                    bail!("too_many_legacy_favorites");
                }
                for value in favs {
                    let favorite = value
                        .as_str()
                        .ok_or_else(|| anyhow!("invalid_legacy_favorites_file"))?;
                    if let Some((namespace, id)) = decode_scoped_id(favorite) {
                        document.scopes.entry(namespace).or_default().insert(id);
                    }
                }
            }
            if document.scopes.len() > MAX_SCOPES {
                bail!("too_many_favorite_namespaces");
            }
            for (namespace, ids) in &document.scopes {
                validate_ids(namespace, &ids.iter().cloned().collect::<Vec<_>>())?;
            }
            document.seeded = true;
            directory.replace(FILE, &serde_json::to_vec(&document)?)?;
        }
        Ok(document)
    }

    pub(crate) fn get(&self, namespace: &str) -> ResultType<Snapshot> {
        validate_ids(namespace, &[])?;
        let directory = storage::Directory::open(&self.root)?;
        let _lock = directory.lock("nikodesk-favorites.lock")?;
        let document = self.load(&directory)?;
        Ok(snapshot(
            namespace,
            document.scopes.get(namespace),
            "ready",
            true,
        ))
    }

    pub(crate) fn patch(
        &self,
        namespace: &str,
        expected: &str,
        add: &[String],
        remove: &[String],
    ) -> ResultType<Snapshot> {
        validate_ids(namespace, add)?;
        validate_ids(namespace, remove)?;
        if ServerScope::from_namespace(expected).is_none() {
            bail!("invalid_revision");
        }
        if add.iter().any(|id| remove.contains(id)) {
            bail!("conflicting_favorite_patch");
        }
        let directory = storage::Directory::open(&self.root)?;
        let _lock = directory.lock("nikodesk-favorites.lock")?;
        let mut document = self.load(&directory)?;
        let current = snapshot(namespace, document.scopes.get(namespace), "ready", true);
        if current.revision != expected {
            return Ok(snapshot(
                namespace,
                document.scopes.get(namespace),
                "conflict",
                false,
            ));
        }
        if !document.scopes.contains_key(namespace) && document.scopes.len() >= MAX_SCOPES {
            bail!("too_many_favorite_namespaces");
        }
        let ids = document.scopes.entry(namespace.to_owned()).or_default();
        for id in remove {
            ids.remove(id);
        }
        ids.extend(add.iter().cloned());
        if ids.len() > MAX_IDS {
            bail!("too_many_favorites");
        }
        let result = snapshot(namespace, Some(ids), "saved", true);
        directory.replace(FILE, &serde_json::to_vec(&document)?)?;
        Ok(result)
    }

    pub(crate) fn replace_compat(&self, namespace: &str, ids: Vec<String>) -> ResultType<()> {
        // The legacy void setter cannot express CAS. Refuse it: new callers must
        // provide a revision instead of silently replacing another window's set.
        validate_ids(namespace, &ids)?;
        bail!("favorites_revision_required");
    }
}

fn validate_ids(namespace: &str, ids: &[String]) -> ResultType<()> {
    if ServerScope::from_namespace(namespace).is_none() {
        bail!("invalid_namespace");
    }
    if ids.len() > MAX_IDS {
        bail!("too_many_favorites");
    }
    for id in ids {
        super::validate_remote_id(id)?;
    }
    Ok(())
}

fn decode_scoped_id(value: &str) -> Option<(String, String)> {
    let (namespace, id) = value.strip_prefix("nikodesk_v1_")?.split_once('_')?;
    validate_ids(namespace, &[id.to_owned()]).ok()?;
    Some((namespace.to_owned(), id.to_owned()))
}

fn snapshot(
    namespace: &str,
    ids: Option<&BTreeSet<String>>,
    status: &'static str,
    ok: bool,
) -> Snapshot {
    let ids = ids
        .map(|ids| ids.iter().cloned().collect::<Vec<_>>())
        .unwrap_or_default();
    let mut digest = Sha256::new();
    digest.update(b"nikodesk-favorites-revision-v1\0");
    digest.update(namespace.as_bytes());
    for id in &ids {
        digest.update([0]);
        digest.update(id.as_bytes());
    }
    Snapshot {
        ok,
        status,
        namespace: namespace.to_owned(),
        revision: format!("{:x}", digest.finalize()),
        ids,
    }
}

pub(crate) fn context(namespace: &str) -> ResultType<Repository> {
    if ServerScope::from_namespace(namespace).is_none() {
        bail!("invalid_namespace");
    }
    super::initialize()?;
    let options = super::server_settings::read_verified_options()?;
    if super::server_scope::namespace_from_options(&options).as_deref() != Some(namespace) {
        bail!("namespace_changed");
    }
    Ok(Repository::new(application_root()?))
}
pub(crate) fn application_root() -> ResultType<PathBuf> {
    super::initialize()?;
    let path = hbb_common::config::Config::file();
    if path.file_name().and_then(|v| v.to_str()) != Some("NikoDesk.toml") {
        bail!("invalid_private_directory");
    }
    Ok(path
        .parent()
        .ok_or_else(|| anyhow!("invalid_private_directory"))?
        .to_owned())
}

pub(crate) fn json<T: Serialize>(result: ResultType<T>) -> String {
    match result {
        Ok(value) => {
            serde_json::to_string(&value).unwrap_or_else(|_| error_json("serialization_failed"))
        }
        // Filesystem errors may contain private paths. Report a bounded category.
        Err(error) => {
            let status = if error.downcast_ref::<std::io::Error>().is_some() {
                "disk_error"
            } else {
                match error.to_string().as_str() {
                    "invalid_namespace" => "invalid_namespace",
                    "namespace_changed" => "namespace_changed",
                    "invalid_revision" => "invalid_revision",
                    "peer_writers_not_coordinated" => "peer_writers_not_coordinated",
                    "atomic_peer_publish_unverified_on_windows" => "unsupported_atomic_publish",
                    "legacy_peer_changed" | "peer_not_in_preview" => "revision_changed",
                    "favorites_revision_required" => "revision_required",
                    "too_many_favorites"
                    | "too_many_favorite_namespaces"
                    | "too_many_legacy_favorites"
                    | "too_many_peer_files"
                    | "too_many_peers"
                    | "storage_file_too_large" => "limit_exceeded",
                    "invalid_favorites_file"
                    | "invalid_legacy_favorites_file"
                    | "invalid_legacy_peer"
                    | "invalid_legacy_preference"
                    | "conflicting_favorite_patch" => "invalid_data",
                    "linked_storage_directory"
                    | "linked_storage_lock"
                    | "invalid_storage_name"
                    | "foreign_storage_directory" => "unsafe_path",
                    _ => "unavailable",
                }
            };
            error_json(status)
        }
    }
}
fn error_json(status: &str) -> String {
    serde_json::json!({"ok": false, "status": status}).to_string()
}

pub fn get(namespace: &str) -> String {
    json(context(namespace).and_then(|repo| repo.get(namespace)))
}
pub fn patch(namespace: &str, revision: &str, add: &[String], remove: &[String]) -> String {
    json(context(namespace).and_then(|repo| repo.patch(namespace, revision, add, remove)))
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use std::{fs, process::Command};
    pub(crate) struct Temp(pub PathBuf);
    impl Temp {
        pub(crate) fn new() -> Self {
            let path = std::env::temp_dir().canonicalize().unwrap().join(format!(
                "nikodesk-repository-test-{}",
                hbb_common::uuid::Uuid::new_v4()
            ));
            fs::create_dir(&path).unwrap();
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                fs::set_permissions(&path, fs::Permissions::from_mode(0o700)).unwrap();
            }
            Self(path)
        }
    }
    impl Drop for Temp {
        fn drop(&mut self) {
            fs::remove_dir_all(&self.0).unwrap();
        }
    }
    pub(crate) fn ns(c: char) -> String {
        c.to_string().repeat(64)
    }
    fn repo(temp: &Temp) -> Repository {
        Repository::new(temp.0.clone())
    }
    fn child(temp: &Temp, namespace: &str, id: &str, revision: &str) -> std::process::Child {
        Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "nikodesk::favorites::tests::repository_child",
                "--nocapture",
            ])
            .env("NIKODESK_REPOSITORY_TEST_ROOT", &temp.0)
            .env("NIKODESK_REPOSITORY_TEST_NS", namespace)
            .env("NIKODESK_REPOSITORY_TEST_ID", id)
            .env("NIKODESK_REPOSITORY_TEST_REV", revision)
            .spawn()
            .unwrap()
    }

    #[test]
    fn repository_child() {
        let Some(root) = std::env::var_os("NIKODESK_REPOSITORY_TEST_ROOT") else {
            return;
        };
        let namespace = std::env::var("NIKODESK_REPOSITORY_TEST_NS").unwrap();
        let id = std::env::var("NIKODESK_REPOSITORY_TEST_ID").unwrap();
        let revision = std::env::var("NIKODESK_REPOSITORY_TEST_REV").unwrap();
        let snapshot = Repository::new(root.into())
            .patch(&namespace, &revision, &[id], &[])
            .unwrap();
        assert!(matches!(snapshot.status, "saved" | "conflict"));
    }
    #[test]
    fn stale_revision_refuses_and_returns_the_current_set() {
        let temp = Temp::new();
        let repo = repo(&temp);
        let a = ns('a');
        let first = repo.get(&a).unwrap();
        let saved = repo
            .patch(&a, &first.revision, &["123456789".into()], &[])
            .unwrap();
        let conflict = repo
            .patch(&a, &first.revision, &["987654321".into()], &[])
            .unwrap();
        assert!(!conflict.ok);
        assert_eq!(conflict.status, "conflict");
        assert_eq!(conflict.ids, saved.ids);
        assert_eq!(repo.get(&a).unwrap().ids, saved.ids);
    }
    #[test]
    fn independent_processes_merge_different_namespaces() {
        let temp = Temp::new();
        let repo = repo(&temp);
        let a = ns('a');
        let b = ns('b');
        let ra = repo.get(&a).unwrap().revision;
        let rb = repo.get(&b).unwrap().revision;
        let mut first = child(&temp, &a, "123456789", &ra);
        let mut second = child(&temp, &b, "987654321", &rb);
        assert!(first.wait().unwrap().success());
        assert!(second.wait().unwrap().success());
        assert_eq!(repo.get(&a).unwrap().ids, vec!["123456789"]);
        assert_eq!(repo.get(&b).unwrap().ids, vec!["987654321"]);
    }
    #[test]
    fn independent_processes_same_revision_have_one_winner() {
        let temp = Temp::new();
        let repo = repo(&temp);
        let a = ns('a');
        let revision = repo.get(&a).unwrap().revision;
        let mut first = child(&temp, &a, "123456789", &revision);
        let mut second = child(&temp, &a, "987654321", &revision);
        assert!(first.wait().unwrap().success());
        assert!(second.wait().unwrap().success());
        assert_eq!(repo.get(&a).unwrap().ids.len(), 1);
    }
    #[test]
    fn seed_only_attributed_legacy_favorites_and_keep_original_bytes() {
        let temp = Temp::new();
        let a = ns('a');
        let b = ns('b');
        let dir = storage::Directory::open(&temp.0).unwrap();
        let original = format!("fav = ['123456789', 'nikodesk_v1_{a}_123456789', 'nikodesk_v1_{b}_987654321']\n[options]\nkeep = 'unchanged'\n");
        dir.replace("NikoDesk_local.toml", original.as_bytes())
            .unwrap();
        let repo = repo(&temp);
        assert_eq!(repo.get(&a).unwrap().ids, vec!["123456789"]);
        assert_eq!(repo.get(&b).unwrap().ids, vec!["987654321"]);
        let old_revision = repo.get(&a).unwrap().revision;
        repo.patch(&a, &old_revision, &[], &["123456789".into()])
            .unwrap();
        assert!(repo.get(&a).unwrap().ids.is_empty());
        assert_eq!(
            fs::read(temp.0.join("NikoDesk_local.toml")).unwrap(),
            original.as_bytes()
        );
    }
    #[test]
    fn idempotent_patch_keeps_revision_and_other_scopes() {
        let temp = Temp::new();
        let repo = repo(&temp);
        let a = ns('a');
        let first = repo.get(&a).unwrap();
        let saved = repo
            .patch(
                &a,
                &first.revision,
                &["123456789".into(), "123456789".into()],
                &[],
            )
            .unwrap();
        let next = repo
            .patch(&a, &saved.revision, &["123456789".into()], &[])
            .unwrap();
        assert_eq!(next.ids, saved.ids);
        assert_eq!(next.revision, saved.revision);
    }
    #[test]
    fn invalid_and_corrupt_data_do_not_overwrite() {
        let temp = Temp::new();
        let a = ns('a');
        let dir = storage::Directory::open(&temp.0).unwrap();
        let repo = repo(&temp);
        dir.replace(FILE, b"not valid json").unwrap();
        assert!(repo.get(&a).is_err());
        assert_eq!(fs::read(temp.0.join(FILE)).unwrap(), b"not valid json");
        assert!(repo
            .patch(&a, &ns('c'), &["../123456".into()], &[])
            .is_err());
        assert!(repo
            .patch(&a, &ns('c'), &["123456789".into()], &["123456789".into()])
            .is_err());
    }
    #[test]
    fn incomplete_legacy_seed_never_publishes_an_empty_repository() {
        let temp = Temp::new();
        let dir = storage::Directory::open(&temp.0).unwrap();
        let repo = repo(&temp);
        for bytes in [
            b"[options]\nalias = 'fixture'\n".as_slice(),
            b"fav = [123456789]\n",
        ] {
            dir.replace("NikoDesk_local.toml", bytes).unwrap();
            assert!(repo.get(&ns('a')).is_err());
            assert!(!temp.0.join(FILE).exists());
            assert_eq!(fs::read(temp.0.join("NikoDesk_local.toml")).unwrap(), bytes);
        }
    }
    #[test]
    fn missing_directory_is_a_real_disk_error_and_does_not_report_success() {
        let temp = Temp::new();
        let repo = Repository::new(temp.0.join("missing"));
        let value: serde_json::Value = serde_json::from_str(&json(repo.get(&ns('a')))).unwrap();
        assert_eq!(value["ok"], false);
        assert_eq!(value["status"], "disk_error");
    }
    #[test]
    fn new_api_invalid_namespace_guards_do_not_initialize_user_config() {
        for value in [
            get(""),
            patch("../bad", "", &[], &[]),
            super::super::peer_migration::preview(""),
            super::super::peer_migration::import("", "", &[]),
        ] {
            let value: serde_json::Value = serde_json::from_str(&value).unwrap();
            assert_eq!(value["ok"], false);
            assert_eq!(value["status"], "invalid_namespace");
        }
    }
    #[cfg(unix)]
    #[test]
    fn linked_files_and_directories_are_rejected() {
        use std::os::unix::fs::symlink;
        let temp = Temp::new();
        let dir = storage::Directory::open(&temp.0).unwrap();
        dir.replace("original", b"secret-free-fixture").unwrap();
        symlink(temp.0.join("original"), temp.0.join(FILE)).unwrap();
        assert!(repo(&temp).get(&ns('a')).is_err());
        fs::remove_file(temp.0.join(FILE)).unwrap();
        fs::hard_link(temp.0.join("original"), temp.0.join(FILE)).unwrap();
        assert!(repo(&temp).get(&ns('a')).is_err());
        symlink(&temp.0, temp.0.join("alias")).unwrap();
        assert!(storage::Directory::open(&temp.0.join("alias")).is_err());
        assert_eq!(
            fs::read(temp.0.join("original")).unwrap(),
            b"secret-free-fixture"
        );
    }
}

/// Only explicit app-owned paths are accepted; tests never call global Config.
pub(crate) mod storage {
    use hbb_common::{anyhow::anyhow, bail, ResultType};
    #[cfg(windows)]
    use std::os::windows::{
        fs::{MetadataExt, OpenOptionsExt},
        io::AsRawHandle,
    };
    #[cfg(unix)]
    use std::{
        ffi::CString,
        os::{
            fd::{AsRawFd, FromRawFd},
            unix::fs::{MetadataExt, OpenOptionsExt},
        },
    };
    use std::{
        fs::{self, File, OpenOptions},
        io::{Read, Write},
        path::{Component, Path, PathBuf},
        time::{Duration, Instant},
    };

    pub(crate) struct Directory {
        path: PathBuf,
        #[cfg(unix)]
        file: File,
    }
    pub(crate) struct Lock {
        _file: File,
    }
    #[cfg(unix)]
    impl Drop for Lock {
        fn drop(&mut self) {
            unsafe {
                hbb_common::libc::flock(self._file.as_raw_fd(), hbb_common::libc::LOCK_UN);
            }
        }
    }

    fn name(value: &str) -> ResultType<()> {
        if value.is_empty()
            || Path::new(value).components().count() != 1
            || !matches!(
                Path::new(value).components().next(),
                Some(Component::Normal(_))
            )
        {
            bail!("invalid_storage_name");
        }
        Ok(())
    }

    fn check_path(path: &Path) -> ResultType<()> {
        if !path.is_absolute()
            || path
                .components()
                .any(|c| matches!(c, Component::ParentDir | Component::CurDir))
        {
            bail!("invalid_private_directory");
        }
        for ancestor in path.ancestors() {
            let meta = fs::symlink_metadata(ancestor)?;
            if meta.file_type().is_symlink() {
                bail!("linked_storage_directory");
            }
            #[cfg(windows)]
            if meta.file_attributes() & 0x400 != 0 {
                bail!("linked_storage_directory");
            }
        }
        Ok(())
    }

    impl Directory {
        pub(crate) fn open(path: &Path) -> ResultType<Self> {
            check_path(path)?;
            #[cfg(unix)]
            {
                let file = OpenOptions::new()
                    .read(true)
                    .custom_flags(
                        hbb_common::libc::O_DIRECTORY
                            | hbb_common::libc::O_NOFOLLOW
                            | hbb_common::libc::O_CLOEXEC,
                    )
                    .open(path)?;
                super::super::identity_file::check_metadata(&file.metadata()?, true)?;
                Ok(Self {
                    path: path.to_owned(),
                    file,
                })
            }
            #[cfg(windows)]
            {
                if !fs::symlink_metadata(path)?.is_dir() {
                    bail!("invalid_private_directory");
                }
                Ok(Self {
                    path: path.to_owned(),
                })
            }
        }

        pub(crate) fn child(&self, child: &str) -> ResultType<Self> {
            name(child)?;
            #[cfg(unix)]
            {
                let child_c = CString::new(child)?;
                let fd = unsafe {
                    hbb_common::libc::openat(
                        self.file.as_raw_fd(),
                        child_c.as_ptr(),
                        hbb_common::libc::O_DIRECTORY
                            | hbb_common::libc::O_NOFOLLOW
                            | hbb_common::libc::O_CLOEXEC,
                    )
                };
                if fd < 0 {
                    return Err(std::io::Error::last_os_error().into());
                }
                let file = unsafe { File::from_raw_fd(fd) };
                let metadata = file.metadata()?;
                // The private root prevents traversal by other users; historical
                // confy children can be 0755 but must not be group/world writable.
                if metadata.uid() != unsafe { hbb_common::libc::geteuid() }
                    || !metadata.is_dir()
                    || metadata.mode() & 0o022 != 0
                {
                    bail!("foreign_storage_directory");
                }
                Ok(Self {
                    path: self.path.join(child),
                    file,
                })
            }
            #[cfg(windows)]
            Self::open(&self.path.join(child))
        }

        pub(crate) fn ensure_child(&self, child: &str) -> ResultType<Self> {
            name(child)?;
            #[cfg(unix)]
            {
                let child_c = CString::new(child)?;
                if unsafe {
                    hbb_common::libc::mkdirat(self.file.as_raw_fd(), child_c.as_ptr(), 0o700)
                } != 0
                {
                    let error = std::io::Error::last_os_error();
                    if error.kind() != std::io::ErrorKind::AlreadyExists {
                        return Err(error.into());
                    }
                }
                let fd = unsafe {
                    hbb_common::libc::openat(
                        self.file.as_raw_fd(),
                        child_c.as_ptr(),
                        hbb_common::libc::O_DIRECTORY
                            | hbb_common::libc::O_NOFOLLOW
                            | hbb_common::libc::O_CLOEXEC,
                    )
                };
                if fd < 0 {
                    return Err(std::io::Error::last_os_error().into());
                }
                let file = unsafe { File::from_raw_fd(fd) };
                if file.metadata()?.uid() != unsafe { hbb_common::libc::geteuid() } {
                    bail!("foreign_storage_directory");
                }
                // Tighten only the opened Niko child inode created by confy.
                if unsafe { hbb_common::libc::fchmod(file.as_raw_fd(), 0o700) } != 0 {
                    return Err(std::io::Error::last_os_error().into());
                }
                super::super::identity_file::check_metadata(&file.metadata()?, true)?;
                file.sync_all()?;
                self.file.sync_all()?;
                Ok(Self {
                    path: self.path.join(child),
                    file,
                })
            }
            #[cfg(windows)]
            {
                match fs::create_dir(self.path.join(child)) {
                    Ok(()) => {}
                    Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {}
                    Err(e) => return Err(e.into()),
                }
                Self::open(&self.path.join(child))
            }
        }

        pub(crate) fn lease(&self, value: &str) -> ResultType<Lock> {
            name(value)?;
            #[cfg(unix)]
            {
                let file =
                    self.open_file(value, hbb_common::libc::O_RDWR | hbb_common::libc::O_CREAT)?;
                if unsafe {
                    hbb_common::libc::flock(
                        file.as_raw_fd(),
                        hbb_common::libc::LOCK_SH | hbb_common::libc::LOCK_NB,
                    )
                } != 0
                {
                    return Err(std::io::Error::last_os_error().into());
                }
                Ok(Lock { _file: file })
            }
            #[cfg(windows)]
            {
                use windows::Win32::Storage::FileSystem::FILE_FLAG_OPEN_REPARSE_POINT;
                let file = OpenOptions::new()
                    .read(true)
                    .write(true)
                    .create(true)
                    .share_mode(3)
                    .custom_flags(FILE_FLAG_OPEN_REPARSE_POINT.0)
                    .open(self.path.join(value))?;
                check_windows_lock(&file)?;
                Ok(Lock { _file: file })
            }
        }

        pub(crate) fn try_exclusive_lease(&self, value: &str) -> ResultType<Option<Lock>> {
            name(value)?;
            #[cfg(unix)]
            {
                let file =
                    self.open_file(value, hbb_common::libc::O_RDWR | hbb_common::libc::O_CREAT)?;
                if unsafe {
                    hbb_common::libc::flock(
                        file.as_raw_fd(),
                        hbb_common::libc::LOCK_EX | hbb_common::libc::LOCK_NB,
                    )
                } == 0
                {
                    return Ok(Some(Lock { _file: file }));
                }
                let error = std::io::Error::last_os_error();
                if error.raw_os_error() == Some(hbb_common::libc::EWOULDBLOCK) {
                    return Ok(None);
                }
                Err(error.into())
            }
            #[cfg(windows)]
            {
                use windows::Win32::Storage::FileSystem::FILE_FLAG_OPEN_REPARSE_POINT;
                match OpenOptions::new()
                    .read(true)
                    .write(true)
                    .create(true)
                    .share_mode(0)
                    .custom_flags(FILE_FLAG_OPEN_REPARSE_POINT.0)
                    .open(self.path.join(value))
                {
                    Ok(file) => {
                        check_windows_lock(&file)?;
                        Ok(Some(Lock { _file: file }))
                    }
                    Err(e) if matches!(e.raw_os_error(), Some(32 | 33)) => Ok(None),
                    Err(e) => Err(e.into()),
                }
            }
        }

        pub(crate) fn remove(&self, value: &str) -> ResultType<()> {
            if self.read(value, 1024 * 1024)?.is_none() {
                return Ok(());
            }
            #[cfg(unix)]
            {
                let value = CString::new(value)?;
                if unsafe { hbb_common::libc::unlinkat(self.file.as_raw_fd(), value.as_ptr(), 0) }
                    != 0
                {
                    return Err(std::io::Error::last_os_error().into());
                }
                self.file.sync_all()?;
            }
            #[cfg(windows)]
            fs::remove_file(self.path.join(value))?;
            Ok(())
        }

        #[cfg(unix)]
        fn open_file(&self, value: &str, flags: i32) -> ResultType<File> {
            name(value)?;
            let value = CString::new(value)?;
            let fd = unsafe {
                hbb_common::libc::openat(
                    self.file.as_raw_fd(),
                    value.as_ptr(),
                    flags | hbb_common::libc::O_NOFOLLOW | hbb_common::libc::O_CLOEXEC,
                    0o600,
                )
            };
            if fd < 0 {
                return Err(std::io::Error::last_os_error().into());
            }
            let file = unsafe { File::from_raw_fd(fd) };
            super::super::identity_file::check_metadata(&file.metadata()?, false)?;
            Ok(file)
        }

        pub(crate) fn lock(&self, value: &str) -> ResultType<Lock> {
            name(value)?;
            let deadline = Instant::now() + Duration::from_secs(3);
            #[cfg(unix)]
            {
                let file =
                    self.open_file(value, hbb_common::libc::O_RDWR | hbb_common::libc::O_CREAT)?;
                loop {
                    if unsafe {
                        hbb_common::libc::flock(
                            file.as_raw_fd(),
                            hbb_common::libc::LOCK_EX | hbb_common::libc::LOCK_NB,
                        )
                    } == 0
                    {
                        return Ok(Lock { _file: file });
                    }
                    let error = std::io::Error::last_os_error();
                    if !matches!(error.raw_os_error(), Some(hbb_common::libc::EWOULDBLOCK))
                        || Instant::now() >= deadline
                    {
                        return Err(error.into());
                    }
                    std::thread::sleep(Duration::from_millis(10));
                }
            }
            #[cfg(windows)]
            loop {
                use windows::Win32::Storage::FileSystem::{
                    GetFileInformationByHandle, BY_HANDLE_FILE_INFORMATION,
                    FILE_FLAG_OPEN_REPARSE_POINT,
                };
                match OpenOptions::new()
                    .read(true)
                    .write(true)
                    .create(true)
                    .share_mode(0)
                    .custom_flags(FILE_FLAG_OPEN_REPARSE_POINT.0)
                    .open(self.path.join(value))
                {
                    Ok(file) => {
                        let mut info = BY_HANDLE_FILE_INFORMATION::default();
                        unsafe {
                            GetFileInformationByHandle(
                                windows::Win32::Foundation::HANDLE(file.as_raw_handle()),
                                &mut info,
                            )?;
                        }
                        if !file.metadata()?.is_file()
                            || info.dwFileAttributes & 0x400 != 0
                            || info.nNumberOfLinks != 1
                        {
                            bail!("linked_storage_lock");
                        }
                        return Ok(Lock { _file: file });
                    }
                    Err(error)
                        if matches!(error.raw_os_error(), Some(32 | 33))
                            && Instant::now() < deadline =>
                    {
                        std::thread::sleep(Duration::from_millis(10))
                    }
                    Err(error) => return Err(error.into()),
                }
            }
        }

        pub(crate) fn read(&self, value: &str, limit: u64) -> ResultType<Option<Vec<u8>>> {
            name(value)?;
            #[cfg(unix)]
            let result = self
                .open_file(value, hbb_common::libc::O_RDONLY)
                .and_then(|file| {
                    if file.metadata()?.len() > limit {
                        bail!("storage_file_too_large");
                    }
                    let mut bytes = Vec::new();
                    file.take(limit + 1).read_to_end(&mut bytes)?;
                    if bytes.len() as u64 > limit {
                        bail!("storage_file_too_large");
                    }
                    Ok(bytes)
                });
            #[cfg(windows)]
            let result =
                super::super::identity_file::read_private_file(&self.path.join(value), limit)
                    .map(String::into_bytes);
            match result {
                Ok(bytes) => Ok(Some(bytes)),
                Err(error)
                    if error
                        .downcast_ref::<std::io::Error>()
                        .map_or(false, |e| e.kind() == std::io::ErrorKind::NotFound) =>
                {
                    Ok(None)
                }
                Err(error) => Err(error),
            }
        }

        pub(crate) fn entries(&self) -> ResultType<Vec<String>> {
            let mut entries = Vec::new();
            for entry in fs::read_dir(&self.path)? {
                if entries.len() >= 2048 {
                    bail!("too_many_peer_files");
                }
                let entry = entry?;
                let value = entry
                    .file_name()
                    .into_string()
                    .map_err(|_| anyhow!("invalid_peer_filename"))?;
                entries.push(value);
            }
            entries.sort();
            Ok(entries)
        }

        pub(crate) fn modified(&self, value: &str) -> ResultType<std::time::SystemTime> {
            name(value)?;
            let metadata = fs::symlink_metadata(self.path.join(value))?;
            #[cfg(unix)]
            super::super::identity_file::check_metadata(&metadata, false)?;
            #[cfg(windows)]
            if !metadata.is_file() || metadata.file_attributes() & 0x400 != 0 {
                bail!("linked_storage_file");
            }
            Ok(metadata.modified()?)
        }

        pub(crate) fn exists(&self, value: &str) -> ResultType<bool> {
            Ok(self.read(value, 1024 * 1024)?.is_some())
        }

        pub(crate) fn replace(&self, value: &str, bytes: &[u8]) -> ResultType<()> {
            name(value)?;
            if bytes.len() > 1024 * 1024 {
                bail!("storage_file_too_large");
            }
            self.read(value, 1024 * 1024)?;
            #[cfg(windows)]
            {
                super::super::identity_file::write_private_file(&self.path.join(value), bytes)?;
            }
            #[cfg(unix)]
            {
                let temporary = format!(".nikodesk-store-{}.tmp", hbb_common::uuid::Uuid::new_v4());
                let result = (|| -> ResultType<()> {
                    let mut file = self.open_file(
                        &temporary,
                        hbb_common::libc::O_WRONLY
                            | hbb_common::libc::O_CREAT
                            | hbb_common::libc::O_EXCL,
                    )?;
                    file.write_all(bytes)?;
                    file.sync_all()?;
                    drop(file);
                    let source = CString::new(temporary.as_str())?;
                    let target = CString::new(value)?;
                    if unsafe {
                        hbb_common::libc::renameat(
                            self.file.as_raw_fd(),
                            source.as_ptr(),
                            self.file.as_raw_fd(),
                            target.as_ptr(),
                        )
                    } != 0
                    {
                        return Err(std::io::Error::last_os_error().into());
                    }
                    self.file.sync_all()?;
                    Ok(())
                })();
                if result.is_err() {
                    let _ = fs::remove_file(self.path.join(temporary));
                }
                result?;
            }
            if self.read(value, 1024 * 1024)?.as_deref() != Some(bytes) {
                bail!("storage_readback_failed");
            }
            Ok(())
        }

        pub(crate) fn publish_new(&self, value: &str, bytes: &[u8]) -> ResultType<bool> {
            name(value)?;
            #[cfg(windows)]
            {
                let _ = (value, bytes);
                bail!("atomic_peer_publish_unverified_on_windows");
            }
            #[cfg(unix)]
            {
                let temporary =
                    format!(".nikodesk-import-{}.tmp", hbb_common::uuid::Uuid::new_v4());
                let result = (|| -> ResultType<bool> {
                    let mut file = self.open_file(
                        &temporary,
                        hbb_common::libc::O_WRONLY
                            | hbb_common::libc::O_CREAT
                            | hbb_common::libc::O_EXCL,
                    )?;
                    file.write_all(bytes)?;
                    file.sync_all()?;
                    drop(file);
                    let source = CString::new(temporary.as_str())?;
                    let target = CString::new(value)?;
                    if unsafe {
                        hbb_common::libc::linkat(
                            self.file.as_raw_fd(),
                            source.as_ptr(),
                            self.file.as_raw_fd(),
                            target.as_ptr(),
                            0,
                        )
                    } != 0
                    {
                        let error = std::io::Error::last_os_error();
                        if error.kind() == std::io::ErrorKind::AlreadyExists {
                            return Ok(false);
                        }
                        return Err(error.into());
                    }
                    if unsafe {
                        hbb_common::libc::unlinkat(self.file.as_raw_fd(), source.as_ptr(), 0)
                    } != 0
                    {
                        return Err(std::io::Error::last_os_error().into());
                    }
                    self.file.sync_all()?;
                    Ok(true)
                })();
                let _ = fs::remove_file(self.path.join(temporary));
                result
            }
        }
    }
    #[cfg(windows)]
    fn check_windows_lock(file: &File) -> ResultType<()> {
        use windows::Win32::Storage::FileSystem::{
            GetFileInformationByHandle, BY_HANDLE_FILE_INFORMATION,
        };
        let mut info = BY_HANDLE_FILE_INFORMATION::default();
        unsafe {
            GetFileInformationByHandle(
                windows::Win32::Foundation::HANDLE(file.as_raw_handle()),
                &mut info,
            )?;
        }
        if !file.metadata()?.is_file()
            || info.dwFileAttributes & 0x400 != 0
            || info.nNumberOfLinks != 1
        {
            bail!("linked_storage_lock");
        }
        Ok(())
    }
}
