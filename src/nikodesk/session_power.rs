//! Power requests remain on the captured desktop session and original sender.
use crate::{
    client::{Data, Interface},
    ui_session_interface::{InvokeUiSession, Session},
};

pub(crate) fn request_restart<T: InvokeUiSession>(session: &Session<T>) -> Result<(), &'static str> {
    if !session.is_default() { return Err("Remote restart requires a desktop session"); }
    if !*session.server_keyboard_enabled.read().map_err(|_| "Session permissions are unavailable")? {
        return Err("Remote restart requires keyboard control");
    }
    let snapshot = session.connection_snapshot().map_err(|_| "Session server could not be verified")?;
    let id = session.get_id();
    if !snapshot.peer_key(&id).is_some_and(|key| key.is_current()) {
        return Err("Session server changed. Reconnect before requesting a restart");
    }
    let sender = session.sender.read().map_err(|_| "Session worker is unavailable")?
        .clone().ok_or("Session is closed")?;
    let mut config = session.lc.write().map_err(|_| "Session configuration is unavailable")?;
    if config.peer_info.is_none() || config.get_toggle_option("view-only") {
        return Err("Remote restart requires an authenticated control session");
    }
    if config.restart_request_pending() {
        return Err("A restart request is already pending. Reconnect before retrying");
    }
    let message = config.restart_remote_device();
    sender.send(Data::Message(message)).map_err(|_| "Session is closed")?;
    // A failed queue submission must not put the UI into restart/reconnect mode.
    config.mark_restarting_remote_device();
    Ok(())
}
