# Startup motion studies

Design-only review artifact: serve this directory with any static server and open `index.html`.
Three directions share simulated ready/slow/failure scenarios. No client process, real connection,
credentials, permission changes or native application code is involved.

A ready signal interrupts the opening motion. Failure retains an explanatory state.
Reduced motion is supported. The simulation's timings are not NikoDesk measurements.
Direction A was selected on 2026-10-08 and is implemented separately with native Flutter animations. This browser demo remains an independent simulation, not the native client.

Brand asset: NikoDesk canonical 512px icon. GSAP 3.13.0 is vendored only for this demo,
with its distribution copyright/license header intact; see `vendor/SOURCE.txt` and
https://gsap.com/standard-license/. It is not bundled into the Flutter app.
