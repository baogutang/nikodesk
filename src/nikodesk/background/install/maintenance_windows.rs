//! Locally confirmed maintenance of the independently provisioned NikoDesk
//! service. No global process search, RustDesk service, remote grant or shell.
use super::*;
#[path = "update_windows.rs"]
mod update;
#[path = "password_windows.rs"]
mod password;
use hbb_common::config::{
    MachineEncryptionContext, MachineProfileFactory as Codec, MachineProfileServer,
};
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

struct HeldFile {
    path: PathBuf,
    id: Option<FileId>,
    private: bool,
    file: Option<File>,
}
struct Managed {
    service: Option<Service>,
    install: PathBuf,
    host: PathBuf,
    config: PathBuf,
    public_id: String,
    parents: Vec<File>,
    files: Vec<HeldFile>,
    privileges: Vec<RestorePrivilege>,
    provision: Option<Provision>,
}
impl Managed {
    fn read(
        approval: &LocalApprovalGrant,
        release: &ReleaseManifest,
        report: &impl Fn(&'static str),
    ) -> Result<Self> {
        approval.revalidate()?;
        release.validate()?;
        let privileges = vec![
            RestorePrivilege::enable_for_explicit_setup("SeBackupPrivilege")?,
            RestorePrivilege::enable_for_explicit_setup("SeRestorePrivilege")?,
        ];
        let install = known(&FOLDERID_ProgramFiles)?.join("NikoDesk");
        let machine = known(&FOLDERID_ProgramData)?.join("NikoDesk");
        let host = machine.join("host");
        let config = host.join("config");
        let mut parents = ancestor_pins(&install)?;
        parents.extend(ancestor_pins(&config)?);
        for (path, private) in [
            (&install, false),
            (&machine, true),
            (&host, true),
            (&config, true),
        ] {
            let pin = open(path, true, READ_CONTROL.0, false, None, FILE_SHARE_READ)?;
            private_acl(&pin, private)?;
            parents.push(pin);
        }
        let lock_path = host.join("setup.lock");
        let lock = open(
            &lock_path,
            false,
            FILE_GENERIC_READ.0 | FILE_GENERIC_WRITE.0 | READ_CONTROL.0,
            false,
            None,
            FILE_SHARE_MODE(0),
        )?;
        private_acl(&lock, true)?;
        let lock_id = facts(&lock, false)?;
        let manager = scm()?;
        let name = wide(SERVICE);
        let service = Service(unsafe {
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
            )?
        });
        service_config(&service, &install)?;
        service_private_acl(&service)?;
        let mut files = Vec::new();
        let mut profile = BTreeMap::new();
        for name in ["NikoDesk.toml", "NikoDesk2.toml"] {
            let path = config.join(name);
            let mut file = open(
                &path,
                false,
                FILE_GENERIC_READ.0 | READ_CONTROL.0,
                false,
                None,
                FILE_SHARE_READ,
            )?;
            private_acl(&file, true)?;
            profile.insert(name.to_owned(), content(&mut file, 128 * 1024)?);
            files.push(HeldFile {
                path,
                id: Some(facts(&file, false)?),
                private: true,
                file: Some(file),
            });
        }
        let context = MachineEncryptionContext::from_os_machine_uid()?;
        let snapshot = MachineProfileServer::new(
            approval.server().rendezvous.clone(),
            approval.server().relay.clone(),
            approval.server().public_key.clone(),
        )?;
        let info = Codec::inspect_existing(&context, &profile, &snapshot, None);
        for bytes in profile.values_mut() {
            wipe(bytes);
        }
        let public_id = info?.public_id;
        let mut managed = Self {
            service: Some(service),
            install: install.clone(),
            host: host.clone(),
            config,
            public_id,
            parents,
            files,
            privileges,
            provision: None,
        };
        if host
            .join(super::super::update_policy::JOURNAL)
            .try_exists()?
        {
            if approval.consent().action != Action::Repair {
                bail!("interrupted_upgrade_requires_local_repair");
            }
            managed.stop(report);
            update::recover(&mut managed, approval, report)?;
        }
        let path = host.join("provision-v1.json");
        let mut file = open(
            &path,
            false,
            FILE_GENERIC_READ.0 | READ_CONTROL.0,
            false,
            None,
            FILE_SHARE_READ,
        )?;
        private_acl(&file, true)?;
        let provision: Provision = serde_json::from_slice(&content(&mut file, 64 * 1024)?)?;
        if provision.version != 1
            || !provision.desktop_preauthorized
            || !hex(&provision.consent_id)
            || provision.files.is_empty()
            || provision.files.len() > 256
            || !provision.files.contains_key(HOST)
            || provision
                .files
                .iter()
                .any(|(name, digest)| !leaf(name) || !hex(digest))
        {
            bail!("owned_machine_provision_unconfirmed");
        }
        managed.files.push(HeldFile {
            path,
            id: Some(facts(&file, false)?),
            private: true,
            file: Some(file),
        });
        for (name, digest) in &provision.files {
            let path = install.join(name);
            if approval.consent().action == Action::Repair && !path.try_exists()? {
                managed.files.push(HeldFile {
                    path,
                    id: None,
                    private: false,
                    file: None,
                });
                continue;
            }
            let mut file = open(
                &path,
                false,
                FILE_GENERIC_READ.0 | READ_CONTROL.0,
                false,
                None,
                FILE_SHARE_READ,
            )?;
            private_acl(&file, false)?;
            let intact = hash(&mut file, MAX_PAYLOAD_BYTES)? == *digest;
            if !intact && approval.consent().action != Action::Repair {
                bail!("owned_service_payload_changed");
            }
            if name == HOST && intact && !approval.reviewed_unsigned() {
                authenticode(&file, &path)?;
            }
            managed.files.push(HeldFile {
                path,
                id: Some(facts(&file, false)?),
                private: false,
                file: Some(file),
            });
        }
        let path = host.join("install-journal-v1.json");
        let mut file = open(
            &path,
            false,
            FILE_GENERIC_READ.0 | READ_CONTROL.0,
            false,
            None,
            FILE_SHARE_READ,
        )?;
        private_acl(&file, true)?;
        let journal: Journal = serde_json::from_slice(&content(&mut file, 64 * 1024)?)?;
        if journal.version != 1 || !hex(&journal.transaction) || !hex(&journal.release_sha256) {
            bail!("owned_install_journal_unconfirmed");
        }
        managed.files.push(HeldFile {
            path,
            id: Some(facts(&file, false)?),
            private: true,
            file: Some(file),
        });
        // Keep the common setup lock until the last owned file is removed.
        managed.files.push(HeldFile {
            path: lock_path,
            id: Some(lock_id),
            private: true,
            file: Some(lock),
        });
        managed.provision = Some(provision);
        if approval.consent().action == Action::Repair {
            update::clear_orphan_commit(&managed, approval)?;
        }
        approval.revalidate()?;
        Ok(managed)
    }
    fn service(&self) -> Result<&Service> {
        self.service
            .as_ref()
            .ok_or_else(|| anyhow!("owned_service_unavailable"))
    }
    fn process(&self) -> Result<Option<Kernel>> {
        let service = self.service()?;
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
        if status.dwProcessId == 0 {
            if status.dwCurrentState == SERVICE_STOPPED {
                return Ok(None);
            }
            bail!("owned_service_process_unconfirmed");
        }
        let process = Kernel(unsafe {
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
                process.0,
                PROCESS_NAME_WIN32,
                PWSTR(path.as_mut_ptr()),
                &mut length,
            )?;
        }
        let path = String::from_utf16(&path[..length as usize])?;
        if !Path::new(&path)
            .to_string_lossy()
            .eq_ignore_ascii_case(&self.install.join(HOST).to_string_lossy())
        {
            bail!("owned_service_process_image_changed");
        }
        let mut repeated = SERVICE_STATUS_PROCESS::default();
        unsafe {
            QueryServiceStatusEx(
                service.0,
                SC_STATUS_PROCESS_INFO,
                Some(std::slice::from_raw_parts_mut(
                    (&mut repeated as *mut SERVICE_STATUS_PROCESS).cast(),
                    std::mem::size_of_val(&repeated),
                )),
                &mut needed,
            )?;
        }
        if repeated.dwProcessId != status.dwProcessId {
            bail!("owned_service_process_changed");
        }
        Ok(Some(process))
    }
    fn stop(&self, report: &impl Fn(&'static str)) {
        // Once this local stop begins, retain the actual owner until both SCM
        // and its original kernel process acknowledge exit. Cancellation never
        // converts StopPending or an observer timeout into a stopped result.
        let mut process = None;
        loop {
            let result = (|| -> Result<()> {
                service_config(self.service()?, &self.install)?;
                if process.is_none() {
                    process = self.process()?;
                }
                stop_confirmed(self.service()?)?;
                if let Some(process) = &process {
                    if unsafe { WaitForSingleObject(process.0, 0) } != WAIT_OBJECT_0 {
                        bail!("owned_service_process_exit_unconfirmed");
                    }
                }
                Ok(())
            })();
            if result.is_ok() {
                return;
            }
            report("recovery");
            std::thread::sleep(Duration::from_secs(2));
        }
    }
    fn resume(
        &mut self,
        approval: &LocalApprovalGrant,
        report: &impl Fn(&'static str),
    ) -> Result<()> {
        approval.revalidate()?;
        service_config(self.service()?, &self.install)?;
        update::enable_existing(self, approval)?;
        set_start(self.service()?, SERVICE_AUTO_START)?;
        let result = (|| -> Result<()> {
            if service_state(self.service()?)? != SERVICE_RUNNING {
                unsafe {
                    StartServiceW(self.service()?.0, None)?;
                }
            }
            let deadline = Instant::now() + Duration::from_secs(15);
            while service_state(self.service()?)? != SERVICE_RUNNING {
                if Instant::now() > deadline {
                    bail!("service_start_unconfirmed");
                }
                approval.revalidate()?;
                std::thread::sleep(Duration::from_millis(100));
            }
            self.process()?
                .ok_or_else(|| anyhow!("owned_service_process_unconfirmed"))?;
            approval.revalidate()
        })();
        if result.is_err() {
            self.stop(report);
        }
        result
    }
    fn configure(
        &mut self,
        approval: &LocalApprovalGrant,
        report: &impl Fn(&'static str),
    ) -> Result<()> {
        approval.revalidate()?;
        let context = MachineEncryptionContext::from_os_machine_uid()?;
        let server = MachineProfileServer::new(approval.server().rendezvous.clone(),
            approval.server().relay.clone(), approval.server().public_key.clone())?;
        let mut profile = BTreeMap::new();
        let prepared = (|| -> Result<Vec<u8>> {
            for name in ["NikoDesk.toml", "NikoDesk2.toml"] {
                let path = self.config.join(name);
                let entry = self.files.iter_mut().find(|entry| entry.path == path)
                    .ok_or_else(|| anyhow!("owned_machine_profile_unavailable"))?;
                let mut held = update::pinned(&path, entry.id.ok_or_else(|| anyhow!("owned_machine_profile_unavailable"))?, true)?;
                profile.insert(name.to_owned(), content(&mut held, 128 * 1024)?);
            }
            Codec::prepare_policy_update(&context, &profile, &server,
                approval.consent().allow_virtual_display, approval.consent().lock_on_disconnect,
                approval.consent().allow_privacy, approval.consent().allow_remote_restart)
        })();
        for bytes in profile.values_mut() { wipe(bytes); }
        let mut bytes = prepared?;
        // Updating a running profile can race Config's own persistence. Stop
        // the exact service and kernel owner first; failure leaves it disabled.
        self.stop(report);
        report("profile");
        let result = (|| -> Result<()> {
            approval.revalidate()?;
            let path = self.config.join("NikoDesk2.toml");
            let temporary = self.config.join(format!(".nikodesk-policy-{}.toml", approval.consent().id()));
            let new_id = update::create(&temporary, &bytes, true)?;
            let replace = (|| -> Result<()> {
                let mut staged = update::pinned(&temporary, new_id, true)?;
                if content(&mut staged, 128 * 1024)? != bytes { bail!("machine_policy_stage_unconfirmed"); }
                drop(staged);
                approval.revalidate()?;
                let entry = self.files.iter_mut().find(|entry| entry.path == path)
                    .ok_or_else(|| anyhow!("owned_machine_profile_unavailable"))?;
                let old = entry.id.ok_or_else(|| anyhow!("owned_machine_profile_unavailable"))?;
                entry.file.take();
                drop(update::pinned(&path, old, true)?);
                // A single atomic replacement leaves either complete policy
                // on power loss. Machine ID/private key/password never move.
                unsafe { MoveFileExW(PCWSTR(wide(&temporary).as_ptr()), PCWSTR(wide(&path).as_ptr()),
                    MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)?; }
                entry.id = Some(new_id);
                let mut current = update::pinned(&path, new_id, true)?;
                if content(&mut current, 128 * 1024)? != bytes { bail!("machine_policy_readback_unconfirmed"); }
                entry.file = Some(current);
                approval.revalidate()
            })();
            // Cleanup is limited to this still-owned temporary ID. A crash can
            // retain a protected stage, but it can never become active policy.
            if replace.is_err() {
                while update::delete(&temporary, new_id, true).is_err() {
                    report("recovery");
                    std::thread::sleep(Duration::from_secs(2));
                }
            }
            replace
        })();
        wipe(&mut bytes);
        result?;
        report("verify");
        if approval.consent().start_after_commit { self.resume(approval, report)?; }
        Ok(())
    }
    fn remove(
        &mut self,
        approval: &LocalApprovalGrant,
        report: &impl Fn(&'static str),
    ) -> Result<()> {
        self.stop(report);
        approval.revalidate()?;
        unsafe {
            DeleteService(self.service()?.0)?;
        }
        self.service.take();
        // Do not remove its payload/identity while another SCM handle keeps
        // the original service registered. Observe only this exact service name.
        let manager = scm()?;
        let name = wide(SERVICE);
        loop {
            match unsafe { OpenServiceW(manager.0, PCWSTR(name.as_ptr()), SERVICE_QUERY_STATUS) } {
                Err(error)
                    if error.code()
                        == windows::core::HRESULT::from_win32(ERROR_SERVICE_DOES_NOT_EXIST.0) =>
                {
                    break
                }
                Err(error)
                    if error.code()
                        == windows::core::HRESULT::from_win32(
                            ERROR_SERVICE_MARKED_FOR_DELETE.0,
                        ) => {}
                Ok(handle) => {
                    drop(Service(handle));
                }
                Err(_) => {}
            }
            report("recovery");
            std::thread::sleep(Duration::from_secs(2));
        }
        // All original file IDs were captured before committing this removal.
        // Finish removal of this set even if its UI disappears after DeleteService.
        for entry in &mut self.files {
            entry.file.take();
            loop {
                let result = (|| -> Result<()> {
                    let file = open(
                        &entry.path,
                        false,
                        DELETE.0 | READ_CONTROL.0,
                        false,
                        None,
                        FILE_SHARE_READ,
                    )?;
                    private_acl(&file, entry.private)?;
                    if Some(facts(&file, false)?) != entry.id {
                        bail!("owned_removal_file_changed");
                    }
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
                })();
                if result.is_ok() {
                    break;
                }
                report("recovery");
                std::thread::sleep(Duration::from_secs(2));
            }
        }
        // A protected non-secret receipt lets a later explicit installation
        // reuse these directories while preserving logs. It never reuses keys.
        let retired = RetiredMachine {
            version: 1,
            public_id: self.public_id.clone(),
            namespace: approval.origin().namespace().into(),
        };
        retired.validate()?;
        let bytes = serde_json::to_vec(&retired)?;
        while update::create(&self.host.join(RETIRED_PROFILE), &bytes, true).is_err() {
            report("recovery");
            std::thread::sleep(Duration::from_secs(2));
        }
        self.parents.clear();
        for path in [&self.config, &self.install] {
            let _ = std::fs::remove_dir(path);
        }
        Ok(())
    }
}
pub(crate) fn run(
    approval: LocalApprovalGrant,
    release: ReleaseManifest,
    source: PathBuf,
    password: Option<UnattendedSecret>,
    report: impl Fn(&'static str),
) -> Result<String> {
    let action = approval.consent().action;
    if matches!(action,Action::Install|Action::RecoverInstall) {
        bail!("maintenance_action_required");
    }
    report("preflight");
    let mut managed = Managed::read(&approval, &release, &report)?;
    super::recovery::finish_committed(&approval,&managed.public_id)?;
    report("consent");
    approval.revalidate()?;
    match action {
        Action::Stop => {
            report("recovery");
            managed.stop(&report);
        }
        Action::Resume => {
            report("started");
            managed.resume(&approval, &report)?;
        }
        Action::Remove => {
            report("payload");
            managed.remove(&approval, &report)?;
        }
        Action::Upgrade | Action::Repair => {
            report("payload");
            update::run(&mut managed, &approval, &release, &source, &report)?;
        }
        Action::Configure => managed.configure(&approval, &report)?,
        Action::ChangePassword => managed.change_password(&approval,
            password.as_ref().ok_or_else(||anyhow!("explicit_unattended_password_required"))?, &report)?,
        Action::Install | Action::RecoverInstall => unreachable!(),
    }
    for privilege in managed.privileges.iter_mut().rev() {
        privilege.restore()?;
    }
    managed.privileges.clear();
    Ok(managed.public_id.clone())
}
