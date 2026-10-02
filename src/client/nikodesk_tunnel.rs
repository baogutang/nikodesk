//! Controller of one original encrypted, probed tunnel stream. No raw fallback.
use super::{Client, Data, Interface, LoginConfigHandler, REQUIRE_2FA};
use crate::{
    nikodesk::{
        server_scope::PeerStorageKey,
        tunnel_endpoint::Target,
        tunnel_wire::{
            self as wire, Binding, CallerFacts, ControlOp, Direction, ProbeFacts, ReadOnlyStatus,
            ReadPhase, StatusFence,
        },
    },
    port_forward_mux::{self as mux, FrameSink, Inbound, RecvWindow, SendCredit},
};
use base::message_proto::{
    login_response, message, misc, port_forward_channel, Features, Hash, LoginRequest, Message,
    NikoTunnelStatus, PortForward, PortForwardChannel,
};
use hbb_common::{
    anyhow::anyhow,
    bail,
    protobuf::Message as _,
    rand::{rngs::OsRng, RngCore},
    rendezvous_proto::ConnType,
    tokio::{
        self,
        net::{TcpListener, TcpStream},
        sync::{mpsc, watch},
        task::JoinHandle,
        time::{interval, timeout, Instant},
    },
    ResultType, Stream,
};
use std::{
    collections::HashMap,
    sync::{
        atomic::{AtomicU64, Ordering},
        Arc, Mutex, OnceLock, RwLock,
    },
    time::{Duration, Instant as Clock},
};

const MAX_MAPPINGS: usize = 16;
const MAX_CHANNELS: usize = 16;
const OUTBOUND_FRAMES: usize = 64;
const STATUS_AGE: Duration = Duration::from_secs(2);
const QUERY_INTERVAL: Duration = Duration::from_secs(1);
const OPEN_BUDGET: Duration = Duration::from_secs(5);
const SEND_BUDGET: Duration = Duration::from_millis(500);
const AUTH_IDLE: Duration = Duration::from_secs(120);
static WIRE_EPOCH: AtomicU64 = AtomicU64::new(1);

#[path = "nikodesk_tunnel_ui.rs"]
pub(crate) mod ui;

type UiLogin = (String, String, String, bool);

/// Installed only while the original Interface builds a login on this stream.
/// Password/TOTP retries keep this exact proof, target and wire binding.
pub(crate) struct LoginState {
    port_forward: PortForward,
    my_id: OnceLock<String>,
}
impl LoginState {
    fn new(port_forward: PortForward) -> ResultType<Arc<Self>> {
        wire::parse_login(&port_forward).map_err(|e| anyhow!(e.code()))?;
        Ok(Arc::new(Self {
            port_forward,
            my_id: OnceLock::new(),
        }))
    }
    pub(super) fn decorate(&self, login: &mut LoginRequest) -> bool {
        if crate::nikodesk::validate_remote_id(&login.my_id).is_err() {
            return false;
        }
        let original = self.my_id.get_or_init(|| login.my_id.clone());
        if original != &login.my_id {
            return false;
        }
        login.nikodesk_features = Some(wire::features(false)).into();
        login.set_port_forward(self.port_forward.clone());
        true
    }
    fn my_id(&self) -> ResultType<&str> {
        self.my_id
            .get()
            .map(String::as_str)
            .ok_or_else(|| anyhow!("tunnel_typed_login_required"))
    }
}

fn nonce() -> ResultType<[u8; 16]> {
    let mut value = [0; 16];
    OsRng
        .try_fill_bytes(&mut value)
        .map_err(|_| anyhow!("tunnel_nonce_unavailable"))?;
    if value == [0; 16] {
        bail!("tunnel_nonce_unavailable");
    }
    Ok(value)
}
fn fresh_binding() -> ResultType<Binding> {
    let epoch = WIRE_EPOCH
        .fetch_update(Ordering::AcqRel, Ordering::Acquire, |n| {
            n.checked_add(1).filter(|next| *next <= i64::MAX as u64)
        })
        .map_err(|_| anyhow!("tunnel_wire_epoch_exhausted"))?;
    Binding::new(nonce()?, epoch).map_err(|e| anyhow!(e.code()).into())
}
async fn scope_current(key: &PeerStorageKey) -> bool {
    let key = key.clone();
    timeout(
        SEND_BUDGET,
        tokio::task::spawn_blocking(move || {
            if crate::nikodesk::background::is_system_worker() {
                return false;
            }
            #[cfg(unix)]
            if unsafe { hbb_common::libc::geteuid() } == 0 {
                return false;
            }
            #[cfg(target_os = "windows")]
            if crate::nikodesk::connection_capabilities::normal_user().is_err() {
                return false;
            }
            key.is_current()
        }),
    )
    .await
    .map_or(false, |r| r.unwrap_or(false))
}
async fn send(stream: &mut Stream, message: &Message) -> ResultType<()> {
    timeout(SEND_BUDGET, stream.send(message))
        .await
        .map_err(|_| anyhow!("tunnel_send_timeout"))?
        .map_err(|_| anyhow!("tunnel_stream_closed").into())
}
fn decode(bytes: &[u8]) -> ResultType<Message> {
    if bytes.len() > mux::MAX_PACKET {
        bail!("tunnel_packet_limit");
    }
    Message::parse_from_bytes(bytes).map_err(|_| anyhow!("tunnel_invalid_message").into())
}

struct LoginTurn {
    lc: Arc<RwLock<LoginConfigHandler>>,
    state: Arc<LoginState>,
}
impl LoginTurn {
    fn install(lc: Arc<RwLock<LoginConfigHandler>>, state: Arc<LoginState>, hash: Hash) -> Self {
        {
            let mut handler = lc.write().unwrap();
            handler.nikodesk_tunnel_login = Some(state.clone());
            handler.set_hash(hash);
        }
        Self { lc, state }
    }
}
impl Drop for LoginTurn {
    fn drop(&mut self) {
        let mut lc = self.lc.write().unwrap();
        if lc
            .nikodesk_tunnel_login
            .as_ref()
            .map_or(false, |s| Arc::ptr_eq(s, &self.state))
        {
            lc.nikodesk_tunnel_login = None;
        }
    }
}
async fn login(
    interface: impl Interface,
    state: &Arc<LoginState>,
    password: &str,
    hash: Hash,
    from_ui: Option<UiLogin>,
    stream: &mut Stream,
) -> bool {
    let lc = interface.get_lch();
    let turn = lc.read().unwrap().port_forward_login_turn.clone();
    let _lock = turn.lock().await;
    let _installed = LoginTurn::install(lc, state.clone(), hash.clone());
    match from_ui {
        Some((user, os_password, password, remember)) => {
            interface
                .handle_login_from_ui(user, os_password, password, remember, stream)
                .await;
            true
        }
        None => interface.handle_hash(password, hash, stream).await,
    }
}

async fn probe(
    stream: &mut Stream,
    ui: &mut mpsc::UnboundedReceiver<Data>,
    key: &PeerStorageKey,
    target: &Target,
    binding: Binding,
) -> ResultType<(Arc<LoginState>, Option<Hash>, Option<UiLogin>)> {
    if !stream.is_secured() || !scope_current(key).await {
        bail!("tunnel_private_stream_required");
    }
    let facts = ProbeFacts {
        encrypted: stream.is_secured(),
        private_stream_bound: true,
        before_login: true,
        stream_nonce: nonce()?,
    };
    let result = probe_stream(stream, ui, target, binding, facts).await?;
    if !scope_current(key).await {
        bail!("tunnel_namespace_changed");
    }
    Ok(result)
}
async fn probe_stream(
    stream: &mut Stream,
    ui: &mut mpsc::UnboundedReceiver<Data>,
    target: &Target,
    binding: Binding,
    facts: ProbeFacts,
) -> ResultType<(Arc<LoginState>, Option<Hash>, Option<UiLogin>)> {
    let started = Clock::now();
    let mut fence =
        wire::ProbeFence::new(nonce()?, facts, started).map_err(|e| anyhow!(e.code()))?;
    let mut request = Message::new();
    request.set_nikodesk_tunnel_probe(
        fence
            .request(facts, Clock::now())
            .map_err(|e| anyhow!(e.code()))?,
    );
    send(stream, &request).await?;
    let mut hash = None;
    let mut pending_login = None;
    let deadline = tokio::time::sleep(wire::PROBE_BUDGET);
    tokio::pin!(deadline);
    loop {
        tokio::select! {
            _ = &mut deadline => bail!("tunnel_protocol_probe_expired"),
            data = ui.recv() => match data {
                None | Some(Data::Close) | Some(Data::RejectInsecureConnection) => bail!("tunnel_cancelled"),
                Some(Data::Login(value)) => pending_login = Some(value),
                _ => {},
            },
            bytes = stream.next() => {
                let bytes = bytes.ok_or_else(|| anyhow!("tunnel_stream_closed"))?
                    .map_err(|_| anyhow!("tunnel_stream_closed"))?;
                if bytes.is_empty() { continue; }
                match decode(&bytes)?.union {
                    Some(message::Union::Hash(value)) if hash.is_none() => hash = Some(value),
                    Some(message::Union::NikodeskTunnelProbeReply(reply)) => {
                        let receipt = fence.accept(&reply, facts, Clock::now()).map_err(|e| anyhow!(e.code()))?;
                        let typed = wire::typed_login(target, binding, receipt, &wire::features(false), facts, Clock::now())
                            .map_err(|e| anyhow!(e.code()))?;
                        return Ok((LoginState::new(typed)?, hash, pending_login));
                    }
                    // The controlled side announces disabled permissions and starts
                    // measuring delay as soon as the stream opens. Skipping them does
                    // not let anything stand in for the receipt.
                    Some(message::Union::Misc(misc))
                        if matches!(misc.union, Some(misc::Union::PermissionInfo(_))) => {}
                    Some(message::Union::TestDelay(_)) => {}
                    // No login, raw frame, or legacy capability can substitute for this receipt.
                    _ => bail!("tunnel_protocol_probe_invalid"),
                }
            }
        }
    }
}

async fn authenticate(
    stream: &mut Stream,
    ui: &mut mpsc::UnboundedReceiver<Data>,
    interface: impl Interface,
    state: &Arc<LoginState>,
    key: &PeerStorageKey,
    password: &str,
    mut hash: Option<Hash>,
    mut pending_login: Option<UiLogin>,
) -> ResultType<(Features, CallerFacts)> {
    if let Some(value) = hash.clone() {
        if !login(
            interface.clone(),
            state,
            password,
            value,
            pending_login.take(),
            stream,
        )
        .await
        {
            bail!("tunnel_cancelled");
        }
    }
    let mut required_2fa = false;
    let mut last_receive = Instant::now();
    let mut tick = interval(Duration::from_millis(100));
    loop {
        tokio::select! {
            _ = tick.tick() => {
                if last_receive.elapsed() >= AUTH_IDLE { bail!("tunnel_authentication_timeout"); }
                if !scope_current(key).await { bail!("tunnel_namespace_changed"); }
            },
            data = ui.recv() => match data {
                None | Some(Data::Close) | Some(Data::RejectInsecureConnection) => bail!("tunnel_cancelled"),
                Some(Data::Login(value)) => match hash.clone() {
                    Some(hash) => {
                        if !scope_current(key).await { bail!("tunnel_namespace_changed"); }
                        if !login(interface.clone(), state, password, hash, Some(value), stream).await { bail!("tunnel_cancelled"); }
                    }
                    None => pending_login = Some(value),
                },
                Some(Data::Message(message)) if matches!(message.union.as_ref(), Some(message::Union::Auth2fa(_))) => {
                    if !scope_current(key).await { bail!("tunnel_namespace_changed"); }
                    send(stream, &message).await?;
                }
                _ => {},
            },
            bytes = stream.next() => {
                let bytes = bytes.ok_or_else(|| anyhow!("tunnel_stream_closed"))?
                    .map_err(|_| anyhow!("tunnel_stream_closed"))?;
                last_receive = Instant::now();
                if bytes.is_empty() { continue; }
                interface.update_received(true);
                match decode(&bytes)?.union {
                    Some(message::Union::Hash(value)) => {
                        hash = Some(value.clone());
                        if !scope_current(key).await { bail!("tunnel_namespace_changed"); }
                        if !login(interface.clone(), state, password, value, pending_login.take(), stream).await { bail!("tunnel_cancelled"); }
                    }
                    Some(message::Union::LoginResponse(response)) => match response.union {
                        Some(login_response::Union::Error(error)) => {
                            required_2fa |= error == REQUIRE_2FA;
                            if !interface.handle_login_error(&error) { bail!("tunnel_authentication_rejected"); }
                        }
                        Some(login_response::Union::PeerInfo(info)) => {
                            let features = info.features.as_ref().cloned().ok_or_else(|| anyhow!("tunnel_protocol_unsupported"))?;
                            if !features.port_forward_mux || !features.nikodesk_tunnel_v1 { bail!("tunnel_protocol_unsupported"); }
                            if !scope_current(key).await { bail!("tunnel_namespace_changed"); }
                            state.my_id()?;
                            interface.handle_peer_info(info);
                            return Ok((features, CallerFacts { encrypted: stream.is_secured(), authenticated: true,
                                typed_tunnel_v1: true, ordinary_user: true, totp_required: required_2fa,
                                totp_verified_current: true }));
                        }
                        _ => bail!("tunnel_authentication_unconfirmed"),
                    },
                    Some(message::Union::TestDelay(value)) => interface.handle_test_delay(value, stream).await,
                    _ => bail!("tunnel_authentication_unconfirmed"),
                }
            }
        }
    }
}

struct StatusGate {
    fence: StatusFence,
    my_id: String,
    last: Option<(ReadOnlyStatus, Clock)>,
    started: Clock,
    closed: bool,
}
impl StatusGate {
    fn new(binding: Binding, namespace: String, target: Target, my_id: String) -> ResultType<Self> {
        Ok(Self {
            fence: StatusFence::new(binding, namespace, target).map_err(|e| anyhow!(e.code()))?,
            my_id,
            last: None,
            started: Clock::now(),
            closed: false,
        })
    }
    fn accept(
        &mut self,
        status: &NikoTunnelStatus,
        peer: &Features,
        facts: CallerFacts,
        now: Clock,
    ) -> ResultType<ReadPhase> {
        if self.closed {
            bail!("tunnel_stream_closed");
        }
        let parsed = ReadOnlyStatus::parse(&status.status_json).map_err(|e| anyhow!(e.code()))?;
        if parsed.identity.peer_id != self.my_id {
            bail!("tunnel_status_owner_mismatch");
        }
        let value = self
            .fence
            .accept(status, peer, facts)
            .map_err(|e| anyhow!(e.code()))?;
        let phase = value.phase;
        self.last = Some((value, now));
        Ok(phase)
    }
    fn fresh(&self, now: Clock) -> bool {
        !self.closed
            && self.last.as_ref().map_or(false, |(_, seen)| {
                now.saturating_duration_since(*seen) < STATUS_AGE
            })
    }
    fn allowed(&self, now: Clock) -> bool {
        self.fresh(now)
            && self.last.as_ref().map_or(false, |(status, _)| {
                !status.cleanup_only
                    && matches!(status.phase, ReadPhase::Starting | ReadPhase::Running)
            })
    }
    fn expired(&self, now: Clock) -> bool {
        self.last.as_ref().map_or(
            now.saturating_duration_since(self.started) >= STATUS_AGE,
            |(_, seen)| now.saturating_duration_since(*seen) >= STATUS_AGE,
        )
    }
}

struct ActiveChannel {
    inbound: mpsc::UnboundedSender<Inbound>,
    window: Arc<Mutex<RecvWindow>>,
    credit: Arc<SendCredit>,
    cancel: watch::Sender<bool>,
    task: JoinHandle<bool>,
    closing: bool,
    close_queued: bool,
}
enum Channel {
    Opening {
        socket: TcpStream,
        deadline: Instant,
    },
    Active(ActiveChannel),
}
struct Channels {
    values: HashMap<i32, Channel>,
    next: i32,
    output: mpsc::Sender<(Instant, Arc<Message>)>,
    join_failed: bool,
}
impl Channels {
    fn new(output: mpsc::Sender<(Instant, Arc<Message>)>) -> Self {
        Self {
            values: HashMap::new(),
            next: 0,
            output,
            join_failed: false,
        }
    }
    fn room(&self) -> bool {
        self.values.len() < MAX_CHANNELS && self.next < i32::MAX
    }
    fn add(&mut self, socket: TcpStream, target: &Target) -> ResultType<Message> {
        if !self.room() {
            bail!("tunnel_channel_limit");
        }
        self.next = self
            .next
            .checked_add(1)
            .ok_or_else(|| anyhow!("tunnel_channel_limit"))?;
        self.values.insert(
            self.next,
            Channel::Opening {
                socket,
                deadline: Instant::now() + OPEN_BUDGET,
            },
        );
        Ok(mux::open_msg(
            self.next,
            target.host(),
            i32::from(target.port()),
            mux::CHANNEL_WINDOW,
        ))
    }
    fn opened(&mut self, id: i32, success: bool, window: u32) -> ResultType<()> {
        let socket = match self.values.remove(&id) {
            Some(Channel::Opening { socket, deadline }) if Instant::now() < deadline => socket,
            Some(channel) => {
                self.values.insert(id, channel);
                bail!("tunnel_channel_open_stale");
            }
            None if id <= self.next => return Ok(()),
            None => bail!("tunnel_channel_unknown"),
        };
        if !success {
            return Ok(());
        }
        // No socket reader, data, or WindowUpdate exists until actual Opened.success.
        let (reader, writer) = socket.into_split();
        let (inbound, receiver) = mpsc::unbounded_channel();
        let (cancel, cancelled) = watch::channel(false);
        let credit = Arc::new(SendCredit::new(window));
        let receive_window = Arc::new(Mutex::new(RecvWindow::new(mux::CHANNEL_WINDOW)));
        let task = tokio::spawn(mux::run_channel_checked(
            id,
            reader,
            writer,
            Vec::new(),
            Vec::new(),
            credit.clone(),
            receive_window.clone(),
            receiver,
            FrameSink::BoundedDirect(self.output.clone()),
            cancelled,
        ));
        self.values.insert(
            id,
            Channel::Active(ActiveChannel {
                inbound,
                window: receive_window,
                credit,
                cancel,
                task,
                closing: false,
                close_queued: false,
            }),
        );
        Ok(())
    }
    fn incoming(&mut self, frame: PortForwardChannel) -> ResultType<()> {
        match frame.union {
            Some(port_forward_channel::Union::Opened(value)) => {
                self.opened(value.channel_id, value.success, value.window)
            }
            Some(port_forward_channel::Union::Data(value)) => {
                match self.values.get(&value.channel_id) {
                    Some(Channel::Active(channel)) if !channel.closing => {
                        if !channel.window.lock().unwrap().accept(value.data.len()) {
                            bail!("tunnel_receive_window_exceeded");
                        }
                        channel
                            .inbound
                            .send(Inbound::Data(value.data))
                            .map_err(|_| anyhow!("tunnel_channel_closed").into())
                    }
                    Some(_) => bail!("tunnel_channel_not_opened"),
                    None if value.channel_id <= self.next => Ok(()),
                    None => bail!("tunnel_channel_unknown"),
                }
            }
            Some(port_forward_channel::Union::WindowUpdate(value)) => {
                match self.values.get(&value.channel_id) {
                    Some(Channel::Active(channel)) if !channel.closing => {
                        channel.credit.add(value.add);
                        Ok(())
                    }
                    Some(_) => bail!("tunnel_channel_not_opened"),
                    None if value.channel_id <= self.next => Ok(()),
                    None => bail!("tunnel_channel_unknown"),
                }
            }
            Some(port_forward_channel::Union::Close(value)) => {
                if let Some(Channel::Active(channel)) = self.values.get_mut(&value.channel_id) {
                    channel.closing = true;
                    let _ = channel.cancel.send(true);
                } else {
                    self.values.remove(&value.channel_id);
                }
                Ok(())
            }
            _ => bail!("tunnel_typed_frame_invalid"),
        }
    }
    fn may_send(&self, message: &Message) -> bool {
        let frame = match message.union.as_ref() {
            Some(message::Union::PortForwardChannel(frame)) => frame,
            _ => return false,
        };
        let (id, close) = match frame.union.as_ref() {
            Some(port_forward_channel::Union::Data(value)) => (value.channel_id, false),
            Some(port_forward_channel::Union::WindowUpdate(value)) => (value.channel_id, false),
            Some(port_forward_channel::Union::Close(value)) => (value.channel_id, true),
            _ => return false,
        };
        self.values.get(&id).map_or(
            false,
            |channel| matches!(channel, Channel::Active(active) if close || !active.closing),
        )
    }
    fn sent(&mut self, message: &Message) {
        if let Some(message::Union::PortForwardChannel(frame)) = message.union.as_ref() {
            if let Some(port_forward_channel::Union::Close(close)) = frame.union.as_ref() {
                if let Some(Channel::Active(channel)) = self.values.get_mut(&close.channel_id) {
                    channel.closing = true;
                    let _ = channel.cancel.send(true);
                }
            }
        }
    }
    async fn reap(&mut self) -> Vec<i32> {
        // A completed relay may still have ordered data queued. Its close must
        // follow that data, rather than being sent directly by this timer.
        for (id, channel) in self.values.iter_mut() {
            if let Channel::Active(channel) = channel {
                if channel.task.is_finished() && !channel.closing && !channel.close_queued {
                    channel.close_queued = self
                        .output
                        .try_send((Instant::now(), Arc::new(mux::close_msg(*id))))
                        .is_ok();
                }
            }
        }
        let finished: Vec<_> = self
            .values
            .iter()
            .filter_map(|(id, channel)| match channel {
                Channel::Opening { deadline, .. } if Instant::now() >= *deadline => {
                    Some((*id, true))
                }
                Channel::Active(channel) if channel.closing && channel.task.is_finished() => {
                    Some((*id, false))
                }
                _ => None,
            })
            .collect();
        let mut openings = Vec::new();
        for (id, opening) in finished {
            if opening {
                openings.push(id);
            }
            if let Some(Channel::Active(channel)) = self.values.remove(&id) {
                self.join_failed |= !matches!(channel.task.await, Ok(true));
            }
        }
        openings
    }
    async fn close(&mut self) -> bool {
        for channel in self.values.values() {
            if let Channel::Active(channel) = channel {
                let _ = channel.cancel.send(true);
            }
        }
        let mut joined = !self.join_failed;
        for (_, channel) in self.values.drain() {
            if let Channel::Active(channel) = channel {
                joined &= matches!(channel.task.await, Ok(true));
            }
        }
        joined
    }
}

async fn frame_send(
    stream: &mut Stream,
    message: &mut Message,
    gate: &StatusGate,
    key: &PeerStorageKey,
    binding: Binding,
    peer: &Features,
    facts: CallerFacts,
) -> ResultType<()> {
    if !scope_current(key).await || !gate.allowed(Clock::now()) {
        bail!("tunnel_status_unconfirmed");
    }
    wire::tag_message(
        message,
        binding,
        peer,
        facts,
        Direction::ControllerToReceiver,
    )
    .map_err(|e| anyhow!(e.code()))?;
    send(stream, message).await
}
async fn query(
    stream: &mut Stream,
    binding: Binding,
    peer: &Features,
    facts: CallerFacts,
    op: ControlOp,
) -> ResultType<()> {
    let mut message = Message::new();
    message.set_nikodesk_tunnel_control(
        wire::control(binding, op, peer, facts).map_err(|e| anyhow!(e.code()))?,
    );
    send(stream, &message).await
}

async fn forward(
    stream: &mut Stream,
    ui: &mut mpsc::UnboundedReceiver<Data>,
    interface: impl Interface,
    key: &PeerStorageKey,
    binding: Binding,
    target: &Target,
    local_port: u16,
    peer: Features,
    facts: CallerFacts,
    mut gate: StatusGate,
    observer: &mut ui::Publisher,
) -> ResultType<()> {
    let (output, mut outgoing) = mpsc::channel(OUTBOUND_FRAMES);
    let mut channels = Channels::new(output);
    let mut listener: Option<TcpListener> = None;
    let mut tick = interval(Duration::from_millis(100));
    let mut last_query = Clock::now()
        .checked_sub(QUERY_INTERVAL)
        .unwrap_or_else(Clock::now);
    let result: ResultType<()> = async {
        let interface = interface;
        loop {
            tokio::select! {
                _ = tick.tick() => {
                    let now = Clock::now();
                    if gate.expired(now) { bail!("tunnel_status_unconfirmed"); }
                    if !scope_current(key).await { bail!("tunnel_namespace_changed"); }
                    if now.saturating_duration_since(last_query) >= QUERY_INTERVAL {
                        query(stream, binding, &peer, facts, ControlOp::Query).await?;
                        last_query = Clock::now();
                    }
                    // Expired opening sockets are dropped here; completed relay tasks are joined.
                    for id in channels.reap().await {
                        if gate.allowed(Clock::now()) {
                            let mut close = mux::close_msg(id);
                            frame_send(stream, &mut close, &gate, key, binding, &peer, facts).await?;
                        }
                    }
                }
                data = ui.recv() => match data {
                    None | Some(Data::Close) | Some(Data::RejectInsecureConnection) => {
                        observer.emit("Stopping", "tunnel_local_stopping", false);
                        break;
                    },
                    _ => {},
                },
                message = outgoing.recv() => {
                    if let Some((queued, message)) = message {
                        if queued.elapsed() >= STATUS_AGE { bail!("tunnel_send_queue_expired"); }
                        if channels.may_send(&message) {
                            frame_send(stream, &mut (*message).clone(), &gate, key, binding, &peer, facts).await?;
                            channels.sent(&message);
                        }
                    }
                },
                accepted = async { match listener.as_ref() {
                    Some(listener) => listener.accept().await,
                    None => std::future::pending().await,
                } }, if gate.allowed(Clock::now()) && channels.room() => {
                    let (socket, _) = accepted.map_err(|_| anyhow!("tunnel_listener_failed"))?;
                    let mut open = channels.add(socket, target)?;
                    frame_send(stream, &mut open, &gate, key, binding, &peer, facts).await?;
                },
                bytes = stream.next() => {
                    let bytes = bytes.ok_or_else(|| anyhow!("tunnel_stream_closed"))?
                        .map_err(|_| anyhow!("tunnel_stream_closed"))?;
                    if bytes.is_empty() { continue; }
                    match decode(&bytes)?.union {
                        Some(message::Union::NikodeskTunnelStatus(status)) => {
                            let received_at = Clock::now();
                            if !scope_current(key).await { bail!("tunnel_namespace_changed"); }
                            let phase = gate.accept(&status, &peer, facts, received_at)?;
                            let previous = observer.remote_phase;
                            observer.remote(phase);
                            if matches!(phase, ReadPhase::Revoking | ReadPhase::RecoveryRequired | ReadPhase::Stopped)
                                || gate.last.as_ref().map_or(false, |(s, _)| s.cleanup_only) {
                                observer.emit("Stopping", "tunnel_remote_stopping", false);
                                break;
                            }
                            if phase == ReadPhase::Pending && previous != Some("Pending") {
                                observer.emit("WaitingApproval", "tunnel_local_approval_required", false);
                            }
                            if gate.allowed(Clock::now()) && listener.is_none() {
                                listener = Some(TcpListener::bind((std::net::Ipv4Addr::LOCALHOST, local_port)).await
                                    .map_err(|_| anyhow!("tunnel_local_port_unavailable"))?);
                                observer.emit("Listening", "tunnel_local_listening", false);
                            }
                        }
                        Some(message::Union::PortForwardChannel(frame)) => {
                            if !gate.allowed(Clock::now()) || !scope_current(key).await { bail!("tunnel_status_unconfirmed"); }
                            wire::validate_frame(&frame, binding, &peer, facts, Direction::ReceiverToController).map_err(|e| anyhow!(e.code()))?;
                            channels.incoming(frame)?;
                        }
                        Some(message::Union::TestDelay(value)) => interface.handle_test_delay(value, stream).await,
                        _ => bail!("tunnel_typed_message_required"),
                    }
                }
            }
        }
        Ok(())
    }.await;
    gate.closed = true;
    drop(listener);
    outgoing.close();
    let joined = channels.close().await;
    // A wire revoke requests remote cleanup. Only local joins above prove these local FDs ended.
    if scope_current(key).await {
        let _ = query(stream, binding, &peer, facts, ControlOp::Revoke).await;
    }
    if !joined {
        bail!("tunnel_local_cleanup_unconfirmed");
    }
    result
}

pub(crate) async fn listen(
    id: String,
    password: String,
    port: i32,
    interface: impl Interface + Sync,
    ui: mpsc::UnboundedReceiver<Data>,
    key: &str,
    token: &str,
    _lc: Arc<RwLock<LoginConfigHandler>>,
    remote_host: String,
    remote_port: i32,
) -> ResultType<()> {
    if !(1..=65535).contains(&port) { bail!("tunnel_ordinary_listener_required"); }
    let target = Target::parse(&remote_host, remote_port).map_err(|_| anyhow!("tunnel_invalid_target"))?;
    let mut observer = ui::Publisher::new(&interface, port as u16, target)?;
    observer.emit("Connecting", "tunnel_connecting", false);
    let result = listen_owned(id, password, port, interface, ui, key, token, _lc,
        remote_host, remote_port, &mut observer).await;
    // The owned native Stream and listeners have left scope before this event.
    observer.complete(&result);
    result
}

async fn listen_owned(
    id: String, password: String, port: i32, interface: impl Interface + Sync,
    mut ui: mpsc::UnboundedReceiver<Data>, key: &str, token: &str,
    _lc: Arc<RwLock<LoginConfigHandler>>, remote_host: String, remote_port: i32,
    observer: &mut ui::Publisher,
) -> ResultType<()> {
    if !(1..=65535).contains(&port) || crate::nikodesk::background::is_system_worker() {
        bail!("tunnel_ordinary_listener_required");
    }
    let target =
        Target::parse(&remote_host, remote_port).map_err(|_| anyhow!("tunnel_invalid_target"))?;
    let snapshot = interface.connection_snapshot()?;
    let peer_key = snapshot
        .peer_key(&id)
        .ok_or_else(|| anyhow!("tunnel_private_stream_required"))?;
    if !scope_current(&peer_key).await {
        bail!("tunnel_namespace_changed");
    }
    let ((mut stream, direct, _pk, _kcp, _stream_type), _) =
        Client::start(&id, key, token, ConnType::PORT_FORWARD, interface.clone()).await?;
    interface.update_direct(Some(direct));
    if !stream.is_secured() {
        bail!("tunnel_encrypted_stream_required");
    }
    stream.set_max_packet_length(mux::MAX_PACKET);
    let binding = fresh_binding()?;
    let (login_state, hash, pending_login) =
        probe(&mut stream, &mut ui, &peer_key, &target, binding).await?;
    let (peer, facts) = authenticate(
        &mut stream,
        &mut ui,
        interface.clone(),
        &login_state,
        &peer_key,
        &password,
        hash,
        pending_login,
    )
    .await?;
    let gate = StatusGate::new(
        binding,
        snapshot.namespace().to_owned(),
        target.clone(),
        login_state.my_id()?.to_owned(),
    )?;
    forward(
        &mut stream,
        &mut ui,
        interface.clone(),
        &peer_key,
        binding,
        &target,
        port as u16,
        peer,
        facts,
        gate,
        observer,
    )
    .await
}

/// A window owns every mapping until its actual native task has exited.
pub(crate) async fn run_mappings(
    interface: impl Interface + Sync,
    password: String,
    args: Vec<String>,
    saved: Vec<(i32, String, i32)>,
    mut receiver: mpsc::UnboundedReceiver<Data>,
    key: String,
    token: String,
) -> bool {
    let mut mappings: HashMap<i32, (mpsc::UnboundedSender<Data>, JoinHandle<bool>)> = HashMap::new();
    let mut children_closed = true;
    let mut initial = saved;
    if !args.is_empty() {
        if args.len() != 3 {
            interface.on_error("tunnel_invalid_mapping");
            return true;
        }
        initial = vec![(
            args[0].parse().unwrap_or(0),
            args[1].clone(),
            args[2].parse().unwrap_or(0),
        )];
    }
    let mut pending = initial.into_iter();
    loop {
        let data = match pending.next() {
            Some(value) => Some(Data::AddPortForward(value)),
            None => receiver.recv().await,
        };
        match data {
            Some(Data::AddPortForward((port, host, remote_port))) => {
                if !(1..=65535).contains(&port) || Target::parse(&host, remote_port).is_err() {
                    interface.on_error("tunnel_invalid_mapping");
                    continue;
                }
                if let Some((close, task)) = mappings.remove(&port) {
                    let _ = close.send(Data::Close);
                    children_closed &= matches!(task.await, Ok(true));
                }
                let finished: Vec<_> = mappings
                    .iter()
                    .filter_map(|(port, (_, task))| task.is_finished().then_some(*port))
                    .collect();
                for port in finished {
                    if let Some((_, task)) = mappings.remove(&port) {
                        children_closed &= matches!(task.await, Ok(true));
                    }
                }
                if !children_closed {
                    interface.on_error("tunnel_local_cleanup_unconfirmed");
                    continue;
                }
                if mappings.len() >= MAX_MAPPINGS {
                    interface.on_error("tunnel_mapping_limit");
                    continue;
                }
                let (sender, receiver) = mpsc::unbounded_channel();
                let owner = interface.clone();
                let password = password.clone();
                let key = key.clone();
                let token = token.clone();
                let task = tokio::spawn(async move {
                    let result = listen(
                        owner.get_id(),
                        password,
                        port,
                        owner.clone(),
                        receiver,
                        &key,
                        &token,
                        owner.get_lch(),
                        host,
                        remote_port,
                    )
                    .await;
                    let closed = result.as_ref().err().map_or(true,
                        |error| error.to_string() != "tunnel_local_cleanup_unconfirmed");
                    if let Err(error) = result {
                        owner.on_error(&error.to_string());
                    }
                    closed
                });
                mappings.insert(port, (sender, task));
            }
            Some(Data::RemovePortForward(port)) => {
                if let Some((close, task)) = mappings.remove(&port) {
                    let _ = close.send(Data::Close);
                    children_closed &= matches!(task.await, Ok(true));
                }
            }
            None | Some(Data::Close) => break,
            Some(data @ Data::Login(_)) | Some(data @ Data::Message(_)) => {
                for (sender, _) in mappings.values() {
                    let _ = sender.send(data.clone());
                }
            }
            _ => {}
        }
    }
    for (sender, _) in mappings.values() {
        let _ = sender.send(Data::Close);
    }
    for (_, (_, task)) in mappings {
        children_closed &= matches!(task.await, Ok(true));
    }
    children_closed
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::nikodesk::{
        connection_capabilities::Identity,
        tunnel_flow::{Phase, Status, TargetView},
    };
    use hbb_common::{
        sodiumoxide::crypto::secretbox::Key,
        tcp::FramedStream,
        tokio::io::{AsyncReadExt, AsyncWriteExt},
    };

    fn target() -> Target {
        Target::parse("127.0.0.1", 23456).unwrap()
    }
    fn binding() -> Binding {
        Binding::new([9; 16], 1).unwrap()
    }
    fn facts() -> CallerFacts {
        CallerFacts {
            encrypted: true,
            authenticated: true,
            typed_tunnel_v1: true,
            ordinary_user: true,
            totp_required: true,
            totp_verified_current: true,
        }
    }
    fn probe_facts() -> ProbeFacts {
        ProbeFacts {
            encrypted: true,
            private_stream_bound: true,
            before_login: true,
            stream_nonce: [7; 16],
        }
    }
    fn status(phase: Phase, revision: u64) -> NikoTunnelStatus {
        let granted = matches!(phase, Phase::Starting | Phase::Running);
        wire::status(
            binding(),
            &Status {
                identity: Identity {
                    connection_id: 7,
                    namespace: "a".repeat(64),
                    peer_id: "123456789".into(),
                    connection_nonce: "01".repeat(16),
                    request_nonce: "02".repeat(16),
                    epoch: "1".into(),
                },
                kind: "tunnel".into(),
                phase,
                reason: "synthetic_contract_fixture".into(),
                revision: revision.to_string(),
                resource_epoch: revision.to_string(),
                target: TargetView {
                    host: target().host().into(),
                    port: target().port(),
                },
                addresses: if granted {
                    vec!["127.0.0.1:23456".into()]
                } else {
                    vec![]
                },
                selected_address: granted.then(|| "127.0.0.1:23456".into()),
                cleanup_only: false,
            },
            &wire::features(true),
            facts(),
        )
        .unwrap()
    }
    fn gate() -> StatusGate {
        StatusGate::new(binding(), "a".repeat(64), target(), "123456789".into()).unwrap()
    }
    fn state() -> Arc<LoginState> {
        let f = probe_facts();
        let now = Clock::now();
        let mut client = wire::ProbeFence::new([8; 16], f, now).unwrap();
        let request = client.request(f, now).unwrap();
        let reply = wire::ServerProbeFence::default()
            .reply(&request, true, f)
            .unwrap();
        let receipt = client.accept(&reply, f, now).unwrap();
        LoginState::new(
            wire::typed_login(
                &target(),
                binding(),
                receipt,
                &wire::features(false),
                f,
                now,
            )
            .unwrap(),
        )
        .unwrap()
    }
    async fn encrypted_pair() -> (Stream, Stream) {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let client = TcpStream::connect(address).await.unwrap();
        let (server, _) = listener.accept().await.unwrap();
        let mut a = Stream::Tcp(FramedStream::from(client, address));
        let mut b = Stream::Tcp(FramedStream::from(server, address));
        a.set_key(Key([23; 32]));
        b.set_key(Key([23; 32]));
        a.set_max_packet_length(mux::MAX_PACKET);
        b.set_max_packet_length(mux::MAX_PACKET);
        (a, b)
    }
    async fn socket_pair() -> (TcpStream, TcpStream) {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let app = TcpStream::connect(listener.local_addr().unwrap())
            .await
            .unwrap();
        let (forward, _) = listener.accept().await.unwrap();
        (app, forward)
    }
    async fn read_message(stream: &mut Stream) -> Message {
        decode(
            &timeout(Duration::from_secs(2), stream.next())
                .await
                .unwrap()
                .unwrap()
                .unwrap(),
        )
        .unwrap()
    }

    #[test]
    fn typed_login_retry_keeps_target_binding_and_original_my_id_without_config() {
        let state = state();
        let mut first = LoginRequest {
            my_id: "123456789".into(),
            password: vec![1, 2].into(),
            ..Default::default()
        };
        assert!(state.decorate(&mut first));
        let mut second = LoginRequest {
            my_id: "123456789".into(),
            password: vec![3, 4].into(),
            ..Default::default()
        };
        assert!(state.decorate(&mut second));
        assert_eq!(first.port_forward(), second.port_forward());
        assert_ne!(first.password, second.password);
        assert!(first.nikodesk_features.as_ref().unwrap().nikodesk_tunnel_v1);
        assert!(
            !first
                .nikodesk_features
                .as_ref()
                .unwrap()
                .nikodesk_tunnel_requests_allowed
        );
        let typed = wire::parse_login(first.port_forward()).unwrap();
        assert_eq!(typed.binding, binding());
        assert_eq!(typed.target, target());
        second.my_id = "987654321".into();
        assert!(!state.decorate(&mut second));
        assert_eq!(state.my_id().unwrap(), "123456789");
    }
    #[test]
    fn raw_or_unprobed_login_cannot_create_a_typed_state() {
        assert!(LoginState::new(PortForward {
            host: "127.0.0.1".into(),
            port: 23456,
            multiplex: true,
            ..Default::default()
        })
        .is_err());
        let mut login = LoginRequest {
            my_id: "123456789@public.example".into(),
            ..Default::default()
        };
        assert!(!state().decorate(&mut login));
    }
    #[test]
    fn remote_pending_is_not_listener_grant_and_same_revision_is_only_freshness() {
        let mut gate = gate();
        let now = Clock::now();
        gate.accept(
            &status(Phase::Pending, 1),
            &wire::features(true),
            facts(),
            now,
        )
        .unwrap();
        assert!(!gate.allowed(now));
        assert!(!gate.expired(now + Duration::from_millis(1900)));
        assert!(gate.expired(now + STATUS_AGE));
        gate.accept(
            &status(Phase::Starting, 2),
            &wire::features(true),
            facts(),
            now,
        )
        .unwrap();
        assert!(gate.allowed(now));
        assert!(!gate.allowed(now + STATUS_AGE));
        gate.accept(
            &status(Phase::Starting, 2),
            &wire::features(true),
            facts(),
            now + Duration::from_secs(1),
        )
        .unwrap();
        assert!(gate.allowed(now + STATUS_AGE));
    }
    #[test]
    fn status_wrong_controller_scope_binding_and_revival_are_rejected() {
        let mut gate = gate();
        let now = Clock::now();
        let mut wrong = status(Phase::Pending, 1);
        wrong.status_json = wrong.status_json.replace("123456789", "987654321");
        assert!(gate
            .accept(&wrong, &wire::features(true), facts(), now)
            .is_err());
        wrong = status(Phase::Pending, 1);
        wrong.binding.as_mut().unwrap().epoch = 2;
        assert!(gate
            .accept(&wrong, &wire::features(true), facts(), now)
            .is_err());
        wrong = status(Phase::Pending, 1);
        wrong.status_json = wrong.status_json.replace(&"a".repeat(64), &"b".repeat(64));
        assert!(gate
            .accept(&wrong, &wire::features(true), facts(), now)
            .is_err());
        gate.accept(
            &status(Phase::Running, 2),
            &wire::features(true),
            facts(),
            now,
        )
        .unwrap();
        assert!(gate
            .accept(
                &status(Phase::Pending, 3),
                &wire::features(true),
                facts(),
                now
            )
            .is_err());
        gate.accept(
            &status(Phase::Revoking, 3),
            &wire::features(true),
            facts(),
            now,
        )
        .unwrap();
        assert!(!gate.allowed(now));
        assert!(gate
            .accept(
                &status(Phase::Running, 4),
                &wire::features(true),
                facts(),
                now
            )
            .is_err());
        gate.closed = true;
        assert!(gate
            .accept(
                &status(Phase::Stopped, 4),
                &wire::features(true),
                facts(),
                now
            )
            .is_err());
    }
    #[tokio::test]
    async fn actual_encrypted_probe_receipt_is_required_before_typed_login() {
        let (mut client, mut peer) = encrypted_pair().await;
        let (sender, mut ui) = mpsc::unbounded_channel();
        let server = tokio::spawn(async move {
            // Protocol fixture, not a RustDesk authentication/CM approval server.
            let request = read_message(&mut peer).await;
            let mut hash = Message::new();
            hash.set_hash(Hash {
                salt: "synthetic".into(),
                challenge: "synthetic".into(),
                ..Default::default()
            });
            send(&mut peer, &hash).await.unwrap();
            let receipt = wire::ServerProbeFence::default()
                .reply(request.nikodesk_tunnel_probe(), true, probe_facts())
                .unwrap();
            let mut reply = Message::new();
            reply.set_nikodesk_tunnel_probe_reply(receipt);
            send(&mut peer, &reply).await.unwrap();
        });
        let (state, hash, _) =
            probe_stream(&mut client, &mut ui, &target(), binding(), probe_facts())
                .await
                .unwrap();
        assert!(hash.is_some());
        assert_eq!(
            wire::parse_login(&state.port_forward).unwrap().binding,
            binding()
        );
        server.await.unwrap();
        drop(sender);
    }
    #[tokio::test]
    async fn probe_skips_what_the_controlled_side_sends_when_a_stream_opens() {
        let (mut client, mut peer) = encrypted_pair().await;
        let (sender, mut ui) = mpsc::unbounded_channel();
        let server = tokio::spawn(async move {
            let request = read_message(&mut peer).await;
            // A real connection announces each disabled permission and starts
            // its delay probe before it handles anything the peer sent.
            let mut permission = Message::new();
            let mut announcement = base::message_proto::Misc::new();
            announcement.set_permission_info(base::message_proto::PermissionInfo {
                permission: base::message_proto::permission_info::Permission::Audio.into(),
                enabled: false,
                ..Default::default()
            });
            permission.set_misc(announcement);
            send(&mut peer, &permission).await.unwrap();
            let mut delay = Message::new();
            delay.set_test_delay(base::message_proto::TestDelay::default());
            send(&mut peer, &delay).await.unwrap();
            let mut hash = Message::new();
            hash.set_hash(Hash {
                salt: "synthetic".into(),
                challenge: "synthetic".into(),
                ..Default::default()
            });
            send(&mut peer, &hash).await.unwrap();
            let receipt = wire::ServerProbeFence::default()
                .reply(request.nikodesk_tunnel_probe(), true, probe_facts())
                .unwrap();
            let mut reply = Message::new();
            reply.set_nikodesk_tunnel_probe_reply(receipt);
            send(&mut peer, &reply).await.unwrap();
        });
        let (state, hash, _) =
            probe_stream(&mut client, &mut ui, &target(), binding(), probe_facts())
                .await
                .unwrap();
        assert!(hash.is_some());
        assert_eq!(
            wire::parse_login(&state.port_forward).unwrap().binding,
            binding()
        );
        server.await.unwrap();
        drop(sender);
    }
    #[tokio::test]
    async fn legacy_probe_reply_and_wrong_nonce_fail_closed_on_real_stream() {
        for wrong_nonce in [false, true] {
            let (mut client, mut peer) = encrypted_pair().await;
            let (_sender, mut ui) = mpsc::unbounded_channel();
            let server = tokio::spawn(async move {
                let request = read_message(&mut peer).await;
                let mut reply = Message::new();
                if wrong_nonce {
                    let mut receipt = wire::ServerProbeFence::default()
                        .reply(request.nikodesk_tunnel_probe(), true, probe_facts())
                        .unwrap();
                    receipt.nonce = vec![11; 16].into();
                    reply.set_nikodesk_tunnel_probe_reply(receipt);
                } else {
                    reply.set_login_response(base::message_proto::LoginResponse::default());
                }
                send(&mut peer, &reply).await.unwrap();
            });
            assert!(
                probe_stream(&mut client, &mut ui, &target(), binding(), probe_facts())
                    .await
                    .is_err()
            );
            server.await.unwrap();
        }
    }
    #[tokio::test]
    async fn probe_cancel_never_creates_a_login_or_local_listener() {
        let (mut client, mut peer) = encrypted_pair().await;
        let (sender, mut ui) = mpsc::unbounded_channel();
        sender.send(Data::Close).unwrap();
        assert!(
            probe_stream(&mut client, &mut ui, &target(), binding(), probe_facts())
                .await
                .is_err()
        );
        let message = read_message(&mut peer).await;
        assert!(matches!(
            message.union,
            Some(message::Union::NikodeskTunnelProbe(_))
        ));
    }
    #[tokio::test]
    async fn reaped_failed_relay_join_cannot_become_successful_cleanup() {
        let (sender, _outgoing) = mpsc::channel(OUTBOUND_FRAMES);
        let mut channels = Channels::new(sender);
        let (mut app, socket) = socket_pair().await;
        channels.add(socket, &target()).unwrap();
        channels.opened(1, true, mux::CHANNEL_WINDOW).unwrap();
        let Some(Channel::Active(channel)) = channels.values.get_mut(&1) else { panic!("actual relay was not started"); };
        channel.closing = true;
        channel.task.abort();
        timeout(Duration::from_secs(1), async {
            while !channels.values.get(&1).is_some_and(|value|
                matches!(value, Channel::Active(channel) if channel.task.is_finished())) {
                tokio::task::yield_now().await;
            }
        }).await.unwrap();
        channels.reap().await;
        assert!(channels.values.is_empty());
        assert!(!channels.close().await);
        let mut byte = [0];
        assert_eq!(timeout(Duration::from_secs(1), app.read(&mut byte)).await.unwrap().unwrap(), 0);
    }
    #[tokio::test]
    async fn checked_relay_half_panic_is_not_normal_local_cleanup() {
        let (sender, _outgoing) = mpsc::channel(OUTBOUND_FRAMES);
        let mut channels = Channels::new(sender);
        let (mut app, socket) = socket_pair().await;
        channels.add(socket, &target()).unwrap();
        channels.opened(1, true, mux::CHANNEL_WINDOW).unwrap();
        let Channel::Active(channel) = channels.values.get(&1).unwrap() else { panic!("actual relay absent"); };
        let window = channel.window.clone();
        assert!(std::thread::spawn(move || { let _guard = window.lock().unwrap(); panic!("isolated receive window poison"); }).join().is_err());
        channel.inbound.send(Inbound::Data(b"actual socket bytes before injected panic".to_vec().into())).unwrap();
        let mut received = vec![0; b"actual socket bytes before injected panic".len()];
        timeout(Duration::from_secs(2), app.read_exact(&mut received)).await.unwrap().unwrap();
        assert_eq!(received, b"actual socket bytes before injected panic");
        assert!(!timeout(Duration::from_secs(2), channels.close()).await.unwrap());
        assert_eq!(timeout(Duration::from_secs(2), app.read(&mut [0])).await.unwrap().unwrap(), 0);
    }
    #[tokio::test]
    async fn first_open_waits_for_real_success_before_data_or_window() {
        let (sender, mut outgoing) = mpsc::channel(OUTBOUND_FRAMES);
        let mut channels = Channels::new(sender);
        let (mut app, socket) = socket_pair().await;
        let open = channels.add(socket, &target()).unwrap();
        assert!(matches!(
            open.port_forward_channel().union,
            Some(port_forward_channel::Union::Open(_))
        ));
        app.write_all(b"held before actual Opened").await.unwrap();
        assert!(timeout(Duration::from_millis(40), outgoing.recv())
            .await
            .is_err());
        channels.opened(1, true, mux::CHANNEL_WINDOW).unwrap();
        let (_, data) = timeout(Duration::from_secs(2), outgoing.recv())
            .await
            .unwrap()
            .unwrap();
        assert!(matches!(
            data.port_forward_channel().union,
            Some(port_forward_channel::Union::Data(_))
        ));
        assert_eq!(
            data.port_forward_channel().data().data.as_ref(),
            b"held before actual Opened"
        );
        assert!(channels.close().await);
        assert_eq!(
            timeout(Duration::from_secs(2), app.read(&mut [0u8; 1]))
                .await
                .unwrap()
                .unwrap(),
            0
        );
    }
    #[tokio::test]
    async fn failed_open_drops_real_fd_without_ever_reading_or_sending_data() {
        let (sender, mut outgoing) = mpsc::channel(OUTBOUND_FRAMES);
        let mut channels = Channels::new(sender);
        let (mut app, socket) = socket_pair().await;
        channels.add(socket, &target()).unwrap();
        channels.opened(1, false, 0).unwrap();
        assert!(channels.values.is_empty());
        assert_eq!(app.read(&mut [0u8; 1]).await.unwrap(), 0);
        assert!(outgoing.try_recv().is_err());
        assert!(channels.close().await);
    }
    #[tokio::test]
    async fn opening_expiry_drops_socket_and_late_success_cannot_resurrect() {
        let (sender, _) = mpsc::channel(OUTBOUND_FRAMES);
        let mut channels = Channels::new(sender);
        let (mut app, socket) = socket_pair().await;
        channels.add(socket, &target()).unwrap();
        if let Some(Channel::Opening { deadline, .. }) = channels.values.get_mut(&1) {
            *deadline = Instant::now();
        }
        assert_eq!(channels.reap().await, vec![1]);
        channels.opened(1, true, mux::CHANNEL_WINDOW).unwrap();
        assert!(channels.values.is_empty());
        assert_eq!(app.read(&mut [0u8; 1]).await.unwrap(), 0);
    }
    #[tokio::test]
    async fn close_joins_real_reader_writer_even_when_both_are_parked() {
        let (sender, _) = mpsc::channel(OUTBOUND_FRAMES);
        let mut channels = Channels::new(sender);
        let (mut app, socket) = socket_pair().await;
        channels.add(socket, &target()).unwrap();
        channels.opened(1, true, mux::CHANNEL_WINDOW).unwrap();
        assert!(timeout(Duration::from_secs(2), channels.close())
            .await
            .unwrap());
        assert!(channels.values.is_empty());
        assert_eq!(app.read(&mut [0u8; 1]).await.unwrap(), 0);
    }
    #[tokio::test]
    async fn actual_encrypted_typed_data_keeps_binding_and_credit() {
        let (mut client, mut peer) = encrypted_pair().await;
        let (sender, mut outgoing) = mpsc::channel(OUTBOUND_FRAMES);
        let mut channels = Channels::new(sender);
        let (mut app, socket) = socket_pair().await;
        let mut open = channels.add(socket, &target()).unwrap();
        wire::tag_message(
            &mut open,
            binding(),
            &wire::features(true),
            facts(),
            Direction::ControllerToReceiver,
        )
        .unwrap();
        send(&mut client, &open).await.unwrap();
        let request = read_message(&mut peer).await;
        wire::validate_frame(
            request.port_forward_channel(),
            binding(),
            &wire::features(true),
            facts(),
            Direction::ControllerToReceiver,
        )
        .unwrap();
        let mut opened = mux::opened_msg(1, true, "", mux::CHANNEL_WINDOW);
        wire::tag_message(
            &mut opened,
            binding(),
            &wire::features(true),
            facts(),
            Direction::ReceiverToController,
        )
        .unwrap();
        send(&mut peer, &opened).await.unwrap();
        let reply = read_message(&mut client).await;
        wire::validate_frame(
            reply.port_forward_channel(),
            binding(),
            &wire::features(true),
            facts(),
            Direction::ReceiverToController,
        )
        .unwrap();
        channels
            .incoming(reply.port_forward_channel().clone())
            .unwrap();
        app.write_all(b"synthetic request").await.unwrap();
        let (_, packet) = outgoing.recv().await.unwrap();
        let mut packet = (*packet).clone();
        wire::tag_message(
            &mut packet,
            binding(),
            &wire::features(true),
            facts(),
            Direction::ControllerToReceiver,
        )
        .unwrap();
        send(&mut client, &packet).await.unwrap();
        let request = read_message(&mut peer).await;
        assert_eq!(
            request.port_forward_channel().data().data.as_ref(),
            b"synthetic request"
        );
        let mut response = mux::data_msg(1, bytes::Bytes::from_static(b"synthetic reply"));
        wire::tag_message(
            &mut response,
            binding(),
            &wire::features(true),
            facts(),
            Direction::ReceiverToController,
        )
        .unwrap();
        send(&mut peer, &response).await.unwrap();
        let reply = read_message(&mut client).await;
        wire::validate_frame(
            reply.port_forward_channel(),
            binding(),
            &wire::features(true),
            facts(),
            Direction::ReceiverToController,
        )
        .unwrap();
        channels
            .incoming(reply.port_forward_channel().clone())
            .unwrap();
        let mut result = [0; 15];
        app.read_exact(&mut result).await.unwrap();
        assert_eq!(&result, b"synthetic reply");
        assert!(channels.close().await);
    }
    #[tokio::test]
    async fn bounded_queue_and_live_channel_limits_are_actual_not_configuration() {
        let (sender, _outgoing) = mpsc::channel(OUTBOUND_FRAMES);
        let sink = FrameSink::BoundedDirect(sender.clone());
        for _ in 0..OUTBOUND_FRAMES {
            sink.send_ordered(mux::data_msg(1, bytes::Bytes::from_static(b"x")))
                .await
                .unwrap();
        }
        assert!(sink
            .send_ordered(mux::data_msg(1, bytes::Bytes::from_static(b"x")))
            .await
            .is_err());
        let mut channels = Channels::new(sender);
        let mut applications = Vec::new();
        for _ in 0..MAX_CHANNELS {
            let (app, socket) = socket_pair().await;
            applications.push(app);
            channels.add(socket, &target()).unwrap();
        }
        assert!(!channels.room());
        let (_app, socket) = socket_pair().await;
        assert!(channels.add(socket, &target()).is_err());
        assert!(channels.close().await);
    }
    #[tokio::test]
    async fn completed_relay_close_cannot_overtake_queued_data() {
        let (sender, mut outgoing) = mpsc::channel(OUTBOUND_FRAMES);
        let mut channels = Channels::new(sender);
        let (mut app, socket) = socket_pair().await;
        channels.add(socket, &target()).unwrap();
        channels.opened(1, true, mux::CHANNEL_WINDOW).unwrap();
        app.write_all(b"last bytes").await.unwrap();
        app.shutdown().await.unwrap();
        tokio::time::sleep(Duration::from_millis(30)).await;
        assert!(channels.reap().await.is_empty());
        let (_, data) = outgoing.recv().await.unwrap();
        assert!(channels.may_send(&data));
        assert!(matches!(
            data.port_forward_channel().union,
            Some(port_forward_channel::Union::Data(_))
        ));
        let (_, close) = outgoing.recv().await.unwrap();
        assert!(channels.may_send(&close));
        assert!(matches!(
            close.port_forward_channel().union,
            Some(port_forward_channel::Union::Close(_))
        ));
        channels.sent(&close);
        channels.reap().await;
        assert!(channels.values.is_empty());
    }
}
