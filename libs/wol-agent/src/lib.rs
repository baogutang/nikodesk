use serde::{Deserialize, Serialize};
use std::{
    io::{self, Read, Write},
    net::{Ipv4Addr, SocketAddr, TcpStream, UdpSocket},
    thread,
    time::{Duration, Instant},
};

#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Target {
    pub mac: String,
    pub broadcast: Ipv4Addr,
    pub port: u16,
}
#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Config {
    pub schema: u32,
    pub listen: SocketAddr,
    pub targets: Vec<Target>,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Request {
    schema: u32,
    request_id: String,
    mac: String,
    broadcast: Ipv4Addr,
    port: u16,
    #[serde(default)]
    namespace: Option<String>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct HealthRequest {
    schema: u32,
    request_id: String,
    command: String,
    namespace: String,
}

/// The integrated receiver binds every request to its verified private server.
/// The standalone receiver keeps its existing local configuration contract.
pub struct Scope<'a> {
    pub namespace: &'a str,
    pub revision: &'a str,
}

fn request_id_valid(value: &str) -> bool {
    value.len() == 32 && value.bytes().all(|b| b.is_ascii_hexdigit())
}

fn read_request(stream: &mut TcpStream) -> io::Result<Vec<u8>> {
    // A trickling client must not extend the deadline by sending one byte
    // before each individual socket timeout.
    let deadline = Instant::now() + Duration::from_secs(3);
    let mut bytes = Vec::new();
    loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Err(io::Error::new(
                io::ErrorKind::TimedOut,
                "Wake request expired",
            ));
        }
        stream.set_read_timeout(Some(remaining))?;
        let mut byte = [0];
        if stream.read(&mut byte)? != 1 {
            return Err(invalid("Incomplete wake request"));
        }
        bytes.push(byte[0]);
        if bytes.len() > 1024 {
            return Err(invalid("Invalid wake request length"));
        }
        if byte[0] == b'\n' {
            return Ok(bytes);
        }
    }
}

fn invalid(message: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidInput, message)
}

pub fn mac(text: &str) -> io::Result<[u8; 6]> {
    let normalized = text.replace('-', ":");
    let parts: Vec<_> = normalized.split(':').collect();
    if parts.len() != 6 || parts.iter().any(|p| p.len() != 2) {
        return Err(invalid("Invalid MAC"));
    }
    let mut bytes = [0; 6];
    for (at, part) in parts.iter().enumerate() {
        bytes[at] = u8::from_str_radix(part, 16).map_err(|_| invalid("Invalid MAC"))?;
    }
    if bytes == [0; 6] || bytes[0] & 1 != 0 {
        return Err(invalid("MAC must identify a unicast NIC"));
    }
    Ok(bytes)
}
pub fn packet(mac: [u8; 6]) -> [u8; 102] {
    let mut packet = [255; 102];
    for chunk in packet[6..].chunks_mut(6) {
        chunk.copy_from_slice(&mac);
    }
    packet
}
impl Config {
    pub fn validate(&self) -> io::Result<()> {
        if self.schema != 1
            || !self.listen.ip().is_loopback()
            || !self.listen.is_ipv4()
            || self.listen.port() == 0
            || self.targets.is_empty()
            || self.targets.len() > 256
        {
            return Err(invalid("Use a loopback listener and explicit wake targets"));
        }
        for target in &self.targets {
            mac(&target.mac)?;
            if target.port == 0
                || !(target.broadcast.is_private()
                    || target.broadcast.is_loopback()
                    || target.broadcast.is_link_local()
                    || target.broadcast == Ipv4Addr::BROADCAST)
            {
                return Err(invalid("Wake targets must be local-network destinations"));
            }
        }
        Ok(())
    }
}

pub fn handle(stream: &mut TcpStream, config: &Config) -> io::Result<()> {
    handle_guarded(stream, config, None, || true)
}

/// Rechecks local policy before each packet and before acknowledging it.
/// Already transmitted packets cannot be recalled after a policy change.
pub fn handle_guarded(
    stream: &mut TcpStream,
    config: &Config,
    scope: Option<Scope<'_>>,
    allowed_now: impl Fn() -> bool,
) -> io::Result<()> {
    config.validate()?;
    stream.set_write_timeout(Some(Duration::from_secs(1)))?;
    let bytes = read_request(stream)?;
    if let Some(scope) = scope.as_ref() {
        if let Ok(health) = serde_json::from_slice::<HealthRequest>(&bytes) {
            if health.schema != 1
                || !request_id_valid(&health.request_id)
                || health.command != "health"
                || health.namespace != scope.namespace
                || !allowed_now()
            {
                return Err(invalid("Wake proxy is unavailable"));
            }
            return writeln!(
                stream,
                "{}",
                serde_json::json!({"schema":1,
                "request_id":health.request_id,"command":"health",
                "namespace":scope.namespace,"revision":scope.revision,"ready":true})
            );
        }
    }
    let request: Request =
        serde_json::from_slice(&bytes).map_err(|_| invalid("Invalid wake request"))?;
    if request.schema != 1
        || !request_id_valid(&request.request_id)
        || scope.as_ref().map_or(false, |scope| {
            request.namespace.as_deref() != Some(scope.namespace)
        })
    {
        return Err(invalid("Invalid wake request identity"));
    }
    let wanted = mac(&request.mac)?;
    let approved = config.targets.iter().any(|t| {
        mac(&t.mac).ok() == Some(wanted)
            && t.broadcast == request.broadcast
            && t.port == request.port
    });
    if !approved || !allowed_now() {
        writeln!(
            stream,
            "{}",
            serde_json::json!({"schema":1,"request_id":request.request_id,"sent":false,"packets":0})
        )?;
        return Ok(());
    }
    let socket = UdpSocket::bind((Ipv4Addr::UNSPECIFIED, 0))?;
    socket.set_broadcast(true)?;
    socket.set_write_timeout(Some(Duration::from_secs(1)))?;
    let packet = packet(wanted);
    let mut sent = 0;
    for at in 0..3 {
        if !allowed_now() {
            break;
        }
        if socket.send_to(&packet, (request.broadcast, request.port))? != packet.len() {
            return Err(io::Error::new(
                io::ErrorKind::WriteZero,
                "Wake packet not sent",
            ));
        }
        sent += 1;
        if at != 2 {
            thread::sleep(Duration::from_millis(100));
        }
    }
    let confirmed = sent == 3 && allowed_now();
    writeln!(
        stream,
        "{}",
        serde_json::json!({"schema":1,"request_id":request.request_id,"sent":confirmed,"packets":sent})
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        io::{BufRead, BufReader},
        net::TcpListener,
    };
    #[test]
    fn actual_tcp_request_sends_exact_magic_packet_to_approved_loopback_udp_target() {
        let udp = UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
        udp.set_read_timeout(Some(Duration::from_secs(3))).unwrap();
        let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
        let port = udp.local_addr().unwrap().port();
        let address = listener.local_addr().unwrap();
        let config = Config {
            schema: 1,
            listen: address,
            targets: vec![Target {
                mac: "02:11:22:33:44:55".into(),
                broadcast: Ipv4Addr::LOCALHOST,
                port,
            }],
        };
        let join =
            thread::spawn(move || handle(&mut listener.accept().unwrap().0, &config).unwrap());
        let mut client = TcpStream::connect(address).unwrap();
        writeln!(client, "{}", serde_json::json!({"schema":1,"request_id":"a".repeat(32),"mac":"02:11:22:33:44:55","broadcast":"127.0.0.1","port":port})).unwrap();
        let mut output = [0; 1024];
        for _ in 0..3 {
            let size = udp.recv(&mut output).unwrap();
            assert_eq!(size, 102);
            assert_eq!(&output[..size], &packet([2, 17, 34, 51, 68, 85]));
        }
        let mut reply = String::new();
        BufReader::new(client).read_line(&mut reply).unwrap();
        assert_eq!(
            serde_json::from_str::<serde_json::Value>(&reply).unwrap()["sent"],
            true
        );
        join.join().unwrap();
    }
    #[test]
    fn unsupported_addresses_and_multicast_or_missing_mac_are_refused() {
        for value in [
            "00:00:00:00:00:00",
            "FF:FF:FF:FF:FF:FF",
            "01:11:22:33:44:55",
            "02:11:22",
        ] {
            assert!(mac(value).is_err());
        }
        let config = Config {
            schema: 1,
            listen: "0.0.0.0:21128".parse().unwrap(),
            targets: vec![Target {
                mac: "02:11:22:33:44:55".into(),
                broadcast: Ipv4Addr::LOCALHOST,
                port: 9,
            }],
        };
        assert!(config.validate().is_err());
    }

    #[test]
    fn revocation_between_packets_stops_the_remaining_udp_sends() {
        use std::sync::atomic::{AtomicUsize, Ordering};
        let udp = UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
        udp.set_read_timeout(Some(Duration::from_millis(500)))
            .unwrap();
        let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
        let address = listener.local_addr().unwrap();
        let port = udp.local_addr().unwrap().port();
        let config = Config {
            schema: 1,
            listen: address,
            targets: vec![Target {
                mac: "02:11:22:33:44:55".into(),
                broadcast: Ipv4Addr::LOCALHOST,
                port,
            }],
        };
        let join = thread::spawn(move || {
            let calls = AtomicUsize::new(0);
            handle_guarded(
                &mut listener.accept().unwrap().0,
                &config,
                Some(Scope {
                    namespace: &"a".repeat(64),
                    revision: &"b".repeat(64),
                }),
                || calls.fetch_add(1, Ordering::SeqCst) < 2,
            )
            .unwrap();
        });
        let mut client = TcpStream::connect(address).unwrap();
        writeln!(client, "{}", serde_json::json!({"schema":1,"request_id":"c".repeat(32),
            "namespace":"a".repeat(64),"mac":"02:11:22:33:44:55","broadcast":"127.0.0.1","port":port})).unwrap();
        let mut output = [0; 128];
        assert_eq!(udp.recv(&mut output).unwrap(), 102);
        assert!(udp.recv(&mut output).is_err());
        let mut reply = String::new();
        BufReader::new(client).read_line(&mut reply).unwrap();
        let reply: serde_json::Value = serde_json::from_str(&reply).unwrap();
        assert_eq!(reply["sent"], false);
        assert_eq!(reply["packets"], 1);
        join.join().unwrap();
    }

    #[test]
    fn health_requires_current_scope_and_does_not_send_a_wake_packet() {
        let udp = UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
        udp.set_read_timeout(Some(Duration::from_millis(100)))
            .unwrap();
        let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
        let address = listener.local_addr().unwrap();
        let config = Config {
            schema: 1,
            listen: address,
            targets: vec![Target {
                mac: "02:11:22:33:44:55".into(),
                broadcast: Ipv4Addr::LOCALHOST,
                port: udp.local_addr().unwrap().port(),
            }],
        };
        let join = thread::spawn(move || {
            for _ in 0..2 {
                let result = handle_guarded(
                    &mut listener.accept().unwrap().0,
                    &config,
                    Some(Scope {
                        namespace: &"a".repeat(64),
                        revision: &"b".repeat(64),
                    }),
                    || true,
                );
                if result.is_ok() {
                    continue;
                }
                assert_eq!(result.unwrap_err().kind(), io::ErrorKind::InvalidInput);
            }
        });
        for namespace in ["a".repeat(64), "d".repeat(64)] {
            let mut client = TcpStream::connect(address).unwrap();
            writeln!(
                client,
                "{}",
                serde_json::json!({"schema":1,"command":"health",
                "request_id":"c".repeat(32),"namespace":namespace})
            )
            .unwrap();
            let mut reply = String::new();
            BufReader::new(client).read_line(&mut reply).unwrap();
            if namespace.starts_with('a') {
                let reply: serde_json::Value = serde_json::from_str(&reply).unwrap();
                assert_eq!(reply["ready"], true);
                assert_eq!(reply["namespace"], namespace);
                assert_eq!(reply["revision"], "b".repeat(64));
            } else {
                assert!(reply.is_empty());
            }
        }
        assert!(udp.recv(&mut [0; 128]).is_err());
        join.join().unwrap();
    }
}
