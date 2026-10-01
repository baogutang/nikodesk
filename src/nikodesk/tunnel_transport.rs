//! Niko controlled-side TCP transport. This module neither authenticates a
//! peer, approves a target, binds a listener, nor enables the product policy.
//!
//! The actor supplies the actual approved endpoint/ticket and rechecks its
//! namespace/policy before dispatch. Channel tasks use the stock wire/window
//! core but never its direct outbound sink: every queued frame crosses this
//! owner's ticket/cancellation gate before reaching the connection writer.
use super::{
    capability_state::{Capabilities, Scope, Ticket},
    tunnel_endpoint::{PinnedEndpoint, Target},
};
use crate::port_forward_mux::{
    opened_msg, run_channel, FrameSink, Inbound, RecvWindow, SendCredit, CHANNEL_WINDOW,
    DATA_QUEUE_FRAMES, INITIAL_WINDOW, MAX_CHANNELS, MAX_FRAME,
};
use base::message_proto::{message, port_forward_channel, Message, PortForwardChannel};
use hbb_common::tokio::{
    self,
    sync::{mpsc, watch},
    task::JoinHandle,
};
use std::{
    collections::BTreeMap,
    sync::{
        atomic::{AtomicBool, AtomicU64, Ordering},
        Arc, Mutex, OnceLock,
    },
    time::{Duration, Instant},
};

const MAX_OWNERS: usize = 16;
const POLL_BATCH: usize = DATA_QUEUE_FRAMES;
const MONITOR_INTERVAL: Duration = Duration::from_millis(50);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Error {
    NotApproved,
    Cancelled,
    StateUnavailable,
    InvalidLimit,
    TooManyOwners,
    AlreadyOwned,
    UnsupportedSink,
    NoRuntime,
    InvalidFrame,
    InvalidChannel,
    ReusedChannel,
    TargetNotApproved,
    TooManyChannels,
    TooManyDials,
    UnknownChannel,
    WindowViolation,
    QueueFull,
    WriterClosed,
    DialFailed,
    TaskUnconfirmed,
}

impl Error {
    pub(crate) fn code(self) -> &'static str {
        match self {
            Self::NotApproved => "tunnel_not_approved",
            Self::Cancelled => "tunnel_cancelled",
            Self::StateUnavailable => "tunnel_state_unavailable",
            Self::InvalidLimit => "tunnel_invalid_limit",
            Self::TooManyOwners => "tunnel_owner_limit",
            Self::AlreadyOwned => "tunnel_ticket_already_owned",
            Self::UnsupportedSink => "tunnel_direct_sink_required",
            Self::NoRuntime => "tunnel_runtime_unavailable",
            Self::InvalidFrame => "tunnel_invalid_frame",
            Self::InvalidChannel => "tunnel_invalid_channel",
            Self::ReusedChannel => "tunnel_channel_reused",
            Self::TargetNotApproved => "tunnel_target_not_approved",
            Self::TooManyChannels => "tunnel_channel_limit",
            Self::TooManyDials => "tunnel_dial_limit",
            Self::UnknownChannel => "tunnel_channel_unknown",
            Self::WindowViolation => "tunnel_window_violation",
            Self::QueueFull => "tunnel_queue_full",
            Self::WriterClosed => "tunnel_writer_closed",
            Self::DialFailed => "tunnel_dial_failed",
            Self::TaskUnconfirmed => "tunnel_task_cleanup_unconfirmed",
        }
    }
}

#[derive(Clone, Copy, Debug)]
pub(crate) struct Limits {
    pub(crate) channels: usize,
    pub(crate) pending_dials: usize,
}

impl Default for Limits {
    fn default() -> Self {
        Self {
            channels: 16,
            pending_dials: 4,
        }
    }
}

impl Limits {
    fn checked(self) -> Result<Self, Error> {
        if self.channels == 0
            || self.channels > MAX_CHANNELS
            || self.pending_dials == 0
            || self.pending_dials > self.channels
        {
            return Err(Error::InvalidLimit);
        }
        Ok(self)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Phase {
    Ready,
    Running,
    Stopping,
    Stopped,
    RecoveryRequired,
}

#[derive(Clone, Copy, Debug)]
pub(crate) struct Report {
    pub(crate) phase: Phase,
    /// An actual TCP socket returned from PinnedEndpoint::connect while owned
    /// by a retained task. Approval/activate alone never sets this fact.
    pub(crate) first_socket_owned: bool,
    pub(crate) live_channels: usize,
    pub(crate) pending_dials: usize,
    pub(crate) retained_tasks: usize,
    pub(crate) joined_channels: usize,
    pub(crate) dropped_outbound_frames: usize,
    pub(crate) reason: Option<Error>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Dispatch {
    Opened,
    Delivered,
    Closing,
}

struct Gate {
    state: Arc<Mutex<Capabilities>>,
    ticket: Ticket,
    scope: Scope,
    external_cancel: watch::Receiver<bool>,
    closed: AtomicBool,
    first_socket_owned: AtomicBool,
    stop: watch::Sender<bool>,
    reason: Mutex<Option<Error>>,
}

impl Gate {
    fn cancelled(&self) -> bool {
        self.closed.load(Ordering::SeqCst)
            || *self.external_cancel.borrow()
            || self.external_cancel.has_changed().is_err()
    }

    fn permitted(&self, current: &Capabilities, starting: bool) -> bool {
        self.ticket.scope() == &self.scope
            && !self.cancelled()
            && (current.may_execute(&self.ticket, &self.scope, Instant::now())
                || starting && current.may_start(&self.ticket, Instant::now()))
    }

    fn check(&self, starting: bool) -> Result<(), Error> {
        if self.cancelled() {
            return Err(Error::Cancelled);
        }
        let current = self.state.try_lock().map_err(|_| Error::StateUnavailable)?;
        if self.permitted(&current, starting) {
            Ok(())
        } else {
            Err(Error::NotApproved)
        }
    }

    fn close(&self, reason: Error) {
        self.closed.store(true, Ordering::SeqCst);
        self.stop.send_replace(true);
        if let Ok(mut stored) = self.reason.lock() {
            if stored.is_none() {
                *stored = Some(reason);
            }
        }
    }

    /// The external sink must be direct: sending there is a synchronous queue
    /// commit under the current capability lock, with no await/callback. The
    /// actor must still reject stale frames when its own network queue drains.
    fn submit(&self, sink: &FrameSink, frame: Message) -> Result<(), Error> {
        let starting = matches!(frame.union.as_ref(),
            Some(message::Union::PortForwardChannel(ch)) if matches!(ch.union.as_ref(),
                Some(port_forward_channel::Union::Opened(opened)) if !opened.success));
        let current = self.state.try_lock().map_err(|_| Error::StateUnavailable)?;
        if !self.permitted(&current, starting) {
            return Err(Error::NotApproved);
        }
        match sink {
            FrameSink::Direct(tx) => tx
                .send((tokio::time::Instant::now(), Arc::new(frame)))
                .map_err(|_| Error::WriterClosed),
            FrameSink::BoundedDirect(tx) => tx
                .try_send((tokio::time::Instant::now(), Arc::new(frame)))
                .map_err(|error| match error {
                    mpsc::error::TrySendError::Full(_) => Error::QueueFull,
                    mpsc::error::TrySendError::Closed(_) => Error::WriterClosed,
                }),
            FrameSink::Queued { .. } => Err(Error::UnsupportedSink),
        }
    }
}

struct Entry {
    inbound: Option<mpsc::UnboundedSender<Inbound>>,
    credit: Arc<SendCredit>,
    window: Arc<Mutex<RecvWindow>>,
    dial_cancel: watch::Sender<bool>,
    dialing: Arc<AtomicBool>,
    task: Option<JoinHandle<Result<(), Error>>>,
    closing: bool,
}

struct Inner {
    lease: u64,
    endpoint: PinnedEndpoint,
    gate: Arc<Gate>,
    sink: FrameSink,
    private_sink: FrameSink,
    data_rx: mpsc::Receiver<Message>,
    control_rx: mpsc::UnboundedReceiver<Message>,
    channels: BTreeMap<i32, Entry>,
    monitor: Option<JoinHandle<()>>,
    limits: Limits,
    last_channel_id: i32,
    stopping: bool,
    recovery: bool,
    unconfirmed_task: bool,
    joined: usize,
    dropped: usize,
    control_next: bool,
}

// A bounded process registry retains a dropped owner's complete task/queue
// graph. Drop signals cancellation; it never detaches a live JoinHandle or
// fabricates an ACK. The actor must periodically poll_retired(), including on
// disconnect/CM shutdown. No background reaper is launched and forgotten.
struct RegistrySlot {
    gate: std::sync::Weak<Gate>,
    retired: Option<Box<Inner>>,
}
type Registry = BTreeMap<u64, RegistrySlot>;
static REGISTRY: OnceLock<Mutex<Registry>> = OnceLock::new();
static NEXT_LEASE: AtomicU64 = AtomicU64::new(1);
fn registry() -> &'static Mutex<Registry> {
    REGISTRY.get_or_init(Default::default)
}

pub(crate) struct OwnedMux {
    inner: Option<Inner>,
}

impl OwnedMux {
    pub(crate) fn activate(
        endpoint: PinnedEndpoint,
        state: Arc<Mutex<Capabilities>>,
        ticket: Ticket,
        cancel: watch::Receiver<bool>,
        sink: FrameSink,
        limits: Limits,
    ) -> Result<Self, Error> {
        let limits = limits.checked()?;
        if !matches!(&sink, FrameSink::Direct(_) | FrameSink::BoundedDirect(_)) {
            return Err(Error::UnsupportedSink);
        }
        let runtime = tokio::runtime::Handle::try_current().map_err(|_| Error::NoRuntime)?;
        let (stop, _) = watch::channel(false);
        let gate = Arc::new(Gate {
            state,
            ticket,
            scope: Scope::Tunnel(endpoint.address()),
            external_cancel: cancel,
            closed: AtomicBool::new(false),
            first_socket_owned: AtomicBool::new(false),
            stop,
            reason: Mutex::new(None),
        });
        gate.check(true)?;
        let mut owners = registry().lock().map_err(|_| Error::StateUnavailable)?;
        if owners.len() >= MAX_OWNERS {
            return Err(Error::TooManyOwners);
        }
        if owners
            .values()
            .filter_map(|slot| slot.gate.upgrade())
            .any(|other| Arc::ptr_eq(&other.state, &gate.state) && other.ticket == gate.ticket)
        {
            return Err(Error::AlreadyOwned);
        }
        let lease = NEXT_LEASE
            .fetch_update(Ordering::SeqCst, Ordering::SeqCst, |n| n.checked_add(1))
            .map_err(|_| Error::TooManyOwners)?;
        owners.insert(
            lease,
            RegistrySlot {
                gate: Arc::downgrade(&gate),
                retired: None,
            },
        );
        drop(owners);
        let (data, data_rx) = mpsc::channel(DATA_QUEUE_FRAMES);
        let (control, control_rx) = mpsc::unbounded_channel();
        let monitor_gate = gate.clone();
        let monitor = runtime.spawn(async move {
            let mut external = monitor_gate.external_cancel.clone();
            let mut stop = monitor_gate.stop.subscribe();
            let mut timer = tokio::time::interval(MONITOR_INTERVAL);
            loop {
                if let Err(error) = monitor_gate.check(true) {
                    monitor_gate.close(error);
                    return;
                }
                tokio::select! {
                    biased;
                    _ = stop.changed() => return,
                    _ = external.changed() => { monitor_gate.close(Error::Cancelled); return; },
                    _ = timer.tick() => {},
                }
            }
        });
        Ok(Self {
            inner: Some(Inner {
                lease,
                endpoint,
                gate,
                sink,
                private_sink: FrameSink::Queued { data, control },
                data_rx,
                control_rx,
                channels: BTreeMap::new(),
                monitor: Some(monitor),
                limits,
                last_channel_id: 0,
                stopping: false,
                recovery: false,
                unconfirmed_task: false,
                joined: 0,
                dropped: 0,
                control_next: true,
            }),
        })
    }

    pub(crate) fn handle_message(
        &mut self,
        expected: &Ticket,
        message: Message,
    ) -> Result<Dispatch, Error> {
        let inner = self.inner.as_mut().ok_or(Error::Cancelled)?;
        if &inner.gate.ticket != expected {
            return Err(Error::NotApproved);
        }
        let frame = match message.union {
            Some(message::Union::PortForwardChannel(frame)) => frame,
            _ => return Err(Error::InvalidFrame),
        };
        inner.handle(frame)
    }

    /// Drive this from the owning actor. It forwards at most one bounded batch,
    /// then joins only tasks that have actually finished; it never blocks on an
    /// active task or infers release from a timeout/closed queue.
    pub(crate) async fn poll(&mut self) -> Report {
        self.inner
            .as_mut()
            .expect("owned mux consumed")
            .poll(false)
            .await
    }

    pub(crate) fn begin_stop(&mut self) {
        if let Some(inner) = self.inner.as_mut() {
            inner.begin_stop(Error::Cancelled);
        }
    }

    pub(crate) fn owner_lease(&self) -> u64 {
        self.inner.as_ref().expect("owned mux consumed").lease
    }

    /// A caller's UI/actor deadline may mark Recovery, but cannot release any
    /// unfinished handle. Keep polling/retrying this same owner until Stopped.
    pub(crate) async fn stop_poll(&mut self) -> Report {
        let inner = self.inner.as_mut().expect("owned mux consumed");
        inner.begin_stop(Error::Cancelled);
        inner.poll(false).await
    }

    pub(crate) fn mark_cleanup_unconfirmed(&mut self) {
        if let Some(inner) = self.inner.as_mut() {
            inner.begin_stop(Error::Cancelled);
            if !inner.confirmed_stopped() {
                inner.recovery = true;
            }
        }
    }
}

impl Drop for OwnedMux {
    fn drop(&mut self) {
        let Some(mut inner) = self.inner.take() else {
            return;
        };
        inner.begin_stop(Error::Cancelled);
        // A poisoned registry must not discard live task ownership. Mutex
        // poison means a previous panic, not that the stored map ceased to exist.
        let mut owners = registry().lock().unwrap_or_else(|e| e.into_inner());
        if inner.confirmed_stopped() {
            owners.remove(&inner.lease);
        } else {
            owners.insert(
                inner.lease,
                RegistrySlot {
                    gate: Arc::downgrade(&inner.gate),
                    retired: Some(Box::new(inner)),
                },
            );
        }
    }
}

#[derive(Clone, Debug)]
pub(crate) struct RetiredReport {
    pub(crate) pending_leases: Vec<u64>,
    pub(crate) stopped_leases: Vec<u64>,
}

pub(crate) async fn poll_retired() -> RetiredReport {
    let work: Vec<OwnedMux> = {
        let mut owners = registry().lock().unwrap_or_else(|e| e.into_inner());
        owners
            .values_mut()
            .filter_map(|slot| slot.retired.take())
            .map(|inner| OwnedMux {
                inner: Some(*inner),
            })
            .collect()
    };
    let mut pending_leases = Vec::new();
    let mut stopped_leases = Vec::new();
    for mut owner in work {
        let lease = owner.owner_lease();
        owner.mark_cleanup_unconfirmed();
        let report = owner.stop_poll().await;
        if report.phase == Phase::Stopped {
            stopped_leases.push(lease);
        } else {
            pending_leases.push(lease);
        }
        // Even cancellation of this async function runs OwnedMux::drop for all
        // remaining work and puts every unfinished owner back in the registry.
    }
    RetiredReport {
        pending_leases,
        stopped_leases,
    }
}

impl Inner {
    fn handle(&mut self, frame: PortForwardChannel) -> Result<Dispatch, Error> {
        if self.stopping {
            return Err(Error::Cancelled);
        }
        let opening = matches!(&frame.union, Some(port_forward_channel::Union::Open(_)));
        if let Err(error) = self.gate.check(opening) {
            // Data is forbidden in Starting: the Niko controller must wait for
            // Opened success rather than stock's speculative INITIAL_WINDOW.
            if error != Error::NotApproved || opening {
                self.begin_stop(error);
            }
            return Err(error);
        }
        match frame.union {
            Some(port_forward_channel::Union::Open(open)) => {
                let id = open.channel_id;
                if id <= 0 {
                    return Err(Error::InvalidChannel);
                }
                if id <= self.last_channel_id {
                    return Err(Error::ReusedChannel);
                }
                let target =
                    Target::parse(&open.host, open.port).map_err(|_| Error::TargetNotApproved)?;
                if &target != self.endpoint.target() {
                    return Err(Error::TargetNotApproved);
                }
                if self.channels.len() >= self.limits.channels {
                    return Err(Error::TooManyChannels);
                }
                if self
                    .channels
                    .values()
                    .filter(|e| e.dialing.load(Ordering::SeqCst))
                    .count()
                    >= self.limits.pending_dials
                {
                    return Err(Error::TooManyDials);
                }
                let credit = Arc::new(SendCredit::new(open.window.max(INITIAL_WINDOW)));
                let window = Arc::new(Mutex::new(RecvWindow::new(INITIAL_WINDOW)));
                let (inbound, inbound_rx) = mpsc::unbounded_channel();
                let (dial_cancel, dial_rx) = watch::channel(false);
                let dialing = Arc::new(AtomicBool::new(true));
                let task = tokio::spawn(controlled_channel(
                    id,
                    self.endpoint.clone(),
                    self.gate.clone(),
                    credit.clone(),
                    window.clone(),
                    inbound_rx,
                    self.private_sink.clone(),
                    dial_rx,
                    dialing.clone(),
                ));
                self.channels.insert(
                    id,
                    Entry {
                        inbound: Some(inbound),
                        credit,
                        window,
                        dial_cancel,
                        dialing,
                        task: Some(task),
                        closing: false,
                    },
                );
                self.last_channel_id = id;
                Ok(Dispatch::Opened)
            }
            Some(port_forward_channel::Union::Data(data)) => {
                if data.data.is_empty() || data.data.len() > MAX_FRAME {
                    return Err(Error::InvalidFrame);
                }
                let entry = self
                    .channels
                    .get_mut(&data.channel_id)
                    .ok_or(Error::UnknownChannel)?;
                if entry.closing {
                    return Err(Error::UnknownChannel);
                }
                let accepted = entry
                    .window
                    .lock()
                    .map_err(|_| Error::StateUnavailable)?
                    .accept(data.data.len());
                if !accepted {
                    Self::close_entry(entry);
                    return Err(Error::WindowViolation);
                }
                entry
                    .inbound
                    .as_ref()
                    .ok_or(Error::UnknownChannel)?
                    .send(Inbound::Data(data.data))
                    .map_err(|_| Error::UnknownChannel)?;
                Ok(Dispatch::Delivered)
            }
            Some(port_forward_channel::Union::WindowUpdate(update)) => {
                if update.add == 0 || update.add > CHANNEL_WINDOW {
                    return Err(Error::WindowViolation);
                }
                let entry = self
                    .channels
                    .get(&update.channel_id)
                    .ok_or(Error::UnknownChannel)?;
                if entry.closing {
                    return Err(Error::UnknownChannel);
                }
                entry.credit.add(update.add);
                Ok(Dispatch::Delivered)
            }
            Some(port_forward_channel::Union::Close(close)) => {
                let entry = self
                    .channels
                    .get_mut(&close.channel_id)
                    .ok_or(Error::UnknownChannel)?;
                Self::close_entry(entry);
                Ok(Dispatch::Closing)
            }
            _ => Err(Error::InvalidFrame),
        }
    }

    fn close_entry(entry: &mut Entry) {
        entry.closing = true;
        entry.dial_cancel.send_replace(true);
        if let Some(inbound) = entry.inbound.take() {
            let _ = inbound.send(Inbound::Close);
        }
    }

    fn begin_stop(&mut self, reason: Error) {
        self.gate.close(reason); // synchronous execution/publication cutoff first
        self.stopping = true;
        self.data_rx.close();
        self.control_rx.close();
        while self.data_rx.try_recv().is_ok() {
            self.dropped += 1;
        }
        while self.control_rx.try_recv().is_ok() {
            self.dropped += 1;
        }
        for entry in self.channels.values_mut() {
            Self::close_entry(entry);
        }
    }

    fn confirmed_stopped(&self) -> bool {
        self.stopping
            && self.channels.is_empty()
            && self.monitor.is_none()
            && !self.unconfirmed_task
            && self.data_rx.is_empty()
            && self.control_rx.is_empty()
    }

    async fn poll(&mut self, deadline_unconfirmed: bool) -> Report {
        if !self.stopping {
            if let Err(error) = self.gate.check(true) {
                self.begin_stop(error);
            }
        }
        if !self.stopping {
            for _ in 0..POLL_BATCH {
                // Both directions need progress under saturation. A permanent
                // control-first order can starve target Data; alternating still
                // lets window updates bypass bulk Data without starving either.
                let frame = if self.control_next {
                    self.control_rx
                        .try_recv()
                        .ok()
                        .or_else(|| self.data_rx.try_recv().ok())
                } else {
                    self.data_rx
                        .try_recv()
                        .ok()
                        .or_else(|| self.control_rx.try_recv().ok())
                };
                self.control_next = !self.control_next;
                let Some(frame) = frame else {
                    break;
                };
                let id = frame_channel_id(&frame);
                if id
                    .and_then(|id| self.channels.get(&id))
                    .map_or(true, |e| e.closing)
                {
                    self.dropped += 1;
                    continue;
                }
                if let Err(error) = self.gate.submit(&self.sink, frame) {
                    self.dropped += 1;
                    self.begin_stop(error);
                    break;
                }
            }
        }
        let finished: Vec<_> = self
            .channels
            .iter()
            .filter_map(|(id, entry)| {
                entry
                    .task
                    .as_ref()
                    .filter(|task| task.is_finished())
                    .map(|_| *id)
            })
            .collect();
        for id in finished {
            // A finished producer may have queued its final Data/Close after
            // this poll's bounded drain. Keep its identity reachable until the
            // queues are empty so its final bytes are not silently discarded.
            if !self.stopping && (!self.data_rx.is_empty() || !self.control_rx.is_empty()) {
                break;
            }
            let entry = self.channels.get_mut(&id).expect("selected channel exists");
            let task = entry.task.take().expect("finished task retained");
            match task.await {
                Ok(_) => {
                    self.channels.remove(&id);
                    self.joined += 1;
                }
                Err(_) => {
                    // A panic could have unwound stock run_channel before its
                    // nested joins. Do not call that unknown resource release.
                    self.unconfirmed_task = true;
                    self.begin_stop(Error::TaskUnconfirmed);
                }
            }
        }
        if self
            .monitor
            .as_ref()
            .map_or(false, |task| task.is_finished())
        {
            if self
                .monitor
                .take()
                .expect("finished monitor retained")
                .await
                .is_err()
            {
                self.unconfirmed_task = true;
                self.begin_stop(Error::TaskUnconfirmed);
            }
        }
        if self.stopping {
            // Closing receivers wakes a shared relay blocked on bounded send.
            // Retained producers may race their final failed send; drain again.
            while self.data_rx.try_recv().is_ok() {
                self.dropped += 1;
            }
            while self.control_rx.try_recv().is_ok() {
                self.dropped += 1;
            }
            if deadline_unconfirmed && !self.confirmed_stopped() {
                self.recovery = true;
            }
        }
        self.report()
    }

    fn report(&self) -> Report {
        Report {
            phase: if self.confirmed_stopped() {
                Phase::Stopped
            } else if self.stopping && (self.recovery || self.unconfirmed_task) {
                Phase::RecoveryRequired
            } else if self.stopping {
                Phase::Stopping
            } else if self.gate.first_socket_owned.load(Ordering::SeqCst) {
                Phase::Running
            } else {
                Phase::Ready
            },
            first_socket_owned: self.gate.first_socket_owned.load(Ordering::SeqCst),
            live_channels: self.channels.len(),
            pending_dials: self
                .channels
                .values()
                .filter(|e| e.dialing.load(Ordering::SeqCst))
                .count(),
            retained_tasks: self.channels.values().filter(|e| e.task.is_some()).count()
                + usize::from(self.monitor.is_some()),
            joined_channels: self.joined,
            dropped_outbound_frames: self.dropped,
            reason: self.gate.reason.lock().ok().and_then(|r| *r),
        }
    }
}

fn frame_channel_id(frame: &Message) -> Option<i32> {
    let Some(message::Union::PortForwardChannel(channel)) = frame.union.as_ref() else {
        return None;
    };
    match channel.union.as_ref()? {
        port_forward_channel::Union::Open(open) => Some(open.channel_id),
        port_forward_channel::Union::Opened(opened) => Some(opened.channel_id),
        port_forward_channel::Union::Data(data) => Some(data.channel_id),
        port_forward_channel::Union::Close(close) => Some(close.channel_id),
        port_forward_channel::Union::WindowUpdate(update) => Some(update.channel_id),
        // The wire enum belongs to base and is non-exhaustive. Future variants
        // have no approved channel identity and must not be published.
        _ => None,
    }
}

async fn controlled_channel(
    id: i32,
    endpoint: PinnedEndpoint,
    gate: Arc<Gate>,
    credit: Arc<SendCredit>,
    window: Arc<Mutex<RecvWindow>>,
    inbound: mpsc::UnboundedReceiver<Inbound>,
    sink: FrameSink,
    dial_cancel: watch::Receiver<bool>,
    dialing: Arc<AtomicBool>,
) -> Result<(), Error> {
    let mut stop = gate.stop.subscribe();
    if *stop.borrow() {
        dialing.store(false, Ordering::SeqCst);
        return Err(Error::Cancelled);
    }
    let result = tokio::select! {
        biased;
        _ = stop.changed() => Err(Error::Cancelled),
        result = endpoint.connect(&gate.state, &gate.ticket, dial_cancel) =>
            result.map_err(|_| Error::DialFailed),
    };
    dialing.store(false, Ordering::SeqCst);
    let socket = match result {
        Ok(socket) => socket,
        Err(error) => {
            // A failed dial owns no FD. A reply is only queued; poll rechecks
            // the current ticket before delivering even this error frame.
            let _ = sink
                .send_ordered(opened_msg(id, false, error.code(), 0))
                .await;
            return Err(error);
        }
    };
    gate.check(false)?;
    gate.first_socket_owned.store(true, Ordering::SeqCst);
    window
        .lock()
        .map_err(|_| Error::StateUnavailable)?
        .grant(CHANNEL_WINDOW - INITIAL_WINDOW);
    sink.send_ordered(opened_msg(id, true, "", CHANNEL_WINDOW))
        .await
        .map_err(|_| Error::WriterClosed)?;
    gate.check(false)?;
    let (reader, writer) = socket.into_split();
    // Never select/drop this future on cancellation: run_channel owns its two
    // real child handles and joins both when the level-triggered stop changes.
    run_channel(
        id,
        reader,
        writer,
        Vec::new(),
        Vec::new(),
        credit,
        window,
        inbound,
        sink,
        stop,
    )
    .await;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::super::{
        capability_state::{Binding, Kind},
        tunnel_endpoint::LocalPolicy,
    };
    use super::*;
    use crate::port_forward_mux::{close_msg, data_msg, open_msg, window_update_msg};
    use hbb_common::{bytes::Bytes, protobuf::Message as _};
    use tokio::{
        io::{AsyncReadExt, AsyncWriteExt},
        net::{TcpListener, TcpStream},
    };

    type Output = mpsc::UnboundedReceiver<(tokio::time::Instant, Arc<Message>)>;
    struct Fixture {
        target: TcpListener,
        state: Arc<Mutex<Capabilities>>,
        ticket: Ticket,
        endpoint: PinnedEndpoint,
        cancel: watch::Sender<bool>,
        cancel_rx: watch::Receiver<bool>,
    }
    async fn fixture(named: bool) -> Fixture {
        let target = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = target.local_addr().unwrap();
        let resolution = Target::parse(
            if named { "localhost" } else { "127.0.0.1" },
            i32::from(address.port()),
        )
        .unwrap()
        .resolve()
        .await
        .unwrap();
        let scope = resolution
            .select(address, LocalPolicy::LoopbackOnly)
            .unwrap();
        let mut state = Capabilities::new(
            Binding::new("a".repeat(64), "123456789".into(), [1; 16]).unwrap(),
            true,
            true,
        );
        state.set_policy(Kind::Tunnel, true, true).unwrap();
        let request = state.request(scope, [2; 16], Instant::now()).unwrap();
        let ticket = state
            .approve(&request, Instant::now(), Duration::from_secs(60))
            .unwrap();
        let endpoint = resolution.for_ticket(&ticket).unwrap();
        let (cancel, cancel_rx) = watch::channel(false);
        Fixture {
            target,
            state: Arc::new(Mutex::new(state)),
            ticket,
            endpoint,
            cancel,
            cancel_rx,
        }
    }
    fn owner(f: &Fixture, limits: Limits) -> (OwnedMux, Output) {
        let (tx, rx) = mpsc::unbounded_channel();
        (
            OwnedMux::activate(
                f.endpoint.clone(),
                f.state.clone(),
                f.ticket.clone(),
                f.cancel_rx.clone(),
                FrameSink::Direct(tx),
                limits,
            )
            .unwrap(),
            rx,
        )
    }
    fn open(f: &Fixture, id: i32) -> Message {
        open_msg(
            id,
            f.endpoint.target().host(),
            i32::from(f.endpoint.target().port()),
            CHANNEL_WINDOW,
        )
    }
    async fn next(owner: &mut OwnedMux, output: &mut Output) -> Message {
        let deadline = Instant::now() + Duration::from_secs(2);
        loop {
            owner.poll().await;
            if let Ok((_, message)) = output.try_recv() {
                // Use the actual production protobuf encoder/parser, not a
                // hand-written tunnel fixture or replacement wire protocol.
                return Message::parse_from_bytes(&message.write_to_bytes().unwrap()).unwrap();
            }
            assert!(Instant::now() < deadline, "real mux frame deadline");
            tokio::time::sleep(Duration::from_millis(1)).await;
        }
    }
    async fn connected(
        f: &Fixture,
        owner: &mut OwnedMux,
        output: &mut Output,
        id: i32,
    ) -> TcpStream {
        assert_eq!(
            owner.handle_message(&f.ticket, open(f, id)),
            Ok(Dispatch::Opened)
        );
        let (peer, _) = tokio::time::timeout(Duration::from_secs(2), f.target.accept())
            .await
            .unwrap()
            .unwrap();
        let message = next(owner, output).await;
        let Some(message::Union::PortForwardChannel(channel)) = message.union else {
            panic!("wrong frame")
        };
        let Some(port_forward_channel::Union::Opened(opened)) = channel.union else {
            panic!("not opened")
        };
        assert!(opened.success);
        assert_eq!(opened.channel_id, id);
        peer
    }
    async fn stopped(owner: &mut OwnedMux) -> Report {
        let deadline = Instant::now() + Duration::from_secs(2);
        loop {
            let report = owner.stop_poll().await;
            if report.phase == Phase::Stopped {
                assert_eq!(report.retained_tasks, 0);
                assert_eq!(report.live_channels, 0);
                return report;
            }
            assert!(Instant::now() < deadline, "real native stop/join deadline");
            tokio::time::sleep(Duration::from_millis(1)).await;
        }
    }
    async fn eof(peer: &mut TcpStream) {
        let mut rest = Vec::new();
        let closed = tokio::time::timeout(Duration::from_secs(2), peer.read_to_end(&mut rest))
            .await
            .unwrap();
        // A socket closed with unread pending TCP bytes produces a real RST.
        // Both EOF and this precise OS error prove the connection ended; an
        // unrelated I/O error is not accepted as resource release evidence.
        assert!(
            closed.is_ok()
                || matches!(closed, Err(ref error)
            if error.kind()==std::io::ErrorKind::ConnectionReset)
        );
    }

    #[tokio::test(flavor = "current_thread")]
    async fn activation_has_no_socket_or_running_ack_and_pending_old_ticket_is_denied() {
        let f = fixture(false).await;
        let (mut owner, mut output) = owner(&f, Limits::default());
        let report = owner.poll().await;
        assert_eq!(report.phase, Phase::Ready);
        assert!(!report.first_socket_owned);
        assert_eq!(
            f.state.lock().unwrap().phase(Kind::Tunnel),
            crate::nikodesk::capability_state::Phase::Starting
        );
        assert!(
            tokio::time::timeout(Duration::from_millis(20), f.target.accept())
                .await
                .is_err()
        );
        assert!(output.try_recv().is_err());
        let stop = f
            .state
            .lock()
            .unwrap()
            .revoke(Kind::Tunnel)
            .unwrap()
            .unwrap();
        stopped(&mut owner).await;
        f.state.lock().unwrap().did_stop(&stop, true).unwrap();
        let _pending = f
            .state
            .lock()
            .unwrap()
            .request(Scope::Tunnel(f.endpoint.address()), [3; 16], Instant::now())
            .unwrap();
        let (tx, _) = mpsc::unbounded_channel();
        assert!(matches!(
            OwnedMux::activate(
                f.endpoint.clone(),
                f.state.clone(),
                f.ticket.clone(),
                f.cancel_rx.clone(),
                FrameSink::Direct(tx),
                Limits::default()
            ),
            Err(Error::NotApproved)
        ));
        assert!(
            tokio::time::timeout(Duration::from_millis(20), f.target.accept())
                .await
                .is_err()
        );
    }

    #[tokio::test(flavor = "current_thread")]
    async fn exact_named_snapshot_dials_pinned_ip_and_rejects_remote_retarget() {
        let f = fixture(true).await;
        let (mut owner, mut output) = owner(&f, Limits::default());
        for (host, port) in [
            ("127.0.0.2", i32::from(f.endpoint.address().port())),
            ("localhost", 0),
            ("RDP", 0),
            ("localhost", 1),
        ] {
            assert_eq!(
                owner.handle_message(&f.ticket, open_msg(1, host, port, CHANNEL_WINDOW)),
                Err(Error::TargetNotApproved)
            );
        }
        assert!(
            tokio::time::timeout(Duration::from_millis(20), f.target.accept())
                .await
                .is_err()
        );
        let mut peer = connected(&f, &mut owner, &mut output, 1).await;
        assert_eq!(peer.local_addr().unwrap(), f.endpoint.address());
        let report = owner.poll().await;
        assert_eq!(report.phase, Phase::Running);
        assert!(report.first_socket_owned);
        assert!(f
            .state
            .lock()
            .unwrap()
            .may_execute(&f.ticket, f.ticket.scope(), Instant::now()));
        stopped(&mut owner).await;
        eof(&mut peer).await;
    }

    #[tokio::test(flavor = "current_thread")]
    async fn real_protobuf_duplex_frames_use_shared_native_window_and_relay() {
        let f = fixture(false).await;
        let (mut owner, mut output) = owner(&f, Limits::default());
        let mut peer = connected(&f, &mut owner, &mut output, 1).await;
        assert_eq!(
            owner.handle_message(&f.ticket, data_msg(1, Bytes::from_static(b"request"))),
            Ok(Dispatch::Delivered)
        );
        let mut request = [0; 7];
        tokio::time::timeout(Duration::from_secs(2), peer.read_exact(&mut request))
            .await
            .unwrap()
            .unwrap();
        assert_eq!(&request, b"request");
        peer.write_all(b"response").await.unwrap();
        let message = next(&mut owner, &mut output).await;
        let Some(message::Union::PortForwardChannel(channel)) = message.union else {
            panic!("wrong frame")
        };
        let Some(port_forward_channel::Union::Data(data)) = channel.union else {
            panic!("wrong payload")
        };
        assert_eq!(data.channel_id, 1);
        assert_eq!(data.data.as_ref(), b"response");
        let report = stopped(&mut owner).await;
        assert_eq!(report.joined_channels, 1);
        eof(&mut peer).await;
    }

    #[tokio::test(flavor = "current_thread")]
    async fn first_payload_and_window_require_actual_opened_start_ack() {
        let f = fixture(false).await;
        let (mut owner, mut output) = owner(&f, Limits::default());
        assert_eq!(
            owner.handle_message(&f.ticket, open(&f, 1)),
            Ok(Dispatch::Opened)
        );
        assert_eq!(
            owner.handle_message(&f.ticket, data_msg(1, Bytes::from_static(b"early"))),
            Err(Error::NotApproved)
        );
        assert_eq!(
            owner.handle_message(&f.ticket, window_update_msg(1, 64)),
            Err(Error::NotApproved)
        );
        let (mut peer, _) = f.target.accept().await.unwrap();
        let _ = next(&mut owner, &mut output).await;
        assert!(owner.poll().await.first_socket_owned);
        assert!(
            tokio::time::timeout(Duration::from_millis(20), peer.read(&mut [0; 5]))
                .await
                .is_err()
        );
        stopped(&mut owner).await;
        eof(&mut peer).await;
    }

    #[tokio::test(flavor = "current_thread")]
    async fn cancellation_before_dial_poll_creates_no_target_socket_and_joins() {
        let f = fixture(false).await;
        let (mut owner, _output) = owner(&f, Limits::default());
        owner.handle_message(&f.ticket, open(&f, 1)).unwrap();
        assert_eq!(owner.inner.as_ref().unwrap().channels.len(), 1);
        owner.begin_stop();
        let report = stopped(&mut owner).await;
        assert!(!report.first_socket_owned);
        assert_eq!(report.joined_channels, 1);
        assert!(
            tokio::time::timeout(Duration::from_millis(20), f.target.accept())
                .await
                .is_err()
        );
    }

    #[tokio::test(flavor = "current_thread")]
    async fn revoke_cancels_both_live_directions_and_drops_queued_publication() {
        let f = fixture(false).await;
        let (mut owner, mut output) = owner(&f, Limits::default());
        let mut peer = connected(&f, &mut owner, &mut output, 1).await;
        peer.write_all(b"queued_before_revoke").await.unwrap();
        tokio::time::sleep(Duration::from_millis(5)).await;
        let stop = f
            .state
            .lock()
            .unwrap()
            .revoke(Kind::Tunnel)
            .unwrap()
            .unwrap();
        f.cancel.send_replace(true);
        assert!(owner
            .handle_message(&f.ticket, data_msg(1, Bytes::from_static(b"late")))
            .is_err());
        let report = stopped(&mut owner).await;
        assert!(report.dropped_outbound_frames > 0);
        assert!(output.try_recv().is_err());
        let mut late = Vec::new();
        tokio::time::timeout(Duration::from_secs(2), peer.read_to_end(&mut late))
            .await
            .unwrap()
            .unwrap();
        assert!(late.is_empty());
        // Only the actor's original StopTicket can update its capability slot.
        f.state.lock().unwrap().did_stop(&stop, true).unwrap();
    }

    #[tokio::test(flavor = "current_thread")]
    async fn dropped_cancel_sender_fails_closed_and_releases_real_fd() {
        let Fixture {
            target,
            state,
            ticket,
            endpoint,
            cancel,
            cancel_rx,
        } = fixture(false).await;
        let (tx, mut output) = mpsc::unbounded_channel();
        let mut owner = OwnedMux::activate(
            endpoint.clone(),
            state,
            ticket.clone(),
            cancel_rx,
            FrameSink::Direct(tx),
            Limits::default(),
        )
        .unwrap();
        owner
            .handle_message(
                &ticket,
                open_msg(
                    1,
                    endpoint.target().host(),
                    i32::from(endpoint.target().port()),
                    CHANNEL_WINDOW,
                ),
            )
            .unwrap();
        let (mut peer, _) = target.accept().await.unwrap();
        let _ = next(&mut owner, &mut output).await;
        drop(cancel);
        stopped(&mut owner).await;
        eof(&mut peer).await;
    }

    #[tokio::test(flavor = "current_thread")]
    async fn limits_bound_channels_and_pending_dials_before_any_fd() {
        let f = fixture(false).await;
        let (mut owner, _) = owner(
            &f,
            Limits {
                channels: 2,
                pending_dials: 1,
            },
        );
        owner.handle_message(&f.ticket, open(&f, 1)).unwrap();
        assert_eq!(
            owner.handle_message(&f.ticket, open(&f, 2)),
            Err(Error::TooManyDials)
        );
        assert_eq!(
            owner.handle_message(&f.ticket, open(&f, 1)),
            Err(Error::ReusedChannel)
        );
        let report = stopped(&mut owner).await;
        assert_eq!(report.joined_channels, 1);
        for limits in [
            Limits {
                channels: 0,
                pending_dials: 1,
            },
            Limits {
                channels: MAX_CHANNELS + 1,
                pending_dials: 1,
            },
            Limits {
                channels: 1,
                pending_dials: 2,
            },
        ] {
            assert_eq!(limits.checked().unwrap_err(), Error::InvalidLimit);
        }
    }

    #[tokio::test(flavor = "current_thread")]
    async fn wrong_ticket_duplicate_owner_and_reused_channel_cannot_execute() {
        let f = fixture(false).await;
        let other = fixture(false).await;
        let (mut owner, mut output) = owner(&f, Limits::default());
        assert_eq!(
            owner.handle_message(&other.ticket, open(&f, 1)),
            Err(Error::NotApproved)
        );
        let (tx, _) = mpsc::unbounded_channel();
        assert!(matches!(
            OwnedMux::activate(
                f.endpoint.clone(),
                f.state.clone(),
                f.ticket.clone(),
                f.cancel_rx.clone(),
                FrameSink::Direct(tx),
                Limits::default()
            ),
            Err(Error::AlreadyOwned)
        ));
        let mut peer = connected(&f, &mut owner, &mut output, 1).await;
        owner.handle_message(&f.ticket, close_msg(1)).unwrap();
        for _ in 0..10 {
            owner.poll().await;
            tokio::task::yield_now().await;
        }
        assert_eq!(
            owner.handle_message(&f.ticket, open(&f, 1)),
            Err(Error::ReusedChannel)
        );
        stopped(&mut owner).await;
        eof(&mut peer).await;
    }

    #[tokio::test(flavor = "current_thread")]
    async fn unknown_and_absent_wire_payloads_are_rejected_by_actual_dispatch() {
        let f = fixture(false).await;
        let (mut owner, mut output) = owner(&f, Limits::default());
        let mut peer = connected(&f, &mut owner, &mut output, 1).await;
        // Field 99 is unknown to the actual current protobuf schema. Parsing
        // preserves it as unknown fields and yields no accepted channel union.
        let unknown = PortForwardChannel::parse_from_bytes(&[0x98, 0x06, 0x01]).unwrap();
        assert!(unknown.union.is_none());
        let mut unknown_message = Message::new();
        unknown_message.set_port_forward_channel(unknown);
        let mut absent_channel = Message::new();
        absent_channel.set_port_forward_channel(PortForwardChannel::new());
        for message in [
            Message::new(),
            absent_channel,
            unknown_message.clone(),
            opened_msg(1, true, "", CHANNEL_WINDOW),
        ] {
            let encoded = message.write_to_bytes().unwrap();
            let decoded = Message::parse_from_bytes(&encoded).unwrap();
            assert_eq!(
                owner.handle_message(&f.ticket, decoded),
                Err(Error::InvalidFrame)
            );
        }
        // Exercise the production publication path as well: an unidentified
        // queued frame must not inherit an existing approved channel's ID.
        owner
            .inner
            .as_ref()
            .unwrap()
            .private_sink
            .send_control(unknown_message)
            .unwrap();
        let report = owner.poll().await;
        assert_eq!(report.phase, Phase::Running);
        assert_eq!(report.live_channels, 1);
        assert_eq!(report.dropped_outbound_frames, 1);
        assert!(output.try_recv().is_err());
        assert!(
            tokio::time::timeout(Duration::from_millis(20), peer.read_u8())
                .await
                .is_err()
        );
        assert!(
            tokio::time::timeout(Duration::from_millis(20), f.target.accept())
                .await
                .is_err()
        );
        stopped(&mut owner).await;
        eof(&mut peer).await;
    }

    #[tokio::test(flavor = "current_thread")]
    async fn data_frame_and_recv_window_limits_are_not_native_writes() {
        let f = fixture(false).await;
        let (mut owner, mut output) = owner(&f, Limits::default());
        let mut peer = connected(&f, &mut owner, &mut output, 1).await;
        assert_eq!(
            owner.handle_message(&f.ticket, data_msg(1, Bytes::new())),
            Err(Error::InvalidFrame)
        );
        assert_eq!(
            owner.handle_message(&f.ticket, data_msg(1, Bytes::from(vec![0; MAX_FRAME + 1]))),
            Err(Error::InvalidFrame)
        );
        assert_eq!(
            owner.handle_message(&f.ticket, window_update_msg(1, CHANNEL_WINDOW + 1)),
            Err(Error::WindowViolation)
        );
        for _ in 0..(CHANNEL_WINDOW as usize / MAX_FRAME) {
            owner
                .handle_message(&f.ticket, data_msg(1, Bytes::from(vec![1; MAX_FRAME])))
                .unwrap();
        }
        assert_eq!(
            owner.handle_message(&f.ticket, data_msg(1, Bytes::from_static(b"x"))),
            Err(Error::WindowViolation)
        );
        stopped(&mut owner).await;
        eof(&mut peer).await;
    }

    #[tokio::test(flavor = "current_thread")]
    async fn bounded_send_backpressure_is_released_before_join_ack() {
        let f = fixture(false).await;
        let (mut owner, mut output) = owner(&f, Limits::default());
        let mut peer = connected(&f, &mut owner, &mut output, 1).await;
        for _ in 0..(DATA_QUEUE_FRAMES + 2) {
            peer.write_all(b"x").await.unwrap();
            tokio::time::sleep(Duration::from_millis(2)).await;
        }
        assert_eq!(
            owner.inner.as_ref().unwrap().data_rx.len(),
            DATA_QUEUE_FRAMES
        );
        owner.mark_cleanup_unconfirmed();
        assert_eq!(
            owner.inner.as_ref().unwrap().report().phase,
            Phase::RecoveryRequired
        );
        let report = stopped(&mut owner).await;
        assert_eq!(report.joined_channels, 1);
        assert!(report.dropped_outbound_frames >= DATA_QUEUE_FRAMES);
        assert!(output.try_recv().is_err());
        eof(&mut peer).await;
    }

    #[tokio::test(flavor = "current_thread")]
    async fn producer_finish_preserves_its_last_real_data_before_reaping_identity() {
        let f = fixture(false).await;
        let (mut owner, mut output) = owner(&f, Limits::default());
        let mut peer = connected(&f, &mut owner, &mut output, 1).await;
        peer.write_all(b"last_bytes").await.unwrap();
        peer.shutdown().await.unwrap();
        tokio::time::sleep(Duration::from_millis(5)).await;
        let mut data = Vec::new();
        let deadline = Instant::now() + Duration::from_secs(2);
        loop {
            let report = owner.poll().await;
            while let Ok((_, message)) = output.try_recv() {
                if let Some(message::Union::PortForwardChannel(channel)) = &message.union {
                    if let Some(port_forward_channel::Union::Data(frame)) = &channel.union {
                        data.extend_from_slice(&frame.data);
                    }
                }
            }
            if report.joined_channels == 1 {
                break;
            }
            assert!(Instant::now() < deadline);
            tokio::time::sleep(Duration::from_millis(1)).await;
        }
        assert_eq!(&data, b"last_bytes");
        stopped(&mut owner).await;
    }

    #[tokio::test(flavor = "current_thread")]
    async fn dropped_owner_retains_join_graph_until_actual_retired_cleanup() {
        let f = fixture(false).await;
        let (mut owner, mut output) = owner(&f, Limits::default());
        let mut peer = connected(&f, &mut owner, &mut output, 1).await;
        let lease = owner.inner.as_ref().unwrap().lease;
        drop(owner);
        assert!(registry()
            .lock()
            .unwrap()
            .get(&lease)
            .unwrap()
            .retired
            .is_some());
        let deadline = Instant::now() + Duration::from_secs(2);
        loop {
            let _ = poll_retired().await;
            if !registry().lock().unwrap().contains_key(&lease) {
                break;
            }
            assert!(Instant::now() < deadline);
            tokio::time::sleep(Duration::from_millis(1)).await;
        }
        eof(&mut peer).await;
        assert!(output.try_recv().is_err());
    }

    #[tokio::test(flavor = "current_thread")]
    async fn queued_external_sink_is_rejected_without_new_resource() {
        let f = fixture(false).await;
        let (data, _) = mpsc::channel(1);
        let (control, _) = mpsc::unbounded_channel();
        assert!(matches!(
            OwnedMux::activate(
                f.endpoint.clone(),
                f.state.clone(),
                f.ticket.clone(),
                f.cancel_rx.clone(),
                FrameSink::Queued { data, control },
                Limits::default()
            ),
            Err(Error::UnsupportedSink)
        ));
        assert!(
            tokio::time::timeout(Duration::from_millis(20), f.target.accept())
                .await
                .is_err()
        );
    }

    #[tokio::test(flavor = "current_thread")]
    async fn bounded_native_writer_overflow_stops_and_joins_the_actual_socket() {
        let f = fixture(false).await;
        let (tx, mut output) = mpsc::channel(1);
        tx.try_send((tokio::time::Instant::now(), Arc::new(Message::new()))).unwrap();
        let mut owner = OwnedMux::activate(
            f.endpoint.clone(), f.state.clone(), f.ticket.clone(), f.cancel_rx.clone(),
            FrameSink::BoundedDirect(tx), Limits::default(),
        ).unwrap();
        assert_eq!(owner.handle_message(&f.ticket, open(&f, 1)), Ok(Dispatch::Opened));
        let (mut peer, _) = tokio::time::timeout(Duration::from_secs(2), f.target.accept())
            .await.unwrap().unwrap();
        let deadline = Instant::now() + Duration::from_secs(2);
        loop {
            let report = owner.poll().await;
            assert_eq!(output.len(), 1);
            if report.phase == Phase::Stopped {
                assert_eq!(report.reason, Some(Error::QueueFull));
                assert_eq!(report.retained_tasks, 0);
                assert_eq!(report.live_channels, 0);
                break;
            }
            assert!(Instant::now() < deadline);
            tokio::time::sleep(Duration::from_millis(1)).await;
        }
        eof(&mut peer).await;
        assert!(output.try_recv().is_ok());
        assert!(output.try_recv().is_err());
        assert_eq!(owner.handle_message(&f.ticket, open(&f, 2)), Err(Error::Cancelled));
    }

    #[tokio::test(flavor = "current_thread")]
    async fn bounded_native_writer_keeps_actual_open_ack_before_socket_data() {
        let f = fixture(false).await;
        let (tx, mut output) = mpsc::channel(2);
        let mut owner = OwnedMux::activate(
            f.endpoint.clone(), f.state.clone(), f.ticket.clone(), f.cancel_rx.clone(),
            FrameSink::BoundedDirect(tx), Limits::default(),
        ).unwrap();
        assert_eq!(owner.handle_message(&f.ticket, open(&f, 1)), Ok(Dispatch::Opened));
        let (mut peer, _) = tokio::time::timeout(Duration::from_secs(2), f.target.accept())
            .await.unwrap().unwrap();
        let deadline = Instant::now() + Duration::from_secs(2);
        let opened = loop {
            owner.poll().await;
            if let Ok((_, message)) = output.try_recv() { break message; }
            assert!(Instant::now() < deadline);
            tokio::time::sleep(Duration::from_millis(1)).await;
        };
        assert!(matches!(opened.union.as_ref(),
            Some(message::Union::PortForwardChannel(frame))
            if matches!(frame.union.as_ref(), Some(port_forward_channel::Union::Opened(value))
                if value.channel_id == 1 && value.success)));
        peer.write_all(b"bounded native bytes").await.unwrap();
        let data = loop {
            owner.poll().await;
            if let Ok((_, message)) = output.try_recv() { break message; }
            assert!(Instant::now() < deadline);
            tokio::time::sleep(Duration::from_millis(1)).await;
        };
        assert!(matches!(data.union.as_ref(),
            Some(message::Union::PortForwardChannel(frame))
            if matches!(frame.union.as_ref(), Some(port_forward_channel::Union::Data(value))
                if value.channel_id == 1 && value.data.as_ref() == b"bounded native bytes")));
        f.cancel.send_replace(true);
        assert_eq!(stopped(&mut owner).await.retained_tasks, 0);
        eof(&mut peer).await;
    }

    #[tokio::test(flavor = "current_thread")]
    async fn same_endpoint_new_epoch_refuses_old_ticket_and_old_owner_cannot_stop_new_slot() {
        let f = fixture(false).await;
        let (mut old, mut old_output) = owner(&f, Limits::default());
        let mut old_peer = connected(&f, &mut old, &mut old_output, 1).await;
        let stop = f
            .state
            .lock()
            .unwrap()
            .revoke(Kind::Tunnel)
            .unwrap()
            .unwrap();
        stopped(&mut old).await;
        f.state.lock().unwrap().did_stop(&stop, true).unwrap();
        let request = f
            .state
            .lock()
            .unwrap()
            .request(Scope::Tunnel(f.endpoint.address()), [3; 16], Instant::now())
            .unwrap();
        let ticket = f
            .state
            .lock()
            .unwrap()
            .approve(&request, Instant::now(), Duration::from_secs(60))
            .unwrap();
        let (tx, mut output) = mpsc::unbounded_channel();
        let mut fresh = OwnedMux::activate(
            f.endpoint.clone(),
            f.state.clone(),
            ticket.clone(),
            f.cancel_rx.clone(),
            FrameSink::Direct(tx),
            Limits::default(),
        )
        .unwrap();
        assert_eq!(
            fresh.handle_message(&f.ticket, open(&f, 1)),
            Err(Error::NotApproved)
        );
        assert_eq!(
            fresh.handle_message(&ticket, open(&f, 1)),
            Ok(Dispatch::Opened)
        );
        let (mut peer, _) = f.target.accept().await.unwrap();
        let _ = next(&mut fresh, &mut output).await;
        old.begin_stop();
        assert!(f
            .state
            .lock()
            .unwrap()
            .may_execute(&ticket, ticket.scope(), Instant::now()));
        assert_eq!(
            fresh.handle_message(&f.ticket, data_msg(1, Bytes::from_static(b"stale"))),
            Err(Error::NotApproved)
        );
        assert!(
            tokio::time::timeout(Duration::from_millis(20), peer.read(&mut [0; 5]))
                .await
                .is_err()
        );
        stopped(&mut fresh).await;
        eof(&mut peer).await;
        eof(&mut old_peer).await;
    }

    #[tokio::test(flavor = "current_thread")]
    async fn real_socket_drain_issues_shared_window_update_and_controls_do_not_starve_data() {
        let f = fixture(false).await;
        let (mut owner, mut output) = owner(&f, Limits::default());
        let mut peer = connected(&f, &mut owner, &mut output, 1).await;
        for _ in 0..2 {
            owner
                .handle_message(&f.ticket, data_msg(1, Bytes::from(vec![7; MAX_FRAME])))
                .unwrap();
        }
        let mut received = vec![0; 2 * MAX_FRAME];
        tokio::time::timeout(Duration::from_secs(2), peer.read_exact(&mut received))
            .await
            .unwrap()
            .unwrap();
        assert!(received.iter().all(|byte| *byte == 7));
        let update = next(&mut owner, &mut output).await;
        assert!(
            matches!(update.union, Some(message::Union::PortForwardChannel(ref channel))
            if matches!(channel.union, Some(port_forward_channel::Union::WindowUpdate(ref update)) if update.add==2*MAX_FRAME as u32))
        );
        // Exercise the real FrameSink queues/dispatcher without a fake relay.
        // This synthetic queue fixture checks fairness, not OS throughput.
        let inner = owner.inner.as_ref().unwrap();
        for _ in 0..POLL_BATCH {
            inner
                .private_sink
                .send_control(window_update_msg(1, 64))
                .unwrap();
        }
        inner
            .private_sink
            .send_ordered(data_msg(1, Bytes::from_static(b"fair")))
            .await
            .unwrap();
        owner.poll().await;
        let mut found = false;
        while let Ok((_, message)) = output.try_recv() {
            found |= matches!(message.union, Some(message::Union::PortForwardChannel(ref channel))
                if matches!(channel.union, Some(port_forward_channel::Union::Data(ref data)) if data.data.as_ref()==b"fair"));
        }
        assert!(found);
        stopped(&mut owner).await;
        eof(&mut peer).await;
    }

    #[tokio::test(flavor = "current_thread")]
    async fn synthetic_stalled_join_keeps_same_owner_until_actual_worker_exit() {
        let f = fixture(false).await;
        let (mut owner, _) = owner(&f, Limits::default());
        let (release, waiting) = tokio::sync::oneshot::channel::<()>();
        let (inbound, _) = mpsc::unbounded_channel();
        let (dial_cancel, _) = watch::channel(false);
        // A pure scheduling fixture for a retained worker, not a replacement
        // socket provider. It cannot prove a physical OS shutdown deadline.
        let task = tokio::spawn(async move {
            let _ = waiting.await;
            Ok(())
        });
        owner.inner.as_mut().unwrap().channels.insert(
            1,
            Entry {
                inbound: Some(inbound),
                credit: Arc::new(SendCredit::new(INITIAL_WINDOW)),
                window: Arc::new(Mutex::new(RecvWindow::new(INITIAL_WINDOW))),
                dial_cancel,
                dialing: Arc::new(AtomicBool::new(false)),
                task: Some(task),
                closing: false,
            },
        );
        owner.mark_cleanup_unconfirmed();
        let report = owner.stop_poll().await;
        assert_eq!(report.phase, Phase::RecoveryRequired);
        assert_eq!(report.live_channels, 1);
        assert!(owner.inner.as_ref().unwrap().channels[&1].task.is_some());
        assert!(registry()
            .lock()
            .unwrap()
            .contains_key(&owner.owner_lease()));
        release.send(()).unwrap();
        let report = stopped(&mut owner).await;
        assert_eq!(report.joined_channels, 1);
        assert_eq!(report.retained_tasks, 0);
    }
}
