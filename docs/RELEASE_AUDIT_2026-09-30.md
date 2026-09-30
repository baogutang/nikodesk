# Release and client audit — 2026-09-30

This audit examines the local `niko/main` checkout, public `v1.0.0` source/Release assets, bilingual README and GitHub Pages website. The published binaries predate the repairs below. Local source implementation, build checks, GUI launch and real remote-session acceptance are separate evidence levels.

## Confirmed defects and repairs

| Priority | Confirmed behavior in the previous revision | Local repair |
| --- | --- | --- |
| P1 | `nikodesk::initialize_inner` rejects every non-macOS platform. Windows exits before Flutter; Android also reaches the failing initializer. | Add current-user Windows identity/configuration/IPC isolation and fallible atomic settings persistence. Initialize Android from its separate app sandbox before the global Flutter event stream; preserve the real native remote-control core. |
| P1 | Android uses upstream `com.carriez.flutter_hbb` as application ID, colliding with RustDesk installation/signing expectations. | Separate `nikodesk` flavor: `io.nikodesk.android`, and explicit test signing uses `io.nikodesk.android.dev`. Retain the original Kotlin/JNI namespace for bridge compatibility. Remove incoming-control services and permissions only from the NikoDesk flavor. |
| P1 | The updater's default HTTP redirects can bypass its explicit host checks. | Disable automatic redirect following on every request and validate each resolved redirect before requesting it. |
| P1 | The updater deletes the installed app before a detached replacement attempt succeeds. | Verify the archive, bundle, architecture and signature, then reveal a staged app for manual installation. Do not delete the running installation or exit it automatically. |
| P2 | The portable packer uses `rustdesk.exe` while the Windows runner is `NikoDesk.exe`; the workflow publishes the raw bundle ZIP. Its old install/Quick Support path can request elevation or touch RustDesk's RuntimeBroker. | Pack the actual NikoDesk payload into a separate user-mode portable EXE. Use an `asInvoker` manifest and isolated extraction directory; disable injected installation arguments and shared RuntimeBroker handling only for NikoDesk. |
| P2 | macOS CI creates a ZIP but no installation DMG. | Add a verified DMG containing the full app and an Applications shortcut; retain the ZIP for update downloads. |
| P2 | The mobile home uses upstream product navigation and desktop components overflow at 320 px. | Add a three-tab Android controller home using existing device, history and private-server gateways; keep native mobile session rendering/input. Fix narrow connection fields and action rows. |
| P2 | README/site overstate platform availability, security/update guarantees and recording support. Screenshots include blank/wrong areas and device/server information. | Correct both languages, redact real local captures using local tools, replace old image payloads, and preserve the warm cream/terracotta design. |

## Published archives

The downloaded `NikoDesk-macos-arm64.zip` matches the published SHA256. It contains one complete `NikoDesk.app`: bundle ID `io.nikodesk.macos`, executable `NikoDesk`, version `1.0.0`, minimum macOS `12.3`, and ARM64 runner/core. Strict deep code-signature verification passes. `Contents`, `Frameworks` and `Resources` are normal app internals and must stay together. This user-space bundle does not require the privileged service helper.

The Windows ZIP also matches its published digest and contains the EXE, DLLs and Flutter `data` directory. A raw Flutter bundle needs all these files; extracting only its EXE will not work. Archive correctness does not repair the independent non-macOS initialization bug. GitHub Actions artifact downloads may add another ZIP layer around the actual package files.

The DMG under `artifacts/audit-20260930/repackaged-v1.0.0/` is a verified repackaging of the original published app. It does **not** contain today's client code. New source builds and packages have separate manifests/logs.

## Executed evidence

- Native macOS core isolation regression: 14 passed, including Android sandbox path validation and rejection of upstream application paths. These Android path tests execute on the macOS host.
- Updater regression: 21 passed with HTTP/process substitutes. One additional integration check stages the actual published macOS archive using real `unzip`, `lipo`, `plutil` and strict `codesign`; it does not launch or install it.
- Portable packer feature-on/off: 10 passed each; generator: 2 passed; Android merged-package gate: 4 passed, all on macOS. Windows private I/O source and four test bodies pass GNU-target API cross-compilation, without execution. Windows-native application checks remain pending.
- Website static checks and real browser desktop/mobile/theme/navigation checks are recorded under `artifacts/audit-20260930/`. App screenshots are real historical captures with documented local redactions.
- Final NikoDesk Flutter regression: 81 passed. Changed Dart analysis has no errors or warnings, with six inherited main.dart deprecation information messages. Full macOS build/package and platform-specific checks are tracked in the workspace's `docs/VALIDATION.md`; pending items are not implied by the above counts.

## Remaining acceptance

1. Build the full Windows app on its native runner, then verify fresh startup, restart identity, private-server settings, RustDesk coexistence and an actual authorized session on the user's Windows computer.
2. Build and inspect the Android APK/merged manifest, then verify installation, startup, private settings, password failure, touch/input, clipboard, files, rotation and reconnect on the user's real device. A fresh CI debug key does not provide stable APK upgrades.
3. Verify macOS launch and receiver permissions separately for the new build. Keep the installed client and original RustDesk unchanged until the user authorizes replacement/testing.
4. Measure real session latency/frame intervals against a reproducible baseline before promising performance gains. Complete publisher signing/notarization and stable Android signing before broad distribution; SHA256 verifies consistency, not publisher identity.

## Regression surfaces

Shared identity initialization and early FFI branding; private-server persistence and event-stream ordering; macOS update staging; Windows registry/bootstrap, elevation guards and portable extraction; Android flavor/manifest and controller navigation; desktop connection-card layout and device/history stores; bilingual website links, images and responsive layout. Feature-off native paths remain upstream where practical; Android upstream builds now select the explicit `rustdesk` flavor.

## Scope

Only local source, packaging and documentation were modified. No GitHub push, Release publication, CI dispatch, NAS write, remote session, app installation, permission change or service installation was performed. Existing RustDesk and NikoDesk installations were not replaced or launched by this review. The user has confirmed Windows and Android devices are available; availability is not execution evidence.

Build instructions: [BUILDING.md](BUILDING.md). Local progress/security/deployment/validation records live in the parent workspace's `docs/` directory and are not uploaded as release assets.
