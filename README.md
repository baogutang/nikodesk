<div align="center">

<img src="flutter/assets/readme-logo.png" width="360" alt="NikoDesk logo" />

# NikoDesk

**Your devices. Your server. Your remote desktop.**

A private-server remote desktop built on the native RustDesk core.

[![Release](https://img.shields.io/github/v/release/baogutang/nikodesk?style=flat-square&color=CC6D45)](https://github.com/baogutang/nikodesk/releases)
[![License](https://img.shields.io/badge/license-AGPL--3.0-8A7665?style=flat-square)](LICENCE)

**English** · [简体中文](README_zh.md) · [Website](https://baogutang.github.io/nikodesk/)

<img src="flutter/assets/readme-light.png" width="48%" alt="NikoDesk warm light workspace with synthetic example data" /> <img src="flutter/assets/readme-dark.png" width="48%" alt="NikoDesk dark workspace with synthetic example data" />

*Production Flutter workspace widgets rendered with synthetic example data, without a remote connection. [Explore the interactive website](https://baogutang.github.io/nikodesk/#nikodesk-demo).*

</div>

## Current status

**1.0.7+18 development candidate (not a stable release)** repairs successful-device history across desktop windows and adds automatic reuse of explicitly remembered credentials, unifies the current blue brand across platform icons, clarifies the manual update handoff, adds the selected light-trail startup animation with explicit failure feedback, displays local devices without waiting for optional status IPC once the server scope is known, and adds continuous privacy checks and recovery, bounded and cancellable directory scans, credential isolation for development builds, capture and FPS matching to the current session window, and recovery from ineffective automatic resolution changes. Signed update manifests must match a publisher key pinned in the client; formal promotion requires signed device acceptance of the exact candidate packages. The Rust OpenSSL bindings are patched to `openssl 0.10.72` / `openssl-sys 0.9.107`; this does not mean the full dependency audit is cleared. [Scope and release conditions](docs/RELEASE-1.0.7.md) · [Nightly build status (`main`)](https://github.com/baogutang/nikodesk/actions/workflows/release.yml?query=branch%3Amain). Build results and device acceptance are separate; the v1.0.6 download links below remain until a new stable release is published.

The versioned delivery channel is **[NikoDesk v1.0.6](https://github.com/baogutang/nikodesk/releases/tag/v1.0.6)** (product `1.0.6`, build `15`). Its tag triggers macOS ARM64, Windows x64 and Android ARM64 builds; packages appear only after the build and packaging checks pass. Every push to `main` builds all three platforms and replaces the rolling **[nightly pre-release](https://github.com/baogutang/nikodesk/releases/tag/nightly)**; `v*` tags create draft candidates for acceptance. The [v1.0.0 archive](https://github.com/baogutang/nikodesk/releases/tag/v1.0.0) is a historical test build — only its macOS ZIP remains published.

Version 1.0.6 makes the privacy screen something you can find and see: a toolbar button and a Control center switch turn it on, and a label stays on the remote picture for as long as it is on. Frame-rate limits go to 120, the **Responsive control** mode asks for the controller's own refresh rate instead of being held to 30, and a controlled Mac now reaches the limit it is given (a 60 limit used to send 54). The Windows program, portable package and tray, and the Android launcher, carry NikoDesk's icon instead of the upstream one. The privacy screen and the frame limits were verified in sessions between two identities on one Mac (the screen measurably blacked out and restored; 60, 75 and 75 new pictures a second at limits of 60, 75 and 120 on a 75 Hz display); the new interface and icons have not been looked at on Windows or Android devices. [Patch details](docs/RELEASE-1.0.6.md). The previous release, [1.0.5](docs/RELEASE-1.0.5.md), added capture scaling to the controller's screen and password-only login.

| Channel | macOS ARM64 | Windows x64 | Android ARM64 |
|---|---|---|---|
| [v1.0.6](https://github.com/baogutang/nikodesk/releases/tag/v1.0.6) / [nightly preview](https://github.com/baogutang/nikodesk/releases/tag/nightly) | DMG + updater ZIP, ad-hoc signed (no Apple Developer ID or notarization; right-click → Open on first launch) | Portable EXE/ZIP (no installation, runs beside RustDesk) + unattended-access setup-validation installer. Unsigned: SmartScreen asks once. The installer changes the system — use a test machine first. | Controller APK (`io.nikodesk.android`), signed with the dedicated NikoDesk release key and verified against the pinned certificate fingerprint |
| [v1.0.0](https://github.com/baogutang/nikodesk/releases/tag/v1.0.0) | Archived ZIP only | Removed (refused to start) | Removed (refused to start) |

**What is actually verified:** on the developer's Mac, two isolated NikoDesk identities ran real sessions through a private RustDesk server relay — password authentication with video, bidirectional file transfer (SHA-256 verified), TOTP two-factor authentication including replay rejection, session audit records on both ends, the remote terminal (request → local approval → command output), port tunnels (data verified through the tunnel), and picture modes (measurable bitrate/framerate changes). These are same-machine, same-user sessions: cross-device, cross-OS, Windows and Android real-device acceptance is still pending, and untested combinations stay unclaimed.

**Implementation scope:** existing source paths include unattended access, wake-on-LAN, privacy screen, virtual display, terminal, camera, tunnels, voice, two-factor authentication, session records and diagnostics, with platform-specific limits. Windows has the unattended service and virtual-display driver paths; macOS has gamma-based privacy blackout but no virtual-display implementation. Android is a controller, not a controlled endpoint. This is a capability inventory, not completion of the full roadmap; implementation and package checks are not a substitute for per-device acceptance.

## What NikoDesk adds

**Foundations**

- **Private-server first:** your ID server, relay server and server public key. Missing configuration keeps registration stopped; the NikoDesk build disables upstream public-rendezvous fallback.
- **Isolated identity:** its own application ID, configuration, IPC namespace and device keys. An installed RustDesk keeps working untouched beside it.
- **Device workspace:** aliases, groups, favorites, search, online status from real server queries, reconnect controls, and per-server session records (last 200 each).
- **Remembered credentials (1.0.7 candidate):** enter the remote password the first time and explicitly choose whether to remember it. After successful authentication, later user-initiated connections can reuse the saved credential without another password prompt. Invalid credentials require fresh authentication. Saved credentials are isolated by server and device in the system secure storage, never plain files.
- **Two-factor authentication:** TOTP with a durable, file-locked replay counter; a used code stays rejected across restarts, and a damaged record disables login instead of downgrading it.

**Sessions**

- **Native core:** RustDesk capture, codecs, input, file transfer, clipboard and multi-display paths are preserved. Picture modes (office / smooth / weak network) change what the controlled side really sends.
- **Video recovery:** a bounded per-display queue preserves encoded reference order, coalesces frame notifications and recovers from overload at a keyframe. A display without a decode estimate no longer disables the other displays' frame-rate feedback. Real VP8, VP9 and AV1 regression fixtures verify decoded pixels; real-network latency is still unmeasured.
- **Quick actions:** desktop and mobile sessions share copy, paste, select all, undo, save, switch application, fit-to-window and original-size controls. Keyboard shortcuts follow the remote operating system, recheck the current session and input permission, and release held keys after failure.
- **Cross-platform keys**: common Ctrl+C/V/X/A/Z/S/F/P/R editing shortcuts from Windows/Linux to Mac use Command automatically. Switch to original keys within the session for terminal Ctrl+C interruption. Control+arrow keeps its Mac Space meaning.
- **Full-screen apps and Spaces**: quick actions expose previous/next Space, Mission Control, app windows and previous/next app. Custom remote shortcuts and macOS Space settings affect the result; arbitrary full-screen windows are not enumerated or directly selected.
- **Connection feedback and diagnostics:** per-connection progress, relay route and decode statistics — labelled observations, not latency promises.
- **Extended capabilities, all off by default:** remote terminal, port tunnels, camera and voice (including receiver-initiated calls) each need a local per-capability policy and an approval from the controlled side's connection manager, which can revoke mid-session.

- **Update channel selection:** choose stable releases or the explicit nightly preview. Checks show the release name/time and link to that checked release; nightly is a manual download and does not pretend its rolling tag proves a newer build.

**Controlled-endpoint features**

- **Unattended access (Windows):** single-file installer, service lifecycle with recovery, machine-level permissions (virtual display, lock-on-disconnect, privacy screen, remote restart) default-off, and password rotation. The setup-validation installer is for test machines.
- **Privacy screen & virtual display:** macOS supports gamma-based blackout; virtual display is not implemented on macOS. Windows uses upstream's signed Amyuni display driver, bundled and byte-pinned in the package.
- **Wake-on-LAN:** wake a whitelisted machine directly, or through an authorized tunnel proxy when the controller is remote.
- **Lock on disconnect** and **remote restart**, each permission-gated.

Light and dark themes follow the system or your choice; the interface ships in English and 简体中文. Extended capabilities await real cross-device acceptance; some Android Bluetooth combinations are unsupported; unmeasured behavior stays unclaimed.

## Windows controlling Mac and full-screen apps

Choose automatic or original keys in **Control center → Local keyboard → Mac**. Automatic maps common Ctrl editing chords to Command; use original keys for terminal Ctrl+C interrupts. Map and Legacy modes support this feature. Combinations containing Shift, Alt/AltGr or Meta retain their meaning.

| Task | Control center action | Default Mac shortcut |
|---|---|---|
| Browse Spaces containing full-screen apps | Previous / next desktop | Control+← / → |
| View Spaces and windows | Task overview | Control+↑ |
| View the active app’s windows | App windows | Control+↓ |
| Switch apps | Switch / previous app | Command+Tab / Command+Shift+Tab |

These actions target the remote system. Local zoom and local full screen change only your view. Remote Mac settings determine whether switching an app also changes Space; customized system shortcuts affect the result.

## Sending fewer pixels

A 5K Mac captures `5120×2880` pixels per frame. A 4K controller cannot show nearly half of them, and every whole-screen change, such as unlocking or entering full screen, has to carry all of them.

**Control center → Picture size sent** (both ends on 1.0.5 or later, controlled side a Retina Mac): the controller says how wide a picture it can show, and the controlled Mac scales its capture towards that without touching its display mode or window layout. The scale moves in quarter steps of the Mac's point size, never below one pixel per point, and only to steps that give whole even pixel sizes; a display with no such step is captured at its native size. *Fit this screen* is the default: a controller reporting a 3840-pixel-wide screen gets `3840×2160` from a 5K Mac. *Smaller* is the Mac's standard size, one pixel per point (`2560×1440` on that Mac). *Remote native size* sends everything. The choice is saved per device; with several controllers the widest request wins. In single local runs at 90% quality and a 60 frame limit, with a window changing its whole content every two seconds, the picture was up to 954 ms behind at native size and up to 17 ms behind at 3840 and at 2560 pixels wide, while decoded frame rate and frame gaps were the same at all three sizes; a second native-size run stayed within 20 ms. Both ends were on one Mac, so none of this is a cross-device result, and no improvement in smoothness is claimed.

**Privacy screen** (1.0.6 for the button, switch and label): first allow it on the controlled computer under **Settings → Session security → Allow privacy screen for new connections** (off by default). Then use the toolbar's privacy screen button or **Control center → Privacy screen**. While it is on, the controlled Mac's displays are black and its own keyboard and mouse are paused; the controller's picture is unaffected and carries a "Privacy screen is on" label. Control + Option + Shift + Esc at the Mac (Esc on Windows), or ending the session, restores it. If it is on when you disconnect, the next session to that device turns it on again.

**Frame rate** (1.0.6): the custom limit goes to 120 and **Responsive control** asks for this screen's refresh rate (60 to 120). A controlled computer sends no more new pictures than its own display refreshes.

**In the 1.0.7 candidate**, automatic capture follows the session's visible canvas and its own display scale; Responsive control follows that window's display refresh rate. Window changes are debounced, while native capture, original/custom zoom and manually chosen FPS retain their intent. If automatic resolution matching changes the display mode without reducing the captured pixels, it restores the recorded previous mode when the reported mode still matches that request and the user has not made a later manual choice. These changes have automated regression coverage; physical monitor moves, Retina pointer accuracy and performance gains remain unverified.

**Control center → Remote resolution → Match this screen** also works with a controlled side older than 1.0.5 and switches the controlled display to the smallest mode, in its original aspect ratio, that still fills the controller's screen (`1920×1080` Retina, captured as `3840×2160`, for that pair). **Restore original** switches back. The controlled side also restores its mode when the last remote-control session disconnects, as long as NikoDesk there is still running. **Match automatically for this device** is off by default; when on, it matches after each connection unless the remote display is already in a non-original mode.

This changes the real display mode of the controlled computer, so anyone sitting at it sees the change, and a smaller Retina mode enlarges its interface. It needs input permission and one selected, non-virtual display. On a controlled computer without Retina scaling, a mode you pick by hand is remembered for that device and applied again on later connections until you restore the original. In a local measurement (both ends on one Mac) the matched mode sent about a third of the data and the frame rate did not change; see the [1.0.4 notes](docs/RELEASE-1.0.4.md).

## Getting started

1. Download from **[v1.0.6](https://github.com/baogutang/nikodesk/releases/tag/v1.0.6)** and verify against its `SHA256SUMS`. The macOS DMG installs a complete `NikoDesk.app` (ad-hoc signed: right-click → Open on the first launch). Windows runs the portable EXE beside an existing RustDesk; Android uses the same release application ID and signing key, with build 15 following build 14; actual device upgrade acceptance remains pending.
2. Configure your own [RustDesk Server OSS](https://github.com/rustdesk/rustdesk-server) in **Settings → Private server**: ID server, relay and **server public key**. Keep server private keys on the server.
3. Configure the other endpoint with the same servers and public key. Check service reachability, registration, then password authentication in a real session; each proves something different.
4. When using a Mac as a controlled endpoint, grant Screen Recording for capture and Accessibility for remote input through macOS settings. From 1.0.5, a valid password connects without a click on the controlled computer: the one-time password the app shows, or a permanent password once you have set it and allowed it. Such a session gets screen, keyboard and mouse, clipboard and file transfer by default. A wrong password or none still raises the confirmation prompt there. 1.0.4 and earlier waited for a click by default even with the right password, and a device updated from them moves to the new rule; to require a click for every session, choose click-only under Security in advanced settings after updating. Each extended capability still asks.

## Network and updates

Registration and relay use your configured infrastructure. Authenticated peer-to-peer sessions also contact the negotiated peer address. Update checks and downloads contact GitHub, including its API and release-asset hosts. “Private server” does not mean every network packet goes to your NAS.

**Settings → Software update** offers Stable and Nightly preview. Stable compares published version numbers; the preview shows its release identity and time for manual download. An earlier `1.1.0+9` development build has a higher numeric version than `1.0.5+14`, so use the v1.0.5 release page for that manual transition. Android upgrades are controlled by the increasing build number and the unchanged release certificate.

The macOS update flow in 1.0.5/1.0.6 downloads, validates and stages an archive for **manual installation**. It never replaced the app or restarted it automatically. The 1.0.7 candidate shows download, verification and unpacking states, keeps the result and installation steps visible within the current settings page, and preserves verified files if Finder cannot open them. A client without a pinned publisher key instead opens the release page for manual download. Save work, quit NikoDesk, replace the app at its original location, reopen it there and verify the version. macOS permissions may need to be granted again. Windows and Android do not have a verified in-app installation path.

SHA256 checks file consistency against a published digest. It does not authenticate the publisher or replace a trusted platform signature.

The **1.0.7 candidate** adds publisher verification before macOS update staging: the signed checksum manifest must identify the checked version and verify against the public key compiled into the client. A client without that key offers an explicit manual-download path. This gate does not add Apple Developer ID signing or notarization, preserve macOS permissions across updates, or retroactively protect older clients. Candidate builds and formal-release promotion remain separate.

## Build from source

The native core must be built before Flutter. For macOS ARM64, first prepare the pinned Rust/Flutter toolchains, Xcode and vcpkg native dependencies described in [the build workflow](.github/workflows/release.yml). Set `VCPKG_ROOT` to that prepared vcpkg directory; use a project-local toolchain rather than changing a global SDK.

```bash
git clone https://github.com/baogutang/nikodesk.git
cd nikodesk
cargo build --locked --lib --release \
  --features flutter,hwcodec,unix-file-copy-paste,screencapturekit,nikodesk
cp target/release/liblibrustdesk.dylib target/release/librustdesk.dylib
cd flutter
flutter pub get
FLUTTER_XCODE_ARCHS=arm64 FLUTTER_XCODE_ONLY_ACTIVE_ARCH=YES \
  flutter build macos --release --dart-define=NIKODESK=true
```

The output is `flutter/build/macos/Build/Products/Release/NikoDesk.app`. Packaging and signing are separate steps. The workflow pins Rust 1.88.0, Flutter 3.24.5 and vcpkg dependencies. Public build scripts allow inspection and rebuilding; byte-for-byte reproducibility has not been established. Windows and Android require their own native toolchains and runtime validation.

## Security and verification limits

- Uses upstream encryption and authentication; a server public key is not a remote-control password. Device private keys and server private keys have different owners and must not be copied between them.
- From 1.0.5 a valid password (the one-time password the app shows, or a permanent password that was set and allowed) connects without confirmation on the controlled side and gets screen, keyboard and mouse, clipboard and file transfer by default; a wrong password or none still raises the confirmation prompt there. Permission controls must be tested on the actual controlled platform. Set them to what you need rather than granting everything for convenience.
- macOS artifacts use local ad-hoc signatures, without Apple Developer ID signing or notarization. Android APKs are signed with the dedicated NikoDesk release key; real-device installs and upgrades remain unverified. Windows artifacts are unsigned.
- Full cross-device testing, file/clipboard behavior, permission revocation and performance comparisons are separate acceptance work. No unmeasured speed or latency improvement is claimed.

## Project and license

- [Website](https://baogutang.github.io/nikodesk/) · [Issues](https://github.com/baogutang/nikodesk/issues) · [Release archive](https://github.com/baogutang/nikodesk/releases)
- [Original upstream README](docs/README_RUSTDESK_UPSTREAM.md)

NikoDesk is an independent downstream of [RustDesk](https://github.com/rustdesk/rustdesk), based on commit `e9ddbd8f` (1.5.0-pre). Its native remote-control core and upstream copyright notices are preserved. It is not affiliated with or endorsed by RustDesk.

[AGPL-3.0](LICENCE). Distributions and modifications must comply with the full license, including its corresponding-source obligations.
