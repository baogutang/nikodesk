use super::*;
use std::{
    fs::{self, File, OpenOptions},
    io::{Read, Write},
    os::windows::{
        ffi::OsStrExt,
        fs::{MetadataExt, OpenOptionsExt},
        io::{AsRawHandle, FromRawHandle},
    },
    path::Path,
    time::{Duration, Instant},
};
use windows::{
    core::{BOOL, PCWSTR},
    Win32::{
        Foundation::{LocalFree, HANDLE, HLOCAL},
        Security::{
            Authorization::{
                ConvertStringSecurityDescriptorToSecurityDescriptorW, ConvertStringSidToSidW,
                GetSecurityInfo, SetSecurityInfo, SE_FILE_OBJECT,
            },
            EqualSid, GetSecurityDescriptorDacl, ACL, DACL_SECURITY_INFORMATION,
            OWNER_SECURITY_INFORMATION, PROTECTED_DACL_SECURITY_INFORMATION, PSECURITY_DESCRIPTOR,
            PSID, SECURITY_ATTRIBUTES,
        },
        Storage::FileSystem::{
            CreateDirectoryW, CreateFileW, GetFileInformationByHandle, MoveFileExW,
            BY_HANDLE_FILE_INFORMATION, CREATE_NEW, FILE_FLAG_BACKUP_SEMANTICS,
            FILE_FLAG_OPEN_REPARSE_POINT, FILE_GENERIC_READ, FILE_GENERIC_WRITE, FILE_SHARE_DELETE,
            FILE_SHARE_MODE, FILE_SHARE_READ, FILE_SHARE_WRITE, MOVEFILE_REPLACE_EXISTING,
            MOVEFILE_WRITE_THROUGH, READ_CONTROL, WRITE_DAC,
        },
    },
};

// Winnt.h ACCESS_MASK value; avoids adding the SystemServices SDK feature.
const MAXIMUM_ALLOWED: u32 = 0x0200_0000;

pub(super) struct Lock {
    _file: File,
}
struct LocalAllocation(*mut std::ffi::c_void);
impl Drop for LocalAllocation {
    fn drop(&mut self) {
        unsafe {
            let _ = LocalFree(Some(HLOCAL(self.0)));
        }
    }
}

fn wide(path: &Path) -> Vec<u16> {
    path.as_os_str()
        .encode_wide()
        .chain(std::iter::once(0))
        .collect()
}

// TOKEN_OWNER can be a group even when TokenUser is the current account.
// Specify the current user at creation; never take ownership of existing storage.
fn private_creation_descriptor() -> ResultType<LocalAllocation> {
    let user = crate::platform::windows::current_process_user_sid_string()?;
    let descriptor = format!("O:{user}D:P(A;OICI;FA;;;{user})")
        .encode_utf16()
        .chain(std::iter::once(0))
        .collect::<Vec<_>>();
    let mut security = PSECURITY_DESCRIPTOR::default();
    unsafe {
        ConvertStringSecurityDescriptorToSecurityDescriptorW(
            PCWSTR(descriptor.as_ptr()),
            1,
            &mut security,
            None,
        )?;
    }
    Ok(LocalAllocation(security.0))
}

fn creation_attributes(descriptor: &LocalAllocation) -> SECURITY_ATTRIBUTES {
    SECURITY_ATTRIBUTES {
        nLength: std::mem::size_of::<SECURITY_ATTRIBUTES>() as u32,
        lpSecurityDescriptor: descriptor.0,
        bInheritHandle: BOOL(0),
    }
}

fn create_private_directory(path: &Path) -> ResultType<()> {
    check_path(path)?;
    let descriptor = private_creation_descriptor()?;
    let attributes = creation_attributes(&descriptor);
    unsafe {
        CreateDirectoryW(PCWSTR(wide(path).as_ptr()), Some(&attributes))?;
    }
    Ok(())
}

fn create_private_file(path: &Path, access: u32, share: FILE_SHARE_MODE) -> ResultType<File> {
    check_path(path)?;
    let descriptor = private_creation_descriptor()?;
    let attributes = creation_attributes(&descriptor);
    let handle = unsafe {
        CreateFileW(
            PCWSTR(wide(path).as_ptr()),
            access,
            share,
            Some(&attributes),
            CREATE_NEW,
            FILE_FLAG_OPEN_REPARSE_POINT,
            None,
        )?
    };
    // CreateFileW succeeded with CREATE_NEW; File now owns this handle.
    Ok(unsafe { File::from_raw_handle(handle.0) })
}

fn win32_error_is(error: &hbb_common::anyhow::Error, code: u32) -> bool {
    error
        .downcast_ref::<std::io::Error>()
        .is_some_and(|error| error.raw_os_error() == Some(code as i32))
        || error
            .downcast_ref::<windows::core::Error>()
            .is_some_and(|error| error.code() == windows::core::HRESULT::from_win32(code))
}

fn ensure_private_directory(path: &Path) -> ResultType<()> {
    check_path(path)?;
    if !path.exists() {
        match create_private_directory(path) {
            Ok(()) => {}
            // Another initializer may have created it. Verify its actual owner below.
            Err(error) if win32_error_is(&error, 183) => {}
            Err(error) => return Err(error),
        }
    }
    restrict_to_current_user(path)
}

fn check_path(path: &Path) -> ResultType<()> {
    if !path.is_absolute() {
        bail!("NikoDesk storage path must be absolute");
    }
    for ancestor in path.ancestors() {
        match fs::symlink_metadata(ancestor) {
            Ok(meta) if meta.file_attributes() & 0x400 != 0 => {
                bail!("NikoDesk storage cannot use a reparse point");
            }
            Ok(_) => {}
            Err(err) if err.kind() == std::io::ErrorKind::NotFound && ancestor == path => {}
            Err(err) => return Err(err.into()),
        }
    }
    Ok(())
}

fn restrict_to_current_user(path: &Path) -> ResultType<()> {
    check_path(path)?;
    let file = OpenOptions::new()
        // SetSecurityInfo does not propagate ACEs to existing children when
        // the handle uses MAXIMUM_ALLOWED. Restrict only this owned object;
        // never change a pre-existing alias through directory inheritance.
        .access_mode(MAXIMUM_ALLOWED)
        .custom_flags(FILE_FLAG_BACKUP_SEMANTICS.0 | FILE_FLAG_OPEN_REPARSE_POINT.0)
        .open(path)?;
    restrict_handle_to_current_user(&file)
}

fn owned_user_sid(file: &File) -> ResultType<String> {
    let user = crate::platform::windows::current_process_user_sid_string()?;
    let user_wide = user
        .encode_utf16()
        .chain(std::iter::once(0))
        .collect::<Vec<_>>();
    let mut expected = PSID::default();
    unsafe {
        ConvertStringSidToSidW(PCWSTR(user_wide.as_ptr()), &mut expected)?;
    }
    let _expected_guard = LocalAllocation(expected.0);
    let handle = HANDLE(file.as_raw_handle());
    let mut owner = PSID::default();
    let mut security = PSECURITY_DESCRIPTOR::default();
    let status = unsafe {
        GetSecurityInfo(
            handle,
            SE_FILE_OBJECT,
            OWNER_SECURITY_INFORMATION,
            Some(&mut owner),
            None,
            None,
            None,
            Some(&mut security),
        )
    };
    let _owner_guard = LocalAllocation(security.0);
    if status.0 != 0 || owner.0.is_null() {
        bail!("Cannot verify NikoDesk storage ownership");
    }
    unsafe { EqualSid(owner, expected) }
        .map_err(|_| anyhow!("NikoDesk storage belongs to another user"))?;
    Ok(user)
}

fn restrict_handle_to_current_user(file: &File) -> ResultType<()> {
    let metadata = file.metadata()?;
    if metadata.file_attributes() & 0x400 != 0 || (!metadata.is_dir() && !metadata.is_file()) {
        bail!("Invalid NikoDesk storage object");
    }
    if metadata.is_file() {
        check_file(file, u64::MAX)?;
    }
    let user = owned_user_sid(file)?;
    let handle = HANDLE(file.as_raw_handle());
    let descriptor = format!("D:P(A;OICI;FA;;;{user})")
        .encode_utf16()
        .chain(std::iter::once(0))
        .collect::<Vec<_>>();
    let mut dacl = PSECURITY_DESCRIPTOR::default();
    unsafe {
        ConvertStringSecurityDescriptorToSecurityDescriptorW(
            PCWSTR(descriptor.as_ptr()),
            1,
            &mut dacl,
            None,
        )?;
    }
    let _dacl_guard = LocalAllocation(dacl.0);
    let mut present = BOOL::default();
    let mut defaulted = BOOL::default();
    let mut acl: *mut ACL = std::ptr::null_mut();
    unsafe {
        GetSecurityDescriptorDacl(dacl, &mut present, &mut acl, &mut defaulted)?;
    }
    if !present.as_bool() || acl.is_null() {
        bail!("Invalid NikoDesk private DACL");
    }
    let status = unsafe {
        SetSecurityInfo(
            handle,
            SE_FILE_OBJECT,
            DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION,
            None,
            None,
            Some(acl),
            None,
        )
    };
    if status.0 != 0 {
        return Err(std::io::Error::from_raw_os_error(status.0 as i32).into());
    }
    Ok(())
}

fn check_file(file: &File, limit: u64) -> ResultType<()> {
    let metadata = file.metadata()?;
    if !metadata.is_file() || metadata.file_attributes() & 0x400 != 0 || metadata.len() > limit {
        bail!("Invalid NikoDesk private file");
    }
    let mut info = BY_HANDLE_FILE_INFORMATION::default();
    unsafe {
        GetFileInformationByHandle(HANDLE(file.as_raw_handle()), &mut info)?;
    }
    if info.nNumberOfLinks != 1 {
        bail!("NikoDesk private files cannot be hard links");
    }
    Ok(())
}

pub(super) fn read_private_file(path: &Path, limit: u64) -> ResultType<String> {
    check_path(path)?;
    let mut file = OpenOptions::new()
        .read(true)
        .access_mode(FILE_GENERIC_READ.0 | WRITE_DAC.0)
        .custom_flags(FILE_FLAG_OPEN_REPARSE_POINT.0)
        .open(path)?;
    check_file(&file, limit)?;
    restrict_handle_to_current_user(&file)?;
    let mut contents = String::new();
    file.read_to_string(&mut contents)?;
    Ok(contents)
}

// Legacy preference sources remain read-only, including their original ACL.
pub(super) fn read_owned_file(path: &Path, limit: u64) -> ResultType<Vec<u8>> {
    check_path(path)?;
    let file = OpenOptions::new()
        .access_mode(FILE_GENERIC_READ.0 | READ_CONTROL.0)
        .custom_flags(FILE_FLAG_OPEN_REPARSE_POINT.0)
        .open(path)?;
    check_file(&file, limit)?;
    owned_user_sid(&file)?;
    let mut bytes = Vec::new();
    file.take(limit.saturating_add(1)).read_to_end(&mut bytes)?;
    if bytes.len() as u64 > limit {bail!("storage_file_too_large");}
    Ok(bytes)
}

pub(super) fn write_private_file(path: &Path, contents: &[u8]) -> ResultType<()> {
    let directory = path
        .parent()
        .ok_or_else(|| anyhow!("Invalid NikoDesk file path"))?;
    restrict_to_current_user(directory)?;
    check_path(path)?;
    if path.exists() {
        let existing = OpenOptions::new()
            .read(true)
            .access_mode(FILE_GENERIC_READ.0 | WRITE_DAC.0)
            .custom_flags(FILE_FLAG_OPEN_REPARSE_POINT.0)
            .open(path)?;
        check_file(&existing, 1024 * 1024)?;
        restrict_handle_to_current_user(&existing)?;
    }
    let temporary = directory.join(format!(
        ".nikodesk-{}.tmp",
        hbb_common::uuid::Uuid::new_v4()
    ));
    // A failed CREATE_NEW must not remove a colliding pre-existing object.
    let mut file = create_private_file(
        &temporary,
        FILE_GENERIC_WRITE.0 | READ_CONTROL.0 | WRITE_DAC.0,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
    )?;
    let result = (|| -> ResultType<()> {
        file.write_all(contents)?;
        file.sync_all()?;
        restrict_handle_to_current_user(&file)?;
        drop(file);
        unsafe {
            MoveFileExW(
                PCWSTR(wide(&temporary).as_ptr()),
                PCWSTR(wide(path).as_ptr()),
                MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH,
            )?;
        }
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result
}

// Publish a complete private file only if the destination is still absent.
// MoveFileEx without REPLACE_EXISTING resolves concurrent publishers in the OS.
pub(super) fn publish_private_file(path: &Path, contents: &[u8]) -> ResultType<bool> {
    if contents.len() > 1024 * 1024 {bail!("storage_file_too_large");}
    let directory = path.parent().ok_or_else(|| anyhow!("Invalid NikoDesk file path"))?;
    restrict_to_current_user(directory)?;
    check_path(path)?;
    let temporary = directory.join(format!(".nikodesk-import-{}.tmp", hbb_common::uuid::Uuid::new_v4()));
    let mut file = create_private_file(
        &temporary,
        FILE_GENERIC_WRITE.0 | READ_CONTROL.0 | WRITE_DAC.0,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
    )?;
    let result = (|| -> ResultType<bool> {
        file.write_all(contents)?;
        file.sync_all()?;
        restrict_handle_to_current_user(&file)?;
        drop(file);
        match unsafe {
            MoveFileExW(PCWSTR(wide(&temporary).as_ptr()), PCWSTR(wide(path).as_ptr()), MOVEFILE_WRITE_THROUGH)
        } {
            Ok(()) => Ok(true),
            Err(error) if matches!(error.code(), code if
                code == windows::core::HRESULT::from_win32(80) ||
                code == windows::core::HRESULT::from_win32(183)) => Ok(false),
            Err(error) => Err(error.into()),
        }
    })();
    // CREATE_NEW above proved this temporary file belongs to this operation.
    if !matches!(result, Ok(true)) {
        fs::remove_file(&temporary)?;
    }
    result
}

pub(super) fn read(path: &Path) -> ResultType<Identity> {
    let identity: Identity = toml::from_str(&read_private_file(path, 128 * 1024)?)
        .map_err(|_| anyhow!("NikoDesk identity file is damaged; original file preserved"))?;
    identity.validate_keys()?;
    Ok(identity)
}

pub(super) fn prepare(path: &Path) -> ResultType<(Lock, Identity)> {
    let directory = path
        .parent()
        .ok_or_else(|| anyhow!("Invalid NikoDesk identity path"))?;
    let parent = directory
        .parent()
        .ok_or_else(|| anyhow!("Invalid NikoDesk configuration directory"))?;
    ensure_private_directory(parent)?;
    ensure_private_directory(directory)?;
    let lock_path = directory.join("identity.lock");
    check_path(&lock_path)?;
    let deadline = Instant::now() + Duration::from_secs(3);
    let lock_file = loop {
        let access = FILE_GENERIC_READ.0 | FILE_GENERIC_WRITE.0 | WRITE_DAC.0;
        let opened = match create_private_file(&lock_path, access, FILE_SHARE_MODE(0)) {
            Err(error) if win32_error_is(&error, 80) || win32_error_is(&error, 183) => {
                // Never assign a descriptor/owner to an existing lock.
                OpenOptions::new()
                    .access_mode(access)
                    .share_mode(0)
                    .custom_flags(FILE_FLAG_OPEN_REPARSE_POINT.0)
                    .open(&lock_path)
                    .map_err(Into::into)
            }
            result => result,
        };
        match opened {
            Ok(file) => break file,
            Err(err)
                if (win32_error_is(&err, 32) || win32_error_is(&err, 33))
                    && Instant::now() < deadline =>
            {
                std::thread::sleep(Duration::from_millis(25));
            }
            Err(err) => return Err(err),
        }
    };
    check_file(&lock_file, 128 * 1024)?;
    restrict_handle_to_current_user(&lock_file)?;
    let lock = Lock { _file: lock_file };
    match fs::symlink_metadata(path) {
        Ok(_) => return Ok((lock, read(path)?)),
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => {}
        Err(err) => return Err(err.into()),
    }
    let (pk, sk) = sign::gen_keypair();
    let identity = Identity {
        id: rand::thread_rng()
            .gen_range(1_000_000_000u32..2_000_000_000)
            .to_string(),
        enc_id: String::new(),
        key_pair: (sk.0.to_vec(), pk.0.to_vec()),
    };
    write_private_file(path, toml::to_string(&identity)?.as_bytes())?;
    Ok((lock, identity))
}

#[cfg(test)]
mod tests {
    use super::*;
    use windows::Win32::{
        Foundation::CloseHandle,
        Security::{
            Authorization::ConvertSecurityDescriptorToStringSecurityDescriptorW, GetAce,
            GetSecurityDescriptorControl, GetSecurityDescriptorOwner, GetTokenInformation,
            TokenOwner, ACCESS_ALLOWED_ACE, SE_DACL_PROTECTED, TOKEN_OWNER, TOKEN_QUERY,
        },
        Storage::FileSystem::FILE_ALL_ACCESS,
        System::Threading::{GetCurrentProcess, OpenProcessToken},
    };
    struct Temp(std::path::PathBuf);
    impl Temp {
        fn new() -> Self {
            let path = std::env::temp_dir().join(format!(
                "nikodesk-windows-test-{}",
                hbb_common::uuid::Uuid::new_v4()
            ));
            create_private_directory(&path).unwrap();
            Self(path)
        }
    }
    impl Drop for Temp {
        fn drop(&mut self) {
            fs::remove_dir_all(&self.0).unwrap();
        }
    }

    fn security_snapshot(file: &File) -> (LocalAllocation, PSID) {
        let mut owner = PSID::default();
        let mut security = PSECURITY_DESCRIPTOR::default();
        let result = unsafe {
            GetSecurityInfo(
                HANDLE(file.as_raw_handle()),
                SE_FILE_OBJECT,
                OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION,
                Some(&mut owner),
                None,
                None,
                None,
                Some(&mut security),
            )
        };
        assert_eq!(result.0, 0);
        assert!(!security.0.is_null());
        (LocalAllocation(security.0), owner)
    }

    fn open_for_security(path: &Path) -> File {
        OpenOptions::new()
            .access_mode(READ_CONTROL.0)
            .custom_flags(FILE_FLAG_BACKUP_SEMANTICS.0 | FILE_FLAG_OPEN_REPARSE_POINT.0)
            .open(path)
            .unwrap()
    }

    fn assert_private_creation(file: &File) {
        let (security, actual_owner) = security_snapshot(file);
        let expected = private_creation_descriptor().unwrap();
        let mut expected_owner = PSID::default();
        let mut defaulted = BOOL::default();
        unsafe {
            GetSecurityDescriptorOwner(
                PSECURITY_DESCRIPTOR(expected.0),
                &mut expected_owner,
                &mut defaulted,
            )
            .unwrap();
            EqualSid(actual_owner, expected_owner).unwrap();
            let mut control = 0;
            let mut revision = 0;
            GetSecurityDescriptorControl(
                PSECURITY_DESCRIPTOR(security.0),
                &mut control,
                &mut revision,
            )
            .unwrap();
            assert_ne!(control & SE_DACL_PROTECTED.0, 0);
            let mut present = BOOL::default();
            let mut acl: *mut ACL = std::ptr::null_mut();
            GetSecurityDescriptorDacl(
                PSECURITY_DESCRIPTOR(security.0),
                &mut present,
                &mut acl,
                &mut defaulted,
            )
            .unwrap();
            assert!(present.as_bool() && !acl.is_null());
            assert_eq!((*acl).AceCount, 1);
            let mut entry = std::ptr::null_mut();
            GetAce(acl, 0, &mut entry).unwrap();
            let ace = &*(entry as *const ACCESS_ALLOWED_ACE);
            assert_eq!(ace.Header.AceType, 0); // ACCESS_ALLOWED_ACE_TYPE
            assert_eq!(ace.Mask, FILE_ALL_ACCESS.0);
            EqualSid(
                PSID(std::ptr::addr_of!(ace.SidStart) as *mut _),
                expected_owner,
            )
            .unwrap();
        }
    }

    #[test]
    fn nikodesk_windows_new_objects_have_user_owner_and_private_protected_dacl() {
        let temp = Temp::new();
        assert_private_creation(&open_for_security(&temp.0));
        let path = temp.0.join("config/NikoDesk.toml");
        let (lock, _) = prepare(&path).unwrap();
        assert_private_creation(&open_for_security(&temp.0.join("config")));
        assert_private_creation(&lock._file);
        assert_private_creation(&open_for_security(&path));
        drop(lock);
        write_private_file(&path, b"replacement").unwrap();
        assert_private_creation(&open_for_security(&path));
    }

    #[test]
    fn nikodesk_windows_create_new_never_overwrites_an_existing_object() {
        let temp = Temp::new();
        assert!(create_private_directory(&temp.0).is_err());
        let path = temp.0.join("existing");
        write_private_file(&path, b"original").unwrap();
        assert!(create_private_file(&path, FILE_GENERIC_WRITE.0, FILE_SHARE_MODE(0)).is_err());
        assert_eq!(fs::read(&path).unwrap(), b"original");
        assert_private_creation(&open_for_security(&path));
    }

    #[test]
    fn nikodesk_windows_atomic_publish_race_keeps_one_complete_private_winner() {
        let temp = Temp::new();
        let path = temp.0.join("preferences.toml");
        let barrier = std::sync::Arc::new(std::sync::Barrier::new(2));
        let tasks = [b"first-whole-file".as_slice(), b"second-whole-file".as_slice()]
            .into_iter().map(|bytes| {
                let path = path.clone();
                let barrier = barrier.clone();
                std::thread::spawn(move || {
                    barrier.wait();
                    publish_private_file(&path, bytes).unwrap()
                })
            }).collect::<Vec<_>>();
        let published = tasks.into_iter().map(|task| task.join().unwrap()).filter(|published| *published).count();
        assert_eq!(published, 1);
        let value = read_private_file(&path, 1024).unwrap();
        assert!(value == "first-whole-file" || value == "second-whole-file");
        assert_private_creation(&open_for_security(&path));
        assert_eq!(fs::read_dir(&temp.0).unwrap().count(), 1);
    }

    #[test]
    fn nikodesk_windows_existing_default_owner_is_checked_without_reassignment() {
        let temp = Temp::new();
        let path = temp.0.join("default-owner");
        // This object is a new fixture only, created with the token's default owner.
        fs::create_dir(&path).unwrap();
        let file = open_for_security(&path);
        let (security, actual_owner) = security_snapshot(&file);
        let descriptor_string = |security: &LocalAllocation| unsafe {
            let mut text = windows::core::PWSTR::null();
            ConvertSecurityDescriptorToStringSecurityDescriptorW(
                PSECURITY_DESCRIPTOR(security.0),
                1,
                OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION,
                &mut text,
                None,
            )
            .unwrap();
            let _allocation = LocalAllocation(text.0 as *mut _);
            text.to_string().unwrap()
        };
        let before = descriptor_string(&security);
        let mut token = HANDLE::default();
        unsafe {
            OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token).unwrap();
        }
        let mut required = 0;
        let result = (|| -> ResultType<bool> {
            unsafe {
                let _ = GetTokenInformation(token, TokenOwner, None, 0, &mut required);
                assert!(required > 0 && required <= 1024 * 1024);
                let mut buffer = vec![
                    0usize;
                    (required as usize + std::mem::size_of::<usize>() - 1)
                        / std::mem::size_of::<usize>()
                ];
                GetTokenInformation(
                    token,
                    TokenOwner,
                    Some(buffer.as_mut_ptr().cast()),
                    required,
                    &mut required,
                )?;
                let default_owner = &*(buffer.as_ptr() as *const TOKEN_OWNER);
                EqualSid(actual_owner, default_owner.Owner)?;
                let expected = private_creation_descriptor()?;
                let mut user = PSID::default();
                let mut defaulted = BOOL::default();
                GetSecurityDescriptorOwner(
                    PSECURITY_DESCRIPTOR(expected.0),
                    &mut user,
                    &mut defaulted,
                )?;
                Ok(EqualSid(actual_owner, user).is_ok())
            }
        })();
        unsafe {
            CloseHandle(token).unwrap();
        }
        let owned_by_current_user = result.unwrap();
        eprintln!(
            "TOKEN_OWNER differs from TokenUser: {}",
            !owned_by_current_user
        );
        assert_eq!(
            restrict_to_current_user(&path).is_ok(),
            owned_by_current_user
        );
        if !owned_by_current_user {
            // Elevated CI exercises this branch; the original owner and ACL must survive.
            let (after, _) = security_snapshot(&file);
            assert_eq!(descriptor_string(&after), before);
        }
    }

    #[test]
    fn nikodesk_windows_identity_is_reused_without_network_or_services() {
        let temp = Temp::new();
        let path = temp.0.join("config/NikoDesk.toml");
        let (lock, first) = prepare(&path).unwrap();
        let expected = first.validated_id().unwrap();
        drop(lock);
        let (_lock, next) = prepare(&path).unwrap();
        assert_eq!(next.validated_id().unwrap(), expected);
        assert_eq!(next.key_pair, first.key_pair);
    }

    #[test]
    fn nikodesk_windows_concurrent_initialization_waits_for_the_identity_lock() {
        let temp = Temp::new();
        let path = temp.0.join("config/NikoDesk.toml");
        let (lock, first) = prepare(&path).unwrap();
        let expected_id = first.validated_id().unwrap();
        let expected_keys = first.key_pair;
        let barrier = std::sync::Arc::new(std::sync::Barrier::new(2));
        let child_barrier = barrier.clone();
        let next = std::thread::spawn(move || {
            child_barrier.wait();
            let (_lock, identity) = prepare(&path).unwrap();
            (identity.validated_id().unwrap(), identity.key_pair)
        });
        barrier.wait();
        std::thread::sleep(Duration::from_millis(100));
        drop(lock);
        assert_eq!(next.join().unwrap(), (expected_id, expected_keys));
    }

    #[test]
    fn nikodesk_windows_settings_reject_hardlink_aliases_and_preserve_them() {
        let temp = Temp::new();
        restrict_to_current_user(&temp.0).unwrap();
        let path = temp.0.join("settings.toml");
        write_private_file(&path, b"[options]\nkey = 'original'\n").unwrap();
        fs::hard_link(&path, temp.0.join("alias")).unwrap();
        assert!(read_private_file(&path, 1024).is_err());
        assert!(write_private_file(&path, b"replacement").is_err());
        assert_eq!(
            fs::read_to_string(path).unwrap(),
            "[options]\nkey = 'original'\n"
        );
    }

    #[test]
    fn nikodesk_windows_damaged_identity_is_never_replaced() {
        let temp = Temp::new();
        let path = temp.0.join("config/NikoDesk.toml");
        let (lock, _) = prepare(&path).unwrap();
        drop(lock);
        fs::write(&path, b"damaged identity").unwrap();
        assert!(prepare(&path).is_err());
        assert_eq!(fs::read(path).unwrap(), b"damaged identity");
    }
}
