# NikoDesk 1.0.4

Product version `1.0.4`, build `13`; native protocol `1.5.0`. This patch preserves the published 1.0.1, 1.0.2 and 1.0.3 tags and packages.

## Fixed

Saving one setting no longer restarts the registration with the private server. Every single-option save used to restart it, whether or not the option had anything to do with it; in local logs each restart took 0.1–0.9 s to register again. The registration now restarts only when the pause state, the server tuple, the transport options or a failed save change it. In local end-to-end runs, the two policy options that the session setup saves produced two restart calls per run before the change and none after it.

## Added

**Remote resolution** in the control center. It is implemented for desktop and Android controllers; so far it has been verified only between two identities on one Mac.

- **Match this screen** asks the controlled side for the smallest display mode, in its original aspect ratio, that still sends as many pixels as the controller's screen can show. A Retina Mac reports modes in points: for a controller screen 3840 pixels wide, a 5K Mac (`2560×1440`, captured as `5120×2880`) switches to `1920×1080` and is captured as `3840×2160`, 56% of the pixels.
- **Restore original** switches back. The controlled side also restores its mode when the last remote-control session disconnects, as long as NikoDesk there is still running; if it is killed first, the smaller mode stays until someone changes it.
- **Match automatically for this device** is stored per device and off by default. It matches shortly after each connection and skips the match when the remote display is already in a non-original mode.

This uses the display-mode change the controlled side already supports. The controlled-side code is unchanged, so it should work against a 1.0.3 controlled device; that pairing has not been tested. It changes the real display mode: someone sitting at the controlled computer sees the change, and a smaller Retina mode makes its interface larger. It needs input permission and one selected, non-virtual display. On a controlled computer without Retina scaling, a mode picked by hand is remembered for that device and applied again on later connections until the original is restored.

## Limits

- A Mac lists Retina and plain modes together and applies the Retina variant of a size when one exists, so the captured size can differ from what the picker expects. The control center shows the captured size after a manual match. Automatic matching checks the result and switches back if the picture did not get smaller or no longer fills the controller's screen.
- On a controlled Windows computer the mode is written as the system display setting. If that computer restarts, or NikoDesk there stops, before the session ends, the smaller mode stays and is afterwards reported as its original.
- The mode belongs to the controlled display: it changes for every controller connected at that time.
- After a manual match or restore, automatic matching stays out of the way until that session window is closed. A mode picked in the display menu instead is not tracked this way.
- If the controller's screen size cannot be read, the match is unavailable and the control center says so; pick a mode in the display menu under Resolution.

## Verification

A session between two local identities through the private relay used the production picker with a controller width of 3840 pixels given to the test. It picked `1920×1080`, the controlled side switched from `5120×2880` to `3840×2160` captured pixels, and after disconnecting and reconnecting it reported `5120×2880` again. The control-center buttons, the automatic option, and the reading of the controller's real screen size were not exercised in a session. The controlled Mac's screen was locked during the run, so no frame-rate comparison could be made. Windows and Android controllers, cross-device latency and frame rate remain untested.

The v1.0.4 tag builds all seven macOS ARM64, Windows x64 and Android ARM64 packages plus SHA256SUMS after the platform and packaging gates pass. Android keeps its release identity and certificate with versionCode `13`.

## Updating

macOS packages are still ad-hoc signed. After the app is replaced, the Screen Recording and Accessibility grants stop applying and must be given again at the Mac. Do not update a controlled Mac that you cannot reach physically or through another remote-control tool.
