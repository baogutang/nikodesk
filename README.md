<div align="center">

<img src="flutter/assets/readme-logo.png" width="360" alt="NikoDesk logo" />

# NikoDesk

**Your devices. Your server. Your remote desktop.**

A private-server remote desktop built on the native RustDesk core.

[![Release](https://img.shields.io/github/v/release/baogutang/nikodesk?style=flat-square&color=CC6D45)](https://github.com/baogutang/nikodesk/releases)
[![License](https://img.shields.io/badge/license-AGPL--3.0-8A7665?style=flat-square)](LICENCE)

**English** · [简体中文](README_zh.md) · [Website](https://baogutang.github.io/nikodesk/)

<img src="flutter/assets/readme-light.png" width="48%" alt="Redacted real NikoDesk light-theme workspace" /> <img src="flutter/assets/readme-dark.png" width="48%" alt="Redacted real NikoDesk dark-theme workspace" />

*Real local UI from an earlier build; device IDs, passwords and server details are redacted. Screenshots show appearance, not remote-session or performance acceptance.*

</div>

## Current status

NikoDesk is under development. **v1.0.0 is an archived test build and does not contain the fixes from the September 30 review.** Build artifacts alone do not establish a working application.

The latest package-checked local test build is **1.1.0+6 (unpublished, October 1, 2026)**. Full builds and package checks passed for the macOS DMG, complete-app update ZIP and Android APK; their common product source files match. Its product version is separate from the upstream core/protocol version. These packages have not been installed, launched or tested in real-device remote sessions; later source changes are not automatically included.

| Platform | v1.0.0 archive | Current validation (new local packages: 1.1.0+6) |
|---|---|---|
| macOS ARM64 | ZIP containing a complete `NikoDesk.app`; local ad-hoc signature, no Developer ID or notarization | Full Rust＋Flutter build, DMG/update ZIP structure and signature integrity verified. This package has not been installed, launched or remote-session tested. |
| Windows x64 | ZIP containing an EXE, DLLs and `data`; the NikoDesk initialization gate refuses to start | The earlier build4 validation CI completed the full MSVC＋Flutter build but failed its application identity checks. A second fixed CI repair awaits authorization. There is no accepted Windows package for this batch; Win10 launch and sessions remain unverified. |
| Android ARM64 | APK; the NikoDesk initialization gate refuses to start | Full Rust＋Gradle test APK, separate package ID, fixed local test certificate, 16KB and voice JNI retention checks verified. Controller only; Android 16 launch, upgrade, remote sessions and voice calls remain unverified. |

The old Windows and Android assets are available for inspection in [the v1.0.0 archive](https://github.com/baogutang/nikodesk/releases/tag/v1.0.0), and are not recommended for installation. New artifacts will be linked only after they are published and verified.

## What NikoDesk adds

- **Private-server configuration:** your ID server, relay server and server public key. Missing configuration keeps registration stopped; the NikoDesk feature disables upstream default public-rendezvous fallback.
- **Device workspace:** local aliases, groups, favorites, search and reconnect controls. Availability comes from server queries; unavailable evidence stays unknown.
- **Password entry before connecting:** the NikoDesk connection entry requires a remote password and does not save it in the device directory. Authentication and encryption are still checked by the peer.
- **Local history:** the last 200 connection attempts. An entry records initiation, not remote acceptance.
- **Native sessions:** preserves RustDesk capture, rendering, input, file transfer, clipboard and multi-display paths. Codec availability depends on both peers and the build; hardware acceleration is not guaranteed.
- **Diagnostics:** source-labelled session samples. Application RTT, successful decode-callback FPS and native submission-call timing are separate observations; they do not establish input-to-screen latency or actual presentation. Unknown measurements stay unknown.
- **Light and dark themes:** follow the system or choose in the app.

Terminal, port tunnels, camera and voice requests are off by default. Allowing requests does not grant local approval or establish that a resource is running. Terminal and camera connection/local-approval flows are implemented. Build6 integrates controller-initiated voice in ordinary desktop-control sessions, manual local device selection and microphone permission, the Android voice switch and cleanup after closing a session. Preparing or queuing a call does not establish that it has started; muting does not release the microphone. All these capabilities await real cross-device acceptance, and some Android Bluetooth combinations are unsupported.

Receiver-initiated voice, complete port tunnels, full unattended access, privacy screens, virtual displays, wake, restart and automatic locking are not delivered. Unfinished capabilities stay unavailable; source implementation and package checks are not a complete security audit.

## Getting started on macOS

1. Review the [release notes and SHA256SUMS](https://github.com/baogutang/nikodesk/releases/tag/v1.0.0). The existing ZIP is a historical build; packaging fixes are not published yet.
2. Extract and retain the complete `NikoDesk.app`. Do not launch a file from `Contents/MacOS` or separate its frameworks. GitHub Actions downloads may add an outer artifact ZIP around the application archive.
3. Configure your own [RustDesk Server OSS](https://github.com/rustdesk/rustdesk-server) in **Settings → Private server**: ID server, relay and **server public key**. Keep server private keys on the server.
4. Configure the other endpoint to use the same servers and public key. Check service reachability, registration, then password authentication in a real session; each proves something different.
5. When using the Mac as a controlled endpoint, grant Screen Recording for capture and Accessibility for remote input through macOS settings. Review individual session permissions before accepting. A control-only workflow should not require every receiver permission.

NikoDesk uses its own application identity, configuration and IPC namespace on macOS. Preserve an existing RustDesk installation while evaluating it. System security protections should remain enabled; local signing is not notarization.

## Network and updates

Registration and relay use your configured infrastructure. Authenticated peer-to-peer sessions also contact the negotiated peer address. Update checks and downloads contact GitHub, including its API and release-asset hosts. “Private server” does not mean every network packet goes to your NAS.

The revised macOS update flow checks a release checksum, validates and stages the application archive, then reveals it for **manual installation**. It does not automatically replace the installed app. This revision is not part of v1.0.0. Keep the previous app until a new version has been verified. Windows and Android do not have a verified in-app installation path.

SHA256 checks file consistency against a published digest. It does not authenticate the publisher or replace a trusted platform signature.

## Build from source

The native core must be built before Flutter. For macOS ARM64, first prepare the pinned Rust/Flutter toolchains, Xcode and vcpkg native dependencies described in [the build workflow](.github/workflows/release.yml). Set `VCPKG_ROOT` to that prepared vcpkg directory; use a project-local toolchain rather than changing a global SDK.

```bash
git clone --recurse-submodules https://github.com/baogutang/nikodesk.git
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
- macOS artifacts use local ad-hoc signatures, without Apple Developer ID signing or notarization. Android uses a fixed local test certificate; formal release signing and real-device upgrades remain unverified. Windows distribution signing remains unverified.
- Full cross-device testing, file/clipboard behavior, permission revocation and performance comparisons are separate acceptance work. No unmeasured speed or latency improvement is claimed.

## Project and license

- [Website](https://baogutang.github.io/nikodesk/) · [Issues](https://github.com/baogutang/nikodesk/issues) · [Release archive](https://github.com/baogutang/nikodesk/releases)
- [Original upstream README](docs/README_RUSTDESK_UPSTREAM.md)

NikoDesk is an independent downstream of [RustDesk](https://github.com/rustdesk/rustdesk), based on commit `e9ddbd8f` (1.5.0-pre). Its native remote-control core and upstream copyright notices are preserved. It is not affiliated with or endorsed by RustDesk.

[AGPL-3.0](LICENCE). Distributions and modifications must comply with the full license, including its corresponding-source obligations.
