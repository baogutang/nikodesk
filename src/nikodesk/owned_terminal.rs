//! Ordinary-user, connection-owned PTY using the native terminal core's PTY
//! implementation. No persistent registry, helper token or remote service ID.
use super::{
    connection_capabilities::Gate,
    terminal_cleanup::{self, Resources},
};
use base::message_proto::{
    terminal_action, OpenTerminal, TerminalAction, TerminalClosed, TerminalData, TerminalError,
    TerminalOpened, TerminalResponse,
};
use hbb_common::{anyhow::anyhow, bail, ResultType};
use portable_pty::{CommandBuilder, PtySize};
use std::{
    collections::BTreeMap,
    io::{Read, Write},
    sync::{
        atomic::{AtomicBool, Ordering},
        mpsc::{self, Receiver},
        Arc,
    },
    thread,
    time::Duration,
};

const MAX_TERMINALS: usize = 4;
const MAX_DATA: usize = 64 * 1024;
const QUEUE: usize = 64;
struct Terminal {
    resources: Resources,
    output: Receiver<Vec<u8>>,
    exiting: Arc<AtomicBool>,
    failed: bool,
}
pub(crate) struct OwnedTerminalService {
    service_id: String,
    gate: Arc<Gate>,
    terminals: BTreeMap<i32, Terminal>,
}

impl OwnedTerminalService {
    pub(crate) fn new(gate: Arc<Gate>) -> Self {
        Self {
            service_id: crate::server::terminal_service::generate_service_id(),
            gate,
            terminals: BTreeMap::new(),
        }
    }
    pub(crate) fn active_count(&self) -> usize {
        self.terminals.len()
    }
    pub(crate) fn validate_open(open: &OpenTerminal) -> ResultType<()> {
        if open.terminal_id <= 0
            || open.terminal_id > 1_000_000
            || open.rows == 0
            || open.cols == 0
            || open.rows > 4096
            || open.cols > 4096
        {
            bail!("invalid_terminal_dimensions_or_id");
        }
        Ok(())
    }
    pub(crate) fn action(
        &mut self,
        action: &TerminalAction,
        starting: bool,
    ) -> ResultType<Option<TerminalResponse>> {
        let gate = self.gate.clone();
        if let Some(terminal_action::Union::Close(close)) = action.union.as_ref() {
            gate.execute(false, || Ok(()))?;
            return self.close(close.terminal_id);
        }
        gate.execute(starting, || {
            self.action_with_execution_guard(action, starting)
        })
    }
    // Production holds Gate before the owner mutex. Taking it again here would
    // prevent revoke from reaching the owned child when a PTY writer is blocked.
    pub(crate) fn action_with_execution_guard(
        &mut self,
        action: &TerminalAction,
        starting: bool,
    ) -> ResultType<Option<TerminalResponse>> {
        match action.union.as_ref() {
            Some(terminal_action::Union::Open(open)) => self.open(open),
            Some(terminal_action::Union::Data(data)) if !starting => {
                if data.data.len() > MAX_DATA {
                    bail!("terminal_input_too_large");
                }
                let terminal = self
                    .terminals
                    .get(&data.terminal_id)
                    .ok_or_else(|| anyhow!("terminal_not_owned_by_connection"))?;
                if terminal.failed || terminal.exiting.load(Ordering::SeqCst) {
                    bail!("terminal_closed");
                }
                terminal
                    .resources
                    .input
                    .as_ref()
                    .ok_or_else(|| anyhow!("terminal_input_closed"))?
                    .try_send(data.data.to_vec())
                    .map_err(|_| anyhow!("terminal_input_queue_full_or_closed"))?;
                Ok(None)
            }
            Some(terminal_action::Union::Resize(resize)) if !starting => {
                if resize.rows == 0 || resize.cols == 0 || resize.rows > 4096 || resize.cols > 4096
                {
                    bail!("invalid_terminal_dimensions");
                }
                let terminal = self
                    .terminals
                    .get(&resize.terminal_id)
                    .ok_or_else(|| anyhow!("terminal_not_owned_by_connection"))?;
                if terminal.failed || terminal.exiting.load(Ordering::SeqCst) {
                    bail!("terminal_closed");
                }
                terminal
                    .resources
                    .pair
                    .as_ref()
                    .ok_or_else(|| anyhow!("terminal_closed"))?
                    .master
                    .resize(PtySize {
                        rows: resize.rows as u16,
                        cols: resize.cols as u16,
                        pixel_width: 0,
                        pixel_height: 0,
                    })?;
                Ok(None)
            }
            Some(terminal_action::Union::Close(close)) if !starting => {
                self.close(close.terminal_id)
            }
            _ => Err(anyhow!("terminal_open_required").into()),
        }
    }
    fn open(&mut self, open: &OpenTerminal) -> ResultType<Option<TerminalResponse>> {
        Self::validate_open(open)?;
        if self.terminals.contains_key(&open.terminal_id) || self.terminals.len() >= MAX_TERMINALS {
            bail!("terminal_id_already_owned_or_limit_reached");
        }
        let shell = default_shell();
        let mut command = CommandBuilder::new(&shell);
        #[cfg(target_os = "macos")]
        {
            command.arg("-l");
            command.env("TERM", "xterm-256color");
        }
        #[cfg(target_os = "windows")]
        crate::server::terminal_helper::configure_utf8_shell_command(&shell, &mut command);
        self.open_command(open, command)
    }
    fn open_command(
        &mut self,
        open: &OpenTerminal,
        command: CommandBuilder,
    ) -> ResultType<Option<TerminalResponse>> {
        let pair = portable_pty::native_pty_system().openpty(PtySize {
            rows: open.rows as u16,
            cols: open.cols as u16,
            pixel_width: 0,
            pixel_height: 0,
        })?;
        let (_tx, output) = mpsc::sync_channel(QUEUE);
        self.terminals.insert(
            open.terminal_id,
            Terminal {
                resources: Resources {
                    input: None,
                    pair: Some(pair),
                    child: None,
                    reader: None,
                    writer: None,
                    reader_panicked: false,
                    writer_panicked: false,
                },
                output,
                exiting: Arc::new(AtomicBool::new(false)),
                failed: false,
            },
        );
        let result = (|| -> ResultType<Option<TerminalResponse>> {
            let terminal = self
                .terminals
                .get_mut(&open.terminal_id)
                .ok_or_else(|| anyhow!("terminal_owner_missing"))?;
            let pair = terminal
                .resources
                .pair
                .as_ref()
                .ok_or_else(|| anyhow!("terminal_pair_missing"))?;
            terminal.resources.child = Some(pair.slave.spawn_command(command)?);
            let pid = terminal
                .resources
                .child
                .as_ref()
                .and_then(|c| c.process_id())
                .unwrap_or(0);
            let mut writer = pair.master.take_writer()?;
            let mut reader = pair.master.try_clone_reader()?;
            let (input, receive) = mpsc::sync_channel::<Vec<u8>>(QUEUE);
            let (send, output) = mpsc::sync_channel::<Vec<u8>>(QUEUE);
            terminal.resources.input = Some(input);
            terminal.output = output;
            let gate = self.gate.clone();
            let exiting = terminal.exiting.clone();
            terminal.resources.writer = Some(
                thread::Builder::new()
                    .name("niko-terminal-writer".into())
                    .spawn(move || {
                        while let Ok(data) = receive.recv() {
                            if exiting.load(Ordering::SeqCst) {
                                break;
                            }
                            if gate
                                .execute(false, || {
                                    writer.write_all(&data)?;
                                    writer.flush()?;
                                    Ok(())
                                })
                                .is_err()
                            {
                                break;
                            }
                        }
                        exiting.store(true, Ordering::SeqCst);
                    })?,
            );
            let exiting = terminal.exiting.clone();
            terminal.resources.reader = Some(
                thread::Builder::new()
                    .name("niko-terminal-reader".into())
                    .spawn(move || {
                        let mut buffer = [0; 4096];
                        let mut chunks =
                            crate::server::terminal_service::Utf8ChunkAccumulator::default();
                        loop {
                            match reader.read(&mut buffer) {
                                Ok(0) => {
                                    if let Some(bytes) = chunks.finish() {
                                        let _ = send.try_send(bytes);
                                    }
                                    break;
                                }
                                Ok(count) => {
                                    if exiting.load(Ordering::SeqCst) {
                                        break;
                                    }
                                    if let Some(bytes) = chunks.push_chunk(buffer[..count].to_vec())
                                    {
                                        if send.try_send(bytes).is_err() {
                                            exiting.store(true, Ordering::SeqCst);
                                            break;
                                        }
                                    }
                                }
                                Err(_) => break,
                            }
                        }
                        exiting.store(true, Ordering::SeqCst);
                    })?,
            );
            let mut opened = TerminalOpened::new();
            opened.terminal_id = open.terminal_id;
            opened.success = true;
            opened.pid = pid;
            opened.service_id = self.service_id.clone();
            opened.message = "Terminal opened after local approval".into();
            let mut response = TerminalResponse::new();
            response.set_opened(opened);
            Ok(Some(response))
        })();
        if result.is_err() {
            if let Some(terminal) = self.terminals.get_mut(&open.terminal_id) {
                terminal.failed = true;
                let _ = terminal_cleanup::stop(
                    &mut terminal.resources,
                    &terminal.exiting,
                    Duration::from_millis(300),
                );
            }
        }
        result
    }
    pub(crate) fn outputs(&mut self) -> Vec<TerminalResponse> {
        let mut responses = Vec::new();
        let mut completed = Vec::new();
        for (&id, terminal) in self.terminals.iter_mut() {
            if terminal.failed {
                continue;
            }
            for _ in 0..QUEUE {
                match terminal.output.try_recv() {
                    Ok(bytes) => {
                        let mut data = TerminalData::new();
                        data.terminal_id = id;
                        data.data = bytes.into();
                        let mut response = TerminalResponse::new();
                        response.set_data(data);
                        responses.push(response);
                    }
                    Err(_) => break,
                }
            }
            let exited = terminal
                .resources
                .child
                .as_mut()
                .map_or(false, |child| matches!(child.try_wait(), Ok(Some(_))))
                || terminal.exiting.load(Ordering::SeqCst);
            if exited {
                completed.push(id);
            }
        }
        for id in completed {
            match self.close(id) {
                Ok(Some(response)) => responses.push(response),
                Ok(None) => {}
                Err(_) => responses.push(error(
                    "Terminal cleanup is unconfirmed; the resource remains owned",
                )),
            }
        }
        responses
    }
    fn close(&mut self, id: i32) -> ResultType<Option<TerminalResponse>> {
        let terminal = self
            .terminals
            .get_mut(&id)
            .ok_or_else(|| anyhow!("terminal_not_owned_by_connection"))?;
        terminal.failed = true;
        let exit_code = terminal
            .resources
            .child
            .as_mut()
            .and_then(|child| child.try_wait().ok().flatten())
            .map(|status| status.exit_code() as i32)
            .unwrap_or(-1);
        if !terminal_cleanup::stop(
            &mut terminal.resources,
            &terminal.exiting,
            Duration::from_millis(300),
        )
        .confirmed()
        {
            bail!("terminal_cleanup_unconfirmed");
        }
        self.terminals.remove(&id);
        let mut closed = TerminalClosed::new();
        closed.terminal_id = id;
        closed.exit_code = exit_code;
        let mut response = TerminalResponse::new();
        response.set_closed(closed);
        Ok(Some(response))
    }
    pub(crate) fn stop(&mut self) -> bool {
        let mut confirmed = true;
        for terminal in self.terminals.values_mut() {
            terminal.failed = true;
            confirmed &= terminal_cleanup::stop(
                &mut terminal.resources,
                &terminal.exiting,
                Duration::from_millis(300),
            )
            .confirmed();
        }
        if confirmed {
            self.terminals.clear();
        }
        confirmed
    }
}
fn default_shell() -> String {
    crate::server::terminal_service::get_default_shell()
}
pub(crate) fn error(message: &str) -> TerminalResponse {
    let mut error = TerminalError::new();
    error.message = message.into();
    let mut response = TerminalResponse::new();
    response.set_error(error);
    response
}

static RECOVERY: std::sync::OnceLock<std::sync::Mutex<Vec<OwnedTerminalService>>> =
    std::sync::OnceLock::new();
static RECOVERY_STARTED: std::sync::OnceLock<()> = std::sync::OnceLock::new();
pub(crate) fn retain_unconfirmed(terminal: OwnedTerminalService) {
    let recovery = RECOVERY.get_or_init(|| std::sync::Mutex::new(Vec::new()));
    match recovery.lock() {
        Ok(mut owned) => owned.push(terminal),
        Err(poisoned) => poisoned.into_inner().push(terminal),
    }
    RECOVERY_STARTED.get_or_init(|| {
        if std::thread::Builder::new()
            .name("niko-terminal-recovery".into())
            .spawn(|| loop {
                std::thread::sleep(Duration::from_secs(1));
                if let Some(recovery) = RECOVERY.get() {
                    // Handoff from Connection::drop only moves handles. Never
                    // make it wait behind an OS cleanup under the ledger lock.
                    let mut pending = match recovery.lock() {
                        Ok(mut owned) => std::mem::take(&mut *owned),
                        Err(poisoned) => std::mem::take(&mut *poisoned.into_inner()),
                    };
                    pending.retain_mut(|terminal| !terminal.stop());
                    match recovery.lock() {
                        Ok(mut owned) => owned.extend(pending),
                        Err(poisoned) => poisoned.into_inner().extend(pending),
                    }
                }
            })
            .is_err()
        {
            hbb_common::log::error!(
                "Terminal recovery worker unavailable; unfinished resources remain owned"
            );
        }
    });
}

#[cfg(all(test, unix))]
mod tests {
    use super::super::connection_capabilities::{test_adapter, test_approve};
    use super::*;
    fn open() -> OpenTerminal {
        let mut open = OpenTerminal::new();
        open.terminal_id = 1;
        open.rows = 24;
        open.cols = 80;
        open
    }
    #[test]
    fn unauthenticated_or_pending_requests_never_open_a_native_pty() {
        let adapter = test_adapter();
        let mut service = OwnedTerminalService::new(adapter.gate.clone());
        let mut action = TerminalAction::new();
        action.set_open(open());
        assert!(service.action(&action, true).is_err());
        assert!(service.terminals.is_empty());
    }
    #[test]
    fn input_and_resize_cannot_name_other_connection_terminals() {
        let adapter = test_adapter();
        test_approve(&adapter);
        adapter.started().unwrap();
        let mut service = OwnedTerminalService::new(adapter.gate.clone());
        let mut data = TerminalData::new();
        data.terminal_id = 987;
        data.data = b"foreign\r".to_vec().into();
        let mut action = TerminalAction::new();
        action.set_data(data);
        assert!(service.action(&action, false).is_err());
        assert!(service.terminals.is_empty());
        assert!(service.stop());
    }
    #[test]
    fn dimensions_and_ids_have_fixed_limits() {
        let mut open = open();
        assert!(OwnedTerminalService::validate_open(&open).is_ok());
        for id in [0, -1, 1_000_001] {
            open.terminal_id = id;
            assert!(OwnedTerminalService::validate_open(&open).is_err());
        }
        open.terminal_id = 1;
        open.rows = 4097;
        assert!(OwnedTerminalService::validate_open(&open).is_err());
    }
    #[test]
    fn real_owned_pty_runs_only_after_grant_and_revoke_never_submits_draft() {
        let root = std::env::temp_dir().join(format!("niko-owned-pty-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir(&root).unwrap();
        let adapter = test_adapter();
        test_approve(&adapter);
        let mut service = OwnedTerminalService::new(adapter.gate.clone());
        let mut command = CommandBuilder::new("/bin/sh");
        command.arg("-i");
        command.cwd(&root);
        command.env("HOME", &root);
        command.env_remove("ENV");
        command.env_remove("BASH_ENV");
        let response = service.open_command(&open(), command).unwrap().unwrap();
        assert!(response.has_opened());
        adapter.started().unwrap();
        let mut data = TerminalData::new();
        data.terminal_id = 1;
        data.data = b"printf verified > owned-proof\r".to_vec().into();
        let mut action = TerminalAction::new();
        action.set_data(data);
        service.action(&action, false).unwrap();
        let deadline = std::time::Instant::now() + Duration::from_secs(2);
        while !root.join("owned-proof").exists() && std::time::Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(5));
        }
        assert_eq!(
            std::fs::read_to_string(root.join("owned-proof")).unwrap(),
            "verified"
        );
        let mut data = TerminalData::new();
        data.terminal_id = 1;
        data.data = b"printf forbidden > unsubmitted-draft".to_vec().into();
        let mut action = TerminalAction::new();
        action.set_data(data);
        service.action(&action, false).unwrap();
        // Cancellation does not append a linefeed and invalidates queued input.
        let _ = adapter.gate.revoke();
        assert!(service.action(&action, false).is_err());
        let deadline = std::time::Instant::now() + Duration::from_secs(2);
        let mut confirmed = service.stop();
        while !confirmed && std::time::Instant::now() < deadline {
            confirmed = service.stop();
        }
        assert!(confirmed, "owned PTY shutdown not confirmed");
        assert!(!root.join("unsubmitted-draft").exists());
        std::fs::remove_dir_all(root).unwrap();
    }
}
