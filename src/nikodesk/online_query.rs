//! Each online query keeps its real routing snapshot from admission to reply.
use super::{connection_snapshot::ConnectionSnapshot, server_scope};
use hbb_common::{anyhow::anyhow, bail, config::Config, rendezvous_proto::*, tokio, ResultType};
use std::{collections::BTreeSet, sync::Arc, time::Duration};

const PREFIX: &str = "nikodesk-scope:";
pub(crate) struct Query {
    pub route: Arc<ConnectionSnapshot>,
    ids: Vec<String>,
    requester: String,
}
fn ids_valid(ids: &[String]) -> ResultType<()> {
    if ids.is_empty() || ids.len() > 4096 {
        bail!("online_query_invalid_targets");
    }
    let mut seen = BTreeSet::new();
    for id in ids {
        super::validate_remote_id(id)?;
        if !seen.insert(id) {
            bail!("online_query_duplicate_target");
        }
    }
    Ok(())
}
fn online_target(rendezvous: &str) -> ResultType<String> {
    let (host, port) = rendezvous
        .rsplit_once(':')
        .ok_or_else(|| anyhow!("online_query_invalid_endpoint"))?;
    let port = port
        .parse::<u16>()?
        .checked_sub(1)
        .filter(|p| *p != 0)
        .ok_or_else(|| anyhow!("online_query_invalid_endpoint"))?;
    super::validate_server_address(rendezvous)?;
    Ok(format!("{host}:{port}"))
}
fn states(ids: &[String], bytes: &[u8]) -> ResultType<(Vec<String>, Vec<String>)> {
    if bytes.len() != ids.len().div_ceil(8) {
        bail!("online_query_invalid_response");
    }
    let mut online = vec![];
    let mut offline = vec![];
    for (index, id) in ids.iter().enumerate() {
        if bytes[index / 8] & (1 << (7 - index % 8)) != 0 {
            online.push(id.clone());
        } else {
            offline.push(id.clone());
        }
    }
    Ok((online, offline))
}
impl Query {
    pub fn capture(mut ids: Vec<String>) -> ResultType<Self> {
        let expected = ids
            .first()
            .and_then(|id| id.strip_prefix(PREFIX))
            .map(str::to_owned);
        if expected.is_some() {
            ids.remove(0);
        }
        ids_valid(&ids)?;
        let route = match expected {
            Some(namespace) => ConnectionSnapshot::capture(&namespace)?,
            None => ConnectionSnapshot::capture_current()?,
        };
        Ok(Self {
            route,
            ids,
            requester: Config::get_id(),
        })
    }
    async fn current(&self) -> ResultType<()> {
        let current = tokio::task::spawn_blocking(server_scope::current).await?;
        if current.as_ref().map(server_scope::ServerScope::namespace)
            != Some(self.route.namespace())
        {
            bail!("online_query_private_server_changed");
        }
        Ok(())
    }
    pub async fn run(&self) -> ResultType<(Vec<String>, Vec<String>)> {
        // OSS has a TCP online-query endpoint. Never silently bypass an explicit
        // WebSocket-only transport preference; leave the status unknown.
        if self.route.websocket_enabled() {
            bail!("online_query_transport_unavailable");
        }
        tokio::time::timeout(Duration::from_secs(5), async {
            self.current().await?;
            let target = online_target(self.route.rendezvous())?;
            let mut socket = self.route.connect_direct(target, None, 1500).await?;
            self.current().await?;
            let mut message = RendezvousMessage::new();
            message.set_online_request(OnlineRequest {
                id: self.requester.clone(),
                peers: self.ids.clone(),
                ..Default::default()
            });
            socket.send(&message).await?;
            for _ in 0..2 {
                let response = crate::get_next_nonkeyexchange_msg(&mut socket, Some(1500))
                    .await
                    .ok_or_else(|| anyhow!("online_query_response_unconfirmed"))?;
                if let Some(rendezvous_message::Union::OnlineResponse(response)) = response.union {
                    self.current().await?;
                    return states(&self.ids, &response.states);
                }
            }
            bail!("online_query_response_unconfirmed")
        })
        .await
        .map_err(|_| anyhow!("online_query_deadline"))?
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn online_endpoint_preserves_ipv6_and_explicit_private_ports() {
        assert_eq!(
            online_target("[2001:db8::1]:21116").unwrap(),
            "[2001:db8::1]:21115"
        );
        assert_eq!(
            online_target("lan.example:12000").unwrap(),
            "lan.example:11999"
        );
        assert!(online_target("lan.example:1").is_err());
    }
    #[test]
    fn offline_requires_an_actual_complete_bitmap_reply() {
        let ids = (0..9).map(|i| format!("12345678{i}")).collect::<Vec<_>>();
        assert!(states(&ids, &[]).is_err());
        assert!(states(&ids, &[0xff]).is_err());
        let (online, offline) = states(&ids, &[0x80, 0x80]).unwrap();
        assert_eq!(online, vec![ids[0].clone(), ids[8].clone()]);
        assert_eq!(offline.len(), 7);
    }
}
