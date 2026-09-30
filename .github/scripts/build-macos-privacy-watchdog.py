#!/usr/bin/env python3
"""Compile the ordinary-user NikoDesk recovery helper; never execute it."""

import argparse
import json
import os
import plistlib
import subprocess
import tempfile
from pathlib import Path


def build(app, architecture):
    with (app / 'Contents/Info.plist').open('rb') as stream:
        if plistlib.load(stream).get('CFBundleIdentifier') != 'io.nikodesk.macos':
            raise ValueError('Recovery helper is only packaged in a NikoDesk app')
    source = Path(__file__).resolve().parents[2] / 'src/platform/macos_privacy_watchdog.cpp'
    sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
    directory = app / 'Contents/Helpers'
    if directory.is_symlink() or not directory.resolve().is_relative_to(app.resolve()):
        raise ValueError('Recovery helper directory must stay inside the app bundle')
    directory.mkdir(parents=True, exist_ok=True)
    output = directory / 'NikoDeskPrivacyWatchdog'
    if output.is_symlink():
        raise ValueError('Refusing to overwrite a symlink recovery helper')
    with tempfile.TemporaryDirectory(prefix='.nikodesk-watchdog-build-', dir=directory) as temporary:
        binary = Path(temporary) / output.name
        subprocess.run(['xcrun', '--sdk', 'macosx', 'clang++', '-std=c++17', '-O2',
                        '-target', architecture + '-apple-macos12.3', '-isysroot', sdk,
                        str(source), '-framework', 'CoreGraphics', '-framework', 'CoreFoundation', '-framework', 'ColorSync',
                        '-o', str(binary)], check=True)
        data = binary.read_bytes()
        if b'nikodesk-privacy-watchdog-v1-production' not in data or b'nikodesk-privacy-watchdog-v1-test-provider' in data:
            raise ValueError('Recovery helper must contain the production provider')
        binary.chmod(0o755)
        os.replace(binary, output)
    return {'privacy_watchdog_present': True, 'privacy_watchdog_protocol_version': 1,
            'architecture': architecture, 'path': str(output), 'helper_executed': False,
            'gamma_runtime_verified': False, 'input_release_runtime_verified': False}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('--architecture', choices=('arm64', 'x86_64'), required=True)
    args = parser.parse_args()
    print(json.dumps(build(args.app, args.architecture), indent=2))
