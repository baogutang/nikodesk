# Niko Android 16 owned voice, stage 1

This is a real `AudioRecord`/`AudioTrack` provider using JNI 0.21.1. It remains
unwired and off: this batch does not modify an Activity, manifest, permissions,
Gradle, network negotiation, Flutter UI or the shared voice module export.

## Integration contract

- After loading the app's existing native library, the trusted local Activity
  can explicitly call `NikoVoiceBridge.initContext(Context)`. It caches that
  actual loaded class and VM. It checks API 36+, the app package and ordinary,
  non-isolated application UID. It requests no permission and opens no device.
- The Activity must forward real resume/pause/window-focus changes using
  `setLocalActivityVisible`. Metadata enumeration uses `snapshotJson` /
  `DeviceSnapshot::enumerate` only; it never constructs a recorder or player,
  probes supported configurations, takes focus or changes routes.
- Snapshot device objects, direction, ID and descriptors remain private in
  Kotlin. Rust exposes opaque tokens and their roster revision, not native IDs.
  The one 48 kHz mono float entry is a client format requiring start readback,
  not a claim that every device supports it. Audio device IDs are OS port IDs,
  not a permanent hardware serial number.
- After an explicit local microphone permission/consent action, and after its
  independent authenticated capability checks, the local Activity calls
  `approveLocal` with snapshot/device/format tokens, call nonce, call epoch and
  a distinct, nonzero, process-monotonic native lease. Consent expires after
  30 seconds until startup confirms real routes. `prepare` consumes it once.
  Rust `DeviceSnapshot::select` returns `AndroidBackend`; use `start(self)` or
  pass its exact binding to `VoiceOwner::start`. `open` checks that binding and
  returns an empty driver: allocation occurs only in the retained `poll` owner.
- This stage sets only each stream's exact `preferredDevice` and verifies
  `getRoutedDevices()` after startup and on every PCM poll. No default device,
  name match or substitute route is accepted. It never calls `setMode`,
  `setCommunicationDevice`, `clearCommunicationDevice`, speakerphone or SCO
  controls. Unsupported routes, including combinations requiring global
  Bluetooth/SCO mode selection, fail closed. The SDK cannot prove a route
  before startup; no captured PCM is published before exact readback and
  non-silenced active recording configuration agree.
- `AudioRecord`/`AudioTrack` construction handles are saved before readback,
  configuration, preferred-device and callback registration checks. Focus and
  callback handles are also retained before a partial failure. Reads and writes
  are non-blocking. Only the actual returned sample count is used; one bounded
  480-sample pending output retains its exact unwritten tail. Buffers and the
  queues are cleared on cancellation/stop.
- Route, focus, device removal, local revoke and visibility loss close the Java
  gate, then close the exact Rust owner's atomic PCM publication gate through
  JNI. Nonce, epoch and native lease must all match. Callbacks never reroute,
  resume or clean up a replacement call.
- Stop unregisters callbacks, stops/releases the recorder, pauses/flushes/
  releases the track, abandons its focus request, drains and joins its callback
  thread, and checks that every owned field is empty before the native ACK.
  An exception, unfinished release or join timeout retains that owner and
  ordered cleanup cursor for retry. The shared `VoiceOwner::stop` additionally
  requires its Rust PCM/codec worker to join. No `Drop` is treated as an ACK.
- `retry_retained_native_stop(binding, native_lease)` is only a recovery-worker
  entry for the same retained Kotlin owner. Its success is a native-framework
  ACK, **not** the Rust worker-join ACK or a complete call `Stopped` state.
  Unknown history or a different currently owned call returns an error rather
  than cancelling that call.
- The new foreground-service class is deliberately absent from the manifest
  and has no start hook. A future explicit local UI flow must allowlist it and
  the microphone permissions. It can mark background authorization only after
  real `startForeground`, while matching the visible approved call. Its stop
  action and destruction are keyed to that call. Stage 1 performs no automatic
  FGS startup, permission request or microphone capture from the background.

## Evidence boundaries

Private SDK compilation, actual Android JNI/Opus linking, synthetic PCM,
real-codec tests and pure lifecycle tests are separate from device execution.
No Android device, TCC/runtime permission, microphone, playback or app has been
started for this batch. Framework `release` return, uninitialized state and
thread join are the available API completion checks; this is not proof of a
HAL hard deadline, Bluetooth interoperability, physical silence, all Android
models, background survival or APK integration. MainActivity's legacy audio
paths must stay blocked for Niko before this provider is wired.

AOSP Android 16 confirms that `setMode` ownership is per calling PID, while
communication-route client removal uses the AudioManager callback Binder and
is asynchronous. A fresh Context's AudioManager therefore does not isolate
mode ownership or provide a strong communication-clear ACK. This provider
avoids those global setters and never restores a saved global mode/route.


## Stage 2 explicit local authorization and integration

Niko MainActivity initializes the actual cached-class JNI bridge after the
application has loaded the native library. Flavor policy lifecycle hooks update
its real Activity visibility; stock policy methods are no-ops and the existing
stock audio path remains unchanged. Niko legacy raw-frame audio and generic
microphone/notification permission requests remain blocked.

`PermissionRequest::begin/poll/cancel` owns an asynchronous actual visible
Activity microphone request. Permission code 0 means **not granted and no
previous request recorded by this app**, not an Android-wide NotDetermined fact.
Codes 1/-1/-3/-4 mean granted/denied/policy-restricted/unavailable. Cancellation
cannot undo an OS grant; late callbacks cannot return a call approval.

`LocalApprovalRequest::begin` binds the immutable native roster/selection,
Binding, unique native lease and explicit `allow_background` (default false).
It returns one proof token that keeps its Java job owner until consumed or
cancelled. Only background-approved jobs request notifications; denial or
blocked notifications return `notification_permission_required` and no native
media is started. A resumed visible Activity, unchanged selection/lease and
unexpired job are checked again after any system dialog.

The Niko manifest allowlists only the non-exported microphone VoiceService,
RECORD_AUDIO, POST_NOTIFICATIONS and the two microphone FGS permissions. The
package verifier permits this exact combination and continues to forbid old
projection/accessibility/boot/overlay/receiving components. Its optional
`--require-owned-voice` flag requires the new metadata while retaining valid
historical APK structure checks.

After explicit background consent, the stream owner requests the FGS while
visible. Background permission is published only after real `startForeground`
and matching service/nonce/epoch/lease validation. The notification has a Stop
action with a distinct per-call PendingIntent data URI. Stop first closes PCM
publication; stream/callback release and join must finish, followed by real
service onDestroy, before that owner is released. Submitted-but-uncertain
service failures retain the owner rather than falsely reporting Stopped.
Notification/microphone revocation, device/route/focus changes and unexpected
service destruction cancel the exact call; they never resume another call.

The independent runtime adapter uses the current production Provider/Roster/
PermissionJob/SelectionJob traits. Its format schema is
`android_client_pcm_f32_48k_mono_v1` (48kHz, mono, float32 **client** format;
actual route/non-silenced recording readback is required before PCM). Android
SDK36/ordinary appUID/native getuid+geteuid/bridge initialization are mandatory.
No default/name replacement or global AudioService mode/route setter is used.

Stage 2 evidence is SDK/JNI compilation, actual source synthetic PCM/Opus,
pure state tests and source manifest merging. No Android permission dialog,
FGS, microphone, playback, installed APK or actual peer call has been executed.
OS/HAL deadlines, physical release/silence, all-model routes, background
survival and a complete APK remain independent acceptance work.
