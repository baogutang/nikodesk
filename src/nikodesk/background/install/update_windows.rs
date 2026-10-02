//! Fixed-release upgrades preserve both machine profile files byte for byte.
//! A protected immutable journal and separate commit marker also permit local
//! repair after power loss. Rollback never depends on a replacement process.
use super::super::super::update_policy::{UpdateJournal, COMMIT, JOURNAL};
use super::*;
use windows::Win32::Foundation::{ERROR_FILE_NOT_FOUND, ERROR_PATH_NOT_FOUND};

fn missing(error: &hbb_common::anyhow::Error) -> bool {
    error
        .downcast_ref::<windows::core::Error>()
        .is_some_and(|e| {
            [ERROR_FILE_NOT_FOUND, ERROR_PATH_NOT_FOUND]
                .iter()
                .any(|code| e.code() == windows::core::HRESULT::from_win32(code.0))
        })
}
pub(super) fn pinned(path: &Path, id: FileId, private: bool) -> Result<File> {
    let file = open(
        path,
        false,
        FILE_GENERIC_READ.0 | READ_CONTROL.0,
        false,
        None,
        FILE_SHARE_READ,
    )?;
    private_acl(&file, private)?;
    if facts(&file, false)? != id {
        bail!("owned_update_file_changed");
    }
    Ok(file)
}
pub(super) fn delete(path: &Path, id: FileId, private: bool) -> Result<()> {
    let file = match open(
        path,
        false,
        DELETE.0 | READ_CONTROL.0,
        false,
        None,
        FILE_SHARE_READ,
    ) {
        Ok(file) => file,
        Err(error) if missing(&error) => return Ok(()),
        Err(error) => return Err(error),
    };
    private_acl(&file, private)?;
    if facts(&file, false)? != id {
        bail!("owned_update_cleanup_file_changed");
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
}
pub(super) fn create(path: &Path, bytes: &[u8], private: bool) -> Result<FileId> {
    let descriptor = Descriptor::new(if private {
        "O:SYD:P(A;;FA;;;SY)(A;;FA;;;BA)"
    } else {
        "O:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)"
    })?;
    let mut file = open(
        path,
        false,
        FILE_GENERIC_READ.0 | FILE_GENERIC_WRITE.0 | READ_CONTROL.0 | DELETE.0,
        true,
        Some(&descriptor),
        FILE_SHARE_READ,
    )?;
    let result = (|| -> Result<FileId> {
        let id = facts(&file, false)?;
        private_acl(&file, private)?;
        file.write_all(bytes)?;
        file.sync_all()?;
        Ok(id)
    })();
    if result.is_err() {
        // This is the still-held CREATE_NEW handle, never a reopened arbitrary
        // pathname. Retain it until its failed write is actually removed.
        let disposition = FILE_DISPOSITION_INFO { DeleteFile: true };
        while unsafe {
            SetFileInformationByHandle(
                HANDLE(file.as_raw_handle()),
                FileDispositionInfo,
                (&disposition as *const FILE_DISPOSITION_INFO).cast(),
                std::mem::size_of_val(&disposition) as u32,
            )
        }
        .is_err()
        {
            std::thread::sleep(Duration::from_millis(500));
        }
    }
    result
}
fn move_file(source: &Path, destination: &Path, id: FileId, private: bool) -> Result<()> {
    drop(pinned(source, id, private)?);
    // No replace-existing flag: an unexpected destination is never overwritten.
    unsafe {
        MoveFileExW(
            PCWSTR(wide(source).as_ptr()),
            PCWSTR(wide(destination).as_ptr()),
            MOVEFILE_WRITE_THROUGH,
        )?;
    }
    drop(pinned(destination, id, private)?);
    Ok(())
}
fn stage_pin(managed: &Managed, journal: &UpdateJournal) -> Result<File> {
    let path = managed.install.join(&journal.directory);
    let file = open(&path, true, READ_CONTROL.0, false, None, FILE_SHARE_READ)?;
    private_acl(&file, false)?;
    if facts(&file, true)? != journal.directory_id {
        bail!("owned_update_directory_changed");
    }
    Ok(file)
}
fn restore_one(
    destination: &Path,
    backup: &Path,
    old: Option<FileId>,
    new: Option<FileId>,
    private: bool,
) -> Result<()> {
    if destination.try_exists()? {
        let file = open(
            destination,
            false,
            READ_CONTROL.0,
            false,
            None,
            FILE_SHARE_READ,
        )?;
        private_acl(&file, private)?;
        let current = facts(&file, false)?;
        drop(file);
        if Some(current) == old {
            return Ok(());
        }
        if Some(current) != new {
            bail!("rollback_destination_not_owned");
        }
        delete(destination, current, private)?;
    }
    if let Some(old) = old {
        move_file(backup, destination, old, private)?;
    }
    Ok(())
}
fn rollback(managed: &Managed, journal: &UpdateJournal) -> Result<()> {
    let stage = managed.install.join(&journal.directory);
    let _directory = if stage.try_exists()? {
        Some(stage_pin(managed, journal)?)
    } else {
        None
    };
    let names = journal
        .old
        .keys()
        .chain(journal.new.keys())
        .collect::<std::collections::BTreeSet<_>>();
    for name in names {
        restore_one(
            &managed.install.join(name),
            &stage.join(format!("old-{name}")),
            journal.old.get(name).copied().flatten(),
            journal.new.get(name).copied(),
            false,
        )?;
    }
    restore_one(
        &managed.host.join("provision-v1.json"),
        &stage.join("old-provision.json"),
        Some(journal.provision_old),
        Some(journal.provision_new),
        true,
    )
}
fn cleanup(managed: &Managed, journal: &UpdateJournal) -> Result<()> {
    let stage = managed.install.join(&journal.directory);
    if !stage.try_exists()? {
        return Ok(());
    }
    let directory = stage_pin(managed, journal)?;
    for (name, id) in &journal.new {
        delete(&stage.join(format!("new-{name}")), *id, false)?;
    }
    for (name, id) in &journal.old {
        if let Some(id) = id {
            delete(&stage.join(format!("old-{name}")), *id, false)?;
        }
    }
    delete(
        &stage.join("new-provision.json"),
        journal.provision_new,
        true,
    )?;
    delete(
        &stage.join("old-provision.json"),
        journal.provision_old,
        true,
    )?;
    drop(directory);
    std::fs::remove_dir(&stage)?;
    Ok(())
}
fn journal_file(managed: &Managed, namespace: &str) -> Result<(UpdateJournal, FileId, Vec<u8>)> {
    let mut file = open(
        &managed.host.join(JOURNAL),
        false,
        FILE_GENERIC_READ.0 | READ_CONTROL.0,
        false,
        None,
        FILE_SHARE_READ,
    )?;
    private_acl(&file, true)?;
    let bytes = content(&mut file, 512 * 1024)?;
    let journal: UpdateJournal = serde_json::from_slice(&bytes)?;
    journal.validate(namespace)?;
    Ok((journal, facts(&file, false)?, bytes))
}
fn is_committed(managed: &Managed, bytes: &[u8]) -> Result<Option<FileId>> {
    let mut file = match open(
        &managed.host.join(COMMIT),
        false,
        FILE_GENERIC_READ.0 | READ_CONTROL.0,
        false,
        None,
        FILE_SHARE_READ,
    ) {
        Ok(file) => file,
        Err(error) if missing(&error) => return Ok(None),
        Err(error) => return Err(error),
    };
    private_acl(&file, true)?;
    let id = facts(&file, false)?;
    if content(&mut file, 128)? == format!("{:x}", Sha256::digest(bytes)).as_bytes() {
        Ok(Some(id))
    } else {
        delete_after_drop(file, &managed.host.join(COMMIT), id, true)?;
        Ok(None)
    }
}
fn delete_after_drop(file: File, path: &Path, id: FileId, private: bool) -> Result<()> {
    drop(file);
    delete(path, id, private)
}
fn finish(
    managed: &Managed,
    journal: &UpdateJournal,
    journal_id: FileId,
    commit: Option<FileId>,
    report: &impl Fn(&'static str),
) {
    loop {
        let result = (|| -> Result<()> {
            if commit.is_none() {
                rollback(managed, journal)?;
            }
            cleanup(managed, journal)?;
            // Remove the journal first. A power loss must never leave an
            // uncommitted journal after the committed backups were removed.
            delete(&managed.host.join(JOURNAL), journal_id, true)?;
            if let Some(id) = commit {
                delete(&managed.host.join(COMMIT), id, true)?;
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
pub(super) fn recover(
    managed: &mut Managed,
    approval: &LocalApprovalGrant,
    report: &impl Fn(&'static str),
) -> Result<()> {
    approval.revalidate()?;
    let (journal, id, bytes) = journal_file(managed, approval.origin().namespace())?;
    let commit = is_committed(managed, &bytes)?;
    finish(managed, &journal, id, commit, report);
    Ok(())
}
pub(super) fn enable_existing(managed: &mut Managed, approval: &LocalApprovalGrant) -> Result<()> {
    if managed
        .provision
        .as_ref()
        .is_some_and(|provision| provision.enabled)
    {
        return Ok(());
    }
    approval.revalidate()?;
    let path = managed.host.join("provision-v1.json");
    let entry = managed
        .files
        .iter_mut()
        .find(|entry| entry.path == path)
        .ok_or_else(|| anyhow!("owned_provision_unavailable"))?;
    let old = entry
        .id
        .ok_or_else(|| anyhow!("owned_provision_unavailable"))?;
    let mut provision = managed
        .provision
        .clone()
        .ok_or_else(|| anyhow!("owned_provision_unavailable"))?;
    provision.enabled = true;
    let temporary = managed
        .host
        .join(format!(".resume-{}.tmp", approval.consent().id()));
    let id = create(&temporary, &serde_json::to_vec(&provision)?, true)?;
    entry.file.take();
    drop(pinned(&path, old, true)?);
    let result = unsafe {
        MoveFileExW(
            PCWSTR(wide(&temporary).as_ptr()),
            PCWSTR(wide(&path).as_ptr()),
            MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH,
        )
    };
    if let Err(error) = result {
        delete(&temporary, id, true)?;
        return Err(error.into());
    }
    entry.file = Some(pinned(&path, id, true)?);
    entry.id = Some(id);
    managed.provision = Some(provision);
    Ok(())
}
pub(super) fn clear_orphan_commit(managed: &Managed, approval: &LocalApprovalGrant) -> Result<()> {
    if managed.host.join(JOURNAL).try_exists()? || !managed.host.join(COMMIT).try_exists()? {
        return Ok(());
    }
    approval.revalidate()?;
    let path = managed.host.join(COMMIT);
    let mut file = open(
        &path,
        false,
        FILE_GENERIC_READ.0 | READ_CONTROL.0,
        false,
        None,
        FILE_SHARE_READ,
    )?;
    private_acl(&file, true)?;
    let id = facts(&file, false)?;
    let bytes = content(&mut file, 128)?;
    if !std::str::from_utf8(&bytes).is_ok_and(hex) {
        bail!("orphan_update_marker_unconfirmed");
    }
    delete_after_drop(file, &path, id, true)
}
pub(super) fn run(
    managed: &mut Managed,
    approval: &LocalApprovalGrant,
    release: &ReleaseManifest,
    source: &Path,
    report: &impl Fn(&'static str),
) -> Result<()> {
    approval.revalidate()?;
    release.validate()?;
    if managed.host.join(JOURNAL).try_exists()? || managed.host.join(COMMIT).try_exists()? {
        bail!("interrupted_upgrade_requires_local_repair");
    }
    let _source_parents = ancestor_pins(source)?;
    let source_directory = open(source, true, READ_CONTROL.0, false, None, FILE_SHARE_READ)?;
    let install_directory = open(
        &managed.install,
        true,
        READ_CONTROL.0,
        false,
        None,
        FILE_SHARE_READ,
    )?;
    if facts(&source_directory, true)? == facts(&install_directory, true)? {
        bail!("separate_fixed_update_source_required");
    }
    let provision = managed
        .provision
        .clone()
        .ok_or_else(|| anyhow!("owned_provision_unavailable"))?;
    let mut source_pins = BTreeMap::new();
    for (name, pin) in &release.files {
        if name.len() > 240 {
            bail!("update_payload_name_too_long");
        }
        let path = source.join(name);
        let mut file = open(
            &path,
            false,
            FILE_GENERIC_READ.0 | READ_CONTROL.0,
            false,
            None,
            FILE_SHARE_READ,
        )?;
        if file.metadata()?.len() != pin.length || hash(&mut file, MAX_PAYLOAD_BYTES)? != pin.sha256
        {
            bail!("fixed_update_payload_changed");
        }
        if name == HOST && !approval.reviewed_unsigned() {
            authenticode(&file, &path)?;
        }
        if !provision.files.contains_key(name) && managed.install.join(name).try_exists()? {
            bail!("update_destination_not_owned");
        }
        source_pins.insert(name.clone(), file);
    }
    let directory = format!(".nikodesk-update-{}", approval.consent().id());
    let stage = managed.install.join(&directory);
    let descriptor = Descriptor::new("O:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)")?;
    unsafe {
        CreateDirectoryW(
            PCWSTR(wide(&stage).as_ptr()),
            Some(&descriptor.attributes()),
        )?;
    }
    let directory_pin = open(&stage, true, READ_CONTROL.0, false, None, FILE_SHARE_READ)?;
    private_acl(&directory_pin, false)?;
    let directory_id = facts(&directory_pin, true)?;
    let mut staged = Vec::<(PathBuf, FileId, bool)>::new();
    let prepared = (|| -> Result<UpdateJournal> {
        let mut new = BTreeMap::new();
        for (name, pin) in &release.files {
            approval.revalidate()?;
            let bytes = content(
                source_pins
                    .get_mut(name)
                    .ok_or_else(|| anyhow!("fixed_update_source_unavailable"))?,
                MAX_PAYLOAD_BYTES,
            )?;
            if bytes.len() as u64 != pin.length
                || format!("{:x}", Sha256::digest(&bytes)) != pin.sha256
            {
                bail!("fixed_update_source_changed");
            }
            let path = stage.join(format!("new-{name}"));
            let id = create(&path, &bytes, false)?;
            staged.push((path.clone(), id, false));
            let mut verified = pinned(&path, id, false)?;
            if hash(&mut verified, MAX_PAYLOAD_BYTES)? != pin.sha256 {
                bail!("staged_update_readback_mismatch");
            }
            if name == HOST && !approval.reviewed_unsigned() {
                authenticode(&verified, &path)?;
            }
            new.insert(name.clone(), id);
        }
        let new_provision =
            Provision::from_manifest(release, approval.consent(), provision.enabled);
        let path = stage.join("new-provision.json");
        let provision_new = create(&path, &serde_json::to_vec(&new_provision)?, true)?;
        staged.push((path, provision_new, true));
        let old = provision
            .files
            .keys()
            .map(|name| {
                let path = managed.install.join(name);
                managed
                    .files
                    .iter()
                    .find(|entry| entry.path == path)
                    .map(|entry| (name.clone(), entry.id))
                    .ok_or_else(|| anyhow!("owned_old_payload_unavailable"))
            })
            .collect::<Result<BTreeMap<_, _>>>()?;
        let provision_old = managed
            .files
            .iter()
            .find(|entry| entry.path == managed.host.join("provision-v1.json"))
            .and_then(|entry| entry.id)
            .ok_or_else(|| anyhow!("owned_old_provision_unavailable"))?;
        let journal = UpdateJournal {
            version: 1,
            namespace: approval.origin().namespace().into(),
            directory,
            directory_id,
            old,
            new,
            provision_old,
            provision_new,
        };
        journal.validate(approval.origin().namespace())?;
        Ok(journal)
    })();
    let journal = match prepared {
        Ok(value) => value,
        Err(error) => {
            drop(directory_pin);
            for (path, id, private) in staged {
                while delete(&path, id, private).is_err() {
                    report("recovery");
                    std::thread::sleep(Duration::from_secs(2));
                }
            }
            while std::fs::remove_dir(&stage).is_err() {
                report("recovery");
                std::thread::sleep(Duration::from_secs(2));
            }
            return Err(error);
        }
    };
    let bytes = serde_json::to_vec(&journal)?;
    let journal_id = match create(&managed.host.join(JOURNAL), &bytes, true) {
        Ok(id) => id,
        Err(error) => {
            drop(directory_pin);
            while cleanup(managed, &journal).is_err() {
                report("recovery");
                std::thread::sleep(Duration::from_secs(2));
            }
            return Err(error);
        }
    };
    let was_running = service_state(managed.service()?)? == SERVICE_RUNNING;
    let startup = service_start_kind(managed.service()?, &managed.install)?;
    managed.stop(report);
    let applied = (|| -> Result<FileId> {
        approval.revalidate()?;
        for (name, old) in &journal.old {
            let path = managed.install.join(name);
            if let Some(entry) = managed.files.iter_mut().find(|entry| entry.path == path) {
                entry.file.take();
            }
            if let Some(old) = old {
                move_file(&path, &stage.join(format!("old-{name}")), *old, false)?;
            }
        }
        for (name, id) in &journal.new {
            approval.revalidate()?;
            move_file(
                &stage.join(format!("new-{name}")),
                &managed.install.join(name),
                *id,
                false,
            )?;
        }
        let path = managed.host.join("provision-v1.json");
        if let Some(entry) = managed.files.iter_mut().find(|entry| entry.path == path) {
            entry.file.take();
        }
        move_file(
            &path,
            &stage.join("old-provision.json"),
            journal.provision_old,
            true,
        )?;
        move_file(
            &stage.join("new-provision.json"),
            &path,
            journal.provision_new,
            true,
        )?;
        for (name, id) in &journal.new {
            let mut file = pinned(&managed.install.join(name), *id, false)?;
            if hash(&mut file, MAX_PAYLOAD_BYTES)? != release.files[name].sha256 {
                bail!("installed_update_readback_mismatch");
            }
        }
        approval.revalidate()?;
        create(
            &managed.host.join(COMMIT),
            format!("{:x}", Sha256::digest(&bytes)).as_bytes(),
            true,
        )
    })();
    drop(directory_pin);
    match applied {
        Err(error) => {
            finish(managed, &journal, journal_id, None, report);
            return Err(error);
        }
        Ok(commit) => finish(managed, &journal, journal_id, Some(commit), report),
    }
    managed.files.retain(|entry| entry.private);
    for (name, id) in &journal.new {
        let path = managed.install.join(name);
        let file = pinned(&path, *id, false)?;
        managed.files.push(HeldFile {
            path,
            id: Some(*id),
            private: false,
            file: Some(file),
        });
    }
    let path = managed.host.join("provision-v1.json");
    if let Some(entry) = managed.files.iter_mut().find(|entry| entry.path == path) {
        entry.id = Some(journal.provision_new);
        entry.file = Some(pinned(&path, journal.provision_new, true)?);
    }
    managed.provision = Some(Provision::from_manifest(
        release,
        approval.consent(),
        provision.enabled,
    ));
    // Explicit update preserves immediate running state. A repaired or stopped
    // installation stays disabled until the separate Resume confirmation.
    if was_running {
        managed.resume(approval, report)?;
    } else if startup == SERVICE_AUTO_START && provision.enabled {
        approval.revalidate()?;
        set_start(managed.service()?, SERVICE_AUTO_START)?;
    }
    Ok(())
}
