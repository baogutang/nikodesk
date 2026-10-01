//! A side-effect-free capability query on the already verified encrypted stream.
use base::message_proto::{message, misc, Message, NikoCameraProbe, NikoCameraProbeReply};
use hbb_common::{anyhow::anyhow, bail, protobuf::Message as _, tokio, ResultType, Stream};
use std::time::Duration;

struct ReplyBinding {
    nonce: [u8; 16],
    consumed: bool,
}
impl ReplyBinding {
    fn accept(&mut self, reply: &NikoCameraProbeReply) -> ResultType<()> {
        if self.consumed {
            bail!("camera_protocol_reply_replayed");
        }
        self.consumed = true;
        if reply.protocol != 1 || reply.nonce.as_ref() != self.nonce || self.nonce == [0; 16] {
            bail!("camera_protocol_reply_invalid");
        }
        if !reply.requests_allowed {
            bail!("camera_requests_disabled_on_remote");
        }
        Ok(())
    }
}
pub(crate) fn valid_request(probe: &NikoCameraProbe) -> bool {
    probe.protocol == 1 && probe.nonce.len() == 16 && probe.nonce.as_ref() != [0; 16]
}
pub(crate) fn allows_outgoing_login(camera: bool, verified: bool, message: &Message) -> bool {
    !camera
        || verified
        || !matches!(
            message.union.as_ref(),
            Some(message::Union::LoginRequest(_))
        )
}
pub(crate) async fn verify(stream: &mut Stream) -> ResultType<()> {
    verify_with_deadline(stream, Duration::from_secs(2)).await
}
async fn verify_with_deadline(stream: &mut Stream, deadline: Duration) -> ResultType<()> {
    if !stream.is_secured() {
        bail!("camera_probe_requires_verified_encryption");
    }
    let nonce = *uuid::Uuid::new_v4().as_bytes();
    let mut binding = ReplyBinding {
        nonce,
        consumed: false,
    };
    let mut request = Message::new();
    request.set_nikodesk_camera_probe(NikoCameraProbe {
        nonce: nonce.to_vec().into(),
        protocol: 1,
        ..Default::default()
    });
    let operation = async {
        stream.send(&request).await?;
        // The server can have sent its initial permissions and delay probes before
        // it saw this query. They establish no local device or resource grant.
        for _ in 0..16 {
            let bytes = stream
                .next()
                .await
                .ok_or_else(|| anyhow!("camera_protocol_probe_closed"))??;
            if bytes.len() > 65536 {
                bail!("camera_protocol_reply_invalid");
            }
            let response = Message::parse_from_bytes(&bytes)
                .map_err(|_| anyhow!("camera_protocol_reply_invalid"))?;
            match response.union {
                Some(message::Union::NikodeskCameraProbeReply(reply)) => {
                    return binding.accept(&reply)
                }
                Some(message::Union::Misc(m))
                    if matches!(m.union.as_ref(), Some(misc::Union::PermissionInfo(_))) => {}
                Some(message::Union::TestDelay(delay)) => {
                    let mut reply = Message::new();
                    reply.set_test_delay(delay);
                    stream.send(&reply).await?;
                }
                _ => bail!("camera_protocol_reply_invalid"),
            }
        }
        bail!("camera_protocol_probe_excess_messages")
    };
    tokio::time::timeout(deadline,operation).await.map_err(|_|anyhow!("Remote camera protocol is unsupported or did not respond; no camera login was sent"))?
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn camera_probe_nonce_protocol_and_single_reply_are_bound() {
        let valid = NikoCameraProbeReply {
            nonce: vec![7; 16].into(),
            protocol: 1,
            requests_allowed: true,
            ..Default::default()
        };
        let mut binding = ReplyBinding {
            nonce: [7; 16],
            consumed: false,
        };
        assert!(binding.accept(&valid).is_ok());
        assert!(binding.accept(&valid).is_err());
        for (nonce, protocol, allowed) in [
            (vec![8; 16], 1, true),
            (vec![7; 15], 1, true),
            (vec![7; 16], 2, true),
            (vec![7; 16], 1, false),
        ] {
            let mut binding = ReplyBinding {
                nonce: [7; 16],
                consumed: false,
            };
            assert!(binding
                .accept(&NikoCameraProbeReply {
                    nonce: nonce.into(),
                    protocol,
                    requests_allowed: allowed,
                    ..Default::default()
                })
                .is_err());
        }
    }
    #[test]
    fn camera_wire_extensions_preserve_empty_legacy_camera_binary() {
        let camera = base::message_proto::ViewCamera::default();
        assert!(camera.write_to_bytes().unwrap().is_empty());
        let camera = base::message_proto::ViewCamera {
            nikodesk_protocol: 1,
            ..Default::default()
        };
        assert_eq!(camera.write_to_bytes().unwrap(), vec![8, 1]);
        let probe = NikoCameraProbe {
            nonce: vec![7; 16].into(),
            protocol: 1,
            ..Default::default()
        };
        assert!(valid_request(&probe));
        let mut message = Message::new();
        message.set_nikodesk_camera_probe(probe);
        let bytes = message.write_to_bytes().unwrap();
        assert_eq!(&bytes[..2], &[0x92, 0x02]);
        assert!(matches!(
            Message::parse_from_bytes(&bytes).unwrap().union,
            Some(message::Union::NikodeskCameraProbe(_))
        ));
    }
    #[test]
    fn camera_ui_and_generic_outgoing_login_cannot_precede_probe() {
        let mut message = Message::new();
        message.set_login_request(base::message_proto::LoginRequest::default());
        assert!(!allows_outgoing_login(true, false, &message));
        assert!(allows_outgoing_login(true, true, &message));
        assert!(allows_outgoing_login(false, false, &message));
        assert!(allows_outgoing_login(true, false, &Message::new()));
    }
    async fn pair() -> (Stream, Stream) {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let client = tokio::net::TcpStream::connect(addr).await.unwrap();
        let (server, remote) = listener.accept().await.unwrap();
        let mut client = Stream::from(client, addr);
        let mut server = Stream::from(server, remote);
        assert!(hbb_common::sodiumoxide::init().is_ok());
        let key = hbb_common::sodiumoxide::crypto::secretbox::Key::from_slice(&[7; 32]).unwrap();
        client.set_key(key.clone());
        server.set_key(key);
        (client, server)
    }
    #[tokio::test]
    async fn camera_probe_real_encrypted_loopback_sends_no_login_or_capture_request() {
        let (mut client, mut server) = pair().await;
        let server = tokio::spawn(async move {
            let bytes = server.next().await.unwrap().unwrap();
            let message = Message::parse_from_bytes(&bytes).unwrap();
            let Some(message::Union::NikodeskCameraProbe(probe)) = message.union else {
                panic!("probe must be the first request")
            };
            let mut reply = Message::new();
            reply.set_nikodesk_camera_probe_reply(NikoCameraProbeReply {
                nonce: probe.nonce,
                protocol: 1,
                requests_allowed: true,
                ..Default::default()
            });
            server.send(&reply).await.unwrap();
            assert!(
                tokio::time::timeout(Duration::from_millis(60), server.next())
                    .await
                    .is_err()
            );
        });
        verify_with_deadline(&mut client, Duration::from_millis(500))
            .await
            .unwrap();
        server.await.unwrap();
    }
    #[tokio::test]
    async fn camera_legacy_ignoring_probe_times_out_without_any_login() {
        let (mut client, mut server) = pair().await;
        let server = tokio::spawn(async move {
            let bytes = server.next().await.unwrap().unwrap();
            assert!(matches!(
                Message::parse_from_bytes(&bytes).unwrap().union,
                Some(message::Union::NikodeskCameraProbe(_))
            ));
            assert!(
                tokio::time::timeout(Duration::from_millis(80), server.next())
                    .await
                    .is_err()
            );
        });
        assert!(verify_with_deadline(&mut client, Duration::from_millis(30))
            .await
            .is_err());
        server.await.unwrap();
    }
}
