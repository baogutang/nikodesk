#!/usr/bin/env python3
"""Add Niko device purposes and fixed voice-runtime license before signing."""
import argparse
import os
import plistlib
from pathlib import Path

PURPOSE = "NikoDesk uses the selected camera only after you explicitly approve a camera session. You can stop it at any time."
MICROPHONE_PURPOSE = "NikoDesk uses your selected microphone only after you explicitly approve a voice call. You can stop the call at any time."
VOICE_SOURCE = Path(__file__).resolve().parents[2] / "libs/nikodesk_cpal"
VOICE_LICENSE_FILES = ("LICENSE", "NIKODESK-PROVENANCE.json", "NIKODESK-PROVENANCE.md")


def prepare_voice_license(app, contents):
    target = contents / "Resources/NikoDesk/licenses/cpal"
    for part in [contents / "Resources", contents / "Resources/NikoDesk",
                 contents / "Resources/NikoDesk/licenses", target]:
        if part.is_symlink() or (part.exists() and not part.is_dir()):
            raise ValueError("Voice license directory must not alias an external path")
        part.mkdir(exist_ok=True)
        if not part.resolve(strict=True).is_relative_to(app):
            raise ValueError("Voice license directory must remain inside this bundle")
    for name in VOICE_LICENSE_FILES:
        source = VOICE_SOURCE / name
        destination = target / name
        if source.is_symlink() or not source.is_file() or source.stat().st_size > 262144:
            raise ValueError("Missing fixed voice-runtime license source")
        if destination.is_symlink() or (destination.exists() and
                (not destination.is_file() or destination.stat().st_nlink != 1)):
            raise ValueError("Voice license must not alias another file")
        flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC | getattr(os, "O_NOFOLLOW", 0)
        with os.fdopen(os.open(destination, flags, 0o644), "wb") as stream:
            stream.write(source.read_bytes())


def prepare(app):
    app = app.resolve(strict=True)
    contents = app / "Contents"
    info_path = contents / "Info.plist"
    if contents.is_symlink() or info_path.is_symlink() or not info_path.resolve(strict=True).is_relative_to(app):
        raise ValueError("Camera metadata must be an ordinary file inside the app bundle")
    if info_path.stat().st_nlink != 1:
        raise ValueError("Camera metadata must not alias another bundle's Info.plist")
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    with os.fdopen(os.open(info_path, flags), "rb") as stream:
        info = plistlib.load(stream)
    if info.get("CFBundleIdentifier") != "io.nikodesk.macos" or info.get("CFBundleExecutable") != "NikoDesk":
        raise ValueError("Camera metadata is only prepared for the built NikoDesk bundle")
    prepare_voice_license(app, contents)
    info["NSCameraUsageDescription"] = PURPOSE
    info["NSMicrophoneUsageDescription"] = MICROPHONE_PURPOSE
    with os.fdopen(os.open(info_path, os.O_WRONLY | os.O_TRUNC | getattr(os, "O_NOFOLLOW", 0)), "wb") as stream:
        plistlib.dump(info, stream, sort_keys=False)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    prepare(parser.parse_args().app)
