use super::{CallSpec, VoiceError};
use ::jni::{
    objects::{GlobalRef, JClass, JFloatArray, JString, JValue},
    sys::jboolean,
    JNIEnv, JavaVM,
};
use std::sync::OnceLock;

struct Runtime {
    vm: JavaVM,
    class: GlobalRef,
}
static RUNTIME: OnceLock<Runtime> = OnceLock::new();
fn error() -> VoiceError {
    VoiceError::Device("android_voice_jni".into())
}
fn runtime() -> Result<&'static Runtime, VoiceError> {
    RUNTIME.get().ok_or(VoiceError::Unsupported)
}
fn with_env<T>(
    action: impl FnOnce(&mut JNIEnv<'_>, &GlobalRef) -> Result<T, VoiceError>,
) -> Result<T, VoiceError> {
    let rt = runtime()?;
    let mut env = rt.vm.attach_current_thread().map_err(|_| error())?;
    let result = env.with_local_frame(32, |env| {
        Ok::<_, ::jni::errors::Error>(action(env, &rt.class))
    });
    if env.exception_check().map_err(|_| error())? {
        env.exception_clear().map_err(|_| error())?;
        return Err(error());
    }
    result.map_err(|_| error())?
}
// Caches the actual loaded class, not FindClass on an attached worker whose
// classloader can differ. Kotlin calls only after ordinary-user/context checks.
#[no_mangle]
pub extern "system" fn Java_io_nikodesk_android_voice_NikoVoiceBridge_nativeInitialize(
    env: JNIEnv<'_>,
    class: JClass<'_>,
) -> jboolean {
    let result = (|| {
        let vm = env.get_java_vm().map_err(|_| error())?;
        if let Some(rt) = RUNTIME.get() {
            if rt.vm.get_java_vm_pointer() != vm.get_java_vm_pointer()
                || !env
                    .is_same_object(rt.class.as_obj(), &class)
                    .map_err(|_| error())?
            {
                return Err(error());
            }
            return Ok(());
        }
        let global = env.new_global_ref(&class).map_err(|_| error())?;
        RUNTIME
            .set(Runtime { vm, class: global })
            .map_err(|_| VoiceError::Busy)
    })();
    if env.exception_check().unwrap_or(true) {
        let _clear = env.exception_clear();
        return 0;
    }
    if result.is_ok() {
        1
    } else {
        0
    }
}
#[no_mangle]
pub extern "system" fn Java_io_nikodesk_android_voice_NikoVoiceBridge_nativeCancelled(
    mut env: JNIEnv<'_>,
    _class: JClass<'_>,
    nonce: JString<'_>,
    epoch: i64,
    lease: i64,
    code: i32,
) {
    // No panic or pending Java exception may cross this callback ABI. Errors
    // leave the Java gate closed; unknown/old calls never touch a new owner.
    let _result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let text: String = env.get_string(&nonce).map_err(|_| error())?.into();
        if text.len() != 32
            || !text
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
            || epoch <= 0
            || lease <= 0
        {
            return Err(VoiceError::InvalidBinding);
        }
        let mut bytes = [0; 16];
        for (index, value) in bytes.iter_mut().enumerate() {
            *value =
                u8::from_str_radix(&text[index * 2..index * 2 + 2], 16).map_err(|_| error())?;
        }
        let binding = super::Binding::new(bytes, epoch as u64)?;
        let reason = match code {
            -1 => VoiceError::PermissionDenied,
            -2 => VoiceError::StaleBinding,
            -4 => VoiceError::Unsupported,
            -6 => VoiceError::Closed,
            _ => return Err(VoiceError::InvalidBinding),
        };
        super::cancellation::cancel_with_error(CallSpec::new(binding, lease as u64)?, reason);
        Ok::<_, VoiceError>(())
    }));
    if env.exception_check().unwrap_or(true) {
        let _clear = env.exception_clear();
    }
}
fn static_int(name: &str) -> Result<i32, VoiceError> {
    with_env(|env, class| {
        let class: &JClass<'_> = class.as_obj().into();
        env.call_static_method(class, name, "()I", &[])
            .and_then(|v| v.i())
            .map_err(|_| error())
    })
}
pub(super) fn authorization_status() -> Result<bool, VoiceError> {
    match static_int("authorizationStatus")? {
        0 => Ok(true),
        -1 => Ok(false),
        value => super::status(value).map(|_| false),
    }
}
pub(super) fn snapshot_json() -> Result<String, VoiceError> {
    with_env(|env, class| {
        let class: &JClass<'_> = class.as_obj().into();
        let value = env
            .call_static_method(class, "snapshotJson", "()Ljava/lang/String;", &[])
            .and_then(|v| v.l())
            .map_err(|_| error())?;
        let value = JString::from(value);
        let text: String = env.get_string(&value).map_err(|_| error())?.into();
        if text.len() > 32_768 {
            return Err(VoiceError::Unsupported);
        }
        Ok(text)
    })
}
pub(super) fn prepare(
    revision: i64,
    input: &str,
    output: &str,
    format: &str,
    call: CallSpec,
    approval: &str,
) -> Result<GlobalRef, VoiceError> {
    with_env(|env, class| {
        let class: &JClass<'_> = class.as_obj().into();
        let input = env.new_string(input).map_err(|_| error())?;
        let output = env.new_string(output).map_err(|_| error())?;
        let format = env.new_string(format).map_err(|_| error())?;
        let approval = env.new_string(approval).map_err(|_| error())?;
        let nonce = env
            .byte_array_from_slice(call.binding.nonce())
            .map_err(|_| error())?;
        let result = env.call_static_method(class, "prepare",
            "(JLjava/lang/String;Ljava/lang/String;Ljava/lang/String;[BJJLjava/lang/String;)Lio/nikodesk/android/voice/NikoVoicePreparation;",
            &[JValue::Long(revision), JValue::Object(input.as_ref()), JValue::Object(output.as_ref()), JValue::Object(format.as_ref()),
              JValue::Object(nonce.as_ref()), JValue::Long(call.epoch), JValue::Long(call.lease), JValue::Object(approval.as_ref())])
            .and_then(|v| v.l()).map_err(|_| error())?;
        let code = env
            .call_method(&result, "code", "()I", &[])
            .and_then(|v| v.i())
            .map_err(|_| error())?;
        super::status(code)?;
        let session = env
            .call_method(
                &result,
                "session",
                "()Lio/nikodesk/android/voice/NikoVoiceSession;",
                &[],
            )
            .and_then(|v| v.l())
            .map_err(|_| error())?;
        if session.is_null() {
            return Err(error());
        }
        // Kotlin preparation owns no route, focus, callbacks or native device.
        env.new_global_ref(session).map_err(|_| error())
    })
}
pub(super) fn session_int(session: &GlobalRef, name: &str) -> Result<i32, VoiceError> {
    with_env(|env, _| {
        env.call_method(session.as_obj(), name, "()I", &[])
            .and_then(|v| v.i())
            .map_err(|_| error())
    })
}
pub(super) fn retained_stop(call: CallSpec) -> Result<i32, VoiceError> {
    with_env(|env, class| {
        let class: &JClass<'_> = class.as_obj().into();
        let nonce = env
            .byte_array_from_slice(call.binding.nonce())
            .map_err(|_| error())?;
        env.call_static_method(
            class,
            "retryRetainedNativeStop",
            "([BJJ)I",
            &[
                JValue::Object(nonce.as_ref()),
                JValue::Long(call.epoch),
                JValue::Long(call.lease),
            ],
        )
        .and_then(|v| v.i())
        .map_err(|_| error())
    })
}
pub(super) fn buffers() -> Result<(GlobalRef, GlobalRef), VoiceError> {
    with_env(|env, _| {
        let input = env.new_float_array(480).map_err(|_| error())?;
        let input = env.new_global_ref(input).map_err(|_| error())?;
        let output = env.new_float_array(480).map_err(|_| error())?;
        let output = env.new_global_ref(output).map_err(|_| error())?;
        Ok((input, output))
    })
}
pub(super) fn read(
    session: &GlobalRef,
    input: &GlobalRef,
    samples: &mut [f32; 480],
) -> Result<i32, VoiceError> {
    with_env(|env, _| {
        let array: &JFloatArray<'_> = input.as_obj().into();
        let count = env
            .call_method(
                session.as_obj(),
                "readPcm",
                "([F)I",
                &[JValue::Object(array.as_ref())],
            )
            .and_then(|v| v.i())
            .map_err(|_| error())?;
        if count < 0 {
            super::status(count)?;
        }
        let count_usize = super::pcm::capture_count(count)?;
        samples.fill(0.);
        env.get_float_array_region(array, 0, &mut samples[..count_usize])
            .map_err(|_| error())?;
        Ok(count)
    })
}
pub(super) fn set_output(output: &GlobalRef, samples: &[f32; 480]) -> Result<(), VoiceError> {
    with_env(|env, _| {
        let array: &JFloatArray<'_> = output.as_obj().into();
        env.set_float_array_region(array, 0, samples)
            .map_err(|_| error())
    })
}
pub(super) fn clear_buffers(buffers: &(GlobalRef, GlobalRef)) -> Result<(), VoiceError> {
    with_env(|env, _| {
        for buffer in [&buffers.0, &buffers.1] {
            let array: &JFloatArray<'_> = buffer.as_obj().into();
            env.set_float_array_region(array, 0, &[0.; 480])
                .map_err(|_| error())?;
        }
        Ok(())
    })
}
pub(super) fn write(
    session: &GlobalRef,
    output: &GlobalRef,
    offset: usize,
    count: usize,
) -> Result<i32, VoiceError> {
    if offset > 480 || count == 0 || count > 480 - offset {
        return Err(VoiceError::InvalidPcm);
    }
    with_env(|env, _| {
        let array: &JFloatArray<'_> = output.as_obj().into();
        let written = env
            .call_method(
                session.as_obj(),
                "writePcm",
                "([FII)I",
                &[
                    JValue::Object(array.as_ref()),
                    JValue::Int(offset as i32),
                    JValue::Int(count as i32),
                ],
            )
            .and_then(|v| v.i())
            .map_err(|_| error())?;
        if written < 0 {
            super::status(written)?;
        }
        if written as usize > count {
            return Err(VoiceError::InvalidPcm);
        }
        Ok(written)
    })
}

pub(super) fn available() -> Result<bool, VoiceError> {
    with_env(|env, class| {
        let class: &JClass<'_> = class.as_obj().into();
        env.call_static_method(class, "available", "()Z", &[])
            .and_then(|v| v.z())
            .map_err(|_| error())
    })
}
pub(super) fn normal_uid() -> Result<i32, VoiceError> {
    static_int("normalUserUid")
}
pub(super) fn authorization_code() -> Result<i32, VoiceError> {
    static_int("authorizationStatusCode")
}
pub(super) fn permission_job() -> Result<GlobalRef, VoiceError> {
    with_env(|env, class| {
        let class: &JClass<'_> = class.as_obj().into();
        let job = env
            .call_static_method(
                class,
                "beginPermissionJob",
                "()Lio/nikodesk/android/voice/NikoVoicePermissionJob;",
                &[],
            )
            .and_then(|v| v.l())
            .map_err(|_| error())?;
        if job.is_null() {
            return Err(error());
        }
        env.new_global_ref(job).map_err(|_| error())
    })
}
pub(super) fn approval_job(
    revision: i64,
    input: &str,
    output: &str,
    format: &str,
    call: CallSpec,
    background: bool,
) -> Result<GlobalRef, VoiceError> {
    with_env(|env, class| {
        let class: &JClass<'_> = class.as_obj().into();
        let input = env.new_string(input).map_err(|_| error())?;
        let output = env.new_string(output).map_err(|_| error())?;
        let format = env.new_string(format).map_err(|_| error())?;
        let nonce = env
            .byte_array_from_slice(call.binding.nonce())
            .map_err(|_| error())?;
        let job = env.call_static_method(class, "beginApprovalJob",
            "(JLjava/lang/String;Ljava/lang/String;Ljava/lang/String;[BJJZ)Lio/nikodesk/android/voice/NikoVoiceApprovalJob;",
            &[JValue::Long(revision),JValue::Object(input.as_ref()),JValue::Object(output.as_ref()),JValue::Object(format.as_ref()),
              JValue::Object(nonce.as_ref()),JValue::Long(call.epoch),JValue::Long(call.lease),JValue::Bool(background as u8)])
            .and_then(|v|v.l()).map_err(|_|error())?;
        if job.is_null() {
            return Err(error());
        }
        env.new_global_ref(job).map_err(|_| error())
    })
}
pub(super) fn cancel_job(job: &GlobalRef) -> Result<(), VoiceError> {
    with_env(|env, _| {
        env.call_method(job.as_obj(), "cancel", "()V", &[])
            .map_err(|_| error())?;
        Ok(())
    })
}
pub(super) fn job_string(job: &GlobalRef, name: &str) -> Result<String, VoiceError> {
    with_env(|env, _| {
        let value = env
            .call_method(job.as_obj(), name, "()Ljava/lang/String;", &[])
            .and_then(|v| v.l())
            .map_err(|_| error())?;
        let value = JString::from(value);
        let text: String = env.get_string(&value).map_err(|_| error())?.into();
        if text.len() > 128 {
            return Err(VoiceError::Unsupported);
        }
        Ok(text)
    })
}
