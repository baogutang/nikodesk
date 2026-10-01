//! Kernel-origin proof only. No settings DTO, setup argument or UI consent can
//! construct it. The future signed setup must supply sealed embedded release pins.
use hbb_common::anyhow::{bail, Result};

const MAX_IMAGE_BYTES: u64 = 512 * 1024 * 1024;

fn captured_context(namespace: &[u8; 32], generation: u64) -> Result<()> {
    if generation == 0 || namespace.iter().all(|byte| *byte == 0) {
        bail!("install_ui_context_invalid");
    }
    Ok(())
}

#[derive(Clone, Copy, PartialEq, Eq)]
struct FileIdentity {
    volume: u64,
    id: [u8; 16],
}
fn file_policy(attributes: u32, links: u32, size: u64, directory: bool) -> Result<()> {
    if attributes & 0x400 != 0
        || (attributes & 0x10 != 0) != directory
        || (!directory && (links != 1 || size == 0 || size > MAX_IMAGE_BYTES))
    {
        bail!("install_ui_image_unsafe_file");
    }
    Ok(())
}

struct TokenFacts {
    sid: Vec<u8>,
    session: u32,
    elevated: bool,
    app_container: bool,
    interactive: bool,
    service: bool,
    integrity: u32,
}
fn ordinary_ui(facts: &TokenFacts, original_user: &[u8], session: u32) -> Result<()> {
    // Binary SIDs are obtained and validated from the actual kernel token, never
    // accepted from a claim. S-1-5-18/19/20 and S-1-5-80 service identities fail.
    let sid = &facts.sid;
    let service_sid = sid.len() >= 12
        && sid[0] == 1
        && sid[2..8] == [0, 0, 0, 0, 0, 5]
        && (matches!(
            u32::from_le_bytes(sid[8..12].try_into().unwrap()),
            18..=20 | 80
        ));
    if sid.is_empty()
        || sid != original_user
        || service_sid
        || facts.elevated
        || facts.app_container
        || !facts.interactive
        || facts.service
        || facts.session == 0
        || facts.session != session
        || !(0x2000..0x3000).contains(&facts.integrity)
    {
        bail!("install_ordinary_ui_required");
    }
    Ok(())
}
fn same_process(
    pid: u32,
    creation: u64,
    current_pid: u32,
    current_creation: u64,
    alive: bool,
) -> Result<()> {
    if pid == 0 || creation == 0 || pid != current_pid || creation != current_creation || !alive {
        bail!("install_ui_process_changed");
    }
    Ok(())
}

#[cfg(windows)]
mod native {
    use super::*;
    use ::windows::{
        core::{PCWSTR, PWSTR},
        Win32::{
            Foundation::{
                CloseHandle, DuplicateHandle, LocalFree, DUPLICATE_SAME_ACCESS, FILETIME, HANDLE,
                HLOCAL, WAIT_TIMEOUT,
            },
            Security::{
                Authorization::{
                    ConvertSidToStringSidW, ConvertStringSecurityDescriptorToSecurityDescriptorW,
                    GetSecurityInfo, SE_FILE_OBJECT,
                },
                GetAce, GetLengthSid, GetSecurityDescriptorControl, GetTokenInformation,
                IsValidSid, IsWellKnownSid, TokenElevation, TokenGroups, TokenIntegrityLevel,
                TokenIsAppContainer, TokenSessionId, TokenUser, WinBuiltinAdministratorsSid,
                WinInteractiveSid, WinLocalSystemSid, WinServiceSid, ACCESS_ALLOWED_ACE,
                ACE_HEADER, ACL, DACL_SECURITY_INFORMATION, OWNER_SECURITY_INFORMATION,
                PSECURITY_DESCRIPTOR, PSID, SECURITY_ATTRIBUTES, TOKEN_GROUPS,
                TOKEN_INFORMATION_CLASS, TOKEN_MANDATORY_LABEL, TOKEN_QUERY, TOKEN_USER,
            },
            Storage::FileSystem::{
                FileIdInfo, GetFileInformationByHandle, GetFileInformationByHandleEx,
                BY_HANDLE_FILE_INFORMATION, FILE_FLAG_BACKUP_SEMANTICS,
                FILE_FLAG_OPEN_REPARSE_POINT, FILE_ID_INFO, FILE_SHARE_READ,
            },
            System::{
                Pipes::{
                    GetNamedPipeClientProcessId, GetNamedPipeClientSessionId, GetNamedPipeInfo,
                    GetNamedPipeServerProcessId, PeekNamedPipe, NAMED_PIPE_MODE, PIPE_SERVER_END,
                },
                Threading::{
                    GetCurrentProcess, GetCurrentProcessId, GetProcessId, GetProcessTimes,
                    OpenProcess, OpenProcessToken, QueryFullProcessImageNameW, WaitForSingleObject,
                    PROCESS_NAME_WIN32, PROCESS_QUERY_LIMITED_INFORMATION, PROCESS_SYNCHRONIZE,
                },
            },
        },
    };
    use hbb_common::{
        anyhow::anyhow,
        tokio::net::windows::named_pipe::{NamedPipeServer, ServerOptions},
    };
    use sha2::{Digest, Sha256};
    use std::{
        ffi::{OsStr, OsString},
        fs::{File, OpenOptions},
        io::{Read, Seek, SeekFrom},
        os::windows::{
            ffi::{OsStrExt, OsStringExt},
            fs::OpenOptionsExt,
            io::AsRawHandle,
        },
        path::{Component, Path, PathBuf, Prefix},
    };

    struct Kernel(HANDLE);
    // Only owned kernel handles, never thread-affine UI objects. Verification is
    // synchronous on a blocking worker; no lock or impersonation crosses await.
    unsafe impl Send for Kernel {}
    impl Drop for Kernel {
        fn drop(&mut self) {
            unsafe {
                let _ = CloseHandle(self.0);
            }
        }
    }
    struct Descriptor(PSECURITY_DESCRIPTOR);
    impl Drop for Descriptor {
        fn drop(&mut self) {
            unsafe {
                let _ = LocalFree(Some(HLOCAL(self.0 .0)));
            }
        }
    }
    fn wide(value: &OsStr) -> Vec<u16> {
        value.encode_wide().chain(Some(0)).collect()
    }
    fn token(process: HANDLE) -> Result<Kernel> {
        let mut handle = HANDLE::default();
        unsafe {
            OpenProcessToken(process, TOKEN_QUERY, &mut handle)?;
        }
        Ok(Kernel(handle))
    }
    struct Information {
        words: Vec<usize>,
        bytes: usize,
    }
    impl Information {
        fn get<T: Copy>(&self) -> Result<T> {
            if self.bytes < std::mem::size_of::<T>() {
                bail!("install_ui_token_invalid");
            }
            Ok(unsafe { std::ptr::read_unaligned(self.words.as_ptr().cast::<T>()) })
        }
        fn sid(&self, sid: PSID) -> Result<Vec<u8>> {
            let start = self.words.as_ptr() as usize;
            let ptr = sid.0 as usize;
            if ptr < start
                || ptr
                    .checked_add(8)
                    .is_none_or(|end| end > start + self.bytes)
            {
                bail!("install_ui_token_sid_invalid");
            }
            let header = unsafe { std::slice::from_raw_parts(sid.0.cast::<u8>(), 8) };
            let len = 8usize + 4usize * usize::from(header[1]);
            if len > 68
                || ptr
                    .checked_add(len)
                    .is_none_or(|end| end > start + self.bytes)
                || !unsafe { IsValidSid(sid) }.as_bool()
                || unsafe { GetLengthSid(sid) } as usize != len
            {
                bail!("install_ui_token_sid_invalid");
            }
            Ok(unsafe { std::slice::from_raw_parts(sid.0.cast::<u8>(), len) }.to_vec())
        }
    }
    fn information(token: HANDLE, class: TOKEN_INFORMATION_CLASS) -> Result<Information> {
        let mut length = 0;
        unsafe {
            let _ = GetTokenInformation(token, class, None, 0, &mut length);
        }
        if length == 0 || length > 65536 {
            bail!("install_ui_token_invalid");
        }
        let capacity = length;
        let mut words = vec![0usize; (length as usize).div_ceil(std::mem::size_of::<usize>())];
        unsafe {
            GetTokenInformation(
                token,
                class,
                Some(words.as_mut_ptr().cast()),
                capacity,
                &mut length,
            )?;
        }
        if length == 0 || length > capacity {
            bail!("install_ui_token_invalid");
        }
        Ok(Information {
            words,
            bytes: length as usize,
        })
    }
    fn user(token: HANDLE) -> Result<Vec<u8>> {
        let data = information(token, TokenUser)?;
        data.sid(data.get::<TOKEN_USER>()?.User.Sid)
    }
    fn token_facts(token: HANDLE) -> Result<TokenFacts> {
        let groups = information(token, TokenGroups)?;
        let count = groups.get::<TOKEN_GROUPS>()?.GroupCount as usize;
        let offset = std::mem::offset_of!(TOKEN_GROUPS, Groups);
        let element = std::mem::size_of::<::windows::Win32::Security::SID_AND_ATTRIBUTES>();
        if count > 2048
            || offset
                + count
                    .checked_mul(element)
                    .ok_or_else(|| anyhow!("install_ui_token_invalid"))?
                > groups.bytes
        {
            bail!("install_ui_token_invalid");
        }
        let mut interactive = false;
        let mut service = false;
        for index in 0..count {
            let group = unsafe {
                std::ptr::read_unaligned(
                    groups
                        .words
                        .as_ptr()
                        .cast::<u8>()
                        .add(offset + index * element)
                        .cast::<::windows::Win32::Security::SID_AND_ATTRIBUTES>(),
                )
            };
            groups.sid(group.Sid)?;
            // SE_GROUP_ENABLED; a deny-only/disabled INTERACTIVE claim is not evidence.
            if group.Attributes & 4 != 0
                && unsafe { IsWellKnownSid(group.Sid, WinInteractiveSid) }.as_bool()
            {
                interactive = true;
            }
            if unsafe { IsWellKnownSid(group.Sid, WinServiceSid) }.as_bool() {
                service = true;
            }
        }
        let label = information(token, TokenIntegrityLevel)?;
        let sid = label.sid(label.get::<TOKEN_MANDATORY_LABEL>()?.Label.Sid)?;
        if sid.len() < 12 {
            bail!("install_ui_token_invalid");
        }
        Ok(TokenFacts {
            sid: user(token)?,
            session: information(token, TokenSessionId)?.get::<u32>()?,
            elevated: information(token, TokenElevation)?.get::<u32>()? != 0,
            app_container: information(token, TokenIsAppContainer)?.get::<u32>()? != 0,
            interactive,
            service,
            integrity: u32::from_le_bytes(sid[sid.len() - 4..].try_into().unwrap()),
        })
    }
    fn sid_string(sid: &mut [u8]) -> Result<String> {
        let mut string = PWSTR::null();
        unsafe {
            ConvertSidToStringSidW(PSID(sid.as_mut_ptr().cast()), &mut string)?;
        }
        let result = unsafe { string.to_string() };
        unsafe {
            let _ = LocalFree(Some(HLOCAL(string.0.cast())));
        }
        Ok(result?)
    }
    fn pipe_acl(pipe: HANDLE, user: &[u8]) -> Result<()> {
        let mut owner = PSID::default();
        let mut acl = std::ptr::null_mut::<ACL>();
        let mut descriptor = PSECURITY_DESCRIPTOR::default();
        unsafe {
            GetSecurityInfo(
                pipe,
                SE_FILE_OBJECT,
                OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION,
                Some(&mut owner),
                None,
                Some(&mut acl),
                None,
                Some(&mut descriptor),
            )
            .ok()?;
        }
        let _owned = Descriptor(descriptor);
        let mut control = 0;
        let mut revision = 0;
        unsafe {
            GetSecurityDescriptorControl(descriptor, &mut control, &mut revision)?;
        }
        if owner.0.is_null()
            || acl.is_null()
            || control & 0x1000 == 0
            || (!unsafe { IsWellKnownSid(owner, WinBuiltinAdministratorsSid) }.as_bool()
                && !unsafe { IsWellKnownSid(owner, WinLocalSystemSid) }.as_bool())
        {
            bail!("install_ui_pipe_unprotected");
        }
        let mut found_user = false;
        for index in 0..unsafe { (*acl).AceCount } {
            let mut raw = std::ptr::null_mut();
            unsafe {
                GetAce(acl, index as u32, &mut raw)?;
            }
            let header = unsafe { &*raw.cast::<ACE_HEADER>() };
            if header.AceType != 0 || header.AceFlags != 0 || usize::from(header.AceSize) < 8 {
                bail!("install_ui_pipe_unprotected");
            }
            let ace = unsafe { &*raw.cast::<ACCESS_ALLOWED_ACE>() };
            let sid = PSID((&ace.SidStart as *const u32).cast_mut().cast());
            if !unsafe { IsValidSid(sid) }.as_bool() {
                bail!("install_ui_pipe_unprotected");
            }
            let len = unsafe { GetLengthSid(sid) } as usize;
            if len + 8 > usize::from(header.AceSize) {
                bail!("install_ui_pipe_unprotected");
            }
            let value = unsafe { std::slice::from_raw_parts(sid.0.cast::<u8>(), len) };
            if value == user {
                if ace.Mask != 0x0012019b {
                    bail!("install_ui_pipe_unprotected");
                }
                found_user = true;
            } else if !unsafe { IsWellKnownSid(sid, WinBuiltinAdministratorsSid) }.as_bool()
                && !unsafe { IsWellKnownSid(sid, WinLocalSystemSid) }.as_bool()
            {
                bail!("install_ui_pipe_unprotected");
            }
        }
        if !found_user {
            bail!("install_ui_pipe_unprotected");
        }
        Ok(())
    }

    /// No production constructor: only a future dedicated setup wrapper may
    /// provide pins from its authenticated embedded release, never command JSON.
    pub(crate) struct FixedReleaseUiImage {
        path: PathBuf,
        sha256: [u8; 32],
        size: u64,
    }
    impl FixedReleaseUiImage {
        fn validate(&self) -> Result<()> {
            if self.size == 0 || self.size > MAX_IMAGE_BYTES || self.sha256.iter().all(|b| *b == 0)
            {
                bail!("install_ui_release_pin_invalid");
            }
            let mut components = self.path.components();
            match components.next() {
                Some(Component::Prefix(prefix))
                    if matches!(prefix.kind(), Prefix::Disk(_) | Prefix::VerbatimDisk(_)) =>
                {
                    ()
                }
                _ => bail!("install_ui_local_image_required"),
            }
            if !matches!(components.next(), Some(Component::RootDir))
                || components
                    .clone()
                    .any(|c| !matches!(c, Component::Normal(_)))
            {
                bail!("install_ui_local_image_required");
            }
            Ok(())
        }
    }
    struct ImagePin {
        file: File,
        identity: FileIdentity,
        size: u64,
        digest: [u8; 32],
        path: PathBuf,
        ancestors: Vec<(File, FileIdentity)>,
    }
    fn file_identity(file: &File, directory: bool) -> Result<(FileIdentity, u64)> {
        let handle = HANDLE(file.as_raw_handle());
        let mut info = BY_HANDLE_FILE_INFORMATION::default();
        let mut id = FILE_ID_INFO::default();
        unsafe {
            GetFileInformationByHandle(handle, &mut info)?;
            GetFileInformationByHandleEx(
                handle,
                FileIdInfo,
                (&mut id as *mut FILE_ID_INFO).cast(),
                std::mem::size_of::<FILE_ID_INFO>() as u32,
            )?;
        }
        let size = (u64::from(info.nFileSizeHigh) << 32) | u64::from(info.nFileSizeLow);
        file_policy(info.dwFileAttributes, info.nNumberOfLinks, size, directory)?;
        let identity = FileIdentity {
            volume: id.VolumeSerialNumber,
            id: id.FileId.Identifier,
        };
        if identity.id.iter().all(|b| *b == 0) {
            bail!("install_ui_image_identity_invalid");
        }
        Ok((identity, size))
    }
    fn open_file(path: &Path, directory: bool) -> Result<File> {
        let file = OpenOptions::new()
            .read(true)
            .share_mode(FILE_SHARE_READ.0)
            .custom_flags((FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_BACKUP_SEMANTICS).0)
            .open(path)?;
        file_identity(&file, directory)?;
        Ok(file)
    }
    fn digest(file: &mut File, size: u64) -> Result<[u8; 32]> {
        file.seek(SeekFrom::Start(0))?;
        let mut hash = Sha256::new();
        let mut remaining = size;
        let mut buffer = [0u8; 65536];
        while remaining != 0 {
            let n = file.read(&mut buffer[..remaining.min(65536) as usize])?;
            if n == 0 {
                bail!("install_ui_image_size_changed");
            }
            hash.update(&buffer[..n]);
            remaining -= n as u64;
        }
        if file.read(&mut buffer[..1])? != 0 {
            bail!("install_ui_image_size_changed");
        }
        Ok(hash.finalize().into())
    }
    impl ImagePin {
        fn open(expected: &FixedReleaseUiImage) -> Result<Self> {
            expected.validate()?;
            let mut ancestors = Vec::new();
            for path in expected
                .path
                .parent()
                .ok_or_else(|| anyhow!("install_ui_local_image_required"))?
                .ancestors()
            {
                let file = open_file(path, true)?;
                let identity = file_identity(&file, true)?.0;
                ancestors.push((file, identity));
            }
            let mut file = open_file(&expected.path, false)?;
            let (identity, size) = file_identity(&file, false)?;
            if size != expected.size {
                bail!("install_ui_image_release_mismatch");
            }
            let actual = digest(&mut file, size)?;
            if actual != expected.sha256 {
                bail!("install_ui_image_release_mismatch");
            }
            Ok(Self {
                file,
                identity,
                size,
                digest: actual,
                path: expected.path.canonicalize()?,
                ancestors,
            })
        }
        fn revalidate(&mut self, process: HANDLE) -> Result<()> {
            for (file, id) in &self.ancestors {
                if file_identity(file, true)?.0 != *id {
                    bail!("install_ui_image_changed");
                }
            }
            let (id, size) = file_identity(&self.file, false)?;
            if id != self.identity
                || size != self.size
                || digest(&mut self.file, size)? != self.digest
            {
                bail!("install_ui_image_changed");
            }
            let actual_path = process_path(process)?;
            if actual_path.canonicalize()? != self.path {
                bail!("install_ui_image_changed");
            }
            let actual = open_file(&actual_path, false)?;
            if file_identity(&actual, false)?.0 != self.identity {
                bail!("install_ui_image_changed");
            }
            Ok(())
        }
    }
    fn process_path(process: HANDLE) -> Result<PathBuf> {
        let mut path = vec![0u16; 32768];
        let mut len = path.len() as u32;
        unsafe {
            QueryFullProcessImageNameW(
                process,
                PROCESS_NAME_WIN32,
                PWSTR(path.as_mut_ptr()),
                &mut len,
            )?;
        }
        if len == 0 || len as usize >= path.len() || path[..len as usize].contains(&0) {
            bail!("install_ui_image_invalid");
        }
        Ok(PathBuf::from(OsString::from_wide(&path[..len as usize])))
    }
    fn process_facts(process: HANDLE) -> Result<(u32, u64, bool)> {
        let mut creation = FILETIME::default();
        let mut exit = FILETIME::default();
        let mut kernel = FILETIME::default();
        let mut user = FILETIME::default();
        unsafe {
            GetProcessTimes(process, &mut creation, &mut exit, &mut kernel, &mut user)?;
        }
        Ok((
            unsafe { GetProcessId(process) },
            (u64::from(creation.dwHighDateTime) << 32) | u64::from(creation.dwLowDateTime),
            unsafe { WaitForSingleObject(process, 0) } == WAIT_TIMEOUT
                && exit.dwHighDateTime == 0
                && exit.dwLowDateTime == 0,
        ))
    }
    fn connected_pid(pipe: HANDLE, session: u32, original_user: &[u8]) -> Result<u32> {
        pipe_acl(pipe, original_user)?;
        let mut flags = NAMED_PIPE_MODE::default();
        let mut server = 0;
        let mut pid = 0;
        let mut found_session = 0;
        unsafe {
            GetNamedPipeInfo(pipe, Some(&mut flags), None, None, None)?;
            GetNamedPipeServerProcessId(pipe, &mut server)?;
            GetNamedPipeClientProcessId(pipe, &mut pid)?;
            GetNamedPipeClientSessionId(pipe, &mut found_session)?;
            PeekNamedPipe(pipe, None, 0, None, None, None)?;
        }
        if flags.0 & PIPE_SERVER_END.0 == 0
            || server != unsafe { GetCurrentProcessId() }
            || pid == 0
            || found_session != session
        {
            bail!("install_ui_pipe_origin_invalid");
        }
        Ok(pid)
    }

    pub(in super::super) struct PreparedUiProcess {
        process: Kernel,
        pid: u32,
        creation: u64,
        facts: TokenFacts,
        expected: FixedReleaseUiImage,
        image: ImagePin,
    }
    impl PreparedUiProcess {
        pub(in super::super) fn from_compiled(
            pid: u32,
            release: &super::super::embedded_release::EmbeddedRelease,
        ) -> Result<Self> {
            if pid == 0 {
                bail!("install_ui_process_invalid");
            }
            let process = Kernel(unsafe {
                OpenProcess(
                    PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_SYNCHRONIZE,
                    false,
                    pid,
                )?
            });
            let (actual, creation, alive) = process_facts(process.0)?;
            same_process(pid, creation, actual, creation, alive)?;
            let facts = token_facts(token(process.0)?.0)?;
            ordinary_ui(&facts, &facts.sid, facts.session)?;
            let path = process_path(process.0)?;
            let directory = path
                .parent()
                .ok_or_else(|| anyhow!("install_ui_image_invalid"))?;
            let expected = FixedReleaseUiImage {
                path: release.ui_path(directory),
                sha256: release.ui_sha(),
                size: release.ui_length(),
            };
            let mut image = ImagePin::open(&expected)?;
            image.revalidate(process.0)?;
            if release.mode() == super::super::embedded_release::TrustMode::SignedProduction {
                super::super::windows::authenticode(&image.file, &image.path)?;
            }
            Ok(Self {
                process,
                pid,
                creation,
                facts,
                expected,
                image,
            })
        }
        fn revalidate(&mut self) -> Result<()> {
            let (pid, creation, alive) = process_facts(self.process.0)?;
            same_process(self.pid, self.creation, pid, creation, alive)?;
            ordinary_ui(
                &token_facts(token(self.process.0)?.0)?,
                &self.facts.sid,
                self.facts.session,
            )?;
            self.image.revalidate(self.process.0)
        }
    }
    pub(in super::super) fn require_elevated_visible_setup() -> Result<()> {
        let facts = token_facts(token(unsafe { GetCurrentProcess() })?.0)?;
        if !facts.elevated
            || facts.session == 0
            || !facts.interactive
            || facts.service
            || facts.app_container
        {
            bail!("install_elevated_interactive_setup_required");
        }
        Ok(())
    }
    pub(in super::super) fn require_visible_ordinary_ui() -> Result<()> {
        let facts = token_facts(token(unsafe { GetCurrentProcess() })?.0)?;
        ordinary_ui(&facts, &facts.sid, facts.session)?;
        let window = unsafe { ::windows::Win32::UI::WindowsAndMessaging::GetForegroundWindow() };
        let mut pid = 0;
        unsafe {
            ::windows::Win32::UI::WindowsAndMessaging::GetWindowThreadProcessId(
                window,
                Some(&mut pid),
            )
        };
        if window.0.is_null()
            || pid != unsafe { GetCurrentProcessId() }
            || !unsafe { ::windows::Win32::UI::WindowsAndMessaging::IsWindowVisible(window) }
                .as_bool()
        {
            bail!("install_visible_local_ui_required");
        }
        Ok(())
    }
    /// Selected by an explicit native local action, not publisher trust. Its
    /// opened file/parents remain pinned through UAC and password handoff.
    pub(in super::super) struct SelectedSetup {
        image: ImagePin,
    }
    impl SelectedSetup {
        pub(in super::super) fn open(path: PathBuf) -> Result<Self> {
            if path
                .extension()
                .and_then(|x| x.to_str())
                .map(|x| x.eq_ignore_ascii_case("exe"))
                != Some(true)
            {
                bail!("install_selected_executable_required");
            }
            let mut file = open_file(&path, false)?;
            let size = file_identity(&file, false)?.1;
            let mut header = [0u8; 64];
            file.read_exact(&mut header)?;
            if &header[..2] != b"MZ" {
                bail!("install_selected_pe_required");
            }
            let offset = u32::from_le_bytes(header[60..64].try_into().unwrap()) as u64;
            if offset < 64 || offset.checked_add(26).is_none_or(|end| end > size) {
                bail!("install_selected_pe_required");
            }
            file.seek(SeekFrom::Start(offset))?;
            let mut pe = [0u8; 26];
            file.read_exact(&mut pe)?;
            if &pe[..4] != b"PE\0\0"
                || u16::from_le_bytes([pe[4], pe[5]]) != 0x8664
                || u16::from_le_bytes([pe[24], pe[25]]) != 0x20b
            {
                bail!("install_selected_x64_pe_required");
            }
            let sha256 = digest(&mut file, size)?;
            let expected = FixedReleaseUiImage { path, sha256, size };
            Ok(Self {
                image: ImagePin::open(&expected)?,
            })
        }
        pub(in super::super) fn path(&self) -> &Path {
            &self.image.path
        }
        pub(in super::super) fn digest_hex(&self) -> String {
            self.image
                .digest
                .iter()
                .map(|b| format!("{b:02x}"))
                .collect()
        }
        pub(in super::super) fn validate_process(&mut self, process: HANDLE) -> Result<()> {
            let facts = token_facts(token(process)?.0)?;
            if !facts.elevated
                || facts.session == 0
                || !facts.interactive
                || facts.service
                || facts.app_container
            {
                bail!("install_setup_server_not_elevated_interactive");
            }
            self.image.revalidate(process)
        }
    }
    /// Created here so server-end/first-instance/local-only provenance cannot be
    /// claimed by a raw HANDLE. One instance is never disconnected/recycled.
    pub(crate) struct ProtectedUiPipe {
        server: NamedPipeServer,
        user: Vec<u8>,
        session: u32,
    }
    impl ProtectedUiPipe {
        pub(crate) fn create(_release: &FixedReleaseUiImage) -> Result<Self> {
            _release.validate()?;
            let current = token(unsafe { GetCurrentProcess() })?;
            let facts = token_facts(current.0)?;
            // Dedicated elevated setup may own the server; client must be the
            // same original user/session and independently non-elevated below.
            if facts.sid.is_empty() || facts.session == 0 || facts.service || !facts.interactive {
                bail!("install_ui_setup_user_required");
            }
            let mut sid = facts.sid.clone();
            let sddl = format!(
                "O:BAG:BAD:P(A;;GA;;;SY)(A;;GA;;;BA)(A;;0x0012019b;;;{})",
                sid_string(&mut sid)?
            );
            let text = wide(OsStr::new(&sddl));
            let mut descriptor = PSECURITY_DESCRIPTOR::default();
            unsafe {
                ConvertStringSecurityDescriptorToSecurityDescriptorW(
                    PCWSTR(text.as_ptr()),
                    1,
                    &mut descriptor,
                    None,
                )?;
            }
            let _owned = Descriptor(descriptor);
            let mut attrs = SECURITY_ATTRIBUTES {
                nLength: std::mem::size_of::<SECURITY_ATTRIBUTES>() as u32,
                lpSecurityDescriptor: descriptor.0,
                bInheritHandle: false.into(),
            };
            let nonce = hbb_common::sodiumoxide::randombytes::randombytes(32);
            let suffix: String = nonce.iter().map(|byte| format!("{byte:02x}")).collect();
            let mut options = ServerOptions::new();
            options
                .first_pipe_instance(true)
                .reject_remote_clients(true)
                .max_instances(1)
                .in_buffer_size(4096)
                .out_buffer_size(4096);
            let server = unsafe {
                options.create_with_security_attributes_raw(
                    format!(r"\\.\pipe\NikoDesk.install.v1.{suffix}"),
                    (&mut attrs as *mut SECURITY_ATTRIBUTES).cast(),
                )?
            };
            pipe_acl(HANDLE(server.as_raw_handle()), &facts.sid)?;
            Ok(Self {
                server,
                user: facts.sid,
                session: facts.session,
            })
        }

        pub(in super::super) fn for_prepared_ui(
            origin: &mut PreparedUiProcess,
            nonce: &[u8; 32],
        ) -> Result<Self> {
            origin.revalidate()?;
            require_elevated_visible_setup()?;
            if nonce == &[0; 32] {
                bail!("install_nonce_invalid");
            }
            let mut sid = origin.facts.sid.clone();
            let sddl = format!(
                "O:BAG:BAD:P(A;;GA;;;SY)(A;;GA;;;BA)(A;;0x0012019b;;;{})",
                sid_string(&mut sid)?
            );
            let text = wide(OsStr::new(&sddl));
            let mut descriptor = PSECURITY_DESCRIPTOR::default();
            unsafe {
                ConvertStringSecurityDescriptorToSecurityDescriptorW(
                    PCWSTR(text.as_ptr()),
                    1,
                    &mut descriptor,
                    None,
                )?;
            }
            let _owned = Descriptor(descriptor);
            let mut attrs = SECURITY_ATTRIBUTES {
                nLength: std::mem::size_of::<SECURITY_ATTRIBUTES>() as u32,
                lpSecurityDescriptor: descriptor.0,
                bInheritHandle: false.into(),
            };
            let mut options = ServerOptions::new();
            options
                .first_pipe_instance(true)
                .reject_remote_clients(true)
                .max_instances(1)
                .in_buffer_size(8192)
                .out_buffer_size(8192);
            let server = unsafe {
                options.create_with_security_attributes_raw(
                    super::super::wire::pipe_name(nonce),
                    (&mut attrs as *mut SECURITY_ATTRIBUTES).cast(),
                )?
            };
            pipe_acl(HANDLE(server.as_raw_handle()), &origin.facts.sid)?;
            Ok(Self {
                server,
                user: origin.facts.sid.clone(),
                session: origin.facts.session,
            })
        }
        pub(in super::super) fn verify_prepared(
            &self,
            origin: &mut PreparedUiProcess,
            namespace: [u8; 32],
            generation: u64,
        ) -> Result<VerifiedUiCaller> {
            origin.revalidate()?;
            let caller = self.verify_connected(&origin.expected, namespace, generation)?;
            if caller.pid != origin.pid || caller.creation != origin.creation {
                bail!("install_ui_process_changed");
            }
            origin.revalidate()?;
            Ok(caller)
        }
        pub(in super::super) fn into_stream(self) -> NamedPipeServer {
            self.server
        }
        pub(in super::super) async fn read(&mut self) -> Result<super::super::wire::Packet> {
            super::super::wire::read_packet(&mut self.server).await
        }
        pub(in super::super) async fn write(
            &mut self,
            packet: &super::super::wire::Packet,
        ) -> Result<()> {
            super::super::wire::write_packet(&mut self.server, packet).await
        }
        pub(crate) async fn connect(&self) -> Result<()> {
            self.server.connect().await?;
            Ok(())
        }
        pub(crate) fn verify_connected(
            &self,
            expected: &FixedReleaseUiImage,
            namespace: [u8; 32],
            settings_generation: u64,
        ) -> Result<VerifiedUiCaller> {
            captured_context(&namespace, settings_generation)?;
            let mut duplicate = HANDLE::default();
            unsafe {
                DuplicateHandle(
                    GetCurrentProcess(),
                    HANDLE(self.server.as_raw_handle()),
                    GetCurrentProcess(),
                    &mut duplicate,
                    0,
                    false,
                    DUPLICATE_SAME_ACCESS,
                )?;
            }
            let pipe = Kernel(duplicate);
            let pid = connected_pid(pipe.0, self.session, &self.user)?;
            let process = Kernel(unsafe {
                OpenProcess(
                    PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_SYNCHRONIZE,
                    false,
                    pid,
                )?
            });
            let (handle_pid, creation, alive) = process_facts(process.0)?;
            same_process(pid, creation, handle_pid, creation, alive)?;
            let peer = token(process.0)?;
            ordinary_ui(&token_facts(peer.0)?, &self.user, self.session)?;
            let mut image = ImagePin::open(expected)?;
            image.revalidate(process.0)?;
            let mut caller = VerifiedUiCaller {
                pipe,
                process,
                pid,
                creation,
                user: self.user.clone(),
                session: self.session,
                image,
                namespace,
                settings_generation,
            };
            caller.revalidate()?;
            Ok(caller)
        }
    }
    pub(crate) struct VerifiedUiCaller {
        pipe: Kernel,
        process: Kernel,
        pid: u32,
        creation: u64,
        user: Vec<u8>,
        session: u32,
        image: ImagePin,
        namespace: [u8; 32],
        settings_generation: u64,
    }
    impl VerifiedUiCaller {
        pub(crate) fn revalidate(&mut self) -> Result<()> {
            let pipe_pid = connected_pid(self.pipe.0, self.session, &self.user)?;
            let (pid, creation, alive) = process_facts(self.process.0)?;
            same_process(self.pid, self.creation, pid, creation, alive)?;
            if pipe_pid != self.pid {
                bail!("install_ui_pipe_origin_changed");
            }
            ordinary_ui(
                &token_facts(token(self.process.0)?.0)?,
                &self.user,
                self.session,
            )?;
            self.image.revalidate(self.process.0)?;
            captured_context(&self.namespace, self.settings_generation)?;
            // Repeat after potentially expensive hashing; caller death/rebind
            // during file verification must not produce a current origin proof.
            let (pid, creation, alive) = process_facts(self.process.0)?;
            same_process(self.pid, self.creation, pid, creation, alive)?;
            if connected_pid(self.pipe.0, self.session, &self.user)? != self.pid {
                bail!("install_ui_pipe_origin_changed");
            }
            Ok(())
        }
        pub(in super::super) fn user_sid_string(&self) -> Result<String> {
            sid_string(&mut self.user.clone())
        }
        pub(crate) fn pid(&self) -> u32 {
            self.pid
        }
        pub(crate) fn creation(&self) -> u64 {
            self.creation
        }
        pub(crate) fn user_sid_bytes(&self) -> &[u8] {
            &self.user
        }
        pub(crate) fn namespace(&self) -> &[u8; 32] {
            &self.namespace
        }
        pub(crate) fn settings_generation(&self) -> u64 {
            self.settings_generation
        }
        pub(crate) fn image_sha256(&self) -> &[u8; 32] {
            &self.image.digest
        }
    }
}
#[cfg(windows)]
pub(super) use native::{
    require_elevated_visible_setup, require_visible_ordinary_ui, PreparedUiProcess, SelectedSetup,
};
#[cfg(windows)]
pub(crate) use native::{FixedReleaseUiImage, ProtectedUiPipe, VerifiedUiCaller};

#[cfg(test)]
mod tests {
    use super::*;
    fn ordinary() -> TokenFacts {
        TokenFacts {
            sid: vec![1, 1, 0, 0, 0, 0, 0, 5, 21, 0, 0, 0],
            session: 2,
            elevated: false,
            app_container: false,
            interactive: true,
            service: false,
            integrity: 0x2000,
        }
    }
    #[test]
    fn namespace_or_revision_is_never_a_process_origin() {
        assert!(captured_context(&[0; 32], 1).is_err());
        assert!(captured_context(&[1; 32], 0).is_err());
        assert!(captured_context(&[1; 32], 9).is_ok());
        assert!(same_process(0, 0, 0, 0, true).is_err());
    }
    #[test]
    fn pid_reuse_death_or_creation_change_is_rejected() {
        assert!(same_process(7, 8, 7, 8, true).is_ok());
        for facts in [(7, 9, true), (8, 8, true), (7, 8, false)] {
            assert!(same_process(7, 8, facts.0, facts.1, facts.2).is_err());
        }
    }
    #[test]
    fn actual_token_policy_rejects_elevation_service_or_noninteractive() {
        let base = ordinary();
        assert!(ordinary_ui(&base, &base.sid, 2).is_ok());
        for field in 0..6 {
            let mut value = ordinary();
            match field {
                0 => value.elevated = true,
                1 => value.service = true,
                2 => value.interactive = false,
                3 => value.app_container = true,
                4 => value.integrity = 0x3000,
                _ => value.integrity = 0x1000,
            };
            assert!(ordinary_ui(&value, &base.sid, 2).is_err());
        }
    }
    #[test]
    fn system_local_network_and_service_sids_are_rejected() {
        for rid in [18u32, 19, 20, 80] {
            let mut value = ordinary();
            value.sid[8..12].copy_from_slice(&rid.to_le_bytes());
            assert!(ordinary_ui(&value, &value.sid, 2).is_err());
        }
    }
    #[test]
    fn kernel_sid_and_session_must_match_original_server_user() {
        let value = ordinary();
        assert!(ordinary_ui(&value, &[1; 12], 2).is_err());
        assert!(ordinary_ui(&value, &value.sid, 3).is_err());
    }
    #[test]
    fn image_file_policy_rejects_reparse_hardlinks_and_unbounded_size() {
        assert!(file_policy(0, 1, 128, false).is_ok());
        for facts in [
            (0x400, 1, 128),
            (0, 2, 128),
            (0, 0, 128),
            (0, 1, 0),
            (0, 1, MAX_IMAGE_BYTES + 1),
            (0x10, 1, 128),
        ] {
            assert!(file_policy(facts.0, facts.1, facts.2, false).is_err());
        }
        assert!(file_policy(0x10, 0, 0, true).is_ok());
    }
}
