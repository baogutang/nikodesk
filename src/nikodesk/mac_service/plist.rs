//! The two launchd jobs of the privileged service and the shell steps that
//! install and remove them (run once with administrator rights). Pure text:
//! everything here is checked by unit tests.

pub(crate) const DAEMON_LABEL: &str = "io.nikodesk.service";
pub(crate) const AGENT_LABEL: &str = "io.nikodesk.server";
pub(crate) const BUNDLE_ID: &str = "io.nikodesk.macos";
/// launchd creates this socket and starts the daemon on the first connection.
pub(crate) const SOCKET_PATH: &str = "/var/run/io.nikodesk.service.sock";
pub(crate) const DAEMON_ARG: &str = "--nikodesk-service";
/// The same core mode as the user-level agent it replaces.
pub(crate) const AGENT_ARG: &str = "--nikodesk-background-agent";
pub(crate) const LEGACY_AGENT_LABEL: &str = "io.nikodesk.background";

pub(crate) fn daemon_path() -> String {
    format!("/Library/LaunchDaemons/{DAEMON_LABEL}.plist")
}

pub(crate) fn agent_path() -> String {
    format!("/Library/LaunchAgents/{AGENT_LABEL}.plist")
}

fn xml(text: &str) -> String {
    text.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
}

/// What launchd runs for the daemon: the app's service mode, or, when the app
/// is gone, the removal of both jobs (launchd cannot start a missing program,
/// so the app itself could never clean up).
pub(crate) fn daemon_command(executable: &str) -> String {
    format!(
        "if [ -x {exe} ]; then exec {exe} {DAEMON_ARG}; fi\nrm -f {agent} {daemon} {socket}\nlaunchctl bootout system/{DAEMON_LABEL}",
        exe = sh(executable),
        agent = sh(&agent_path()),
        daemon = sh(&daemon_path()),
        socket = sh(SOCKET_PATH),
    )
}

/// Started on demand through its socket, and once at boot to clean up after
/// a deleted app. It never runs the remote-control core.
pub(crate) fn daemon_plist(executable: &str) -> String {
    format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>{DAEMON_LABEL}</string>
    <key>AssociatedBundleIdentifiers</key>
    <string>{BUNDLE_ID}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/sh</string>
        <string>-c</string>
        <string>{command}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>Sockets</key>
    <dict>
        <key>Listener</key>
        <dict>
            <key>SockPathName</key>
            <string>{SOCKET_PATH}</string>
            <key>SockPathMode</key>
            <integer>438</integer>
        </dict>
    </dict>
</dict>
</plist>
"#,
        command = xml(&daemon_command(executable))
    )
}

/// The real core, in the login window and in each signed-in desktop. Restarted
/// only after a crash, three seconds apart.
pub(crate) fn agent_plist(executable: &str) -> String {
    format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>{AGENT_LABEL}</string>
    <key>AssociatedBundleIdentifiers</key>
    <string>{BUNDLE_ID}</string>
    <key>LimitLoadToSessionType</key>
    <array>
        <string>LoginWindow</string>
        <string>Aqua</string>
    </array>
    <key>ProgramArguments</key>
    <array>
        <string>{exe}</string>
        <string>{AGENT_ARG}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>ThrottleInterval</key>
    <integer>3</integer>
    <key>ProcessType</key>
    <string>Interactive</string>
</dict>
</plist>
"#,
        exe = xml(executable)
    )
}

/// Single-quoted for /bin/sh.
fn sh(text: &str) -> String {
    format!("'{}'", text.replace('\'', r"'\''"))
}

/// Shell steps run as root: write both jobs atomically, load the daemon,
/// load the agent into the user's session and retire the old user agent.
pub(crate) fn install_steps(executable: &str, uid: u32) -> String {
    let daemon = daemon_path();
    let agent = agent_path();
    let legacy = format!("$HOME_DIR/Library/LaunchAgents/{LEGACY_AGENT_LABEL}.plist");
    [
        "set -e".to_owned(),
        format!("HOME_DIR=$(dscl . -read /Users/$(id -nu {uid}) NFSHomeDirectory | awk '{{print $2}}')"),
        format!("printf %s {} > {}.new", sh(&daemon_plist(executable)), sh(&daemon)),
        format!("printf %s {} > {}.new", sh(&agent_plist(executable)), sh(&agent)),
        format!("chown root:wheel {d}.new {a}.new && chmod 644 {d}.new {a}.new", d = sh(&daemon), a = sh(&agent)),
        format!("mv -f {d}.new {d} && mv -f {a}.new {a}", d = sh(&daemon), a = sh(&agent)),
        format!("launchctl bootout system/{DAEMON_LABEL} 2>/dev/null || true"),
        format!("launchctl bootstrap system {}", sh(&daemon)),
        format!("launchctl bootout gui/{uid}/{LEGACY_AGENT_LABEL} 2>/dev/null || true"),
        format!("rm -f \"{legacy}\""),
        format!("launchctl bootout gui/{uid}/{AGENT_LABEL} 2>/dev/null || true"),
        format!("launchctl bootstrap gui/{uid} {}", sh(&agent)),
    ]
    .join("\n")
}

/// Shell steps run as root: unload and delete both jobs. The daemon goes
/// last because it may be the process running these steps.
pub(crate) fn uninstall_steps(uid: u32) -> String {
    [
        format!("launchctl bootout gui/{uid}/{AGENT_LABEL} 2>/dev/null || true"),
        format!("rm -f {} {}", sh(&agent_path()), sh(&daemon_path())),
        format!("rm -f {}", sh(SOCKET_PATH)),
        format!("launchctl bootout system/{DAEMON_LABEL} 2>/dev/null || true"),
    ]
    .join("\n")
}

/// AppleScript that runs `steps` with the system administrator prompt.
pub(crate) fn admin_script(steps: &str, prompt: &str) -> String {
    let quote = |text: &str| text.replace('\\', "\\\\").replace('"', "\\\"");
    format!(
        "do shell script \"{}\" with prompt \"{}\" with administrator privileges",
        quote(steps),
        quote(prompt)
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    const EXE: &str = "/Applications/NikoDesk.app/Contents/MacOS/NikoDesk";

    #[test]
    fn jobs_name_the_app_and_their_role() {
        let daemon = daemon_plist(EXE);
        assert!(daemon.contains("<string>io.nikodesk.service</string>"));
        assert!(daemon.contains("<string>/bin/sh</string>"));
        assert!(daemon.contains("exec '/Applications/NikoDesk.app/Contents/MacOS/NikoDesk' --nikodesk-service"));
        assert!(daemon.contains("launchctl bootout system/io.nikodesk.service"), "cleans up without the app");
        assert!(daemon.contains(SOCKET_PATH));
        assert!(daemon.contains("<integer>438</integer>"), "socket mode 0666");
        assert!(!daemon.contains("KeepAlive"), "on demand only");
        let agent = agent_plist(EXE);
        assert!(agent.contains("<string>LoginWindow</string>") && agent.contains("<string>Aqua</string>"));
        assert!(agent.contains("<string>--nikodesk-background-agent</string>"));
        assert!(agent.contains("<integer>3</integer>"));
        assert!(agent.contains("<string>Interactive</string>"));
    }

    #[test]
    fn odd_paths_cannot_break_out_of_plist_or_shell() {
        let exe = "/Applications/Niko's <Desk>&.app/x";
        let plist = agent_plist(exe);
        assert!(plist.contains("Niko's &lt;Desk&gt;&amp;.app"));
        assert!(daemon_plist(exe).contains(r"Niko'\''s &lt;Desk&gt;&amp;.app"));
        let steps = install_steps(exe, 501);
        assert!(steps.contains(r"Niko'\''s"), "single quotes are closed and reopened");
        let script = admin_script(&steps, "NikoDesk");
        // Inside the AppleScript literal every double quote is escaped.
        let literal = script
            .strip_prefix("do shell script \"")
            .and_then(|rest| rest.split_once("\" with prompt "))
            .map(|(literal, _)| literal)
            .unwrap();
        let bytes = literal.as_bytes();
        for (i, byte) in bytes.iter().enumerate() {
            if *byte == b'"' {
                let backslashes = bytes[..i].iter().rev().take_while(|b| **b == b'\\').count();
                assert!(backslashes % 2 == 1, "unescaped quote at {i}");
            }
        }
    }

    #[test]
    fn install_replaces_the_old_user_agent_and_uninstall_removes_both_jobs() {
        let steps = install_steps(EXE, 501);
        assert!(steps.starts_with("set -e"));
        assert!(steps.contains("launchctl bootstrap system '/Library/LaunchDaemons/io.nikodesk.service.plist'"));
        assert!(steps.contains("launchctl bootout gui/501/io.nikodesk.background"));
        assert!(steps.contains("launchctl bootstrap gui/501 '/Library/LaunchAgents/io.nikodesk.server.plist'"));
        let remove = uninstall_steps(501);
        assert!(remove.contains("rm -f '/Library/LaunchAgents/io.nikodesk.server.plist' '/Library/LaunchDaemons/io.nikodesk.service.plist'"));
        assert!(remove.trim_end().ends_with("launchctl bootout system/io.nikodesk.service 2>/dev/null || true"));
    }
}
