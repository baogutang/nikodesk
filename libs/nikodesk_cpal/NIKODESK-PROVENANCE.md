# Fixed NikoDesk CPAL source

Full 83 tracked files from rustdesk-org/cpal commit `96d4da121b7d949677ac5b6887413a9185fd7f39`, version 0.15.3, Apache-2.0 (`LICENSE`). Source caches, dependency versions, and the stock Git dependency remain unchanged. The optional dependency is enabled only by Niko on macOS or Windows.

The macOS patch adds `CoreAudioDevice::nikodesk_audio_device_id()`, a read-only accessor used by the Niko-only voice provider to query public CoreAudio DeviceUID/IsAlive properties. It does not open, start, stop, or change a device; no default/name fallback is introduced.

The Windows patch marks only input streams built on a render endpoint as loopback, retaining shared `EVENTCALLBACK | LOOPBACK` initialization and `SetEventHandle`. Windows before 10 1703 does not signal those capture events. Active loopback waits at most 10 ms for commands/audio, then checks real capture packets; modern audio events still wake it earlier. Paused loopback blocks indefinitely on commands alone. Ordinary microphone/output stream initialization and sample processing remain unchanged. Wait errors, abandoned/APC/out-of-range results, and unexpected timeouts never become audio events.

Loopback packet batches are bounded to 32 with a command/playing gate before each packet. Successful nonempty `GetBuffer` acquires one packet lease; normal return, validation/timestamp failure, and callback unwinding each perform exactly one `ReleaseBuffer`, with unconsumed packets released as 0 frames. Release errors are reported, not retried. Silent packets use aligned owned PCM with signed/float zero and unsigned midpoint values. The loopback event owner closes on initialization failure and, after successful construction, outlives the client/service references. CPAL's public play/pause return is still a queued command, not an actual device-start/stop ACK.

`NIKODESK-PROVENANCE.json` preserves all upstream file hashes and records the changed/new Niko files. Independent tests and Windows SDK metadata compilation are development evidence; no audio device, physical recording/playback, Windows native link, OS compatibility matrix, or real remote-session validation is claimed.
