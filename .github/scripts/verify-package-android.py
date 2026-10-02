#!/usr/bin/env python3
"""Inspect the final APK's merged manifest and native libraries without installing it."""

import argparse
import hashlib
import json
import os
import re
import shutil
import struct
import subprocess
import xml.etree.ElementTree as ET
import zipfile
import zlib
from pathlib import Path


ANDROID = '{http://schemas.android.com/apk/res/android}'
FORBIDDEN_PERMISSIONS = {
    'android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS',
    'android.permission.FOREGROUND_SERVICE_MEDIA_PROJECTION',
    'android.permission.FOREGROUND_SERVICE_SPECIAL_USE',
    'android.permission.RECEIVE_BOOT_COMPLETED',
    'android.permission.SYSTEM_ALERT_WINDOW',
    'android.permission.BIND_ACCESSIBILITY_SERVICE',
}

OWNED_VOICE_SERVICE = 'io.nikodesk.android.voice.NikoVoiceService'
OWNED_VOICE_PERMISSIONS = {
    'android.permission.RECORD_AUDIO', 'android.permission.POST_NOTIFICATIONS',
    'android.permission.FOREGROUND_SERVICE', 'android.permission.FOREGROUND_SERVICE_MICROPHONE',
}

# Frozen actual JVM descriptors checked against the production Kotlin/JNI SDK
# compilation. Only the classes invoked across JNI and the manifest Service
# are constrained; private Kotlin implementation layouts are not a contract.
VOICE_PACKAGE = 'Lio/nikodesk/android/voice/'
OWNED_VOICE_METHODS = {
    'NikoVoiceBridge': {
        'nativeInitialize': '()Z',
        'nativeCancelled': '(Ljava/lang/String;JJI)V',
        'authorizationStatus': '()I',
        'snapshotJson': '()Ljava/lang/String;',
        'prepare': '(JLjava/lang/String;Ljava/lang/String;Ljava/lang/String;[BJJLjava/lang/String;)Lio/nikodesk/android/voice/NikoVoicePreparation;',
        'retryRetainedNativeStop': '([BJJ)I',
        'available': '()Z',
        'normalUserUid': '()I',
        'authorizationStatusCode': '()I',
        'beginPermissionJob': '()Lio/nikodesk/android/voice/NikoVoicePermissionJob;',
        'beginApprovalJob': '(JLjava/lang/String;Ljava/lang/String;Ljava/lang/String;[BJJZ)Lio/nikodesk/android/voice/NikoVoiceApprovalJob;',
    },
    'NikoVoicePreparation': {'code': '()I', 'session': '()Lio/nikodesk/android/voice/NikoVoiceSession;'},
    'NikoVoiceSession': {
        'permissionStatus': '()I', 'pollStatus': '()I', 'stopStatus': '()I',
        'readPcm': '([F)I', 'writePcm': '([FII)I',
    },
    'NikoVoicePermissionJob': {'pollCode': '()I', 'cancel': '()V'},
    'NikoVoiceApprovalJob': {'pollProof': '()Ljava/lang/String;', 'cancel': '()V'},
}
OWNED_VOICE_JNI = tuple('Java_io_nikodesk_android_voice_NikoVoiceBridge_' + method
                        for method in ('nativeInitialize', 'nativeCancelled'))
MAX_DEX_BYTES = 128 * 1024 * 1024
MAX_DEX_TOTAL_BYTES = 256 * 1024 * 1024
MAX_DEX_ITEMS = 2_000_000


class DexReader:
    """Bounded DEX class/method metadata reader; never executes bytecode.

    This reads defined class_data, not string occurrences or method references.
    DEX 041 containers are rejected until their different offsets are supported.
    It is a static ABI gate, not a Dalvik bytecode verifier or runtime proof.
    Format: https://source.android.com/docs/core/runtime/dex-format
    """
    def __init__(self, data):
        self.data = data
        if (len(data) < 112 or len(data) > MAX_DEX_BYTES
                or not re.fullmatch(rb'dex\n0(?:35|37|38|39|40)\x00', data[:8])):
            raise ValueError('Unsupported or invalid final APK DEX header')
        if (self.u32(32) != len(data) or self.u32(36) != 112
                or self.u32(40) != 0x12345678
                or self.u32(8) != zlib.adler32(data[12:]) & 0xffffffff
                or data[12:32] != hashlib.sha1(data[32:]).digest()):
            raise ValueError('Invalid final APK DEX size/checksum/signature/endian metadata')
        self.data_size, self.data_off = self.u32(104), self.u32(108)
        if self.data_off < 112 or self.data_off % 4 or self.data_off + self.data_size != len(data):
            raise ValueError('Invalid final APK DEX data bounds')
        self.tables = {}
        spans = []
        for name, offset, stride in [('strings', 56, 4), ('types', 64, 4), ('protos', 72, 12),
                                     ('fields', 80, 8), ('methods', 88, 8), ('classes', 96, 32)]:
            count, start = self.u32(offset), self.u32(offset + 4)
            maximum = 65535 if name in {'types', 'protos', 'fields', 'methods'} else MAX_DEX_ITEMS
            if (count > maximum or (not count and start)
                    or count and (start < 112 or start % 4 or start + count * stride > self.data_off)):
                raise ValueError('Invalid final APK DEX table bounds')
            self.tables[name] = count, start, stride
            if count:
                spans.append((start, start + count * stride))
        spans.sort()
        if any(a[1] > b[0] for a, b in zip(spans, spans[1:])):
            raise ValueError('Overlapping final APK DEX tables')
        self.strings = {}
        self.types = {}

    def u32(self, offset):
        if offset < 0 or offset + 4 > len(self.data):
            raise ValueError('Truncated final APK DEX metadata')
        return struct.unpack_from('<I', self.data, offset)[0]

    def data_offset(self, offset, size=1):
        if offset < self.data_off or size < 0 or offset + size > len(self.data):
            raise ValueError('Out-of-range final APK DEX data offset')
        return offset

    def uleb(self, offset):
        value = 0
        for shift in range(0, 35, 7):
            self.data_offset(offset)
            byte = self.data[offset]
            offset += 1
            if shift == 28 and byte > 15:
                raise ValueError('Overflowing final APK DEX ULEB128')
            value |= (byte & 127) << shift
            if byte < 128:
                return value, offset
        raise ValueError('Unterminated final APK DEX ULEB128')

    def table_offset(self, name, index):
        count, start, stride = self.tables[name]
        if index < 0 or index >= count:
            raise ValueError('Out-of-range final APK DEX table index')
        return start + index * stride

    def string(self, index):
        if index not in self.strings:
            offset = self.data_offset(self.u32(self.table_offset('strings', index)))
            length, offset = self.uleb(offset)
            end = self.data.find(b'\0', offset, min(len(self.data), offset + 262144))
            if end < 0 or length > 131072:
                raise ValueError('Unbounded final APK DEX string')
            raw = self.data[offset:end]
            if any(byte >= 0xf0 for byte in raw):
                raise ValueError('Invalid final APK DEX modified UTF-8')
            try:
                text = raw.replace(b'\xc0\x80', b'\0').decode('utf-8', 'surrogatepass')
            except UnicodeDecodeError as error:
                raise ValueError('Invalid final APK DEX modified UTF-8') from error
            if len(text.encode('utf-16-le', 'surrogatepass')) // 2 != length:
                raise ValueError('Invalid final APK DEX string length')
            self.strings[index] = text
        return self.strings[index]

    def type(self, index):
        if index not in self.types:
            value = self.string(self.u32(self.table_offset('types', index)))
            if not value or '\0' in value or len(value) > 4096:
                raise ValueError('Invalid final APK DEX type descriptor')
            self.types[index] = value
        return self.types[index]

    def prototype(self, index):
        offset = self.table_offset('protos', index)
        result = self.type(self.u32(offset + 4))
        params = self.u32(offset + 8)
        types = []
        if params:
            self.data_offset(params, 4)
            count = self.u32(params)
            if count > 255 or params % 4:
                raise ValueError('Invalid final APK DEX parameter list')
            self.data_offset(params + 4, count * 2)
            types = [self.type(struct.unpack_from('<H', self.data, params + 4 + i * 2)[0])
                     for i in range(count)]
            if 'V' in types:
                raise ValueError('Invalid final APK DEX void parameter')
        return '(' + ''.join(types) + ')' + result

    def defined_classes(self):
        result = {}
        for i in range(self.tables['classes'][0]):
            offset = self.table_offset('classes', i)
            class_idx, flags, superclass = struct.unpack_from('<III', self.data, offset)
            name = self.type(class_idx)
            if not name.startswith('L') or not name.endswith(';') or name in result:
                raise ValueError('Invalid or duplicate final APK DEX class definition')
            parent = None if superclass == 0xffffffff else self.type(superclass)
            class_data = self.u32(offset + 24)
            methods = {}
            if class_data:
                pos = self.data_offset(class_data)
                counts = []
                for _ in range(4):
                    value, pos = self.uleb(pos)
                    if value > MAX_DEX_ITEMS:
                        raise ValueError('Unbounded final APK DEX class data')
                    counts.append(value)
                seen_fields = set()
                for count in counts[:2]:
                    if count > self.tables['fields'][0]:
                        raise ValueError('Unbounded final APK DEX encoded fields')
                    index = 0
                    for n in range(count):
                        diff, pos = self.uleb(pos)
                        _, pos = self.uleb(pos)
                        if n and not diff:
                            raise ValueError('Duplicate final APK DEX field entry')
                        index += diff
                        field = self.table_offset('fields', index)
                        if index in seen_fields or struct.unpack_from('<H', self.data, field)[0] != class_idx:
                            raise ValueError('Duplicate or misowned final APK DEX field definition')
                        seen_fields.add(index)
                seen = set()
                for count in counts[2:]:
                    if count > self.tables['methods'][0]:
                        raise ValueError('Unbounded final APK DEX encoded methods')
                    index = 0
                    for n in range(count):
                        diff, pos = self.uleb(pos)
                        access, pos = self.uleb(pos)
                        code, pos = self.uleb(pos)
                        if n and not diff:
                            raise ValueError('Duplicate final APK DEX method entry')
                        index += diff
                        method = self.table_offset('methods', index)
                        declaring, proto, string = struct.unpack_from('<HHI', self.data, method)
                        key = (self.string(string), self.prototype(proto))
                        if declaring != class_idx or index in seen or key in methods:
                            raise ValueError('Duplicate or misowned final APK DEX method definition')
                        seen.add(index)
                        if code:
                            self.data_offset(code, 16)
                            if code % 4 or access & (0x100 | 0x400):
                                raise ValueError('Invalid final APK DEX method code ownership')
                            code_units = self.u32(code + 12)
                            self.data_offset(code + 16, 2 * code_units)
                        elif not access & (0x100 | 0x400):
                            raise ValueError('Final APK DEX method has no actual code')
                        methods[key] = {'access': access, 'code': code,
                                        'code_units': code_units if code else 0}
            result[name] = {'access': flags, 'superclass': parent, 'methods': methods}
        return result


def verify_voice_dex(archive):
    entries = [entry for entry in archive.infolist() if entry.filename.endswith('.dex')]
    if not entries or len(entries) > 256:
        raise ValueError('Missing or excessive final APK DEX entries')
    classes, size, names = {}, 0, []
    for entry in entries:
        if not re.fullmatch(r'classes(?:[2-9]|[1-9][0-9]+)?\.dex', entry.filename):
            raise ValueError('Unexpected final APK DEX entry name')
        size += entry.file_size
        if entry.file_size > MAX_DEX_BYTES or size > MAX_DEX_TOTAL_BYTES:
            raise ValueError('Unbounded final APK DEX payload')
        defined = DexReader(archive.read(entry)).defined_classes()
        if classes.keys() & defined.keys():
            raise ValueError('Duplicate final APK class across DEX files')
        classes.update(defined)
        names.append(entry.filename)
    required = [VOICE_PACKAGE + name + ';' for name in (*OWNED_VOICE_METHODS, 'NikoVoiceService')]
    for name in required:
        if name not in classes or classes[name]['access'] & (0x200 | 0x400):
            raise ValueError('Missing concrete owned voice class in final APK DEX')
    service = classes[VOICE_PACKAGE + 'NikoVoiceService;']
    constructor = service['methods'].get(('<init>', '()V'))
    if (service['superclass'] != 'Landroid/app/Service;' or not service['access'] & 1
            or constructor is None or not constructor['access'] & 1
            or constructor['access'] & (8 | 0x100 | 0x400) or not constructor['code_units']):
        raise ValueError('Owned voice service is not an actual Android Service class')
    for name, methods in OWNED_VOICE_METHODS.items():
        for method, descriptor in methods.items():
            record = classes[VOICE_PACKAGE + name + ';']['methods'].get((method, descriptor))
            native = name == 'NikoVoiceBridge' and method in ('nativeInitialize', 'nativeCancelled')
            if (record is None or bool(record['access'] & 8) != (name == 'NikoVoiceBridge')
                    or bool(record['access'] & 0x100) != native or record['access'] & 0x400
                    or not native and (not record['access'] & 1 or not record['code_units'])):
                raise ValueError('Missing or incompatible owned voice JNI method in final APK DEX')
    return {'owned_voice_dex_files': sorted(names), 'owned_voice_defined_classes': required,
            'owned_voice_jvm_descriptors_verified': sum(map(len, OWNED_VOICE_METHODS.values())),
            'owned_voice_dex_abi_verified': True}


def verify_voice_jni_exports(data):
    """Require defined, visible, global function dynsyms, not symbol-like strings.

    Symbol layout/binding: https://gabi.xinuos.com/elf/05-symtab.html
    """
    verify_elf(data, 'librustdesk.so')
    offset = struct.unpack_from('<Q', data, 40)[0]
    stride, count = struct.unpack_from('<HH', data, 58)
    if stride != 64 or not count or offset < 64 or offset + stride * count > len(data):
        raise ValueError('Final APK Rust core lacks a valid ELF dynamic symbol section table')
    sections = [struct.unpack_from('<IIQQQQIIQQ', data, offset + i * stride) for i in range(count)]
    ph_offset = struct.unpack_from('<Q', data, 32)[0]
    ph_count = struct.unpack_from('<H', data, 56)[0]
    programs = [struct.unpack_from('<IIQQQQQQ', data, ph_offset + i * 56) for i in range(ph_count)]
    found = {}
    expected = {name.encode() for name in OWNED_VOICE_JNI}
    for section in sections:
        _, kind, _, _, start, size, link, _, _, entry_size = section
        if kind != 11:
            continue
        if entry_size != 24 or size % 24 or start + size > len(data) or link >= count:
            raise ValueError('Invalid final APK Rust core dynamic symbol bounds')
        strings = sections[link]
        if strings[1] != 3 or strings[4] + strings[5] > len(data):
            raise ValueError('Invalid final APK Rust core dynamic symbol string table')
        text = data[strings[4]:strings[4] + strings[5]]
        for pos in range(start, start + size, 24):
            name, info, other, index, value, length = struct.unpack_from('<IBBHQQ', data, pos)
            if name >= len(text):
                raise ValueError('Invalid final APK Rust core dynamic symbol name')
            end = text.find(b'\0', name)
            if end < 0:
                raise ValueError('Unterminated final APK Rust core dynamic symbol name')
            symbol = bytes(text[name:end])
            if symbol not in expected:
                continue
            decoded = symbol.decode('ascii')
            if decoded in found:
                raise ValueError('Duplicate final APK owned voice JNI export')
            if (info != 0x12 or other or not 0 < index < count
                    or sections[index][1] != 1 or not sections[index][2] & 4 or not length
                    or sections[index][4] + sections[index][5] > len(data)
                    or value < sections[index][3]
                    or value + length > sections[index][3] + sections[index][5]
                    or not any(p[0] == 1 and p[1] & 1 and p[3] <= value
                               and value + length <= p[3] + p[5] for p in programs)):
                raise ValueError('Owned voice JNI entry is not an exported defined function')
            found[decoded] = True
    if set(found) != set(OWNED_VOICE_JNI):
        raise ValueError('Missing owned voice JNI exports from final APK Rust core')
    return {'owned_voice_jni_exports': sorted(found), 'owned_voice_native_abi_verified': True}


def microphone_service_type(value):
    # apkanalyzer prints binary XML flag values numerically. The SDK's exact
    # FOREGROUND_SERVICE_TYPE_MICROPHONE is 128 (0x80); combined/unknown bits
    # are forbidden just as the source XML "microphone|..." form is forbidden.
    if value == 'microphone':
        return True
    if not isinstance(value, str) or not re.fullmatch(r'(?:0x[0-9a-fA-F]{1,8}|[0-9]{1,10})', value):
        return False
    return int(value, 16 if value.startswith('0x') else 10) == 128


def verify_manifest(text, application_id, version_name=None, version_code=None, require_owned_voice=False):
    manifest = ET.fromstring(text)
    if require_owned_voice and application_id not in {'io.nikodesk.android', 'io.nikodesk.android.dev'}:
        raise ValueError('Owned voice APK must use its isolated NikoDesk application ID')
    if manifest.get('package') != application_id:
        raise ValueError(f'Unexpected application ID: {manifest.get("package")}')
    if version_name is not None and manifest.get(ANDROID + 'versionName') != version_name:
        raise ValueError('APK product version does not match the build version')
    if version_code is not None and manifest.get(ANDROID + 'versionCode') != str(version_code):
        raise ValueError('APK versionCode does not match the build number')
    permission_nodes = manifest.findall('uses-permission') + manifest.findall('uses-permission-sdk-23')
    permissions = {node.get(ANDROID + 'name') for node in permission_nodes}
    if any(node.get(ANDROID + 'permission') == 'android.permission.BIND_ACCESSIBILITY_SERVICE'
           or node.get(ANDROID + 'name', '').rsplit('.', 1)[-1] == 'PermissionRequestTransparentActivity'
           for node in manifest.findall('./application/*')):
        raise ValueError('Controller APK contains a receiving/accessibility permission component')
    if forbidden := permissions & FORBIDDEN_PERMISSIONS:
        raise ValueError(f'Controller APK contains receiving permissions: {sorted(forbidden)}')
    owned_services = [node for node in manifest.findall('./application/service')
                      if node.get(ANDROID + 'name') == OWNED_VOICE_SERVICE]
    owned_permissions = permissions & OWNED_VOICE_PERMISSIONS
    owned_voice = bool(owned_permissions or owned_services)
    if require_owned_voice and not owned_voice:
        raise ValueError('Missing explicit owned voice metadata')
    if owned_voice:
        if len(owned_services) != 1 or owned_permissions != OWNED_VOICE_PERMISSIONS:
            raise ValueError('Owned voice requires its exact service and permission allowlist')
        service = owned_services[0]
        if (service.get(ANDROID + 'exported') != 'false' or service.get(ANDROID + 'enabled') != 'true'
                or not microphone_service_type(service.get(ANDROID + 'foregroundServiceType'))
                or service.findall('intent-filter') or service.findall('meta-data')
                or any(service.get(ANDROID + name) is not None
                       for name in ('permission', 'process', 'directBootAware', 'isolatedProcess'))):
            raise ValueError('Owned voice service has unsafe lifecycle/export/foreground metadata')
        if any(node.get(ANDROID + 'maxSdkVersion') is not None
               for node in permission_nodes if node.get(ANDROID + 'name') in OWNED_VOICE_PERMISSIONS):
            raise ValueError('Owned voice permissions must remain available on Android 16')
    for service in manifest.findall('./application/service'):
        if service.get(ANDROID + 'name') != OWNED_VOICE_SERVICE and service.get(ANDROID + 'foregroundServiceType'):
            raise ValueError('Unapproved foreground service in controller APK')
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
            'controller_manifest_verified': True, 'owned_voice_metadata_verified': owned_voice}


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


SIGNER_CERTIFICATE_DIGEST = re.compile(
    r'^(?P<label>[^:]*igner[^:]*)[:\s]+certificate SHA-256 digest:\s*(?P<digest>[0-9a-fA-F:]+)\s*$')


def signing_certificate(apk):
    sdk = os.environ.get('ANDROID_HOME') or os.environ.get('ANDROID_SDK_ROOT')
    candidates = sorted((Path(sdk) / 'build-tools').glob('*/apksigner')) if sdk else []
    executable = shutil.which('apksigner') or (str(candidates[-1]) if candidates else None)
    if not executable:
        raise ValueError('Android SDK apksigner is required for signature verification')
    output = subprocess.run([executable, 'verify', '--verbose', '--print-certs', str(apk)],
                            check=True, capture_output=True, text=True, timeout=120).stdout
    # build-tools up to 36 label the block "Signer #1"; newer releases qualify it
    # by scheme ("V2 Signer:", "JAR signer", ...), and every scheme block of one
    # APK repeats the same certificate, so one distinct digest remains exactly
    # one verified signing certificate.
    digests = {match['digest'].replace(':', '').lower()
               for match in map(SIGNER_CERTIFICATE_DIGEST.match, output.splitlines()) if match}
    digests.discard('')
    if len(digests) != 1:
        raise ValueError(f'APK must have exactly one verified signing certificate '
                         f'(apksigner {executable}); verify output:\n{output.strip()[:2000]}')
    return digests.pop()


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
               version_code=None, certificate_sha256=None, unsigned=False, report_output=None, require_owned_voice=False):
    if require_owned_voice and not unsigned and (
            certificate_sha256 is None or not re.fullmatch('[0-9a-fA-F]{64}', certificate_sha256.replace(':', ''))):
        raise ValueError('Signed owned voice inspection requires the expected stable signing certificate')
    text = subprocess.run([analyzer_path(), 'manifest', 'print', str(apk)],
                          check=True, capture_output=True, text=True, timeout=120).stdout
    result = verify_manifest(text, application_id, version_name, version_code, require_owned_voice)
    application = ET.fromstring(text).find('application')
    extract_native = application is not None and application.get(ANDROID + 'extractNativeLibs') != 'false'
    libraries = ('librustdesk.so', 'libc++_shared.so', 'libflutter.so', 'libapp.so')
    voice_verification = {}
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
        if require_owned_voice:
            voice_verification = {
                **verify_voice_dex(archive),
                **verify_voice_jni_exports(archive.read('lib/arm64-v8a/librustdesk.so')),
            }
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
    result.update(voice_verification)
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
    parser.add_argument('--require-owned-voice', action='store_true', help='Require final APK owned voice metadata, defined DEX/JNI ABI and explicit stable signer (or --unsigned structure-only)')
    args = parser.parse_args()
    verify_apk(args.apk, args.application_id, args.manifest_output, args.version_name,
               args.version_code, args.certificate_sha256, args.unsigned, args.report_output, args.require_owned_voice)
