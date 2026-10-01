//! Owned Win32 provision transaction. No installer/CLI entry invokes it yet.
#[path = "maintenance_windows.rs"]
pub(super) mod maintenance;
#[path = "recovery_windows.rs"]
pub(super) mod recovery;
use super::recovery_policy::{Area, Event as Ownership, Header as OwnershipHeader, Object as OwnedObject, LEDGER};
use super::{approval::LocalApprovalGrant, policy::*, profile::*, transaction::*};
use ::windows::{
    core::{BOOL, PCWSTR},
    Win32::{
        Foundation::{
            CloseHandle, GetLastError, LocalFree, SetLastError, ERROR_NOT_ALL_ASSIGNED,
            ERROR_NO_TOKEN, ERROR_SERVICE_DOES_NOT_EXIST, HANDLE, HLOCAL, HWND, LUID,
        },
        Security::{
            AdjustTokenPrivileges,
            Authorization::{
                ConvertStringSecurityDescriptorToSecurityDescriptorW, GetSecurityInfo,
                SE_FILE_OBJECT,
            },
            CheckTokenMembership, GetAce, GetSecurityDescriptorControl, GetTokenInformation,
            IsWellKnownSid, LookupPrivilegeValueW, TokenElevation, TokenUser,
            WinBuiltinAdministratorsSid, WinLocalSystemSid,
            WinTrust::{
                WinVerifyTrust, WINTRUST_ACTION_GENERIC_VERIFY_V2, WINTRUST_DATA, WINTRUST_DATA_0,
                WINTRUST_FILE_INFO, WTD_CACHE_ONLY_URL_RETRIEVAL, WTD_CHOICE_FILE,
                WTD_REVOCATION_CHECK_CHAIN_EXCLUDE_ROOT, WTD_REVOKE_WHOLECHAIN,
                WTD_STATEACTION_CLOSE, WTD_STATEACTION_VERIFY, WTD_UI_NONE,
            },
            ACCESS_ALLOWED_ACE, ACE_HEADER, ACL, DACL_SECURITY_INFORMATION,
            OWNER_SECURITY_INFORMATION, PSECURITY_DESCRIPTOR, PSID, SECURITY_ATTRIBUTES,
            SE_PRIVILEGE_ENABLED, TOKEN_ADJUST_PRIVILEGES, TOKEN_ELEVATION, TOKEN_PRIVILEGES,
            TOKEN_QUERY, TOKEN_USER,
        },
        Storage::FileSystem::{
            CreateDirectoryW, CreateFileW, FileDispositionInfo, GetFileInformationByHandle,
            MoveFileExW, SetFileInformationByHandle, BY_HANDLE_FILE_INFORMATION, CREATE_NEW,
            DELETE, FILE_DISPOSITION_INFO, FILE_FLAG_BACKUP_SEMANTICS,
            FILE_FLAG_OPEN_REPARSE_POINT, FILE_GENERIC_READ, FILE_GENERIC_WRITE, FILE_SHARE_MODE,
            FILE_SHARE_READ, MOVEFILE_REPLACE_EXISTING, MOVEFILE_WRITE_THROUGH, OPEN_EXISTING,
            READ_CONTROL, WRITE_DAC,
        },
        System::{
            Com::CoTaskMemFree,
            Services::*,
            Threading::{GetCurrentProcess, GetCurrentThread, OpenProcessToken, OpenThreadToken},
        },
        UI::Shell::{
            FOLDERID_ProgramData, FOLDERID_ProgramFiles, SHGetKnownFolderPath, KNOWN_FOLDER_FLAG,
        },
    },
};
use hbb_common::anyhow::{anyhow, bail, Result};
use sha2::{Digest, Sha256};
use std::{
    collections::BTreeMap,
    ffi::OsStr,
    fs::File,
    io::{Read, Seek, SeekFrom, Write},
    os::windows::{
        ffi::OsStrExt,
        io::{AsRawHandle, FromRawHandle},
    },
    path::{Path, PathBuf},
    time::{Duration, Instant},
};

fn wide(value: impl AsRef<OsStr>) -> Vec<u16> {
    value.as_ref().encode_wide().chain(Some(0)).collect()
}
struct Kernel(HANDLE);
impl Drop for Kernel {
    fn drop(&mut self) {
        unsafe {
            let _ = CloseHandle(self.0);
        }
    }
}
struct Descriptor(PSECURITY_DESCRIPTOR);
impl Descriptor {
    fn new(sddl: &str) -> Result<Self> {
        let mut p = PSECURITY_DESCRIPTOR::default();
        let text = wide(sddl);
        unsafe {
            ConvertStringSecurityDescriptorToSecurityDescriptorW(
                PCWSTR(text.as_ptr()),
                1,
                &mut p,
                None,
            )?;
        }
        Ok(Self(p))
    }
    fn attributes(&self) -> SECURITY_ATTRIBUTES {
        SECURITY_ATTRIBUTES {
            nLength: std::mem::size_of::<SECURITY_ATTRIBUTES>() as u32,
            lpSecurityDescriptor: self.0 .0,
            bInheritHandle: BOOL(0),
        }
    }
}
impl Drop for Descriptor {
    fn drop(&mut self) {
        unsafe {
            let _ = LocalFree(Some(HLOCAL(self.0 .0)));
        }
    }
}
struct RestorePrivilege {
    token: Kernel,
    previous: TOKEN_PRIVILEGES,
}
impl RestorePrivilege {
    fn enable_for_explicit_setup(privilege: &str) -> Result<Self> {
        let mut thread = HANDLE::default();
        match unsafe { OpenThreadToken(GetCurrentThread(), TOKEN_QUERY, true, &mut thread) } {
            Ok(()) => {
                let _owned = Kernel(thread);
                bail!("impersonating_setup_rejected");
            }
            Err(error) if error.code() == windows::core::HRESULT::from_win32(ERROR_NO_TOKEN.0) => {}
            Err(error) => return Err(error.into()),
        }
        let mut token = HANDLE::default();
        unsafe {
            OpenProcessToken(
                GetCurrentProcess(),
                TOKEN_QUERY | TOKEN_ADJUST_PRIVILEGES,
                &mut token,
            )?;
        }
        let token = Kernel(token);
        let mut elevation = TOKEN_ELEVATION::default();
        let mut len = 0;
        unsafe {
            GetTokenInformation(
                token.0,
                TokenElevation,
                Some((&mut elevation as *mut TOKEN_ELEVATION).cast()),
                std::mem::size_of::<TOKEN_ELEVATION>() as u32,
                &mut len,
            )?;
        }
        let mut user_bytes = vec![0usize; 128];
        unsafe {
            GetTokenInformation(
                token.0,
                TokenUser,
                Some(user_bytes.as_mut_ptr().cast()),
                (user_bytes.len() * std::mem::size_of::<usize>()) as u32,
                &mut len,
            )?;
        }
        if unsafe {
            IsWellKnownSid(
                (&*user_bytes.as_ptr().cast::<TOKEN_USER>()).User.Sid,
                WinLocalSystemSid,
            )
        }
        .as_bool()
        {
            bail!("system_setup_entry_rejected");
        }
        let admin = Descriptor::new("O:BAD:P(A;;GA;;;BA)")?;
        let mut sid = PSID::default();
        // Obtain the BA owner SID through the descriptor, not a caller-supplied SID.
        let mut defaulted = BOOL(0);
        unsafe {
            windows::Win32::Security::GetSecurityDescriptorOwner(
                admin.0,
                &mut sid,
                &mut defaulted,
            )?;
        }
        let mut member = BOOL(0);
        unsafe {
            CheckTokenMembership(None, sid, &mut member)?;
        }
        if elevation.TokenIsElevated == 0 || !member.as_bool() {
            bail!("explicit_elevated_administrator_setup_required");
        }
        let mut luid = LUID::default();
        let name = wide(privilege);
        unsafe {
            LookupPrivilegeValueW(PCWSTR::null(), PCWSTR(name.as_ptr()), &mut luid)?;
        }
        let mut wanted = TOKEN_PRIVILEGES::default();
        wanted.PrivilegeCount = 1;
        wanted.Privileges[0].Luid = luid;
        wanted.Privileges[0].Attributes = SE_PRIVILEGE_ENABLED;
        let mut previous = TOKEN_PRIVILEGES::default();
        let mut returned = 0;
        unsafe {
            SetLastError(windows::Win32::Foundation::WIN32_ERROR(0));
            AdjustTokenPrivileges(
                token.0,
                false,
                Some(&wanted),
                std::mem::size_of::<TOKEN_PRIVILEGES>() as u32,
                Some(&mut previous),
                Some(&mut returned),
            )?;
            if GetLastError() == ERROR_NOT_ALL_ASSIGNED {
                bail!("required_setup_privilege_not_assigned");
            }
        }
        Ok(Self { token, previous })
    }
    fn restore(&mut self) -> Result<()> {
        unsafe {
            SetLastError(windows::Win32::Foundation::WIN32_ERROR(0));
            AdjustTokenPrivileges(self.token.0, false, Some(&self.previous), 0, None, None)?;
            if GetLastError() == ERROR_NOT_ALL_ASSIGNED {
                bail!("setup_privilege_restore_unconfirmed");
            }
        }
        Ok(())
    }
}
impl Drop for RestorePrivilege {
    fn drop(&mut self) {
        let _ = self.restore();
    }
}

fn known(id: &windows::core::GUID) -> Result<PathBuf> {
    let p = unsafe { SHGetKnownFolderPath(id, KNOWN_FOLDER_FLAG(0), None)? };
    let path = unsafe { p.to_string() }.map(PathBuf::from);
    unsafe {
        CoTaskMemFree(Some(p.0.cast()));
    }
    Ok(path?)
}
type FileId = FileIdentity;
fn facts(file: &File, directory: bool) -> Result<FileId> {
    let mut f = BY_HANDLE_FILE_INFORMATION::default();
    unsafe {
        GetFileInformationByHandle(HANDLE(file.as_raw_handle()), &mut f)?;
    }
    checked_file_identity(
        f.dwFileAttributes,
        f.nNumberOfLinks,
        directory,
        f.dwVolumeSerialNumber,
        f.nFileIndexHigh,
        f.nFileIndexLow,
    )
}
fn open(
    path: &Path,
    directory: bool,
    access: u32,
    create: bool,
    sddl: Option<&Descriptor>,
    share: FILE_SHARE_MODE,
) -> Result<File> {
    if !path.is_absolute() {
        bail!("absolute_setup_path_required");
    }
    // Only the explicit setup scope owns SeBackupPrivilege. Apply the flag also
    // to its own SYSTEM-only regular identity file; never change its DACL to read.
    let name = wide(path);
    let flags = FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_BACKUP_SEMANTICS;
    let attrs = sddl.map(Descriptor::attributes);
    let handle = unsafe {
        CreateFileW(
            PCWSTR(name.as_ptr()),
            access,
            share,
            attrs.as_ref().map(|a| a as *const _),
            if create { CREATE_NEW } else { OPEN_EXISTING },
            flags,
            None,
        )?
    };
    let file = unsafe { File::from_raw_handle(handle.0) };
    facts(&file, directory)?;
    Ok(file)
}
fn ancestor_pins(path: &Path) -> Result<Vec<File>> {
    let mut result = vec![];
    for p in path.ancestors().collect::<Vec<_>>().into_iter().rev() {
        result.push(open(p, true, READ_CONTROL.0, false, None, FILE_SHARE_READ)?);
    }
    Ok(result)
}
fn private_acl(file: &File, system: bool) -> Result<()> {
    let mut owner = PSID::default();
    let mut acl = std::ptr::null_mut::<ACL>();
    let mut sd = PSECURITY_DESCRIPTOR::default();
    unsafe {
        GetSecurityInfo(
            HANDLE(file.as_raw_handle()),
            SE_FILE_OBJECT,
            OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION,
            Some(&mut owner),
            None,
            Some(&mut acl),
            None,
            Some(&mut sd),
        )
        .ok()?;
    }
    let descriptor = Descriptor(sd);
    check_private_descriptor(descriptor.0, owner, acl, system)
}
fn check_private_descriptor(
    descriptor: PSECURITY_DESCRIPTOR,
    owner: PSID,
    acl: *mut ACL,
    system: bool,
) -> Result<()> {
    let mut control = 0u16;
    let mut revision = 0;
    unsafe {
        GetSecurityDescriptorControl(descriptor, &mut control, &mut revision)?;
    }
    if owner.0.is_null() || acl.is_null() || control & 0x1000 == 0 {
        bail!("unprotected_setup_acl");
    }
    unsafe {
        if !IsWellKnownSid(owner, WinLocalSystemSid).as_bool()
            && (system || !IsWellKnownSid(owner, WinBuiltinAdministratorsSid).as_bool())
        {
            bail!("wrong_setup_owner");
        }
        let mut trusted = 0;
        for i in 0..(*acl).AceCount {
            let mut raw = std::ptr::null_mut();
            GetAce(acl, i as u32, &mut raw)?;
            let head = &*raw.cast::<ACE_HEADER>();
            if head.AceType != 0 || head.AceSize < std::mem::size_of::<ACCESS_ALLOWED_ACE>() as u16
            {
                bail!("unsupported_setup_acl");
            }
            let ace = &*raw.cast::<ACCESS_ALLOWED_ACE>();
            let sid = PSID((&ace.SidStart as *const u32).cast_mut().cast());
            if !IsWellKnownSid(sid, WinLocalSystemSid).as_bool()
                && !IsWellKnownSid(sid, WinBuiltinAdministratorsSid).as_bool()
            {
                bail!("foreign_setup_acl_principal");
            }
            if ace.Mask & 0x001f01ff == 0x001f01ff || ace.Mask & 0x10000000 != 0 {
                trusted += 1;
            }
        }
        if trusted == 0 {
            bail!("setup_acl_has_no_trusted_full_access");
        }
    }
    Ok(())
}
fn content(file: &mut File, limit: u64) -> Result<Vec<u8>> {
    if file.metadata()?.len() > limit {
        bail!("setup_file_too_large");
    }
    file.seek(SeekFrom::Start(0))?;
    let mut bytes = vec![];
    file.take(limit + 1).read_to_end(&mut bytes)?;
    if bytes.len() as u64 > limit {
        bail!("setup_file_too_large");
    }
    Ok(bytes)
}
fn hash(file: &mut File, limit: u64) -> Result<String> {
    Ok(format!("{:x}", Sha256::digest(content(file, limit)?)))
}
pub(super) fn authenticode(file: &File, path: &Path) -> Result<()> {
    let text = wide(path);
    let mut info = WINTRUST_FILE_INFO {
        cbStruct: std::mem::size_of::<WINTRUST_FILE_INFO>() as u32,
        pcwszFilePath: PCWSTR(text.as_ptr()),
        hFile: HANDLE(file.as_raw_handle()),
        ..Default::default()
    };
    let mut data = WINTRUST_DATA {
        cbStruct: std::mem::size_of::<WINTRUST_DATA>() as u32,
        dwUIChoice: WTD_UI_NONE,
        fdwRevocationChecks: WTD_REVOKE_WHOLECHAIN,
        dwUnionChoice: WTD_CHOICE_FILE,
        Anonymous: WINTRUST_DATA_0 { pFile: &mut info },
        dwStateAction: WTD_STATEACTION_VERIFY,
        dwProvFlags: WTD_CACHE_ONLY_URL_RETRIEVAL | WTD_REVOCATION_CHECK_CHAIN_EXCLUDE_ROOT,
        ..Default::default()
    };
    let mut action = WINTRUST_ACTION_GENERIC_VERIFY_V2;
    let status = unsafe {
        WinVerifyTrust(
            HWND::default(),
            &mut action,
            (&mut data as *mut WINTRUST_DATA).cast(),
        )
    };
    data.dwStateAction = WTD_STATEACTION_CLOSE;
    let closed = unsafe {
        WinVerifyTrust(
            HWND::default(),
            &mut action,
            (&mut data as *mut WINTRUST_DATA).cast(),
        )
    };
    if status != 0 || closed != 0 {
        bail!("setup_authenticode_trust_or_cache_revocation_unconfirmed");
    }
    Ok(())
}
struct Created {
    path: PathBuf,
    id: Option<FileId>,
    directory: bool,
    pending: Option<File>,
}
struct Service(SC_HANDLE);
impl Drop for Service {
    fn drop(&mut self) {
        unsafe {
            let _ = CloseServiceHandle(self.0);
        }
    }
}
fn scm() -> Result<Service> {
    Ok(Service(unsafe {
        OpenSCManagerW(
            PCWSTR::null(),
            PCWSTR::null(),
            SC_MANAGER_CONNECT | SC_MANAGER_CREATE_SERVICE,
        )?
    }))
}
fn expected_command(root: &Path) -> String {
    format!("\"{}\" --service", root.join(HOST).display())
}
fn service_config(service: &Service, root: &Path) -> Result<()> {
    service_start_kind(service, root).map(|_| ())
}
fn service_start_kind(service: &Service, root: &Path) -> Result<SERVICE_START_TYPE> {
    let mut needed = 0;
    unsafe {
        let _ = QueryServiceConfigW(service.0, None, 0, &mut needed);
    }
    if needed < std::mem::size_of::<QUERY_SERVICE_CONFIGW>() as u32 || needed > 64 * 1024 {
        bail!("invalid_niko_service_config");
    }
    let mut buffer = vec![
        0usize;
        (needed as usize + std::mem::size_of::<usize>() - 1)
            / std::mem::size_of::<usize>()
    ];
    unsafe {
        QueryServiceConfigW(
            service.0,
            Some(buffer.as_mut_ptr().cast()),
            needed,
            &mut needed,
        )?;
    }
    let cfg = unsafe { &*buffer.as_ptr().cast::<QUERY_SERVICE_CONFIGW>() };
    let command = unsafe { cfg.lpBinaryPathName.to_string()? };
    let account = unsafe { cfg.lpServiceStartName.to_string()? };
    if cfg.dwServiceType != SERVICE_WIN32_OWN_PROCESS
        || command != expected_command(root)
        || !account.eq_ignore_ascii_case("LocalSystem")
        || !matches!(cfg.dwStartType, SERVICE_AUTO_START | SERVICE_DISABLED)
    {
        bail!("foreign_nikodesk_service_rejected");
    }
    Ok(cfg.dwStartType)
}
fn service_private_acl(service: &Service) -> Result<()> {
    use windows::Win32::Security::{GetSecurityDescriptorDacl, GetSecurityDescriptorOwner};
    let mut needed = 0;
    unsafe {
        let _ = QueryServiceObjectSecurity(
            service.0,
            (OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION).0,
            None,
            0,
            &mut needed,
        );
    }
    if needed == 0 || needed > 64 * 1024 {
        bail!("invalid_service_security_descriptor");
    }
    let mut buffer = vec![
        0usize;
        (needed as usize + std::mem::size_of::<usize>() - 1)
            / std::mem::size_of::<usize>()
    ];
    let descriptor = PSECURITY_DESCRIPTOR(buffer.as_mut_ptr().cast());
    unsafe {
        QueryServiceObjectSecurity(
            service.0,
            (OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION).0,
            Some(descriptor),
            needed,
            &mut needed,
        )?;
    }
    let mut owner = PSID::default();
    let mut defaulted = BOOL(0);
    let mut present = BOOL(0);
    let mut acl = std::ptr::null_mut();
    unsafe {
        GetSecurityDescriptorOwner(descriptor, &mut owner, &mut defaulted)?;
        GetSecurityDescriptorDacl(descriptor, &mut present, &mut acl, &mut defaulted)?;
    }
    if !present.as_bool() {
        bail!("service_has_no_private_dacl");
    }
    check_private_descriptor(descriptor, owner, acl, false)
}
fn service_state(service: &Service) -> Result<SERVICE_STATUS_CURRENT_STATE> {
    let mut value = SERVICE_STATUS_PROCESS::default();
    let mut needed = 0;
    let slice = unsafe {
        std::slice::from_raw_parts_mut(
            (&mut value as *mut SERVICE_STATUS_PROCESS).cast::<u8>(),
            std::mem::size_of::<SERVICE_STATUS_PROCESS>(),
        )
    };
    unsafe {
        QueryServiceStatusEx(service.0, SC_STATUS_PROCESS_INFO, Some(slice), &mut needed)?;
    }
    Ok(value.dwCurrentState)
}
fn set_start(service: &Service, kind: SERVICE_START_TYPE) -> Result<()> {
    unsafe {
        ChangeServiceConfigW(
            service.0,
            ENUM_SERVICE_TYPE(SERVICE_NO_CHANGE),
            kind,
            SERVICE_ERROR(SERVICE_NO_CHANGE),
            PCWSTR::null(),
            PCWSTR::null(),
            None,
            PCWSTR::null(),
            PCWSTR::null(),
            PCWSTR::null(),
            PCWSTR::null(),
        )?;
    }
    Ok(())
}
fn stop_confirmed(service: &Service) -> Result<()> {
    set_start(service, SERVICE_DISABLED)?;
    if service_state(service)? == SERVICE_STOPPED {
        return Ok(());
    }
    let mut status = SERVICE_STATUS::default();
    if let Err(error) = unsafe { ControlService(service.0, SERVICE_CONTROL_STOP, &mut status) } {
        if service_state(service)? != SERVICE_STOPPED {
            return Err(error.into());
        }
    }
    let deadline = Instant::now() + Duration::from_secs(15);
    while service_state(service)? != SERVICE_STOPPED {
        if Instant::now() > deadline {
            bail!("owned_niko_service_stop_unconfirmed");
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    Ok(())
}

pub struct NativeSetup {
    factory: MachineProfileFactory,
    source: PathBuf,
    release: ReleaseManifest,
    approval: LocalApprovalGrant,
    password: Option<UnattendedSecret>,
    install: PathBuf,
    machine: PathBuf,
    host: PathBuf,
    config: PathBuf,
    privileges: Vec<RestorePrivilege>,
    parents: Vec<File>,
    pins: BTreeMap<String, File>,
    root_pins: Vec<File>,
    created: Vec<Created>,
    service: Option<Service>,
    owns_service: bool,
    lock: Option<File>,
    journal: Journal,
    profile: Option<MachineProfile>,
    repeated: bool,
    verified_public_id: Option<String>,
    retired: bool,
    retired_marker: Option<(FileId, File)>,
    ledger: Option<recovery::Ledger>,
    file_serial: u32,
    stopped_process: Option<Kernel>,
    service_deleted: bool,
}
impl NativeSetup {
    pub(super) fn committed(&self) -> bool {
        self.repeated || self.ledger.as_ref().is_some_and(|ledger| ledger.replay.committed)
    }
    pub(super) fn owns_install(&self) -> bool { self.ledger.is_some() }
    // Called only after the owned transaction completed its protected-file
    // readback. Return the public ID; no key or password leaves this owner.
    pub(super) fn public_id(&self) -> Result<String> {
        self.verified_public_id.clone()
            .ok_or_else(|| anyhow!("verified_machine_id_unavailable"))
    }
    /// A trusted standalone setup binary embeds the release manifest and shows
    /// explicit local consent before calling. The ordinary client never calls it.
    pub fn new(
        factory: MachineProfileFactory,
        source: PathBuf,
        release: ReleaseManifest,
        approval: LocalApprovalGrant,
        password: UnattendedSecret,
    ) -> Result<Transaction<Self>> {
        release.validate()?;
        factory.validate_private_server(&approval)?;
        let install = known(&FOLDERID_ProgramFiles)?.join("NikoDesk");
        let machine = known(&FOLDERID_ProgramData)?.join("NikoDesk");
        let host = machine.join("host");
        let config = host.join("config");
        let journal = Journal {
            version: 1,
            transaction: approval.consent().id().into(),
            release_sha256: format!("{:x}", Sha256::digest(serde_json::to_vec(&release)?)),
            phase: Phase::Preflight,
        };
        let start = approval.consent().start_after_commit;
        Ok(Transaction::new(
            Self {
                factory,
                source,
                release,
                approval,
                password: Some(password),
                install,
                machine,
                host,
                config,
                privileges: vec![],
                parents: vec![],
                pins: BTreeMap::new(),
                root_pins: vec![],
                created: vec![],
                service: None,
                owns_service: false,
                lock: None,
                journal,
                profile: None,
                repeated: false,
                verified_public_id: None,
                retired: false,
                retired_marker: None,
                ledger: None,
                file_serial: 0,
                stopped_process: None,
                service_deleted: false,
            },
            start,
        ))
    }
    fn preflight(&mut self) -> Result<()> {
        self.factory.validate_private_server(&self.approval)?;
        self.parents.extend(ancestor_pins(&self.source)?);
        self.parents.extend(ancestor_pins(
            self.install
                .parent()
                .ok_or_else(|| anyhow!("missing_programfiles"))?,
        )?);
        self.parents.extend(ancestor_pins(
            self.machine
                .parent()
                .ok_or_else(|| anyhow!("missing_programdata"))?,
        )?);
        // Production requires OS Authenticode trust. Only a sealed broker grant
        // from the compiled reviewed-unsigned mode plus native confirmation may
        // take the development path; the exact release pins still apply.
        let setup = std::env::current_exe()?;
        let _setup_parents = ancestor_pins(
            setup
                .parent()
                .ok_or_else(|| anyhow!("missing_setup_parent"))?,
        )?;
        let setup_file = open(
            &setup,
            false,
            FILE_GENERIC_READ.0 | READ_CONTROL.0,
            false,
            None,
            FILE_SHARE_READ,
        )?;
        if !self.approval.reviewed_unsigned() {
            authenticode(&setup_file, &setup)?;
        }
        self.parents.push(setup_file);
        self.privileges
            .push(RestorePrivilege::enable_for_explicit_setup(
                "SeRestorePrivilege",
            )?);
        self.privileges
            .push(RestorePrivilege::enable_for_explicit_setup(
                "SeBackupPrivilege",
            )?);
        for (name, pin) in &self.release.files {
            let path = self.source.join(name);
            let mut file = open(
                &path,
                false,
                FILE_GENERIC_READ.0 | READ_CONTROL.0,
                false,
                None,
                FILE_SHARE_READ,
            )?;
            if file.metadata()?.len() != pin.length
                || hash(&mut file, MAX_PAYLOAD_BYTES)? != pin.sha256
            {
                bail!("release_payload_pin_mismatch");
            }
            if name == HOST && !self.approval.reviewed_unsigned() {
                authenticode(&file, &path)?;
            }
            self.pins.insert(name.clone(), file);
        }
        let manager = scm()?;
        let name = wide(SERVICE);
        match unsafe {
            OpenServiceW(
                manager.0,
                PCWSTR(name.as_ptr()),
                SERVICE_QUERY_CONFIG
                    | SERVICE_QUERY_STATUS
                    | SERVICE_CHANGE_CONFIG
                    | SERVICE_STOP
                    | SERVICE_START
                    | READ_CONTROL.0
                    | DELETE.0,
            )
        } {
            Ok(raw) => {
                let service = Service(raw);
                service_config(&service, &self.install)?;
                service_private_acl(&service)?;
                // Repeat install verifies existing protected profile/pins and does
                // not regenerate identity, modify consent or restart the service.
                let lock = open(&self.host.join("setup.lock"), false,
                    FILE_GENERIC_READ.0 | FILE_GENERIC_WRITE.0 | READ_CONTROL.0, false, None, FILE_SHARE_MODE(0))?;
                private_acl(&lock, true)?;
                self.lock = Some(lock);
                self.verify_existing()?;
                self.service = Some(service);
                self.repeated = true;
                self.password.take();
            }
            Err(error)
                if error.code()
                    == windows::core::HRESULT::from_win32(ERROR_SERVICE_DOES_NOT_EXIST.0) => {}
            Err(error) => return Err(error.into()),
        }
        if !self.repeated && (self.install.try_exists()? || self.machine.try_exists()?) {
            self.verify_retired_roots()?;
        }
        if !self.repeated {
            let layout=recovery::Layout::read()?;
            if layout.machine_parent.join(LEDGER).try_exists()? {
                bail!("interrupted_install_requires_local_recovery");
            }
            let program=open(&layout.program_parent,true,READ_CONTROL.0,false,None,FILE_SHARE_READ)?;
            let machine=open(&layout.machine_parent,true,READ_CONTROL.0,false,None,FILE_SHARE_READ)?;
            let mut existing_roots=BTreeMap::new();
            if self.retired {
                for area in [Area::Program,Area::Machine,Area::Host,Area::Config] {
                    let path=layout.root(area);
                    if path.try_exists()? {
                        let file=open(&path,true,READ_CONTROL.0,false,None,FILE_SHARE_READ)?;
                        private_acl(&file,area!=Area::Program)?;
                        existing_roots.insert(area,facts(&file,true)?);
                    }
                }
            }
            let header=OwnershipHeader {version:2,transaction:self.journal.transaction.clone(),
                namespace:self.approval.origin().namespace().into(),program_parent:facts(&program,true)?,
                machine_parent:facts(&machine,true)?,existing_roots,release:self.release.clone()};
            self.ledger=Some(recovery::Ledger::create(&layout,header.clone())?);
            self.record(Ownership::Begin {header})?;
        }
        Ok(())
    }
    fn record(&mut self,event: Ownership) -> Result<()> {
        self.ledger.as_mut().ok_or_else(||anyhow!("install_ownership_ledger_missing"))?.append(event)
    }
    fn verify_retired_roots(&mut self) -> Result<()> {
        // Only a completed locally confirmed removal can authorize reuse.
        // A failed or partially installed tree remains a recovery case.
        self.parents.extend(ancestor_pins(&self.host)?);
        let mut marker=open(&self.host.join(RETIRED_PROFILE),false,
            FILE_GENERIC_READ.0|READ_CONTROL.0,false,None,FILE_SHARE_READ)?;
        private_acl(&marker,true)?;
        let value:RetiredMachine=serde_json::from_slice(&content(&mut marker,4096)?)?;
        value.validate()?;
        for path in [self.config.join("NikoDesk.toml"),self.config.join("NikoDesk2.toml"),
            self.host.join("provision-v1.json"),self.host.join("setup.lock"),self.host.join("install-journal-v1.json"),
            self.host.join(super::update_policy::JOURNAL),self.host.join(super::update_policy::COMMIT)] {
            if path.try_exists()? {bail!("removed_machine_has_unconfirmed_profile_or_transaction");}
        }
        for name in self.release.files.keys() {
            if self.install.join(name).try_exists()? {bail!("removed_machine_has_unconfirmed_payload");}
        }
        for (path,private) in [(&self.install,false),(&self.machine,true),(&self.host,true),(&self.config,true)] {
            if path.try_exists()? {
                let directory=open(path,true,READ_CONTROL.0,false,None,FILE_SHARE_READ)?;
                private_acl(&directory,private)?;self.root_pins.push(directory);
            }
        }
        self.retired_marker=Some((facts(&marker,false)?,marker));self.retired=true;
        Ok(())
    }
    fn verify_existing(&mut self) -> Result<()> {
        for (path, system) in [
            (&self.install, false),
            (&self.machine, true),
            (&self.host, true),
            (&self.config, true),
        ] {
            let file = open(path, true, READ_CONTROL.0, false, None, FILE_SHARE_READ)?;
            private_acl(&file, system)?;
            self.root_pins.push(file);
        }
        let mut provision = open(
            &self.host.join("provision-v1.json"),
            false,
            FILE_GENERIC_READ.0 | READ_CONTROL.0,
            false,
            None,
            FILE_SHARE_READ,
        )?;
        private_acl(&provision, true)?;
        let actual: Provision = serde_json::from_slice(&content(&mut provision, 64 * 1024)?)?;
        if actual.version != 1
            || !actual.desktop_preauthorized
            || !hex(&actual.consent_id)
            || actual.files.len() != self.release.files.len()
            || self
                .release
                .files
                .iter()
                .any(|(name, p)| actual.files.get(name) != Some(&p.sha256))
        {
            bail!("repeat_install_release_or_consent_mismatch");
        }
        for (name, pin) in &self.release.files {
            let mut file = open(
                &self.install.join(name),
                false,
                FILE_GENERIC_READ.0 | READ_CONTROL.0,
                false,
                None,
                FILE_SHARE_READ,
            )?;
            private_acl(&file, false)?;
            if hash(&mut file, MAX_PAYLOAD_BYTES)? != pin.sha256 {
                bail!("installed_payload_pin_mismatch");
            }
            self.root_pins.push(file);
        }
        let mut profile = BTreeMap::new();
        for name in ["NikoDesk.toml", "NikoDesk2.toml"] {
            let mut file = open(
                &self.config.join(name),
                false,
                FILE_GENERIC_READ.0 | READ_CONTROL.0,
                false,
                None,
                FILE_SHARE_READ,
            )?;
            private_acl(&file, true)?;
            profile.insert(name.into(), content(&mut file, 128 * 1024)?);
            self.root_pins.push(file);
        }
        let verified = self.factory.verify_existing(&profile, &self.approval,
            self.password.as_ref().ok_or_else(||anyhow!("explicit_unattended_password_required"))?);
        for bytes in profile.values_mut() {
            wipe(bytes);
        }
        self.verified_public_id = Some(verified?);
        for entry in std::fs::read_dir(&self.install)? {
            let entry = entry?;
            let name = entry.file_name().to_string_lossy().into_owned();
            if !self.release.files.contains_key(&name) {
                bail!("repeat_install_has_unpinned_entry");
            }
        }
        Ok(())
    }
    fn make_roots(&mut self) -> Result<()> {
        let layout=recovery::Layout::read()?;
        for area in [Area::Program,Area::Machine,Area::Host,Area::Config] {
            let path=layout.root(area);let system=area!=Area::Program;
            if self.retired && path.try_exists()? {
                let directory=open(&path,true,READ_CONTROL.0,false,None,FILE_SHARE_READ)?;
                private_acl(&directory,system)?;
                if self.ledger.as_ref().and_then(|l|l.replay.header.existing_roots.get(&area))!=Some(&facts(&directory,true)?) {
                    bail!("retained_install_root_changed");
                }
                self.root_pins.push(directory);continue;
            }
            let object=OwnedObject::RootStage {area};
            let temporary=layout.path(&object,&self.journal.transaction);
            self.record(Ownership::Intent {object:object.clone()})?;
            let sd = Descriptor::new(if system {
                "O:SYD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)"
            } else {
                "O:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)"
            })?;
            let attrs = sd.attributes();
            unsafe {
                CreateDirectoryW(PCWSTR(wide(&temporary).as_ptr()), Some(&attrs))?;
            }
            self.created.push(Created {
                path: temporary.clone(),
                id: None,
                directory: true,
                pending: None,
            });
            let file = open(&temporary, true, READ_CONTROL.0, false, None, FILE_SHARE_READ)?;
            let id = facts(&file, true)?;
            self.created
                .last_mut()
                .ok_or_else(|| anyhow!("missing_created_root"))?
                .id = Some(id);
            private_acl(&file, system)?;
            self.record(Ownership::Created {object:object.clone(),id})?;
            self.record(Ownership::Rename {from:object,to:OwnedObject::Root {area},id,replaces:None})?;
            drop(file);
            unsafe {MoveFileExW(PCWSTR(wide(&temporary).as_ptr()),PCWSTR(wide(&path).as_ptr()),MOVEFILE_WRITE_THROUGH)?;}
            self.created.last_mut().ok_or_else(||anyhow!("missing_created_root"))?.path=path.clone();
            let pin=open(&path,true,READ_CONTROL.0,false,None,FILE_SHARE_READ)?;
            if facts(&pin,true)?!=id {bail!("created_root_changed");}
            self.root_pins.push(pin);
        }
        Ok(())
    }
    fn create_file(&mut self, path: PathBuf, bytes: &[u8], system: bool) -> Result<File> {
        let layout=recovery::Layout::read()?;let target=layout.file_object(&path)?;
        self.file_serial=self.file_serial.checked_add(1).ok_or_else(||anyhow!("install_file_limit"))?;
        let stage=OwnedObject::FileStage {area:target.area(),serial:self.file_serial};
        let temporary=layout.path(&stage,&self.journal.transaction);
        self.record(Ownership::Intent {object:stage.clone()})?;
        let sd = Descriptor::new(if system {
            "O:SYD:P(A;;FA;;;SY)(A;;FA;;;BA)"
        } else {
            "O:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)"
        })?;
        let attrs = sd.attributes();
        let handle = unsafe {
            CreateFileW(
                PCWSTR(wide(&temporary).as_ptr()),
                FILE_GENERIC_READ.0 | FILE_GENERIC_WRITE.0 | READ_CONTROL.0 | DELETE.0,
                FILE_SHARE_READ,
                Some(&attrs),
                CREATE_NEW,
                FILE_FLAG_OPEN_REPARSE_POINT,
                None,
            )?
        };
        self.created.push(Created {
            path: temporary.clone(),
            id: None,
            directory: false,
            pending: Some(unsafe { File::from_raw_handle(handle.0) }),
        });
        let id={
            let entry=self.created.last_mut().ok_or_else(||anyhow!("missing_created_file"))?;
            let file=entry.pending.as_ref().ok_or_else(||anyhow!("missing_created_handle"))?;
            let id=facts(file,false)?;entry.id=Some(id);private_acl(file,system)?;id
        };
        self.record(Ownership::Created {object:stage.clone(),id})?;
        {
            let file=self.created.last_mut().unwrap().pending.as_mut().unwrap();
            file.write_all(bytes)?;file.sync_all()?;
        }
        self.record(Ownership::Rename {from:stage,to:target,id,replaces:None})?;
        self.created.last_mut().unwrap().pending.take();
        unsafe {MoveFileExW(PCWSTR(wide(&temporary).as_ptr()),PCWSTR(wide(&path).as_ptr()),MOVEFILE_WRITE_THROUGH)?;}
        self.created.last_mut().unwrap().path=path.clone();
        open(
            &path,
            false,
            FILE_GENERIC_READ.0 | READ_CONTROL.0,
            false,
            None,
            FILE_SHARE_READ,
        )
    }
    fn write_provision(&mut self, enabled: bool) -> Result<()> {
        let bytes = serde_json::to_vec(&Provision::from_manifest(
            &self.release,
            self.approval.consent(),
            enabled,
        ))?;
        self.atomic_private(self.host.join("provision-v1.json"), &bytes)
    }
    fn atomic_private(&mut self, path: PathBuf, bytes: &[u8]) -> Result<()> {
        let mut replaces=None;
        // Existing destination is owned by this transaction and protected root;
        // it is never a user-controlled path. Compare FileId before replacement.
        if path.try_exists()? {
            let existing = open(&path, false, READ_CONTROL.0, false, None, FILE_SHARE_READ)?;
            private_acl(&existing, true)?;
            let id = facts(&existing, false)?;
            replaces=Some(id);
            if !self
                .created
                .iter()
                .any(|entry| entry.path == path && entry.id == Some(id))
            {
                bail!("atomic_target_not_owned");
            }
        }
        let temporary = self.host.join(format!(
            ".{}-{}.tmp",
            self.journal.transaction,
            self.file_serial.checked_add(1).ok_or_else(||anyhow!("install_file_limit"))?
        ));
        let file = self.create_file(temporary.clone(), bytes, true)?;
        let id=facts(&file,false)?;
        drop(file);
        let layout=recovery::Layout::read()?;
        self.record(Ownership::Rename {from:layout.file_object(&temporary)?,to:layout.file_object(&path)?,id,replaces})?;
        unsafe {
            MoveFileExW(
                PCWSTR(wide(&temporary).as_ptr()),
                PCWSTR(wide(&path).as_ptr()),
                MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH,
            )?;
        }
        self.created.retain(|entry| entry.path != path);
        let entry = self
            .created
            .iter_mut()
            .find(|entry| entry.path == temporary)
            .ok_or_else(|| anyhow!("missing_owned_temp"))?;
        entry.path = path;
        Ok(())
    }
    fn make_service(&mut self) -> Result<()> {
        self.record(Ownership::ServiceIntent)?;
        let manager = scm()?;
        let name = wide(SERVICE);
        let display=wide(recovery::service_tag(&self.journal.transaction));
        let command = wide(expected_command(&self.install));
        let system = wide("LocalSystem");
        let raw = unsafe {
            CreateServiceW(
                manager.0,
                PCWSTR(name.as_ptr()),
                PCWSTR(display.as_ptr()),
                SERVICE_QUERY_CONFIG
                    | SERVICE_QUERY_STATUS
                    | SERVICE_CHANGE_CONFIG
                    | SERVICE_STOP
                    | SERVICE_START
                    | READ_CONTROL.0
                    | WRITE_DAC.0
                    | DELETE.0,
                SERVICE_WIN32_OWN_PROCESS,
                SERVICE_DISABLED,
                SERVICE_ERROR_NORMAL,
                PCWSTR(command.as_ptr()),
                PCWSTR::null(),
                None,
                PCWSTR::null(),
                PCWSTR(system.as_ptr()),
                PCWSTR::null(),
            )?
        };
        self.service = Some(Service(raw));
        self.owns_service = true;
        let sd = Descriptor::new("D:P(A;;GA;;;SY)(A;;GA;;;BA)")?;
        unsafe {
            SetServiceObjectSecurity(raw, DACL_SECURITY_INFORMATION, sd.0)?;
        }
        service_config(
            self.service
                .as_ref()
                .ok_or_else(|| anyhow!("missing_service"))?,
            &self.install,
        )?;
        service_private_acl(
            self.service
                .as_ref()
                .ok_or_else(|| anyhow!("missing_service"))?,
        )?;
        if service_state(
            self.service
                .as_ref()
                .ok_or_else(|| anyhow!("missing_service"))?,
        )? != SERVICE_STOPPED
        {
            bail!("new_disabled_service_is_not_stopped");
        }
        Ok(())
    }
    fn verify_profile(&mut self) -> Result<()> {
        let profile = self
            .profile
            .as_ref()
            .ok_or_else(|| anyhow!("missing_owned_machine_profile"))?;
        let mut readback = BTreeMap::new();
        for (name, written) in profile.files() {
            let mut file = open(
                &self.config.join(name),
                false,
                FILE_GENERIC_READ.0 | READ_CONTROL.0,
                false,
                None,
                FILE_SHARE_READ,
            )?;
            private_acl(&file, true)?;
            let actual = content(&mut file, 128 * 1024)?;
            if actual != *written {
                bail!("machine_profile_readback_mismatch");
            }
            readback.insert(name.clone(), actual);
            self.root_pins.push(file);
        }
        let verified = self.factory.verify_readback(&readback, &self.approval);
        for bytes in readback.values_mut() {
            wipe(bytes);
        }
        let id = verified?;
        if id != profile.public_id() {
            bail!("machine_profile_public_id_mismatch");
        }
        self.verified_public_id = Some(id);
        for (name, pin) in &self.release.files {
            let mut file = open(
                &self.install.join(name),
                false,
                FILE_GENERIC_READ.0 | READ_CONTROL.0,
                false,
                None,
                FILE_SHARE_READ,
            )?;
            private_acl(&file, false)?;
            if hash(&mut file, MAX_PAYLOAD_BYTES)? != pin.sha256 {
                bail!("installed_payload_readback_mismatch");
            }
            self.root_pins.push(file);
        }
        Ok(())
    }
}
impl Platform for NativeSetup {
    fn perform(&mut self, phase: Phase) -> Result<()> {
        self.factory.validate_private_server(&self.approval)?;
        if self.repeated {
            if phase == Phase::Complete {
                recovery::finish_committed(&self.approval,&self.public_id()?)?;
                for p in self.privileges.iter_mut().rev() {
                    p.restore()?;
                }
                self.privileges.clear();
            }
            return Ok(());
        }
        match phase {
            Phase::Preflight => self.preflight()?,
            Phase::Roots => self.make_roots()?,
            Phase::Journal => {
                let path = self.host.join("setup.lock");
                drop(self.create_file(path.clone(), &[], true)?);
                self.lock = Some(open(
                    &path,
                    false,
                    FILE_GENERIC_READ.0 | FILE_GENERIC_WRITE.0 | READ_CONTROL.0,
                    false,
                    None,
                    FILE_SHARE_MODE(0),
                )?);
            }
            Phase::Payload => {
                let names: Vec<_> = self.release.files.keys().cloned().collect();
                for name in names {
                    let bytes = content(
                        self.pins
                            .get_mut(&name)
                            .ok_or_else(|| anyhow!("missing_source_pin"))?,
                        MAX_PAYLOAD_BYTES,
                    )?;
                    let file = self.create_file(self.install.join(&name), &bytes, false)?;
                    self.root_pins.push(file);
                }
            }
            Phase::DisabledService => {
                self.make_service()?;
                self.write_provision(false)?;
            }
            Phase::Profile => {
                let keys = MachineIdentity::generate()?;
                let secret = self
                    .password
                    .take()
                    .ok_or_else(|| anyhow!("missing_explicit_password"))?;
                self.factory.validate_private_server(&self.approval)?;
                let profile = self.factory.prepare(keys, &self.approval, secret)?;
                for (name, bytes) in profile.files() {
                    let file = self.create_file(self.config.join(name), bytes, true)?;
                    self.root_pins.push(file);
                }
                self.profile = Some(profile);
            }
            Phase::Verify => self.verify_profile()?,
            Phase::Consent => {
                self.factory.validate_private_server(&self.approval)?;
                // Identity/payload readback precedes this durable commit. A
                // later startup failure retains the same machine for repair.
                self.record(Ownership::Commit {public_id:self.public_id()?})?;
                self.write_provision(true)?;
            }
            Phase::AutoStart => set_start(
                self.service
                    .as_ref()
                    .ok_or_else(|| anyhow!("missing_service"))?,
                SERVICE_AUTO_START,
            )?,
            Phase::Started => {
                let service = self
                    .service
                    .as_ref()
                    .ok_or_else(|| anyhow!("missing_service"))?;
                unsafe {
                    StartServiceW(service.0, None)?;
                }
                let deadline = Instant::now() + Duration::from_secs(15);
                while service_state(service)? != SERVICE_RUNNING {
                    if self.stopped_process.is_none() {
                        self.stopped_process=recovery::process(service,&self.install).ok().flatten();
                    }
                    if service_state(service)? == SERVICE_STOPPED || Instant::now() > deadline {
                        bail!("scm_start_not_confirmed");
                    }
                    std::thread::sleep(Duration::from_millis(100));
                }
                if self.stopped_process.is_none() {
                    self.stopped_process=recovery::process(service,&self.install)?;
                }
                if self.stopped_process.is_none() {bail!("owned_service_process_unconfirmed");}
            }
            Phase::Complete => {
                self.persist_phase(Phase::Complete)?;
                if let Some((id,marker))=self.retired_marker.take() {
                    drop(marker);
                    let file=open(&self.host.join(RETIRED_PROFILE),false,DELETE.0|READ_CONTROL.0,false,None,FILE_SHARE_READ)?;
                    private_acl(&file,true)?;
                    if facts(&file,false)?!=id {bail!("removed_machine_record_changed");}
                    let disposition=FILE_DISPOSITION_INFO{DeleteFile:true};
                    unsafe {SetFileInformationByHandle(HANDLE(file.as_raw_handle()),FileDispositionInfo,
                        (&disposition as *const FILE_DISPOSITION_INFO).cast(),std::mem::size_of_val(&disposition) as u32)?;}
                }
                for p in self.privileges.iter_mut().rev() {
                    p.restore()?;
                }
                self.privileges.clear();
                if let Some(ledger)=self.ledger.as_ref() {ledger.remove()?;}
                self.ledger.take();
            }
            Phase::Recovery => bail!("invalid_install_phase"),
        }
        Ok(())
    }
    fn persist_phase(&mut self, phase: Phase) -> Result<()> {
        if self.repeated {
            return Ok(());
        }
        self.journal.phase = phase;
        self.atomic_private(
            self.host.join("install-journal-v1.json"),
            &serde_json::to_vec(&self.journal)?,
        )?;
        self.record(Ownership::Phase {phase})
    }
    fn disable_and_confirm_stopped(&mut self) -> Result<()> {
        if self.owns_service {
            let service=self.service.as_ref().ok_or_else(||anyhow!("missing_owned_service"))?;
            if self.stopped_process.is_none() {
                self.stopped_process=recovery::process(service,&self.install)?;
            }
            stop_confirmed(
                self.service
                    .as_ref()
                    .ok_or_else(|| anyhow!("missing_owned_service"))?,
            )?;
            recovery::confirm_process_exit(&self.stopped_process)?;
            if self.host.join("provision-v1.json").try_exists()? {
                self.write_provision(false)?;
            }
        }
        Ok(())
    }
    fn remove_only_owned_artifacts(&mut self) -> Result<()> {
        if self.committed() {bail!("committed_machine_identity_must_be_preserved");}
        if self.owns_service {
            let service = self
                .service
                .as_ref()
                .ok_or_else(|| anyhow!("missing_owned_service"))?;
            if service_state(service)? != SERVICE_STOPPED {
                bail!("remove_before_service_stop_rejected");
            }
            unsafe {
                DeleteService(service.0)?;
            }
            self.service.take();
            self.owns_service = false;
            self.service_deleted = true;
        }
        if self.service_deleted {recovery::confirm_service_absent()?;}
        // Close pins only after Stop ACK. Protected parent handles remain held
        // until the deletion of each child is checked by original kernel FileId.
        self.lock.take();
        self.root_pins.clear();
        while let Some(entry) = self.created.last_mut() {
            let file = if let Some(pending) = entry.pending.take() {
                pending
            } else {
                if entry.id.is_none() {
                    // Before its Created append, a nonce directory has no
                    // children. Never adopt a fixed destination this way.
                    let layout=recovery::Layout::read()?;
                    let nonce=&self.journal.transaction;
                    let planned=self.ledger.as_ref().is_some_and(|ledger|ledger.replay.intents.iter()
                        .any(|object|object.stage() && object.directory() && layout.path(object,nonce)==entry.path));
                    if !entry.directory || !planned || std::fs::read_dir(&entry.path)?.next().is_some() {
                        bail!("created_directory_identity_unconfirmed_retain_recovery");
                    }
                }
                open(
                    &entry.path,
                    entry.directory,
                    DELETE.0 | READ_CONTROL.0,
                    false,
                    None,
                    FILE_SHARE_READ,
                )?
            };
            let id = match facts(&file, entry.directory) {
                Ok(id) => id,
                Err(error) => {
                    entry.pending = Some(file);
                    return Err(error);
                }
            };
            private_acl(&file,entry.path.starts_with(&self.machine))?;
            if entry.id.is_some_and(|original| original != id) {
                entry.pending = Some(file);
                bail!("rollback_object_identity_changed");
            }
            entry.id = Some(id);
            let disposition = FILE_DISPOSITION_INFO { DeleteFile: true };
            if let Err(error) = unsafe {
                SetFileInformationByHandle(
                    HANDLE(file.as_raw_handle()),
                    FileDispositionInfo,
                    (&disposition as *const FILE_DISPOSITION_INFO).cast(),
                    std::mem::size_of::<FILE_DISPOSITION_INFO>() as u32,
                )
            } {
                entry.pending = Some(file);
                return Err(error.into());
            }
            drop(file);
            self.created.pop();
        }
        for p in self.privileges.iter_mut().rev() {
            p.restore()?;
        }
        self.privileges.clear();
        if let Some(ledger)=self.ledger.as_ref() {ledger.remove()?;}
        self.ledger.take();
        Ok(())
    }
}
