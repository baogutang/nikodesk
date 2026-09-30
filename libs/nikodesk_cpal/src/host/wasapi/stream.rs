use super::windows_err_to_cpal_err;
use crate::traits::StreamTrait;
use crate::{
    BackendSpecificError, Data, InputCallbackInfo, OutputCallbackInfo, PauseStreamError,
    PlayStreamError, SampleFormat, StreamError,
};
use std::mem;
use std::os::windows::io::{AsRawHandle, FromRawHandle, OwnedHandle};
use std::ptr;
use std::sync::mpsc::{channel, Receiver, Sender};
use std::sync::Arc;
use std::thread::{self, JoinHandle};
use windows::Win32::Foundation;
use windows::Win32::Media::Audio;
use windows::Win32::System::SystemServices;
use windows::Win32::System::Threading;

mod wait_policy;
mod loopback_packet;
use wait_policy::{WaitError, WaitPolicy, Wake};

pub struct Stream {
    /// The high-priority audio processing thread calling callbacks.
    /// Option used for moving out in destructor.
    thread: Option<JoinHandle<()>>,

    // Commands processed by the `run()` method that is currently running.
    // `pending_scheduled_event` must be signalled whenever a command is added here, so that it
    // will get picked up.
    commands: Sender<Command>,

    // This event is signalled after a new entry is added to `commands`, so that the `run()`
    // method can be notified.
    pending_scheduled_event: Arc<OwnedHandle>,
}

struct RunContext {
    // Streams that have been created in this event loop.
    stream: StreamInner,

    // Handles corresponding to the `event` field of each element of `voices`. Must always be in
    // sync with `voices`, except that the first element is always `pending_scheduled_event`.
    handles: Vec<Foundation::HANDLE>,

    commands: Receiver<Command>,

    // Keep the event alive if Stream is dropped inside its own callback.
    _pending_scheduled_event: Arc<OwnedHandle>,
}

// Once we start running the eventloop, the RunContext will not be moved.
unsafe impl Send for RunContext {}

pub enum Command {
    PlayStream,
    PauseStream,
    Terminate,
}

pub enum AudioClientFlow {
    Render {
        render_client: Audio::IAudioRenderClient,
    },
    Capture {
        capture_client: Audio::IAudioCaptureClient,
    },
}

pub struct StreamInner {
    pub audio_client: Audio::IAudioClient,
    pub audio_clock: Audio::IAudioClock,
    pub client_flow: AudioClientFlow,
    // Event that is signalled by WASAPI whenever audio data must be written.
    pub event: Foundation::HANDLE,
    // True if the stream is currently playing. False if paused.
    pub playing: bool,
    // Old Windows loopback clients do not signal their capture event.
    pub loopback_polling: bool,
    // Number of frames of audio data in the underlying buffer allocated by WASAPI.
    pub max_frames_in_buffer: u32,
    // Number of bytes that each frame occupies.
    pub bytes_per_frame: u16,
    // The configuration with which the stream was created.
    pub config: crate::StreamConfig,
    // The sample format with which the stream was created.
    pub sample_format: SampleFormat,
    // Declared last so loopback's event outlives all AudioClient/service refs,
    // including their teardown. Other stream kinds retain the upstream owner.
    pub loopback_event_owner: Option<OwnedHandle>,
}

impl Stream {
    pub(crate) fn new_input<D, E>(
        stream_inner: StreamInner,
        mut data_callback: D,
        mut error_callback: E,
    ) -> Stream
    where
        D: FnMut(&Data, &InputCallbackInfo) + Send + 'static,
        E: FnMut(StreamError) + Send + 'static,
    {
        let pending_scheduled_event = unsafe {
            Threading::CreateEventA(None, false, false, windows::core::PCSTR(ptr::null()))
        }
        .expect("cpal: could not create input stream event");
        let owned_event =
            Arc::new(unsafe { OwnedHandle::from_raw_handle(pending_scheduled_event.0 as _) });
        let (tx, rx) = channel();

        let run_context = RunContext {
            handles: vec![pending_scheduled_event, stream_inner.event],
            stream: stream_inner,
            commands: rx,
            _pending_scheduled_event: Arc::clone(&owned_event),
        };

        let thread = thread::Builder::new()
            .name("cpal_wasapi_in".to_owned())
            .spawn(move || run_input(run_context, &mut data_callback, &mut error_callback))
            .unwrap();

        Stream {
            thread: Some(thread),
            commands: tx,
            pending_scheduled_event: owned_event,
        }
    }

    pub(crate) fn new_output<D, E>(
        stream_inner: StreamInner,
        mut data_callback: D,
        mut error_callback: E,
    ) -> Stream
    where
        D: FnMut(&mut Data, &OutputCallbackInfo) + Send + 'static,
        E: FnMut(StreamError) + Send + 'static,
    {
        let pending_scheduled_event = unsafe {
            Threading::CreateEventA(None, false, false, windows::core::PCSTR(ptr::null()))
        }
        .expect("cpal: could not create output stream event");
        let owned_event =
            Arc::new(unsafe { OwnedHandle::from_raw_handle(pending_scheduled_event.0 as _) });
        let (tx, rx) = channel();

        let run_context = RunContext {
            handles: vec![pending_scheduled_event, stream_inner.event],
            stream: stream_inner,
            commands: rx,
            _pending_scheduled_event: Arc::clone(&owned_event),
        };

        let thread = thread::Builder::new()
            .name("cpal_wasapi_out".to_owned())
            .spawn(move || run_output(run_context, &mut data_callback, &mut error_callback))
            .unwrap();

        Stream {
            thread: Some(thread),
            commands: tx,
            pending_scheduled_event: owned_event,
        }
    }

    #[inline]
    fn push_command(&self, command: Command) -> Result<(), StreamError> {
        self.commands
            .send(command)
            .map_err(|_| StreamError::DeviceNotAvailable)?;
        unsafe {
            Threading::SetEvent(Foundation::HANDLE(
                self.pending_scheduled_event.as_raw_handle() as _,
            ))
        }
        .map_err(windows_err_to_cpal_err)
    }
}

impl Drop for Stream {
    #[inline]
    fn drop(&mut self) {
        let _ = self.push_command(Command::Terminate);
        if let Some(thread) = self.thread.take() {
            // Prevent self-join: Terminate was sent; the thread exits after the current callback
            // returns. Shared event ownership keeps the handle alive until both Stream and
            // RunContext release it.
            if thread.thread().id() != thread::current().id() {
                let _ = thread.join();
            }
        }
    }
}

impl StreamTrait for Stream {
    fn play(&self) -> Result<(), PlayStreamError> {
        self.push_command(Command::PlayStream)
            .map_err(|error| match error {
                StreamError::DeviceNotAvailable => PlayStreamError::DeviceNotAvailable,
                StreamError::BackendSpecific { err } | StreamError::StreamInterrupted { err } => {
                    PlayStreamError::BackendSpecific { err }
                }
            })
    }
    fn pause(&self) -> Result<(), PauseStreamError> {
        self.push_command(Command::PauseStream)
            .map_err(|error| match error {
                StreamError::DeviceNotAvailable => PauseStreamError::DeviceNotAvailable,
                StreamError::BackendSpecific { err } | StreamError::StreamInterrupted { err } => {
                    PauseStreamError::BackendSpecific { err }
                }
            })
    }
}

impl Drop for StreamInner {
    #[inline]
    fn drop(&mut self) {
        if self.loopback_event_owner.is_none() {
            unsafe {
                let _ = Foundation::CloseHandle(self.event);
            }
        }
    }
}

// Process any pending commands that are queued within the `RunContext`.
// Returns `true` if the loop should continue running, `false` if it should terminate.
fn process_commands(run_context: &mut RunContext) -> Result<bool, StreamError> {
    // Process the pending commands.
    for command in run_context.commands.try_iter() {
        match command {
            Command::PlayStream => unsafe {
                if !run_context.stream.playing {
                    run_context
                        .stream
                        .audio_client
                        .Start()
                        .map_err(windows_err_to_cpal_err::<StreamError>)?;
                    run_context.stream.playing = true;
                }
            },
            Command::PauseStream => unsafe {
                if run_context.stream.playing {
                    run_context
                        .stream
                        .audio_client
                        .Stop()
                        .map_err(windows_err_to_cpal_err::<StreamError>)?;
                    run_context.stream.playing = false;
                }
            },
            Command::Terminate => {
                return Ok(false);
            }
        }
    }

    Ok(true)
}
// Wait for any of the given handles to be signalled.
//
// Returns the index of the `handle` that was signalled, or an `Err` if
// `WaitForMultipleObjectsEx` fails.
//
// This is called when the `run` thread is ready to wait for the next event. The
// next event might be some command submitted by the user (the first handle) or
// might indicate that one of the streams is ready to deliver or receive audio.
fn wait_for_handle_signal(
    handles: &[Foundation::HANDLE],
    policy: WaitPolicy,
) -> Result<Wake, BackendSpecificError> {
    debug_assert!(handles.len() <= SystemServices::MAXIMUM_WAIT_OBJECTS as usize);
    match policy.wait(|plan| unsafe {
        Threading::WaitForMultipleObjectsEx(
            &handles[..plan.handle_count],
            false,
            plan.timeout_ms,
            false,
        )
        .0
    }) {
        Ok(wake) => Ok(wake),
        Err(WaitError::Failed) => {
            let err = unsafe { Foundation::GetLastError() };
            Err(BackendSpecificError {
                description: format!("WaitForMultipleObjectsEx failed: {:?}", err),
            })
        }
        Err(WaitError::Unexpected(value)) => Err(BackendSpecificError {
            description: format!("WaitForMultipleObjectsEx returned unexpected value: {:#x}", value),
        }),
    }
}

// Get the number of available frames that are available for writing/reading.
fn get_available_frames(stream: &StreamInner) -> Result<u32, StreamError> {
    unsafe {
        let padding = stream
            .audio_client
            .GetCurrentPadding()
            .map_err(windows_err_to_cpal_err::<StreamError>)?;
        Ok(stream.max_frames_in_buffer - padding)
    }
}

fn run_input(
    mut run_ctxt: RunContext,
    data_callback: &mut dyn FnMut(&Data, &InputCallbackInfo),
    error_callback: &mut dyn FnMut(StreamError),
) {
    if let Err(err) = boost_current_thread_priority() {
        error_callback(err);
    }

    loop {
        match process_commands_and_await_signal(&mut run_ctxt, error_callback) {
            Some(ControlFlow::Break) => break,
            Some(ControlFlow::Continue) => continue,
            None => (),
        }
        let capture_client = match run_ctxt.stream.client_flow {
            AudioClientFlow::Capture { ref capture_client } => capture_client.clone(),
            _ => unreachable!(),
        };
        if run_ctxt.stream.loopback_polling {
            match process_loopback_input(&mut run_ctxt, capture_client, data_callback, error_callback) {
                ControlFlow::Break => break,
                ControlFlow::Continue => continue,
            }
        }
        match process_input(
            &run_ctxt.stream,
            capture_client,
            data_callback,
            error_callback,
        ) {
            ControlFlow::Break => break,
            ControlFlow::Continue => continue,
        }
    }
}

fn run_output(
    mut run_ctxt: RunContext,
    data_callback: &mut dyn FnMut(&mut Data, &OutputCallbackInfo),
    error_callback: &mut dyn FnMut(StreamError),
) {
    if let Err(err) = boost_current_thread_priority() {
        error_callback(err);
    }

    loop {
        match process_commands_and_await_signal(&mut run_ctxt, error_callback) {
            Some(ControlFlow::Break) => break,
            Some(ControlFlow::Continue) => continue,
            None => (),
        }
        let render_client = match run_ctxt.stream.client_flow {
            AudioClientFlow::Render { ref render_client } => render_client.clone(),
            _ => unreachable!(),
        };
        match process_output(
            &run_ctxt.stream,
            render_client,
            data_callback,
            error_callback,
        ) {
            ControlFlow::Break => break,
            ControlFlow::Continue => continue,
        }
    }
}

// Priority boosting remains best-effort; callers report failure without stopping the stream.
fn boost_current_thread_priority() -> Result<(), StreamError> {
    unsafe {
        Threading::SetThreadPriority(
            Threading::GetCurrentThread(),
            Threading::THREAD_PRIORITY_TIME_CRITICAL,
        )
    }
    .map_err(|err| super::windows_err_to_cpal_err_message(err, "SetThreadPriority failed: "))
}

enum ControlFlow {
    Break,
    Continue,
}

fn process_commands_and_await_signal(
    run_context: &mut RunContext,
    error_callback: &mut dyn FnMut(StreamError),
) -> Option<ControlFlow> {
    // Process queued commands.
    match process_commands(run_context) {
        Ok(true) => (),
        Ok(false) => return Some(ControlFlow::Break),
        Err(err) => {
            error_callback(err);
            return Some(ControlFlow::Break);
        }
    };

    // Wait for any of the handles to be signalled.
    let policy = WaitPolicy::new(run_context.stream.loopback_polling, run_context.stream.playing);
    let wake = match wait_for_handle_signal(&run_context.handles, policy) {
        Ok(wake) => wake,
        Err(err) => {
            error_callback(err.into());
            return Some(ControlFlow::Break);
        }
    };

    if wake == Wake::Command {
        return Some(ControlFlow::Continue);
    }

    // A stop/pause can arrive alongside an audio event or the fallback timeout.
    // Keep it ahead of the next bounded loopback packet batch.
    if run_context.stream.loopback_polling {
        match process_commands(run_context) {
            Ok(false) => return Some(ControlFlow::Break),
            Ok(true) if !run_context.stream.playing => return Some(ControlFlow::Continue),
            Ok(true) => (),
            Err(err) => {
                error_callback(err);
                return Some(ControlFlow::Break);
            }
        }
    }

    None
}

// The loop for processing pending input data.
fn process_input(
    stream: &StreamInner,
    capture_client: Audio::IAudioCaptureClient,
    data_callback: &mut dyn FnMut(&Data, &InputCallbackInfo),
    error_callback: &mut dyn FnMut(StreamError),
) -> ControlFlow {
    unsafe {
        // Get the available data in the shared buffer.
        let mut buffer: *mut u8 = ptr::null_mut();
        let mut flags = mem::MaybeUninit::uninit();
        loop {
            let mut frames_available = match capture_client.GetNextPacketSize() {
                Ok(0) => return ControlFlow::Continue,
                Ok(f) => f,
                Err(err) => {
                    error_callback(windows_err_to_cpal_err(err));
                    return ControlFlow::Break;
                }
            };
            let mut qpc_position: u64 = 0;
            let result = capture_client.GetBuffer(
                &mut buffer,
                &mut frames_available,
                flags.as_mut_ptr(),
                None,
                Some(&mut qpc_position),
            );

            match result {
                // TODO: Can this happen?
                Err(e) if e.code() == Audio::AUDCLNT_S_BUFFER_EMPTY => continue,
                Err(e) => {
                    error_callback(windows_err_to_cpal_err(e));
                    return ControlFlow::Break;
                }
                Ok(_) => (),
            }

            debug_assert!(!buffer.is_null());

            let data = buffer as *mut ();
            let len = frames_available as usize * stream.bytes_per_frame as usize
                / stream.sample_format.sample_size();
            let data = Data::from_parts(data, len, stream.sample_format);

            // The `qpc_position` is in 100 nanosecond units. Convert it to nanoseconds.
            let timestamp = match input_timestamp(stream, qpc_position) {
                Ok(ts) => ts,
                Err(err) => {
                    error_callback(err);
                    return ControlFlow::Break;
                }
            };
            let info = InputCallbackInfo { timestamp };
            data_callback(&data, &info);

            // Release the buffer.
            let result = capture_client
                .ReleaseBuffer(frames_available)
                .map_err(windows_err_to_cpal_err);
            if let Err(err) = result {
                error_callback(err);
                return ControlFlow::Break;
            }
        }
    }
}

// Keep the ordinary microphone processing unchanged. The polling path owns
// each packet until its matching ReleaseBuffer, including callback unwinding.
fn process_loopback_input(
    run_context: &mut RunContext,
    capture_client: Audio::IAudioCaptureClient,
    data_callback: &mut dyn FnMut(&Data, &InputCallbackInfo),
    error_callback: &mut dyn FnMut(StreamError),
) -> ControlFlow {
    let mut packets_processed = 0;
    loop {
        match process_commands(run_context) {
            Ok(false) => return ControlFlow::Break,
            Ok(true) if !run_context.stream.playing => return ControlFlow::Continue,
            Ok(true) => (),
            Err(err) => {
                error_callback(err);
                return ControlFlow::Break;
            }
        }
        let stream = &run_context.stream;
        unsafe {
            match capture_client.GetNextPacketSize() {
                Ok(0) => return ControlFlow::Continue,
                Ok(_) => (),
                Err(err) => {
                    error_callback(windows_err_to_cpal_err(err));
                    return ControlFlow::Break;
                }
            }
            let mut buffer = ptr::null_mut();
            let mut frames = 0;
            let mut flags = 0;
            let mut qpc_position = 0;
            if let Err(err) = capture_client.GetBuffer(
                &mut buffer, &mut frames, &mut flags, None, Some(&mut qpc_position),
            ) {
                error_callback(windows_err_to_cpal_err(err));
                return ControlFlow::Break;
            }
            // AUDCLNT_S_BUFFER_EMPTY is a successful HRESULT with zero frames.
            if frames == 0 {
                return ControlFlow::Continue;
            }
            let frames_read = std::cell::Cell::new(0);
            let (read_result, release_result) = loopback_packet::with_packet(
                || {
                    let invalid_packet = || StreamError::BackendSpecific {
                        err: BackendSpecificError { description: "invalid loopback packet size or pointer".into() },
                    };
                    if frames > stream.max_frames_in_buffer {
                        return Err(invalid_packet());
                    }
                    let bytes = (frames as usize).checked_mul(stream.bytes_per_frame as usize)
                        .ok_or_else(invalid_packet)?;
                    let mut silence;
                    let data = if flags & Audio::AUDCLNT_BUFFERFLAGS_SILENT.0 as u32 != 0 {
                        let unsigned_bits = match stream.sample_format {
                            SampleFormat::U8 => Some(8),
                            SampleFormat::U16 => Some(16),
                            SampleFormat::U32 => Some(32),
                            SampleFormat::U64 => Some(64),
                            _ => None,
                        };
                        silence = loopback_packet::aligned_silence(bytes, unsigned_bits);
                        silence.as_mut_ptr() as *mut ()
                    } else {
                        if buffer.is_null() {
                            return Err(invalid_packet());
                        }
                        buffer as *mut ()
                    };
                    let data = Data::from_parts(data, bytes / stream.sample_format.sample_size(), stream.sample_format);
                    let info = InputCallbackInfo { timestamp: input_timestamp(stream, qpc_position)? };
                    data_callback(&data, &info);
                    frames_read.set(frames);
                    Ok(())
                },
                || capture_client.ReleaseBuffer(frames_read.get()).map_err(windows_err_to_cpal_err::<StreamError>),
                |err| error_callback(err),
            );
            let mut failed = false;
            if let Err(err) = read_result {
                error_callback(err);
                failed = true;
            }
            if let Err(err) = release_result {
                error_callback(err);
                failed = true;
            }
            if failed {
                return ControlFlow::Break;
            }
            packets_processed += 1;
            if wait_policy::batch_complete(true, packets_processed) {
                return ControlFlow::Continue;
            }
        }
    }
}

// The loop for writing output data.
fn process_output(
    stream: &StreamInner,
    render_client: Audio::IAudioRenderClient,
    data_callback: &mut dyn FnMut(&mut Data, &OutputCallbackInfo),
    error_callback: &mut dyn FnMut(StreamError),
) -> ControlFlow {
    // The number of frames available for writing.
    let frames_available = match get_available_frames(stream) {
        Ok(0) => return ControlFlow::Continue, // TODO: Can this happen?
        Ok(n) => n,
        Err(err) => {
            error_callback(err);
            return ControlFlow::Break;
        }
    };

    unsafe {
        let buffer = match render_client.GetBuffer(frames_available) {
            Ok(b) => b,
            Err(e) => {
                error_callback(windows_err_to_cpal_err(e));
                return ControlFlow::Break;
            }
        };

        debug_assert!(!buffer.is_null());

        let data = buffer as *mut ();
        let len = frames_available as usize * stream.bytes_per_frame as usize
            / stream.sample_format.sample_size();
        let mut data = Data::from_parts(data, len, stream.sample_format);
        let sample_rate = stream.config.sample_rate;
        let timestamp = match output_timestamp(stream, frames_available, sample_rate) {
            Ok(ts) => ts,
            Err(err) => {
                error_callback(err);
                return ControlFlow::Break;
            }
        };
        let info = OutputCallbackInfo { timestamp };
        data_callback(&mut data, &info);

        if let Err(err) = render_client.ReleaseBuffer(frames_available, 0) {
            error_callback(windows_err_to_cpal_err(err));
            return ControlFlow::Break;
        }
    }

    ControlFlow::Continue
}

/// Convert the given duration in frames at the given sample rate to a `std::time::Duration`.
fn frames_to_duration(frames: u32, rate: crate::SampleRate) -> std::time::Duration {
    let secsf = frames as f64 / rate.0 as f64;
    let secs = secsf as u64;
    let nanos = ((secsf - secs as f64) * 1_000_000_000.0) as u32;
    std::time::Duration::new(secs, nanos)
}

/// Use the stream's `IAudioClock` to produce the current stream instant.
///
/// Uses the QPC position produced via the `GetPosition` method.
fn stream_instant(stream: &StreamInner) -> Result<crate::StreamInstant, StreamError> {
    let mut position: u64 = 0;
    let mut qpc_position: u64 = 0;
    unsafe {
        stream
            .audio_clock
            .GetPosition(&mut position, Some(&mut qpc_position))
            .map_err(windows_err_to_cpal_err::<StreamError>)?;
    };
    // The `qpc_position` is in 100 nanosecond units. Convert it to nanoseconds.
    let qpc_nanos = qpc_position as i128 * 100;
    let instant = crate::StreamInstant::from_nanos_i128(qpc_nanos)
        .expect("performance counter out of range of `StreamInstant` representation");
    Ok(instant)
}

/// Produce the input stream timestamp.
///
/// `buffer_qpc_position` is the `qpc_position` returned via the `GetBuffer` call on the capture
/// client. It represents the instant at which the first sample of the retrieved buffer was
/// captured.
fn input_timestamp(
    stream: &StreamInner,
    buffer_qpc_position: u64,
) -> Result<crate::InputStreamTimestamp, StreamError> {
    // The `qpc_position` is in 100 nanosecond units. Convert it to nanoseconds.
    let qpc_nanos = buffer_qpc_position as i128 * 100;
    let capture = crate::StreamInstant::from_nanos_i128(qpc_nanos)
        .expect("performance counter out of range of `StreamInstant` representation");
    let callback = stream_instant(stream)?;
    Ok(crate::InputStreamTimestamp { capture, callback })
}

/// Produce the output stream timestamp.
///
/// `frames_available` is the number of frames available for writing as reported by subtracting the
/// result of `GetCurrentPadding` from the maximum buffer size.
///
/// `sample_rate` is the rate at which audio frames are processed by the device.
///
/// TODO: The returned `playback` is an estimate that assumes audio is delivered immediately after
/// `frames_available` are consumed. The reality is that there is likely a tiny amount of latency
/// after this, but not sure how to determine this.
fn output_timestamp(
    stream: &StreamInner,
    frames_available: u32,
    sample_rate: crate::SampleRate,
) -> Result<crate::OutputStreamTimestamp, StreamError> {
    let callback = stream_instant(stream)?;
    let buffer_duration = frames_to_duration(frames_available, sample_rate);
    let playback = callback
        .add(buffer_duration)
        .expect("`playback` occurs beyond representation supported by `StreamInstant`");
    Ok(crate::OutputStreamTimestamp { callback, playback })
}
