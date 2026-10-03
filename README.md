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

The versioned delivery channel is **[NikoDesk v1.0.4](https://github.com/baogutang/nikodesk/releases/tag/v1.0.4)** (product `1.0.4`, build `13`). Its tag triggers macOS ARM64, Windows x64 and Android ARM64 builds; packages appear only after the build and packaging checks pass. Every push to `main` builds all three platforms and replaces the rolling **[nightly pre-release](https://github.com/baogutang/nikodesk/releases/tag/nightly)**; `v*` tags publish formal releases. The [v1.0.0 archive](https://github.com/baogutang/nikodesk/releases/tag/v1.0.0) is a historical test build — only its macOS ZIP remains published.

Version 1.0.4 stops restarting the registration with the private server every time one setting is saved (0.1–0.9 s per restart in local logs), and adds **Remote resolution** to the control center: one action switches the controlled display to a smaller mode that still fills the controller's screen, optionally on every connection to that device. For a controller screen 3840 pixels wide, a 5K Mac goes from `5120×2880` to `3840×2160` captured pixels. The switch and its restore were verified in a session between two identities on one Mac; the control-center action has not yet been run from a Windows or Android controller. [Patch details](docs/RELEASE-1.0.4.md).

| Channel | macOS ARM64 | Windows x64 | Android ARM64 |
|---|---|---|---|
| [v1.0.4](https://github.com/baogutang/nikodesk/releases/tag/v1.0.4) / [nightly preview](https://github.com/baogutang/nikodesk/releases/tag/nightly) | DMG + updater ZIP, ad-hoc signed (no Apple Developer ID or notarization; right-click → Open on first launch) | Portable EXE/ZIP (no installation, runs beside RustDesk) + unattended-access setup-validation installer. Unsigned: SmartScreen asks once. The installer changes the system — use a test machine first. | Controller APK (`io.nikodesk.android`), signed with the dedicated NikoDesk release key and verified against the pinned certificate fingerprint |
| [v1.0.0](https://github.com/baogutang/nikodesk/releases/tag/v1.0.0) | Archived ZIP only | Removed (refused to start) | Removed (refused to start) |

**What is actually verified:** on the developer's Mac, two isolated NikoDesk identities ran real sessions through a private RustDesk server relay — password authentication with video, bidirectional file transfer (SHA-256 verified), TOTP two-factor authentication including replay rejection, session audit records on both ends, the remote terminal (request → local approval → command output), port tunnels (data verified through the tunnel), and picture modes (measurable bitrate/framerate changes). These are same-machine, same-user sessions: cross-device, cross-OS, Windows and Android real-device acceptance is still pending, and untested combinations stay unclaimed.

**Implementation scope:** all planned capabilities are implemented in the source — unattended access, wake-on-LAN, privacy screen, virtual display, terminal, camera, tunnels, voice, two-factor authentication, session records and diagnostics across macOS, Windows and Android. Implementation and package checks are not a substitute for per-device acceptance.

## What NikoDesk adds

**Foundations**

- **Private-server first:** your ID server, relay server and server public key. Missing configuration keeps registration stopped; the NikoDesk build disables upstream public-rendezvous fallback.
- **Isolated identity:** its own application ID, configuration, IPC namespace and device keys. An installed RustDesk keeps working untouched beside it.
- **Device workspace:** aliases, groups, favorites, search, online status from real server queries, reconnect controls, and per-server session records (last 200 each).
- **Password before connecting:** the connection entry requires the remote password; saved credentials go to the system secure storage per server scope, never to plain files.
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
- **Privacy screen & virtual display:** macOS gamma-based blackout; Windows uses upstream's signed Amyuni display driver, bundled and byte-pinned in the package.
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

## Sending fewer pixels: remote resolution

A 5K Mac captures `5120×2880` pixels per frame; a 4K controller cannot show nearly half of them. **Control center → Remote resolution → Match this screen** switches the controlled display to the smallest mode, in its original aspect ratio, that still fills the controller's screen (`1920×1080` Retina, captured as `3840×2160`, for that pair). **Restore original** switches back. The controlled side also restores its mode when the last remote-control session disconnects, as long as NikoDesk there is still running. **Match automatically for this device** is off by default; when on, it matches after each connection unless the remote display is already in a non-original mode.

This changes the real display mode of the controlled computer, so anyone sitting at it sees the change, and a smaller Retina mode enlarges its interface. It needs input permission and one selected, non-virtual display. On a controlled computer without Retina scaling, a mode you pick by hand is remembered for that device and applied again on later connections until you restore the original. The effect on frame rate has not been measured yet.

## Getting started

1. Download from **[v1.0.4](https://github.com/baogutang/nikodesk/releases/tag/v1.0.4)** and verify against its `SHA256SUMS`. The macOS DMG installs a complete `NikoDesk.app` (ad-hoc signed: right-click → Open on the first launch). Windows runs the portable EXE beside an existing RustDesk; Android uses the same release application ID and signing key, with build 13 following build 12; actual device upgrade acceptance remains pending.
2. Configure your own [RustDesk Server OSS](https://github.com/rustdesk/rustdesk-server) in **Settings → Private server**: ID server, relay and **server public key**. Keep server private keys on the server.
3. Configure the other endpoint with the same servers and public key. Check service reachability, registration, then password authentication in a real session; each proves something different.
4. When using a Mac as a controlled endpoint, grant Screen Recording for capture and Accessibility for remote input through macOS settings. Review individual session permissions before accepting; each extended capability still asks.

## Network and updates

Registration and relay use your configured infrastructure. Authenticated peer-to-peer sessions also contact the negotiated peer address. Update checks and downloads contact GitHub, including its API and release-asset hosts. “Private server” does not mean every network packet goes to your NAS.

**Settings → Software update** offers Stable and Nightly preview. Stable compares published version numbers; the preview shows its release identity and time for manual download. An earlier `1.1.0+9` development build has a higher numeric version than `1.0.4+13`, so use the v1.0.4 release page for that manual transition. Android upgrades are controlled by the increasing build number and the unchanged release certificate.

The macOS update flow checks a release checksum, validates and stages the application archive, then reveals it for **manual installation**. It does not automatically replace the installed app. This revision is not part of v1.0.0. Keep the previous app until a new version has been verified. Windows and Android do not have a verified in-app installation path.

SHA256 checks file consistency against a published digest. It does not authenticate the publisher or replace a trusted platform signature.

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
- Session confirmation and permission controls must be tested on the actual controlled platform. Review the requested capabilities rather than granting everything for convenience.
- macOS artifacts use local ad-hoc signatures, without Apple Developer ID signing or notarization. Android APKs are signed with the dedicated NikoDesk release key; real-device installs and upgrades remain unverified. Windows artifacts are unsigned.
- Full cross-device testing, file/clipboard behavior, permission revocation and performance comparisons are separate acceptance work. No unmeasured speed or latency improvement is claimed.

## Project and license

- [Website](https://baogutang.github.io/nikodesk/) · [Issues](https://github.com/baogutang/nikodesk/issues) · [Release archive](https://github.com/baogutang/nikodesk/releases)
- [Original upstream README](docs/README_RUSTDESK_UPSTREAM.md)

NikoDesk is an independent downstream of [RustDesk](https://github.com/rustdesk/rustdesk), based on commit `e9ddbd8f` (1.5.0-pre). Its native remote-control core and upstream copyright notices are preserved. It is not affiliated with or endorsed by RustDesk.

[AGPL-3.0](LICENCE). Distributions and modifications must comply with the full license, including its corresponding-source obligations.
