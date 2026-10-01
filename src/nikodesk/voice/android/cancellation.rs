use super::super::{Binding, MediaIo, VoiceError};
use super::CallSpec;
use std::{
    collections::HashMap,
    sync::{Mutex, OnceLock},
};

// Registry entries contain no device handles. A Java callback first closes only
// its exact Rust publication gate; native teardown remains on the owning worker.
// The entry stays until that worker has a real stop ACK and drops its driver.
struct Entry {
    binding: Binding,
    io: MediaIo,
}
static OWNERS: OnceLock<Mutex<HashMap<i64, Entry>>> = OnceLock::new();
fn owners() -> &'static Mutex<HashMap<i64, Entry>> {
    OWNERS.get_or_init(|| Mutex::new(HashMap::new()))
}
pub(super) struct Registration {
    lease: i64,
    binding: Binding,
}
pub(super) fn register(call: CallSpec, io: MediaIo) -> Result<Registration, VoiceError> {
    if io.binding() != call.binding {
        return Err(VoiceError::StaleBinding);
    }
    let mut owners = owners().lock().unwrap_or_else(|error| error.into_inner());
    if owners.contains_key(&call.lease) {
        return Err(VoiceError::Busy);
    }
    owners.insert(
        call.lease,
        Entry {
            binding: call.binding,
            io,
        },
    );
    Ok(Registration {
        lease: call.lease,
        binding: call.binding,
    })
}
pub(super) fn cancel_with_error(call: CallSpec, error: VoiceError) {
    let io = {
        let owners = owners().lock().unwrap_or_else(|error| error.into_inner());
        owners
            .get(&call.lease)
            .filter(|entry| entry.binding == call.binding)
            .map(|entry| entry.io.clone())
    };
    // fail() publishes its atomic cancelled flag before acquiring the media
    // state lock. Never hold the registry lock through a JNI/native call.
    if let Some(io) = io {
        io.fail(error);
    }
}
#[cfg(test)]
fn cancel(call: CallSpec) {
    cancel_with_error(call, VoiceError::Closed);
}
impl Drop for Registration {
    fn drop(&mut self) {
        let mut owners = owners().lock().unwrap_or_else(|error| error.into_inner());
        if owners.get(&self.lease).map(|entry| entry.binding) == Some(self.binding) {
            owners.remove(&self.lease);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::super::super::{sealed, VoiceBackend, VoiceDriver, VoiceOwner};
    use super::*;
    use std::{
        sync::{Arc, Condvar},
        time::Duration,
    };
    struct NoDevice {
        output: Arc<(Mutex<Option<MediaIo>>, Condvar)>,
    }
    struct Empty;
    impl sealed::Sealed for NoDevice {}
    impl VoiceBackend for NoDevice {
        fn physical_device_provider(&self) -> bool {
            false
        }
        fn open(self, io: MediaIo) -> Result<Box<dyn VoiceDriver>, VoiceError> {
            *self.output.0.lock().unwrap() = Some(io);
            self.output.1.notify_all();
            Ok(Box::new(Empty))
        }
    }
    impl VoiceDriver for Empty {
        fn check_permission(&self) -> Result<(), VoiceError> {
            Ok(())
        }
        fn stop(&mut self) -> Result<(), VoiceError> {
            Ok(())
        }
    }
    fn owned(binding: Binding) -> (VoiceOwner, MediaIo) {
        let output = Arc::new((Mutex::new(None), Condvar::new()));
        let owner = VoiceOwner::start(
            binding,
            NoDevice {
                output: output.clone(),
            },
        )
        .unwrap();
        let guard = output.0.lock().unwrap();
        let (guard, _) = output
            .1
            .wait_timeout_while(guard, Duration::from_secs(2), |v| v.is_none())
            .unwrap();
        (owner, guard.clone().unwrap())
    }
    #[test]
    fn android_voice_stale_callback_cannot_cancel_new_call_or_replace_lease() {
        let binding = Binding::new([41; 16], 2).unwrap();
        let call = CallSpec::new(binding, 1_000_001).unwrap();
        let (mut owner, io) = owned(binding);
        let entry = register(call, io.clone()).unwrap();
        assert!(matches!(register(call, io.clone()), Err(VoiceError::Busy)));
        cancel(CallSpec::new(Binding::new([40; 16], 2).unwrap(), call.lease as u64).unwrap());
        cancel(CallSpec::new(Binding::new([41; 16], 1).unwrap(), call.lease as u64).unwrap());
        cancel(CallSpec::new(binding, call.lease as u64 + 1).unwrap());
        assert!(io.active());
        cancel(call);
        assert!(!io.active());
        assert_eq!(io.capture(&[0.; 480], 1), Err(VoiceError::Closed));
        assert_eq!(io.execute(|| Ok(())), Err(VoiceError::Closed));
        owner.stop(Duration::from_secs(1)).unwrap();
        drop(entry);
    }
    #[test]
    fn android_voice_cancel_registry_rejects_mismatched_owner_binding() {
        let binding = Binding::new([43; 16], 2).unwrap();
        let (mut owner, io) = owned(binding);
        let other = CallSpec::new(Binding::new([42; 16], 2).unwrap(), 1_000_002).unwrap();
        assert!(matches!(
            register(other, io.clone()),
            Err(VoiceError::StaleBinding)
        ));
        cancel(other);
        assert!(io.active());
        owner.stop(Duration::from_secs(1)).unwrap();
    }
}
