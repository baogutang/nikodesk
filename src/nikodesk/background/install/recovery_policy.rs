//! Append-only, non-secret ownership records for interrupted first installs.
//! An intent names only a nonce staging object. Fixed targets are claimed only
//! after recording their actual kernel identity and a pending rename.
use super::{
    policy::{hex, FileIdentity, ReleaseManifest},
    transaction::Phase,
};
use hbb_common::anyhow::{anyhow, bail, Result};
use hbb_common::serde_derive::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};

pub(crate) const LEDGER: &str = "NikoDesk-install-v2.journal";
pub(crate) const MAX_LEDGER: usize = 2 * 1024 * 1024;
const MAX_RECORD: usize = 256 * 1024;

#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum Area {
    Program,
    Machine,
    Host,
    Config,
}

#[derive(Clone, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub(crate) enum Object {
    Root { area: Area },
    RootStage { area: Area },
    File { area: Area, name: String },
    FileStage { area: Area, serial: u32 },
}
impl Object {
    pub(crate) fn area(&self) -> Area {
        match self {
            Self::Root { area }
            | Self::RootStage { area }
            | Self::File { area, .. }
            | Self::FileStage { area, .. } => *area,
        }
    }
    pub(crate) fn directory(&self) -> bool {
        matches!(self, Self::Root { .. } | Self::RootStage { .. })
    }
    pub(crate) fn stage(&self) -> bool {
        matches!(self, Self::RootStage { .. } | Self::FileStage { .. })
    }
    fn validate(&self, header: &Header) -> Result<()> {
        match self {
            Self::Root { .. } | Self::RootStage { .. } => {}
            Self::FileStage { area, serial } if *area != Area::Machine && *serial <= 4096 => {}
            Self::File {
                area: Area::Program,
                name,
            } if header.release.files.contains_key(name) => {}
            Self::File {
                area: Area::Config,
                name,
            } if matches!(name.as_str(), "NikoDesk.toml" | "NikoDesk2.toml") => {}
            Self::File {
                area: Area::Host,
                name,
            } if matches!(
                name.as_str(),
                "setup.lock" | "provision-v1.json" | "install-journal-v1.json"
            ) => {}
            Self::File {
                area: Area::Host,
                name,
            } => {
                let prefix = format!(".{}-", header.transaction);
                let serial = name
                    .strip_prefix(&prefix)
                    .and_then(|value| value.strip_suffix(".tmp"))
                    .filter(|value| !value.is_empty() && value.bytes().all(|b| b.is_ascii_digit()))
                    .and_then(|value| value.parse::<u32>().ok());
                if serial.map_or(true, |value| value > 4096) {
                    bail!("install_recovery_invalid_object");
                }
            }
            _ => bail!("install_recovery_invalid_object"),
        }
        Ok(())
    }
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Header {
    pub version: u32,
    pub transaction: String,
    pub namespace: String,
    pub program_parent: FileIdentity,
    pub machine_parent: FileIdentity,
    pub existing_roots: BTreeMap<Area, FileIdentity>,
    pub release: ReleaseManifest,
}
impl Header {
    pub(crate) fn validate(&self) -> Result<()> {
        if self.version != 2
            || !hex(&self.transaction)
            || !hex(&self.namespace)
            || self.transaction == "0".repeat(64)
            || self.namespace == "0".repeat(64)
        {
            bail!("install_recovery_invalid_header");
        }
        identity(self.program_parent)?;
        identity(self.machine_parent)?;
        for id in self.existing_roots.values() {
            identity(*id)?;
        }
        self.release.validate()
    }
}
fn identity(value: FileIdentity) -> Result<()> {
    if value.high == 0 && value.low == 0 {
        bail!("install_recovery_invalid_identity");
    }
    Ok(())
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case", deny_unknown_fields)]
pub(crate) enum Event {
    Begin {
        header: Header,
    },
    Intent {
        object: Object,
    },
    Created {
        object: Object,
        id: FileIdentity,
    },
    Rename {
        from: Object,
        to: Object,
        id: FileIdentity,
        replaces: Option<FileIdentity>,
    },
    ServiceIntent,
    Commit {
        public_id: String,
    },
    Phase {
        phase: Phase,
    },
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Frame {
    sequence: u64,
    previous: String,
    event: Event,
}

#[derive(Clone)]
pub(crate) struct Replay {
    pub header: Header,
    pub objects: BTreeMap<Object, Vec<FileIdentity>>,
    pub intents: BTreeSet<Object>,
    pub existing: BTreeSet<Area>,
    pub committed: bool,
    pub public_id: Option<String>,
    pub service_intended: bool,
    pub valid_length: usize,
    sequence: u64,
    previous: String,
}
impl Replay {
    pub(crate) fn begin(header: Header) -> Result<Self> {
        header.validate()?;
        let objects = header
            .existing_roots
            .iter()
            .map(|(area, id)| (Object::Root { area: *area }, vec![*id]))
            .collect();
        let existing = header.existing_roots.keys().copied().collect();
        Ok(Self {
            header,
            objects,
            intents: BTreeSet::new(),
            existing,
            committed: false,
            public_id: None,
            service_intended: false,
            valid_length: 0,
            sequence: 0,
            previous: "0".repeat(64),
        })
    }
    pub(crate) fn encode_next(&self, event: Event) -> Result<Vec<u8>> {
        let mut bytes = serde_json::to_vec(&Frame {
            sequence: self
                .sequence
                .checked_add(1)
                .ok_or_else(|| anyhow!("install_recovery_sequence_exhausted"))?,
            previous: self.previous.clone(),
            event,
        })?;
        if bytes.len() > MAX_RECORD || self.valid_length + bytes.len() + 1 > MAX_LEDGER {
            bail!("install_recovery_limit");
        }
        bytes.push(b'\n');
        Ok(bytes)
    }
    pub(crate) fn accept(&mut self, bytes: &[u8]) -> Result<()> {
        if bytes.len() > MAX_RECORD + 1 || bytes.last() != Some(&b'\n') {
            bail!("install_recovery_invalid_record");
        }
        let frame: Frame = serde_json::from_slice(bytes)?;
        if frame.sequence != self.sequence + 1 || frame.previous != self.previous {
            bail!("install_recovery_invalid_chain");
        }
        if self.sequence == 0 && !matches!(&frame.event, Event::Begin { .. }) {
            bail!("install_recovery_missing_header");
        }
        match frame.event {
            Event::Begin { header } => {
                if self.sequence != 0
                    || serde_json::to_vec(&header)? != serde_json::to_vec(&self.header)?
                {
                    bail!("install_recovery_invalid_begin");
                }
            }
            Event::Intent { object } => {
                object.validate(&self.header)?;
                if !object.stage() || !self.intents.insert(object) {
                    bail!("install_recovery_invalid_intent");
                }
            }
            Event::Created { object, id } => {
                identity(id)?;
                if !self.intents.contains(&object) || self.objects.contains_key(&object) {
                    bail!("install_recovery_unowned_create");
                }
                self.objects.insert(object, vec![id]);
            }
            Event::Rename {
                from,
                to,
                id,
                replaces,
            } => {
                from.validate(&self.header)?;
                to.validate(&self.header)?;
                identity(id)?;
                if from == to
                    || from.area() != to.area()
                    || from.directory() != to.directory()
                    || !self
                        .objects
                        .get(&from)
                        .map_or(false, |ids| ids.contains(&id))
                    || replaces.map_or(false, |old| {
                        !self
                            .objects
                            .get(&to)
                            .map_or(false, |ids| ids.contains(&old))
                    })
                    || replaces.is_none() && self.objects.contains_key(&to)
                {
                    bail!("install_recovery_invalid_rename");
                }
                self.objects.entry(to).or_default().push(id);
            }
            Event::ServiceIntent => {
                if self.committed || self.service_intended {
                    bail!("install_recovery_invalid_service_intent");
                }
                self.service_intended = true;
            }
            Event::Commit { public_id } => {
                if self.committed
                    || !self.service_intended
                    || public_id.len() != 10
                    || public_id.starts_with('0')
                    || !public_id.bytes().all(|b| b.is_ascii_digit())
                {
                    bail!("install_recovery_invalid_commit");
                }
                self.committed = true;
                self.public_id = Some(public_id);
            }
            Event::Phase { .. } => {}
        }
        self.sequence = frame.sequence;
        self.previous = format!("{:x}", Sha256::digest(bytes));
        self.valid_length += bytes.len();
        Ok(())
    }
    pub(crate) fn decode(bytes: &[u8]) -> Result<Self> {
        if bytes.len() > MAX_LEDGER {
            bail!("install_recovery_limit");
        }
        let first = bytes
            .split_inclusive(|b| *b == b'\n')
            .next()
            .ok_or_else(|| anyhow!("install_recovery_missing_header"))?;
        if first.last() != Some(&b'\n') {
            bail!("install_recovery_missing_header");
        }
        let first_frame: Frame = serde_json::from_slice(first)?;
        let Event::Begin { header } = first_frame.event else {
            bail!("install_recovery_missing_header");
        };
        let mut replay = Self::begin(header)?;
        for record in bytes.split_inclusive(|b| *b == b'\n') {
            if record.last() != Some(&b'\n') {
                break;
            } // Only an unfinished final append is ignorable.
            replay.accept(record)?;
        }
        Ok(replay)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn header() -> Header {
        Header {
            version: 2,
            transaction: "a".repeat(64),
            namespace: "b".repeat(64),
            program_parent: FileIdentity {
                volume: 1,
                high: 0,
                low: 1,
            },
            machine_parent: FileIdentity {
                volume: 1,
                high: 0,
                low: 2,
            },
            existing_roots: BTreeMap::new(),
            release: ReleaseManifest {
                version: "1.1.0".into(),
                build: 8,
                files: BTreeMap::from([(
                    "nikodesk-host.exe".into(),
                    super::super::policy::PayloadEntry {
                        sha256: "c".repeat(64),
                        length: 1,
                    },
                )]),
            },
        }
    }
    #[test]
    fn partial_append_keeps_prior_id_and_rename_intent_but_complete_corruption_is_rejected() {
        let mut replay = Replay::begin(header()).unwrap();
        let mut bytes = vec![];
        let area = Area::Program;
        let stage = Object::RootStage { area };
        let id = FileIdentity {
            volume: 1,
            high: 0,
            low: 3,
        };
        for event in [
            Event::Begin { header: header() },
            Event::Intent {
                object: stage.clone(),
            },
            Event::Created {
                object: stage.clone(),
                id,
            },
            Event::Rename {
                from: stage,
                to: Object::Root { area },
                id,
                replaces: None,
            },
        ] {
            let frame = replay.encode_next(event).unwrap();
            replay.accept(&frame).unwrap();
            bytes.extend(frame);
        }
        let complete = bytes.len();
        bytes.extend(b"{\"sequence\":5,");
        let recovered = Replay::decode(&bytes).unwrap();
        assert_eq!(recovered.valid_length, complete);
        assert!(recovered.objects[&Object::Root { area }].contains(&id));
        bytes.push(b'\n');
        assert!(Replay::decode(&bytes).is_err());
    }
    #[test]
    fn retained_roots_are_in_the_first_durable_frame_and_never_become_owned() {
        let id = FileIdentity {
            volume: 1,
            high: 0,
            low: 9,
        };
        let mut header = header();
        header.existing_roots.insert(Area::Host, id);
        let replay = Replay::begin(header.clone()).unwrap();
        let first = replay.encode_next(Event::Begin { header }).unwrap();
        let readback = Replay::decode(&first).unwrap();
        assert!(readback.existing.contains(&Area::Host));
        assert!(readback.objects[&Object::Root { area: Area::Host }].contains(&id));
        let mut incomplete = first;
        incomplete.extend(b"{\"sequence\":2,");
        assert!(Replay::decode(&incomplete)
            .unwrap()
            .existing
            .contains(&Area::Host));
    }
    #[test]
    fn fixed_path_intents_and_wrong_object_identity_never_authorize_cleanup() {
        let mut replay = Replay::begin(header()).unwrap();
        let first = replay
            .encode_next(Event::Begin { header: header() })
            .unwrap();
        replay.accept(&first).unwrap();
        let invalid = replay
            .encode_next(Event::Intent {
                object: Object::File {
                    area: Area::Program,
                    name: "nikodesk-host.exe".into(),
                },
            })
            .unwrap();
        assert!(replay.accept(&invalid).is_err());
        let invalid = replay
            .encode_next(Event::Created {
                object: Object::RootStage {
                    area: Area::Program,
                },
                id: FileIdentity {
                    volume: 1,
                    high: 0,
                    low: 3,
                },
            })
            .unwrap();
        assert!(replay.accept(&invalid).is_err());
    }
}
