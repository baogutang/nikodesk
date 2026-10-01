//! The privileged side owns the kernel caller. Every transaction refresh asks
//! that still-connected pinned UI for its current verified settings snapshot.
use super::{
    approval::{CallerOrigin, LocalApprovalGrant},
    broker_origin::{PreparedUiProcess, ProtectedUiPipe, VerifiedUiCaller},
    embedded_release::{EmbeddedRelease, TrustMode},
    policy::{Action, LocalConsent},
    profile::{MachineProfileFactory, ServerInput, UnattendedSecret},
    transaction::Phase,
    windows::NativeSetup,
    wire::{self, CurrentServerSnapshot, Packet},
};
use hbb_common::{
    anyhow::{anyhow, bail, Result},
    tokio::{
        self,
        sync::mpsc,
        time::{timeout, Duration},
    },
};
use std::{
    ffi::OsString,
    path::PathBuf,
    sync::{
        atomic::{AtomicBool, Ordering},
        mpsc as sync_channel, Arc,
    },
    time::Instant,
};

struct Refresh {
    reply: sync_channel::SyncSender<bool>,
}
pub(super) struct BrokerAuthority {
    requests: mpsc::UnboundedSender<Refresh>,
    cancelled: Arc<AtomicBool>,
    expiry: Instant,
    mode: TrustMode,
}
impl BrokerAuthority {
    pub(super) fn refresh(&self) -> Result<()> {
        if self.cancelled.load(Ordering::Acquire) || Instant::now() >= self.expiry {
            bail!("install_local_authorization_expired");
        }
        let (tx, rx) = sync_channel::sync_channel(1);
        self.requests
            .send(Refresh { reply: tx })
            .map_err(|_| anyhow!("install_broker_closed"))?;
        if rx.recv_timeout(std::time::Duration::from_secs(5)) != Ok(true)
            || self.cancelled.load(Ordering::Acquire)
            || Instant::now() >= self.expiry
        {
            bail!("install_current_local_authorization_unconfirmed");
        }
        Ok(())
    }
    pub(super) fn reviewed_unsigned(&self) -> bool {
        self.mode == TrustMode::ReviewedLocalUnsignedValidation
    }
}
/// Its fields are private. Only the actual native confirmation result following
/// kernel verification below can create this value; no deserializer exists.
pub(super) struct ConfirmedApproval {
    origin: CallerOrigin,
    server: ServerInput,
    consent: LocalConsent,
    authority: Arc<BrokerAuthority>,
}
impl ConfirmedApproval {
    pub(super) fn into_parts(
        self,
    ) -> (
        CallerOrigin,
        ServerInput,
        LocalConsent,
        Arc<BrokerAuthority>,
    ) {
        (self.origin, self.server, self.consent, self.authority)
    }
}
fn text(value: &str) -> Vec<u16> {
    value.encode_utf16().chain(Some(0)).collect()
}
fn native_confirm(
    snapshot: &CurrentServerSnapshot,
    release: &EmbeddedRelease,
    start: bool,
    virtual_display: bool,
    auto_lock: bool,
    privacy: bool,
    restart: bool,
    action: Action,
) -> Result<()> {
    use ::windows::{
        core::PCWSTR,
        Win32::UI::WindowsAndMessaging::{
            MessageBoxW, IDYES, MB_DEFBUTTON2, MB_ICONWARNING, MB_SETFOREGROUND, MB_YESNO,
        },
    };
    super::broker_origin::require_elevated_visible_setup()?;
    let warning = if release.mode() == TrustMode::ReviewedLocalUnsignedValidation {
        "此安装器是明确启用的未签名开发验证版，没有可信发布者签名。继续仅表示您明确信任本次选择的程序，不代表 Windows 发布者验证。\r\n\r\n"
    } else {
        "此发行版要求 Windows Authenticode 验证。\r\n\r\n"
    };
    let fingerprint = format!("{:x}", sha2::Sha256::digest(snapshot.key().as_bytes()));
    let body=text(&format!("{warning}允许 NikoDesk {} (构建 {}) 创建独立机器身份和 NikoDeskHost 服务吗？\r\n这会允许登录前、注销后与 UAC 桌面的无人值守远控。不会修改已安装 RustDesk。\r\n\r\n私服：{}\r\n公钥指纹：{}\r\n完成后立即启动：{}\r\n允许连接创建虚拟屏：{}（需要另行在本机安装兼容的签名驱动，此安装不会安装驱动）\r\n最后一个控制会话断开后自动锁屏：{}\r\n允许已认证连接请求隐私屏：{}（仅登录后的普通桌面；切换登录/UAC桌面恢复，物理Esc可恢复）\r\n允许远程重启机器：{}（默认关闭；需已认证远控、键鼠权限和明确请求）\r\n\r\n只在您明确同意上述机器范围时选择‘是’。",release.version(),release.build(),snapshot.rendezvous(),fingerprint,if start {"是"}else{"否"},if virtual_display {"是"}else{"否"},if auto_lock {"是"}else{"否"},if privacy {"是"}else{"否"},if restart {"是"}else{"否"}));
    let body = if action == Action::Install { body } else {
        let operation = match action {
            Action::Stop => "停止 NikoDeskHost 并关闭开机启动。保留原机器 ID、密码和设置。",
            Action::Resume => "恢复 NikoDeskHost 的开机启动并立即启动服务。保留原机器 ID、密码和设置。",
            Action::Remove => "卸载 NikoDeskHost 服务、已核验的程序文件和机器身份。原机器 ID 和密码会失效；日志和无法确认归属的文件保留。",
            Action::Upgrade => "将 NikoDeskHost 程序升级为本次选择的固定发行版。保留机器 ID、密码、私服和权限设置。升级期间暂时离线；失败会恢复原文件并保持服务停用，需明确恢复运行。",
            Action::Repair => "从本次选择的固定发行版修复 NikoDeskHost 程序，恢复中断升级的原文件。保留机器 ID、密码、私服和权限设置。身份文件损坏时不会重新生成或覆盖身份。",
            Action::RecoverInstall => "清理中断的首次安装。只停止并清理原安装记录确认归属的 NikoDesk 服务与文件；已完成提交的机器身份不会清除，无法确认归属的文件保留。清理完成后可重新安装。",
            Action::Configure => "修改已安装机器的隐私屏、虚拟屏、重启和断开后锁屏权限。保留原机器 ID、密码、私服和程序文件；先停止服务，再原子保存本次完整选择。",
            Action::ChangePassword => "修改已安装机器的服务密码，并更换密码验证盐。保留机器 ID、私钥、私服、权限和程序文件。会先停止服务及原进程，旧验证凭据失效；密码不会显示或写入日志。",
            Action::Install => unreachable!(),
        };
        let policies = if action == Action::Configure {
            format!("\r\n本次完整权限选择（未选的权限关闭）：\r\n允许虚拟屏：{}（不会安装驱动）\r\n断开后锁屏：{}\r\n允许隐私屏：{}（仅普通登录桌面；物理Esc恢复）\r\n允许远程重启机器：{}\r\n保存后恢复开机启动并立即运行：{}\r\n", if virtual_display {"是"}else{"否"}, if auto_lock {"是"}else{"否"}, if privacy {"是"}else{"否"}, if restart {"是"}else{"否"}, if start {"是"}else{"否"})
        } else if action == Action::ChangePassword {
            format!("\r\n保存后恢复开机启动并立即运行：{}\r\n未选择时保持服务停用。", if start {"是"}else{"否"})
        } else {String::new()};
        text(&format!("{warning}{operation}\r\n\r\n只操作 Program Files / ProgramData 下经核验的独立 NikoDesk 服务，不修改 RustDesk。\r\n当前私服：{}\r\n公钥指纹：{}{policies}\r\n\r\n只有当前机器配置与此私服一致才会执行。是否确认这项本机操作？", snapshot.rendezvous(),fingerprint))
    };
    let caption = text("NikoDesk — 本机无人值守操作确认");
    if unsafe {
        MessageBoxW(
            None,
            PCWSTR(body.as_ptr()),
            PCWSTR(caption.as_ptr()),
            MB_YESNO | MB_DEFBUTTON2 | MB_ICONWARNING | MB_SETFOREGROUND,
        )
    } != IDYES
    {
        bail!("install_local_native_consent_declined");
    }
    super::broker_origin::require_elevated_visible_setup()
}
use sha2::Digest;
fn arguments(args: Vec<OsString>) -> Result<([u8; 32], u32)> {
    if args.len() != 4 || args[0] != "--broker" || args[2] != "--ui-pid" {
        bail!("install_setup_handoff_required");
    }
    let nonce = wire::parse_nonce(
        args[1]
            .to_str()
            .ok_or_else(|| anyhow!("install_nonce_invalid"))?,
    )?;
    let pid = args[3]
        .to_str()
        .ok_or_else(|| anyhow!("install_ui_process_invalid"))?
        .parse::<u32>()?;
    if pid == 0 {
        bail!("install_ui_process_invalid");
    }
    Ok((nonce, pid))
}
struct ReaderOwner(Option<tokio::task::JoinHandle<()>>);
impl ReaderOwner {
    async fn stop(mut self) {
        if let Some(task) = self.0.take() {
            task.abort();
            let _ = task.await;
        }
    }
}
impl Drop for ReaderOwner {
    fn drop(&mut self) {
        if let Some(task) = &self.0 {
            task.abort();
        }
    }
}
struct Progress {
    phase: &'static str,
    quiescent: bool,
}
fn phase_name(phase: Phase) -> &'static str {
    match phase {
        Phase::Preflight => "preflight",
        Phase::Roots => "roots",
        Phase::Journal => "journal",
        Phase::Payload => "payload",
        Phase::DisabledService => "disabled_service",
        Phase::Profile => "profile",
        Phase::Verify => "verify",
        Phase::Consent => "consent",
        Phase::AutoStart => "auto_start",
        Phase::Started => "started",
        Phase::Complete => "complete",
        Phase::Recovery => "recovery",
    }
}
struct WorkerOutcome { phase: &'static str, public_id: String }
fn worker(
    confirmed: ConfirmedApproval,
    password: Option<UnattendedSecret>,
    source: PathBuf,
    release: super::policy::ReleaseManifest,
    progress: mpsc::UnboundedSender<Progress>,
) -> Result<WorkerOutcome> {
    let approval = LocalApprovalGrant::from_confirmed(confirmed)?;
    if approval.consent().action == Action::RecoverInstall {
        super::windows::recovery::run(approval,|phase| {
            let _=progress.send(Progress {phase,quiescent:false});
        })?;
        return Ok(WorkerOutcome {phase:"install_recovered",public_id:String::new()});
    }
    if approval.consent().action != Action::Install {
        let public_id=super::windows::maintenance::run(approval,release,source,password,|phase| {
            let _=progress.send(Progress {phase,quiescent:false});
        })?;
        return Ok(WorkerOutcome {phase:"complete",public_id});
    }
    let factory = MachineProfileFactory::from_approved_snapshot(&approval)?;
    let mut transaction = NativeSetup::new(factory, source, release, approval,
        password.ok_or_else(||anyhow!("explicit_unattended_password_required"))?)?;
    loop {
        let _ = progress.send(Progress {
            phase: phase_name(transaction.phase()),
            quiescent: false,
        });
        if transaction.advance()? {
            return Ok(WorkerOutcome {phase:"complete",public_id:transaction.into_platform().public_id()?});
        }
        if transaction.phase() == Phase::Recovery {
            // Unknown SCM Stop never discards the transaction/held file/privilege
            // owners. Cancellation also waits for real stopped confirmation.
            while transaction.recovery_error().is_some() {
                let _ = progress.send(Progress {
                    phase: "recovery",
                    quiescent: false,
                });
                std::thread::sleep(std::time::Duration::from_secs(2));
                let _ = transaction.retry_confirm_stopped();
            }
            // The original owner still holds the exact created-object identities.
            // Leaving its payload/profile behind would prevent the next install.
            // Keep that owner until real rollback succeeds, including cancellation.
            if transaction.platform().committed() {
                bail!("install_failed_committed_identity_preserved");
            }
            if !transaction.platform().owns_install() {
                bail!("install_failed_before_ownership_use_local_recovery");
            }
            while transaction.rollback().is_err() {
                let _ = progress.send(Progress { phase: "recovery", quiescent: false });
                std::thread::sleep(std::time::Duration::from_secs(2));
            }
            return Ok(WorkerOutcome {phase:"install_recovered",public_id:String::new()});
        }
    }
}
async fn validate_refresh(
    pipe: &mut tokio::io::WriteHalf<tokio::net::windows::named_pipe::NamedPipeServer>,
    incoming: &mut mpsc::Receiver<Result<Packet>>,
    caller: &mut Option<VerifiedUiCaller>,
    current: &CurrentServerSnapshot,
    sequence: &mut u64,
    nonce: [u8; 32],
    cancelled: &AtomicBool,
) -> Result<()> {
    if cancelled.load(Ordering::Acquire) {
        bail!("install_cancelled");
    }
    *sequence = sequence
        .checked_add(1)
        .ok_or_else(|| anyhow!("install_sequence_exhausted"))?;
    wire::write_packet(
        pipe,
        &Packet::Read {
            sequence: *sequence,
            nonce,
        },
    )
    .await?;
    let packet = timeout(Duration::from_secs(4), incoming.recv())
        .await
        .map_err(|_| anyhow!("install_current_snapshot_timeout"))?
        .ok_or_else(|| anyhow!("install_broker_closed"))??;
    match &packet {
        Packet::Snapshot {
            sequence: actual,
            nonce: bound,
            current: actual_current,
        } => {
            wire::expect_sequence(*actual, *sequence, bound, &nonce)?;
            actual_current.validate()?;
            if actual_current != current {
                bail!("install_private_server_snapshot_changed");
            }
        }
        _ => bail!("install_current_snapshot_unconfirmed"),
    }
    let mut owned = caller
        .take()
        .ok_or_else(|| anyhow!("install_kernel_caller_unavailable"))?;
    let (returned, result) = tokio::task::spawn_blocking(move || {
        let result = owned.revalidate();
        (owned, result)
    })
    .await?;
    *caller = Some(returned);
    result?;
    if cancelled.load(Ordering::Acquire) {
        bail!("install_cancelled");
    }
    Ok(())
}
/// Dedicated setup bin owns the runtime. This library creates none. No fixed
/// build-time release means failure before any pipe, machine UID or SCM call.
pub(crate) async fn run(args: Vec<OsString>) -> Result<()> {
    let release = EmbeddedRelease::compiled()?;
    let (nonce, pid) = arguments(args)?;
    hbb_common::sodiumoxide::init().map_err(|_| anyhow!("install_crypto_initialization_failed"))?;
    super::broker_origin::require_elevated_visible_setup()?;
    let mut prepared = PreparedUiProcess::from_compiled(pid, &release)?;
    let mut pipe = ProtectedUiPipe::for_prepared_ui(&mut prepared, &nonce)?;
    timeout(Duration::from_secs(60), pipe.connect())
        .await
        .map_err(|_| anyhow!("install_ui_connect_timeout"))??;
    let mut packet = pipe.read().await?;
    let (current, password, start, virtual_display, auto_lock, privacy, restart, action) = match &mut packet {
        Packet::Begin {
            action,
            sequence,
            nonce: bound,
            current,
            password,
            start_after_commit,
            allow_virtual_display,
            lock_on_disconnect,
            allow_privacy,
            allow_remote_restart,
        } => {
            wire::expect_sequence(*sequence, 1, bound, &nonce)?;
            current.validate()?;
            if (!action.accepts_password() && !password.is_empty())
                || (!action.accepts_start() && *start_after_commit)
                || (!action.accepts_session_policies()
                && (*allow_virtual_display || *lock_on_disconnect || *allow_privacy || *allow_remote_restart)) {
                bail!("maintenance_request_has_install_policy");
            }
            (
                current.clone(),
                if action.accepts_password() {Some(UnattendedSecret::from_explicit_user_entry(std::mem::take(password))?)} else {None},
                *start_after_commit,
                *allow_virtual_display,
                *lock_on_disconnect,
                *allow_privacy,
                *allow_remote_restart,
                *action,
            )
        }
        _ => bail!("install_begin_required"),
    };
    drop(packet);
    let mut caller =
        Some(pipe.verify_prepared(&mut prepared, current.namespace(), current.generation())?);
    drop(prepared);
    let cancelled = Arc::new(AtomicBool::new(false));
    let expiry = Instant::now() + std::time::Duration::from_secs(300);
    let (mut reader, mut writer) = tokio::io::split(pipe.into_stream());
    let (input_tx, mut input_rx) = mpsc::channel(8);
    let reader_cancel = Arc::clone(&cancelled);
    let read_task = ReaderOwner(Some(tokio::spawn(async move {
        loop {
            let result = wire::read_packet(&mut reader).await;
            if let Ok(Packet::Cancel { nonce: bound, .. }) = &result {
                if bound == &nonce {
                    reader_cancel.store(true, Ordering::Release);
                }
            }
            let failed = result.is_err();
            if input_tx.send(result).await.is_err() {
                break;
            }
            if failed {
                reader_cancel.store(true, Ordering::Release);
                break;
            }
        }
    })));
    // The native UI is a real local approval, not any message field. Even an
    // OS-granted UAC launch is insufficient without this subsequent confirmation.
    let confirmation = current.clone();
    let mut confirmation_owner = tokio::task::spawn_blocking(move || {
        let result = native_confirm(&confirmation, &release, start, virtual_display, auto_lock, privacy, restart, action);
        (release, result)
    });
    let (release, confirm) = loop {
        tokio::select! {
            result=&mut confirmation_owner=>break match result {
                Ok(value)=>value,
                Err(_)=>{cancelled.store(true,Ordering::Release);read_task.stop().await;return Err(anyhow!("install_native_confirmation_exit_unconfirmed"));}
            },
            _=tokio::time::sleep(Duration::from_secs(1))=> {
                if wire::write_packet(&mut writer,&Packet::Progress {sequence:1,nonce,phase:"awaiting_native_confirmation".into(),quiescent:false,machine_id:String::new()}).await.is_err() {
                    cancelled.store(true,Ordering::Release);
                }
            }
        }
    };
    if confirm.is_err() || cancelled.load(Ordering::Acquire) || Instant::now() >= expiry {
        cancelled.store(true, Ordering::Release);
        read_task.stop().await;
        bail!("install_local_native_consent_not_current");
    }
    let (request_tx, mut requests) = mpsc::unbounded_channel();
    let authority = Arc::new(BrokerAuthority {
        requests: request_tx,
        cancelled: Arc::clone(&cancelled),
        expiry,
        mode: release.mode(),
    });
    let origin = LocalApprovalGrant::from_kernel_caller(
        caller
            .as_ref()
            .ok_or_else(|| anyhow!("install_kernel_caller_unavailable"))?,
    )?;
    let consent_id: String = hbb_common::sodiumoxide::randombytes::randombytes(32)
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect();
    let consent = LocalConsent::from_explicit_local_action(consent_id, true, true, start)?
        .with_session_policies(virtual_display, auto_lock).with_privacy_policy(privacy)
        .with_restart_policy(restart).with_action(action);
    let confirmed = ConfirmedApproval {
        origin,
        server: current.server(),
        consent,
        authority,
    };
    let source = std::env::current_exe()?
        .parent()
        .ok_or_else(|| anyhow!("install_source_unavailable"))?
        .to_path_buf();
    let payload = release.payload().clone();
    let (progress_tx, mut progress_rx) = mpsc::unbounded_channel();
    let mut owned_worker = tokio::task::spawn_blocking(move || {
        worker(confirmed, password, source, payload, progress_tx)
    });
    let mut sequence = 1u64;
    let mut input_open = true;
    let result = loop {
        tokio::select! {
            result=&mut owned_worker=>break match result {Ok(value)=>value,Err(_)=>Err(anyhow!("install_worker_exit_unconfirmed"))},
            Some(refresh)=requests.recv()=> {
                let valid=validate_refresh(&mut writer,&mut input_rx,&mut caller,&current,&mut sequence,nonce,&cancelled).await.is_ok();
                if !valid {cancelled.store(true,Ordering::Release);}
                let _=refresh.reply.send(valid);
            }
            Some(progress)=progress_rx.recv()=> {
                if wire::write_packet(&mut writer,&Packet::Progress {sequence,nonce,phase:progress.phase.into(),quiescent:progress.quiescent,machine_id:String::new()}).await.is_err() {
                    cancelled.store(true,Ordering::Release);
                }
            }
            unsolicited=input_rx.recv(), if input_open=> {
                // Only a response to an actual current Read may refresh authority.
                input_open=unsolicited.is_some();cancelled.store(true,Ordering::Release);
            }
        }
    };
    cancelled.store(true, Ordering::Release);
    // A final packet is emitted only after the real worker has returned; the UI
    // still independently waits for this exact setup process to exit.
    let unconfirmed = result
        .as_ref()
        .err()
        .is_some_and(|e| e.to_string() == "install_worker_exit_unconfirmed");
    let _ = wire::write_packet(
        &mut writer,
        &Packet::Progress {
            sequence,
            nonce,
            phase: if unconfirmed {
                "recovery"
            } else if result.is_ok() {
                result.as_ref().unwrap().phase
            } else {
                "recovery_disabled"
            }
            .into(),
            quiescent: !unconfirmed,
            machine_id: result.as_ref().ok().map(|outcome|outcome.public_id.clone()).unwrap_or_default(),
        },
    )
    .await;
    read_task.stop().await;
    drop(writer);
    result.map(|_| ())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn cli_cannot_supply_password_server_or_grant() {
        let nonce = "a".repeat(64);
        let args = vec![
            "--broker".into(),
            nonce.clone().into(),
            "--ui-pid".into(),
            "42".into(),
        ];
        assert!(arguments(args).is_ok());
        assert!(arguments(vec![
            "--broker".into(),
            nonce.into(),
            "--ui-pid".into(),
            "0".into()
        ])
        .is_err());
        assert!(arguments(vec!["--approved".into(), "true".into()]).is_err());
    }
    #[test]
    fn closed_or_cancelled_authority_cannot_mint_fresh_consent() {
        let (tx, _rx) = mpsc::unbounded_channel();
        let authority = BrokerAuthority {
            requests: tx,
            cancelled: Arc::new(AtomicBool::new(true)),
            expiry: Instant::now() + std::time::Duration::from_secs(1),
            mode: TrustMode::ReviewedLocalUnsignedValidation,
        };
        assert!(authority.refresh().is_err());
    }
}
