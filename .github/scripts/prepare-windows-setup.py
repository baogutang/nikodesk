#!/usr/bin/env python3
"""Freeze final Windows GUI/service bytes before compiling nikodesk-setup.

Set NIKODESK_SETUP_RELEASE_JSON to setup-release.json's exact contents, compile
only the setup bin, then copy only nikodesk-setup.exe into this new directory.
Never replace pinned HOST/DLL files with that final Cargo invocation's outputs.
These hashes are build pins, not publisher authentication or local consent.
"""

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import stat
import struct
import sys


ROOT = Path(__file__).resolve().parents[2]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


VERSION = load('setup_product_version', ROOT / '.github/scripts/product-version.py')
PACKAGE = load('setup_windows_package', ROOT / '.github/scripts/verify-package-windows.py')
HOST = 'nikodesk-host.exe'
RESERVED = {'setup-release.json', 'setup-release-evidence.json', 'nikodesk-setup.exe'}
TRUST_MODES = ('reviewed-local-unsigned-validation', 'signed-production')


def ordinary(path, directory=False):
    info = path.lstat()
    if (stat.S_ISLNK(info.st_mode) or getattr(info, 'st_file_attributes', 0) & 0x400 or
            not (stat.S_ISDIR(info.st_mode) if directory else stat.S_ISREG(info.st_mode)) or
            (not directory and info.st_nlink != 1)):
        raise ValueError('Expected an ordinary, unlinked local file/directory: ' + str(path))
    return info


def ordinary_parents(path):
    for parent in reversed(path.absolute().parents):
        ordinary(parent, directory=True)


def stamp(info):
    return (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def handle_stamp(info):
    """The part of a stamp an open handle and its path agree on.

    On Windows os.stat and os.fstat come from different system calls and
    report different device numbers, file IDs and change times for the same
    file, so only size and modification time can be compared across them.
    """
    return stamp(info) if os.name != 'nt' else (info.st_size, info.st_mtime_ns)


def inventory(root, flat=False):
    ordinary_parents(root)
    ordinary(root, directory=True)
    files, seen, total = {}, set(), 0
    for path in sorted(root.rglob('*')):
        relative = path.relative_to(root).as_posix()
        key = PACKAGE.windows_path(relative)
        if key in seen:
            raise ValueError('Duplicate case-insensitive Windows path')
        seen.add(key)
        info = path.lstat()
        if stat.S_ISDIR(info.st_mode):
            ordinary(path, directory=True)
            if flat:
                raise ValueError('Service payload must be flat HOST/DLL files, without GUI data')
            continue
        info = ordinary(path)
        if (flat and info.st_size == 0) or info.st_size > PACKAGE.MAX_FILE:
            raise ValueError('Empty or excessive setup input file')
        total += info.st_size
        if len(files) >= (256 if flat else PACKAGE.MAX_ENTRIES) or total > PACKAGE.MAX_TOTAL:
            raise ValueError('Excessive setup input count/size')
        if flat and (not relative.isascii() or relative.startswith('.') or
                     any(ord(c) <= 32 for c in relative) or
                     relative.split('.')[0].upper() == 'CLOCK$' or '/' in relative or
                     relative != HOST and not relative.casefold().endswith('.dll')):
            raise ValueError('Service payload accepts only exact HOST and root DLLs')
        if key in RESERVED:
            raise ValueError('Input contains a reserved setup output')
        files[relative] = stamp(info)
    if flat and HOST not in files:
        raise ValueError('Service payload is missing the exact nikodesk-host.exe')
    return files


def read_file(path, expected=None, destination=None):
    info = ordinary(path)
    if expected is not None and stamp(info) != expected:
        raise ValueError('Setup input changed before copying')
    descriptor = os.open(str(path), os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0))
    digest, length = hashlib.sha256(), 0
    contents = bytearray() if destination is None else None
    with os.fdopen(descriptor, 'rb') as stream:
        if handle_stamp(os.fstat(stream.fileno())) != handle_stamp(info):
            raise ValueError('Setup input identity changed while opening')
        output = destination.open('xb') if destination is not None else None
        try:
            for chunk in iter(lambda: stream.read(1024 * 1024), b''):
                length += len(chunk)
                if length > PACKAGE.MAX_FILE:
                    raise ValueError('Excessive setup input size')
                digest.update(chunk)
                if output is None:
                    contents.extend(chunk)
                else:
                    output.write(chunk)
            if (handle_stamp(os.fstat(stream.fileno())) != handle_stamp(info) or
                    stamp(ordinary(path)) != stamp(info)):
                raise ValueError('Setup input changed during copying')
        finally:
            if output is not None:
                output.close()
    if length != info.st_size:
        raise ValueError('Setup input length changed')
    return {'sha256': digest.hexdigest(), 'length': length}, bytes(contents) if contents is not None else None


def require_inner_gui(pe):
    optional = PACKAGE.unpack('<I', pe.data, 0x3c)[0] + 24
    rva, size = PACKAGE.unpack('<II', pe.data, optional + 120)
    if not rva or not 20 <= size <= 20 * 512:
        raise ValueError('GUI must be the inner Flutter runner, not a portable wrapper')
    imports = set()
    for index in range(size // 20):
        descriptor = PACKAGE.unpack('<5I', pe.data, pe.rva_offset(rva + index * 20, 20))
        if not any(descriptor):
            break
        name = bytearray()
        for offset in range(261):
            char = PACKAGE.checked(pe.data, pe.rva_offset(descriptor[3] + offset, 1), 1)
            if char == b'\0':
                break
            name.extend(char)
        else:
            raise ValueError('Invalid GUI import name')
        imports.add(name.decode('ascii').casefold())
    else:
        raise ValueError('Unterminated GUI import directory')
    if 'flutter_windows.dll' not in imports:
        raise ValueError('GUI must directly import the Flutter engine')


def host_version(data, parts):
    pe = PACKAGE.PE(data)
    versions = [value for key, value in pe.resources.items() if key[0] == 16]
    if not versions:
        raise ValueError('HOST is missing its product version resource')
    for raw in versions:
        node, _ = PACKAGE.version_node(raw)
        if node['key'] != 'VS_VERSION_INFO' or len(node['value']) != 52:
            raise ValueError('Invalid HOST version resource')
        fixed = struct.unpack('<13I', node['value'])
        actual = ((fixed[2] >> 16, fixed[2] & 65535, fixed[3] >> 16, fixed[3] & 65535),
                  (fixed[4] >> 16, fixed[4] & 65535, fixed[5] >> 16, fixed[5] & 65535))
        if fixed[0] != 0xfeef04bd or actual != (parts, parts):
            raise ValueError('HOST product version/build does not match pubspec')
        tables = [table for block in node['children'] if block['key'] == 'StringFileInfo'
                  for table in block['children']]
        if not tables:
            raise ValueError('HOST is missing product identity')
        for table in tables:
            strings = {}
            for value in table['children']:
                if value['kind'] != 1 or value['key'] in strings:
                    raise ValueError('Duplicate or invalid HOST version strings')
                strings[value['key']] = value['value'].decode('utf-16le').rstrip('\0')
            expected = {'ProductName': 'NikoDesk', 'OriginalFilename': HOST,
                        'FileVersion': '.'.join(map(str, parts)), 'ProductVersion': '.'.join(map(str, parts))}
            if any(strings.get(key) != value for key, value in expected.items()):
                raise ValueError('HOST product identity/version strings do not match')


def gui_records(bundle, parts):
    text = (bundle / 'NikoDesk-source.txt').read_text(encoding='utf-8')
    source = re.fullmatch(r'Product ([^;\n]+); upstream native/protocol ([^\n]+)\nSource ([0-9a-f]{40}); dirty=(true|false)\n?', text, re.I)
    if not source:
        raise ValueError('Missing GUI build source record')
    records = PACKAGE.inspect_bundle(bundle, parts, ROOT / 'LICENCE', source[3], source[4].lower() == 'true', source[2])
    require_inner_gui(PACKAGE.product_exe((bundle / 'NikoDesk.exe').read_bytes(), parts))
    return records


def service_records(directory, files, parts):
    records = {}
    for name, original in files.items():
        pin, data = read_file(directory / name, original)
        if name == HOST:
            host_version(data, parts)
        else:
            PACKAGE.PE(data, dll=True)
        records[name] = pin
    return records


def prepare(gui, service, output, trust_mode, pubspec=VERSION.PUBSPEC):
    if trust_mode not in TRUST_MODES:
        raise ValueError('An explicit supported trust mode is required')
    ordinary_parents(pubspec)
    ordinary(pubspec)
    version = VERSION.product_version(pubspec.read_text(encoding='utf-8'))
    parts = PACKAGE.version_parts(version['version_name'], version['build_number'])
    gui, service, output = gui.absolute(), service.absolute(), output.absolute()
    for source in (gui, service):
        if source == output or source in output.parents or output in source.parents:
            raise ValueError('Setup output must be separate from both input trees')
    ordinary_parents(output)
    if output.exists() or output.is_symlink():
        raise ValueError('Setup output must be a new directory; never overwrite pins')
    gui_files, service_files = inventory(gui), inventory(service, flat=True)
    gui_pins, service_pins = gui_records(gui, parts), service_records(service, service_files, parts)
    gui_names = {PACKAGE.windows_path(name): name for name in gui_files}
    for name, pin in service_pins.items():
        key = PACKAGE.windows_path(name)
        if key in gui_names:
            record = gui_pins[key]
            if name != gui_names[key] or record['sha256'] != pin['sha256'] or record['size'] != pin['length']:
                raise ValueError('GUI/service root DLL collision differs in spelling or bytes')
    output.mkdir()
    for name, original in gui_files.items():
        destination = output / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        pin, _ = read_file(gui / name, original, destination)
        if pin != {'sha256': gui_pins[PACKAGE.windows_path(name)]['sha256'], 'length': gui_pins[PACKAGE.windows_path(name)]['size']}:
            raise ValueError('Copied GUI bytes differ from inspected bundle')
    for name, original in service_files.items():
        destination = output / name
        if not destination.exists():
            pin, _ = read_file(service / name, original, destination)
        else:
            pin, _ = read_file(destination)
        if pin != service_pins[name]:
            raise ValueError('Copied service bytes differ from inspected payload')
    if inventory(gui) != gui_files or inventory(service, flat=True) != service_files:
        raise ValueError('Input tree changed during freezing')
    # Re-parse the actual copied PE bytes; pins never refer to later Cargo output.
    PACKAGE.product_exe((output / 'NikoDesk.exe').read_bytes(), parts)
    host_version((output / HOST).read_bytes(), parts)
    document = {'schema': 1, 'product_version': version['version_name'], 'product_build': version['build_number'],
                'trust_mode': trust_mode, 'ui_runner': {'name': 'NikoDesk.exe', **read_file(output / 'NikoDesk.exe')[0]},
                'service_payload': {'version': version['version_name'], 'build': version['build_number'], 'files': service_pins}}
    serialized = json.dumps(document, sort_keys=True, separators=(',', ':'))
    if len(serialized.encode('utf-8')) > 128 * 1024:
        raise ValueError('Embedded release exceeds its native bound')
    (output / 'setup-release.json').write_text(serialized, encoding='utf-8')
    sources = [ROOT / p for p in ('Cargo.toml', 'build.rs', '.github/scripts/product-version.py',
               '.github/scripts/prepare-windows-setup.py', 'src/nikodesk/background/setup_main.rs')]
    sources += sorted((ROOT / 'src/nikodesk/background/install').rglob('*.rs'))
    evidence = {'schema': 1, 'release_json_sha256': hashlib.sha256(serialized.encode()).hexdigest(),
                'pubspec_sha256': read_file(pubspec)[0]['sha256'], 'source_files': {str(p.relative_to(ROOT)): read_file(p)[0]['sha256'] for p in sources},
                'gui_bundle_files': {key: {'sha256': value['sha256'], 'length': value['size']} for key, value in gui_pins.items()},
                'host_product_version_verified': True, 'dependency_product_versions_verified': False,
                'production_signature_verified': False, 'publisher_authorized': False, 'setup_built_or_run': False,
                'note': 'DLL pins prove copied x64 bytes, not a product version or publisher. GUI source text is a build record, not publisher authority. Compile setup last and copy only its EXE; do not replace pinned files.'}
    (output / 'setup-release-evidence.json').write_text(json.dumps(evidence, sort_keys=True, indent=2) + '\n', encoding='utf-8')
    for path in output.rglob('*'):
        if path.is_file():
            path.chmod(stat.S_IRUSR | stat.S_IRGRP | stat.S_IROTH)
    return document


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--gui-bundle', type=Path, required=True)
    parser.add_argument('--service-payload', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--trust-mode', choices=TRUST_MODES, required=True)
    parser.add_argument('--pubspec', type=Path, default=VERSION.PUBSPEC)
    args = parser.parse_args(argv)
    try:
        result = prepare(args.gui_bundle, args.service_payload, args.output, args.trust_mode, args.pubspec)
    except (OSError, UnicodeError, ValueError, PACKAGE.ET.ParseError) as error:
        parser.exit(1, 'Windows setup preparation failed: {}\n'.format(error))
    print(json.dumps({'product_version': result['product_version'], 'product_build': result['product_build'],
                      'release_json': str(args.output.absolute() / 'setup-release.json'), 'setup_built_or_run': False}, sort_keys=True))
    return 0


if __name__ == '__main__':
    sys.exit(main())
