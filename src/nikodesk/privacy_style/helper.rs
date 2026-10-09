//! Private child-process renderer with a bounded lease. No ordinary app/core
//! initialization, profile, key, service or network is available to the child.
use super::{
    native::{self, Wallpaper},
    MAX_FRAME_BYTES,
};
use base::message_proto::NikoPrivacyStyle;
use hbb_common::{anyhow::anyhow, bail, protobuf::Message, ResultType};
use std::{
    io::{Read, Write},
    process::{Child, Command, Stdio},
    sync::{
        atomic::{AtomicBool, Ordering},
        mpsc::{self, SyncSender},
        Arc, Mutex,
    },
    time::{Duration, Instant},
};

const ARG: &str = "--niko-styled-privacy";
pub(super) const LEASE: Duration = Duration::from_secs(5);
const WAIT: Duration = Duration::from_secs(4);
enum Operation {
    Heartbeat,
    Show,
    Style(Vec<u8>),
}
struct CommandFrame {
    issued: Instant,
    operation: Operation,
    reply: Option<SyncSender<bool>>,
}
pub(super) struct Screen {
    pub conn_id: i32,
    child: Child,
    sender: SyncSender<CommandFrame>,
    alive: Arc<AtomicBool>,
    last_ack: Arc<Mutex<Instant>>,
}

fn write_style(output: &mut impl Write, bytes: &[u8]) -> std::io::Result<()> {
    if bytes.is_empty() || bytes.len() > MAX_FRAME_BYTES {
        return Err(std::io::ErrorKind::InvalidData.into());
    }
    output.write_all(&(bytes.len() as u32).to_le_bytes())?;
    output.write_all(bytes)?;
    output.flush()
}

impl Screen {
    pub fn start(conn_id: i32, style: &NikoPrivacyStyle) -> ResultType<Self> {
        if !native::supported() {
            bail!("style_unsupported");
        }
        let bytes = style.write_to_bytes()?;
        let mut child = Command::new(std::env::current_exe()?)
            .arg(ARG)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()?;
        let Some(mut input) = child.stdin.take() else {
            let _ = child.kill();
            bail!("helper_pipe_unavailable");
        };
        let Some(mut output) = child.stdout.take() else {
            let _ = child.kill();
            bail!("helper_pipe_unavailable");
        };
        #[cfg(target_os = "macos")]
        scrap::privacy_capture::reserve(child.id());
        let (sender, receiver) = mpsc::sync_channel::<CommandFrame>(1);
        let (ready, waiting) = mpsc::sync_channel(1);
        let alive = Arc::new(AtomicBool::new(false));
        let last_ack = Arc::new(Mutex::new(Instant::now()));
        let live = alive.clone();
        let ack = last_ack.clone();
        std::thread::spawn(move || {
            let mut byte = [0; 1];
            let initialized = input
                .write_all(b"NPS2")
                .and_then(|_| write_style(&mut input, &bytes))
                .and_then(|_| output.read_exact(&mut byte))
                .is_ok()
                && byte == *b"R";
            live.store(initialized, Ordering::Release);
            let _ = ready.try_send(initialized);
            if !initialized {
                return;
            }
            while let Ok(frame) = receiver.recv() {
                let valid = frame.issued.elapsed() < Duration::from_secs(2);
                let written = if !valid {
                    false
                } else {
                    match frame.operation {
                        Operation::Heartbeat => input.write_all(b"H"),
                        Operation::Show => input.write_all(b"V"),
                        Operation::Style(bytes) => input
                            .write_all(b"C")
                            .and_then(|_| write_style(&mut input, &bytes)),
                    }
                    .and_then(|_| input.flush())
                    .and_then(|_| output.read_exact(&mut byte))
                    .is_ok()
                        && byte == *b"A"
                };
                if written {
                    if let Ok(mut last) = ack.lock() {
                        *last = Instant::now();
                    }
                }
                if let Some(reply) = frame.reply {
                    let _ = reply.try_send(written);
                }
                if !written {
                    break;
                }
            }
            live.store(false, Ordering::Release);
        });
        let mut screen = Self {
            conn_id,
            child,
            sender,
            alive,
            last_ack,
        };
        if waiting.recv_timeout(WAIT) != Ok(true) {
            bail!("helper_start_failed");
        }
        #[cfg(target_os = "macos")]
        {
            // Every display's excluded capture must produce a frame before any
            // cover is shown. Quartz frames are suspended during this handoff.
            scrap::privacy_capture::prepare(screen.child.id())?;
            if !super::macos::input(true) {
                bail!("input_permission_required");
            }
        }
        screen.transact(Operation::Show)?;
        Ok(screen)
    }
    fn transact(&mut self, operation: Operation) -> ResultType<()> {
        let (reply, waiting) = mpsc::sync_channel(1);
        let deadline = Instant::now() + WAIT;
        let mut frame = CommandFrame {
            issued: Instant::now(),
            operation,
            reply: Some(reply),
        };
        loop {
            frame.issued = Instant::now();
            match self.sender.try_send(frame) {
                Ok(()) => break,
                Err(mpsc::TrySendError::Full(returned)) => {
                    if Instant::now() >= deadline {
                        bail!("helper_busy");
                    }
                    frame = returned;
                    std::thread::sleep(Duration::from_millis(10));
                }
                Err(_) => {
                    let _ = self.stop();
                    bail!("helper_update_failed");
                }
            }
        }
        if waiting.recv_timeout(WAIT) != Ok(true) {
            let _ = self.stop();
            bail!("helper_update_failed");
        }
        Ok(())
    }
    pub fn update(&mut self, style: &NikoPrivacyStyle) -> ResultType<()> {
        self.transact(Operation::Style(style.write_to_bytes()?))
    }
    pub fn running(&self) -> bool {
        self.alive.load(Ordering::Acquire)
    }
    pub fn renew(&mut self, permitted: bool) -> bool {
        #[cfg(target_os = "macos")]
        let permitted = permitted
            && super::macos::input_active()
            && scrap::privacy_capture::healthy(self.child.id());
        if !permitted
            || !self.alive.load(Ordering::Acquire)
            || self
                .last_ack
                .lock()
                .map_or(true, |ack| ack.elapsed() > Duration::from_secs(3))
            || !matches!(self.child.try_wait(), Ok(None))
        {
            let _ = self.stop();
            return false;
        }
        match self.sender.try_send(CommandFrame {
            issued: Instant::now(),
            operation: Operation::Heartbeat,
            reply: None,
        }) {
            Ok(()) | Err(mpsc::TrySendError::Full(_)) => true,
            Err(_) => {
                let _ = self.stop();
                false
            }
        }
    }
    pub fn stop(&mut self) -> ResultType<()> {
        self.alive.store(false, Ordering::Release);
        #[cfg(target_os = "macos")]
        {
            super::macos::input(false);
        }
        if self.child.try_wait()?.is_none() {
            self.child.kill()?;
            let deadline = Instant::now() + Duration::from_secs(2);
            while self.child.try_wait()?.is_none() {
                if Instant::now() > deadline {
                    bail!("helper_exit_unconfirmed");
                }
                std::thread::sleep(Duration::from_millis(10));
            }
        }
        #[cfg(target_os = "macos")]
        {
            scrap::privacy_capture::clear(self.child.id());
        }
        Ok(())
    }
}
impl Drop for Screen {
    fn drop(&mut self) {
        let _ = self.stop();
    }
}

pub(crate) enum Input {
    Ready(Instant, Arc<Wallpaper>),
    Heartbeat(Instant),
    Show(Instant),
    Style(Instant, Arc<Wallpaper>),
}
impl Input {
    pub fn issued(&self) -> Instant {
        match self {
            Self::Ready(t, _) | Self::Heartbeat(t) | Self::Show(t) | Self::Style(t, _) => *t,
        }
    }
}

fn read_style(input: &mut impl Read) -> ResultType<Arc<Wallpaper>> {
    let mut length = [0; 4];
    input.read_exact(&mut length)?;
    let length = u32::from_le_bytes(length) as usize;
    if length == 0 || length > MAX_FRAME_BYTES {
        bail!("image_size_limit");
    }
    let mut bytes = vec![0; length];
    input.read_exact(&mut bytes)?;
    native::prepare(&NikoPrivacyStyle::parse_from_bytes(&bytes)?)
}
pub(crate) fn incoming() -> mpsc::Receiver<Input> {
    let (sender, receiver) = mpsc::sync_channel(1);
    std::thread::spawn(move || {
        let mut input = std::io::stdin().lock();
        let mut header = [0; 4];
        if input.read_exact(&mut header).is_err() || header != *b"NPS2" {
            return;
        }
        let Ok(style) = read_style(&mut input) else {
            return;
        };
        if sender.send(Input::Ready(Instant::now(), style)).is_err() {
            return;
        }
        let mut byte = [0; 1];
        while input.read_exact(&mut byte).is_ok() {
            let frame = match byte[0] {
                b'H' => Input::Heartbeat(Instant::now()),
                b'V' => Input::Show(Instant::now()),
                b'C' => {
                    let Ok(style) = read_style(&mut input) else {
                        return;
                    };
                    Input::Style(Instant::now(), style)
                }
                _ => return,
            };
            if sender.send(frame).is_err() {
                return;
            }
        }
    });
    receiver
}
pub(crate) fn initial(receiver: &mpsc::Receiver<Input>) -> ResultType<Arc<Wallpaper>> {
    match receiver.recv_timeout(Duration::from_secs(3)) {
        Ok(Input::Ready(issued, style)) if issued.elapsed() < Duration::from_secs(2) => Ok(style),
        _ => Err(anyhow!("helper_start_expired")),
    }
}
pub(crate) fn respond(byte: u8) -> ResultType<()> {
    let mut output = std::io::stdout().lock();
    output.write_all(&[byte])?;
    output.flush()?;
    Ok(())
}

pub(crate) fn helper_entry() -> Option<i32> {
    let args = std::env::args().skip(1).collect::<Vec<_>>();
    if args.first().map(String::as_str) != Some(ARG) {
        return None;
    }
    let result = if args.len() != 1 {
        Err(anyhow!("invalid_arguments"))
    } else {
        #[cfg(target_os = "macos")]
        {
            super::macos::run()
        }
        #[cfg(windows)]
        {
            crate::nikodesk::privacy_windows::run_styled_helper()
        }
    };
    Some(if result.is_ok() { 0 } else { 1 })
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn frame_length_is_rejected_before_allocation_or_decode() {
        for length in [0, u32::MAX, (MAX_FRAME_BYTES + 1) as u32] {
            assert!(read_style(&mut CursorForTest::new(length.to_le_bytes())).is_err());
        }
    }
    type CursorForTest = std::io::Cursor<[u8; 4]>;
}
