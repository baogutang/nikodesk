//! The launchd jobs of the privileged service and the shell steps that
//! install and remove them (run once with administrator rights). Pure text:
//! everything here is checked by unit tests.
use crate::{REQUIREMENT, SERVICE_REQUIREMENT};

pub const DAEMON_LABEL: &str = "io.nikodesk.service";
pub const AGENT_LABEL: &str = "io.nikodesk.server";
pub const BUNDLE_ID: &str = "io.nikodesk.macos";
/// launchd creates this socket and starts the daemon on the first connection.
pub const SOCKET_PATH: &str = "/var/run/io.nikodesk.service.sock";
/// The same core mode as the user-level agent it replaces.
pub const AGENT_ARG: &str = "--nikodesk-background-agent";
pub const LEGACY_AGENT_LABEL: &str = "io.nikodesk.background";
/// The app the user runs, and the only location the service updates.
pub const INSTALLED_APP: &str = "/Applications/NikoDesk.app";
/// Root-owned (0700): root's copy of the app and the update work area.
pub const SERVICE_ROOT: &str = "/Library/Application Support/NikoDesk";

pub fn service_app() -> String {
    format!("{SERVICE_ROOT}/service/NikoDesk.app")
}

pub fn service_executable() -> String {
    format!("{}/Contents/MacOS/nikodesk-service", service_app())
}

pub fn update_dir() -> String {
    format!("{SERVICE_ROOT}/update")
}

pub fn daemon_path() -> String {
    format!("/Library/LaunchDaemons/{DAEMON_LABEL}.plist")
}

pub fn agent_path() -> String {
    format!("/Library/LaunchAgents/{AGENT_LABEL}.plist")
}

fn xml(text: &str) -> String {
    text.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
}

/// Single-quoted for /bin/sh.
fn sh(text: &str) -> String {
    format!("'{}'", text.replace('\'', r"'\''"))
}

/// What launchd runs for the daemon: root's copy, or, once the app is gone
/// from /Applications, the removal of everything the service installed.
pub fn daemon_command(uid: u32) -> String {
    format!(
        "if [ -d {app} ] && [ -x {exe} ]; then exec {exe}; fi\n{remove}",
        app = sh(INSTALLED_APP),
        exe = sh(&service_executable()),
        remove = uninstall_steps(uid),
    )
}

/// Started on demand through its socket, and once at boot to clean up after
/// a deleted app. It never runs the remote-control core.
pub fn daemon_plist(uid: u32) -> String {
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
        command = xml(&daemon_command(uid))
    )
}

/// The real core in each signed-in desktop, as that user, from /Applications.
/// Restarted only after a crash, three seconds apart. The login window (root)
/// is not served yet; when it is, it gets its own job running root's copy.
pub fn agent_plist() -> String {
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
        exe = xml(&format!("{INSTALLED_APP}/Contents/MacOS/NikoDesk"))
    )
}

/// Shell steps run as root: copy the app into the root-owned directory and
/// check the copy there (the user can no longer change it), write both jobs
/// atomically, load the daemon, load the agent into the user's session and
/// retire the old user agent.
pub fn install_steps(uid: u32) -> String {
    let root = sh(SERVICE_ROOT);
    let next = format!("{SERVICE_ROOT}/service.new");
    let next_app = format!("{next}/NikoDesk.app");
    let daemon = daemon_path();
    let agent = agent_path();
    let legacy = format!("$HOME_DIR/Library/LaunchAgents/{LEGACY_AGENT_LABEL}.plist");
    [
        "set -e".to_owned(),
        format!("HOME_DIR=$(dscl . -read /Users/$(id -nu {uid}) NFSHomeDirectory | awk '{{print $2}}')"),
        format!("mkdir -p {root} && chown root:wheel {root} && chmod 700 {root}"),
        format!("rm -rf {n} && mkdir -m 700 {n}", n = sh(&next)),
        format!("/usr/bin/ditto {} {}", sh(INSTALLED_APP), sh(&next_app)),
        // ditto keeps the user as owner; root takes its copy over.
        format!("chown -R -h root:wheel {n} && chmod -R -h go-w {n}", n = sh(&next)),
        format!(
            "/usr/bin/codesign --verify --deep --strict {} {}",
            sh(&format!("-R={REQUIREMENT}")),
            sh(&next_app)
        ),
        format!(
            "/usr/bin/codesign --verify --strict {} {}",
            sh(&format!("-R={SERVICE_REQUIREMENT}")),
            sh(&format!("{next_app}/Contents/MacOS/nikodesk-service"))
        ),
        format!("rm -rf {s} && mv {n} {s}", s = sh(&format!("{SERVICE_ROOT}/service")), n = sh(&next)),
        format!("printf %s {} > {}.new", sh(&daemon_plist(uid)), sh(&daemon)),
        format!("printf %s {} > {}.new", sh(&agent_plist()), sh(&agent)),
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

/// Shell steps run as root: unload and delete everything the service
/// installed. The daemon goes last because it may be running these steps.
pub fn uninstall_steps(uid: u32) -> String {
    [
        format!("launchctl bootout gui/{uid}/{AGENT_LABEL} 2>/dev/null || true"),
        format!("rm -f {} {}", sh(&agent_path()), sh(&daemon_path())),
        format!("rm -f {}", sh(SOCKET_PATH)),
        format!("rm -rf {}", sh(SERVICE_ROOT)),
        format!("launchctl bootout system/{DAEMON_LABEL} 2>/dev/null || true"),
    ]
    .join("\n")
}

/// AppleScript that runs `steps` with the system administrator prompt.
pub fn admin_script(steps: &str, prompt: &str) -> String {
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

    #[test]
    fn root_runs_only_its_own_copy_and_the_user_agent_runs_from_applications() {
        let daemon = daemon_plist(501);
        assert!(daemon.contains("<string>io.nikodesk.service</string>"));
        assert!(daemon.contains("<string>/bin/sh</string>"));
        assert!(daemon.contains(
            "exec '/Library/Application Support/NikoDesk/service/NikoDesk.app/Contents/MacOS/nikodesk-service'"
        ));
        assert!(!daemon.contains("exec '/Applications"), "root never starts code from /Applications");
        assert!(daemon.contains("launchctl bootout system/io.nikodesk.service"), "cleans up without the app");
        assert!(daemon.contains(SOCKET_PATH));
        assert!(daemon.contains("<integer>438</integer>"), "socket mode 0666");
        assert!(!daemon.contains("KeepAlive"), "on demand only");
        let agent = agent_plist();
        assert!(agent.contains("<string>Aqua</string>"));
        assert!(!agent.contains("LoginWindow"), "the login window would run it as root");
        assert!(agent.contains("<string>/Applications/NikoDesk.app/Contents/MacOS/NikoDesk</string>"));
        assert!(agent.contains("<string>--nikodesk-background-agent</string>"));
        assert!(agent.contains("<integer>3</integer>"));
        assert!(agent.contains("<string>Interactive</string>"));
    }

    #[test]
    fn install_checks_the_copy_before_any_job_points_at_it() {
        let steps = install_steps(501);
        assert!(steps.starts_with("set -e"));
        let at = |needle: &str| steps.find(needle).unwrap_or_else(|| panic!("missing {needle}"));
        let copy = at("/usr/bin/ditto '/Applications/NikoDesk.app' '/Library/Application Support/NikoDesk/service.new/NikoDesk.app'");
        let app_check = at(r#"'-R=identifier "io.nikodesk.macos" and certificate leaf = H"7C5F3E1E513BDCD4DEF443C7D71FE98FF07392A9"'"#);
        let service_check = at(r#"'-R=identifier "io.nikodesk.service" and certificate leaf"#);
        let seal = at("chown -R -h root:wheel '/Library/Application Support/NikoDesk/service.new' && chmod -R -h go-w");
        let promote = at("mv '/Library/Application Support/NikoDesk/service.new' '/Library/Application Support/NikoDesk/service'");
        let load = at("launchctl bootstrap system '/Library/LaunchDaemons/io.nikodesk.service.plist'");
        assert!(copy < seal && seal < app_check && app_check < service_check && service_check < promote && promote < load);
        assert!(steps.contains("chmod 700 '/Library/Application Support/NikoDesk'"));
        assert!(steps.contains("launchctl bootout gui/501/io.nikodesk.background"));
        assert!(steps.contains("launchctl bootstrap gui/501 '/Library/LaunchAgents/io.nikodesk.server.plist'"));
        let remove = uninstall_steps(501);
        assert!(remove.contains("rm -f '/Library/LaunchAgents/io.nikodesk.server.plist' '/Library/LaunchDaemons/io.nikodesk.service.plist'"));
        assert!(remove.contains("rm -rf '/Library/Application Support/NikoDesk'"));
        assert!(remove.trim_end().ends_with("launchctl bootout system/io.nikodesk.service 2>/dev/null || true"));
    }

    #[test]
    fn steps_survive_shell_and_applescript_quoting() {
        let steps = install_steps(501);
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
        // The plist text embedded with printf keeps its quotes balanced for sh.
        assert!(sh("it's").contains(r"'\''"));
    }
}
