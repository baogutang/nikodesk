//! Bounded role-specific protocol: no command, path, config, secret or SAS RPC.
use super::policy::Binding;
use hbb_common::{
    anyhow::anyhow,
    bail,
    tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt},
    ResultType,
};
use serde::{Deserialize, Serialize};
pub(crate) const MAX_FRAME: usize = 16 * 1024;
const VERSION: u32 = 1;
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(tag = "kind", deny_unknown_fields)]
pub(crate) enum Packet {
    Hello {
        session: u32,
        generation: u64,
        nonce: [u8; 32],
    },
    Grant {
        session: u32,
        generation: u64,
        nonce: [u8; 32],
    },
    Ready {
        session: u32,
        generation: u64,
        nonce: [u8; 32],
        desktop_selected: bool,
    },
    Heartbeat {
        session: u32,
        generation: u64,
        nonce: [u8; 32],
    },
    Revoke {
        session: u32,
        generation: u64,
        nonce: [u8; 32],
    },
}
#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Frame {
    version: u32,
    packet: Packet,
}
impl Packet {
    pub(crate) fn binding(&self) -> Binding {
        let (session, generation, nonce) = match self {
            Self::Hello {
                session,
                generation,
                nonce,
            }
            | Self::Grant {
                session,
                generation,
                nonce,
            }
            | Self::Ready {
                session,
                generation,
                nonce,
                ..
            }
            | Self::Heartbeat {
                session,
                generation,
                nonce,
            }
            | Self::Revoke {
                session,
                generation,
                nonce,
            } => (*session, *generation, *nonce),
        };
        Binding {
            session,
            generation,
            nonce,
        }
    }
}
pub(crate) async fn read<R: AsyncRead + Unpin>(stream: &mut R) -> ResultType<Packet> {
    let len = stream.read_u32_le().await? as usize;
    if len == 0 || len > MAX_FRAME {
        bail!("Invalid background frame length");
    }
    let mut bytes = vec![0; len];
    stream.read_exact(&mut bytes).await?;
    let frame: Frame =
        serde_json::from_slice(&bytes).map_err(|_| anyhow!("Invalid background packet"))?;
    if frame.version != VERSION {
        bail!("Unsupported background protocol version");
    }
    Ok(frame.packet)
}
pub(crate) async fn write<W: AsyncWrite + Unpin>(
    stream: &mut W,
    packet: &Packet,
) -> ResultType<()> {
    let bytes = serde_json::to_vec(&Frame {
        version: VERSION,
        packet: packet.clone(),
    })?;
    if bytes.len() > MAX_FRAME {
        bail!("Background frame is too large");
    }
    stream.write_u32_le(bytes.len() as u32).await?;
    stream.write_all(&bytes).await?;
    stream.flush().await?;
    Ok(())
}
#[cfg(test)]
mod tests {
    use super::*;
    fn hello() -> Packet {
        Packet::Hello {
            session: 1,
            generation: 1,
            nonce: [1; 32],
        }
    }
    fn frame(bytes: Vec<u8>) -> Vec<u8> {
        let mut frame = (bytes.len() as u32).to_le_bytes().to_vec();
        frame.extend(bytes);
        frame
    }
    #[tokio::test]
    async fn unknown_roles_and_oversized_frames_are_rejected_before_allocation() {
        let mut unknown_field = serde_json::to_value(&Frame {
            version: VERSION,
            packet: hello(),
        })
        .unwrap();
        unknown_field["packet"]["path"] = "fixture".into();
        for bytes in [
            br#"{"version":1,"packet":{"kind":"RunCommand","cmd":"fixture"}}"#.to_vec(),
            serde_json::to_vec(&unknown_field).unwrap(),
        ] {
            let frame = frame(bytes);
            assert!(read(&mut frame.as_slice()).await.is_err());
        }
        let frame = ((MAX_FRAME + 1) as u32).to_le_bytes();
        assert!(read(&mut frame.as_slice()).await.is_err());
    }
    #[tokio::test]
    async fn valid_frames_retain_the_binding_and_reject_versions_and_truncation() {
        let mut bytes = Vec::new();
        write(&mut bytes, &hello()).await.unwrap();
        assert_eq!(
            read(&mut bytes.as_slice()).await.unwrap().binding(),
            hello().binding()
        );
        let wrong_version = frame(
            serde_json::to_vec(&Frame {
                version: 2,
                packet: hello(),
            })
            .unwrap(),
        );
        assert!(read(&mut wrong_version.as_slice()).await.is_err());
        assert!(read(&mut &bytes[..bytes.len() - 1]).await.is_err());
        assert!(read(&mut &[0u8; 4][..]).await.is_err());
    }
}
