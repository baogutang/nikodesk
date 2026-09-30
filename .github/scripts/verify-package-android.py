#!/usr/bin/env python3
"""Inspect the final APK's merged manifest and native libraries without installing it."""

import argparse
import json
import os
import shutil
import struct
import subprocess
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path


ANDROID = '{http://schemas.android.com/apk/res/android}'
FORBIDDEN_PERMISSIONS = {
    'android.permission.POST_NOTIFICATIONS',
    'android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS',
    'android.permission.FOREGROUND_SERVICE',
    'android.permission.FOREGROUND_SERVICE_MEDIA_PROJECTION',
    'android.permission.FOREGROUND_SERVICE_MICROPHONE',
    'android.permission.FOREGROUND_SERVICE_SPECIAL_USE',
    'android.permission.RECORD_AUDIO',
    'android.permission.RECEIVE_BOOT_COMPLETED',
    'android.permission.SYSTEM_ALERT_WINDOW',
    'android.permission.BIND_ACCESSIBILITY_SERVICE',
}


def verify_manifest(text, application_id, version_name=None, version_code=None):
    manifest = ET.fromstring(text)
    if manifest.get('package') != application_id:
        raise ValueError(f'Unexpected application ID: {manifest.get("package")}')
    if version_name is not None and manifest.get(ANDROID + 'versionName') != version_name:
        raise ValueError('APK product version does not match the build version')
    if version_code is not None and manifest.get(ANDROID + 'versionCode') != str(version_code):
        raise ValueError('APK versionCode does not match the build number')
    permissions = {node.get(ANDROID + 'name') for node in manifest.findall('uses-permission')}
    if forbidden := permissions & FORBIDDEN_PERMISSIONS:
        raise ValueError(f'Controller APK contains receiving permissions: {sorted(forbidden)}')
    for node in manifest.findall('.//service') + manifest.findall('.//receiver'):
        name = node.get(ANDROID + 'name', '').rsplit('.', 1)[-1]
        if name in {'InputService', 'MainService', 'FloatingWindowService', 'BootReceiver'}:
            raise ValueError(f'Controller APK contains receiving component: {name}')
    schemes = {node.get(ANDROID + 'scheme') for node in manifest.findall('.//intent-filter/data')
               if node.get(ANDROID + 'scheme')}
    if schemes != {'nikodesk'}:
        raise ValueError(f'Unexpected application schemes: {sorted(schemes)}')
    launcher = any(
        any(action.get(ANDROID + 'name') == 'android.intent.action.MAIN'
            for action in intent.findall('action')) and
        any(category.get(ANDROID + 'name') == 'android.intent.category.LAUNCHER'
            for category in intent.findall('category'))
        for intent in manifest.findall('.//activity/intent-filter')
    )
    if not launcher:
        raise ValueError('Controller APK has no launcher activity')
    return {'application_id': application_id, 'schemes': sorted(schemes),
            'version_name': manifest.get(ANDROID + 'versionName'),
            'version_code': manifest.get(ANDROID + 'versionCode'),
            'controller_manifest_verified': True}


def verify_elf(data, name):
    if (len(data) < 64 or data[:6] != b'\x7fELF\x02\x01' or
            struct.unpack_from('<H', data, 16)[0] != 3 or
            struct.unpack_from('<H', data, 18)[0] != 183):
        raise ValueError(f'{name} is not a real ARM64 shared ELF library')
    offset = struct.unpack_from('<Q', data, 32)[0]
    size, count = struct.unpack_from('<HH', data, 54)
    if size != 56 or count == 0 or offset + size * count > len(data):
        raise ValueError(f'{name} has an invalid ELF program header table')
    loads = []
    for index in range(count):
        header = struct.unpack_from('<IIQQQQQQ', data, offset + size * index)
        kind, _, file_offset, address, _, file_size, memory_size, alignment = header
        if kind != 1:
            continue
        if (alignment < 16384 or alignment & (alignment - 1) or
                file_offset % alignment != address % alignment or
                memory_size < file_size or file_offset + file_size > len(data)):
            raise ValueError(f'{name} has a LOAD segment incompatible with 16 KB pages')
        loads.append(alignment)
    if not loads:
        raise ValueError(f'{name} has no ELF LOAD segments')
    return {'elf_load_alignments': loads, 'elf_16kb_verified': True}


def verify_zip_library_alignment(apk_stream, entry):
    apk_stream.seek(entry.header_offset)
    header = apk_stream.read(30)
    if len(header) != 30 or header[:4] != b'PK\x03\x04':
        raise ValueError(f'Invalid local ZIP header: {entry.filename}')
    filename_length, extra_length = struct.unpack_from('<HH', header, 26)
    data_offset = entry.header_offset + 30 + filename_length + extra_length
    if entry.compress_type == zipfile.ZIP_STORED and data_offset % 16384:
        raise ValueError(f'{entry.filename} is not ZIP-aligned for 16 KB mmap')
    if entry.compress_type not in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED):
        raise ValueError(f'Unsupported library ZIP compression: {entry.filename}')
    return {'zip_compressed': entry.compress_type != zipfile.ZIP_STORED,
            'zip_data_offset': data_offset, 'zip_16kb_verified': True}


def signing_certificate(apk):
    sdk = os.environ.get('ANDROID_HOME') or os.environ.get('ANDROID_SDK_ROOT')
    candidates = sorted((Path(sdk) / 'build-tools').glob('*/apksigner')) if sdk else []
    executable = shutil.which('apksigner') or (str(candidates[-1]) if candidates else None)
    if not executable:
        raise ValueError('Android SDK apksigner is required for signature verification')
    output = subprocess.run([executable, 'verify', '--verbose', '--print-certs', str(apk)],
                            check=True, capture_output=True, text=True, timeout=120).stdout
    certificates = [line.split(':', 1)[1].strip().lower() for line in output.splitlines()
                    if 'certificate SHA-256 digest:' in line and line.startswith('Signer #')]
    if len(certificates) != 1:
        raise ValueError('APK must have exactly one verified signing certificate')
    return certificates[0]


def analyzer_path():
    if found := shutil.which('apkanalyzer'):
        return found
    sdk = os.environ.get('ANDROID_HOME') or os.environ.get('ANDROID_SDK_ROOT')
    if sdk:
        preferred = Path(sdk) / 'cmdline-tools/latest/bin/apkanalyzer'
        if preferred.is_file():
            return str(preferred)
        candidates = sorted((Path(sdk) / 'cmdline-tools').glob('*/bin/apkanalyzer'))
        if candidates:
            return str(candidates[-1])
    raise ValueError('Android SDK apkanalyzer is required to inspect the final merged APK manifest')


def verify_apk(apk, application_id, manifest_output=None, version_name=None,
               version_code=None, certificate_sha256=None, unsigned=False, report_output=None):
    text = subprocess.run([analyzer_path(), 'manifest', 'print', str(apk)],
                          check=True, capture_output=True, text=True, timeout=120).stdout
    result = verify_manifest(text, application_id, version_name, version_code)
    application = ET.fromstring(text).find('application')
    extract_native = application is not None and application.get(ANDROID + 'extractNativeLibs') != 'false'
    libraries = ('librustdesk.so', 'libc++_shared.so', 'libflutter.so', 'libapp.so')
    with zipfile.ZipFile(apk) as archive:
        if corrupt := archive.testzip():
            raise ValueError(f'Corrupt APK entry: {corrupt}')
        names = archive.namelist()
        if len(names) != len(set(names)):
            raise ValueError('APK has duplicate ZIP entries')
        for library in libraries:
            if 'lib/arm64-v8a/' + library not in names:
                raise ValueError(f'Missing native library: {library}')
        native = {}
        with apk.open('rb') as apk_stream:
            for entry in archive.infolist():
                if entry.filename.startswith('lib/') and entry.filename.endswith('.so'):
                    if not entry.filename.startswith('lib/arm64-v8a/') or entry.file_size > 256 * 1024 * 1024:
                        raise ValueError(f'Unexpected native APK entry: {entry.filename}')
                    native[entry.filename] = {
                        **verify_elf(archive.read(entry), entry.filename),
                        **verify_zip_library_alignment(apk_stream, entry),
                    }
                    if native[entry.filename]['zip_compressed'] and not extract_native:
                        raise ValueError('Compressed native libraries require extractNativeLibs=true')
    actual_certificate = None if unsigned else signing_certificate(apk)
    if certificate_sha256 is not None and actual_certificate != certificate_sha256.lower().replace(':', ''):
        raise ValueError('APK signing identity changed; refusing an incompatible upgrade')
    if manifest_output:
        manifest_output.write_text(text)
    result.update({'native_arm64_libraries_verified': list(libraries), 'native_libraries': native,
                   'extract_native_libraries': extract_native,
                   'elf_16kb_verified': True, 'zip_16kb_verified': True,
                   'signature_verified': not unsigned, 'certificate_sha256': actual_certificate,
                   'expected_signing_identity_verified': certificate_sha256 is not None,
                   'launch_verified': False, 'remote_session_verified': False,
                   'stable_release_signing_verified': False})
    if report_output:
        report_output.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('apk', type=Path)
    parser.add_argument('--application-id', required=True)
    parser.add_argument('--manifest-output', type=Path)
    parser.add_argument('--version-name')
    parser.add_argument('--version-code', type=int)
    parser.add_argument('--certificate-sha256')
    parser.add_argument('--unsigned', action='store_true', help='Structure-only CI inspection; not installable/upgradeable evidence')
    parser.add_argument('--report-output', type=Path)
    args = parser.parse_args()
    verify_apk(args.apk, args.application_id, args.manifest_output, args.version_name,
               args.version_code, args.certificate_sha256, args.unsigned, args.report_output)
