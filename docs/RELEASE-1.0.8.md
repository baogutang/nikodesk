# NikoDesk 1.0.8+19 — Android startup repair

**[Download v1.0.8](https://github.com/baogutang/nikodesk/releases/tag/v1.0.8)**

This release repairs the Android client, which quit immediately at launch on a
real device for every prior version. The maintainer explicitly authorized the
fix, adversarial review, push and formal publication of 1.0.8.

## Changes

### Android startup crash (the 1.0.7 symptom)

- On first launch on a real Android device, the native NikoDesk initialization
  rejected the app's platform-created configuration directory and stopped the
  process with `exit(1)`. The system recorded every launch as
  `EXIT_SELF status=1`; the visible `FORTIFY: pthread_mutex_lock called on a
  destroyed mutex` aborts in `hwuiTask`/render threads were teardown fallout
  of that exit, not the cause.
- Root cause: Android hands the app its data directory with the platform's
  `0771` convention (group/other execute bits). The strict desktop privacy
  invariant requires group/other bits to be empty, so the identity-directory
  check failed deterministically on every Android device. macOS passes because
  `~/Library/Preferences` is `0700`. No Android build had ever been launched on
  a real device before, which is why this surfaced only now.
- Fix: on Android the initialization tightens the configuration directory to
  `0700` before checking, instead of weakening the check. The privacy
  invariant stays identical on every platform; the app sandbox is still
  enforced by the `0700` package directory above it. Symbolic links are
  rejected and never followed; the tightened state is re-verified. The change
  is compiled and reachable on Android only.
- Regression coverage: the raw Android-style `0771` directory must fail the
  strict check (the pre-1.0.8 behavior, documented), then pass after
  tightening; already-private directories are untouched; symbolic-link parents
  are rejected without touching the target.

### Startup failures are now diagnosable on Android

- An early initialization failure previously wrote the reason to `stderr`,
  which is `/dev/null` for an Android app, then exited — leaving no trace. It
  now also logs the reason to logcat (tag `NikoDesk`) and writes a
  `nikodesk-startup-failure.txt` marker (mode `0600`, no secrets) inside the
  configuration directory before stopping. The strict fail-stop behavior is
  unchanged; only its visibility is fixed.

### Android package size regression

- v1.0.7 shipped an unstripped `libc++_shared.so` (~9.2 MB instead of
  ~1.2 MB) because NDK r28's sysroot copy is unstripped and AGP did not strip
  `jniLibs` in that build. The build now strips the staged library explicitly
  on CI and locally, the staging step fails loudly if it remains large, and
  the final-APK verifier rejects any `libc++_shared.so` at or above 2 MB so
  the regression cannot silently return. Expect the Android APK to shrink
  back to roughly its 1.0.6 size.

## Evidence and limits

- Local verification before release: full `nikodesk` Rust regression filters
  (551 passed / 2 ignored) including the new directory tests; Android-target
  compile check via cargo-ndk; the Android packaging verifier suite
  (43 tests) including the new unstripped-library rejection; actionlint.
- Real-device acceptance gate: before publication, a locally built,
  test-signed package of this exact source must launch on the maintainer's
  device (vivo, Android 16) and stay running past the first-run screen. The
  published release package is built by CI from the tagged source. Touch
  control, remote sessions and upgrades from earlier installs remain
  separate acceptance items.
- macOS/Windows behavior is untouched by this change; their configuration
  directories were already private and follow the same invariant as before.
- The 1.0.7 OpenSSL pin, icons, update handoff and history/credential work
  are unchanged. macOS remains ad-hoc signed, Windows unsigned, Android on
  the existing release certificate. The dependency audit status is unchanged.
