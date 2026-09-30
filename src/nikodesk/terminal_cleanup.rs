//! Owned terminal teardown. Closing a terminal must never submit its draft.
//! This does not authorize/open a terminal or claim cleanup of daemonized jobs.
use portable_pty::{Child, PtyPair};
use std::{
    sync::{
        atomic::{AtomicBool, Ordering},
        mpsc::SyncSender,
    },
    thread::{self, JoinHandle},
    time::{Duration, Instant},
};

pub(crate) struct Resources {
    pub(crate) input: Option<SyncSender<Vec<u8>>>,
    pub(crate) pair: Option<PtyPair>,
    pub(crate) child: Option<Box<dyn Child + Send + Sync>>,
    pub(crate) reader: Option<JoinHandle<()>>,
    pub(crate) writer: Option<JoinHandle<()>>,
    pub(crate) reader_panicked: bool,
    pub(crate) writer_panicked: bool,
}

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct Report {
    pub(crate) child_exited: bool,
    pub(crate) reader_joined: bool,
    pub(crate) writer_joined: bool,
}

impl Report {
    pub(crate) fn confirmed(&self) -> bool {
        self.child_exited && self.reader_joined && self.writer_joined
    }
}

/// Invalidate input first, kill only the owned Child, close the PTY, then join
/// finished I/O threads. Retain unfinished ownership for a subsequent retry.
/// The budget bounds polling/join; an OS PTY close itself can still block.
pub(crate) fn stop(resources: &mut Resources, exiting: &AtomicBool, budget: Duration) -> Report {
    exiting.store(true, Ordering::SeqCst);
    // No send, including an empty/CRLF message. SyncSender::send could also
    // block on a full input queue while the writer is stuck in OS I/O.
    resources.input.take();
    let deadline = Instant::now()
        .checked_add(budget)
        .unwrap_or_else(Instant::now);
    if let Some(child) = resources.child.as_mut() {
        if matches!(child.try_wait(), Ok(None)) {
            let _ = child.kill();
        }
    }
    // Kill before closing/joining, so a reader waiting for shell output can
    // receive EOF. Drop the slave on macOS as well as Windows/Linux.
    resources.pair.take();
    let mut child_exited = resources.child.is_none();
    loop {
        if !child_exited {
            if let Some(child) = resources.child.as_mut() {
                match child.try_wait() {
                    Ok(Some(_)) => {
                        child_exited = true;
                        resources.child.take();
                    }
                    Ok(None) => {}
                    Err(_) => break,
                }
            }
        }
        let reader_done = resources
            .reader
            .as_ref()
            .map_or(true, JoinHandle::is_finished);
        let writer_done = resources
            .writer
            .as_ref()
            .map_or(true, JoinHandle::is_finished);
        if (child_exited && reader_done && writer_done) || Instant::now() >= deadline {
            break;
        }
        thread::sleep(Duration::from_millis(1));
    }
    let reader_joined = join_finished(&mut resources.reader, &mut resources.reader_panicked);
    let writer_joined = join_finished(&mut resources.writer, &mut resources.writer_panicked);
    Report {
        child_exited,
        reader_joined,
        writer_joined,
    }
}

fn join_finished(handle: &mut Option<JoinHandle<()>>, panicked: &mut bool) -> bool {
    if handle.as_ref().map_or(true, JoinHandle::is_finished) {
        // A panicked worker is terminated but cannot be called confirmed.
        if let Some(handle) = handle.take() {
            if handle.join().is_err() {
                *panicked = true;
            }
        }
        !*panicked
    } else {
        false
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        io::{Read, Write},
        sync::{mpsc, Arc},
    };

    fn empty() -> Resources {
        Resources {
            input: None,
            pair: None,
            child: None,
            reader: None,
            writer: None,
            reader_panicked: false,
            writer_panicked: false,
        }
    }

    #[test]
    fn close_drops_a_full_queue_without_submitting_or_blocking() {
        let (tx, rx) = mpsc::sync_channel(1);
        tx.send(b"unsubmitted draft".to_vec()).unwrap();
        let mut resources = empty();
        resources.input = Some(tx);
        let exiting = AtomicBool::new(false);
        assert!(stop(&mut resources, &exiting, Duration::ZERO).confirmed());
        assert!(exiting.load(Ordering::SeqCst));
        assert_eq!(rx.recv().unwrap(), b"unsubmitted draft");
        assert_eq!(rx.recv(), Err(mpsc::RecvError));
    }

    #[test]
    fn unfinished_io_is_unconfirmed_retained_and_retryable() {
        let (release, receive) = mpsc::channel();
        let mut resources = empty();
        resources.reader = Some(thread::spawn(move || {
            let _ = receive.recv();
        }));
        let exiting = AtomicBool::new(false);
        let report = stop(&mut resources, &exiting, Duration::from_millis(3));
        assert!(!report.confirmed());
        assert!(resources.reader.is_some());
        release.send(()).unwrap();
        assert!(stop(&mut resources, &exiting, Duration::from_secs(1)).confirmed());
        assert!(stop(&mut resources, &exiting, Duration::ZERO).confirmed());
    }

    #[test]
    fn thread_panic_cannot_report_confirmed_cleanup() {
        let mut resources = empty();
        resources.writer = Some(thread::spawn(|| panic!("isolated teardown fixture")));
        while !resources.writer.as_ref().unwrap().is_finished() {
            thread::yield_now();
        }
        let report = stop(&mut resources, &AtomicBool::new(false), Duration::ZERO);
        assert!(!report.confirmed());
        // Consuming JoinHandle must not erase the evidence on another stop.
        assert!(!stop(&mut resources, &AtomicBool::new(false), Duration::ZERO).confirmed());
    }

    #[cfg(unix)]
    #[test]
    fn real_owned_pty_close_never_executes_a_draft_command() {
        use portable_pty::{CommandBuilder, PtySize};
        let root = std::env::temp_dir().join(format!(
            "nikodesk-pty-close-{}-{}",
            std::process::id(),
            uuid::Uuid::new_v4()
        ));
        std::fs::create_dir(&root).unwrap();
        let marker = root.join("draft-must-not-run");
        let pair = portable_pty::native_pty_system()
            .openpty(PtySize::default())
            .unwrap();
        let mut command = CommandBuilder::new("/bin/sh");
        command.arg("-i");
        command.cwd(&root);
        command.env_remove("ENV");
        command.env_remove("BASH_ENV");
        let child = pair.slave.spawn_command(command).unwrap();
        let mut reader = pair.master.try_clone_reader().unwrap();
        let mut writer = pair.master.take_writer().unwrap();
        let exiting = Arc::new(AtomicBool::new(false));
        let (input, receive) = mpsc::sync_channel::<Vec<u8>>(1);
        let (written, ack) = mpsc::channel();
        let writer_exiting = exiting.clone();
        let writer_thread = thread::spawn(move || {
            while let Ok(data) = receive.recv() {
                if writer_exiting.load(Ordering::SeqCst) {
                    break;
                }
                writer.write_all(&data).unwrap();
                writer.flush().unwrap();
                let _ = written.send(());
            }
        });
        let reader_thread = thread::spawn(move || {
            let mut data = [0u8; 1024];
            loop {
                if !matches!(reader.read(&mut data), Ok(n) if n > 0) {
                    break;
                }
            }
        });
        input
            .send(b"printf should-not-run > draft-must-not-run".to_vec())
            .unwrap();
        ack.recv_timeout(Duration::from_secs(2)).unwrap();
        assert!(!marker.exists());
        let mut resources = Resources {
            input: Some(input),
            pair: Some(pair),
            child: Some(child),
            reader: Some(reader_thread),
            writer: Some(writer_thread),
            reader_panicked: false,
            writer_panicked: false,
        };
        let report = stop(&mut resources, &exiting, Duration::from_secs(2));
        assert!(report.confirmed(), "owned PTY cleanup: {report:?}");
        assert!(!marker.exists(), "closing the PTY submitted its draft");
        std::fs::remove_dir_all(&root).unwrap();
    }
}
