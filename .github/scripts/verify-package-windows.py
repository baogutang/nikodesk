#!/usr/bin/env python3
"""Inspect NikoDesk Windows packages without executing or loading an image.

PE/resource layouts follow Microsoft's PE and VS_VERSIONINFO specifications:
https://learn.microsoft.com/en-us/windows/win32/debug/pe-format
https://learn.microsoft.com/en-us/windows/win32/menurc/vs-versioninfo
Only the portable payload decoder needs a dependency: Brotli 1.2.0.
"""

import argparse
import hashlib
import json
import re
import stat
import struct
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path


MAX_FILE = 512 * 1024 * 1024
MAX_TOTAL = 2 * 1024 * 1024 * 1024
MAX_ENTRIES = 20000
CPAL_SOURCE = Path(__file__).resolve().parents[2] / 'libs' / 'nikodesk_cpal'
CPAL_NOTICES = tuple('data/NikoDesk/licenses/cpal/' + name for name in (
    'LICENSE', 'NIKODESK-PROVENANCE.md', 'NIKODESK-PROVENANCE.json'))
REQUIRED = ('NikoDesk.exe', 'librustdesk.dll', 'flutter_windows.dll',
            'dylib_virtual_display.dll', 'data/app.so', 'data/icudtl.dat',
            'NikoDesk-LICENCE.txt', 'NikoDesk-source.txt') + CPAL_NOTICES
# The only driver material a bundle may carry: upstream's signed Amyuni
# virtual-display driver, file for file as pinned.
DRIVER_FOLDER = 'usbmmidd_v2/'
DRIVER_FILES = {(DRIVER_FOLDER + name).casefold(): digest for name, digest in json.loads(
    (Path(__file__).resolve().parents[2] / 'res/windows-display-driver.json')
    .read_text(encoding='utf-8'))['files'].items()}


def checked(data, offset, length):
    if offset < 0 or length < 0 or offset + length > len(data):
        raise ValueError('Truncated binary structure')
    return data[offset:offset + length]


def unpack(fmt, data, offset):
    return struct.unpack(fmt, checked(data, offset, struct.calcsize(fmt)))


def version_parts(name, number):
    if not re.fullmatch(r'\d+\.\d+\.\d+', name) or not re.fullmatch(r'\d+', str(number)):
        raise ValueError('Invalid product version/build number')
    parts = tuple(int(x) for x in name.split('.')) + (int(number),)
    if any(x > 65535 for x in parts) or parts[-1] == 0:
        raise ValueError('Windows version components must fit 16 bits; build must be positive')
    return parts


def windows_path(name, portable=False):
    name = name.replace('\\', '/')
    if portable and name.startswith('./'):
        name = name[2:]
    parts = name.split('/')
    if not name or len(name) > 1024:
        raise ValueError('Invalid package path length')
    for part in parts:
        if (part in ('', '.', '..') or part.endswith(('.', ' ')) or
                any(ord(c) < 32 or c in '<>:"|?*' for c in part) or
                re.fullmatch(r'(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])', part.split('.')[0], re.I)):
            raise ValueError(f'Unsafe Windows package path: {name}')
    return name.casefold()


class PE:
    def __init__(self, data, dll=False, resources=True):
        self.data = data
        if checked(data, 0, 2) != b'MZ':
            raise ValueError('Not a PE image')
        at, = unpack('<I', data, 0x3c)
        if checked(data, at, 4) != b'PE\0\0':
            raise ValueError('Invalid PE signature')
        machine, count, _, _, _, size, flags = unpack('<HHIIIHH', data, at + 4)
        if machine != 0x8664 or not 1 <= count <= 96 or not flags & 2 or bool(flags & 0x2000) != dll:
            raise ValueError('Expected x64 PE DLL' if dll else 'Expected x64 PE executable')
        optional = at + 24
        checked(data, optional, size)
        if size < 136 or unpack('<H', data, optional)[0] != 0x20b:
            raise ValueError('Expected PE32+ optional header')
        self.sections = []
        for index in range(count):
            header = optional + size + index * 40
            virtual_size, rva, raw_size, raw = unpack('<IIII', data, header + 8)
            characteristics, = unpack('<I', data, header + 36)
            checked(data, raw, raw_size)
            if raw_size and any(raw < old['raw'] + old['size'] and old['raw'] < raw + raw_size
                                for old in self.sections if old['size']):
                raise ValueError('Overlapping PE sections')
            self.sections.append({'rva': rva, 'raw': raw, 'size': raw_size,
                                  'virtual_size': virtual_size, 'flags': characteristics})
        directories, = unpack('<I', data, optional + 108)
        self.resources = {}
        if resources and directories >= 3:
            rva, size = unpack('<II', data, optional + 128)
            if rva and size:
                self._resources(rva, size)

    def rva_offset(self, rva, size):
        matches = [x for x in self.sections if x['rva'] <= rva and
                   rva + size <= x['rva'] + min(x['size'], x['virtual_size'])]
        if len(matches) != 1:
            raise ValueError('PE RVA is outside one initialized section')
        return matches[0]['raw'] + rva - matches[0]['rva']

    def _resources(self, rva, size):
        root = self.rva_offset(rva, size)
        seen = set()

        def relative(offset, length):
            if offset + length > size:
                raise ValueError('Resource directory exceeds its declared size')
            return root + offset

        def visit(offset, path):
            if offset in seen or len(path) > 2:
                raise ValueError('Cyclic or unexpected PE resource directory')
            seen.add(offset)
            named, ids = unpack('<HH', self.data, relative(offset, 16) + 12)
            count = named + ids
            if count > 4096:
                raise ValueError('Excessive PE resource entries')
            for index in range(count):
                name, target = unpack('<II', self.data, relative(offset + 16 + 8 * index, 8))
                if name & 0x80000000:
                    start = name & 0x7fffffff
                    length, = unpack('<H', self.data, relative(start, 2))
                    name = checked(self.data, relative(start + 2, length * 2), length * 2).decode('utf-16le')
                new_path = path + (name,)
                if target & 0x80000000:
                    visit(target & 0x7fffffff, new_path)
                else:
                    if len(new_path) != 3 or new_path in self.resources:
                        raise ValueError('Invalid or duplicate PE resource leaf')
                    address, length, _, _ = unpack('<IIII', self.data, relative(target, 16))
                    if length > 1024 * 1024:
                        raise ValueError('Excessive PE resource size')
                    self.resources[new_path] = checked(self.data, self.rva_offset(address, length), length)
        visit(0, ())


def version_node(data, start=0, parent_end=None):
    end_limit = len(data) if parent_end is None else parent_end
    length, value_length, kind = unpack('<HHH', data, start)
    end = start + length
    if length < 8 or end > end_limit or kind not in (0, 1):
        raise ValueError('Invalid version resource node')
    at = start + 6
    chars = []
    while at + 2 <= end:
        char = checked(data, at, 2)
        at += 2
        if char == b'\0\0':
            break
        chars.append(char)
    else:
        raise ValueError('Unterminated version resource key')
    key = b''.join(chars).decode('utf-16le')
    at = (at + 3) & ~3
    size = value_length * (2 if kind else 1)
    if at + size > end:
        raise ValueError('Invalid version resource value length')
    value = checked(data, at, size)
    at = (at + size + 3) & ~3
    children = []
    while at + 6 <= end:
        child, next_at = version_node(data, at, end)
        children.append(child)
        at = (next_at + 3) & ~3
    return {'key': key, 'value': value, 'kind': kind, 'children': children}, end


def product_version_resource(data, parts):
    root, _ = version_node(data)
    if root['key'] != 'VS_VERSION_INFO' or len(root['value']) != 52:
        raise ValueError('Missing VS_FIXEDFILEINFO')
    fixed = struct.unpack('<13I', root['value'])
    actual_file = (fixed[2] >> 16, fixed[2] & 65535, fixed[3] >> 16, fixed[3] & 65535)
    actual_product = (fixed[4] >> 16, fixed[4] & 65535, fixed[5] >> 16, fixed[5] & 65535)
    if fixed[0] != 0xfeef04bd or actual_file != parts or actual_product != parts:
        raise ValueError(f'Wrong NikoDesk numeric product version: {actual_file}/{actual_product}; expected {parts}')
    expected = '.'.join(str(x) for x in parts[:3]) + '+' + str(parts[3])
    tables = [table for block in root['children'] if block['key'] == 'StringFileInfo'
              for table in block['children']]
    if not tables:
        raise ValueError('Missing NikoDesk string version metadata')
    for table in tables:
        strings = {}
        for node in table['children']:
            if node['kind'] != 1 or node['key'] in strings:
                raise ValueError('Invalid/duplicate string version metadata')
            strings[node['key']] = node['value'].decode('utf-16le').rstrip('\0')
        for key, value in {'ProductName': 'NikoDesk', 'OriginalFilename': 'NikoDesk.exe',
                           'FileVersion': expected, 'ProductVersion': expected}.items():
            if strings.get(key) != value:
                raise ValueError(f'Wrong NikoDesk {key}: {strings.get(key)!r}')


def ordinary_user_manifest(data):
    if b'<!DOCTYPE' in data.upper() or b'<!ENTITY' in data.upper():
        raise ValueError('Manifest contains forbidden XML declarations')
    root = ET.fromstring(data.rstrip(b'\0'))
    levels = root.findall('.//{urn:schemas-microsoft-com:asm.v3}requestedExecutionLevel')
    if (len(levels) != 1 or levels[0].get('level') != 'asInvoker' or
            levels[0].get('uiAccess') != 'false'):
        raise ValueError('Executable must explicitly request asInvoker and uiAccess=false')


def product_exe(data, parts):
    pe = PE(data)
    versions = [x for key, x in pe.resources.items() if key[0] == 16]
    manifests = [x for key, x in pe.resources.items() if key[:2] == (24, 1)]
    if not versions or not manifests:
        raise ValueError('Missing executable version or default manifest resource')
    for version in versions:
        product_version_resource(version, parts)
    for manifest in manifests:
        ordinary_user_manifest(manifest)
    return pe


def dart_aot(data):
    if (checked(data, 0, 6) != b'\x7fELF\x02\x01' or
            unpack('<HH', data, 16) != (3, 62)):
        raise ValueError('data/app.so must be the real x64 ELF Dart AOT library')
    offset, = unpack('<Q', data, 32)
    size, count = unpack('<HH', data, 54)
    if size != 56 or not 1 <= count <= 128:
        raise ValueError('Invalid Dart AOT ELF program headers')
    loads = 0
    for index in range(count):
        kind, _, file_offset, _, _, file_size, memory_size, _ = unpack('<IIQQQQQQ', data, offset + index * size)
        checked(data, file_offset, file_size)
        if memory_size < file_size:
            raise ValueError('Invalid Dart AOT ELF segment')
        loads += kind == 1
    if not loads:
        raise ValueError('Dart AOT library has no LOAD segments')


def file_hashes(path):
    sha, md5 = hashlib.sha256(), hashlib.md5()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            sha.update(chunk)
            md5.update(chunk)
    return {'sha256': sha.hexdigest(), 'md5': md5.hexdigest(), 'size': path.stat().st_size}


def inspect_bundle(bundle, parts, license_file, source_revision, source_dirty, native_version,
                   require_display_driver=False):
    info = bundle.lstat()
    if not bundle.is_dir() or bundle.is_symlink() or getattr(info, 'st_file_attributes', 0) & 0x400:
        raise ValueError('Expected an ordinary bundle directory without reparse points')
    records = {}
    paths = set()
    total = 0
    for path in sorted(bundle.rglob('*')):
        info = path.lstat()
        if path.is_symlink() or getattr(info, 'st_file_attributes', 0) & 0x400:
            raise ValueError('Bundle contains a symlink or reparse point')
        relative = path.relative_to(bundle).as_posix()
        key = windows_path(relative)
        if key in paths:
            raise ValueError('Bundle has a Windows file/directory path collision')
        paths.add(key)
        if not path.is_file():
            if not path.is_dir():
                raise ValueError('Unexpected special bundle file')
            continue
        if info.st_size > MAX_FILE or len(records) >= MAX_ENTRIES:
            raise ValueError('Excessive bundle file count/size')
        total += info.st_size
        if total > MAX_TOTAL or key in records:
            raise ValueError('Excessive bundle size or Windows path collision')
        suffix = path.suffix.casefold()
        if key.startswith(DRIVER_FOLDER):
            if DRIVER_FILES.get(key) != file_hashes(path)['sha256']:
                raise ValueError(f'Not a pinned display driver file: {relative}')
        elif (suffix == '.exe' and key != 'nikodesk.exe') or suffix in ('.sys', '.inf', '.cat', '.msi'):
            raise ValueError(f'Unexpected executable, service/helper or driver: {relative}')
        elif suffix == '.dll':
            PE(path.read_bytes(), dll=True)
        records[key] = {'path': relative, **file_hashes(path)}
    bundled_driver = sum(key in records for key in DRIVER_FILES)
    if bundled_driver not in ((len(DRIVER_FILES),) if require_display_driver else (0, len(DRIVER_FILES))):
        raise ValueError('The pinned display driver is missing or incomplete')
    for required in REQUIRED:
        if windows_path(required) not in records:
            raise ValueError(f'Missing bundle file: {required}')
    if not any(key.startswith('data/flutter_assets/') for key in records):
        raise ValueError('Missing Flutter assets')
    product_exe((bundle / 'NikoDesk.exe').read_bytes(), parts)
    dart_aot((bundle / 'data/app.so').read_bytes())
    if records['data/icudtl.dat']['size'] < 64:
        raise ValueError('Missing real ICU data')
    if records['nikodesk-licence.txt']['sha256'] != file_hashes(license_file)['sha256']:
        raise ValueError('Bundled license differs from source LICENCE')
    for notice in CPAL_NOTICES:
        if records[windows_path(notice)]['sha256'] != file_hashes(CPAL_SOURCE / Path(notice).name)['sha256']:
            raise ValueError('Bundled CPAL notices differ from fixed source')
    text = (bundle / 'NikoDesk-source.txt').read_text(encoding='utf-8')
    expected = '.'.join(map(str, parts[:3])) + '+' + str(parts[3])
    match = re.fullmatch(r'Product ([^;\n]+); upstream native/protocol ([^\n]+)\nSource ([0-9a-f]{40}); dirty=(true|false)\n?', text, re.I)
    if (not match or match[1] != expected or match[2] != native_version or
            match[3].lower() != source_revision.lower() or (match[4].lower() == 'true') != source_dirty):
        raise ValueError('Bundled product/source revision/dirty record does not match the expected build')
    return records


def inspect_zip(path, records):
    with zipfile.ZipFile(path) as archive:
        if len(archive.infolist()) > MAX_ENTRIES:
            raise ValueError('Excessive ZIP entries')
        seen, files = set(), set()
        for entry in archive.infolist():
            key = windows_path(entry.filename.rstrip('/') if entry.is_dir() else entry.filename)
            if key in seen or entry.flag_bits & 1 or stat.S_ISLNK(entry.external_attr >> 16):
                raise ValueError('Duplicate/unsafe/encrypted ZIP entry')
            seen.add(key)
            if entry.is_dir():
                if not any(x.startswith(key + '/') for x in records):
                    raise ValueError('Unexpected ZIP directory')
                continue
            if key not in records or entry.file_size != records[key]['size']:
                raise ValueError('ZIP does not contain the complete inspected bundle')
            digest = hashlib.sha256()
            with archive.open(entry) as stream:
                for chunk in iter(lambda: stream.read(1024 * 1024), b''):
                    digest.update(chunk)
            if digest.hexdigest() != records[key]['sha256']:
                raise ValueError(f'ZIP payload differs from inspected bundle: {entry.filename}')
            files.add(key)
        if files != set(records):
            raise ValueError('ZIP is missing inspected bundle files')


def inspect_payload(blob, records):
    try:
        import brotli
    except ImportError as error:
        raise ValueError('Brotli 1.2.0 is required for bounded portable payload inspection') from error
    if brotli.__version__ != '1.2.0':
        raise ValueError('Use pinned Brotli 1.2.0 for bounded decoding')
    if checked(blob, 0, 8) != b'rustdesk':
        raise ValueError('Invalid portable blob header')
    expected = set(records) - {'experimental.txt'}
    seen, at = set(), 8
    while checked(blob, at, 8) != b'rustdesk':
        length, = unpack('>I', blob, at)
        at += 4
        if not 1 <= length <= 1024:
            raise ValueError('Invalid portable path length')
        key = windows_path(checked(blob, at, length).decode('utf-8'), portable=True)
        at += length
        if key in seen or key not in expected:
            raise ValueError('Duplicate/unexpected portable payload entry')
        seen.add(key)
        length, = unpack('>I', blob, at)
        at += 4
        compressed = checked(blob, at, length)
        at += length
        md5_record = checked(blob, at, 32)
        at += 32
        decoder, sha, md5, count, offset = brotli.Decompressor(), hashlib.sha256(), hashlib.md5(), 0, 0
        while True:
            chunk = compressed[offset:offset + 65536] if (offset < len(compressed) and decoder.can_accept_more_data()) else b''
            offset += len(chunk)
            try:
                output = decoder.process(chunk, output_buffer_limit=65536)
            except brotli.error as error:
                raise ValueError('Invalid portable Brotli stream') from error
            count += len(output)
            if count > records[key]['size']:
                raise ValueError('Portable decompression exceeds inspected file size')
            sha.update(output)
            md5.update(output)
            # The decoder can hold a full output buffer past the last input chunk,
            # and can_accept_more_data() only reports its input window, so keep
            # draining on empty input. An empty chunk producing no output can then
            # only mean the stream ended or is truncated.
            if not chunk and not output:
                if decoder.is_finished() and offset >= len(compressed):
                    break
                raise ValueError(f'Truncated portable Brotli stream: {key}')
        if (not decoder.is_finished() or count != records[key]['size'] or
                sha.hexdigest() != records[key]['sha256'] or md5.hexdigest().encode() != md5_record):
            raise ValueError(f'Portable payload differs from inspected bundle: {key}')
    executable = checked(blob, at + 8, len(blob) - at - 8).decode('utf-8')
    if windows_path(executable, portable=True) != 'nikodesk.exe' or seen != expected:
        raise ValueError('Portable executable/content is not the complete NikoDesk bundle')


def verify_package(bundle, portable, archive, blob_path, version_name, build_number,
                   license_file, source_revision, source_dirty, native_version,
                   require_display_driver=False):
    parts = version_parts(version_name, build_number)
    if not re.fullmatch(r'[0-9a-fA-F]{40}', source_revision):
        raise ValueError('Expected a complete source commit SHA')
    records = inspect_bundle(bundle, parts, license_file, source_revision, source_dirty, native_version,
                             require_display_driver)
    inspect_zip(archive, records)
    if portable.stat().st_size > MAX_FILE or blob_path.stat().st_size > MAX_FILE:
        raise ValueError('Excessive portable image/blob size')
    pe = product_exe(portable.read_bytes(), parts)
    if any(key[0] == 10 and key[1] == 'RDPKG' for key in pe.resources):
        raise ValueError('NikoDesk portable package must not override content with RDPKG')
    blob = blob_path.read_bytes()
    inspect_payload(blob, records)
    matches = sum(pe.data[x['raw']:x['raw'] + x['size']].count(blob)
                  for x in pe.sections if x['flags'] & 0x40000000 and x['flags'] & 0x40)
    if matches != 1:
        raise ValueError('Inspected portable blob is not embedded exactly once in initialized readable PE data')
    return {'product_version': version_name, 'build_number': int(build_number),
            'upstream_native_protocol_version': native_version,
            'source_commit': source_revision, 'source_dirty': source_dirty,
            'pe_x64_verified': True, 'pe_resources_verified': True,
            'ordinary_user_manifest_verified': True, 'dart_aot_x64_verified': True,
            'bundle_zip_verified': True, 'portable_embedded_payload_verified': True,
            'bundle_files': records, 'portable_sha256': file_hashes(portable)['sha256'],
            'zip_sha256': file_hashes(archive)['sha256'], 'blob_sha256': hashlib.sha256(blob).hexdigest(),
            'client_launch_verified': False, 'remote_session_verified': False,
            'unattended_verified': False, 'production_signature_verified': False}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bundle', type=Path, required=True)
    parser.add_argument('--portable', type=Path, required=True)
    parser.add_argument('--zip', type=Path, required=True)
    parser.add_argument('--blob', type=Path, required=True)
    parser.add_argument('--version-name', required=True)
    parser.add_argument('--build-number', required=True, type=int)
    parser.add_argument('--license-file', type=Path, required=True)
    parser.add_argument('--source-revision', required=True)
    parser.add_argument('--source-dirty', choices=('true', 'false'), required=True)
    parser.add_argument('--native-protocol-version', required=True)
    parser.add_argument('--require-display-driver', action='store_true')
    parser.add_argument('--report-output', type=Path, required=True)
    args = parser.parse_args()
    try:
        result = verify_package(args.bundle, args.portable, args.zip, args.blob,
                                args.version_name, args.build_number, args.license_file,
                                args.source_revision, args.source_dirty == 'true', args.native_protocol_version,
                                args.require_display_driver)
        args.report_output.write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
    except (ValueError, OSError, UnicodeError, ET.ParseError, zipfile.BadZipFile) as error:
        parser.exit(1, f'Windows package verification failed: {error}\n')
    print(f'Windows package contents verified: {len(result["bundle_files"])} files; client launch/session remain unverified.')
