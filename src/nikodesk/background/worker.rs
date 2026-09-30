//! Granted SystemDesktopWorker only. Password/2FA stay in the real connection core.
use super::{
    policy::Binding,
    protocol::{self, Packet},
    windows::Layout,
};
use hbb_common::{anyhow::anyhow, bail, tokio, ResultType};
use std::{
    sync::{atomic::Ordering, Arc, OnceLock},
    time::Duration,
};
use windows::Win32::{
    Foundation::HANDLE,
    System::{
        RemoteDesktop::WTSGetActiveConsoleSessionId,
        StationsAndDesktops::{
            CloseDesktop, GetUserObjectInformationW, OpenInputDesktop, DESKTOP_ACCESS_FLAGS,
            DESKTOP_CONTROL_FLAGS, DESKTOP_READOBJECTS, DESKTOP_SWITCHDESKTOP, UOI_NAME,
        },
    },
};
struct Desktop(windows::Win32::System::StationsAndDesktops::HDESK);
impl Drop for Desktop {
    fn drop(&mut self) {
        unsafe {
            let _ = CloseDesktop(self.0);
        }
    }
}
static DESKTOP_NAME: OnceLock<String> = OnceLock::new();
fn input_desktop_name() -> ResultType<String> {
    let desktop = Desktop(unsafe {
        OpenInputDesktop(
            DESKTOP_CONTROL_FLAGS(0),
            false,
            DESKTOP_ACCESS_FLAGS(DESKTOP_READOBJECTS.0 | DESKTOP_SWITCHDESKTOP.0),
        )?
    });
    let mut name = vec![0u16; 512];
    let mut needed = 0;
    unsafe {
        GetUserObjectInformationW(
            HANDLE(desktop.0 .0),
            UOI_NAME,
            Some(name.as_mut_ptr().cast()),
            (name.len() * 2) as u32,
            Some(&mut needed),
        )?;
    }
    if needed < 2 || needed as usize > name.len() * 2 {
        bail!("Invalid worker desktop name");
    }
    let len = name
        .iter()
        .position(|v| *v == 0)
        .ok_or_else(|| anyhow!("Invalid worker desktop name"))?;
    Ok(String::from_utf16(&name[..len])?)
}
pub(crate) fn desktop_matches() -> bool {
    if super::WORKER
        .get()
        .is_none_or(|binding| unsafe { WTSGetActiveConsoleSessionId() } != binding.session)
    {
        return false;
    }
    DESKTOP_NAME
        .get()
        .zip(input_desktop_name().ok().as_ref())
        .map_or(false, |(expected, current)| expected == current)
}
pub(crate) async fn run(
    layout: Arc<Layout>,
    binding: Binding,
    mut pipe: tokio::net::windows::named_pipe::NamedPipeClient,
) -> ResultType<()> {
    let name = input_desktop_name()?;
    DESKTOP_NAME
        .set(name)
        .map_err(|_| anyhow!("Worker desktop already selected"))?;
    super::enter_worker(binding)?;
    // Layout is a verified, SYSTEM-owned object produced solely by OS preflight.
    // Its protected handles remain alive for the entire remote-control loop.
    let root = layout.config.clone();
    tokio::task::spawn_blocking(move || crate::nikodesk::initialize_system_desktop_worker(root))
        .await??;
    if !crate::platform::windows::try_change_desktop() || !desktop_matches() {
        bail!("Cannot select the granted input desktop");
    }
    let core = crate::server::start_system_desktop_worker();
    let control = async {
        let start_deadline = tokio::time::Instant::now() + Duration::from_secs(10);
        while !super::CORE_BOOTSTRAPPED.load(Ordering::Acquire) {
            if !desktop_matches() || tokio::time::Instant::now() > start_deadline {
                bail!("Background core did not initialize on the granted desktop");
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        if !desktop_matches() {
            bail!("Worker desktop changed during initialization");
        }
        super::WORKER_ACTIVE.store(true, Ordering::Release);
        let Binding {
            session,
            generation,
            nonce,
        } = binding;
        protocol::write(
            &mut pipe,
            &Packet::Ready {
                session,
                generation,
                nonce,
                desktop_selected: true,
            },
        )
        .await?;
        let (mut reader, mut writer) = tokio::io::split(&mut pipe);
        let incoming = async {
            loop {
                let packet = protocol::read(&mut reader).await?;
                if packet.binding() != binding || !matches!(packet, Packet::Revoke { .. }) {
                    bail!("Unexpected host control packet");
                }
                super::revoke_worker();
                return Ok::<_, hbb_common::anyhow::Error>(());
            }
        };
        tokio::pin!(incoming);
        let mut heartbeat = tokio::time::interval(Duration::from_secs(1));
        loop {
            tokio::select! {
                result=&mut incoming=>{result?;break;},
                _=heartbeat.tick()=>{if !desktop_matches(){super::revoke_worker();break;}protocol::write(&mut writer,&Packet::Heartbeat{session,generation,nonce}).await?;},
                _=tokio::time::sleep(Duration::from_millis(100))=>{if !desktop_matches(){super::revoke_worker();break;}}
            }
        }
        Ok::<_, hbb_common::anyhow::Error>(())
    };
    tokio::select! {
        _ = core => {
            super::revoke_worker();
            crate::server::input_service::nikodesk_windows_input::revoke_worker_inputs();
            bail!("Background connection core ended unexpectedly");
        },
        result = control => {
            super::revoke_worker();
            crate::server::input_service::nikodesk_windows_input::revoke_worker_inputs();
            result?;
        }
    }
    super::revoke_worker();
    drop(layout);
    Ok(())
}

/// This replacement has no click-authorization channel and never sends
/// Data::Authorize (which would clear 2FA). Authenticated status is not authority.
/// Startup requires a separate machine preauthorization AND a permanent verifier;
/// the ordinary connection core still performs password and configured TOTP.
pub(crate) async fn connection_status(
    mut incoming: tokio::sync::mpsc::UnboundedReceiver<crate::ipc::Data>,
) -> ResultType<()> {
    while incoming.recv().await.is_some() {
        if !super::worker_active() {
            bail!("System desktop grant is no longer active");
        }
    }
    Ok(())
}
