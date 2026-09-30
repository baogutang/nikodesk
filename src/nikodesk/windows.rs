use super::*;
use std::{
    fs::{self, File, OpenOptions},
    io::{Read, Write},
    os::windows::{
        ffi::OsStrExt,
        fs::{MetadataExt, OpenOptionsExt},
        io::AsRawHandle,
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
            PSID,
        },
        Storage::FileSystem::{
            GetFileInformationByHandle, MoveFileExW, BY_HANDLE_FILE_INFORMATION,
            FILE_FLAG_BACKUP_SEMANTICS, FILE_FLAG_OPEN_REPARSE_POINT, FILE_GENERIC_READ,
            FILE_GENERIC_WRITE, MOVEFILE_REPLACE_EXISTING, MOVEFILE_WRITE_THROUGH, READ_CONTROL,
            WRITE_DAC,
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

fn restrict_handle_to_current_user(file: &File) -> ResultType<()> {
    let metadata = file.metadata()?;
    if metadata.file_attributes() & 0x400 != 0 || (!metadata.is_dir() && !metadata.is_file()) {
        bail!("Invalid NikoDesk storage object");
    }
    if metadata.is_file() {
        check_file(file, u64::MAX)?;
    }
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
    let result = (|| -> ResultType<()> {
        let mut file = OpenOptions::new()
            .write(true)
            .access_mode(FILE_GENERIC_WRITE.0 | READ_CONTROL.0 | WRITE_DAC.0)
            .create_new(true)
            .custom_flags(FILE_FLAG_OPEN_REPARSE_POINT.0)
            .open(&temporary)?;
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
    if !parent.exists() {
        check_path(parent)?;
        fs::create_dir(parent)?;
    }
    restrict_to_current_user(parent)?;
    check_path(directory)?;
    if !directory.exists() {
        fs::create_dir(directory)?;
    }
    restrict_to_current_user(directory)?;
    let lock_path = directory.join("identity.lock");
    check_path(&lock_path)?;
    let deadline = Instant::now() + Duration::from_secs(3);
    let lock_file = loop {
        match OpenOptions::new()
            .read(true)
            .write(true)
            .access_mode(FILE_GENERIC_READ.0 | FILE_GENERIC_WRITE.0 | WRITE_DAC.0)
            .create(true)
            .share_mode(0)
            .custom_flags(FILE_FLAG_OPEN_REPARSE_POINT.0)
            .open(&lock_path)
        {
            Ok(file) => break file,
            Err(err)
                if matches!(err.raw_os_error(), Some(32 | 33)) && Instant::now() < deadline =>
            {
                std::thread::sleep(Duration::from_millis(25));
            }
            Err(err) => return Err(err.into()),
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
    struct Temp(std::path::PathBuf);
    impl Temp {
        fn new() -> Self {
            let path = std::env::temp_dir().join(format!(
                "nikodesk-windows-test-{}",
                hbb_common::uuid::Uuid::new_v4()
            ));
            fs::create_dir(&path).unwrap();
            Self(path)
        }
    }
    impl Drop for Temp {
        fn drop(&mut self) {
            fs::remove_dir_all(&self.0).unwrap();
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
