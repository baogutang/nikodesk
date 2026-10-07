# Building and packaging NikoDesk

The versioned product is `1.0.6+15`; the native protocol remains `1.5.0`. The three-platform pipeline has passed for the previous build. Windows user-mode support and the Android controller still need target-device acceptance; the broken public `v1.0.0` Windows and Android binaries were removed. A successful compilation does not establish that a client launches, connects, captures the screen, or accepts input.

## Clean-clone macOS build

Use an Apple Silicon Mac with Xcode and its command-line tools already configured. The build requires Rust 1.88.0, Flutter 3.24.5, Python 3.9 or newer, CMake, Ninja, pkg-config, LLVM/libclang and CocoaPods. Keep private dependencies in `.tools/`; do not change the installed RustDesk app or its services. Installing system tools or obtaining signing credentials is a separate prerequisite, not something these commands perform.

The public repository is a flat source export: the pinned hbb_common sources are included as ordinary files. Clone it without a submodule initialization step; the private upstream-preserving development tree still records its submodule pin. Use a path without spaces: upstream FFmpeg's configure script does not support spaces in its build path.

```sh
git clone https://github.com/baogutang/nikodesk.git
cd nikodesk
mkdir -p .tools
```

Ensure `flutter` resolves to your isolated Flutter 3.24.5 SDK and `cargo +1.88.0` is available. Check these before proceeding:

```sh
flutter --version
cargo +1.88.0 --version
xcodebuild -version
```

Prepare the pinned vcpkg checkout and the NikoDesk native overlay. Run this setup once in the clean clone; retain the checkout for subsequent builds.

```sh
git clone https://github.com/microsoft/vcpkg.git .tools/vcpkg
git -C .tools/vcpkg checkout 9e593bb18ea69cc5095e012465dcd675a822ed0d
export VCPKG_ROOT="$PWD/.tools/vcpkg"
export VCPKG_DEFAULT_TRIPLET=arm64-osx
export VCPKG_DEFAULT_HOST_TRIPLET=arm64-osx
export VCPKG_DISABLE_METRICS=1
"$VCPKG_ROOT/bootstrap-vcpkg.sh" -disableMetrics
"$VCPKG_ROOT/vcpkg" install --triplet arm64-osx \
  --overlay-ports="$PWD/res/vcpkg-nikodesk" \
  --x-install-root="$VCPKG_ROOT/installed"
```

Apply the same Flutter SDK patches as the CI workflow, once in the isolated SDK. `git apply --check` must pass before applying; on a reused SDK, use `git apply --reverse --check` to confirm the patch is already present. Do not ignore a mismatch.

```sh
flutter_sdk="$(cd "$(dirname "$(command -v flutter)")/.." && pwd)"
git -C "$flutter_sdk" apply --check "$PWD/.github/patches/flutter_3.24.4_dropdown_menu_enableFilter.diff"
git -C "$flutter_sdk" apply "$PWD/.github/patches/flutter_3.24.4_dropdown_menu_enableFilter.diff"
python3 - "$flutter_sdk/packages/flutter/lib/src/scheduler/binding.dart" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()
s = s.replace('_setFramesEnabledState(false);', '//_setFramesEnabledState(false);')
p.write_text(s)
PY
```

Build the real Rust core and Flutter runner. Restrict Xcode to ARM64 so its architecture matches the Rust library. The checked-in bridge files are required; this does not create a substitute for the native core.

```sh
export MACOSX_DEPLOYMENT_TARGET=12.3
export FLUTTER_XCODE_ARCHS=arm64
export FLUTTER_XCODE_ONLY_ACTIVE_ARCH=YES
cargo +1.88.0 build --locked --lib --release \
  --features flutter,hwcodec,unix-file-copy-paste,screencapturekit,nikodesk
cp target/release/liblibrustdesk.dylib target/release/librustdesk.dylib
(cd flutter && flutter pub get && flutter build macos --release \
  --dart-define=NIKODESK=true)
python3 .github/scripts/prepare-macos-camera.py \
  flutter/build/macos/Build/Products/Release/NikoDesk.app
python3 .github/scripts/build-macos-privacy-watchdog.py \
  flutter/build/macos/Build/Products/Release/NikoDesk.app --architecture arm64
```

The runner links `Contents/Frameworks/liblibrustdesk.dylib`; the differently named copy in `target/release/` is an upstream build convention. The NikoDesk user-mode bundle does not contain or install the privileged `service` helper.

## Verify and package an existing signed app

Packaging never launches the client, modifies the installed app, re-signs a bundle, or installs a service. You can check an existing signed build independently:

```sh
python3 .github/scripts/package-macos.py \
  flutter/build/macos/Build/Products/Release/NikoDesk.app --verify-only
```

For a freshly built app, compile the ordinary-user recovery helper with the command above, copy `LICENCE` into `Contents/Resources/NikoDesk-LICENCE.txt` and add the corresponding source revision there before signing. `.github/scripts/sign-macos-app.sh` signs the helper as `io.nikodesk.privacy-watchdog` before sealing the outer app; no service, launch item or privileged installation is involved. Signing must be performed separately. CI retains its existing ad-hoc, app-scoped local-development signature; that is neither an Apple Developer ID signature nor notarization. Do not use a system security bypass as an installation step.

Given an already signed app, use a new output directory:

```sh
python3 .github/scripts/package-macos.py \
  flutter/build/macos/Build/Products/Release/NikoDesk.app dist --require-privacy-watchdog --require-camera
(cd dist && shasum -a 256 NikoDesk-macos-arm64* > SHA256SUMS)
```

The outputs are:

| File | Purpose |
| --- | --- |
| `NikoDesk-macos-arm64.dmg` | Manual installation: contains `NikoDesk.app` and an Applications shortcut. |
| `NikoDesk-macos-arm64.zip` | Full `.app` bundle used by the existing updater. Preserve this asset name. |
| `NikoDesk-macos-arm64-manifest.json` | Package verification results; launch and remote-session checks remain explicitly unverified. |
| `SHA256SUMS` | Digests of the distributed files. |

The verifier checks the bundle identifier and executable, ARM64 Mach-O runner and Rust library, bundled native dependencies, absence of a privileged service and signature integrity. It extracts the ZIP and mounts the DMG read-only to repeat the checks, then detaches the image. These checks establish package contents and signature integrity; they do not establish Developer ID trust, notarization or runtime behavior.

New camera-backend builds read the product version/build from `flutter/pubspec.yaml`. Run `prepare-macos-camera.py` only on the built NikoDesk bundle before signing, then sign with `NikoRelease.entitlements` (or the explicitly selected `NikoLocalDevelopment.entitlements` for local development). This adds `NSCameraUsageDescription` and verifies the signed camera entitlement; stock RustDesk metadata and entitlements remain unchanged. `--require-camera` repeats these checks on both archives and rejects test-provider exports. Camera capability remains disabled until its explicit device/format grant and actual capture/stop acceptance are complete. No build or package command requests TCC, opens a camera, or demonstrates hardware compatibility.

New builds pass `--require-privacy-watchdog`: the helper must be an ordinary ARM64 executable with the production provider and its signed identity. Omitting that flag permits inspection of historical packages and reports their helper presence. Privacy mode remains disabled pending real display, input and coexistence acceptance. The independent helper stores complete gamma tables in a private temporary directory before acknowledging a blackout, then uses an inherited anonymous channel and parent/heartbeat monitoring to attempt owned-table recovery. Unresolved records remain private on disk. Native IPC tests use a separately compiled provider with no CoreGraphics imports; they do not prove real gamma recovery or input release when the parent is suspended. An identical black table written by another app cannot establish exclusive ownership, and detached-display or helper/WindowServer failures still require acceptance and recovery work.

## CI and experimental platforms

`.github/workflows/release.yml` accepts manual `workflow_dispatch` runs and pushes to `validation/**` branches for build review, and pushes to `main`. A validation-branch run builds all three platforms without creating a GitHub Release. A manual run builds all three platforms by default; clearing `experimental_platforms` selects macOS alone. Every push to `main` builds all three platforms and replaces the rolling `nightly` pre-release; its notes state plainly that Windows and Android target-device acceptance is still pending. A `v*` tag publishes all three platforms under the release job's explicit write permission. Pages only deploys from its configured main branch, so validation branches do not publish the website. All actions are pinned to commit SHAs. A new validation-branch push or CI run is an external action requiring the user's authorization; editing this workflow does not perform it.

The Windows NikoDesk build uses the actual `NikoDesk.exe` payload and the portable wrapper's separate `nikodesk` feature. It emits `NikoDesk-windows-x64.exe`, a self-extracting user-mode client, rather than a system installer. Extraction uses the `nikodesk` directory; the wrapper does not inject install/Quick Support arguments, read wrapper-name custom-server settings, or copy/kill RustDesk's RuntimeBroker process. The manifest requests `asInvoker` privileges. The inherited RustDesk feature-off build keeps its existing packer path.

On a Windows x64 machine with Flutter 3.24.5, Rust 1.88.0, Visual Studio C++ tools, LLVM and NASM already available, use the same clean clone and vcpkg commit as above. Bootstrap the isolated Windows vcpkg checkout and build from the repository root:

```powershell
$env:VCPKG_ROOT="$PWD\.tools\vcpkg"
$env:VCPKG_DEFAULT_HOST_TRIPLET='x64-windows-static'
$env:VCPKG_DISABLE_METRICS='1'
& "$env:VCPKG_ROOT\bootstrap-vcpkg.bat" -disableMetrics
& "$env:VCPKG_ROOT\vcpkg.exe" install --triplet x64-windows-static `
  --overlay-ports="$PWD\res\vcpkg-nikodesk" `
  --x-install-root="$env:VCPKG_ROOT\installed"
python3 .\build.py --flutter --hwcodec --nikodesk --build-name 1.0.6 --build-number 15
```

NikoDesk defaults to the product version in `flutter/pubspec.yaml`, currently `1.0.6+15`; explicit parameters pass that same version into both Flutter and the portable packer. The executable resources use numeric version `1.0.5.14` and product string `1.0.6+15`. The inherited Cargo/native protocol version remains `1.5.0`. Do not change the protocol version to repair product metadata. Invalid Windows version components fail before compilation or packaging. The packer records the product/build alongside its extraction timestamp and includes the license and source revision before compressing the bundle.

In the outer local development workspace, `scripts/build-windows.ps1` performs the actual Windows x64 build in an isolated source snapshot. Prepare the official Flutter 3.24.5 Windows SDK at `.tools/windows/flutter`, LLVM including `libclang.dll` at `.tools/windows/llvm/bin`, and NASM 2.16.03 at `.tools/windows/native/bin`. Existing Visual Studio C++/Windows SDK tools, Python 3.9 or newer and Git are prerequisites; the script installs no system tools. Run it from an ordinary, unelevated Visual Studio developer PowerShell where `cl.exe`, `rc.exe`, `mt.exe`, CMake and Ninja are available. It uses private Rust/Cargo/Python/vcpkg directories under `.tools/windows`, pins Rust 1.88.0 and the vcpkg revision above, applies the two CI Flutter patches only in the private SDK, and runs the real native/Flutter/packer builds and Windows-specific regression tests. It does not launch the app or install services, drivers or autostart entries.

```powershell
.\scripts\build-windows.ps1 -ProductVersion 1.0.6 -BuildNumber 15 -PreflightOnly
.\scripts\build-windows.ps1 -ProductVersion 1.0.6 -BuildNumber 15
```

The script requires an existing `rustup` bootstrap executable, but keeps the selected toolchain and proxies in this workspace's private directories. `-PreflightOnly` records prerequisites and host information; it does not compile the client. A completed build records the exact Windows build, source hashes/revision/dirty state, ordinary-user `asInvoker` manifests, x64 PE payloads, product versions, package hashes and test output under `artifacts/windows/`. Both the Flutter runner and portable wrapper explicitly request `asInvoker` with `uiAccess=false`; this common Windows runner declaration also applies to feature-off builds. That declaration grants no elevated/UAC-screen capability. The core/library/plugin names inherited from upstream remain internal dependencies, while the product executable and runtime identity are NikoDesk.

CI uploads the portable EXE and a ZIP of the complete Flutter bundle (`NikoDesk-windows-x64.exe`/`.zip`) for inspection. The prior three-platform CI completed native Windows MSVC compilation and executable-resource/package inspection. Real Windows startup, installation and remote-session acceptance remain pending; macOS-host tests and API cross-compilation do not establish those runtime behaviors. The default build creates no Authenticode signature or system installer. The old public `v1.0.0` Windows ZIP was removed and is not evidence of this repaired portable build.

The optional unattended validation path uses `.github/scripts/build-windows-product.py`, shared by the outer PowerShell script and CI. Use the version/build from this checkout's `flutter/pubspec.yaml`; setup rejects overrides that differ from the snapshot. On the configured native Windows x64 host:

```powershell
python3 .github/scripts/build-windows-product.py --build-name 1.0.6 --build-number 15 `
  --setup-output dist/NikoDesk-windows-x64-setup-validation `
  --setup-trust-mode reviewed-local-unsigned-validation
```

This builds the actual HOST, GUI and setup binaries, freezes the GUI and flat service dependency closure before compiling setup, and verifies versions, manifests, import dependencies, compiled pins and the complete archive. Output paths must be new. The source pipeline now also builds a single installation-assistant EXE containing the complete frozen bundle, alongside the inspection ZIP and JSON/text. The assistant extracts into a new per-user directory and starts the ordinary GUI, where the user configures the private server and explicitly confirms installation. Setup requires the original GUI authorization and visible native/UAC confirmation; directly double-clicking setup is unsupported. The EXE has been built and package-verified in native Windows CI; its actual installation/service acceptance remains pending. Building does not run setup or install/start a service.

The outer script opts in with `-BuildSetupValidation`. A manual CI run opts in with `windows_setup_validation` (default false); this defines a separate validation-artifact upload. Merely editing the workflow executes no CI or upload. Main, version-tag and validation-branch pushes include the setup-validation bundle; it is uploaded as a separate artifact.

Windows CI runs `.github/scripts/verify-package-windows.py` before release publication. This host-independent gate reads PE resources directly: the runner and portable wrapper must be x64 EXEs with product version `1.0.6+15`, numeric version `1.0.5.14`, `NikoDesk` identity and default manifests requesting `asInvoker` with `uiAccess=false`. Bundled DLLs must be x64 DLLs; the Dart AOT library must be x64 ELF. The gate requires the real core, Flutter and virtual-display libraries, Dart/ICU/assets, original license and matching source revision/dirty record. It rejects extra executables, service helpers, reparse points and ambiguous Windows paths. The reviewed, digest-pinned Amyuni display-driver files are allowed only in their dedicated usbmmidd_v2 directory; bundling does not install that driver. Every ZIP file must match the inspected bundle's SHA256 and size.

Portable inspection requires pinned [Brotli 1.2.0](https://pypi.org/project/Brotli/1.2.0/), installed only in a private dependency directory. The gate checks every `libs/portable/data.bin` entry using bounded decompression, legacy MD5 and SHA256, then verifies that this complete blob occurs exactly once in initialized readable PE data. It rejects an `RDPKG` resource that could override the inspected payload. CI adds `EXPERIMENTAL.txt` after building the portable EXE; this companion notice is the only bundle file excluded from the portable comparison. Neither executable loading nor client execution is performed. The JSON report keeps launch, remote sessions, unattended access and production signing explicitly unverified. Parser fixtures and the cached old public PE's expected version rejection do not establish that a newly built Windows client is usable.

To inspect an already built package, set `PYTHONPATH` to the private Brotli directory and provide the actual recorded source SHA and dirty state. The input ZIP must contain the complete bundle at its root. Example for the clean CI checkout:

```powershell
python3 .github/scripts/verify-package-windows.py `
  --bundle flutter/build/windows/x64/runner/Release `
  --portable NikoDesk-windows-x64.exe `
  --zip NikoDesk-windows-x64.zip --blob libs/portable/data.bin `
  --version-name 1.0.6 --build-number 15 --license-file LICENCE `
  --source-revision $env:GITHUB_SHA --source-dirty false `
  --native-protocol-version 1.5.0 --report-output windows-package-report.json
```

Android uses the `nikodesk` flavor and a separate `io.nikodesk.android` application ID; the upstream `rustdesk` flavor retains its own platform manifest. The NikoDesk manifest is controller-only. The current development validation version is `1.0.5`, with Android versionCode `14`; this product version is separate from the inherited native protocol version and does not assert that all planned features are complete.

Use JDK 17, Rust 1.88.0, cargo-ndk 3.1.2, Flutter 3.24.5, SDK 36, Build Tools 36.0.0 and NDK r28c (`28.2.13676358`). Older pinned Flutter plugins also require SDK platforms 31–34 and Build Tools 35.0.0. The Gradle wrapper pins 8.11.1 and its distribution checksum. Keep the SDK, caches and signing material outside tracked source. After preparing those tools, build the real ARM64 native dependencies and core before Gradle; Gradle resolves the Android rustls Maven artifact from locked, offline Cargo metadata.

From the repository root, use a separate Android vcpkg checkout at the same pinned revision as above. Set its host triplet to `arm64-osx` on Apple Silicon or `x64-linux` on the Linux CI host. For NDK r28c, `NDK_HOST` is `darwin-x86_64` on macOS, including Apple Silicon, and `linux-x86_64` on Linux:

```sh
mkdir -p .tools/android
git clone https://github.com/microsoft/vcpkg.git .tools/android/vcpkg
git -C .tools/android/vcpkg checkout 9e593bb18ea69cc5095e012465dcd675a822ed0d
export VCPKG_ROOT="$PWD/.tools/android/vcpkg"
export VCPKG_DEFAULT_TRIPLET=arm64-android
case "$(uname -s):$(uname -m)" in
  Darwin:arm64) export VCPKG_DEFAULT_HOST_TRIPLET=arm64-osx NDK_HOST=darwin-x86_64 ;;
  Linux:x86_64) export VCPKG_DEFAULT_HOST_TRIPLET=x64-linux NDK_HOST=linux-x86_64 ;;
  *) echo 'Unsupported build host for these pinned instructions'; exit 1 ;;
esac
export VCPKG_DISABLE_METRICS=1
"$VCPKG_ROOT/bootstrap-vcpkg.sh" -disableMetrics
export ANDROID_NDK_ROOT="$ANDROID_NDK_HOME"
export LIBCLANG_PATH="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/$NDK_HOST/lib"
export BINDGEN_EXTRA_CLANG_ARGS_aarch64_linux_android="--sysroot=$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/$NDK_HOST/sysroot -I$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/$NDK_HOST/sysroot/usr/include/aarch64-linux-android -D__ANDROID_API__=22"
export CARGO_TARGET_AARCH64_LINUX_ANDROID_RUSTFLAGS='-C link-arg=-Wl,-z,max-page-size=16384 -C link-arg=-Wl,-z,common-page-size=16384'
rustup target add --toolchain 1.88.0 aarch64-linux-android
cargo +1.88.0 install cargo-ndk --version 3.1.2 --locked
"$VCPKG_ROOT/vcpkg" install --triplet arm64-android \
  --overlay-ports="$PWD/res/vcpkg-nikodesk" \
  --x-install-root="$VCPKG_ROOT/installed"
cargo +1.88.0 ndk --platform 22 --target aarch64-linux-android build \
  --locked --release --features flutter,hwcodec,nikodesk
mkdir -p flutter/android/app/src/main/jniLibs/arm64-v8a
cp target/aarch64-linux-android/release/liblibrustdesk.so \
  flutter/android/app/src/main/jniLibs/arm64-v8a/librustdesk.so
cp "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/$NDK_HOST/sysroot/usr/lib/aarch64-linux-android/libc++_shared.so" \
  flutter/android/app/src/main/jniLibs/arm64-v8a/
```

An installable test APK requires one persistent, private test keystore. Set `NIKODESK_TEST_SIGNING_PROPERTIES` to an external properties file containing `storeFile`, `storePassword`, `keyAlias` and `keyPassword`; use an absolute keystore path. Missing or incomplete signing material fails the build. Do not use Gradle's runner-generated debug key or copy RustDesk's private key. Supply the common version explicitly:

```sh
cd flutter
flutter pub get --enforce-lockfile
NIKODESK_TEST_SIGNING=1 flutter build apk --release --flavor nikodesk \
  --target-platform android-arm64 --no-pub --dart-define=NIKODESK=true \
  --build-name 1.0.6 --build-number 15
```

The output is `flutter/build/app/outputs/flutter-apk/app-nikodesk-release.apk`, with application ID `io.nikodesk.android.dev`. Do not add `--split-per-abi` for this single ARM64 target: Flutter 3.24.5 changes versionCode `14` to `2014` when ABI splitting is enabled. Verify the expected public certificate fingerprint, exact versions and all native libraries before copying it to `NikoDesk-android-arm64-test.apk`:

```sh
cd ..
python3 .github/scripts/verify-package-android.py \
  flutter/build/app/outputs/flutter-apk/app-nikodesk-release.apk \
  --application-id io.nikodesk.android.dev --version-name 1.0.6 --version-code 15 \
  --certificate-sha256 "$NIKODESK_TEST_CERTIFICATE_SHA256" \
  --manifest-output android-manifest.xml --report-output android-package-report.json
```

`NIKODESK_TEST_CERTIFICATE_SHA256` is the expected public certificate digest, not a secret. Keep an encrypted private backup of the original keystore, its password/properties and the recorded certificate digest together. Reuse that same identity and increase versionCode for future upgrades of `.dev`. A replacement key cannot upgrade existing installations signed by the lost key. The `.dev` channel can coexist with the `io.nikodesk.android` release; it is not a production release signer. Never commit or upload private signing material.

In the local NikoDesk development workspace, the outer `scripts/setup-android-tools.py`, `scripts/setup-android-signing.py --initialize` and `scripts/build-android.sh` automate the same path on Apple Silicon. Signing initialization is explicit and runs once; subsequent builds reuse it. Run `NIKO_VERSION=1.0.5 NIKO_BUILD_NUMBER=14 bash scripts/build-android.sh` from that workspace. The build records an immutable source snapshot, its dirty state, tool hashes and package verification under `artifacts/android/`. These outer workspace helpers are separate from this published source checkout.

CI holds the release key in its `ANDROID_RELEASE_KEYSTORE_BASE64`/`ANDROID_RELEASE_KEYSTORE_PASSWORD` secrets; the workflow pins the key's public certificate SHA-256. With the secrets present it decodes them into `flutter/android/key.properties`, builds `io.nikodesk.android` as `NikoDesk-android-arm64.apk`, and verifies that APK against the pinned fingerprint. Forks or secret-less runs fall back to `NIKODESK_UNSIGNED_BUILD=1` and the unsigned `.dev` structure build `NikoDesk-android-arm64-unsigned.apk`, which cannot be installed or used to prove upgrades. Release signing and unsigned mode are mutually exclusive. Actual device installation/startup/connection and two-version upgrade acceptance remain pending; publishing the signed package does not establish those behaviors.

The final APK gate inspects the merged manifest using the SDK's [`apkanalyzer manifest print`](https://developer.android.com/tools/apkanalyzer). It checks the exact application ID/versionCode, `nikodesk` URI scheme, launcher, removal of receiving services/BootReceiver/permissions, ZIP integrity, ARM64 ELF headers and every native library's 16KB LOAD alignment. Uncompressed libraries must also have 16KB ZIP data offsets; compressed libraries require `extractNativeLibs=true`. The actual pinned Flutter engine is checked along with the Rust, C++ and Dart libraries. The gate preserves the upstream Kotlin/JNI class namespace, which is separate from application identity. Signed test builds also require verified signatures and the expected certificate fingerprint. These are package checks, not installation or connection tests.

Building or packaging is not permission to launch an experimental client. Before a separate runtime test, verify private-server settings, IPC, service state and ports; preserve the installed RustDesk client and never register the experiment with public rendezvous services.
