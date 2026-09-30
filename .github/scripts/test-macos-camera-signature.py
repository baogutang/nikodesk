#!/usr/bin/env python3
"""Compile and sign static fixtures, never execute a fixture or capture camera data."""
import argparse
import importlib.util
import json
import plistlib
import subprocess
from pathlib import Path


def run(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True)


def validate(output):
    repository = Path(__file__).resolve().parents[2]
    script = repository / ".github/scripts"
    spec = importlib.util.spec_from_file_location("camera_static_package", script / "package-macos.py")
    package = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(package)
    output.mkdir(parents=True, exist_ok=True)
    output = output.resolve()
    app = output / "NikoDesk.app"
    if app.exists():
        raise ValueError("Use a new output directory; existing evidence is not overwritten")
    contents = app / "Contents"
    for directory in ("MacOS", "Frameworks", "Resources"):
        (contents / directory).mkdir(parents=True)
    info_path = contents / "Info.plist"
    info_path.write_bytes(plistlib.dumps({"CFBundleIdentifier":"io.nikodesk.macos", "CFBundleExecutable":"NikoDesk",
        "CFBundlePackageType":"APPL", "CFBundleShortVersionString":"1.1.0", "CFBundleVersion":"3",
        "LSMinimumSystemVersion":"12.3"}))
    source = output / "static-runner.cpp"
    source.write_text('extern "C" int NKCameraAuthorizationStatus();\nint (*volatile camera_entry)()=NKCameraAuthorizationStatus;\nint main(){return camera_entry?0:1;}\n')
    run("xcrun", "clang++", "-std=c++17", "-fobjc-arc", "-fblocks", "-mmacosx-version-min=12.3",
        "-dynamiclib", str(repository / "libs/scrap/src/common/macos_camera.mm"),
        "-framework", "AVFoundation", "-framework", "Foundation", "-framework", "CoreMedia", "-framework", "CoreVideo",
        "-Wl,-install_name,@rpath/liblibrustdesk.dylib", "-o", str(contents / "Frameworks/liblibrustdesk.dylib"))
    run("xcrun", "clang++", "-mmacosx-version-min=12.3", str(source), "-L"+str(contents / "Frameworks"),
        "-llibrustdesk", "-Wl,-rpath,@executable_path/../Frameworks", "-o", str(contents / "MacOS/NikoDesk"))
    run("python3", str(script / "prepare-macos-camera.py"), str(app))
    run("python3", str(script / "build-macos-privacy-watchdog.py"), str(app), "--architecture", "arm64")

    def sign(entitlement="NikoRelease.entitlements"):
        run("bash", str(script / "sign-macos-app.sh"), str(app), "-", str(repository / "flutter/macos/Runner" / entitlement))

    sign()
    positive = package.verify_bundle(app, True, True)
    checks = {"actual_native_signature_and_camera_metadata":True}
    # -R needs an '=' prefix for inline source; without it the text is a filename.
    helper = contents / "Helpers/NikoDeskPrivacyWatchdog"
    wrong_syntax = subprocess.run(["codesign", "--verify", "--strict", "-R",
        'identifier "io.nikodesk.privacy-watchdog"', str(helper)], capture_output=True, text=True)
    checks["requirement_filename_form_rejected"] = wrong_syntax.returncode != 0
    (output / "requirement-filename-form.stderr").write_text(wrong_syntax.stderr)
    run("codesign", "--force", "--options", "runtime", "--sign", "-", "--entitlements",
        str(repository / "flutter/macos/Runner/Release.entitlements"), str(app))
    try:
        package.verify_bundle(app, True, True)
        raise AssertionError("Missing camera entitlement accepted")
    except ValueError as error:
        if "signed camera entitlement" not in str(error): raise
        checks["actual_missing_signed_camera_entitlement_rejected"] = True
    sign()
    info=plistlib.loads(info_path.read_bytes()); info["NSCameraUsageDescription"]=" "
    info_path.write_bytes(plistlib.dumps(info));sign()
    try:
        package.verify_bundle(app, True, True)
        raise AssertionError("Blank purpose accepted")
    except ValueError as error:
        if "NSCameraUsageDescription" not in str(error): raise
        checks["actual_blank_purpose_rejected"] = True
    run("python3", str(script / "prepare-macos-camera.py"), str(app));sign()
    package.verify_bundle(app, True, True)
    if not all(checks.values()): raise AssertionError(checks)
    report = {"layer":"compiled-static-signature-fixture", "checks":checks, "passed":len(checks),
        "product_build":False, "fixture_or_helper_executed":False, "TCC_requested":False,
        "physical_camera_started":False, "gamma_or_eventtap_changed":False, "positive_verification":positive}
    (output / "validation.json").write_text(json.dumps(report,indent=2)+"\n")
    print(json.dumps(report,indent=2))


if __name__ == "__main__":
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output",type=Path)
    validate(parser.parse_args().output)
