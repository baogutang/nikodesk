# NikoDesk 1.0.5

Product version `1.0.5`, build `14`; native protocol `1.5.0`. This release preserves the published 1.0.1 to 1.0.4 tags and packages.

Everything below was verified between two identities on one Mac, through the private relay, on development builds of this source. Nothing in this release has been run between two devices.

## Reported problem

With 1.0.3, whole-screen changes on a controlled 5K Mac (unlocking, entering full screen) were very choppy.

Two things were found. Neither is confirmed as the cause of that particular session.

**The hardware encoder could be lost for the rest of a run.** After a capture restart, the Mac's hardware encoder returns nothing for its first frames. Three empty results in a row, which take 50 ms at 60 frames a second, made the app give up on the hardware encoder until it was restarted and encode in software. In a 1.0.3 session log, four capture restarts within 90 seconds ended with H.265 marked unusable and a 5K display encoded as software AV1 for at least the next half hour. Those four restarts were caused by test runs on the same Mac, not by the user; any restart can do the same, and a refresh request from the controller is one.

**Every frame carried all `5120×2880` pixels.** The hardware encoder is given an average bitrate and no limit per frame. In one local run where a second 5K stream shared the uplink, repeated whole-window changes left the picture 7.2 seconds behind at about 5 frames a second. In that condition a `3840×2160` picture was still 4.1 seconds behind at the median; a `2560×1440` picture was 16 ms behind at the median and 1.5 seconds at most. In a later run, when the link was less busy, a native-size picture stayed within 20 ms.

## Changed

**The hardware encoder gets time after a restart.** On macOS a hardware encoder is given up on after 30 empty results in a row, not 3. A stress run with 14 size changes at a 60 frame limit started 24 encoders and saw 3 empty results in a row, the point where earlier versions gave up, and stayed on H.265. An earlier run of the same test only reached 2 in a row.

**Picture size sent.** The controller tells the controlled side how wide a picture it can show, and a controlled Retina Mac scales its capture towards that on the GPU. The display mode, the window layout and what someone sitting at the Mac sees stay as they are.

- **Fit this screen** (default): a controller reporting a 3840-pixel-wide screen gets `3840×2160` from a 5K Mac, 56% of the pixels.
- **Smaller**: the Mac's standard size, one pixel per point. On a 5K Mac that is `2560×1440`, 25% of the pixels.
- **Remote native size**: everything the display has.

The choice is in **Control center → Picture size sent** and is saved per device. A change during a session restarts the capture, which took 0.2 to 0.3 seconds locally.

How the size is chosen: the scale moves in quarter steps of the Mac's point size, from one pixel per point up to the display's own scale, and takes the smallest step that still covers the request. A step is used only when both edges come out as whole even pixels, so the point size the controller sees is exact; a display with no such step is captured at native size. A 14-inch MacBook Pro (`1512×982` points) has none below native for a 1920-wide controller.

Limits:

- Both ends need 1.0.5, and the controlled side must be a Mac with a Retina display. A Windows controlled computer ignores the request.
- The controller reports the largest of its screens. A Mac controller reports its pixel size, so a 4K panel set to "looks like 2560×1440" reports 5120 and gets the native size.
- With several controllers the widest request wins. A controller on an older version makes no request and receives whatever the others asked for.
- The pointer image is not scaled with the picture; at the standard size it is twice as large relative to the picture.
- When two or more displays of the Mac are captured at once, it already captures at point size as before.
- The encoder still has no per-frame limit. Fewer pixels make the large frames smaller; they do not remove them.
- With this scaling in effect, **Remote resolution → Match this screen** has nothing left to do and is disabled.

**A valid password is enough.** The controlled side's default was click-only, so a controller that entered the right password still waited for someone there. The default is now password or click.

- Valid passwords are the one-time password the app shows, and a permanent password once it has been set and allowed.
- Such a session gets screen, keyboard and mouse, clipboard and file transfer by default. Terminal, camera, tunnels and voice keep their own approvals.
- A wrong password, or none, still raises the confirmation prompt on the controlled computer.
- Every device updated from 1.0.4 or earlier moves to this rule, including one where click-only had been selected: that was the default, so it was never stored. To require a click for every session, select click-only again under **Advanced settings → Security** after updating.

## Fixed

- An update download that hit its time limit, or was cancelled, while a chunk was being written reported an unrelated file error instead of the timeout or the cancellation.

## Release process

- The macOS job starts the app it built, in a fresh home directory containing only the standard Library folders, and fails unless its core starts, it stays up and it logs no panic. An earlier run of this check failed when those folders were missing.

## Verification

| Check | Result |
|---|---|
| Capture scaling | Asked for 3840: `3840×2160`. Asked for 2560 or for the smallest size: `2560×1440`. Asked for native: `5120×2880`. The display stayed 2560 points wide throughout. A new login with a saved request started at `3840×2160`; after that controller left, the next one saw `5120×2880`. |
| Pointer mapping | After each size change a pointer position was sent to a different spot of the picture and read back from the system; all five landed where expected (for example `2880,540` of a `3840×2160` picture at `1920,360` points). |
| Scale rule | Unit test over ten real Mac point sizes and nine requests: every result is a whole even pixel size whose point size is exact, and never smaller than requested unless the display has no more. |
| Transitions, 90% quality, 60 frame limit, a window covering 64% of the screen changing its whole content every 2 s for 20 s, one run each | Native: 32.9 decoded frames a second, 14 gaps over 250 ms, picture 17 ms behind at the median and 954 ms at most. 3840 wide: 33.8, 20 gaps, 14 ms and 17 ms. 2560 wide: 33.5, 20 gaps, 15 ms and 17 ms. Frame rate and gaps did not improve; only the largest delay differed, and in a second native run it was 20 ms. Another remote session was capturing and encoding the same screen on the same Mac during these runs. |
| Hardware encoder | 14 size changes at a 60 frame limit: 24 encoders started, up to 3 empty results in a row, no fallback, H.265 before and after. |
| Password rule | Controlled side on its defaults, nobody clicking: the one-time password logged in and received video; the permanent password, never allowed, was refused; a wrong password was refused. With click-only chosen explicitly, the right password did not log in. Before the change, the default did not log in with the right password within 30 s. |
| Update download | A test that cancels during a file write fails without the fix and passes with it. |
| Launch check | The CI-built app started and stayed up. |

Not verified: Windows and Android controllers; a Windows controlled computer; frame rate and latency between devices; the control-center selector and the automatic request at session start, including how the controller reads its own screen size; two controllers at once; and behaviour after updating an installed 1.0.3 or 1.0.4.

The v1.0.5 tag builds all seven macOS ARM64, Windows x64 and Android ARM64 packages plus SHA256SUMS after the platform and packaging gates pass. Android keeps its release identity and certificate with versionCode `14`.

## Updating

macOS packages are still ad-hoc signed. After the app is replaced, the Screen Recording and Accessibility grants stop applying and must be given again at the Mac. Do not update a controlled Mac that you cannot reach physically or through another remote-control tool.

After the update a valid password connects without a click, whatever acceptance rule the device used before.
