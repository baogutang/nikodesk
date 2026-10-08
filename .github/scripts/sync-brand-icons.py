#!/usr/bin/env python3
"""Check or regenerate NikoDesk icons from the pinned, user-provided brand pack.

Default/--check is dependency-free and never changes files. --write needs Pillow;
macOS regeneration also needs Apple's iconutil. No app installation/cache changes.
"""
import argparse
import hashlib
import importlib.util
import io
import json
import plistlib
import re
import shutil
import struct
import subprocess
import tempfile
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BRAND = Path('res/nikodesk-brand')
APP_SIZES = (16, 20, 24, 32, 40, 48, 64, 128, 256)
TRAY_SIZES = (16, 20, 24, 32, 48)
APP_ICO = 'flutter/windows/runner/resources/app_icon.ico'
TRAY_ICO = 'res/nikodesk-tray.ico'
MAC_ICNS = 'flutter/macos/Runner/AppIcon.icns'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def manifest(root):
    data = json.loads((root / BRAND / 'manifest.json').read_text(encoding='utf-8'))
    for name, record in data['sources'].items():
        if digest(root / BRAND / name) != record['sha256']:
            raise ValueError(f'Canonical brand source changed: {name}')
    return data


def ico(paths):
    from PIL import Image
    entries = []
    for path in paths:
        with Image.open(path) as image:
            size = image.width
            if size != image.height or size > 256:
                raise ValueError(f'Invalid square ICO layer: {path}')
            if size >= 128:
                data = path.read_bytes()
            else:
                pixels = image.convert('RGBA').tobytes('raw', 'BGRA')
                row = size * 4
                colour = b''.join(pixels[y * row:(y + 1) * row]
                                  for y in range(size - 1, -1, -1))
                mask_row = ((size + 31) // 32) * 4
                data = struct.pack('<IiiHHIIiiII', 40, size, size * 2, 1, 32,
                                   0, len(colour) + mask_row * size, 0, 0, 0, 0)
                data += colour + bytes(mask_row * size)
        entries.append((size, data))
    offset = 6 + 16 * len(entries)
    directory = bytearray(struct.pack('<HHH', 0, 1, len(entries)))
    for size, data in entries:
        directory += struct.pack('<BBBBHHII', size % 256, size % 256, 0, 0,
                                 1, 32, len(data), offset)
        offset += len(data)
    return bytes(directory) + b''.join(data for _, data in entries)


def check(root=ROOT):
    data = manifest(root)
    for target, source in data['copies'].items():
        if digest(root / target) != data['sources'][source]['sha256']:
            raise ValueError(f'Brand icon differs from canonical source: {target}')
    for target, expected in data['generated'].items():
        if digest(root / target) != expected:
            raise ValueError(f'Generated brand icon differs: {target}')
    if set(data['generated']) != {APP_ICO, TRAY_ICO, MAC_ICNS}:
        raise ValueError('Missing generated platform icon checksums')
    return len(data['copies']) + len(data['generated'])


def write(root=ROOT, platform='all'):
    data = manifest(root)
    if platform in ('all', 'macos') and shutil.which('iconutil') is None:
        raise ValueError('macOS icons must be generated with Apple iconutil')
    for target, source in data['copies'].items():
        owner = 'android' if '/android/' in target else 'macos' if target == 'res/nikodesk-tray.png' else 'ui'
        if platform == 'all' or owner in (platform, 'ui'):
            shutil.copyfile(root / BRAND / source, root / target)
    if platform in ('all', 'windows'):
        for target, prefix, sizes in ((APP_ICO, 'app', APP_SIZES),
                                      (TRAY_ICO, 'tray', TRAY_SIZES)):
            (root / target).write_bytes(ico([root / BRAND / 'windows' / f'{prefix}-{s}.png'
                                            for s in sizes]))
    if platform in ('all', 'macos'):
        with tempfile.TemporaryDirectory(prefix='nikodesk-icons-') as tmp:
            iconset = Path(tmp) / 'NikoDesk.iconset'
            iconset.mkdir()
            for source in (root / BRAND / 'macos').glob('icon_*.png'):
                shutil.copyfile(source, iconset / source.name)
            subprocess.run(['iconutil', '-c', 'icns', str(iconset), '-o',
                            str(root / MAC_ICNS)], check=True)


def export(folder, root=ROOT):
    data = manifest(root)
    if folder.exists() and any(folder.iterdir()):
        raise ValueError('Icon export folder must be empty')
    for source in data['sources']:
        if source.startswith(('windows/', 'android/')):
            target = folder / source
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(root / BRAND / source, target)


def verify_windows_executable(path, root=ROOT):
    spec = importlib.util.spec_from_file_location('windows_package', root / '.github/scripts/verify-package-windows.py')
    package = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(package)
    if path.stat().st_size > package.MAX_FILE:
        raise ValueError('Executable exceeds package verification limit')
    pe = package.PE(path.read_bytes())
    try:
        verify_windows_resources(pe.resources, (root / APP_ICO).read_bytes())
    except ValueError as error:
        raise ValueError(f'{path}: {error}') from error


def verify_windows_resources(resources, raw):
    _, _, count = struct.unpack_from('<HHH', raw)
    expected = {}
    for index in range(count):
        width, height, colours, reserved, planes, bits, size, offset = struct.unpack_from('<BBBBHHII', raw, 6 + 16 * index)
        expected[(width, height, colours, reserved, planes, bits, size)] = raw[offset:offset + size]
    groups = [(key, data) for key, data in resources.items() if key[0] == 14]
    if not groups:
        raise ValueError('Missing executable brand icon')
    for key, group in groups:
        if len(group) != 6 + count * 14 or struct.unpack_from('<HHH', group) != (0, 1, count):
            raise ValueError('Executable icon sizes differ')
        actual = {}
        for index in range(count):
            entry = struct.unpack_from('<BBBBHHIH', group, 6 + 14 * index)
            actual[entry[:-1]] = resources.get((3, entry[-1], key[2]))
        if actual != expected:
            raise ValueError('Executable carries a stale/different brand icon')


def verify_macos_app(path, root=ROOT):
    info = plistlib.loads((path / 'Contents/Info.plist').read_bytes())
    if (info.get('CFBundleIdentifier') != 'io.nikodesk.macos'
            or info.get('CFBundleIconFile') != 'AppIcon.icns' or info.get('CFBundleIconName')):
        raise ValueError(f'{path}: unexpected macOS bundle/icon identity')
    if digest(path / 'Contents/Resources/AppIcon.icns') != digest(root / MAC_ICNS):
        raise ValueError(f'{path}/Contents/Resources/AppIcon.icns: stale/different brand icon')


def verify_android_apk(path, aapt2, root=ROOT):
    from PIL import Image

    def dump(kind, file=None):
        command = [str(aapt2), 'dump', kind, str(path)]
        if file is not None:
            command += ['--file', file]
        return subprocess.run(command, check=True, capture_output=True, text=True).stdout

    resource_ids, files = {}, {}
    current = None
    for line in dump('resources').splitlines():
        header = re.fullmatch(r'\s*resource (0x[0-9a-f]+) (\S+).*', line)
        if header:
            current = header[2]
            resource_ids[current] = header[1]
            files[current] = {}
        value = re.fullmatch(r'\s*\(([^)]*)\) \(file\) (\S+) type=\w+.*', line)
        if value and current:
            files[current][value[1]] = value[2]
    android = '{http://schemas.android.com/apk/res/android}'
    manifest_text = dump('xmltree', 'AndroidManifest.xml')
    with zipfile.ZipFile(path) as apk:
        for name, attribute in [('ic_launcher', 'icon'), ('ic_launcher_round', 'roundIcon')]:
            key = 'mipmap/' + name
            if key not in files or not re.search(r':' + attribute + r'\(0x[0-9a-f]+\)=@' + resource_ids[key] + r'\b', manifest_text):
                raise ValueError('APK launcher/round icon reference differs from NikoDesk brand')
            for density in ('mdpi', 'hdpi', 'xhdpi', 'xxhdpi', 'xxxhdpi'):
                encoded = apk.read(files[key][density])
                with Image.open(io.BytesIO(encoded)) as actual, Image.open(root / BRAND / 'android' / f'mipmap-{density}' / f'{name}.png') as expected:
                    if actual.size != expected.size or actual.convert('RGBA').tobytes() != expected.convert('RGBA').tobytes():
                        raise ValueError(f'APK contains stale launcher pixels: {name}/{density}')
            for version in (26, 33):
                text = dump('xmltree', files[key][f'anydpi-v{version}'])
                layers = ['background', 'foreground'] + (['monochrome'] if version == 33 else [])
                references = re.findall(r':drawable\(0x[0-9a-f]+\)=@(0x[0-9a-f]+)', text)
                if references != [resource_ids[f'drawable/nikodesk_launcher_{layer}'] for layer in layers]:
                    raise ValueError('APK adaptive icon layers differ from NikoDesk brand')
        for name in ('background', 'foreground', 'monochrome'):
            resource = 'drawable/nikodesk_launcher_' + name
            text = dump('xmltree', files[resource][''])
            source = ET.parse(root / BRAND / 'android/drawable' / (resource.split('/')[1] + '.xml'))
            paths = [node.attrib[android + 'pathData'] for node in source.iter() if android + 'pathData' in node.attrib]
            if re.findall(r':pathData\(0x[0-9a-f]+\)="([^"]*)"', text) != paths:
                raise ValueError(f'APK adaptive icon geometry differs: {resource}')
            colours = [value[1:].lower().rjust(8, 'f') for node in source.iter()
                       for attr, value in node.attrib.items() if attr in
                       (android + 'color', android + 'fillColor', android + 'strokeColor')]
            if sorted(re.findall(r'(?:color|fillColor|strokeColor)\(0x[0-9a-f]+\)=#([0-9a-f]{8})', text)) != sorted(colours):
                raise ValueError(f'APK adaptive icon colours differ: {resource}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--check', action='store_true')
    mode.add_argument('--write', action='store_true')
    mode.add_argument('--export', type=Path)
    parser.add_argument('--platform', choices=('all', 'macos', 'windows', 'android'), default='all')
    parser.add_argument('--windows-exe', type=Path, action='append', default=[])
    parser.add_argument('--macos-app', type=Path)
    parser.add_argument('--android-apk', type=Path)
    parser.add_argument('--aapt2', type=Path)
    args = parser.parse_args()
    if args.write:
        write(platform=args.platform)
    if args.export:
        export(args.export)
    count = check()
    for path in args.windows_exe:
        verify_windows_executable(path)
    if args.macos_app:
        verify_macos_app(args.macos_app)
    if args.android_apk:
        if args.aapt2 is None:
            parser.error('--android-apk requires --aapt2 (and Pillow)')
        verify_android_apk(args.android_apk, args.aapt2)
    print(f'Canonical NikoDesk platform icons verified: {count} files')


if __name__ == '__main__':
    main()
