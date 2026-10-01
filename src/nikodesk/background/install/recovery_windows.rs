//! Recovery uses protected, flushed ownership records and actual Win32 objects.
//! It never guesses ownership from a filename or deletes a committed identity.
use super::super::recovery_policy::{Area, Event, Header, Object, Replay, LEDGER, MAX_LEDGER};
use super::*;
use windows::{
    core::PWSTR,
    Win32::{
        Foundation::{ERROR_SERVICE_MARKED_FOR_DELETE, WAIT_OBJECT_0},
        System::Threading::{
            OpenProcess, QueryFullProcessImageNameW, WaitForSingleObject, PROCESS_NAME_WIN32,
            PROCESS_QUERY_LIMITED_INFORMATION, PROCESS_SYNCHRONIZE,
        },
    },
};

pub(super) struct Layout {
    pub program_parent: PathBuf,
    pub machine_parent: PathBuf,
}
impl Layout {
    pub fn read() -> Result<Self> {
        Ok(Self {
            program_parent: known(&FOLDERID_ProgramFiles)?,
            machine_parent: known(&FOLDERID_ProgramData)?,
        })
    }
    pub fn root(&self, area: Area) -> PathBuf {
        match area {
            Area::Program => self.program_parent.join("NikoDesk"),
            Area::Machine => self.machine_parent.join("NikoDesk"),
            Area::Host => self.machine_parent.join("NikoDesk/host"),
            Area::Config => self.machine_parent.join("NikoDesk/host/config"),
        }
    }
    pub fn path(&self, object: &Object, transaction: &str) -> PathBuf {
        match object {
            Object::Root { area } => self.root(*area),
            Object::RootStage { area } => self.root(*area).parent().unwrap().join(format!(
                ".nikodesk-{transaction}-{}-root",
                match area {
                    Area::Program => "program",
                    Area::Machine => "machine",
                    Area::Host => "host",
                    Area::Config => "config",
                }
            )),
            Object::File { area, name } => self.root(*area).join(name),
            Object::FileStage { area, serial } => self
                .root(*area)
                .join(format!(".{transaction}-file-{serial}.tmp")),
        }
    }
    pub fn file_object(&self, path: &Path) -> Result<Object> {
        for area in [Area::Program, Area::Host, Area::Config] {
            if path.parent() == Some(self.root(area).as_path()) {
                return Ok(Object::File {
                    area,
                    name: path
                        .file_name()
                        .and_then(|s| s.to_str())
                        .ok_or_else(|| anyhow!("install_recovery_invalid_path"))?
                        .into(),
                });
            }
        }
        bail!("install_recovery_invalid_path")
    }
}

pub(super) struct Ledger {
    file: File,
    id: FileId,
    pub replay: Replay,
}
impl Ledger {
    pub fn create(layout: &Layout, header: Header) -> Result<Self> {
        let sd = Descriptor::new("O:SYD:P(A;;FA;;;SY)(A;;FA;;;BA)")?;
        let file = open(
            &layout.machine_parent.join(LEDGER),
            false,
            FILE_GENERIC_READ.0 | FILE_GENERIC_WRITE.0 | READ_CONTROL.0 | DELETE.0,
            true,
            Some(&sd),
            FILE_SHARE_MODE(0),
        )?;
        let id = facts(&file, false)?;
        private_acl(&file, true)?;
        Ok(Self {
            file,
            id,
            replay: Replay::begin(header)?,
        })
    }
    pub fn read(layout: &Layout) -> Result<Self> {
        let mut file = open(
            &layout.machine_parent.join(LEDGER),
            false,
            FILE_GENERIC_READ.0 | FILE_GENERIC_WRITE.0 | READ_CONTROL.0 | DELETE.0,
            false,
            None,
            FILE_SHARE_MODE(0),
        )?;
        private_acl(&file, true)?;
        let id = facts(&file, false)?;
        let replay = Replay::decode(&content(&mut file, MAX_LEDGER as u64)?)?;
        Ok(Self { file, id, replay })
    }
    pub fn append(&mut self, event: Event) -> Result<()> {
        let bytes = self.replay.encode_next(event)?;
        let mut next = self.replay.clone();
        next.accept(&bytes)?;
        // An earlier incomplete append has no authorized following OS action.
        self.file.set_len(self.replay.valid_length as u64)?;
        self.file
            .seek(SeekFrom::Start(self.replay.valid_length as u64))?;
        self.file.write_all(&bytes)?;
        self.file.sync_all()?;
        self.replay = next;
        Ok(())
    }
    pub fn remove(&self) -> Result<()> {
        if facts(&self.file, false)? != self.id {
            bail!("install_recovery_anchor_changed");
        }
        dispose(&self.file)
    }
}
fn dispose(file: &File) -> Result<()> {
    let disposition = FILE_DISPOSITION_INFO { DeleteFile: true };
    unsafe {
        SetFileInformationByHandle(
            HANDLE(file.as_raw_handle()),
            FileDispositionInfo,
            (&disposition as *const FILE_DISPOSITION_INFO).cast(),
            std::mem::size_of_val(&disposition) as u32,
        )?;
    }
    Ok(())
}
pub(super) fn service_tag(transaction: &str) -> String {
    format!("NikoDeskHost [{transaction}]")
}
fn check_service_tag(service: &Service, transaction: &str) -> Result<()> {
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
    let config = unsafe { &*buffer.as_ptr().cast::<QUERY_SERVICE_CONFIGW>() };
    if unsafe { config.lpDisplayName.to_string()? } != service_tag(transaction) {
        bail!("install_recovery_service_owner_changed");
    }
    Ok(())
}
pub(super) fn process(service: &Service, install: &Path) -> Result<Option<Kernel>> {
    let read = || -> Result<SERVICE_STATUS_PROCESS> {
        let mut status = SERVICE_STATUS_PROCESS::default();
        let mut needed = 0;
        unsafe {
            QueryServiceStatusEx(
                service.0,
                SC_STATUS_PROCESS_INFO,
                Some(std::slice::from_raw_parts_mut(
                    (&mut status as *mut SERVICE_STATUS_PROCESS).cast(),
                    std::mem::size_of_val(&status),
                )),
                &mut needed,
            )?;
        }
        Ok(status)
    };
    let status = read()?;
    if status.dwProcessId == 0 {
        if status.dwCurrentState == SERVICE_STOPPED {
            return Ok(None);
        }
        bail!("owned_service_process_unconfirmed");
    }
    let handle = Kernel(unsafe {
        OpenProcess(
            PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_SYNCHRONIZE,
            false,
            status.dwProcessId,
        )?
    });
    let mut path = vec![0u16; 32768];
    let mut length = path.len() as u32;
    unsafe {
        QueryFullProcessImageNameW(
            handle.0,
            PROCESS_NAME_WIN32,
            PWSTR(path.as_mut_ptr()),
            &mut length,
        )?;
    }
    if !String::from_utf16(&path[..length as usize])?
        .eq_ignore_ascii_case(&install.join(HOST).to_string_lossy())
        || read()?.dwProcessId != status.dwProcessId
    {
        bail!("owned_service_process_changed");
    }
    Ok(Some(handle))
}
pub(super) fn confirm_process_exit(process: &Option<Kernel>) -> Result<()> {
    if process
        .as_ref()
        .is_some_and(|p| unsafe { WaitForSingleObject(p.0, 0) } != WAIT_OBJECT_0)
    {
        bail!("owned_service_process_exit_unconfirmed");
    }
    Ok(())
}
pub(super) fn confirm_service_absent() -> Result<()> {
    let manager = scm()?;
    let name = wide(SERVICE);
    match unsafe { OpenServiceW(manager.0, PCWSTR(name.as_ptr()), SERVICE_QUERY_STATUS) } {
        Ok(raw) => {
            drop(Service(raw));
            bail!("owned_service_removal_unconfirmed")
        }
        Err(e)
            if e.code() == windows::core::HRESULT::from_win32(ERROR_SERVICE_DOES_NOT_EXIST.0) =>
        {
            Ok(())
        }
        Err(e) => Err(e.into()),
    }
}
fn validate_roots(layout: &Layout, replay: &Replay) -> Result<()> {
    for area in [Area::Program, Area::Machine, Area::Host, Area::Config] {
        let path = layout.root(area);
        if !path.try_exists()? {
            continue;
        }
        let pin = open(&path, true, READ_CONTROL.0, false, None, FILE_SHARE_READ)?;
        private_acl(&pin, area != Area::Program)?;
        let actual = facts(&pin, true)?;
        if !replay
            .objects
            .get(&Object::Root { area })
            .is_some_and(|ids| ids.contains(&actual))
        {
            bail!("install_recovery_root_owner_changed");
        }
    }
    Ok(())
}
pub(super) fn finish_committed(approval: &LocalApprovalGrant, public_id: &str) -> Result<()> {
    let layout = Layout::read()?;
    if !layout.machine_parent.join(LEDGER).try_exists()? {
        return Ok(());
    }
    let ledger = Ledger::read(&layout)?;
    if !ledger.replay.committed
        || ledger.replay.public_id.as_deref() != Some(public_id)
        || ledger.replay.header.namespace != approval.origin().namespace()
    {
        bail!("install_recovery_committed_owner_changed");
    }
    approval.revalidate()?;
    ledger.remove()
}

pub(crate) fn run(approval: LocalApprovalGrant, report: impl Fn(&'static str)) -> Result<()> {
    if approval.consent().action != Action::RecoverInstall {
        bail!("install_recovery_requires_local_confirmation");
    }
    approval.revalidate()?;
    let mut privileges = vec![
        RestorePrivilege::enable_for_explicit_setup("SeBackupPrivilege")?,
        RestorePrivilege::enable_for_explicit_setup("SeRestorePrivilege")?,
    ];
    let layout = Layout::read()?;
    let mut parents = ancestor_pins(&layout.program_parent)?;
    parents.extend(ancestor_pins(&layout.machine_parent)?);
    let mut raw = open(
        &layout.machine_parent.join(LEDGER),
        false,
        FILE_GENERIC_READ.0 | FILE_GENERIC_WRITE.0 | READ_CONTROL.0 | DELETE.0,
        false,
        None,
        FILE_SHARE_MODE(0),
    )?;
    private_acl(&raw, true)?;
    let id = facts(&raw, false)?;
    let bytes = content(&mut raw, MAX_LEDGER as u64)?;
    if !bytes.contains(&b'\n') {
        // No durable Begin means no root, payload or service action was allowed.
        // An unexpectedly truncated journal must not claim that an existing
        // machine or unknown installation tree has been cleared.
        confirm_service_absent()?;
        if [Area::Program, Area::Machine, Area::Host, Area::Config]
            .iter().any(|area|layout.root(*area).try_exists().unwrap_or(true)) {
            let host=layout.root(Area::Host);
            let mut receipt=open(&host.join(RETIRED_PROFILE),false,
                FILE_GENERIC_READ.0|READ_CONTROL.0,false,None,FILE_SHARE_READ)?;
            private_acl(&receipt,true)?;
            let retired:RetiredMachine=serde_json::from_slice(&content(&mut receipt,4096)?)?;
            retired.validate()?;
            for path in [host.join("setup.lock"),host.join("provision-v1.json"),host.join("install-journal-v1.json"),
                layout.root(Area::Config).join("NikoDesk.toml"),layout.root(Area::Config).join("NikoDesk2.toml")] {
                if path.try_exists()? {bail!("install_recovery_missing_ownership_records");}
            }
        }
        approval.revalidate()?;
        dispose(&raw)?;
        drop(raw);
        for privilege in privileges.iter_mut().rev() {
            privilege.restore()?;
        }
        return Ok(());
    }
    let replay = Replay::decode(&bytes)?;
    if replay.header.namespace != approval.origin().namespace() {
        bail!("install_recovery_server_changed");
    }
    if replay.committed {
        bail!("install_recovery_committed_use_repair");
    }
    let program = open(
        &layout.program_parent,
        true,
        READ_CONTROL.0,
        false,
        None,
        FILE_SHARE_READ,
    )?;
    let machine = open(
        &layout.machine_parent,
        true,
        READ_CONTROL.0,
        false,
        None,
        FILE_SHARE_READ,
    )?;
    if facts(&program, true)? != replay.header.program_parent
        || facts(&machine, true)? != replay.header.machine_parent
    {
        bail!("install_recovery_parent_changed");
    }
    parents.extend([program, machine]);
    validate_roots(&layout, &replay)?;
    let ledger = Ledger {
        file: raw,
        id,
        replay,
    };
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
                | READ_CONTROL.0
                | WRITE_DAC.0
                | DELETE.0,
        )
    } {
        Ok(raw) => {
            let service = Service(raw);
            if !ledger.replay.service_intended {
                bail!("install_recovery_foreign_service");
            }
            service_config(&service, &layout.root(Area::Program))?;
            check_service_tag(&service, &ledger.replay.header.transaction)?;
            // A crash may precede SetServiceObjectSecurity; the atomic nonce tag
            // and exact SCM configuration identify this locally created service.
            let sd = Descriptor::new("D:P(A;;GA;;;SY)(A;;GA;;;BA)")?;
            approval.revalidate()?;
            unsafe {
                SetServiceObjectSecurity(service.0, DACL_SECURITY_INFORMATION, sd.0)?;
            }
            service_private_acl(&service)?;
            let mut owned_process = None;
            loop {
                let stopped = (|| -> Result<()> {
                    if owned_process.is_none() {
                        owned_process = process(&service, &layout.root(Area::Program))?;
                    }
                    stop_confirmed(&service)?;
                    confirm_process_exit(&owned_process)
                })();
                if stopped.is_ok() {
                    break;
                }
                report("recovery");
                std::thread::sleep(Duration::from_secs(2));
            }
            approval.revalidate()?;
            unsafe {
                DeleteService(service.0)?;
            }
            drop(service);
            while confirm_service_absent().is_err() {
                report("recovery");
                std::thread::sleep(Duration::from_secs(2));
            }
        }
        Err(e)
            if e.code() == windows::core::HRESULT::from_win32(ERROR_SERVICE_DOES_NOT_EXIST.0) => {}
        Err(e)
            if e.code()
                == windows::core::HRESULT::from_win32(ERROR_SERVICE_MARKED_FOR_DELETE.0) =>
        {
            while confirm_service_absent().is_err() {
                report("recovery");
                std::thread::sleep(Duration::from_secs(2));
            }
        }
        Err(e) => return Err(e.into()),
    }
    let mut objects = ledger
        .replay
        .objects
        .keys()
        .chain(ledger.replay.intents.iter())
        .cloned()
        .collect::<std::collections::BTreeSet<_>>()
        .into_iter()
        .collect::<Vec<_>>();
    objects.sort_by_key(|object| {
        (
            object.directory(),
            std::cmp::Reverse(
                layout
                    .path(object, &ledger.replay.header.transaction)
                    .components()
                    .count(),
            ),
        )
    });
    for object in objects {
        if matches!(object,Object::Root {area} if ledger.replay.existing.contains(&area)) {
            continue;
        }
        let path = layout.path(&object, &ledger.replay.header.transaction);
        if !path.try_exists()? {
            continue;
        }
        approval.revalidate()?;
        validate_roots(&layout, &ledger.replay)?;
        let _ancestors = ancestor_pins(
            path.parent()
                .ok_or_else(|| anyhow!("install_recovery_invalid_parent"))?,
        )?;
        let file = open(
            &path,
            object.directory(),
            DELETE.0 | READ_CONTROL.0 | FILE_GENERIC_READ.0,
            false,
            None,
            FILE_SHARE_READ,
        )?;
        private_acl(&file, object.area() != Area::Program)?;
        let actual = facts(&file, object.directory())?;
        if let Some(ids) = ledger.replay.objects.get(&object) {
            if !ids.contains(&actual) {
                bail!("install_recovery_object_changed");
            }
        } else if !object.stage()
            || !ledger.replay.intents.contains(&object)
            || if object.directory() {
                std::fs::read_dir(&path)?.next().is_some()
            } else {
                file.metadata()?.len() != 0
            }
        {
            bail!("install_recovery_staging_owner_unconfirmed");
        }
        // Nonempty directories fail rather than deleting unknown files or logs.
        dispose(&file)?;
        drop(file);
    }
    approval.revalidate()?;
    ledger.remove()?;
    drop(ledger);
    for privilege in privileges.iter_mut().rev() {
        privilege.restore()?;
    }
    Ok(())
}
