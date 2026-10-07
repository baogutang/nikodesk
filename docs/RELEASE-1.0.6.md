# NikoDesk 1.0.6

Product version `1.0.6`, build `15`; native protocol `1.5.0`. This release preserves the published 1.0.1 to 1.0.5 tags and packages.

Unless a line says otherwise, the checks below ran between two identities on one Mac, through the private relay, on development builds of this source. Two sessions between devices on 1.0.5 are reported where they bear on a change.

## Privacy screen: a visible switch and a visible state

The privacy screen already existed: on a controlled Mac it blacks out the displays and pauses the local keyboard and mouse while the controller keeps its picture. The only way to reach it was an entry inside the display menu, and nothing showed whether it was on.

- **Toolbar button.** One click switches it; the button is highlighted while it is on, and its tooltip says which state it is in. When it cannot be switched, the click opens the explanation instead.
- **Control center → Privacy screen.** A switch with the state in words and what that state means at the controlled computer.
- **A label on the remote picture** for as long as it is on, visible with the toolbar folded away, on desktop and phone.
- **When it is unavailable, the reason is given**: not allowed by the controlled computer, view-only session, or not supported there.

To use it, the controlled computer has to allow it once: **Settings → Session security → Allow privacy screen for new connections**. That is off by default and unchanged by this release; a connection that is already open can be allowed in the controlled computer's connection window instead. Both can be done through the remote session itself.

At the controlled computer, Control + Option + Shift + Esc on a Mac, or Esc on Windows, restores the screen; so does ending the session. If the privacy screen is on when a session ends, the next session to that device turns it on again.

## Frame rate: limits up to 120

- The custom frame-rate limit went to 60 in NikoDesk's own panel; the session itself accepts 120. The slider now goes to 120.
- **Responsive control** asked for the balanced quality, which a session holds to 30 frames a second. It now asks for a 50% bitrate ratio and this controller's own refresh rate, between 60 and 120. A device that saved the old meaning shows as custom until the mode is chosen again.
- **A controlled Mac reaches the limit it is given.** Its video loop slept out the rest of every frame time, so each oversleep lengthened the period: a 60 limit sent 54. It now keeps to absolute times.

A controlled computer cannot send more new pictures than its own display refreshes. The 5K Mac used here has a 75 Hz display, so 75 is its ceiling whatever the limit.

## Icons

The Windows program, its portable package and its tray icon, and the Android launcher icon, were still the upstream ones: the names had been changed and the image files had not. They are NikoDesk's now. A packaging test fails if the upstream image comes back.

## Log

The controlled side writes one line every 30 seconds per display while pictures flow: size, encoder, new pictures a second against the limit in force, quality, target bitrate and the newest reported delay. Earlier logs had none of these, so a report of choppy video could only be read from the settings.

## Verification

| Check | Result |
|---|---|
| Privacy screen allowed, real session | Request answered "entered"; while on, the brightest value in the display's colour table was 0 (blacked out) and frames kept arriving at the controller; off again answered "exited" and the value was back at 1. |
| Privacy screen on the default policy, real session | The controller is told it is not allowed; a request sent anyway is answered "denied" and the state stays off. |
| Privacy screen interface | Unit and widget tests for every state, for the implementation that is asked for, for the switch, the button and the label. The panel, button and label were not opened in a session by hand. |
| Frame limits on an unlocked screen, 90% quality, `3200×1800`, 15 s of continuous motion, relay reached through a tunnel (see 1.0.5 notes) | Limit 60: 59.6–60.2 new pictures a second sent, 60.0 decoded, longest gap 38 ms. Limit 75: 73.0–73.8 sent, 74.9 decoded, 35 ms. Limit 120: 75.0–75.4 sent (the display's rate), 107.3 decoded including repeats of unchanged pictures, 28 ms. No gap over 100 ms in any; delay 21–30 ms at the median. One run each. |
| Loop pacing with real sleeps | Limits 30/60/75/120 gave 24.0/46.7/58.3/103.6 iterations a second before and 29.9/59.9/74.9/120.0 after. |
| Icons | The Windows icon file has nine sizes from 16 to 256 and the tray icon five; a test tells NikoDesk's image from the upstream one. Not looked at on a Windows or Android device. |
| Status line | Seen in the controlled side's log of a real session. |
| Sessions between devices on 1.0.5 | A Mac with a 3024-pixel-wide screen got `3200×1800`, and a Windows PC with a 3840-pixel-wide screen got `3840×2160`, both on the hardware H.265 encoder from a 5K Mac, and both logged in on the password alone. |

Not verified: the privacy screen, the new frame limits and the icons on Windows and Android devices; a Windows controlled computer's privacy screen; frame rate and delay measured in a session between devices; the pacing change on anything but a Mac (other platforms keep the previous pacing).

The v1.0.6 tag builds all seven macOS ARM64, Windows x64 and Android ARM64 packages plus SHA256SUMS after the platform and packaging gates pass. Android keeps its release identity and certificate with versionCode `15`.

## Updating

macOS packages are still ad-hoc signed. After the app is replaced, the Screen Recording and Accessibility grants stop applying and must be given again at the Mac. Do not update a controlled Mac that you cannot reach physically or through another remote-control tool.

The controlled Mac needs 1.0.6 to reach a limit of 60 or more; the controller needs it for the new limits in the picture-mode panel and for the privacy screen button, switch and label.
