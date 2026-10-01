use super::super::{
    Binding, MediaIo, VoiceBackend, VoiceDriver, VoiceError, VoiceOwner, FRAME_SAMPLES,
};
use super::{jni, pcm::PendingPlayback, CallSpec};
use ::jni::objects::GlobalRef;

pub struct AndroidBackend {
    call: CallSpec,
    session: GlobalRef,
}
impl AndroidBackend {
    pub(super) fn new(call: CallSpec, session: GlobalRef) -> Self {
        Self { call, session }
    }
    pub fn binding(&self) -> Binding {
        self.call.binding
    }
    pub fn native_lease(&self) -> u64 {
        self.call.lease as u64
    }
    /// Keeps the approved call binding rather than accepting a replacement.
    pub fn start(self) -> Result<VoiceOwner, VoiceError> {
        VoiceOwner::start(self.call.binding, self)
    }
}
impl super::super::sealed::Sealed for AndroidBackend {}
impl VoiceBackend for AndroidBackend {
    fn physical_device_provider(&self) -> bool {
        true
    }
    fn open(self, io: MediaIo) -> Result<Box<dyn VoiceDriver>, VoiceError> {
        if io.binding() != self.call.binding {
            return Err(VoiceError::StaleBinding);
        }
        // No JNI start or native/route/focus allocation is allowed in open.
        // Subsequent errors keep this driver owned through real stop retry.
        let registration = super::cancellation::register(self.call, io.clone())?;
        Ok(Box::new(AndroidDriver {
            session: self.session,
            io,
            _registration: registration,
            buffers: None,
            capture: [0.; FRAME_SAMPLES],
            playback: PendingPlayback::new(),
            stopped: false,
        }))
    }
}
struct AndroidDriver {
    session: GlobalRef,
    io: MediaIo,
    _registration: super::cancellation::Registration,
    buffers: Option<(GlobalRef, GlobalRef)>,
    capture: [f32; FRAME_SAMPLES],
    playback: PendingPlayback,
    stopped: bool,
}
impl VoiceDriver for AndroidDriver {
    fn check_permission(&self) -> Result<(), VoiceError> {
        super::status(jni::session_int(&self.session, "permissionStatus")?)
    }
    fn poll(&mut self) -> Result<(), VoiceError> {
        if self.stopped {
            return Err(VoiceError::Closed);
        }
        if self.buffers.is_none() {
            self.buffers = Some(jni::buffers()?);
        }
        let io = self.io.clone();
        match io.execute(|| jni::session_int(&self.session, "pollStatus"))? {
            1 => return Ok(()),
            2 => (),
            code => {
                super::status(code)?;
                return Err(VoiceError::WorkerFailed);
            }
        }
        let (input, output) = self.buffers.as_ref().ok_or(VoiceError::WorkerFailed)?;
        let count = io.execute(|| jni::read(&self.session, input, &mut self.capture))?;
        let count = super::pcm::capture_count(count)?;
        if count > 0 {
            match io.capture(&self.capture[..count], 1) {
                Ok(()) | Err(VoiceError::Busy) => (),
                Err(error) => return Err(error),
            }
        }
        if self.playback.empty() {
            let mut samples = [0.; FRAME_SAMPLES];
            io.render_pending(&mut samples, 1);
            self.playback.load(samples)?;
            jni::set_output(output, self.playback.data())?;
        }
        let written = io.execute(|| {
            jni::write(
                &self.session,
                output,
                self.playback.offset(),
                self.playback.remaining(),
            )
        })?;
        self.playback.accepted(written)?;
        if written > 0 {
            io.playback_prepared();
        }
        Ok(())
    }
    fn stop(&mut self) -> Result<(), VoiceError> {
        self.capture.fill(0.);
        self.playback.clear();
        if self.stopped {
            return Ok(());
        }
        super::status(jni::session_int(&self.session, "stopStatus")?)?;
        if let Some(buffers) = &self.buffers {
            jni::clear_buffers(buffers)?;
        }
        self.stopped = true;
        self.buffers = None;
        // Kotlin ACK includes native release, callback detach/drain and its
        // thread join. VoiceOwner additionally waits for this worker's join.
        Ok(())
    }
}
