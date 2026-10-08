# NikoDesk 1.0.7+18 — formal release

**[Download v1.0.7](https://github.com/baogutang/nikodesk/releases/tag/v1.0.7)**

Published with the maintainer's explicit authorization using the same seven
packages verified from successful [build 37726367056](https://github.com/baogutang/nikodesk/actions/runs/37726367056).
The tag and binaries correspond to public source
[`4423a266cf01e1cef687530871e0bd16d10c8dcc`](https://github.com/baogutang/nikodesk/commit/4423a266cf01e1cef687530871e0bd16d10c8dcc).
No application rebuild was performed for formal publication. Every package was
downloaded and matched to the CI artifact and published SHA-256 checksum;
platform version, entrypoint, archive, icon and source checks passed.

This is a manual maintainer-authorized release. The automated signed-acceptance
promotion workflow described below was not used or changed. No unperformed
acceptance gate is represented as passed. Target-device upgrades and real
cross-device sessions remain unverified for this build. macOS is ad-hoc signed
without Developer ID or notarization, Windows is unsigned, and Android uses the
existing NikoDesk release certificate. The Windows setup-validation files retain
their installation-preview status. Installation remains manual; automatic app
replacement/restart is not implemented. No publisher-key pin or signed update
manifest is supplied, so this client uses the explicit manual-download path.

## Changes

### Build 18: connection history and remembered credentials

- Successful desktop sessions record the device in the immutable server scope
  of that session. A separate Windows remote window no longer writes success
  into an unconfigured directory hidden from the main window. Existing ambiguous
  unconfigured records are retained, not assigned to an arbitrary server.
- The actual-session history refreshes while visible and offers reconnection
  for eligible controller records. Controlled-end records never become a way
  to connect to an untrusted self-reported peer ID.
- The quick connection entry offers an explicit remember choice. Authentication
  success is still required before saving. Later user-initiated connections
  reuse available system-stored credentials without an extra password dialog;
  external links retain their confirmation boundary. Invalid saved credentials
  require a fresh password, and replacements are stored only after success.
- The default remains not to save a password without an explicit choice. No
  plaintext passwords or private keys are copied into the device/history files.
  Cross-device Windows installation and real credential-store acceptance remain
  separate from the synthetic regression tests.

### Build 17: icon consistency, update handoff and startup responsiveness

- Windows application, portable/setup and background executable icons and Android
  launcher/adaptive/monochrome icons now use the canonical blue NikoDesk brand.
  macOS ICNS is rebuilt with Apple iconutil to improve system decoding compatibility
  for small image slots.
  CI checks canonical inputs and the icons in the final platform packages.
  Existing macOS permission records/caches and installed applications are untouched;
  their visible icons still need installation-side verification.
- Update status distinguishes downloading, verifying and unpacking. Installation
  steps and file locations remain visible in the current settings page; a Finder
  failure preserves verified files and offers a retry. Browser-opening failure
  is visible. This remains manual installation, with no automatic replacement or
  restart; page-local status is not persisted across app restarts.
- Once the private-server namespace is known, local devices render without
  waiting for optional status IPC. Unknown configuration and connection gates
  remain unchanged. Five widget regressions cover this path.
- The English/Chinese website is reorganized around everyday use, private
  connections and clear download choices. Engineering details belong here and
  in GitHub release notes. The selected light-trail startup design is implemented
  with Flutter animations in the desktop main window. Readiness interrupts the
  entry immediately; reduced motion is supported. Slow visible startup offers
  an exit, and initialization failure opens a standalone error page instead of
  continuing with partial core bindings. Initial-link and hidden-window rules
  are retained. Native initialization before Flutter, and core-dependent hidden
  window preparation, are outside the visible animation. Real startup timings
  remain unmeasured. `design/startup` retains the three review demos.

### Build 16 foundations

- macOS privacy protection continues checking the recorded display gamma and
  local input filter after the initial five seconds. Protection loss notifies
  the controller; failed restoration retains its owner and retries. Reopening
  an inactive mode cannot rely on the old same-owner success shortcut.
- File listing and transfer initialization run on bounded workers. Cancellation,
  permission revocation, disconnection and request generations discard stale
  results. The 30-second, 100,000-entry, depth-128 and 16-MiB-name budgets fail
  explicitly; they never return a truncated successful list. At most four scan
  workers run per process. An OS-blocked filesystem call cannot be interrupted;
  its worker stays bounded until the OS returns.
- Development-profile binaries refuse every persistent credential operation,
  even without a profile environment variable. Production credential keys are
  unchanged; saved passwords are not migrated or deleted.
- Capture matching and responsive-control refresh rate use the current session
  window rather than the largest or fastest of all attached displays. Resize
  changes are debounced; manual capture modes and manual FPS remain in charge.
  Automatic remote-resolution rollback checks the actual reported display mode,
  including scale, instead of waiting only for changed captured pixels.
- macOS update staging requires a version-bound checksum manifest authenticated
  by a public key compiled into the client. Missing keys use an explicit manual
  download path. A checksum alone is not publisher authentication.
- The Rust OpenSSL bindings are pinned to `openssl 0.10.72` with
  `openssl-sys 0.9.107`, addressing
  RUSTSEC-2025-0004 and RUSTSEC-2025-0022. Android/Linux compilation and TLS
  acceptance remain separate from the macOS build.
- Version is `1.0.7+18`; upstream protocol version is unchanged. The known old
  `1.1.0+9` preview can open the stable release page for a manual transition,
  without treating a numerical downgrade as an automatic update.

## Evidence and limits

Native bridge tests use memory-backed providers and do not demonstrate physical
blackout, hot-plug, sleep/wake recovery or real remote notification. Directory
tests use synthetic local files and controlled workers; Windows CM, Android,
slow mounts and cross-device transfers need target-device acceptance. Display
policy tests do not establish Retina pointer accuracy or a performance gain.

No Developer ID identity or publisher release key has been provisioned by this
change. Ad-hoc macOS signing cannot establish continuity of system permissions
across updates. Windows remains unsigned. Keep an independent remote-access
path while testing upgrades; do not disable system protections.

The dependency audit still has unresolved items; this release does not claim
that the full audit is cleared.
No ToDesk latency, throughput, CPU, battery or visual-quality comparison has been
measured for this release. Existing virtual display, terminal, camera, voice,
file and mobile capabilities retain their platform-specific acceptance limits.

## Automated signed-acceptance promotion

The following describes the separate automated path. It was not used for the
manual v1.0.7 release above and remains unchanged for future eligible candidates.

Pushes to `validation/**` run candidate checks and upload workflow artifacts.
They do not publish a stable release or replace nightly. Consult the linked
workflow run for the exact source commit, job result and available artifacts.

1. A `v*` tag matching `flutter/pubspec.yaml` builds packages and creates a
   **draft** with `build-provenance.json`, including the public-key digest used
   by that source build. Promotion rejects a missing or different pin; adding a
   key after building an unpinned candidate cannot make that candidate eligible.
   It does not publish a formal release.
   Nightly remains a separate pre-release channel.
2. Before building a publisher-verified candidate, provision only the public RSA
   key (2048–8192 bits, SubjectPublicKeyInfo PEM) in
   `res/nikodesk-update-public.pem`. Keep its private key offline, outside this
   repository and outside CI secrets. Changing the pin requires a trusted
   transition for already-installed clients. Older clients without this verifier
   need a trusted manual bootstrap; this patch cannot retroactively protect them.
3. Complete real acceptance for the exact seven package hashes. Create
   `release-acceptance.json` with the same `tag` and full `commit` as provenance,
   a `package_sha256` map for all seven packages, and a `gates` map. Each gate
   from `.github/scripts/release-manifest.py` needs `status: "passed"` and a
   concrete `evidence` reference. Untested, failed or waived gates block automated promotion.
   A signed assertion is not a substitute for performing those checks.
4. In the candidate directory, use `release-manifest.py create` to generate
   canonical ASCII `SHA256SUMS` after adding acceptance. Sign its exact bytes
   offline using RSA/SHA-256 and supply the base64 signature as `SHA256SUMS.sig`.
   The first line binds the tag: `# NikoDesk release v1.0.7`. Re-run
   `release-manifest.py verify` with the trusted public key and full source SHA.
5. Uploading or publishing needs the maintainer's explicit authorization. Once
   authorized, add the acceptance, manifest and signature to the draft and run
   `Promote accepted NikoDesk candidate`. It downloads and checks that draft,
   then promotes the same bytes without a rebuild. Configure required reviewers
   for the repository's `release` environment; declaring the environment in
   YAML does not itself create reviewer protection.

Automated signed-acceptance promotion requires source/security review, package settings on macOS and
Windows, Android upgrade, a private-network session, permission revocation,
physical privacy recovery, display/input acceptance, macOS signing continuity,
and Windows unattended installation acceptance. Authorization to push a candidate
and run CI does not establish those acceptance results or authorize remote access
or driver/service installation. The subsequent explicit instruction to publish
v1.0.7 authorized the manual publication above; it did not establish device
acceptance, platform signing or a signed-manifest verification result.
