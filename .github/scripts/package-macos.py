#!/usr/bin/env python3
"""Verify a signed NikoDesk bundle and package it without launching or re-signing it."""

import argparse
import hashlib
import json
import os
import plistlib
import subprocess
import tempfile
from datetime import datetime, timezone
from pathlib import Path


def command(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True).stdout


def verify_voice_metadata(app, info):
    purpose = info.get("NSMicrophoneUsageDescription")
    if not isinstance(purpose, str) or not purpose.strip():
        raise ValueError("This build requires a nonempty NSMicrophoneUsageDescription")
    signed = plistlib.loads(command("codesign", "-d", "--entitlements", ":-", str(app)).encode())
    if signed.get("com.apple.security.device.audio-input") is not True:
        raise ValueError("This build requires its signed microphone entitlement")
    source = Path(__file__).resolve().parents[2] / "libs/nikodesk_cpal"
    target = app / "Contents/Resources/NikoDesk/licenses/cpal"
    for parent in (target, *target.parents):
        if parent == app:
            break
        if parent.is_symlink() or not parent.is_dir():
            raise ValueError("Voice license directory must be ordinary and bundled")
    for name in ("LICENSE", "NIKODESK-PROVENANCE.json", "NIKODESK-PROVENANCE.md"):
        file = target / name
        if file.is_symlink() or not file.is_file() or file.stat().st_nlink != 1 or file.stat().st_size > 262144:
            raise ValueError("Missing or aliased fixed voice-runtime license")
        if file.read_bytes() != (source / name).read_bytes():
            raise ValueError("Voice-runtime license/provenance differs from the fixed source")
    provenance = json.loads((target / "NIKODESK-PROVENANCE.json").read_bytes())
    if provenance.get("commit") != "96d4da121b7d949677ac5b6887413a9185fd7f39" or provenance.get("tracked_files") != 83:
        raise ValueError("Voice-runtime provenance is not the fixed CPAL source")


def verify_bundle(app, require_privacy_watchdog=False, require_camera=False, require_voice=False):
    app = app.resolve()
    with (app / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    for key, expected in {
        "CFBundleIdentifier": "io.nikodesk.macos",
        "CFBundleExecutable": "NikoDesk",
        "CFBundlePackageType": "APPL",
    }.items():
        if info.get(key) != expected:
            raise ValueError(f"Unexpected {key}: {info.get(key)!r}")
    executable = app / "Contents/MacOS/NikoDesk"
    core = app / "Contents/Frameworks/liblibrustdesk.dylib"
    helper = app / "Contents/Helpers/NikoDeskPrivacyWatchdog"
    helper_present = helper.exists() or helper.is_symlink()
    if require_privacy_watchdog and not helper_present:
        raise ValueError("This build requires its independent privacy recovery helper")
    binaries = [(executable, "executable"), (core, "shared library")]
    if helper_present:
        if helper.is_symlink():
            raise ValueError("Privacy helper must be an ordinary bundled binary")
        binaries.append((helper, "executable"))
        data = helper.read_bytes()
        if b'nikodesk-privacy-watchdog-v1-production' not in data or b'nikodesk-privacy-watchdog-v1-test-provider' in data:
            raise ValueError("Privacy helper is missing its production protocol/provider")
        command("codesign", "--verify", "--strict", "-R", '=identifier "io.nikodesk.privacy-watchdog"', str(helper))
    for binary, expected_kind in binaries:
        if not binary.is_file() or not os.access(binary, os.X_OK):
            raise ValueError(f"Missing executable native binary: {binary}")
        description = command("file", "-b", str(binary))
        if "Mach-O" not in description or expected_kind not in description:
            raise ValueError(f"Invalid native binary: {binary}: {description.strip()}")
        if command("lipo", "-archs", str(binary)).strip() != "arm64":
            raise ValueError(f"Expected ARM64 binary: {binary}")
    if "@rpath/liblibrustdesk.dylib" not in command("otool", "-L", str(executable)):
        raise ValueError("The runner does not link the bundled Rust core")
    if (app / "Contents/MacOS/service").exists():
        raise ValueError("This user-mode package must not include a privileged service")

    frameworks = app / "Contents/Frameworks"
    for binary in [executable, *([helper] if helper_present else []), *(p for p in frameworks.rglob("*") if p.is_file())]:
        if "Mach-O" not in command("file", "-b", str(binary)):
            continue
        for line in command("otool", "-L", str(binary)).splitlines()[1:]:
            dependency = line.strip().split(" (", 1)[0]
            if dependency.startswith(("/System/Library/", "/usr/lib/")):
                continue
            if dependency.startswith("@rpath/"):
                resolved = frameworks / dependency.removeprefix("@rpath/")
            elif dependency.startswith("@loader_path/"):
                resolved = binary.parent / dependency.removeprefix("@loader_path/")
            elif dependency.startswith("@executable_path/"):
                resolved = executable.parent / dependency.removeprefix("@executable_path/")
            else:
                raise ValueError(f"External build-machine dependency: {dependency}")
            if not resolved.is_file() or not resolved.resolve().is_relative_to(app):
                raise ValueError(f"Missing bundled dependency: {dependency}")

    command("codesign", "--verify", "--deep", "--strict", str(app))
    camera_purpose = info.get("NSCameraUsageDescription")
    camera_present = "NSCameraUsageDescription" in info
    if require_camera or camera_present:
        if not isinstance(camera_purpose, str) or not camera_purpose.strip():
            raise ValueError("This build requires a nonempty NSCameraUsageDescription")
        signed_entitlements = plistlib.loads(command("codesign", "-d", "--entitlements", ":-", str(app)).encode())
        if signed_entitlements.get("com.apple.security.device.camera") is not True:
            raise ValueError("This build requires its signed camera entitlement")
        if "NKCameraTest" in command("nm", "-gU", str(core)):
            raise ValueError("Camera test-provider exports must not be bundled")
    if require_voice:
        verify_voice_metadata(app, info)
    return {
        "bundle_id": info["CFBundleIdentifier"],
        "executable": info["CFBundleExecutable"],
        "version": info.get("CFBundleShortVersionString"),
        "build_number": info.get("CFBundleVersion"),
        "minimum_macos": info.get("LSMinimumSystemVersion"),
        "architecture": "arm64",
        "bundle_and_signature_verified": True,
        "privacy_watchdog_present": helper_present,
        "privacy_watchdog_protocol_version": 1 if helper_present else None,
        "privacy_gamma_recovery_runtime_verified": False,
        "privacy_input_recovery_runtime_verified": False,
        "camera_metadata_and_entitlement_verified": camera_present,
        "camera_capture_runtime_verified": False,
        "camera_tcc_runtime_verified": False,
        "voice_metadata_license_and_entitlement_verified": require_voice,
        "voice_microphone_runtime_verified": False,
        "voice_playback_runtime_verified": False,
        "launch_verified": False,
        "remote_session_verified": False,
    }


def package(app, output, require_privacy_watchdog=False, require_camera=False, require_voice=False):
    verification = verify_bundle(app, require_privacy_watchdog, require_camera, require_voice)
    output.mkdir(parents=True, exist_ok=True)
    zip_path = output / "NikoDesk-macos-arm64.zip"
    dmg_path = output / "NikoDesk-macos-arm64.dmg"
    manifest_path = output / "NikoDesk-macos-arm64-manifest.json"
    for path in (zip_path, dmg_path, manifest_path):
        if path.exists():
            raise ValueError(f"Refusing to overwrite an existing output: {path}")

    with tempfile.TemporaryDirectory(prefix="nikodesk-package-") as temporary:
        work = Path(temporary)
        stage = work / "stage"
        stage.mkdir()
        command("ditto", str(app), str(stage / "NikoDesk.app"))
        (stage / "Applications").symlink_to("/Applications", target_is_directory=True)
        command("ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(app), str(zip_path))
        extracted = work / "zip"
        command("ditto", "-x", "-k", str(zip_path), str(extracted))
        if sorted(p.name for p in extracted.iterdir() if p.name != "__MACOSX") != ["NikoDesk.app"]:
            raise ValueError("The updater ZIP must contain exactly one NikoDesk.app")
        verify_bundle(extracted / "NikoDesk.app", require_privacy_watchdog, require_camera, require_voice)

        command("hdiutil", "create", "-srcfolder", str(stage), "-volname", "NikoDesk",
                "-format", "UDZO", str(dmg_path))
        command("hdiutil", "verify", str(dmg_path))
        mounted = work / "mounted"
        mounted.mkdir()
        command("hdiutil", "attach", "-readonly", "-nobrowse", "-noautoopen",
                "-mountpoint", str(mounted), str(dmg_path))
        try:
            if not (mounted / "Applications").is_symlink() or os.readlink(mounted / "Applications") != "/Applications":
                raise ValueError("The DMG is missing its Applications shortcut")
            verify_bundle(mounted / "NikoDesk.app", require_privacy_watchdog, require_camera, require_voice)
        finally:
            command("hdiutil", "detach", str(mounted))

    verification.update({
        "packaged_at_utc": datetime.now(timezone.utc).isoformat(),
        "source_sha": os.environ.get("GITHUB_SHA"),
        "release_tag": os.environ.get("GITHUB_REF_NAME"),
        "signature_integrity": "verified",
        "developer_id_trust": "not_checked",
        "notarization": "not_checked",
        "archive_roundtrip_verified": True,
        "assets": [{"name": path.name, "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
                   for path in (dmg_path, zip_path)],
    })
    manifest_path.write_text(json.dumps(verification, indent=2) + "\n")
    print(json.dumps(verification, indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("output", type=Path, nargs="?")
    parser.add_argument("--verify-only", action="store_true")
    parser.add_argument("--require-privacy-watchdog", action="store_true",
                        help="Require the ordinary-user production helper for this new build; historical packages remain inspectable")
    parser.add_argument("--require-camera", action="store_true",
                        help="Require signed camera metadata for this new build; never opens a camera or requests TCC")
    parser.add_argument("--require-voice", action="store_true",
                        help="Require signed microphone metadata and fixed CPAL license; never opens audio devices")
    args = parser.parse_args()
    if args.verify_only:
        print(json.dumps(verify_bundle(args.app, args.require_privacy_watchdog, args.require_camera, args.require_voice), indent=2))
    else:
        if args.output is None:
            parser.error("An output directory is required when packaging")
        package(args.app.resolve(), args.output.resolve(), args.require_privacy_watchdog, args.require_camera, args.require_voice)


if __name__ == "__main__":
    main()
