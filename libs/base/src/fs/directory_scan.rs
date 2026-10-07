//! Bounded, cancellable directory enumeration for NikoDesk's peer-triggered reads.
use super::*;
use std::{
    collections::HashMap,
    sync::{
        atomic::{AtomicBool, AtomicU64},
        Arc, OnceLock,
    },
    time::Instant,
};
use tokio::sync::{mpsc, Semaphore};

#[path = "directory_query.rs"]
mod query;

pub const TIME_LIMIT: Duration = Duration::from_secs(30);
const MAX_PENDING: usize = 4;
const MAX_ENTRIES: usize = 100_000;
const MAX_NAME_BYTES: usize = 16 * 1024 * 1024;
const MAX_DEPTH: usize = 128;
static NEXT_GENERATION: AtomicU64 = AtomicU64::new(1);

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum Kind {
    Files,
    Directory,
    EmptyDirectories,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReadSpec {
    pub file_num: i32,
    pub overwrite_detection: bool,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Request {
    pub id: i32,
    pub kind: Kind,
    pub generation: u64,
    pub path: String,
    pub include_hidden: bool,
    pub read: Option<ReadSpec>,
}

impl Request {
    pub fn new(id: i32, path: String, include_hidden: bool, read: Option<ReadSpec>) -> Self {
        Self {
            id,
            kind: Kind::Files,
            generation: NEXT_GENERATION.fetch_add(1, Ordering::Relaxed),
            path,
            include_hidden,
            read,
        }
    }
}

#[derive(Debug)]
pub enum Output {
    Files(Vec<FileEntry>),
    Response(Message),
}

pub struct Completion {
    pub request: Request,
    pub result: Result<Output, String>,
}

struct Pending {
    request: Request,
    cancelled: Arc<AtomicBool>,
    started: Instant,
}

/// Owned by exactly one connection/IPC task. Workers can only enqueue results;
/// the owner alone decides whether they still belong to a live request.
pub struct Scans {
    pending: HashMap<(Kind, i32), Pending>,
    tx: mpsc::Sender<Completion>,
    rx: mpsc::Receiver<Completion>,
}

impl Default for Scans {
    fn default() -> Self {
        let (tx, rx) = mpsc::channel(MAX_PENDING);
        Self {
            pending: HashMap::new(),
            tx,
            rx,
        }
    }
}

impl Scans {
    pub fn requests(&self) -> impl Iterator<Item = &Request> {
        self.pending.values().map(|pending| &pending.request)
    }

    pub fn is_pending(&self) -> bool {
        !self.pending.is_empty()
    }

    pub fn track(&mut self, request: Request) -> Result<(), String> {
        if request.kind != Kind::Files {
            self.cancel_key(request.kind, request.id);
        }
        if self.pending.contains_key(&(request.kind, request.id)) {
            return Err("A directory request with this id is still running".into());
        }
        if self.pending.len() >= MAX_PENDING {
            return Err("Too many directory scans; retry after another scan completes".into());
        }
        self.pending.insert(
            (request.kind, request.id),
            Pending {
                request,
                cancelled: Arc::new(AtomicBool::new(false)),
                started: Instant::now(),
            },
        );
        Ok(())
    }

    pub fn start(&mut self, request: Request, max_files: usize) -> Result<(), String> {
        self.start_with(request, move |request, cancelled, started| {
            match request.kind {
                Kind::Files => scan(
                    &request.path,
                    request.include_hidden,
                    max_files,
                    cancelled,
                    started,
                    Limits::default(),
                )
                .map(Output::Files),
                _ => query::scan_query(request, cancelled, started).map(Output::Response),
            }
            .map_err(|e| e.to_string())
        })
    }

    fn start_with<F>(&mut self, request: Request, work: F) -> Result<(), String>
    where
        F: FnOnce(&Request, &AtomicBool, Instant) -> Result<Output, String> + Send + 'static,
    {
        // The permit stays in the blocking worker even after cancellation: a stuck
        // filesystem syscall must not allow unbounded replacement worker threads.
        static WORKERS: OnceLock<Arc<Semaphore>> = OnceLock::new();
        // Retire obsolete browser queries even if all workers are currently busy.
        if request.kind != Kind::Files {
            self.cancel_key(request.kind, request.id);
        }
        let permit = WORKERS
            .get_or_init(|| Arc::new(Semaphore::new(MAX_PENDING)))
            .clone()
            .try_acquire_owned()
            .map_err(|_| "Directory scanner is busy; retry later".to_owned())?;
        self.track(request.clone())?;
        let pending = &self.pending[&(request.kind, request.id)];
        let cancelled = pending.cancelled.clone();
        let started = pending.started;
        let tx = self.tx.clone();
        tokio::task::spawn_blocking(move || {
            let _permit = permit;
            let result = work(&request, &cancelled, started);
            if !cancelled.load(Ordering::Acquire) {
                // Cancelled/replaced results may still fill the queue. Never block
                // a worker on it; a dropped live result fails at the owner deadline.
                let _ = tx.try_send(Completion { request, result });
            }
        });
        Ok(())
    }

    fn cancel_key(&mut self, kind: Kind, id: i32) {
        if let Some(pending) = self.pending.remove(&(kind, id)) {
            pending.cancelled.store(true, Ordering::Release);
        }
    }

    pub fn cancel(&mut self, id: i32) {
        self.cancel_key(Kind::Files, id);
    }

    pub fn cancel_matching(&mut self, request: &Request) {
        if self
            .pending
            .get(&(request.kind, request.id))
            .map_or(false, |p| p.request == *request)
        {
            self.cancel_key(request.kind, request.id);
        }
    }

    pub fn cancel_all(&mut self) {
        for (_, pending) in self.pending.drain() {
            pending.cancelled.store(true, Ordering::Release);
        }
        while self.rx.try_recv().is_ok() {}
    }

    /// Also used for CM replies. The generation and complete request must match;
    /// cancellation, timeout and id reuse cannot revive an older result.
    pub fn finish(&mut self, request: &Request) -> bool {
        let matches = self
            .pending
            .get(&(request.kind, request.id))
            .map_or(false, |p| {
                p.request == *request && p.started.elapsed() < TIME_LIMIT
            });
        if matches {
            self.cancel_key(request.kind, request.id);
        }
        matches
    }

    pub fn take_ready(&mut self) -> Option<Completion> {
        let expired = self
            .pending
            .values()
            .find(|p| p.started.elapsed() >= TIME_LIMIT)
            .map(|p| p.request.clone());
        if let Some(request) = expired {
            self.cancel_key(request.kind, request.id);
            return Some(Completion {
                request,
                result: Err("Directory scan timed out; no partial list was returned".into()),
            });
        }
        while let Ok(completion) = self.rx.try_recv() {
            if self.finish(&completion.request) {
                return Some(completion);
            }
        }
        None
    }
}

impl Drop for Scans {
    fn drop(&mut self) {
        self.cancel_all();
    }
}

#[derive(Clone, Copy)]
struct Limits {
    entries: usize,
    names: usize,
    depth: usize,
    time: Duration,
}
impl Default for Limits {
    fn default() -> Self {
        Self {
            entries: MAX_ENTRIES,
            names: MAX_NAME_BYTES,
            depth: MAX_DEPTH,
            time: TIME_LIMIT,
        }
    }
}

struct Budget<'a> {
    cancelled: &'a AtomicBool,
    started: Instant,
    limits: Limits,
    entries: usize,
    names: usize,
    max_files: usize,
}
impl Budget<'_> {
    fn check(&self) -> ResultType<()> {
        if self.cancelled.load(Ordering::Acquire) {
            bail!("Directory scan cancelled");
        }
        if self.started.elapsed() >= self.limits.time {
            bail!("Directory scan timed out; no partial list was returned");
        }
        Ok(())
    }
    fn entry(&mut self) -> ResultType<()> {
        self.check()?;
        self.entries += 1;
        if self.entries > self.limits.entries {
            bail!("Directory scan entry limit exceeded; choose a smaller directory");
        }
        Ok(())
    }
    fn push(
        &mut self,
        files: &mut Vec<FileEntry>,
        name: String,
        meta: std::fs::Metadata,
        hidden: bool,
    ) -> ResultType<()> {
        self.check()?;
        if files.len() >= self.max_files {
            bail!("File count limit exceeded; choose a smaller directory");
        }
        self.names = self.names.saturating_add(name.len());
        if self.names > self.limits.names {
            bail!("Directory scan name-size limit exceeded; choose a smaller directory");
        }
        let modified_time = meta
            .modified()?
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        files.push(FileEntry {
            name,
            entry_type: FileType::File.into(),
            is_hidden: hidden,
            size: meta.len(),
            modified_time,
            ..Default::default()
        });
        Ok(())
    }
}

fn scan(
    path: &str,
    include_hidden: bool,
    max_files: usize,
    cancelled: &AtomicBool,
    started: Instant,
    limits: Limits,
) -> ResultType<Vec<FileEntry>> {
    let root = Path::new(path);
    let mut budget = Budget {
        cancelled,
        started,
        limits,
        entries: 0,
        names: 0,
        max_files,
    };
    budget.check()?;
    let meta = std::fs::symlink_metadata(root)?;
    budget.check()?;
    if meta.file_type().is_symlink() {
        bail!("Symbolic-link scan roots are not supported");
    }
    let mut files = Vec::new();
    if meta.is_file() {
        budget.push(&mut files, String::new(), meta, false)?;
    } else if meta.is_dir() {
        // Iterative DFS bounds both stack depth and open directory handles.
        let mut stack = vec![(root.read_dir()?, PathBuf::new(), 0usize)];
        while let Some((entries, prefix, depth)) = stack.last_mut() {
            budget.check()?;
            let entry = match entries.next() {
                Some(entry) => entry?,
                None => {
                    stack.pop();
                    continue;
                }
            };
            budget.entry()?;
            let name = entry
                .file_name()
                .into_string()
                .map_err(|_| anyhow!("Directory contains a non-UTF-8 file name"))?;
            let meta = std::fs::symlink_metadata(entry.path())?;
            budget.check()?;
            #[cfg(windows)]
            let hidden = meta.file_attributes() & 0x2 != 0;
            #[cfg(not(windows))]
            let hidden = name.starts_with('.');
            if hidden && !include_hidden {
                continue;
            }
            let relative = prefix.join(&name);
            let name = relative
                .to_str()
                .ok_or_else(|| anyhow!("Invalid file name"))?
                .to_owned();
            if meta.is_file() {
                budget.push(&mut files, name, meta, hidden)?;
            } else if meta.is_dir() && !meta.file_type().is_symlink() {
                let next_depth = *depth + 1;
                if next_depth > limits.depth {
                    bail!("Directory scan depth limit exceeded; choose a shallower directory");
                }
                let next = entry.path().read_dir()?;
                budget.check()?;
                stack.push((next, relative, next_depth));
            }
            // Match the transfer protocol's existing policy: do not follow links.
        }
    } else {
        bail!("Not a regular file or directory");
    }
    budget.check()?;
    Ok(files)
}

pub fn error(request: &Request, error: impl std::fmt::Display) -> Message {
    if request.kind == Kind::EmptyDirectories {
        // The existing client uses this marker to abort its independent directory-creation phase.
        new_error(-1, "NIKODESK_EMPTY_DIRECTORY_READ_FAILED", -1)
    } else {
        new_error(request.id, error, -1)
    }
}

/// Construct a read job from the already scanned list, without a second filesystem walk.
pub fn read_job(request: &Request, files: Vec<FileEntry>) -> ResultType<TransferJob> {
    let read = request
        .read
        .as_ref()
        .ok_or_else(|| anyhow!("Not a file-read request"))?;
    validate_transfer_file_names(&files)?;
    let total_size = files.iter().try_fold(0u64, |sum, f| {
        sum.checked_add(f.size)
            .ok_or_else(|| anyhow!("Transfer size overflow"))
    })?;
    Ok(TransferJob {
        id: request.id,
        r#type: JobType::Generic,
        remote: String::new(),
        data_source: DataSource::FilePath(PathBuf::from(&request.path)),
        file_num: read.file_num,
        show_hidden: request.include_hidden,
        is_remote: true,
        files,
        total_size,
        enable_overwrite_detection: read.overwrite_detection,
        ..Default::default()
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    pub(super) struct Fixture(pub(super) PathBuf);
    impl Fixture {
        pub(super) fn new() -> Self {
            let root = std::env::temp_dir().join(format!(
                "nikodesk-directory-{}-{}",
                std::process::id(),
                NEXT_GENERATION.fetch_add(1, Ordering::Relaxed)
            ));
            std::fs::create_dir(&root).unwrap();
            Self(root)
        }
        pub(super) fn file(&self, name: &str) {
            let path = self.0.join(name);
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();
            std::fs::write(path, b"fixture").unwrap();
        }
        fn scan(&self, hidden: bool, max: usize, limits: Limits) -> ResultType<Vec<FileEntry>> {
            scan(
                self.0.to_str().unwrap(),
                hidden,
                max,
                &AtomicBool::new(false),
                Instant::now(),
                limits,
            )
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn complete_listing_and_single_file_preserve_transfer_shape() {
        let fixture = Fixture::new();
        fixture.file("one.txt");
        fixture.file("child/two.txt");
        fixture.file(".hidden/file.txt");
        let mut names = fixture
            .scan(false, 2, Limits::default())
            .unwrap()
            .into_iter()
            .map(|f| f.name)
            .collect::<Vec<_>>();
        names.sort();
        assert_eq!(names, ["child/two.txt", "one.txt"]);
        assert_eq!(fixture.scan(true, 3, Limits::default()).unwrap().len(), 3);
        let files = scan(
            fixture.0.join("one.txt").to_str().unwrap(),
            false,
            1,
            &AtomicBool::new(false),
            Instant::now(),
            Limits::default(),
        )
        .unwrap();
        assert_eq!(files[0].name, "");
        assert_eq!(files[0].size, 7);
    }

    #[test]
    fn exceeding_file_count_fails_instead_of_returning_partial_success() {
        let fixture = Fixture::new();
        for i in 0..64 {
            fixture.file(&format!("{i}.txt"));
        }
        assert!(fixture
            .scan(true, 63, Limits::default())
            .unwrap_err()
            .to_string()
            .contains("File count limit"));
        assert_eq!(fixture.scan(true, 64, Limits::default()).unwrap().len(), 64);
    }

    #[test]
    fn empty_directories_and_hidden_entries_also_consume_work_budget() {
        let fixture = Fixture::new();
        for i in 0..20 {
            std::fs::create_dir(fixture.0.join(format!(".hidden-{i}"))).unwrap();
        }
        assert!(fixture
            .scan(
                false,
                usize::MAX,
                Limits {
                    entries: 10,
                    ..Limits::default()
                }
            )
            .unwrap_err()
            .to_string()
            .contains("entry limit"));
    }

    #[test]
    fn depth_and_name_memory_have_independent_limits() {
        let fixture = Fixture::new();
        fixture.file("a/b/c/d.txt");
        assert!(fixture
            .scan(
                true,
                10,
                Limits {
                    depth: 2,
                    ..Limits::default()
                }
            )
            .unwrap_err()
            .to_string()
            .contains("depth limit"));
        assert!(fixture
            .scan(
                true,
                10,
                Limits {
                    names: 3,
                    ..Limits::default()
                }
            )
            .unwrap_err()
            .to_string()
            .contains("name-size limit"));
    }

    #[test]
    fn cancellation_and_expired_deadlines_prevent_even_initial_io() {
        let missing = "/not-a-nikodesk-fixture";
        assert!(scan(
            missing,
            true,
            10,
            &AtomicBool::new(true),
            Instant::now(),
            Limits::default()
        )
        .unwrap_err()
        .to_string()
        .contains("cancelled"));
        assert!(scan(
            missing,
            true,
            10,
            &AtomicBool::new(false),
            Instant::now() - TIME_LIMIT,
            Limits::default()
        )
        .unwrap_err()
        .to_string()
        .contains("timed out"));
    }

    #[test]
    fn cancellation_is_checked_during_enumeration_budget() {
        let cancel = AtomicBool::new(false);
        let mut budget = Budget {
            cancelled: &cancel,
            started: Instant::now(),
            limits: Limits::default(),
            entries: 0,
            names: 0,
            max_files: 100,
        };
        budget.entry().unwrap();
        cancel.store(true, Ordering::Release);
        assert!(budget
            .entry()
            .unwrap_err()
            .to_string()
            .contains("cancelled"));
    }

    #[cfg(unix)]
    #[test]
    fn unreadable_child_aborts_the_entire_listing() {
        use std::os::unix::fs::PermissionsExt;
        let fixture = Fixture::new();
        fixture.file("one.txt");
        fixture.file("blocked/two.txt");
        let dir = fixture.0.join("blocked");
        std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0)).unwrap();
        let result = fixture.scan(true, 10, Limits::default());
        std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700)).unwrap();
        assert!(
            result.is_err(),
            "test requires an unprivileged user; never accept partial listing"
        );
    }

    #[cfg(unix)]
    #[test]
    fn symlink_children_are_not_followed_and_symlink_roots_fail() {
        let fixture = Fixture::new();
        fixture.file("child/a.txt");
        std::os::unix::fs::symlink(&fixture.0, fixture.0.join("child/loop")).unwrap();
        assert_eq!(fixture.scan(true, 10, Limits::default()).unwrap().len(), 1);
        assert!(scan(
            fixture.0.join("child/loop").to_str().unwrap(),
            true,
            10,
            &AtomicBool::new(false),
            Instant::now(),
            Limits::default()
        )
        .is_err());
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn unrepresentable_name_aborts_instead_of_omitting_a_file() {
        use std::os::unix::ffi::OsStringExt;
        let fixture = Fixture::new();
        fixture.file("one.txt");
        std::fs::write(
            fixture.0.join(std::ffi::OsString::from_vec(vec![0xff])),
            b"fixture",
        )
        .unwrap();
        assert!(fixture
            .scan(true, 10, Limits::default())
            .unwrap_err()
            .to_string()
            .contains("UTF-8"));
    }

    fn request(id: i32) -> Request {
        Request::new(id, "fixture".into(), true, None)
    }

    #[test]
    fn cancellation_and_reused_id_reject_already_queued_old_result() {
        let mut scans = Scans::default();
        let old = request(1);
        scans.track(old.clone()).unwrap();
        let old_token = scans.pending[&(Kind::Files, 1)].cancelled.clone();
        scans
            .tx
            .try_send(Completion {
                request: old.clone(),
                result: Ok(Output::Files(Vec::new())),
            })
            .unwrap();
        scans.cancel(1);
        assert!(old_token.load(Ordering::Acquire));
        let new = request(1);
        scans.track(new.clone()).unwrap();
        assert!(!scans.finish(&old));
        assert!(scans.take_ready().is_none());
        assert!(scans.finish(&new));
        assert!(!scans.finish(&new));
    }

    #[test]
    fn completed_cancelled_or_replaced_requests_cannot_grow_result_queue() {
        for kind in [Kind::Files, Kind::Directory, Kind::EmptyDirectories] {
            let mut scans = Scans::default();
            let mut accepted = 0;
            // Deliberately do not poll: completion followed by cancellation or
            // browser replacement must not accumulate results indefinitely.
            for _ in 0..MAX_PENDING * 16 {
                let mut req = request(0);
                req.kind = kind;
                scans.track(req.clone()).unwrap();
                match scans.tx.try_send(Completion {
                    request: req,
                    result: Ok(Output::Files(Vec::new())),
                }) {
                    Ok(()) => accepted += 1,
                    Err(mpsc::error::TrySendError::Full(_)) => {}
                    Err(mpsc::error::TrySendError::Closed(_)) => panic!("owner is alive"),
                }
                if kind == Kind::Files {
                    scans.cancel(0);
                }
            }
            assert_eq!(accepted, MAX_PENDING);
            assert_eq!(scans.tx.capacity(), 0);
            let mut current = request(0);
            current.kind = kind;
            scans.track(current.clone()).unwrap();
            // All queued generations are obsolete, even for the reused id.
            assert!(scans.take_ready().is_none());
            assert_eq!(scans.tx.capacity(), MAX_PENDING);
            assert!(scans.finish(&current));
        }
    }

    #[test]
    fn saturated_result_queue_expires_live_request_without_partial_success() {
        let mut scans = Scans::default();
        for _ in 0..MAX_PENDING {
            let req = request(1);
            scans.track(req.clone()).unwrap();
            scans
                .tx
                .try_send(Completion {
                    request: req,
                    result: Ok(Output::Files(Vec::new())),
                })
                .unwrap();
            scans.cancel(1);
        }
        let current = request(1);
        scans.track(current.clone()).unwrap();
        assert!(matches!(
            scans.tx.try_send(Completion {
                request: current.clone(),
                result: Ok(Output::Files(Vec::new())),
            }),
            Err(mpsc::error::TrySendError::Full(_))
        ));
        assert!(scans.is_pending());
        scans.pending.get_mut(&(Kind::Files, 1)).unwrap().started -= TIME_LIMIT;
        let expired = scans.take_ready().unwrap();
        assert_eq!(expired.request, current);
        assert!(expired
            .result
            .unwrap_err()
            .contains("timed out; no partial list"));
        assert!(!scans.finish(&current));
        assert!(!scans.is_pending());
        assert!(scans.take_ready().is_none());
        assert_eq!(scans.tx.capacity(), MAX_PENDING);
    }

    #[test]
    fn revocation_and_owner_drop_cancel_workers_and_queued_results() {
        let mut scans = Scans::default();
        let req = request(1);
        scans.track(req.clone()).unwrap();
        let token = scans.pending[&(Kind::Files, 1)].cancelled.clone();
        scans
            .tx
            .try_send(Completion {
                request: req,
                result: Ok(Output::Files(Vec::new())),
            })
            .unwrap();
        scans.cancel_all();
        assert!(token.load(Ordering::Acquire));
        assert!(scans.take_ready().is_none());
        scans.track(request(2)).unwrap();
        let token = scans.pending[&(Kind::Files, 2)].cancelled.clone();
        drop(scans);
        assert!(token.load(Ordering::Acquire));
    }

    #[test]
    fn external_timeout_is_explicit_and_rejects_late_completion() {
        let mut scans = Scans::default();
        let req = request(1);
        scans.track(req.clone()).unwrap();
        scans.pending.get_mut(&(Kind::Files, 1)).unwrap().started -= TIME_LIMIT;
        assert!(!scans.finish(&req));
        let result = scans.take_ready().unwrap().result.unwrap_err();
        assert!(result.contains("timed out"));
        assert!(!scans.finish(&req));
        assert!(!scans.is_pending());
    }

    #[test]
    fn request_owner_checks_path_generation_and_pending_bound() {
        let mut scans = Scans::default();
        let req = request(1);
        scans.track(req.clone()).unwrap();
        let mut forged = req.clone();
        forged.path = "other".into();
        assert!(!scans.finish(&forged));
        assert!(scans.track(request(1)).is_err());
        for i in 2..=MAX_PENDING as i32 {
            scans.track(request(i)).unwrap();
        }
        assert!(scans.track(request(100)).is_err());
        let mut another_connection = Scans::default();
        another_connection.track(request(1)).unwrap();
        assert!(!another_connection.finish(&req));
    }

    #[tokio::test]
    async fn worker_enumerates_without_blocking_owner_and_constructs_transfer_job() {
        let fixture = Fixture::new();
        fixture.file("a.txt");
        fixture.file("child/b.txt");
        let mut scans = Scans::default();
        let request = Request::new(
            3,
            fixture.0.to_str().unwrap().into(),
            true,
            Some(ReadSpec {
                file_num: 0,
                overwrite_detection: false,
            }),
        );
        scans.start(request.clone(), 10).unwrap();
        let completion = tokio::time::timeout(Duration::from_secs(5), scans.rx.recv())
            .await
            .unwrap()
            .unwrap();
        assert!(scans.finish(&completion.request));
        let job = read_job(
            &request,
            match completion.result.unwrap() {
                Output::Files(files) => files,
                _ => panic!("expected file list"),
            },
        )
        .unwrap();
        assert_eq!(job.files().len(), 2);
        assert_eq!(job.total_size(), 14);
        assert_eq!(job.id(), 3);
    }
    #[test]
    fn replacing_a_browser_query_retires_only_its_own_kind() {
        let mut scans = Scans::default();
        let mut old = request(0);
        old.kind = Kind::Directory;
        scans.track(old.clone()).unwrap();
        let token = scans.pending[&(Kind::Directory, 0)].cancelled.clone();
        let file_request = request(0);
        scans.track(file_request.clone()).unwrap();
        let mut next = request(0);
        next.kind = Kind::Directory;
        scans.track(next.clone()).unwrap();
        assert!(token.load(Ordering::Acquire));
        scans.cancel_matching(&old);
        assert!(!scans.finish(&old));
        assert!(scans.finish(&next));
        assert!(scans.finish(&file_request));
    }

    #[tokio::test]
    async fn blocked_worker_does_not_block_owner_cancellation_or_replacement() {
        let mut scans = Scans::default();
        let mut old = request(0);
        old.kind = Kind::Directory;
        let (entered_tx, entered_rx) = tokio::sync::oneshot::channel();
        let (release_tx, release_rx) = std::sync::mpsc::channel();
        let (done_tx, done_rx) = tokio::sync::oneshot::channel();
        scans
            .start_with(old.clone(), move |_, cancelled, _| {
                let _ = entered_tx.send(());
                // Models one uninterruptible filesystem call without touching a slow mount.
                release_rx.recv_timeout(Duration::from_secs(5)).unwrap();
                let _ = done_tx.send(cancelled.load(Ordering::Acquire));
                Ok(Output::Files(Vec::new()))
            })
            .unwrap();
        tokio::time::timeout(Duration::from_secs(1), entered_rx)
            .await
            .unwrap()
            .unwrap();
        let mut replacement = request(0);
        replacement.kind = Kind::Directory;
        tokio::time::timeout(Duration::from_millis(100), async {
            tokio::task::yield_now().await;
            scans.track(replacement.clone()).unwrap();
            assert!(!scans.finish(&old));
        })
        .await
        .unwrap();
        release_tx.send(()).unwrap();
        assert!(tokio::time::timeout(Duration::from_secs(1), done_rx)
            .await
            .unwrap()
            .unwrap());
        assert!(scans.take_ready().is_none());
        assert!(scans.finish(&replacement));
    }
}
