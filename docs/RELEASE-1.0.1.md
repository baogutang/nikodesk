# NikoDesk 1.0.1

Product version `1.0.1`, build number `10`. The native RustDesk protocol version remains `1.5.0`.

## Connection and video

NikoDesk now queues encoded video in one bounded FIFO per display. Keyframes and delta frames keep their reference order. At overload, the client requests the existing refresh path once and waits for a leading keyframe before replacing a broken reference chain. Decoder and display resets take effect with that recovery frame. Pending frame notifications are coalesced, and a display without a decode estimate no longer disables the other displays' frame-rate feedback.

The upstream path remains available with the NikoDesk feature disabled. No rendezvous protocol, authentication, encryption or decoder has been replaced. Regression fixtures use real VP8, VP9 and AV1 encoding and compare decoded pixels, including VP9 overload recovery. H264/H265 frame classification is covered; hardware decoding, network latency and cross-device input-to-photon measurements remain unverified.

## Daily operation

Desktop and Android control sessions share a quick-action panel: copy, paste, select all, undo, save, switch application, fit-to-window and original size. Shortcuts choose Command or Control/Alt according to the remote operating system. Dispatch rechecks connection, session identity and input permission; held keys are released after errors. Successful dispatch does not prove that the remote application acted on a shortcut. View adjustments remain available in a view-only session.

Software update settings offer stable and nightly preview channels. Stable keeps checksum and bundle validation before manual macOS installation. Preview checks show release identity and time and open the exact checked release page for manual download. Rolling nightly tags are not treated as monotonically increasing versions.

## Packages and verification

The main and version-tag workflows build macOS ARM64, Windows x64 and Android ARM64. macOS CI runs video recovery regressions, checks the upstream native path and runs Flutter tests with the product enabled and disabled. Formal publication waits for all platform builds and Windows packaging tests, requires all seven package files, and publishes `SHA256SUMS`.

- macOS: complete DMG and updater ZIP, ad-hoc signed; no Apple Developer ID or notarization.
- Windows: portable EXE/ZIP plus unattended setup-validation EXE/ZIP, unsigned. Use a test machine for installer acceptance.
- Android: controller APK, `io.nikodesk.android`, signed with the existing NikoDesk release key. Build 10 follows build 9; actual device upgrade acceptance remains pending.

Local validation for this revision: 914 Flutter tests passed with NikoDesk enabled; 893 passed with it disabled. Native NikoDesk tests: 506 passed, one optional synthetic probe ignored by the standard suite and executed separately. Packaging suite: 142 cases, one existing network-gated skip. Full Dart analysis has no errors or warnings, with 247 informational style/deprecation notices. The synthetic software-codec probe verifies queue behavior and decoded pixels; it does not establish a real-network speed advantage.

Existing runtime evidence covers two isolated identities on one Mac using a private server relay. Cross-device Windows/Android sessions, unattended system lifecycle, hardware video paths and comparative performance require separate acceptance. An existing RustDesk installation and its active session are preserved during development and packaging.

The previous development version `1.1.0+9` is numerically higher than `1.0.1+10`. Use the [v1.0.1 release page](https://github.com/baogutang/nikodesk/releases/tag/v1.0.1) for that manual transition; do not disable platform signature or version checks.
