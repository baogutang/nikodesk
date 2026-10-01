use super::ResultType;
use hbb_common::anyhow::anyhow;
use jni::{
    objects::{GlobalRef, JByteArray, JClass, JObject, JValue},
    JNIEnv, JavaVM,
};
use std::sync::OnceLock;

struct Runtime {
    vm: JavaVM,
    class: GlobalRef,
}
static RUNTIME: OnceLock<Runtime> = OnceLock::new();
fn unavailable() -> hbb_common::anyhow::Error {
    anyhow!("secure_credentials_unavailable")
}
fn call<T>(action: impl FnOnce(&mut JNIEnv<'_>, &JClass<'_>) -> ResultType<T>) -> ResultType<T> {
    let runtime = RUNTIME.get().ok_or_else(unavailable)?;
    let mut env = runtime
        .vm
        .attach_current_thread()
        .map_err(|_| unavailable())?;
    let result = env.with_local_frame(16, |env| {
        let class: &JClass<'_> = runtime.class.as_obj().into();
        Ok::<_, jni::errors::Error>(action(env, class))
    });
    if env.exception_check().map_err(|_| unavailable())? {
        env.exception_clear().map_err(|_| unavailable())?;
        return Err(unavailable());
    }
    result.map_err(|_| unavailable())?
}
#[no_mangle]
pub extern "system" fn Java_io_nikodesk_android_credentials_NikoCredentialBridge_nativeInitialize(
    env: JNIEnv<'_>,
    class: JClass<'_>,
) -> jni::sys::jboolean {
    let result = (|| {
        let vm = env.get_java_vm()?;
        if let Some(runtime) = RUNTIME.get() {
            return Ok::<_, jni::errors::Error>(
                runtime.vm.get_java_vm_pointer() == vm.get_java_vm_pointer()
                    && env.is_same_object(runtime.class.as_obj(), &class)?,
            );
        }
        let class = env.new_global_ref(&class)?;
        Ok(RUNTIME.set(Runtime { vm, class }).is_ok())
    })();
    if env.exception_check().unwrap_or(true) {
        let _ = env.exception_clear();
        return 0;
    }
    u8::from(result.unwrap_or(false))
}
pub(super) fn read(account: &str) -> ResultType<Option<Vec<u8>>> {
    call(|env, class| {
        let name = env.new_string(account).map_err(|_| unavailable())?;
        let object = env
            .call_static_method(
                class,
                "read",
                "(Ljava/lang/String;)[B",
                &[JValue::Object(&name)],
            )
            .and_then(|value| value.l())
            .map_err(|_| unavailable())?;
        if object.is_null() {
            return Ok(None);
        }
        let array = JByteArray::from(object);
        if env.get_array_length(&array).map_err(|_| unavailable())? > 4096 {
            return Err(unavailable());
        }
        env.convert_byte_array(array)
            .map(Some)
            .map_err(|_| unavailable())
    })
}
fn change(account: &str, value: Option<&[u8]>) -> ResultType<()> {
    call(|env, class| {
        let name = env.new_string(account).map_err(|_| unavailable())?;
        let success = if let Some(bytes) = value {
            let array = env
                .byte_array_from_slice(bytes)
                .map_err(|_| unavailable())?;
            env.call_static_method(
                class,
                "write",
                "(Ljava/lang/String;[B)Z",
                &[JValue::Object(&name), JValue::Object(&JObject::from(array))],
            )
        } else {
            env.call_static_method(
                class,
                "delete",
                "(Ljava/lang/String;)Z",
                &[JValue::Object(&name)],
            )
        }
        .and_then(|value| value.z())
        .map_err(|_| unavailable())?;
        if success {
            Ok(())
        } else {
            Err(unavailable())
        }
    })
}
pub(super) fn write(account: &str, bytes: &[u8]) -> ResultType<()> {
    change(account, Some(bytes))
}
pub(super) fn delete(account: &str) -> ResultType<()> {
    change(account, None)
}
