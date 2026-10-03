# NikoDesk 1.0.2

Product version `1.0.2`, build `11`. The native protocol remains `1.5.0`. This patch follows the published 1.0.1; its tag and packages remain unchanged.

## Light theme and website

The light workspace now uses warm paper surfaces, terracotta actions and brown-gray text, matching the website. Opaque light surfaces replace layered blur and gradients. Dark mode retains its existing direction. Existing contrast and responsive widget regressions cover both product modes; screenshot examples render production Flutter widgets with invented device/server data, without opening a native client or establishing a connection.

The English and Chinese website now includes a local interactive interface example: device search and favorites, light/dark themes, session controls, Mac Space illustrations and original/automatic keyboard semantics. It neither connects to servers nor collects credentials or sends keys. README previews and social sharing use the new production-widget example.

## Windows/Linux controlling Mac

In Map and Legacy keyboard modes, selected common Ctrl editing chords (C/V/X/A/Z/S/F/P/R) become Command chords on a Mac desktop peer. Both the native physical-key capture path and Flutter input path use the common native dispatcher. A visible session option restores original keys and is saved for that device; use it for terminal Ctrl+C interrupts. Combinations with Shift, Alt/AltGr or Meta are preserved, as are Control+arrow Space commands. Translate mode retains its original semantics.

The modifier state machine tracks left/right Control, key repeat, overlapping keys and balanced release. Loss of focus, keyboard-mode/input-source changes, permission revocation, reconnect and close release or clear the owned state. Synthetic quick actions carry explicit remote semantics and bypass the old global modifier swap so Mac Space controls remain Control.

## Apps, full-screen work and daily actions

The desktop and mobile control center exposes cut, find, print and reload alongside copy, paste, select all, undo and save. App and desktop actions use the remote platform's actual shortcuts. For Mac: previous/next Space, Mission Control, app windows and forward/reverse Command+Tab. For Windows: Task View, previous/next virtual desktop and forward/reverse Alt+Tab. Unsupported actions are omitted for other platforms. Local view tools are separated from remote input and remain available during view-only sessions.

Full-screen Mac applications occupy Spaces. Remote system settings or customized shortcuts determine their behavior; Command+Tab does not guarantee switching to any particular full-screen window. No private Space enumeration or remote system-preference changes are introduced. Native tests exercise the event stream and Flutter tests the real dispatch entry points, permissions and UI; physical Windows-to-Mac session acceptance remains separate.

## Delivery

Main maintains the nightly preview. The v1.0.2 tag publishes all seven macOS ARM64, Windows x64 and Android ARM64 packages plus SHA256SUMS after every platform build and packaging gate passes. Mac and Windows CI also run the native shortcut regressions. Android keeps `io.nikodesk.android` and the existing release certificate, advancing versionCode from 10 to 11.

Existing video-queue recovery and real VP8/VP9/AV1 pixel regressions from 1.0.1 remain. No measured real-network or ToDesk performance advantage is claimed. Current RustDesk services, credentials, configuration and the user's active remote session remain untouched. This patch is built and tested without launching an experimental native client, installing drivers/services or changing security settings. Target-device startup, remote input behavior and installation acceptance require their own verification.

Local checks: full Flutter Niko 923 passed / 2 skipped; stock 902 passed / 6 skipped. Native Niko-name-filter 521 passed, one optional probe ignored, 329 upstream tests outside the filter; stock lib/bins compilation passed. Packaging Python 142 cases / 1 existing skip plus 9 portable cases; Dart analysis 0 errors, 0 warnings, 291 informational notices. Initial toolbar contrast and unused test import failures were corrected and final checks passed. No physical-key injection or native client launch occurred.
