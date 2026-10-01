//! Private local broker transport; these DTOs are not an installation grant.
use super::profile::ServerInput;
use hbb_common::{
    anyhow::{anyhow, bail, Result},
    config::MachineProfileServer,
    serde_derive::{Deserialize, Serialize},
};
use std::sync::Arc;

pub(crate) const MAX_WIRE: usize = 8192;

#[derive(Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub(crate) struct CurrentServerSnapshot {
    namespace: [u8; 32],
    generation: u64,
    settings_revision: u64,
    rendezvous: String,
    relay: String,
    public_key: String,
}
impl CurrentServerSnapshot {
    /// Only a snapshot claim. A real fixed-image kernel peer and subsequent
    /// privileged native confirmation are required before grant construction.
    pub(crate) fn from_verified_local_read(
        namespace: [u8; 32],
        generation: u64,
        settings_revision: u64,
        rendezvous: String,
        relay: String,
        public_key: String,
    ) -> Result<Self> {
        let value = Self {
            namespace,
            generation,
            settings_revision,
            rendezvous,
            relay,
            public_key,
        };
        value.validate()?;
        Ok(value)
    }
    pub(super) fn validate(&self) -> Result<()> {
        if self.namespace == [0; 32]
            || self.generation == 0
            || self.settings_revision == 0
            || self.rendezvous.len() > 320
            || self.relay.len() > 320
            || self.public_key.len() > 64
        {
            bail!("install_current_snapshot_invalid");
        }
        MachineProfileServer::new(
            self.rendezvous.clone(),
            self.relay.clone(),
            self.public_key.clone(),
        )?;
        Ok(())
    }
    pub(super) fn namespace(&self) -> [u8; 32] {
        self.namespace
    }
    pub(super) fn generation(&self) -> u64 {
        self.generation
    }
    pub(super) fn server(&self) -> ServerInput {
        ServerInput {
            rendezvous: self.rendezvous.clone(),
            relay: self.relay.clone(),
            public_key: self.public_key.clone(),
            settings_revision: self.settings_revision,
        }
    }
    pub(super) fn rendezvous(&self) -> &str {
        &self.rendezvous
    }
    pub(super) fn key(&self) -> &str {
        &self.public_key
    }
}
pub(crate) trait CurrentServerSnapshotProvider: Send + Sync {
    fn read_current_verified(&self) -> Result<CurrentServerSnapshot>;
}
pub(crate) type SnapshotProvider = Arc<dyn CurrentServerSnapshotProvider>;

#[derive(Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub(super) enum Packet {
    Read {
        sequence: u64,
        nonce: [u8; 32],
    },
    Snapshot {
        sequence: u64,
        nonce: [u8; 32],
        current: CurrentServerSnapshot,
    },
    Begin {
        #[serde(default)]
        action: super::policy::Action,
        sequence: u64,
        nonce: [u8; 32],
        current: CurrentServerSnapshot,
        password: String,
        start_after_commit: bool,
        #[serde(default)]
        allow_virtual_display: bool,
        #[serde(default)]
        lock_on_disconnect: bool,
        #[serde(default)]
        allow_privacy: bool,
        #[serde(default)]
        allow_remote_restart: bool,
    },
    Progress {
        sequence: u64,
        nonce: [u8; 32],
        phase: String,
        quiescent: bool,
        #[serde(default)]
        machine_id: String,
    },
    Cancel {
        sequence: u64,
        nonce: [u8; 32],
    },
}
impl Drop for Packet {
    fn drop(&mut self) {
        if let Self::Begin { password, .. } = self {
            // No raw password is printed or placed in CLI/environment parameters.
            unsafe {
                hbb_common::sodiumoxide::utils::memzero(password.as_bytes_mut());
            }
        }
    }
}
pub(super) fn encode(packet: &Packet) -> Result<Vec<u8>> {
    let mut bytes = serde_json::to_vec(packet).map_err(|_| anyhow!("install_packet_invalid"))?;
    if bytes.is_empty() || bytes.len() > MAX_WIRE {
        hbb_common::sodiumoxide::utils::memzero(&mut bytes);
        bail!("install_packet_too_large");
    }
    let mut output = Vec::with_capacity(bytes.len() + 4);
    output.extend_from_slice(&(bytes.len() as u32).to_le_bytes());
    output.append(&mut bytes);
    Ok(output)
}
pub(super) fn decode(bytes: &[u8]) -> Result<Packet> {
    if bytes.is_empty() || bytes.len() > MAX_WIRE {
        bail!("install_packet_too_large");
    }
    serde_json::from_slice(bytes).map_err(|_| anyhow!("install_packet_invalid"))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn json_never_contains_a_grant_and_bounds_or_unknown_fields_reject() {
        assert!(decode(br#"{"kind":"grant","approved":true}"#).is_err());
        assert!(decode(&vec![b'x'; MAX_WIRE + 1]).is_err());
        assert!(decode(br#"{"kind":"cancel","sequence":1,"nonce":[],"extra":true}"#).is_err());
    }
    #[test]
    fn valid_snapshot_is_a_claim_only_and_cannot_change_private_shape() {
        let key = hbb_common::sodiumoxide::base64::encode(
            [7; 32],
            hbb_common::sodiumoxide::base64::Variant::Original,
        );
        assert!(CurrentServerSnapshot::from_verified_local_read(
            [1; 32],
            1,
            1,
            "nas.fixture.local:21116".into(),
            "".into(),
            key.clone()
        )
        .is_ok());
        assert!(CurrentServerSnapshot::from_verified_local_read(
            [1; 32],
            0,
            1,
            "nas.fixture.local:21116".into(),
            "".into(),
            key
        )
        .is_err());
    }
}

pub(super) fn pipe_name(nonce: &[u8; 32]) -> String {
    let suffix: String = nonce.iter().map(|b| format!("{b:02x}")).collect();
    format!(r"\\.\pipe\NikoDesk.install.v1.{suffix}")
}
pub(super) fn parse_nonce(text: &str) -> Result<[u8; 32]> {
    if text.len() != 64
        || !text
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    {
        bail!("install_nonce_invalid");
    }
    let mut nonce = [0; 32];
    for (i, byte) in nonce.iter_mut().enumerate() {
        *byte = u8::from_str_radix(&text[i * 2..i * 2 + 2], 16)
            .map_err(|_| anyhow!("install_nonce_invalid"))?;
    }
    if nonce == [0; 32] {
        bail!("install_nonce_invalid");
    }
    Ok(nonce)
}
pub(super) fn expect_sequence(
    actual: u64,
    expected: u64,
    nonce: &[u8; 32],
    current: &[u8; 32],
) -> Result<()> {
    if actual == 0 || actual != expected || nonce != current {
        bail!("install_packet_binding_changed");
    }
    Ok(())
}
struct SecretBuffer(Vec<u8>);
impl Drop for SecretBuffer {
    fn drop(&mut self) {
        hbb_common::sodiumoxide::utils::memzero(&mut self.0);
    }
}
pub(super) async fn read_packet<R: hbb_common::tokio::io::AsyncRead + Unpin>(
    stream: &mut R,
) -> Result<Packet> {
    use hbb_common::tokio::{
        io::AsyncReadExt,
        time::{timeout, Duration},
    };
    timeout(Duration::from_secs(10), async {
        let mut prefix = [0; 4];
        stream.read_exact(&mut prefix).await?;
        let size = u32::from_le_bytes(prefix) as usize;
        if size == 0 || size > MAX_WIRE {
            bail!("install_packet_too_large");
        }
        let mut bytes = SecretBuffer(vec![0; size]);
        stream.read_exact(&mut bytes.0).await?;
        decode(&bytes.0)
    })
    .await
    .map_err(|_| anyhow!("install_packet_timeout"))?
}
pub(super) async fn write_packet<W: hbb_common::tokio::io::AsyncWrite + Unpin>(
    stream: &mut W,
    packet: &Packet,
) -> Result<()> {
    use hbb_common::tokio::{
        io::AsyncWriteExt,
        time::{timeout, Duration},
    };
    let bytes = SecretBuffer(encode(packet)?);
    timeout(Duration::from_secs(10), stream.write_all(&bytes.0))
        .await
        .map_err(|_| anyhow!("install_packet_timeout"))??;
    Ok(())
}

#[cfg(test)]
mod transport_tests {
    use super::*;
    use hbb_common::tokio::{self, io::AsyncWriteExt};
    #[tokio::test]
    async fn actual_framed_transport_accepts_fragmented_bound_cancel() {
        let (mut sender, mut receiver) = tokio::io::duplex(4096);
        let expected = Packet::Cancel {
            sequence: 7,
            nonce: [2; 32],
        };
        let bytes = encode(&expected).unwrap();
        let writer = tokio::spawn(async move {
            for byte in bytes {
                sender.write_all(&[byte]).await.unwrap();
            }
        });
        let packet = read_packet(&mut receiver).await.unwrap();
        match &packet {
            Packet::Cancel { sequence, nonce } => {
                assert!(expect_sequence(*sequence, 7, nonce, &[2; 32]).is_ok())
            }
            _ => panic!("wrong packet"),
        }
        writer.await.unwrap();
    }
    #[tokio::test]
    async fn oversized_prefix_rejects_before_payload_allocation_or_wait() {
        let (mut sender, mut receiver) = tokio::io::duplex(64);
        sender
            .write_all(&((MAX_WIRE + 1) as u32).to_le_bytes())
            .await
            .unwrap();
        assert!(read_packet(&mut receiver).await.is_err());
    }
    #[tokio::test]
    async fn eof_during_payload_never_becomes_cancel_or_approval() {
        let (mut sender, mut receiver) = tokio::io::duplex(64);
        sender.write_all(&100u32.to_le_bytes()).await.unwrap();
        sender.write_all(b"{}").await.unwrap();
        drop(sender);
        assert!(read_packet(&mut receiver).await.is_err());
    }
    #[tokio::test]
    async fn production_encoder_and_reader_preserve_password_only_in_begin() {
        let key = hbb_common::sodiumoxide::base64::encode(
            [7; 32],
            hbb_common::sodiumoxide::base64::Variant::Original,
        );
        let current = CurrentServerSnapshot::from_verified_local_read(
            [1; 32],
            2,
            3,
            "nas.fixture.local:21116".into(),
            "".into(),
            key,
        )
        .unwrap();
        let (mut sender, mut receiver) = tokio::io::duplex(4096);
        let writer = tokio::spawn(async move {
            write_packet(
                &mut sender,
                &Packet::Begin {
                    action: super::super::policy::Action::Install,
                    sequence: 1,
                    nonce: [3; 32],
                    current,
                    password: "fixture-only Unicode 密码".into(),
                    start_after_commit: false,
                    allow_virtual_display: true,
                    lock_on_disconnect: false,
                    allow_privacy: false,
                    allow_remote_restart: false,
                },
            )
            .await
            .unwrap();
        });
        let packet = read_packet(&mut receiver).await.unwrap();
        match &packet {
            Packet::Begin {
                password,
                start_after_commit,
                ..
            } => {
                assert_eq!(password, "fixture-only Unicode 密码");
                assert!(!start_after_commit);
            }
            _ => panic!("wrong packet"),
        }
        writer.await.unwrap();
    }
    #[test]
    fn old_nonce_epoch_sequence_and_zero_nonce_cannot_refresh() {
        assert!(expect_sequence(7, 8, &[1; 32], &[1; 32]).is_err());
        assert!(expect_sequence(8, 8, &[2; 32], &[1; 32]).is_err());
        assert!(expect_sequence(0, 0, &[1; 32], &[1; 32]).is_err());
        assert!(parse_nonce(&"0".repeat(64)).is_err());
        assert!(parse_nonce(&"A".repeat(64)).is_err());
        assert!(parse_nonce(&"a".repeat(64)).is_ok());
    }
    #[tokio::test]
    async fn unknown_json_direction_does_not_generate_grant() {
        let (mut sender, mut receiver) = tokio::io::duplex(128);
        let payload = br#"{"kind":"grant","approved":true}"#;
        sender
            .write_all(&(payload.len() as u32).to_le_bytes())
            .await
            .unwrap();
        sender.write_all(payload).await.unwrap();
        assert!(read_packet(&mut receiver).await.is_err());
    }
}
