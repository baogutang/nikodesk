//! Persisted filesystem facts for an owned upgrade. These are never local
//! approval: the native broker must independently verify its current caller.
use super::policy::{hex, leaf, FileIdentity};
use hbb_common::{
    anyhow::{bail, Result},
    serde_derive::{Deserialize, Serialize},
};
use std::collections::{BTreeMap, BTreeSet};

pub const JOURNAL: &str = "update-journal-v1.json";
pub const COMMIT: &str = "update-commit-v1";
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct UpdateJournal {
    pub version: u32,
    pub namespace: String,
    pub directory: String,
    pub directory_id: FileIdentity,
    pub old: BTreeMap<String, Option<FileIdentity>>,
    pub new: BTreeMap<String, FileIdentity>,
    pub provision_old: FileIdentity,
    pub provision_new: FileIdentity,
}
impl UpdateJournal {
    pub fn validate(&self, namespace: &str) -> Result<()> {
        let valid_id = |id: &FileIdentity| id.high != 0 || id.low != 0;
        if self.version != 1
            || !hex(&self.namespace)
            || self.namespace != namespace
            || self.namespace == "0".repeat(64)
            || !self
                .directory
                .strip_prefix(".nikodesk-update-")
                .is_some_and(hex)
            || !valid_id(&self.directory_id)
            || !valid_id(&self.provision_old)
            || !valid_id(&self.provision_new)
            || self.old.is_empty()
            || self.old.len() > 256
            || self.new.is_empty()
            || self.new.len() > 256
            || !self.old.contains_key(super::policy::HOST)
            || !self.new.contains_key(super::policy::HOST)
        {
            bail!("owned_update_journal_unconfirmed");
        }
        let mut names = BTreeMap::<String, String>::new();
        for name in self.old.keys().chain(self.new.keys()) {
            if !leaf(name) || name.len() > 240 {
                bail!("invalid_update_payload_name");
            }
            if let Some(original) = names.insert(name.to_ascii_lowercase(), name.clone()) {
                if original != *name {
                    bail!("update_payload_case_collision");
                }
            }
        }
        if self
            .old
            .values()
            .flatten()
            .chain(self.new.values())
            .any(|id| !valid_id(id))
        {
            bail!("invalid_update_file_identity");
        }
        let ids = self
            .new
            .values()
            .map(|id| (id.volume, id.high, id.low))
            .collect::<BTreeSet<_>>();
        if ids.len() != self.new.len() {
            bail!("duplicate_update_file_identity");
        }
        Ok(())
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    fn journal() -> UpdateJournal {
        let id = |low| FileIdentity {
            volume: 7,
            high: 0,
            low,
        };
        UpdateJournal {
            version: 1,
            namespace: "a".repeat(64),
            directory: format!(".nikodesk-update-{}", "b".repeat(64)),
            directory_id: id(1),
            old: BTreeMap::from([(super::super::policy::HOST.into(), Some(id(2)))]),
            new: BTreeMap::from([(super::super::policy::HOST.into(), id(3))]),
            provision_old: id(4),
            provision_new: id(5),
        }
    }
    #[test]
    fn update_journal_has_exact_scope_and_never_accepts_paths_or_zero_file_ids() {
        let original = journal();
        assert!(original.validate(&"a".repeat(64)).is_ok());
        assert!(original.validate(&"c".repeat(64)).is_err());
        for path in ["..", "C:\\Windows", ".nikodesk-update-../other"] {
            let mut value = journal();
            value.directory = path.into();
            assert!(value.validate(&"a".repeat(64)).is_err());
        }
        let mut value = journal();
        value.provision_old.low = 0;
        assert!(value.validate(&"a".repeat(64)).is_err());
        value = journal();
        value.new.insert(
            "NIKODESK-HOST.EXE".into(),
            FileIdentity {
                volume: 7,
                high: 0,
                low: 6,
            },
        );
        assert!(value.validate(&"a".repeat(64)).is_err());
        value = journal();
        value
            .new
            .insert("extra.dll".into(), value.new[super::super::policy::HOST]);
        assert!(value.validate(&"a".repeat(64)).is_err());
    }
}
