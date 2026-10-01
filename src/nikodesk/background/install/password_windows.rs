//! The local maintenance grant owns this single-file credential replacement.
use super::*;

impl Managed {
    pub(super) fn change_password(
        &mut self,
        approval: &LocalApprovalGrant,
        password: &UnattendedSecret,
        report: &impl Fn(&'static str),
    ) -> Result<()> {
        approval.revalidate()?;
        let context = MachineEncryptionContext::from_os_machine_uid()?;
        let server = MachineProfileServer::new(
            approval.server().rendezvous.clone(),
            approval.server().relay.clone(),
            approval.server().public_key.clone(),
        )?;
        let mut profile = BTreeMap::new();
        let prepared = (|| -> Result<Vec<u8>> {
            for name in ["NikoDesk.toml", "NikoDesk2.toml"] {
                let path = self.config.join(name);
                let entry = self
                    .files
                    .iter()
                    .find(|entry| entry.path == path)
                    .ok_or_else(|| anyhow!("owned_machine_profile_unavailable"))?;
                let id = entry
                    .id
                    .ok_or_else(|| anyhow!("owned_machine_profile_unavailable"))?;
                let mut held = update::pinned(&path, id, true)?;
                profile.insert(name.to_owned(), content(&mut held, 128 * 1024)?);
            }
            Codec::prepare_password_update(&context, &profile, &server, password)
        })();
        for bytes in profile.values_mut() {
            wipe(bytes);
        }
        let mut bytes = prepared?;
        self.stop(report);
        report("profile");
        let result = (|| -> Result<()> {
            approval.revalidate()?;
            let path = self.config.join("NikoDesk.toml");
            let temporary = self.config.join(format!(
                ".nikodesk-password-{}.toml",
                approval.consent().id()
            ));
            let new_id = update::create(&temporary, &bytes, true)?;
            let replaced = (|| -> Result<()> {
                let mut staged = update::pinned(&temporary, new_id, true)?;
                let mut readback = content(&mut staged, 128 * 1024)?;
                let matches = readback == bytes;
                wipe(&mut readback);
                if !matches {
                    bail!("machine_password_stage_unconfirmed");
                }
                drop(staged);
                approval.revalidate()?;
                let entry = self
                    .files
                    .iter_mut()
                    .find(|entry| entry.path == path)
                    .ok_or_else(|| anyhow!("owned_machine_profile_unavailable"))?;
                let old = entry
                    .id
                    .ok_or_else(|| anyhow!("owned_machine_profile_unavailable"))?;
                entry.file.take();
                drop(update::pinned(&path, old, true)?);
                // Salt and verifier live in the same atomic replacement. The
                // settings file and encrypted device ID are not regenerated.
                unsafe {
                    MoveFileExW(
                        PCWSTR(wide(&temporary).as_ptr()),
                        PCWSTR(wide(&path).as_ptr()),
                        MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH,
                    )?;
                }
                entry.id = Some(new_id);
                let mut current = update::pinned(&path, new_id, true)?;
                let mut readback = content(&mut current, 128 * 1024)?;
                let matches = readback == bytes;
                wipe(&mut readback);
                if !matches {
                    bail!("machine_password_readback_unconfirmed");
                }
                entry.file = Some(current);
                approval.revalidate()
            })();
            if replaced.is_err() {
                while update::delete(&temporary, new_id, true).is_err() {
                    report("recovery");
                    std::thread::sleep(Duration::from_secs(2));
                }
            }
            replaced
        })();
        wipe(&mut bytes);
        result?;
        report("verify");
        if approval.consent().start_after_commit {
            self.resume(approval, report)?;
        }
        Ok(())
    }
}
