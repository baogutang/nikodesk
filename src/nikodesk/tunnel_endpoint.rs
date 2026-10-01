//! Freeze an approved TCP endpoint; never re-resolve a hostname while dialing.
//! This adapter starts no listener and does not enable the product capability.
use super::capability_state::{Capabilities, Scope, Ticket};
use hbb_common::tokio::{self, net::TcpStream, sync::watch};
use std::{
    net::{IpAddr, SocketAddr},
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};

const MAX_ADDRESSES: usize = 8;
const CONNECT_BUDGET: Duration = Duration::from_secs(3);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Error {
    InvalidTarget,
    InvalidResolution,
    TooManyAddresses,
    OutsideLocalPolicy,
    NotApproved,
    Cancelled,
    TimedOut,
    ResolveFailed,
    ConnectFailed,
    StateUnavailable,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Target {
    host: String,
    port: u16,
}

impl Target {
    pub(crate) fn host(&self) -> &str {
        &self.host
    }

    pub(crate) fn port(&self) -> u16 {
        self.port
    }

    pub(crate) fn label(&self) -> String {
        match self.host.parse::<IpAddr>() {
            Ok(ip) => SocketAddr::new(ip, self.port).to_string(),
            Err(_) => format!("{}:{}", self.host, self.port),
        }
    }

    pub(crate) fn parse(host: &str, port: i32) -> Result<Self, Error> {
        if !(1..=65535).contains(&port)
            || host.is_empty()
            || host.len() > 253
            || !host.is_ascii()
            || host.chars().any(char::is_whitespace)
        {
            return Err(Error::InvalidTarget);
        }
        let unbracketed = match host.strip_prefix('[') {
            Some(value) => value.strip_suffix(']').ok_or(Error::InvalidTarget)?,
            None => host,
        };
        let normalized = if let Ok(ip) = unbracketed.parse::<IpAddr>() {
            if !valid_ip(ip) {
                return Err(Error::InvalidTarget);
            }
            normalize_ip(ip).to_string()
        } else {
            // A host field accepts a DNS name, never an URL, port or command.
            let name = host.strip_suffix('.').unwrap_or(host).to_ascii_lowercase();
            if name.is_empty()
                || name.split('.').any(|label| {
                    label.is_empty()
                        || label.len() > 63
                        || label.starts_with('-')
                        || label.ends_with('-')
                        || !label
                            .bytes()
                            .all(|c| c.is_ascii_alphanumeric() || c == b'-')
                })
            {
                return Err(Error::InvalidTarget);
            }
            name
        };
        Ok(Self {
            host: normalized,
            port: port as u16,
        })
    }

    pub(crate) async fn resolve(&self) -> Result<Resolution, Error> {
        if let Ok(ip) = self.host.parse::<IpAddr>() {
            return Resolution::checked(self.clone(), vec![SocketAddr::new(ip, self.port)]);
        }
        let addresses = tokio::time::timeout(
            CONNECT_BUDGET,
            tokio::net::lookup_host((self.host.as_str(), self.port)),
        )
        .await
        .map_err(|_| Error::TimedOut)?
        .map_err(|_| Error::ResolveFailed)?;
        Resolution::checked(self.clone(), addresses.take(MAX_ADDRESSES + 1).collect())
    }
}

fn normalize_ip(ip: IpAddr) -> IpAddr {
    match ip {
        IpAddr::V6(ip) => ip.to_ipv4_mapped().map_or(IpAddr::V6(ip), IpAddr::V4),
        other => other,
    }
}

fn valid_ip(ip: IpAddr) -> bool {
    let ip = normalize_ip(ip);
    !ip.is_unspecified() && !ip.is_multicast() && ip != std::net::Ipv4Addr::BROADCAST
}

#[derive(Clone, Debug)]
pub(crate) struct Resolution {
    target: Target,
    addresses: Vec<SocketAddr>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum LocalPolicy {
    LoopbackOnly,
    // Must be supplied by an explicit local policy, never a remote request.
    ExactAddress(SocketAddr),
}

impl Resolution {
    fn checked(target: Target, addresses: Vec<SocketAddr>) -> Result<Self, Error> {
        if addresses.is_empty() {
            return Err(Error::InvalidResolution);
        }
        if addresses.len() > MAX_ADDRESSES {
            return Err(Error::TooManyAddresses);
        }
        let mut normalized = Vec::new();
        for address in addresses {
            if address.port() != target.port || !valid_ip(address.ip()) {
                return Err(Error::InvalidResolution);
            }
            // Scoped IPv6 interfaces require a separate explicit UI/contract.
            if let SocketAddr::V6(v6) = address {
                if v6.scope_id() != 0 || v6.flowinfo() != 0 {
                    return Err(Error::InvalidResolution);
                }
            }
            normalized.push(SocketAddr::new(normalize_ip(address.ip()), address.port()));
        }
        normalized.sort_unstable();
        normalized.dedup();
        Ok(Self {
            target,
            addresses: normalized,
        })
    }

    pub(crate) fn addresses(&self) -> &[SocketAddr] {
        &self.addresses
    }

    /// The exact selected address is displayed/approved locally before request.
    pub(crate) fn select(&self, selected: SocketAddr, policy: LocalPolicy) -> Result<Scope, Error> {
        if !self.addresses.contains(&selected) {
            return Err(Error::InvalidResolution);
        }
        let permitted = match policy {
            LocalPolicy::LoopbackOnly => selected.ip().is_loopback(),
            LocalPolicy::ExactAddress(expected) => expected == selected,
        };
        if !permitted {
            return Err(Error::OutsideLocalPolicy);
        }
        Ok(Scope::Tunnel(selected))
    }

    pub(crate) fn for_ticket(&self, ticket: &Ticket) -> Result<PinnedEndpoint, Error> {
        match ticket.scope() {
            Scope::Tunnel(address) if self.addresses.contains(address) => Ok(PinnedEndpoint {
                target: self.target.clone(),
                address: *address,
            }),
            _ => Err(Error::NotApproved),
        }
    }
}

#[derive(Clone, Debug)]
pub(crate) struct PinnedEndpoint {
    target: Target,
    address: SocketAddr,
}

impl PinnedEndpoint {
    pub(crate) fn address(&self) -> SocketAddr {
        self.address
    }
    pub(crate) fn target(&self) -> &Target {
        &self.target
    }

    /// Cancellation wins a simultaneous completion. All state locks are short
    /// and synchronous; the owning connection must retain/drop the returned FD.
    pub(crate) async fn connect(
        &self,
        state: &Arc<Mutex<Capabilities>>,
        ticket: &Ticket,
        cancel: watch::Receiver<bool>,
    ) -> Result<TcpStream, Error> {
        self.connect_using(state, ticket, cancel, TcpStream::connect(self.address))
            .await
    }

    async fn connect_using(
        &self,
        state: &Arc<Mutex<Capabilities>>,
        ticket: &Ticket,
        mut cancel: watch::Receiver<bool>,
        connect: impl std::future::Future<Output = std::io::Result<TcpStream>>,
    ) -> Result<TcpStream, Error> {
        let scope = Scope::Tunnel(self.address);
        let approved = |state: &Capabilities| {
            ticket.scope() == &scope
                && (state.may_start(ticket, Instant::now())
                    || state.may_execute(ticket, &scope, Instant::now()))
        };
        if *cancel.borrow() || cancel.has_changed().is_err() {
            return Err(Error::Cancelled);
        }
        {
            let current = state.lock().map_err(|_| Error::StateUnavailable)?;
            if !approved(&current) {
                return Err(Error::NotApproved);
            }
        }
        // SocketAddr prevents a second DNS lookup and RDP sentinel dispatch.
        let socket = tokio::select! {
            biased;
            _ = cancel.changed() => return Err(Error::Cancelled),
            result = tokio::time::timeout(CONNECT_BUDGET, connect) =>
                result.map_err(|_| Error::TimedOut)?.map_err(|_| Error::ConnectFailed)?,
        };
        if *cancel.borrow() || cancel.has_changed().is_err() {
            return Err(Error::Cancelled);
        }
        let mut current = state.lock().map_err(|_| Error::StateUnavailable)?;
        if !approved(&current) {
            return Err(Error::NotApproved);
        }
        if current.may_start(ticket, Instant::now()) {
            current
                .did_start(ticket, Instant::now())
                .map_err(|_| Error::NotApproved)?;
        }
        Ok(socket)
    }
}

#[cfg(test)]
mod tests {
    use super::super::capability_state::{Binding, Kind, Phase};
    use super::*;
    use hbb_common::tokio::{io::AsyncReadExt, net::TcpListener};

    fn approved(address: SocketAddr) -> (Arc<Mutex<Capabilities>>, Ticket) {
        let mut state = Capabilities::new(
            Binding::new("a".repeat(64), "123456789".into(), [1; 16]).unwrap(),
            true,
            true,
        );
        state.set_policy(Kind::Tunnel, true, true).unwrap();
        let now = Instant::now();
        let request = state.request(Scope::Tunnel(address), [2; 16], now).unwrap();
        let ticket = state
            .approve(&request, now, Duration::from_secs(60))
            .unwrap();
        (Arc::new(Mutex::new(state)), ticket)
    }

    #[test]
    fn rejects_urls_commands_rdp_and_invalid_endpoints() {
        for host in [
            "",
            "host:3000",
            "http://localhost",
            "name@host",
            " x",
            "x ",
            "a/b",
            "a\\b",
            "a\0b",
            "-bad",
            "bad-",
            "a..b",
            "[localhost]",
            "0.0.0.0",
            "::",
            "224.0.0.1",
            "255.255.255.255",
            "::ffff:0.0.0.0",
        ] {
            assert_eq!(Target::parse(host, 3000), Err(Error::InvalidTarget));
        }
        for port in [-1, 0, 65536] {
            assert_eq!(Target::parse("localhost", port), Err(Error::InvalidTarget));
        }
        assert_eq!(Target::parse("LOCALHOST.", 3000).unwrap().host, "localhost");
        assert_eq!(Target::parse("[::1]", 3000).unwrap().host, "::1");
    }

    #[test]
    fn resolution_is_bounded_and_default_policy_cannot_allow_remote() {
        let target = Target::parse("example.test", 3000).unwrap();
        let remote = "192.0.2.1:3000".parse().unwrap();
        let snapshot = Resolution::checked(target.clone(), vec![remote]).unwrap();
        assert_eq!(
            snapshot.select(remote, LocalPolicy::LoopbackOnly),
            Err(Error::OutsideLocalPolicy)
        );
        assert_eq!(
            snapshot.select(remote, LocalPolicy::ExactAddress(remote)),
            Ok(Scope::Tunnel(remote))
        );
        assert_eq!(
            snapshot.select(
                "192.0.2.2:3000".parse().unwrap(),
                LocalPolicy::ExactAddress(remote)
            ),
            Err(Error::InvalidResolution)
        );
        assert!(matches!(
            Resolution::checked(target.clone(), vec![remote; 9]),
            Err(Error::TooManyAddresses)
        ));
        assert!(matches!(
            Resolution::checked(target, vec!["192.0.2.1:3001".parse().unwrap()]),
            Err(Error::InvalidResolution)
        ));
    }

    #[test]
    fn mapped_ipv4_is_normalized_before_local_policy_check() {
        let target = Target::parse("localhost", 3000).unwrap();
        let resolution =
            Resolution::checked(target, vec!["[::ffff:127.0.0.1]:3000".parse().unwrap()]).unwrap();
        let address = "127.0.0.1:3000".parse().unwrap();
        assert_eq!(resolution.addresses(), &[address]);
        assert_eq!(
            resolution.select(address, LocalPolicy::LoopbackOnly),
            Ok(Scope::Tunnel(address))
        );
    }

    #[test]
    fn a_changed_dns_snapshot_cannot_retarget_an_existing_ticket() {
        let address = "127.0.0.1:3000".parse().unwrap();
        let (_, ticket) = approved(address);
        let target = Target::parse("example.test", 3000).unwrap();
        let old = Resolution::checked(target.clone(), vec![address]).unwrap();
        let pinned = old.for_ticket(&ticket).unwrap();
        assert_eq!(pinned.address(), address);
        assert_eq!(pinned.target().host, "example.test");
        let new = Resolution::checked(target, vec!["192.0.2.1:3000".parse().unwrap()]).unwrap();
        assert!(matches!(new.for_ticket(&ticket), Err(Error::NotApproved)));
        assert_eq!(pinned.address(), address);
    }

    #[tokio::test]
    async fn real_loopback_connect_is_confirmed_and_owned_socket_drop_closes_it() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let resolution = Target::parse("127.0.0.1", i32::from(address.port()))
            .unwrap()
            .resolve()
            .await
            .unwrap();
        let (state, ticket) = approved(address);
        let endpoint = resolution.for_ticket(&ticket).unwrap();
        let (_cancel_tx, cancel) = watch::channel(false);
        let socket = endpoint.connect(&state, &ticket, cancel).await.unwrap();
        assert_eq!(socket.peer_addr().unwrap(), address);
        assert_eq!(state.lock().unwrap().phase(Kind::Tunnel), Phase::Running);
        let (mut peer, _) = listener.accept().await.unwrap();
        drop(socket);
        assert_eq!(
            tokio::time::timeout(Duration::from_secs(1), peer.read(&mut [0; 1]))
                .await
                .unwrap()
                .unwrap(),
            0
        );
    }

    #[tokio::test]
    async fn prior_cancel_or_revoke_prevents_any_dial() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let snapshot = Target::parse("127.0.0.1", i32::from(address.port()))
            .unwrap()
            .resolve()
            .await
            .unwrap();
        let (state, ticket) = approved(address);
        let endpoint = snapshot.for_ticket(&ticket).unwrap();
        let (_cancel_tx, cancel) = watch::channel(true);
        assert!(matches!(
            endpoint.connect(&state, &ticket, cancel).await,
            Err(Error::Cancelled)
        ));
        state.lock().unwrap().revoke(Kind::Tunnel).unwrap();
        let (_cancel_tx, cancel) = watch::channel(false);
        assert!(matches!(
            endpoint.connect(&state, &ticket, cancel).await,
            Err(Error::NotApproved)
        ));
        assert!(
            tokio::time::timeout(Duration::from_millis(30), listener.accept())
                .await
                .is_err()
        );
    }

    #[tokio::test]
    async fn late_real_socket_is_disposed_if_grant_was_revoked() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let snapshot = Target::parse("127.0.0.1", i32::from(address.port()))
            .unwrap()
            .resolve()
            .await
            .unwrap();
        let (state, ticket) = approved(address);
        let endpoint = snapshot.for_ticket(&ticket).unwrap();
        let (_cancel_tx, cancel) = watch::channel(false);
        let changed = state.clone();
        let connect = async move {
            let socket = TcpStream::connect(address).await?;
            changed.lock().unwrap().revoke(Kind::Tunnel).unwrap();
            Ok(socket)
        };
        assert!(matches!(
            endpoint
                .connect_using(&state, &ticket, cancel, connect)
                .await,
            Err(Error::NotApproved)
        ));
        assert_eq!(state.lock().unwrap().phase(Kind::Tunnel), Phase::Revoking);
        let (mut peer, _) = listener.accept().await.unwrap();
        assert_eq!(
            tokio::time::timeout(Duration::from_secs(1), peer.read(&mut [0; 1]))
                .await
                .unwrap()
                .unwrap(),
            0
        );
    }

    #[tokio::test]
    async fn late_real_socket_is_disposed_on_cancel_without_running_ack() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let snapshot = Target::parse("127.0.0.1", i32::from(address.port()))
            .unwrap()
            .resolve()
            .await
            .unwrap();
        let (state, ticket) = approved(address);
        let endpoint = snapshot.for_ticket(&ticket).unwrap();
        let (cancel_tx, cancel) = watch::channel(false);
        let connect = async move {
            let socket = TcpStream::connect(address).await?;
            cancel_tx.send_replace(true);
            Ok(socket)
        };
        assert!(matches!(
            endpoint
                .connect_using(&state, &ticket, cancel, connect)
                .await,
            Err(Error::Cancelled)
        ));
        assert_eq!(state.lock().unwrap().phase(Kind::Tunnel), Phase::Starting);
        let (mut peer, _) = listener.accept().await.unwrap();
        assert_eq!(
            tokio::time::timeout(Duration::from_secs(1), peer.read(&mut [0; 1]))
                .await
                .unwrap()
                .unwrap(),
            0
        );
    }

    #[tokio::test]
    async fn a_closed_cancel_owner_denies_dial() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let snapshot = Target::parse("127.0.0.1", i32::from(address.port()))
            .unwrap()
            .resolve()
            .await
            .unwrap();
        let (state, ticket) = approved(address);
        let endpoint = snapshot.for_ticket(&ticket).unwrap();
        let (cancel_tx, cancel) = watch::channel(false);
        drop(cancel_tx);
        assert!(matches!(
            endpoint.connect(&state, &ticket, cancel).await,
            Err(Error::Cancelled)
        ));
        assert!(
            tokio::time::timeout(Duration::from_millis(30), listener.accept())
                .await
                .is_err()
        );
    }
}
