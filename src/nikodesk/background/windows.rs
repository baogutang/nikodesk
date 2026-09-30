//! Windows SCM/supervision implementation. Never installs or elevates itself.
use super::{
    policy::*,
    protocol::{self, Packet},
    worker,
};
use hbb_common::toml;
use hbb_common::{
    anyhow::{anyhow, Context},
    bail,
    rand::RngCore,
    tokio, ResultType,
};
use sha2::{Digest, Sha256};
use std::{
    ffi::OsString,
    fs::{self, File, OpenOptions},
    io::Read,
    os::windows::{
        ffi::OsStrExt,
        fs::{MetadataExt, OpenOptionsExt},
        io::AsRawHandle,
    },
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc,
    },
    time::Duration,
};
use windows::{
    core::{PCWSTR, PWSTR},
    Win32::{
        Foundation::{
            CloseHandle, DuplicateHandle, LocalFree, DUPLICATE_SAME_ACCESS, FILETIME, HANDLE,
            HLOCAL, WAIT_OBJECT_0,
        },
        Security::{
            Authorization::{
                ConvertStringSecurityDescriptorToSecurityDescriptorW, GetSecurityInfo,
                SE_FILE_OBJECT,
            },
            DuplicateTokenEx, GetAce, GetTokenInformation, IsWellKnownSid, SecurityImpersonation,
            TokenPrimary, TokenUser, WinBuiltinAdministratorsSid, WinLocalSystemSid,
            ACCESS_ALLOWED_ACE, ACE_HEADER, ACL, DACL_SECURITY_INFORMATION,
            OWNER_SECURITY_INFORMATION, PSECURITY_DESCRIPTOR, PSID, SECURITY_ATTRIBUTES,
            TOKEN_ALL_ACCESS, TOKEN_QUERY, TOKEN_USER,
        },
        Storage::FileSystem::{
            GetFileInformationByHandle, BY_HANDLE_FILE_INFORMATION, FILE_FLAG_BACKUP_SEMANTICS,
            FILE_FLAG_OPEN_REPARSE_POINT, FILE_SHARE_READ,
        },
        System::{
            Com::CoTaskMemFree,
            Diagnostics::ToolHelp::{
                CreateToolhelp32Snapshot, Process32FirstW, Process32NextW, PROCESSENTRY32W,
                TH32CS_SNAPPROCESS,
            },
            Environment::{CreateEnvironmentBlock, DestroyEnvironmentBlock},
            JobObjects::{
                AssignProcessToJobObject, CreateJobObjectW, JobObjectExtendedLimitInformation,
                SetInformationJobObject, TerminateJobObject, JOBOBJECT_EXTENDED_LIMIT_INFORMATION,
                JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
            },
            Pipes::{GetNamedPipeClientProcessId, GetNamedPipeServerProcessId},
            RemoteDesktop::{ProcessIdToSessionId, WTSGetActiveConsoleSessionId},
            Threading::{
                CreateProcessAsUserW, GetCurrentProcess, GetCurrentProcessId, GetExitCodeProcess,
                GetProcessTimes, OpenProcess, OpenProcessToken, QueryFullProcessImageNameW,
                ResumeThread, WaitForSingleObject, CREATE_NO_WINDOW, CREATE_SUSPENDED,
                CREATE_UNICODE_ENVIRONMENT, PROCESS_INFORMATION, PROCESS_NAME_WIN32,
                PROCESS_QUERY_LIMITED_INFORMATION, STARTUPINFOW,
            },
        },
        UI::Shell::{
            FOLDERID_ProgramData, FOLDERID_ProgramFiles, SHGetKnownFolderPath, KNOWN_FOLDER_FLAG,
        },
    },
};
use windows_service::{
    define_windows_service,
    service::{
        ServiceControl, ServiceControlAccept, ServiceExitCode, ServiceState, ServiceStatus,
        ServiceType,
    },
    service_control_handler::{self, ServiceControlHandlerResult},
};

pub(crate) struct Owned(HANDLE);
// These are owned kernel process/token/job/snapshot/pipe handles, never thread-bound
// desktop/window handles. Blocking verification may transfer them between threads.
unsafe impl Send for Owned {}
impl Owned {
    fn get(&self) -> HANDLE {
        self.0
    }
}
impl Drop for Owned {
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
fn wide(path: impl AsRef<std::ffi::OsStr>) -> Vec<u16> {
    path.as_ref().encode_wide().chain(Some(0)).collect()
}
fn system_token(process: HANDLE) -> ResultType<Owned> {
    let mut token = HANDLE::default();
    unsafe {
        OpenProcessToken(process, TOKEN_QUERY, &mut token)?;
    }
    let token = Owned(token);
    let mut length = 0;
    unsafe {
        let _ = GetTokenInformation(token.get(), TokenUser, None, 0, &mut length);
    }
    if length == 0 || length > 65536 {
        bail!("Invalid background token");
    }
    let mut bytes = vec![
        0usize;
        (length as usize + std::mem::size_of::<usize>() - 1)
            / std::mem::size_of::<usize>()
    ];
    unsafe {
        GetTokenInformation(
            token.get(),
            TokenUser,
            Some(bytes.as_mut_ptr().cast()),
            length,
            &mut length,
        )?;
        let user = &*bytes.as_ptr().cast::<TOKEN_USER>();
        if !IsWellKnownSid(user.User.Sid, WinLocalSystemSid).as_bool() {
            bail!("Background role requires LocalSystem");
        }
    }
    Ok(token)
}
fn assert_system(session: Option<u32>) -> ResultType<()> {
    system_token(unsafe { GetCurrentProcess() })?;
    if let Some(expected) = session {
        let mut found = 0;
        unsafe {
            ProcessIdToSessionId(GetCurrentProcessId(), &mut found)?;
        }
        if found != expected {
            bail!("Background process is in the wrong system session");
        }
    }
    Ok(())
}
fn known_folder(id: &windows::core::GUID) -> ResultType<PathBuf> {
    let p = unsafe { SHGetKnownFolderPath(id, KNOWN_FOLDER_FLAG(0), None)? };
    let result = unsafe { p.to_string() }.map(PathBuf::from);
    unsafe {
        CoTaskMemFree(Some(p.0.cast()));
    }
    Ok(result?)
}
fn protected_file(path: &Path, directory: bool, system_owner: bool) -> ResultType<File> {
    if !path.is_absolute() {
        bail!("Background path must be absolute");
    }
    for ancestor in path.ancestors() {
        let meta = fs::symlink_metadata(ancestor)?;
        if meta.file_attributes() & 0x400 != 0 {
            bail!("Reparse background path rejected");
        }
    }
    let file = OpenOptions::new()
        .read(true)
        .share_mode(FILE_SHARE_READ.0)
        .custom_flags(
            FILE_FLAG_OPEN_REPARSE_POINT.0
                | if directory {
                    FILE_FLAG_BACKUP_SEMANTICS.0
                } else {
                    0
                },
        )
        .open(path)?;
    let meta = file.metadata()?;
    if meta.file_attributes() & 0x400 != 0
        || if directory {
            !meta.is_dir()
        } else {
            !meta.is_file()
        }
    {
        bail!("Invalid background storage object");
    }
    if !directory {
        let mut info = BY_HANDLE_FILE_INFORMATION::default();
        unsafe {
            GetFileInformationByHandle(HANDLE(file.as_raw_handle()), &mut info)?;
        }
        if info.nNumberOfLinks != 1 {
            bail!("Hard-linked background file rejected");
        }
    }
    let mut owner = PSID::default();
    let mut acl = std::ptr::null_mut::<ACL>();
    let mut descriptor = PSECURITY_DESCRIPTOR::default();
    unsafe {
        GetSecurityInfo(
            HANDLE(file.as_raw_handle()),
            SE_FILE_OBJECT,
            DACL_SECURITY_INFORMATION | OWNER_SECURITY_INFORMATION,
            Some(&mut owner),
            None,
            Some(&mut acl),
            None,
            Some(&mut descriptor),
        )
        .ok()?;
    }
    let _descriptor = Descriptor(descriptor);
    if acl.is_null() || owner.0.is_null() {
        bail!("Unprotected background storage");
    }
    unsafe {
        let sys = IsWellKnownSid(owner, WinLocalSystemSid).as_bool();
        let admin = IsWellKnownSid(owner, WinBuiltinAdministratorsSid).as_bool();
        if !sys && (system_owner || !admin) {
            bail!("Background storage owner is not trusted");
        }
        for index in 0..(*acl).AceCount {
            let mut raw = std::ptr::null_mut();
            GetAce(acl, index as u32, &mut raw)?;
            let header = &*raw.cast::<ACE_HEADER>();
            if (header.AceFlags & 8 != 0 && !directory) || header.AceType == 1 {
                continue;
            }
            if header.AceType != 0
                || header.AceSize < std::mem::size_of::<ACCESS_ALLOWED_ACE>() as u16
            {
                bail!("Unsupported background DACL");
            }
            let ace = &*raw.cast::<ACCESS_ALLOWED_ACE>();
            let sid = PSID((&ace.SidStart as *const u32).cast_mut().cast());
            let trusted = IsWellKnownSid(sid, WinLocalSystemSid).as_bool()
                || IsWellKnownSid(sid, WinBuiltinAdministratorsSid).as_bool();
            if !allows_storage_ace(ace.Mask, trusted, system_owner) {
                bail!("Background storage grants an unsafe principal access");
            }
        }
    }
    Ok(file)
}
fn verify_config_tree(directory: &Path, depth: usize, remaining: &mut usize) -> ResultType<()> {
    if depth > 8 {
        bail!("Machine configuration nesting exceeds limit");
    }
    let _directory = protected_file(directory, true, true)?;
    for entry in fs::read_dir(directory)? {
        let entry = entry?;
        if *remaining == 0 {
            bail!("Machine configuration entries exceed limit");
        }
        *remaining -= 1;
        let metadata = fs::symlink_metadata(entry.path())?;
        if metadata.is_dir() {
            verify_config_tree(&entry.path(), depth + 1, remaining)?;
        } else {
            protected_file(&entry.path(), false, true)?;
        }
    }
    Ok(())
}
fn bytes(file: &File, limit: u64) -> ResultType<Vec<u8>> {
    if file.metadata()?.len() > limit {
        bail!("Background file exceeds limit");
    }
    let mut content = Vec::new();
    file.take(limit + 1).read_to_end(&mut content)?;
    if content.len() as u64 > limit {
        bail!("Background file exceeds limit");
    }
    Ok(content)
}
pub(crate) struct Layout {
    pub config: PathBuf,
    install: PathBuf,
    provision: Provision,
    _pins: Vec<File>,
}
impl Layout {
    fn verify() -> ResultType<Self> {
        let install = known_folder(&FOLDERID_ProgramFiles)?.join("NikoDesk");
        let machine = known_folder(&FOLDERID_ProgramData)?.join("NikoDesk");
        let host = machine.join("host");
        let config = host.join("config");
        let mut pins = vec![
            protected_file(&install, true, false)?,
            protected_file(&machine, true, true)?,
            protected_file(&host, true, true)?,
            protected_file(&config, true, true)?,
        ];
        let provision_file = protected_file(&host.join("provision-v1.json"), false, true)?;
        let provision: Provision = serde_json::from_slice(&bytes(&provision_file, 64 * 1024)?)
            .map_err(|_| anyhow!("Invalid background provision"))?;
        provision.validate().map_err(|e| anyhow!(e))?;
        pins.push(provision_file);
        for (name, hash) in &provision.files {
            let file = protected_file(&install.join(name), false, false)?;
            if format!("{:x}", Sha256::digest(bytes(&file, 512 * 1024 * 1024)?)) != *hash {
                bail!("Background executable or dependency pin mismatch");
            }
            pins.push(file);
        }
        for entry in fs::read_dir(&install)? {
            let entry = entry?;
            let name = entry.file_name().to_string_lossy().into_owned();
            if matches!(
                entry
                    .path()
                    .extension()
                    .and_then(|v| v.to_str())
                    .map(|v| v.to_ascii_lowercase())
                    .as_deref(),
                Some("dll" | "exe")
            ) && !provision.files.contains_key(&name)
            {
                bail!("Unpinned background executable dependency");
            }
        }
        let expected = install.join(HOST_EXE).canonicalize()?;
        if std::env::current_exe()?.canonicalize()? != expected {
            bail!("Background binary is outside protected installation");
        }
        // Read-only preflight: provisioned identity must exist. No user keys copied/generated here.
        let identity = protected_file(&config.join("NikoDesk.toml"), false, true)?;
        let _: toml::Value = toml::from_str(
            std::str::from_utf8(&bytes(&identity, 128 * 1024)?)
                .map_err(|_| anyhow!("Invalid machine identity"))?,
        )
        .map_err(|_| anyhow!("Invalid machine identity"))?;
        drop(identity);
        verify_config_tree(&config, 0, &mut 4096)?;
        Ok(Self {
            config,
            install,
            provision,
            _pins: pins,
        })
    }
    fn pin(&self) -> &str {
        &self.provision.files[HOST_EXE]
    }
    fn image_matches(&self, process: HANDLE) -> ResultType<bool> {
        let mut path = vec![0u16; 32768];
        let mut length = path.len() as u32;
        unsafe {
            QueryFullProcessImageNameW(
                process,
                PROCESS_NAME_WIN32,
                PWSTR(path.as_mut_ptr()),
                &mut length,
            )?;
        }
        let path = PathBuf::from(String::from_utf16(&path[..length as usize])?);
        if path.canonicalize()? != self.install.join(HOST_EXE).canonicalize()? {
            return Ok(false);
        }
        let file = protected_file(&path, false, false)?;
        Ok(format!("{:x}", Sha256::digest(bytes(&file, 512 * 1024 * 1024)?)) == self.pin())
    }
}
fn process_facts(handle: HANDLE, pid: u32, layout: &Layout) -> ResultType<ProcessFacts> {
    system_token(handle)?;
    let mut session = 0;
    unsafe {
        ProcessIdToSessionId(pid, &mut session)?;
    }
    let mut created = FILETIME::default();
    let mut exited = FILETIME::default();
    let mut kernel = FILETIME::default();
    let mut user = FILETIME::default();
    unsafe {
        GetProcessTimes(handle, &mut created, &mut exited, &mut kernel, &mut user)?;
    }
    Ok(ProcessFacts {
        pid,
        creation: ((created.dwHighDateTime as u64) << 32) | created.dwLowDateTime as u64,
        session,
        system: true,
        image_pin_verified: layout.image_matches(handle)?,
    })
}
fn peer_facts(pipe: HANDLE, server: bool, layout: &Layout) -> ResultType<(Owned, ProcessFacts)> {
    let mut pid = 0;
    unsafe {
        if server {
            GetNamedPipeClientProcessId(pipe, &mut pid)?;
        } else {
            GetNamedPipeServerProcessId(pipe, &mut pid)?;
        }
    }
    let process = Owned(unsafe { OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid)? });
    let facts = process_facts(process.get(), pid, layout)?;
    Ok((process, facts))
}
async fn verified_peer(
    pipe: HANDLE,
    server: bool,
    layout: Arc<Layout>,
) -> ResultType<(Owned, ProcessFacts)> {
    // The verifier must retain its own handle if the awaiting control future is
    // cancelled; a borrowed pipe handle could otherwise be closed/reused.
    let mut duplicate = HANDLE::default();
    unsafe {
        DuplicateHandle(
            GetCurrentProcess(),
            pipe,
            GetCurrentProcess(),
            &mut duplicate,
            0,
            false,
            DUPLICATE_SAME_ACCESS,
        )?;
    }
    let pipe = Owned(duplicate);
    tokio::task::spawn_blocking(move || peer_facts(pipe.get(), server, &layout)).await?
}
fn new_pipe(binding: Binding) -> ResultType<tokio::net::windows::named_pipe::NamedPipeServer> {
    let mut descriptor = PSECURITY_DESCRIPTOR::default();
    let sddl = wide("D:P(A;;GA;;;SY)");
    unsafe {
        ConvertStringSecurityDescriptorToSecurityDescriptorW(
            PCWSTR(sddl.as_ptr()),
            1,
            &mut descriptor,
            None,
        )?;
    }
    let _descriptor = Descriptor(descriptor);
    let mut attrs = SECURITY_ATTRIBUTES {
        nLength: std::mem::size_of::<SECURITY_ATTRIBUTES>() as u32,
        lpSecurityDescriptor: descriptor.0,
        bInheritHandle: false.into(),
    };
    let mut options = tokio::net::windows::named_pipe::ServerOptions::new();
    options
        .first_pipe_instance(true)
        .reject_remote_clients(true)
        .max_instances(1);
    Ok(unsafe {
        options.create_with_security_attributes_raw(
            binding.pipe().map_err(|e| anyhow!(e))?,
            (&mut attrs as *mut SECURITY_ATTRIBUTES).cast(),
        )?
    })
}
struct Environment(*mut std::ffi::c_void);
impl Drop for Environment {
    fn drop(&mut self) {
        unsafe {
            let _ = DestroyEnvironmentBlock(self.0);
        }
    }
}
struct Child {
    process: Owned,
    _job: Owned,
    facts: ProcessFacts,
}
impl Child {
    fn stop(&self) -> ResultType<()> {
        // A valid Revoke was already attempted. Allow bounded cleanup of the
        // worker's own held inputs; a hang still terminates the owned job only.
        if unsafe { WaitForSingleObject(self.process.get(), 1000) } == WAIT_OBJECT_0 {
            return Ok(());
        }
        unsafe {
            TerminateJobObject(self._job.get(), 1)?;
        }
        if unsafe { WaitForSingleObject(self.process.get(), 5000) } != WAIT_OBJECT_0 {
            bail!("Owned worker exit was not confirmed");
        }
        Ok(())
    }
}
impl Drop for Child {
    fn drop(&mut self) {
        unsafe {
            let _ = TerminateJobObject(self._job.get(), 1);
        }
    }
}
fn launch(layout: &Layout, binding: Binding, parent: ProcessFacts) -> ResultType<Child> {
    let snapshot = Owned(unsafe { CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0)? });
    let mut entry = PROCESSENTRY32W {
        dwSize: std::mem::size_of::<PROCESSENTRY32W>() as u32,
        ..Default::default()
    };
    let mut found = unsafe { Process32FirstW(snapshot.get(), &mut entry) }.is_ok();
    let mut token_source = None;
    while found {
        let len = entry
            .szExeFile
            .iter()
            .position(|v| *v == 0)
            .unwrap_or(entry.szExeFile.len());
        if String::from_utf16_lossy(&entry.szExeFile[..len]).eq_ignore_ascii_case("winlogon.exe") {
            let mut session = 0;
            if unsafe { ProcessIdToSessionId(entry.th32ProcessID, &mut session) }.is_ok()
                && session == binding.session
            {
                let process = Owned(unsafe {
                    OpenProcess(
                        PROCESS_QUERY_LIMITED_INFORMATION,
                        false,
                        entry.th32ProcessID,
                    )?
                });
                system_token(process.get())?;
                token_source = Some(process);
                break;
            }
        }
        found = unsafe { Process32NextW(snapshot.get(), &mut entry) }.is_ok();
    }
    let source =
        token_source.ok_or_else(|| anyhow!("No verified system token in target session"))?;
    let mut token = HANDLE::default();
    unsafe {
        OpenProcessToken(source.get(), TOKEN_ALL_ACCESS, &mut token)?;
    }
    let token = Owned(token);
    let mut primary = HANDLE::default();
    unsafe {
        DuplicateTokenEx(
            token.get(),
            TOKEN_ALL_ACCESS,
            None,
            SecurityImpersonation,
            TokenPrimary,
            &mut primary,
        )?;
    }
    let primary = Owned(primary);
    let mut env = std::ptr::null_mut();
    unsafe {
        CreateEnvironmentBlock(&mut env, Some(primary.get()), false)?;
    }
    let env = Environment(env);
    let job = Owned(unsafe { CreateJobObjectW(None, PCWSTR::null())? });
    let mut limits = JOBOBJECT_EXTENDED_LIMIT_INFORMATION::default();
    limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    unsafe {
        SetInformationJobObject(
            job.get(),
            JobObjectExtendedLimitInformation,
            (&limits as *const JOBOBJECT_EXTENDED_LIMIT_INFORMATION).cast(),
            std::mem::size_of_val(&limits) as u32,
        )?;
    }
    let exe = layout.install.join(HOST_EXE);
    let nonce = binding
        .nonce
        .iter()
        .map(|v| format!("{v:02x}"))
        .collect::<String>();
    let mut command = wide(format!(
        "\"{}\" --worker {} {} {} {} {}",
        exe.display(),
        binding.session,
        binding.generation,
        nonce,
        parent.pid,
        parent.creation
    ));
    let application = wide(exe.as_os_str());
    let directory = wide(layout.install.as_os_str());
    let mut desktop = wide("winsta0\\default");
    let startup = STARTUPINFOW {
        cb: std::mem::size_of::<STARTUPINFOW>() as u32,
        lpDesktop: PWSTR(desktop.as_mut_ptr()),
        ..Default::default()
    };
    let mut process = PROCESS_INFORMATION::default();
    unsafe {
        CreateProcessAsUserW(
            Some(primary.get()),
            PCWSTR(application.as_ptr()),
            Some(PWSTR(command.as_mut_ptr())),
            None,
            None,
            false,
            CREATE_SUSPENDED | CREATE_UNICODE_ENVIRONMENT | CREATE_NO_WINDOW,
            Some(env.0),
            PCWSTR(directory.as_ptr()),
            &startup,
            &mut process,
        )?;
    }
    let process_handle = Owned(process.hProcess);
    let thread = Owned(process.hThread);
    if let Err(error) = unsafe { AssignProcessToJobObject(job.get(), process_handle.get()) } {
        unsafe {
            let _ = windows::Win32::System::Threading::TerminateProcess(process_handle.get(), 1);
        }
        return Err(error.into());
    }
    if unsafe { ResumeThread(thread.get()) } == u32::MAX {
        unsafe {
            let _ = TerminateJobObject(job.get(), 1);
        }
        bail!("Cannot resume owned background worker");
    }
    let facts = process_facts(process_handle.get(), process.dwProcessId, layout)?;
    if !allows_worker(&facts, &facts, binding) {
        unsafe {
            let _ = TerminateJobObject(job.get(), 1);
        }
        bail!("Invalid created background worker");
    }
    Ok(Child {
        process: process_handle,
        _job: job,
        facts,
    })
}
fn status(state: ServiceState) -> ServiceStatus {
    ServiceStatus {
        service_type: ServiceType::OWN_PROCESS,
        current_state: state,
        controls_accepted: if state == ServiceState::Running {
            ServiceControlAccept::STOP | ServiceControlAccept::SHUTDOWN
        } else {
            ServiceControlAccept::empty()
        },
        exit_code: ServiceExitCode::Win32(0),
        checkpoint: 0,
        wait_hint: Duration::default(),
        process_id: None,
    }
}
define_windows_service!(ffi_main, service_main);
fn service_main(_args: Vec<OsString>) {
    let _ = serve();
}
fn serve() -> ResultType<()> {
    assert_system(Some(0))?;
    let stop = Arc::new(AtomicBool::new(false));
    let control = stop.clone();
    let handle = service_control_handler::register(HOST_SERVICE, move |event| match event {
        ServiceControl::Stop | ServiceControl::Shutdown => {
            control.store(true, Ordering::Release);
            ServiceControlHandlerResult::NoError
        }
        ServiceControl::Interrogate => ServiceControlHandlerResult::NoError,
        _ => ServiceControlHandlerResult::NotImplemented,
    })?;
    handle.set_service_status(status(ServiceState::StartPending))?;
    let result = (|| -> ResultType<()> {
        let layout = Arc::new(Layout::verify()?);
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()?;
        handle.set_service_status(status(ServiceState::Running))?;
        runtime.block_on(async{let parent_layout=layout.clone();let parent=tokio::task::spawn_blocking(move||process_facts(unsafe{GetCurrentProcess()},unsafe{GetCurrentProcessId()},&parent_layout)).await??;let mut generation=0u64;
            while !stop.load(Ordering::Acquire){let session=unsafe{WTSGetActiveConsoleSessionId()};if session==0||session==u32::MAX{tokio::time::sleep(Duration::from_millis(250)).await;continue;}
                generation=generation.checked_add(1).ok_or_else(||anyhow!("Background generation exhausted"))?;let mut nonce=[0;32];hbb_common::rand::thread_rng().fill_bytes(&mut nonce);let binding=Binding{session,generation,nonce};
                let mut pipe=new_pipe(binding)?;let launch_layout=layout.clone();let parent=parent.clone();let child=match tokio::task::spawn_blocking(move||launch(&launch_layout,binding,parent)).await?{Ok(child)=>child,Err(_)=>{tokio::time::sleep(Duration::from_secs(2)).await;continue;}};
                let attempt=async{tokio::time::timeout(Duration::from_secs(10),pipe.connect()).await??;
                    let (_peer,facts)=verified_peer(HANDLE(pipe.as_raw_handle()),true,layout.clone()).await?;if !allows_worker(&facts,&child.facts,binding){bail!("Unowned worker on protected pipe");}
                    let hello=tokio::time::timeout(Duration::from_secs(3),protocol::read(&mut pipe)).await??;if !matches!(hello,Packet::Hello{..})||hello.binding()!=binding{bail!("Invalid worker hello");}
                    let mut authorization=WorkerAuthorization::new(binding).map_err(|e|anyhow!(e))?;authorization.grant(binding,true).map_err(|e|anyhow!(e))?;
                    protocol::write(&mut pipe,&Packet::Grant{session,generation,nonce}).await?;
                    let ready=tokio::time::timeout(Duration::from_secs(15),protocol::read(&mut pipe)).await??;
                    let selected=match &ready{Packet::Ready{desktop_selected,..}=>*desktop_selected,_=>false};authorization.ready(ready.binding(),true,selected).map_err(|e|anyhow!(e))?;
                    let (mut reader,mut writer)=tokio::io::split(&mut pipe);
                    let heartbeat=async {loop {let packet=tokio::time::timeout(Duration::from_secs(5),protocol::read(&mut reader)).await??;
                        if !matches!(packet,Packet::Heartbeat{..})||packet.binding()!=binding {bail!("Invalid background heartbeat");}
                    }#[allow(unreachable_code)] Ok::<_,hbb_common::anyhow::Error>(())};tokio::pin!(heartbeat);
                    loop{if stop.load(Ordering::Acquire)||unsafe{WTSGetActiveConsoleSessionId()}!=session{authorization.revoke();let _=tokio::time::timeout(Duration::from_millis(200),protocol::write(&mut writer,&Packet::Revoke{session,generation,nonce})).await;break;}
                        let mut exit=0;unsafe{GetExitCodeProcess(child.process.get(),&mut exit)?;}if exit!=259{break;}
                        // Keep the same reader future across timer ticks; partial frames
                        // must not be discarded by cancellation of read_exact.
                        tokio::select!{_ =tokio::time::sleep(Duration::from_millis(250))=>{},result=&mut heartbeat=>{result?;break;}}
                    }Ok::<_,hbb_common::anyhow::Error>(())};
                let cancelled=async{while !stop.load(Ordering::Acquire)&&unsafe{WTSGetActiveConsoleSessionId()}==session{tokio::time::sleep(Duration::from_millis(100)).await;}};
                tokio::select!{_ =attempt=>{},_ =cancelled=>{}}
                let _=tokio::time::timeout(Duration::from_millis(200),protocol::write(&mut pipe,&Packet::Revoke{session,generation,nonce})).await;
                tokio::task::spawn_blocking(move||child.stop()).await??;tokio::time::sleep(Duration::from_secs(2)).await;
            }Ok::<_,hbb_common::anyhow::Error>(())})
    })();
    let mut stopped = status(ServiceState::Stopped);
    if result.is_err() {
        stopped.exit_code = ServiceExitCode::Win32(1);
    }
    handle.set_service_status(stopped)?;
    result
}
pub(crate) fn run(args: Vec<String>) -> ResultType<()> {
    // Exclude PATH/current-directory DLL lookup before any background setup.
    unsafe {
        use windows::Win32::System::LibraryLoader::{
            SetDefaultDllDirectories, SetDllDirectoryW, LOAD_LIBRARY_SEARCH_APPLICATION_DIR,
            LOAD_LIBRARY_SEARCH_SYSTEM32,
        };
        SetDefaultDllDirectories(
            LOAD_LIBRARY_SEARCH_APPLICATION_DIR | LOAD_LIBRARY_SEARCH_SYSTEM32,
        )?;
        SetDllDirectoryW(PCWSTR(wide("").as_ptr()))?;
    }
    if args == ["--service"] {
        assert_system(Some(0))?;
        return windows_service::service_dispatcher::start(HOST_SERVICE, ffi_main)
            .context("Not started by the NikoDesk SCM entry");
    }
    if args.len() != 6 || args[0] != "--worker" {
        bail!("Invalid background entry arguments");
    }
    let session = args[1].parse()?;
    let generation = args[2].parse()?;
    if !hex(&args[3]) {
        bail!("Invalid worker binding");
    }
    let mut nonce = [0; 32];
    for (i, part) in args[3].as_bytes().chunks_exact(2).enumerate() {
        nonce[i] = u8::from_str_radix(std::str::from_utf8(part)?, 16)?;
    }
    let binding = Binding {
        session,
        generation,
        nonce,
    };
    if !binding.valid() {
        bail!("Invalid worker binding");
    }
    assert_system(Some(session))?;
    let layout = Arc::new(Layout::verify()?);
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()?;
    runtime.block_on(async {
        let mut pipe = tokio::net::windows::named_pipe::ClientOptions::new()
            .open(binding.pipe().map_err(|e| anyhow!(e))?)?;
        let (_parent, facts) =
            verified_peer(HANDLE(pipe.as_raw_handle()), false, layout.clone()).await?;
        if !allows_host(&facts, args[4].parse()?, args[5].parse()?) {
            bail!("Worker parent identity is not verified");
        }
        protocol::write(
            &mut pipe,
            &Packet::Hello {
                session,
                generation,
                nonce,
            },
        )
        .await?;
        let grant =
            tokio::time::timeout(Duration::from_secs(3), protocol::read(&mut pipe)).await??;
        if !matches!(grant, Packet::Grant { .. }) || grant.binding() != binding {
            bail!("Worker grant rejected");
        }
        worker::run(layout, binding, pipe).await
    })
}
