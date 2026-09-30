//! Ordinary-user CM boundary. Facts come from the kernel peer, never DTOs.
#[cfg(unix)]
use hbb_common::anyhow::anyhow;
use hbb_common::{bail, ResultType};
#[cfg(unix)]
pub(crate) fn verify_unix(uid: Option<u32>, pid: Option<u32>) -> ResultType<()> {
    use std::{fs, os::unix::fs::MetadataExt};
    let ours = unsafe { hbb_common::libc::geteuid() };
    if ours == 0 || uid != Some(ours) {
        bail!("cm_peer_user_mismatch");
    }
    let pid = pid
        .filter(|pid| *pid > 0)
        .ok_or_else(|| anyhow!("cm_peer_pid_unavailable"))?;
    #[cfg(target_os = "linux")]
    let peer = fs::canonicalize(fs::read_link(format!("/proc/{}/exe", pid))?)?;
    #[cfg(target_os = "macos")]
    let peer = {
        let mut bytes = vec![0u8; hbb_common::libc::PROC_PIDPATHINFO_MAXSIZE as usize];
        let length = unsafe {
            hbb_common::libc::proc_pidpath(pid as _, bytes.as_mut_ptr() as _, bytes.len() as _)
        };
        if length <= 0 {
            bail!("cm_peer_image_unavailable");
        }
        bytes.truncate(length as usize);
        fs::canonicalize(String::from_utf8(bytes).map_err(|_| anyhow!("cm_peer_image_invalid"))?)?
    };
    let current = fs::canonicalize(std::env::current_exe()?)?;
    #[cfg(target_os = "linux")]
    let (a, b) = (
        fs::metadata(format!("/proc/{}/exe", pid))?,
        fs::metadata("/proc/self/exe")?,
    );
    #[cfg(target_os = "macos")]
    let (a, b) = (fs::metadata(&peer)?, fs::metadata(&current)?);
    if peer != current
        || !a.is_file()
        || a.dev() != b.dev()
        || a.ino() != b.ino()
        || a.nlink() != 1
        || b.nlink() != 1
    {
        bail!("cm_peer_image_mismatch");
    }
    #[cfg(target_os = "macos")]
    verify_macos_code(pid)?;
    Ok(())
}
#[cfg(target_os = "macos")]
fn verify_macos_code(pid: u32) -> ResultType<()> {
    use core_foundation::{
        base::{CFType, CFTypeRef, TCFType},
        data::CFData,
        dictionary::{CFDictionary, CFDictionaryRef},
        number::CFNumber,
        string::{CFString, CFStringRef},
    };
    type Code = CFTypeRef;
    #[link(name = "Security", kind = "framework")]
    extern "C" {
        static kSecGuestAttributePid: CFStringRef;
        static kSecCodeInfoUnique: CFStringRef;
        fn SecCodeCopyGuestWithAttributes(
            host: Code,
            attributes: CFDictionaryRef,
            flags: u32,
            code: *mut Code,
        ) -> i32;
        fn SecCodeCopySelf(flags: u32, code: *mut Code) -> i32;
        fn SecCodeCheckValidity(code: Code, flags: u32, requirement: CFTypeRef) -> i32;
        fn SecCodeCopySigningInformation(
            code: Code,
            flags: u32,
            information: *mut CFDictionaryRef,
        ) -> i32;
    }
    struct OwnedCode(Code);
    impl Drop for OwnedCode {
        fn drop(&mut self) {
            unsafe {
                core_foundation::base::CFRelease(self.0);
            }
        }
    }
    fn code_hash(code: Code) -> ResultType<Vec<u8>> {
        let mut information = std::ptr::null();
        unsafe {
            if SecCodeCopySigningInformation(code, 0, &mut information) != 0
                || information.is_null()
            {
                bail!("cm_code_hash_unavailable");
            }
            let information = CFDictionary::<CFString, CFType>::wrap_under_create_rule(information);
            let key = CFString::wrap_under_get_rule(kSecCodeInfoUnique);
            let data = information
                .find(&key)
                .and_then(|value| value.downcast::<CFData>())
                .ok_or_else(|| anyhow!("cm_code_hash_unavailable"))?;
            if data.bytes().is_empty() {
                bail!("cm_code_hash_unavailable");
            }
            Ok(data.bytes().to_vec())
        }
    }
    let attributes = unsafe {
        CFDictionary::from_CFType_pairs(&[(
            CFString::wrap_under_get_rule(kSecGuestAttributePid).as_CFType(),
            CFNumber::from(pid as i64).as_CFType(),
        )])
    };
    let mut peer = std::ptr::null();
    let mut own = std::ptr::null();
    unsafe {
        if SecCodeCopyGuestWithAttributes(
            std::ptr::null(),
            attributes.as_concrete_TypeRef(),
            0,
            &mut peer,
        ) != 0
            || peer.is_null()
        {
            bail!("cm_peer_code_identity_unavailable");
        }
        let peer = OwnedCode(peer);
        if SecCodeCopySelf(0, &mut own) != 0 || own.is_null() {
            bail!("cm_local_code_identity_unavailable");
        }
        let own = OwnedCode(own);
        if SecCodeCheckValidity(peer.0, 0, std::ptr::null()) != 0
            || SecCodeCheckValidity(own.0, 0, std::ptr::null()) != 0
        {
            bail!("cm_code_signature_invalid");
        }
        if code_hash(peer.0)? != code_hash(own.0)? {
            bail!("cm_running_code_mismatch");
        }
    }
    Ok(())
}

#[cfg(windows)]
mod win {
    use super::*;
    use std::{
        fs,
        os::windows::{fs::OpenOptionsExt, io::AsRawHandle},
        path::{Path, PathBuf},
    };
    use windows::{
        core::PWSTR,
        Win32::{
            Foundation::{CloseHandle, HANDLE},
            Security::{
                EqualSid, GetTokenInformation, TokenElevation, TokenSessionId, TokenUser,
                TOKEN_ELEVATION, TOKEN_QUERY, TOKEN_USER,
            },
            Storage::FileSystem::{
                GetFileInformationByHandle, BY_HANDLE_FILE_INFORMATION,
                FILE_FLAG_OPEN_REPARSE_POINT, FILE_SHARE_READ,
            },
            System::{
                Pipes::{GetNamedPipeClientProcessId, GetNamedPipeServerProcessId},
                RemoteDesktop::WTSGetActiveConsoleSessionId,
                Threading::{
                    GetCurrentProcess, OpenProcess, OpenProcessToken, QueryFullProcessImageNameW,
                    PROCESS_NAME_WIN32, PROCESS_QUERY_LIMITED_INFORMATION,
                },
            },
        },
    };
    struct Owned(HANDLE);
    impl Drop for Owned {
        fn drop(&mut self) {
            unsafe {
                let _ = CloseHandle(self.0);
            }
        }
    }
    fn token(process: HANDLE) -> ResultType<Owned> {
        let mut token = HANDLE::default();
        unsafe {
            OpenProcessToken(process, TOKEN_QUERY, &mut token)?;
        }
        Ok(Owned(token))
    }
    fn information(
        token: HANDLE,
        class: windows::Win32::Security::TOKEN_INFORMATION_CLASS,
    ) -> ResultType<Vec<usize>> {
        let mut length = 0;
        unsafe {
            let _ = GetTokenInformation(token, class, None, 0, &mut length);
        }
        if length == 0 || length > 64 * 1024 {
            bail!("cm_token_information_invalid");
        }
        let mut words = vec![
            0usize;
            (length as usize + std::mem::size_of::<usize>() - 1)
                / std::mem::size_of::<usize>()
        ];
        unsafe {
            GetTokenInformation(
                token,
                class,
                Some(words.as_mut_ptr().cast()),
                length,
                &mut length,
            )?;
        }
        Ok(words)
    }
    fn ordinary(token: HANDLE) -> ResultType<u32> {
        let elevation = information(token, TokenElevation)?;
        let session = information(token, TokenSessionId)?;
        let elevated =
            unsafe { std::ptr::read_unaligned(elevation.as_ptr().cast::<TOKEN_ELEVATION>()) };
        let session = unsafe { std::ptr::read_unaligned(session.as_ptr().cast::<u32>()) };
        if elevated.TokenIsElevated != 0
            || session == 0
            || session != unsafe { WTSGetActiveConsoleSessionId() }
        {
            bail!("cm_ordinary_interactive_token_required");
        }
        Ok(session)
    }
    struct Image {
        _file: fs::File,
        information: BY_HANDLE_FILE_INFORMATION,
    }
    fn image(path: &Path) -> ResultType<Image> {
        use std::os::windows::fs::MetadataExt;
        let mut part = PathBuf::new();
        for component in path.components() {
            part.push(component.as_os_str());
            if fs::symlink_metadata(&part)?.file_attributes() & 0x400 != 0 {
                bail!("cm_image_reparse_point");
            }
        }
        let file = fs::OpenOptions::new()
            .read(true)
            .share_mode(FILE_SHARE_READ.0)
            .custom_flags(FILE_FLAG_OPEN_REPARSE_POINT.0)
            .open(path)?;
        let mut information = BY_HANDLE_FILE_INFORMATION::default();
        unsafe {
            GetFileInformationByHandle(HANDLE(file.as_raw_handle()), &mut information)?;
        }
        if information.nNumberOfLinks != 1 || information.dwFileAttributes & 0x400 != 0 {
            bail!("cm_image_unsafe_link");
        }
        Ok(Image {
            _file: file,
            information,
        })
    }
    pub(super) fn verify(pipe: HANDLE, server_side: bool) -> ResultType<()> {
        let mut pid = 0;
        unsafe {
            if server_side {
                GetNamedPipeClientProcessId(pipe, &mut pid)?;
            } else {
                GetNamedPipeServerProcessId(pipe, &mut pid)?;
            }
        }
        if pid == 0 {
            bail!("cm_peer_pid_unavailable");
        }
        let process = Owned(unsafe { OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid)? });
        let peer = token(process.0)?;
        let current = token(unsafe { GetCurrentProcess() })?;
        if ordinary(peer.0)? != ordinary(current.0)? {
            bail!("cm_peer_session_mismatch");
        }
        let peer_user = information(peer.0, TokenUser)?;
        let own_user = information(current.0, TokenUser)?;
        let peer_user =
            unsafe { std::ptr::read_unaligned(peer_user.as_ptr().cast::<TOKEN_USER>()) };
        let own_user = unsafe { std::ptr::read_unaligned(own_user.as_ptr().cast::<TOKEN_USER>()) };
        if peer_user.User.Sid.0.is_null()
            || own_user.User.Sid.0.is_null()
            || unsafe { EqualSid(peer_user.User.Sid, own_user.User.Sid) }.is_err()
        {
            bail!("cm_peer_sid_mismatch");
        }
        let mut path = vec![0u16; 32768];
        let mut length = path.len() as u32;
        unsafe {
            QueryFullProcessImageNameW(
                process.0,
                PROCESS_NAME_WIN32,
                PWSTR(path.as_mut_ptr()),
                &mut length,
            )?;
        }
        let peer_path = PathBuf::from(String::from_utf16(&path[..length as usize])?);
        let current_path = std::env::current_exe()?;
        if fs::canonicalize(&peer_path)? != fs::canonicalize(&current_path)? {
            bail!("cm_peer_image_mismatch");
        }
        let peer_image = image(&peer_path)?;
        let own_image = image(&current_path)?;
        if peer_image.information.dwVolumeSerialNumber != own_image.information.dwVolumeSerialNumber
            || peer_image.information.nFileIndexHigh != own_image.information.nFileIndexHigh
            || peer_image.information.nFileIndexLow != own_image.information.nFileIndexLow
        {
            bail!("cm_peer_image_file_mismatch");
        }
        Ok(())
    }
}
#[cfg(windows)]
pub(crate) fn verify_windows(
    pipe: windows::Win32::Foundation::HANDLE,
    server_side: bool,
) -> ResultType<()> {
    win::verify(pipe, server_side)
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    #[test]
    fn cm_peer_cannot_claim_a_different_kernel_user() {
        let uid = unsafe { hbb_common::libc::geteuid() };
        assert!(verify_unix(None, Some(std::process::id())).is_err());
        assert!(verify_unix(Some(if uid == 1 { 2 } else { 1 }), Some(std::process::id())).is_err());
    }
    #[test]
    fn cm_peer_missing_or_zero_kernel_pid_fails_before_image_lookup() {
        let uid = unsafe { hbb_common::libc::geteuid() };
        assert!(verify_unix(Some(uid), None).is_err());
        assert!(verify_unix(Some(uid), Some(0)).is_err());
    }
}
