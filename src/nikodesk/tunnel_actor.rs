//! One actual Flow and mux owner on a caller-owned, long-lived Tokio runner.
//! Local commands carry a verified CM actor; remote metadata cannot mint one.
use super::{
    connection_capabilities::Identity,
    tunnel_endpoint::Target,
    tunnel_flow::{
        self, AuthFacts, Cancellation, Command, Flow, Op, Phase, Reply, ResolveCompletion,
        ResolveJob, Status, TrustedActor, WriterBarrier, WriterDrainAck,
    },
    tunnel_transport::{Limits, OwnedMux, Report, RetiredReport},
    tunnel_wire::{self, Binding, CallerFacts, ControlOp, Direction},
};
use base::message_proto::{message, Features, Message};
use hbb_common::{
    protobuf::Message as _,
    tokio::{
        self,
        runtime::Handle,
        sync::{mpsc, watch},
        task::JoinHandle,
    },
};
use std::{
    sync::{
        atomic::{AtomicBool, AtomicU64, Ordering},
        Arc, Mutex, TryLockError,
    },
    time::Duration,
};

const COMMAND_CAPACITY: usize = 16;
const FRAME_CAPACITY: usize = 64;
const TICK: Duration = Duration::from_millis(50);
const REFRESH: Duration = Duration::from_millis(250);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Error {
    Flow(tunnel_flow::Error),
    Wire(tunnel_wire::Error),
    QueueFull,
    Closed,
    Busy,
    WorkerFailed,
    InvalidRoute,
}
impl Error {
    pub(crate) fn code(self) -> &'static str {
        match self {
            Self::Flow(error) => error.code(),
            Self::Wire(error) => error.code(),
            Self::QueueFull => "tunnel_actor_queue_full",
            Self::Closed => "tunnel_actor_closed",
            Self::Busy => "tunnel_actor_busy",
            Self::WorkerFailed => "tunnel_actor_worker_failed",
            Self::InvalidRoute => "tunnel_actor_route_invalid",
        }
    }
}
impl From<tunnel_flow::Error> for Error {
    fn from(value: tunnel_flow::Error) -> Self {
        Self::Flow(value)
    }
}
impl From<tunnel_wire::Error> for Error {
    fn from(value: tunnel_wire::Error) -> Self {
        Self::Wire(value)
    }
}

pub(crate) struct TaggedFrame {
    message: Arc<Message>,
    binding: Binding,
    ticket: super::capability_state::Ticket,
    owner_lease: u64,
}
impl TaggedFrame {
    pub(crate) fn message(&self) -> &Message {
        &self.message
    }
    pub(crate) fn binding(&self) -> Binding {
        self.binding
    }
    pub(crate) fn owner_lease(&self) -> u64 {
        self.owner_lease
    }
}
/// Native cutoff facts captured from the original state, never a peer/CM DTO.
pub(crate) struct NativeCutoff {
    identity: Identity,
    owner_lease: Option<u64>,
    stop_epoch: u64,
}
impl NativeCutoff {
    pub(crate) fn identity(&self) -> &Identity {
        &self.identity
    }
    pub(crate) fn owner_lease(&self) -> Option<u64> {
        self.owner_lease
    }
    pub(crate) fn stop_epoch(&self) -> u64 {
        self.stop_epoch
    }
}
#[derive(Clone)]
pub(crate) struct RetiredObserver {
    shared: Arc<Shared>,
}
impl RetiredObserver {
    pub(crate) fn identity(&self) -> &Identity {
        &self.shared.identity
    }
    pub(crate) fn observe(&self, report: &RetiredReport) -> Result<(), Error> {
        let mut flow = self.shared.flow.try_lock().map_err(|_| Error::Busy)?;
        flow.observe_retired(report)?;
        self.shared.publish(&flow);
        Ok(())
    }
    pub(crate) fn owner_lease(&self) -> Option<u64> {
        self.shared.owner_lease()
    }
}
struct Shared {
    identity: Identity,
    binding: Binding,
    peer: Features,
    caller: CallerFacts,
    flow: Mutex<Flow>,
    cancellation: Cancellation,
    closed: AtomicBool,
    retired: AtomicBool,
    failed: AtomicBool,
    lease: AtomicU64,
    writer_ack: Mutex<Option<WriterDrainAck>>,
    status: watch::Sender<Status>,
    replies: watch::Sender<Option<Arc<Reply>>>,
    retained: Mutex<Vec<FailedOwner>>,
    cleanup_retry: AtomicBool,
}
enum Work {
    Local(TrustedActor, Command),
    Query,
    Revoke,
}
pub(crate) struct Actor {
    shared: Arc<Shared>,
    commands: mpsc::Sender<Work>,
    inbound: mpsc::Sender<Message>,
    frames: Option<mpsc::Receiver<TaggedFrame>>,
    driver: Option<JoinHandle<Result<(), Error>>>,
    runner: Handle,
    cleanup: Option<JoinHandle<Result<(), Error>>>,
    cleanup_joined: bool,
}

impl Actor {
    pub(crate) fn attach_audit(&self, context: super::capability_audit::Context) -> Result<(), Error> {
        self.shared.flow.lock().map_err(|_| Error::WorkerFailed)?.attach_audit(context);
        Ok(())
    }
    /// The passed runtime must outlive the parent Connection and its cleanup.
    /// No new runtime is created, and no global user Config is read in tests.
    pub(crate) async fn authenticated(
        runner: Handle,
        identity: Identity,
        target: Target,
        auth: AuthFacts,
        binding: Binding,
        peer: Features,
        limits: Limits,
    ) -> Result<Self, Error> {
        if !identity.valid()
            || identity.epoch != "1"
            || !peer.nikodesk_tunnel_v1
            || !peer.port_forward_mux
        {
            return Err(Error::InvalidRoute);
        }
        if limits.channels == 0
            || limits.channels > crate::port_forward_mux::MAX_CHANNELS
            || limits.pending_dials == 0
            || limits.pending_dials > limits.channels
        {
            return Err(Error::InvalidRoute);
        }
        let flow = runner
            .spawn_blocking(move || Flow::authenticated(identity, target, auth))
            .await
            .map_err(|_| Error::WorkerFailed)??;
        Self::start(runner, flow, auth, binding, peer, limits)
    }
    fn start(
        runner: Handle,
        flow: Flow,
        auth: AuthFacts,
        binding: Binding,
        peer: Features,
        limits: Limits,
    ) -> Result<Self, Error> {
        if flow.status().phase != Phase::Pending || flow.current_ticket().is_some() {
            return Err(Error::InvalidRoute);
        }
        let initial = flow.status();
        let cancellation = flow.cancellation();
        let (status, _) = watch::channel(initial.clone());
        let (replies, _) = watch::channel(None);
        let shared = Arc::new(Shared {
            identity: initial.identity,
            binding,
            peer,
            caller: CallerFacts {
                encrypted: auth.encrypted,
                authenticated: auth.authenticated,
                typed_tunnel_v1: auth.ordinary_tunnel_v1,
                ordinary_user: true,
                totp_required: auth.totp_required,
                totp_verified_current: auth.totp_verified_current,
            },
            flow: Mutex::new(flow),
            cancellation,
            closed: AtomicBool::new(false),
            retired: AtomicBool::new(false),
            failed: AtomicBool::new(false),
            lease: AtomicU64::new(0),
            writer_ack: Mutex::new(None),
            status,
            replies,
            retained: Mutex::new(Vec::new()),
            cleanup_retry: AtomicBool::new(false),
        });
        let (commands, cmd_rx) = mpsc::channel(COMMAND_CAPACITY);
        let (inbound, in_rx) = mpsc::channel(FRAME_CAPACITY);
        let (frames, frame_rx) = mpsc::channel(FRAME_CAPACITY);
        let (raw_tx, raw_rx) = mpsc::channel(FRAME_CAPACITY);
        let task_shared = shared.clone();
        let task_runner = runner.clone();
        let driver = runner.spawn(async move {
            let mut driver = Driver {
                shared: task_shared,
                runner: task_runner,
                limits,
                commands: cmd_rx,
                inbound: in_rx,
                frames,
                raw_tx,
                raw_rx,
                owner: None,
                operation: None,
                refresh: None,
                refresh_result: None,
                pending_report: None,
                commands_open: true,
                inbound_open: true,
                raw_open: true,
                normal_exit: false,
            };
            let result = driver.run().await;
            driver.normal_exit = result.is_ok();
            result
        });
        Ok(Self {
            shared,
            commands,
            inbound,
            frames: Some(frame_rx),
            driver: Some(driver),
            runner,
            cleanup: None,
            cleanup_joined: false,
        })
    }
    pub(crate) fn status(&self) -> Status {
        self.shared.status.borrow().clone()
    }
    pub(crate) fn subscribe(&self) -> watch::Receiver<Status> {
        self.shared.status.subscribe()
    }
    pub(crate) fn subscribe_replies(&self) -> watch::Receiver<Option<Arc<Reply>>> {
        self.shared.replies.subscribe()
    }
    pub(crate) fn take_frames(&mut self) -> Option<mpsc::Receiver<TaggedFrame>> {
        self.frames.take()
    }
    pub(crate) fn binding(&self) -> Binding {
        self.shared.binding
    }
    /// Execute immediately before each real Stream send, after any prior await.
    pub(crate) fn may_send(&self, frame: &TaggedFrame) -> bool {
        if frame.binding != self.shared.binding
            || self.shared.closed.load(Ordering::SeqCst)
            || self.shared.retired.load(Ordering::SeqCst)
            || self.shared.failed.load(Ordering::SeqCst)
        {
            return false;
        }
        self.shared.flow.try_lock().map_or(false, |flow| {
            flow.may_write(frame.owner_lease, &frame.ticket)
        })
    }
    pub(crate) fn try_local(&self, actor: TrustedActor, command: Command) -> Result<Reply, Error> {
        if command.identity != self.shared.identity {
            return Err(Error::InvalidRoute);
        }
        if self.shared.retired.load(Ordering::SeqCst)
            && !matches!(command.op, Op::Query | Op::RetryCleanup)
        {
            return Err(Error::Closed);
        }
        if !matches!(command.op, Op::Resolve | Op::Approve) {
            // Pure validation and cutoff run before returning to the verified
            // CM caller. A stale decision cannot cancel the current owner.
            let mut flow = self.shared.flow.try_lock().map_err(|_| Error::Busy)?;
            let result = flow.local(&actor, &command).map(|_| ());
            self.shared.publish(&flow);
            if command.op == Op::RetryCleanup
                && result.is_ok()
                && self.shared.failed.load(Ordering::SeqCst)
            {
                self.shared.cleanup_retry.store(true, Ordering::SeqCst);
            }
            return Ok(flow.reply(result));
        }
        if self.shared.closed.load(Ordering::SeqCst) || self.status().phase != Phase::Pending {
            return Err(Error::Closed);
        }
        self.enqueue(Work::Local(actor, command))?;
        let status = self.status();
        Ok(Reply {
            ok: true,
            reason: "queued",
            identity: status.identity,
            revision: status.revision,
        })
    }
    fn enqueue(&self, work: Work) -> Result<(), Error> {
        self.commands.try_send(work).map_err(|error| match error {
            mpsc::error::TrySendError::Full(_) => Error::QueueFull,
            mpsc::error::TrySendError::Closed(_) => Error::Closed,
        })
    }
    /// Root has already checked wire caller facts and original binding.
    pub(crate) fn remote_control(&self, binding: Binding, op: ControlOp) -> Result<(), Error> {
        if binding != self.shared.binding || self.shared.retired.load(Ordering::SeqCst) {
            return Err(Error::InvalidRoute);
        }
        match op {
            ControlOp::Query => self.enqueue(Work::Query),
            ControlOp::Revoke => {
                self.cancel()?;
                self.enqueue(Work::Revoke)
            }
        }
    }
    pub(crate) fn try_frame(&self, binding: Binding, frame: Message) -> Result<(), Error> {
        if binding != self.shared.binding
            || self.shared.closed.load(Ordering::SeqCst)
            || self.shared.retired.load(Ordering::SeqCst)
            || frame.compute_size() > crate::port_forward_mux::MAX_PACKET as u64
        {
            return Err(Error::InvalidRoute);
        }
        if !matches!(self.status().phase, Phase::Starting | Phase::Running) {
            return Err(Error::Closed);
        }
        let Some(message::Union::PortForwardChannel(channel)) = frame.union.as_ref() else {
            return Err(Error::InvalidRoute);
        };
        tunnel_wire::validate_frame(
            channel,
            binding,
            &self.shared.peer,
            self.shared.caller,
            Direction::ControllerToReceiver,
        )?;
        match self.inbound.try_send(frame) {
            Ok(()) => Ok(()),
            Err(error) => {
                let _ = self.cancel();
                Err(match error {
                    mpsc::error::TrySendError::Full(_) => Error::QueueFull,
                    mpsc::error::TrySendError::Closed(_) => Error::Closed,
                })
            }
        }
    }
    pub(crate) fn cancel(&self) -> Result<(), Error> {
        self.shared.closed.store(true, Ordering::SeqCst);
        self.shared.cancellation.cancel().map_err(Error::from)
    }
    pub(crate) fn parent_closed(&self) -> Result<(), Error> {
        self.shared.retired.store(true, Ordering::SeqCst);
        self.cancel()?;
        // This also covers a parent closing after the driver already joined.
        // A pending blocking operation retains the Flow; the driver performs
        // the same retirement as soon as that guard is available.
        match self.shared.flow.try_lock() {
            Ok(mut flow) => {
                let result = flow.retire().map_err(Error::from);
                self.shared.publish(&flow);
                result
            }
            Err(TryLockError::WouldBlock) => Ok(()),
            Err(TryLockError::Poisoned(_)) => Err(Error::WorkerFailed),
        }
    }
    pub(crate) fn cutoff_native(&self) -> Result<NativeCutoff, Error> {
        self.shared.closed.store(true, Ordering::SeqCst);
        let epoch = self
            .shared
            .cancellation
            .cancel_with_epoch()?
            .ok_or(Error::Flow(tunnel_flow::Error::NotApproved))?;
        // Activation publishes its lease under this same guard. A busy native
        // operation means retry, never an inferred no-owner acknowledgement.
        let _flow = self.shared.flow.try_lock().map_err(|_| Error::Busy)?;
        Ok(NativeCutoff {
            identity: self.shared.identity.clone(),
            owner_lease: self.owner_lease(),
            stop_epoch: epoch,
        })
    }
    pub(crate) fn update_auth(&self, auth: AuthFacts) -> Result<(), Error> {
        if !auth.encrypted
            || !auth.authenticated
            || !auth.ordinary_tunnel_v1
            || (auth.totp_required && !auth.totp_verified_current)
        {
            self.cancel()?;
        }
        let mut flow = self.shared.flow.try_lock().map_err(|_| Error::Busy)?;
        flow.update_auth(auth)?;
        self.shared.publish(&flow);
        Ok(())
    }
    pub(crate) fn writer_barrier(&self) -> Result<WriterBarrier, Error> {
        self.shared
            .flow
            .try_lock()
            .map_err(|_| Error::Busy)?
            .writer_barrier()
            .map_err(Error::from)
    }
    /// Only a real original writer/Stream drain path supplies this native value.
    pub(crate) fn writer_ack(&self, ack: WriterDrainAck) -> Result<(), Error> {
        let mut slot = self
            .shared
            .writer_ack
            .lock()
            .map_err(|_| Error::WorkerFailed)?;
        if slot.is_some() {
            return Err(Error::Busy);
        }
        *slot = Some(ack);
        Ok(())
    }
    pub(crate) fn owner_lease(&self) -> Option<u64> {
        self.shared.owner_lease()
    }
    pub(crate) fn retired_observer(&self) -> RetiredObserver {
        RetiredObserver {
            shared: self.shared.clone(),
        }
    }
    /// The root coordinator polls the global registry once, then fans out its
    /// typed report. An individual actor never consumes global completions.
    pub(crate) fn observe_retired(&self, report: &RetiredReport) -> Result<(), Error> {
        self.retired_observer().observe(report)
    }
    pub(crate) async fn finished(&mut self) -> Result<bool, Error> {
        let mut failed_now = false;
        if let Some(task) = self.driver.as_ref() {
            if !task.is_finished() {
                return Ok(false);
            }
            let task = self.driver.take().ok_or(Error::WorkerFailed)?;
            if !matches!(task.await, Ok(Ok(()))) {
                self.shared.mark_failed();
                self.shared.cleanup_retry.store(true, Ordering::SeqCst);
                failed_now = true;
            }
        }
        if !self.shared.failed.load(Ordering::SeqCst) {
            return Ok(true);
        }
        if self.cleanup_joined {
            let mut flow = match self.shared.flow.try_lock() {
                Ok(flow) => flow,
                Err(TryLockError::WouldBlock) => return Ok(false),
                Err(TryLockError::Poisoned(_)) => return Err(Error::WorkerFailed),
            };
            if flow.status().phase != Phase::Stopped {
                flow.acknowledge_actor_join(&self.shared.identity, self.owner_lease())?;
                self.shared.publish(&flow);
            }
            return Ok(flow.status().phase == Phase::Stopped);
        }
        if self.cleanup.is_none() && self.shared.cleanup_retry.swap(false, Ordering::SeqCst) {
            let owned = {
                let mut retained = self
                    .shared
                    .retained
                    .lock()
                    .map_err(|_| Error::WorkerFailed)?;
                std::mem::take(&mut *retained)
            };
            // Construct the ownership guard before spawn: cancellation before
            // the task's first poll must also return every original job/owner.
            let cleanup = FailureCleanup {
                shared: self.shared.clone(),
                owned,
                normal_exit: false,
            };
            self.cleanup = Some(self.runner.spawn(async move {
                let mut cleanup = cleanup;
                let result = cleanup.run().await;
                cleanup.normal_exit = result.is_ok();
                result
            }));
        }
        if self.cleanup.as_ref().map_or(false, JoinHandle::is_finished) {
            let task = self.cleanup.take().ok_or(Error::WorkerFailed)?;
            if !matches!(task.await, Ok(Ok(()))) {
                self.shared.mark_failed();
                return Err(Error::WorkerFailed);
            }
            self.cleanup_joined = true;
            // No lock crosses await. Final status is committed only on the
            // next call, after this actual cleanup task was normally joined.
            return Ok(false);
        }
        if failed_now {
            Err(Error::WorkerFailed)
        } else {
            Ok(false)
        }
    }
}
impl Drop for Actor {
    fn drop(&mut self) {
        let _ = self.parent_closed();
        // The driver remains on the caller's long-lived runner. Dropping a join
        // handle is not a cleanup ACK; root must retain Actor for observation.
    }
}
impl Shared {
    fn publish(&self, flow: &Flow) {
        self.status.send_replace(flow.status());
    }
    fn cutoff(&self) {
        self.closed.store(true, Ordering::SeqCst);
        let _ = self.cancellation.cancel();
    }
    fn owner_lease(&self) -> Option<u64> {
        match self.lease.load(Ordering::SeqCst) {
            0 => None,
            value => Some(value),
        }
    }
    fn record_reply(&self, result: Result<(), Error>) {
        let status = self.status.borrow().clone();
        self.replies.send_replace(Some(Arc::new(Reply {
            ok: result.is_ok(),
            reason: result.err().map_or("queued", Error::code),
            identity: status.identity,
            revision: status.revision,
        })));
    }
    fn mark_failed(&self) {
        self.failed.store(true, Ordering::SeqCst);
        self.cutoff();
        match self.flow.try_lock() {
            Ok(mut flow) => {
                let _ = flow.mark_actor_failed();
                self.publish(&flow);
            }
            Err(TryLockError::Poisoned(guard)) => {
                let mut flow = guard.into_inner();
                let _ = flow.mark_actor_failed();
                self.publish(&flow);
            }
            Err(TryLockError::WouldBlock) => {}
        }
    }
    fn worker_publish(&self, flow: &mut Flow) {
        if self.failed.load(Ordering::SeqCst) {
            let _ = flow.mark_actor_failed();
        }
        self.publish(flow);
    }
}
enum Operation {
    Prepare(JoinHandle<Result<ResolveJob, Error>>),
    Resolve(JoinHandle<ResolveCompletion>),
    Finish(JoinHandle<Result<(), Error>>),
    Approve(JoinHandle<Result<(), Error>>),
}
impl Operation {
    fn done(&self) -> bool {
        match self {
            Self::Prepare(job) => job.is_finished(),
            Self::Resolve(job) => job.is_finished(),
            Self::Finish(job) | Self::Approve(job) => job.is_finished(),
        }
    }
}
struct FailedOwner {
    owner: Option<OwnedMux>,
    operation: Option<Operation>,
    refresh: Option<JoinHandle<tunnel_flow::RefreshCompletion>>,
    report: Option<(u64, Report)>,
}
impl Shared {
    fn retain_failed(&self, owned: Vec<FailedOwner>) {
        // Poison is not permission to discard still-live native ownership.
        let mut retained = self
            .retained
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        retained.extend(owned);
    }
}
struct FailureCleanup {
    shared: Arc<Shared>,
    owned: Vec<FailedOwner>,
    normal_exit: bool,
}
impl Drop for FailureCleanup {
    fn drop(&mut self) {
        if !self.normal_exit {
            self.shared.mark_failed();
            self.shared.retain_failed(std::mem::take(&mut self.owned));
        }
    }
}
impl FailureCleanup {
    async fn run(&mut self) -> Result<(), Error> {
        let mut timer = tokio::time::interval(TICK);
        timer.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
        loop {
            timer.tick().await;
            for owned in &mut self.owned {
                if owned
                    .refresh
                    .as_ref()
                    .map_or(false, JoinHandle::is_finished)
                {
                    // This job only reads native settings. A completed panic is
                    // terminal evidence for that job, never an FD/writer ACK.
                    let job = owned.refresh.take().ok_or(Error::WorkerFailed)?;
                    let _ = job.await;
                }
                if owned.operation.as_ref().map_or(false, Operation::done) {
                    match owned.operation.take().ok_or(Error::WorkerFailed)? {
                        Operation::Prepare(job) => {
                            let _ = job.await;
                        }
                        Operation::Resolve(job) => {
                            let _ = job.await;
                        }
                        Operation::Finish(job) | Operation::Approve(job) => {
                            let _ = job.await;
                        }
                    }
                    // A job that poisoned Flow is not assumed to have cleaned
                    // resources. The short lock below keeps it in Recovery.
                }
                if owned.report.is_none() {
                    if let Some(owner) = owned.owner.as_mut() {
                        owner.begin_stop();
                        let lease = owner.owner_lease();
                        owned.report = Some((lease, owner.stop_poll().await));
                    }
                }
            }
            let mut flow = match self.shared.flow.try_lock() {
                Ok(flow) => flow,
                Err(TryLockError::WouldBlock) => continue,
                Err(TryLockError::Poisoned(_)) => return Err(Error::WorkerFailed),
            };
            flow.mark_actor_failed()?;
            if self.shared.retired.load(Ordering::SeqCst) && !flow.status().cleanup_only {
                flow.retire()?;
            }
            for owned in &mut self.owned {
                if let Some((lease, report)) = owned.report.take() {
                    flow.finish_transport_poll(lease, report)?;
                    if report.phase == super::tunnel_transport::Phase::Stopped {
                        owned.owner.take(); // actual normal task/FD join already confirmed
                    }
                }
            }
            let ack = self
                .shared
                .writer_ack
                .lock()
                .map_err(|_| Error::WorkerFailed)?
                .take();
            if let Some(ack) = ack {
                flow.writer_drained(ack)?;
            }
            self.shared.publish(&flow);
            let jobs_done = self.owned.iter().all(|owned| {
                owned.operation.is_none()
                    && owned.refresh.is_none()
                    && owned.owner.is_none()
                    && owned.report.is_none()
            });
            if jobs_done && flow.ready_for_actor_join() {
                return Ok(());
            }
        }
    }
}
struct Driver {
    shared: Arc<Shared>,
    runner: Handle,
    limits: Limits,
    commands: mpsc::Receiver<Work>,
    inbound: mpsc::Receiver<Message>,
    frames: mpsc::Sender<TaggedFrame>,
    raw_tx: mpsc::Sender<(tokio::time::Instant, Arc<Message>)>,
    raw_rx: mpsc::Receiver<(tokio::time::Instant, Arc<Message>)>,
    owner: Option<OwnedMux>,
    operation: Option<Operation>,
    refresh: Option<JoinHandle<tunnel_flow::RefreshCompletion>>,
    refresh_result: Option<tunnel_flow::RefreshCompletion>,
    pending_report: Option<(u64, Report)>,
    commands_open: bool,
    inbound_open: bool,
    raw_open: bool,
    normal_exit: bool,
}
impl Drop for Driver {
    fn drop(&mut self) {
        if !self.normal_exit {
            self.shared.mark_failed();
            let owned = FailedOwner {
                owner: self.owner.take(),
                operation: self.operation.take(),
                refresh: self.refresh.take(),
                report: self.pending_report.take(),
            };
            self.shared.retain_failed(vec![owned]);
        }
    }
}
impl Driver {
    async fn run(&mut self) -> Result<(), Error> {
        let mut tick = tokio::time::interval(TICK);
        tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
        let mut refresh_tick = tokio::time::interval(REFRESH);
        refresh_tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
        loop {
            tokio::select! {
                biased;
                _ = tick.tick() => {
                    self.complete_workers().await?;
                    self.advance().await?;
                    if self.finished() { return Ok(()); }
                }
                _ = refresh_tick.tick(), if self.refresh.is_none() && self.refresh_result.is_none() && self.operation.is_none() => self.begin_refresh()?,
                work = self.commands.recv(), if self.commands_open && self.operation.is_none() && self.refresh.is_none() && self.refresh_result.is_none() => match work {
                    Some(work) => self.command(work)?,
                    None => { self.commands_open = false; self.shared.retired.store(true,Ordering::SeqCst); self.shared.cutoff(); }
                },
                frame = self.inbound.recv(), if self.inbound_open && self.owner.is_some() && self.operation.is_none() => match frame {
                    Some(frame) => self.dispatch(frame)?,
                    None => { self.inbound_open = false; self.shared.cutoff(); },
                },
                frame = self.raw_rx.recv(), if self.raw_open && self.owner.is_some() => match frame { Some((_,frame)) => self.output(frame)?, None => self.raw_open = false },
            }
        }
    }
    fn flow<R>(
        &self,
        operation: impl FnOnce(&mut Flow) -> Result<R, Error>,
    ) -> Result<Option<R>, Error> {
        match self.shared.flow.try_lock() {
            Ok(mut flow) => {
                let result = operation(&mut flow);
                self.shared.publish(&flow);
                result.map(Some)
            }
            Err(TryLockError::WouldBlock) => Ok(None),
            Err(TryLockError::Poisoned(_)) => {
                self.shared.cutoff();
                Err(Error::WorkerFailed)
            }
        }
    }
    fn begin_refresh(&mut self) -> Result<(), Error> {
        if self.shared.closed.load(Ordering::SeqCst) || self.shared.retired.load(Ordering::SeqCst) {
            return Ok(());
        }
        let job = self.flow(|flow| flow.prepare_refresh().map_err(Error::from));
        match job {
            Ok(Some(job)) => self.refresh = Some(self.runner.spawn_blocking(move || job.run())),
            Ok(None) | Err(Error::Flow(tunnel_flow::Error::Stale)) => {}
            Err(error) => return Err(error),
        }
        Ok(())
    }
    async fn complete_workers(&mut self) -> Result<(), Error> {
        if self.refresh.as_ref().map_or(false, JoinHandle::is_finished) {
            let job = self.refresh.take().ok_or(Error::WorkerFailed)?;
            match job.await {
                Ok(result) => self.refresh_result = Some(result),
                Err(_) => {
                    self.shared.cutoff();
                    return Err(Error::WorkerFailed);
                }
            }
        }
        if let Some(completion) = self.refresh_result.take() {
            match self.shared.flow.try_lock() {
                Ok(mut flow) => {
                    let result = flow.finish_refresh(completion).map_err(Error::from);
                    self.shared.publish(&flow);
                    if let Err(error) = result {
                        self.shared.record_reply(Err(error));
                    }
                }
                Err(TryLockError::WouldBlock) => {
                    self.refresh_result = Some(completion);
                    return Ok(());
                }
                Err(TryLockError::Poisoned(_)) => return Err(Error::WorkerFailed),
            }
        }
        if !self.operation.as_ref().map_or(false, Operation::done) {
            return Ok(());
        }
        let operation = self.operation.take().ok_or(Error::WorkerFailed)?;
        match operation {
            Operation::Prepare(job) => match job.await {
                Ok(Ok(job)) if !self.shared.closed.load(Ordering::SeqCst) => {
                    self.operation = Some(Operation::Resolve(self.runner.spawn(job.run())))
                }
                Ok(Ok(_)) => {}
                Ok(Err(error)) => self.shared.record_reply(Err(error)),
                Err(_) => return Err(Error::WorkerFailed),
            },
            Operation::Resolve(job) => {
                let result = job.await.map_err(|_| Error::WorkerFailed)?;
                let shared = self.shared.clone();
                self.operation = Some(Operation::Finish(self.runner.spawn_blocking(move || {
                    let mut flow = shared.flow.lock().map_err(|_| Error::WorkerFailed)?;
                    let result = flow.finish_resolve(result).map_err(Error::from);
                    shared.worker_publish(&mut flow);
                    result
                })));
            }
            Operation::Finish(job) | Operation::Approve(job) => {
                self.shared
                    .record_reply(job.await.map_err(|_| Error::WorkerFailed)?);
            }
        }
        Ok(())
    }
    fn command(&mut self, work: Work) -> Result<(), Error> {
        match work {
            Work::Query => {
                let _ = self.flow(|_| Ok(()))?;
            }
            Work::Revoke => {
                self.shared.cutoff();
            }
            Work::Local(actor, command) => {
                if matches!(command.op, Op::Resolve | Op::Approve) {
                    if self.shared.closed.load(Ordering::SeqCst)
                        || self.shared.retired.load(Ordering::SeqCst)
                        || self.shared.status.borrow().phase != Phase::Pending
                    {
                        self.shared.record_reply(Err(Error::Closed));
                        return Ok(());
                    }
                    let shared = self.shared.clone();
                    self.operation = Some(if command.op == Op::Resolve {
                        Operation::Prepare(self.runner.spawn_blocking(move || {
                            let mut flow = shared.flow.lock().map_err(|_| Error::WorkerFailed)?;
                            let result =
                                flow.prepare_resolve(&actor, &command).map_err(Error::from);
                            shared.worker_publish(&mut flow);
                            result
                        }))
                    } else {
                        Operation::Approve(self.runner.spawn_blocking(move || {
                            let mut flow = shared.flow.lock().map_err(|_| Error::WorkerFailed)?;
                            let result = flow.approve(&actor, &command).map_err(Error::from);
                            shared.worker_publish(&mut flow);
                            result
                        }))
                    });
                } else {
                    let result = self.flow(|flow| {
                        flow.local(&actor, &command)
                            .map(|_| ())
                            .map_err(Error::from)
                    });
                    self.shared.record_reply(result.map(|_| ()));
                }
            }
        }
        Ok(())
    }
    async fn advance(&mut self) -> Result<(), Error> {
        self.flow(|flow| {
            if self.shared.retired.load(Ordering::SeqCst) {
                flow.retire()?;
            } else if self.shared.closed.load(Ordering::SeqCst) {
                flow.invalidate("revoked_locally")?;
            }
            flow.tick()?;
            let ack = self
                .shared
                .writer_ack
                .lock()
                .map_err(|_| Error::WorkerFailed)?
                .take();
            if let Some(ack) = ack {
                if let Err(error) = flow.writer_drained(ack) {
                    self.shared.record_reply(Err(error.into()));
                }
            }
            Ok(())
        })?;
        if self.owner.is_none()
            && self.operation.is_none()
            && !self.shared.closed.load(Ordering::SeqCst)
        {
            let result = self.flow(|flow| {
                if flow.status().phase != Phase::Starting {
                    return Ok(None);
                }
                let owner = flow.activate(
                    crate::port_forward_mux::FrameSink::BoundedDirect(self.raw_tx.clone()),
                    self.limits,
                )?;
                self.shared
                    .lease
                    .store(owner.owner_lease(), Ordering::SeqCst);
                Ok(Some(owner))
            });
            match result {
                Ok(Some(Some(owner))) => {
                    self.owner = Some(owner);
                }
                Ok(_) => {}
                Err(_) => self.shared.cutoff(),
            }
        }
        let Some(owner) = self.owner.as_mut() else {
            return Ok(());
        };
        let lease = owner.owner_lease();
        if let Some((lease, report)) = self.pending_report.take() {
            match self.shared.flow.try_lock() {
                Ok(mut flow) => {
                    if flow.finish_transport_poll(lease, report)? {
                        owner.begin_stop();
                    }
                    self.shared.publish(&flow);
                }
                Err(TryLockError::WouldBlock) => {
                    self.pending_report = Some((lease, report));
                    return Ok(());
                }
                Err(TryLockError::Poisoned(_)) => return Err(Error::WorkerFailed),
            }
        }
        let stopping = match self.shared.flow.try_lock() {
            Ok(mut flow) => {
                let stop = flow.prepare_transport_poll(lease)?;
                self.shared.publish(&flow);
                stop
            }
            Err(TryLockError::WouldBlock) => return Ok(()),
            Err(TryLockError::Poisoned(_)) => return Err(Error::WorkerFailed),
        };
        let report = if stopping {
            owner.stop_poll().await
        } else {
            owner.poll().await
        };
        let begin_stop = {
            match self.shared.flow.try_lock() {
                Ok(mut flow) => {
                    let stop = flow.finish_transport_poll(lease, report)?;
                    self.shared.publish(&flow);
                    stop
                }
                Err(TryLockError::WouldBlock) => {
                    self.pending_report = Some((lease, report));
                    return Ok(());
                }
                Err(TryLockError::Poisoned(_)) => return Err(Error::WorkerFailed),
            }
        };
        if begin_stop {
            owner.begin_stop();
        }
        if stopping {
            self.raw_open = false;
            self.raw_rx.close();
            while self.raw_rx.try_recv().is_ok() {}
        }
        Ok(())
    }
    fn dispatch(&mut self, frame: Message) -> Result<(), Error> {
        let Some(owner) = self.owner.as_mut() else {
            self.shared.cutoff();
            return Ok(());
        };
        let mut flow = self.shared.flow.try_lock().map_err(|_| Error::Busy)?;
        if flow.dispatch(owner, frame).is_err() {
            self.shared.cutoff();
            owner.begin_stop();
        }
        self.shared.publish(&flow);
        Ok(())
    }
    fn output(&mut self, mut frame: Arc<Message>) -> Result<(), Error> {
        let Some(owner) = self.owner.as_ref() else {
            self.shared.cutoff();
            return Ok(());
        };
        let flow = self.shared.flow.try_lock().map_err(|_| Error::Busy)?;
        let Some(ticket) = flow.current_ticket() else {
            self.shared.cutoff();
            return Ok(());
        };
        let lease = owner.owner_lease();
        if !flow.may_write(lease, &ticket) {
            return Ok(());
        }
        tunnel_wire::tag_message(
            Arc::make_mut(&mut frame),
            self.shared.binding,
            &self.shared.peer,
            self.shared.caller,
            Direction::ReceiverToController,
        )?;
        let outgoing = TaggedFrame {
            message: frame,
            binding: self.shared.binding,
            ticket,
            owner_lease: lease,
        };
        if self.frames.try_send(outgoing).is_err() {
            self.shared.cutoff();
        }
        Ok(())
    }
    fn finished(&self) -> bool {
        self.operation.is_none()
            && self.refresh.is_none()
            && self.refresh_result.is_none()
            && self.shared.status.borrow().phase == Phase::Stopped
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn unauthenticated_ctor_is_rejected_before_any_config_or_socket_access() {
        let identity = Identity {
            connection_id: 7,
            namespace: "a".repeat(64),
            peer_id: "123456789".into(),
            connection_nonce: "01".repeat(16),
            request_nonce: "02".repeat(16),
            epoch: "1".into(),
        };
        let result = Actor::authenticated(
            Handle::current(),
            identity,
            Target::parse("127.0.0.1", 23456).unwrap(),
            AuthFacts {
                encrypted: true,
                authenticated: false,
                ordinary_tunnel_v1: true,
                totp_required: true,
                totp_verified_current: false,
            },
            Binding::new([7; 16], 1).unwrap(),
            tunnel_wire::features(true),
            Limits::default(),
        )
        .await;
        assert!(matches!(
            result,
            Err(Error::Flow(tunnel_flow::Error::Unauthenticated))
        ));
    }
}
