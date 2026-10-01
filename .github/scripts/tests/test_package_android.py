import importlib.util
import contextlib
import io
import hashlib
import re
import struct
import tempfile
import unittest
from unittest.mock import patch
import zipfile
import zlib
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / 'verify-package-android.py'
SPEC = importlib.util.spec_from_file_location('android_package', SCRIPT)
PACKAGE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PACKAGE)


def manifest(extra='', package='io.nikodesk.android.dev', scheme='nikodesk', launcher=True):
    launch = ('<intent-filter><action android:name="android.intent.action.MAIN" />'
              '<category android:name="android.intent.category.LAUNCHER" /></intent-filter>') if launcher else ''
    root_extra = extra if extra.startswith('<uses-permission') else ''
    app_extra = '' if root_extra else extra
    return f'''<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="{package}">
      {root_extra}<application>{app_extra}<activity android:name="com.carriez.flutter_hbb.MainActivity">
        {launch}<intent-filter><data android:scheme="{scheme}" /></intent-filter>
      </activity></application></manifest>'''


class ControllerPackageTests(unittest.TestCase):
    def test_external_url_queries_do_not_become_inbound_app_schemes(self):
        text = manifest().replace('<application>', '<queries><intent><data android:scheme="https" /></intent></queries><application>')
        PACKAGE.verify_manifest(text, 'io.nikodesk.android.dev')

    def test_rejects_version_metadata_that_cannot_identify_the_upgrade(self):
        for name, code in [('1.0.1', None), (None, 2)]:
            with self.subTest(name=name, code=code), self.assertRaises(ValueError):
                PACKAGE.verify_manifest(manifest(), 'io.nikodesk.android.dev', name, code)

    def test_accepts_isolated_controller_with_upstream_jni_namespace(self):
        result = PACKAGE.verify_manifest(manifest(), 'io.nikodesk.android.dev')
        self.assertTrue(result['controller_manifest_verified'])

    def test_rejects_upstream_application_identity_and_uri_scheme(self):
        for text in (manifest(package='com.carriez.flutter_hbb'), manifest(scheme='rustdesk')):
            with self.subTest(text=text), self.assertRaises(ValueError):
                PACKAGE.verify_manifest(text, 'io.nikodesk.android.dev')

    def test_rejects_receiving_components_and_permissions(self):
        for extra in (
            '<uses-permission android:name="android.permission.RECORD_AUDIO" />',
            '<uses-permission android:name="android.permission.FOREGROUND_SERVICE" />',
            '<service android:name="com.carriez.flutter_hbb.MainService" />',
            '<service android:name="com.carriez.flutter_hbb.InputService" />',
            '<receiver android:name="com.carriez.flutter_hbb.BootReceiver" />',
        ):
            with self.subTest(extra=extra), self.assertRaises(ValueError):
                PACKAGE.verify_manifest(manifest(extra=extra), 'io.nikodesk.android.dev')

    def test_rejects_a_manifest_merge_that_removed_the_launcher(self):
        with self.assertRaises(ValueError):
            PACKAGE.verify_manifest(manifest(launcher=False), 'io.nikodesk.android.dev')


class OwnedVoiceManifestTests(unittest.TestCase):
    def owned(self):
        permissions = ''.join(f'<uses-permission android:name="{name}" />' for name in sorted(PACKAGE.OWNED_VOICE_PERMISSIONS))
        return manifest().replace('<application>', permissions + '<application><service android:name="io.nikodesk.android.voice.NikoVoiceService" android:exported="false" android:enabled="true" android:foregroundServiceType="microphone" />')

    def test_exact_owned_service_permissions_pass_and_history_remains_valid(self):
        self.assertTrue(PACKAGE.verify_manifest(self.owned(), 'io.nikodesk.android.dev', require_owned_voice=True)['owned_voice_metadata_verified'])
        self.assertFalse(PACKAGE.verify_manifest(manifest(), 'io.nikodesk.android.dev')['owned_voice_metadata_verified'])
        with self.assertRaises(ValueError):
            PACKAGE.verify_manifest(manifest(), 'io.nikodesk.android.dev', require_owned_voice=True)

    def test_foreground_export_process_and_restart_metadata_cannot_broaden_allowlist(self):
        for text in [self.owned().replace('android:exported="false"', 'android:exported="true"'),
                     self.owned().replace('android:foregroundServiceType="microphone"', 'android:foregroundServiceType="microphone|mediaProjection"'),
                     self.owned().replace('android:enabled="true"', 'android:enabled="false"'),
                     self.owned().replace('android:enabled="true"', 'android:enabled="true" android:process=":voice"'),
                     self.owned().replace('android:enabled="true"', 'android:enabled="true" android:directBootAware="true"'),
                     self.owned().replace('android:foregroundServiceType="microphone" />', 'android:foregroundServiceType="microphone"><intent-filter><action android:name="android.intent.action.BOOT_COMPLETED" /></intent-filter></service>')]:
            with self.subTest(text=text), self.assertRaises(ValueError):
                PACKAGE.verify_manifest(text, 'io.nikodesk.android.dev')

    def test_missing_notification_or_microphone_permission_is_not_background_ready(self):
        for name in PACKAGE.OWNED_VOICE_PERMISSIONS:
            text=self.owned().replace(f'<uses-permission android:name="{name}" />', '')
            with self.subTest(name=name), self.assertRaises(ValueError): PACKAGE.verify_manifest(text, 'io.nikodesk.android.dev')

    def test_binary_xml_microphone_flag_is_equivalent_but_combined_bits_are_rejected(self):
        for value in ['microphone', '0x80', '0x00000080', '128']:
            text = self.owned().replace('foregroundServiceType="microphone"', f'foregroundServiceType="{value}"')
            with self.subTest(value=value):
                self.assertTrue(PACKAGE.verify_manifest(text, 'io.nikodesk.android.dev', require_owned_voice=True)['owned_voice_metadata_verified'])
        for value in ['', '0', '0x20', '0xa0', '160', 'microphone|mediaProjection', '0x80|0x20',
                      '-128', '+128', ' 128', '128.0', '0x100000080', '0xffffffff']:
            text = self.owned().replace('foregroundServiceType="microphone"', f'foregroundServiceType="{value}"')
            with self.subTest(value=value), self.assertRaises(ValueError):
                PACKAGE.verify_manifest(text, 'io.nikodesk.android.dev', require_owned_voice=True)

    def test_legacy_projection_service_remains_forbidden_with_owned_voice(self):
        for extra in ['<uses-permission android:name="android.permission.FOREGROUND_SERVICE_MEDIA_PROJECTION" />',
                      '<uses-permission-sdk-23 android:name="android.permission.SYSTEM_ALERT_WINDOW" />',
                      '<service android:name="com.carriez.flutter_hbb.MainService" />',
                      '<service android:name="another.Service" android:foregroundServiceType="microphone" />',
                      '<service android:name="another.Service" android:permission="android.permission.BIND_ACCESSIBILITY_SERVICE" />',
                      '<activity android:name="com.carriez.flutter_hbb.PermissionRequestTransparentActivity" />']:
            text=self.owned().replace('<application>',extra+'<application>') if 'uses-permission' in extra else self.owned().replace('</application>',extra+'</application>')
            with self.subTest(extra=extra), self.assertRaises(ValueError): PACKAGE.verify_manifest(text,'io.nikodesk.android.dev')

    def test_duplicate_owned_service_and_sdk_capped_permissions_are_rejected(self):
        for text in [self.owned().replace('</application>','<service android:name="io.nikodesk.android.voice.NikoVoiceService" /></application>'),
                     self.owned().replace('android:name="android.permission.RECORD_AUDIO"','android:name="android.permission.RECORD_AUDIO" android:maxSdkVersion="35"')]:
            with self.subTest(text=text), self.assertRaises(ValueError): PACKAGE.verify_manifest(text,'io.nikodesk.android.dev')


def elf(alignment=16384, file_offset=0, address=0, load=True):
    data = bytearray(120)
    data[:6] = b'\x7fELF\x02\x01'
    struct.pack_into('<HH', data, 16, 3, 183)
    struct.pack_into('<Q', data, 32, 64)
    struct.pack_into('<HH', data, 54, 56, 1)
    struct.pack_into('<IIQQQQQQ', data, 64, 1 if load else 4, 5,
                     file_offset, address, 0, 1, 1, alignment)
    return data


class PageSizeTests(unittest.TestCase):
    def test_accepts_arm64_loads_aligned_to_16k_or_64k(self):
        for alignment in [16384, 65536]:
            self.assertTrue(PACKAGE.verify_elf(elf(alignment), 'test.so')['elf_16kb_verified'])

    def test_rejects_4k_only_and_noncongruent_load_segments(self):
        for data in [elf(4096), elf(file_offset=1), elf(load=False), elf()[:80]]:
            with self.subTest(data=data), self.assertRaises(ValueError):
                PACKAGE.verify_elf(data, 'test.so')

    def test_rejects_arm32_even_if_load_alignment_matches(self):
        data = elf()
        data[4] = 1
        with self.assertRaises(ValueError):
            PACKAGE.verify_elf(data, 'test.so')

    def test_rejects_unaligned_uncompressed_native_zip(self):
        stream = io.BytesIO()
        with zipfile.ZipFile(stream, 'w') as archive:
            archive.writestr('lib/arm64-v8a/test.so', elf())
        stream.seek(0)
        with zipfile.ZipFile(stream) as archive, self.assertRaises(ValueError):
            PACKAGE.verify_zip_library_alignment(stream, archive.infolist()[0])

    def test_accepts_aligned_uncompressed_and_extracted_compressed_native_zip(self):
        for compressed in [False, True]:
            stream = io.BytesIO()
            entry = zipfile.ZipInfo('lib/arm64-v8a/test.so')
            if compressed:
                entry.compress_type = zipfile.ZIP_DEFLATED
            else:
                padding = 16384 - 30 - len(entry.filename)
                entry.extra = struct.pack('<HH', 0xffff, padding - 4) + bytes(padding - 4)
            with zipfile.ZipFile(stream, 'w') as archive:
                archive.writestr(entry, elf())
            stream.seek(0)
            with zipfile.ZipFile(stream) as archive:
                result = PACKAGE.verify_zip_library_alignment(stream, archive.infolist()[0])
                self.assertTrue(result['zip_16kb_verified'])

    def test_compressed_apk_requires_native_extraction(self):
        with tempfile.TemporaryDirectory() as temporary:
            apk = Path(temporary) / 'sample.apk'
            with zipfile.ZipFile(apk, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
                for name in ('librustdesk.so', 'libc++_shared.so', 'libflutter.so', 'libapp.so'):
                    archive.writestr('lib/arm64-v8a/' + name, elf())
            for extract in [True, False]:
                text = manifest().replace('<application>', f'<application android:extractNativeLibs="{str(extract).lower()}">')
                with patch.object(PACKAGE, 'analyzer_path', return_value='apkanalyzer'), \
                     patch.object(PACKAGE.subprocess, 'run') as run, contextlib.redirect_stdout(io.StringIO()):
                    run.return_value.stdout = text
                    if extract:
                        PACKAGE.verify_apk(apk, 'io.nikodesk.android.dev', unsigned=True)
                    else:
                        with self.assertRaises(ValueError):
                            PACKAGE.verify_apk(apk, 'io.nikodesk.android.dev', unsigned=True)


class SigningAndArchiveTests(unittest.TestCase):
    certificate = 'ab' * 32

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.apk = Path(self.temporary.name) / 'test.apk'
        self.libraries = ['librustdesk.so', 'libc++_shared.so', 'libflutter.so', 'libapp.so']

    def write_apk(self, names=None):
        with zipfile.ZipFile(self.apk, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
            for name in names if names is not None else self.libraries:
                archive.writestr('lib/arm64-v8a/' + name, elf())

    def verify(self, **kwargs):
        with patch.object(PACKAGE, 'analyzer_path', return_value='apkanalyzer'), \
             patch.object(PACKAGE.subprocess, 'run') as run, \
             patch.object(PACKAGE, 'signing_certificate', return_value=self.certificate), \
             contextlib.redirect_stdout(io.StringIO()):
            run.return_value.stdout = manifest()
            PACKAGE.verify_apk(self.apk, 'io.nikodesk.android.dev', **kwargs)

    def test_rejects_signing_identity_change_even_when_signature_is_valid(self):
        self.write_apk()
        with self.assertRaisesRegex(ValueError, 'signing identity changed'):
            self.verify(certificate_sha256='cd' * 32)

    def test_signed_report_records_verified_expected_identity(self):
        self.write_apk()
        report = Path(self.temporary.name) / 'report.json'
        self.verify(certificate_sha256=self.certificate, report_output=report)
        result = PACKAGE.json.loads(report.read_text())
        self.assertTrue(result['signature_verified'])
        self.assertTrue(result['expected_signing_identity_verified'])
        self.assertFalse(result['stable_release_signing_verified'])

    def test_unsigned_inspection_cannot_claim_signature_or_upgrade_identity(self):
        self.write_apk()
        report = Path(self.temporary.name) / 'report.json'
        self.verify(unsigned=True, report_output=report)
        result = PACKAGE.json.loads(report.read_text())
        self.assertFalse(result['signature_verified'])
        self.assertFalse(result['expected_signing_identity_verified'])
        self.assertIsNone(result['certificate_sha256'])
        with self.assertRaisesRegex(ValueError, 'signing identity changed'):
            self.verify(unsigned=True, certificate_sha256=self.certificate)

    def test_rejects_missing_core_even_if_other_libraries_are_valid(self):
        self.write_apk(self.libraries[1:])
        with self.assertRaisesRegex(ValueError, 'Missing native library: librustdesk.so'):
            self.verify(unsigned=True)

    def test_rejects_duplicate_native_entries(self):
        import warnings
        with warnings.catch_warnings():
            warnings.simplefilter('ignore', UserWarning)
            self.write_apk(self.libraries + [self.libraries[0]])
        with self.assertRaisesRegex(ValueError, 'duplicate ZIP entries'):
            self.verify(unsigned=True)

    def test_rejects_unexpected_native_abi_despite_valid_arm64_payload(self):
        self.write_apk()
        with zipfile.ZipFile(self.apk, 'a', compression=zipfile.ZIP_DEFLATED) as archive:
            archive.writestr('lib/armeabi-v7a/unexpected.so', elf())
        with self.assertRaisesRegex(ValueError, 'Unexpected native APK entry'):
            self.verify(unsigned=True)


def uleb(value):
    result = bytearray()
    while value > 127:
        result.append((value & 127) | 128)
        value >>= 7
    return bytes(result + bytes([value]))


def mutf8(text):
    units = text.encode('utf-16-le', 'surrogatepass')
    raw = bytearray()
    for i in range(0, len(units), 2):
        value = int.from_bytes(units[i:i + 2], 'little')
        if value and value < 128:
            raw.append(value)
        elif value < 2048:
            raw.extend([0xc0 | (value >> 6), 0x80 | (value & 63)])
        else:
            raw.extend([0xe0 | (value >> 12), 0x80 | ((value >> 6) & 63), 0x80 | (value & 63)])
    return uleb(len(units) // 2) + raw + b'\0'


def dex_checksums(data):
    data = bytearray(data)
    data[12:32] = hashlib.sha1(data[32:]).digest()
    struct.pack_into('<I', data, 8, zlib.adler32(data[12:]) & 0xffffffff)
    return data


def voice_classes():
    result = []
    for name, methods in PACKAGE.OWNED_VOICE_METHODS.items():
        result.append({'name': PACKAGE.VOICE_PACKAGE + name + ';',
                       'parent': 'Ljava/lang/Object;', 'flags': 0x11,
                       'methods': [(method, descriptor, (0x10a if method.startswith('native') else 9)
                                    if name == 'NikoVoiceBridge' else 1)
                                   for method, descriptor in methods.items()]})
    result.append({'name': PACKAGE.VOICE_PACKAGE + 'NikoVoiceService;',
                   'parent': 'Landroid/app/Service;', 'flags': 0x11,
                   'methods': [('<init>', '()V', 0x10001)]})
    return result


def dex_fixture(classes, extra_strings=()):
    """Synthetic bounded ABI metadata for parser/adversarial tests only.

    This is not the official D8 positive fixture or a runtime-valid APK. The
    separate recorded SDK fixture compiles actual production Kotlin classes.
    """
    descriptors = {c['name'] for c in classes} | {c['parent'] for c in classes}
    prototypes = set()
    names = set(extra_strings)
    for c in classes:
        for name, descriptor, _ in c['methods']:
            params, result = descriptor[1:].split(')', 1)
            parameters = tuple(re.findall(r'\[*(?:[VZBSCIJFD]|L[^;]+;)', params))
            prototypes.add((result, parameters))
            descriptors.update([result, *parameters])
            names.add(name)
    names.update(descriptors)
    shorty = lambda t: 'L' if t.startswith(('L', '[')) else t
    for result, params in prototypes:
        names.add(shorty(result) + ''.join(map(shorty, params)))
    strings = sorted(names, key=lambda s: s.encode('utf-16-be', 'surrogatepass'))
    string_ids = {s: i for i, s in enumerate(strings)}
    types = sorted(descriptors, key=string_ids.get)
    type_ids = {s: i for i, s in enumerate(types)}
    prototypes = sorted(prototypes, key=lambda p: (type_ids[p[0]], tuple(map(type_ids.get, p[1]))))
    proto_ids = {p: i for i, p in enumerate(prototypes)}
    methods = []
    for c in classes:
        for name, descriptor, _ in c['methods']:
            params, result = descriptor[1:].split(')', 1)
            parameters = tuple(re.findall(r'\[*(?:[VZBSCIJFD]|L[^;]+;)', params))
            methods.append((type_ids[c['name']], proto_ids[(result, parameters)], string_ids[name]))
    methods = sorted(set(methods), key=lambda p: (p[0], p[2], p[1]))
    method_ids = {p: i for i, p in enumerate(methods)}
    starts, cursor = {}, 112
    for key, size, stride in [('strings', len(strings), 4), ('types', len(types), 4),
                              ('protos', len(prototypes), 12), ('fields', 0, 8),
                              ('methods', len(methods), 8), ('classes', len(classes), 32)]:
        starts[key] = (cursor if size else 0, size)
        cursor += size * stride
    data_off = cursor
    data = bytearray(cursor)
    string_offsets = []
    for text in strings:
        string_offsets.append(len(data))
        data.extend(mutf8(text))
    align = lambda: data.extend(bytes((-len(data)) % 4))
    parameter_offsets = []
    for _, parameters in prototypes:
        if parameters:
            align()
            parameter_offsets.append(len(data))
            data.extend(struct.pack('<I', len(parameters)))
            data.extend(b''.join(struct.pack('<H', type_ids[p]) for p in parameters))
        else:
            parameter_offsets.append(0)
    class_offsets = []
    for c in classes:
        groups = [[], []]
        for name, descriptor, flags in c['methods']:
            params, result = descriptor[1:].split(')', 1)
            parameters = tuple(re.findall(r'\[*(?:[VZBSCIJFD]|L[^;]+;)', params))
            index = method_ids[(type_ids[c['name']], proto_ids[(result, parameters)], string_ids[name])]
            code = 0
            if not flags & (0x100 | 0x400):
                align()
                code = len(data)
                data.extend(struct.pack('<HHHHIIH', 2, 0, 0, 0, 0, 1, 0x000e))
            groups[0 if flags & (8 | 2 | 0x10000) else 1].append((index, flags, code))
        if c.get('references_only'):
            class_offsets.append(0)
            continue
        class_offsets.append(len(data))
        data.extend(b'\0\0' + uleb(len(groups[0])) + uleb(len(groups[1])))
        for group in groups:
            previous = 0
            for index, flags, code in sorted(group):
                data.extend(uleb(index - previous) + uleb(flags) + uleb(code))
                previous = index
    data[:8] = b'dex\n035\0'
    struct.pack_into('<III', data, 32, len(data), 112, 0x12345678)
    struct.pack_into('<II', data, 104, len(data) - data_off, data_off)
    for key, offset in [('strings', 56), ('types', 64), ('protos', 72),
                        ('fields', 80), ('methods', 88), ('classes', 96)]:
        start, count = starts[key]
        struct.pack_into('<II', data, offset, count, start)
    for i, offset in enumerate(string_offsets):
        struct.pack_into('<I', data, starts['strings'][0] + 4 * i, offset)
    for i, descriptor in enumerate(types):
        struct.pack_into('<I', data, starts['types'][0] + 4 * i, string_ids[descriptor])
    for i, (result, params) in enumerate(prototypes):
        struct.pack_into('<III', data, starts['protos'][0] + 12 * i,
                         string_ids[shorty(result) + ''.join(map(shorty, params))], type_ids[result], parameter_offsets[i])
    for i, method in enumerate(methods):
        struct.pack_into('<HHI', data, starts['methods'][0] + 8 * i, *method)
    for i, c in enumerate(classes):
        struct.pack_into('<IIIIIIII', data, starts['classes'][0] + 32 * i,
                         type_ids[c['name']], c['flags'], type_ids[c['parent']], 0, 0xffffffff, 0, class_offsets[i], 0)
    return dex_checksums(data)


def jni_elf(exports=PACKAGE.OWNED_VOICE_JNI, info=0x12, visibility=0, section_index=1):
    """Synthetic ELF symbol metadata; no load/execute or native-runtime claim."""
    data = bytearray(elf())
    text_offset = len(data)
    data.extend(bytes(16))
    names = b'\0' + b'\0'.join(name.encode() for name in exports) + b'\0'
    strings_offset = len(data)
    data.extend(names)
    data.extend(bytes((-len(data)) % 8))
    symbols_offset = len(data)
    data.extend(bytes(24))
    string_offset = 1
    for i, name in enumerate(exports):
        data.extend(struct.pack('<IBBHQQ', string_offset, info, visibility, section_index, text_offset + i * 4, 4))
        string_offset += len(name) + 1
    sections_offset = len(data)
    data.extend(bytes(64))
    for fields in [(0, 1, 6, text_offset, text_offset, 16, 0, 0, 4, 0),
                   (0, 3, 0, 0, strings_offset, len(names), 0, 0, 1, 0),
                   (0, 11, 0, 0, symbols_offset, 24 * (len(exports) + 1), 2, 1, 8, 24)]:
        data.extend(struct.pack('<IIQQQQIIQQ', *fields))
    struct.pack_into('<Q', data, 40, sections_offset)
    struct.pack_into('<HH', data, 58, 64, 4)
    struct.pack_into('<QQ', data, 96, len(data), len(data))
    return data


class FinalOwnedVoiceAbiTests(unittest.TestCase):
    def verify_dex(self, entries):
        stream = io.BytesIO()
        with zipfile.ZipFile(stream, 'w', zipfile.ZIP_DEFLATED) as archive:
            for name, data in entries:
                archive.writestr(name, data)
        with zipfile.ZipFile(stream) as archive:
            return PACKAGE.verify_voice_dex(archive)

    def test_actual_definition_metadata_can_span_multiple_dex(self):
        classes = voice_classes()
        result = self.verify_dex([('classes.dex', dex_fixture(classes[:2])),
                                  ('classes2.dex', dex_fixture(classes[2:]))])
        self.assertEqual(result['owned_voice_jvm_descriptors_verified'], 22)
        self.assertEqual(len(result['owned_voice_defined_classes']), 6)

    def test_symbol_like_strings_and_references_are_not_defined_classes_or_methods(self):
        with self.assertRaisesRegex(ValueError, 'Missing concrete'):
            self.verify_dex([('classes.dex', dex_fixture([], [c['name'] for c in voice_classes()]))])
        classes = voice_classes()
        classes[0]['references_only'] = True
        with self.assertRaisesRegex(ValueError, 'JNI method'):
            self.verify_dex([('classes.dex', dex_fixture(classes))])

    def test_duplicate_classes_in_one_or_multiple_dex_are_rejected(self):
        classes = voice_classes()
        for entries in [[('classes.dex', dex_fixture(classes + [classes[0]]))],
                        [('classes.dex', dex_fixture(classes)), ('classes2.dex', dex_fixture([classes[0]]))]]:
            with self.subTest(count=len(entries)), self.assertRaisesRegex(ValueError, '[Dd]uplicate'):
                self.verify_dex(entries)

    def test_duplicate_encoded_method_cannot_be_hidden_by_dictionary_overwrite(self):
        classes = voice_classes()
        classes[0]['methods'].append(classes[0]['methods'][0])
        with self.assertRaisesRegex(ValueError, 'Duplicate'):
            self.verify_dex([('classes.dex', dex_fixture(classes))])

    def test_missing_class_or_incompatible_required_method_cannot_pass(self):
        for index in range(len(voice_classes())):
            classes = voice_classes()
            del classes[index]
            with self.subTest(missing=index), self.assertRaisesRegex(ValueError, 'Missing concrete'):
                self.verify_dex([('classes.dex', dex_fixture(classes))])
        for descriptor, flags in [('()V', 0x10a), ('()Z', 0x102), ('()Z', 9), ('()Z', 0x408)]:
            classes = voice_classes()
            classes[0]['methods'][0] = ('nativeInitialize', descriptor, flags)
            with self.subTest(descriptor=descriptor, flags=flags), self.assertRaisesRegex(ValueError, 'JNI method'):
                self.verify_dex([('classes.dex', dex_fixture(classes))])

    def test_service_requires_concrete_android_type_and_public_constructor(self):
        for parent, flags, constructor in [('Ljava/lang/Object;', 0x11, 0x10001),
                                           ('Landroid/app/Service;', 0x411, 0x10001),
                                           ('Landroid/app/Service;', 0x11, 0x10002)]:
            classes = voice_classes()
            classes[-1].update(parent=parent, flags=flags, methods=[('<init>', '()V', constructor)])
            with self.subTest(parent=parent, flags=flags), self.assertRaises(ValueError):
                self.verify_dex([('classes.dex', dex_fixture(classes))])

    def test_unknown_missing_and_noncanonical_dex_names_are_rejected(self):
        data = dex_fixture(voice_classes())
        for entries in [[], [('classes1.dex', data)], [('assets/classes.dex', data)],
                        [('classes01.dex', data)], [('classes0.dex', data)]]:
            with self.subTest(entries=[name for name, _ in entries]), self.assertRaises(ValueError):
                self.verify_dex(entries)

    def test_mutf8_preserves_chinese_nul_surrogate_pairs_and_unpaired_code_units(self):
        text = ['中文', 'with\0nul', '\ud83d\ude03', '\ud800isolated']
        data = dex_fixture([], text)
        reader = PACKAGE.DexReader(data)
        actual = [reader.string(i) for i in range(reader.tables['strings'][0])]
        self.assertEqual(set(actual), set(text))

    def test_nonascii_defined_class_and_method_do_not_break_metadata_reader(self):
        classes = [{'name': 'Lfixture/中文;', 'parent': 'Ljava/lang/Object;', 'flags': 1,
                    'methods': [('测试', '()V', 1)]}]
        result = PACKAGE.DexReader(dex_fixture(classes)).defined_classes()
        self.assertIn(('测试', '()V'), result['Lfixture/中文;']['methods'])

    def test_mutf8_rejects_four_byte_utf8_overlong_or_wrong_utf16_length(self):
        for text, replacement in [('abcd', b'\xf0\x9f\x98\x80'), ('ab', b'\xc1\xbf'),
                                  ('abc', b'\xed\xa0\x80')]:
            data = dex_fixture([], [text])
            reader = PACKAGE.DexReader(data)
            start = reader.u32(reader.table_offset('strings', 0)) + 1
            data[start:start + len(replacement)] = replacement
            with self.subTest(text=text), self.assertRaises(ValueError):
                PACKAGE.DexReader(dex_checksums(data)).string(0)

    def test_corrupt_checksum_unsupported_container_and_malicious_table_bounds_fail(self):
        original = dex_fixture(voice_classes())
        mutations = [original[:80], bytearray(original), bytearray(original), bytearray(original), bytearray(original)]
        mutations[1][8] ^= 1
        mutations[2][:8] = b'dex\n041\0'
        struct.pack_into('<I', mutations[3], 60, len(original) + 1)
        struct.pack_into('<I', mutations[4], 56, 0xffffffff)
        for data in mutations:
            with self.subTest(size=len(data)), self.assertRaises(ValueError):
                PACKAGE.DexReader(dex_checksums(data) if len(data) > 112 and data != mutations[1] else data)

    def test_invalid_type_index_class_data_uleb_and_code_bounds_fail(self):
        original = dex_fixture(voice_classes())
        reader = PACKAGE.DexReader(original)
        for variant in ['type', 'data', 'uleb', 'code']:
            data = bytearray(original)
            if variant == 'type':
                struct.pack_into('<I', data, reader.table_offset('types', 0), 0xffffffff)
            elif variant == 'data':
                struct.pack_into('<I', data, reader.table_offset('classes', 0) + 24, len(data) + 1)
            elif variant == 'uleb':
                pos = reader.u32(reader.table_offset('classes', 0) + 24)
                data[pos:pos + 5] = b'\xff' * 5
            else:
                definitions = reader.defined_classes()
                code = next(record['code'] for c in definitions.values() for record in c['methods'].values() if record['code'])
                struct.pack_into('<I', data, code + 12, 0xffffffff)
            with self.subTest(variant=variant), self.assertRaises(ValueError):
                PACKAGE.DexReader(dex_checksums(data)).defined_classes()

    def test_jni_requires_defined_global_visible_function_and_unique_export(self):
        self.assertTrue(PACKAGE.verify_voice_jni_exports(jni_elf())['owned_voice_native_abi_verified'])
        for data in [jni_elf(info=0x11), jni_elf(info=0x02), jni_elf(info=0x22),
                     jni_elf(visibility=2), jni_elf(visibility=4), jni_elf(section_index=0),
                     jni_elf(exports=PACKAGE.OWNED_VOICE_JNI[:1]),
                     jni_elf(exports=[PACKAGE.OWNED_VOICE_JNI[0]] * 2),
                     elf() + b'\0'.join(name.encode() for name in PACKAGE.OWNED_VOICE_JNI)]:
            with self.subTest(size=len(data)), self.assertRaises(ValueError):
                PACKAGE.verify_voice_jni_exports(data)

    def test_elf_dynamic_section_link_and_entry_bounds_fail(self):
        original = jni_elf()
        section_table = struct.unpack_from('<Q', original, 40)[0]
        for field, format, value in [(32, '<Q', len(original) + 1), (40, '<I', 99), (56, '<Q', 23)]:
            data = bytearray(original)
            struct.pack_into(format, data, section_table + 3 * 64 + field, value)
            with self.subTest(field=field), self.assertRaises(ValueError):
                PACKAGE.verify_voice_jni_exports(data)

    def test_owned_package_boundary_and_stable_signer_are_explicit(self):
        text = OwnedVoiceManifestTests().owned()
        with self.assertRaisesRegex(ValueError, 'isolated'):
            PACKAGE.verify_manifest(text.replace('io.nikodesk.android.dev', 'another.app'), 'another.app', require_owned_voice=True)
        for expected in [None, '', 'ab' * 31, 'xx' * 32]:
            with self.subTest(expected=expected), self.assertRaisesRegex(ValueError, 'expected stable'):
                PACKAGE.verify_apk(Path('unused.apk'), 'io.nikodesk.android.dev', certificate_sha256=expected, require_owned_voice=True)

    def test_final_archive_flag_runs_abi_gate_and_history_keeps_old_behavior(self):
        with tempfile.TemporaryDirectory() as directory:
            apk = Path(directory) / 'fixture.apk'
            report = Path(directory) / 'report.json'
            with zipfile.ZipFile(apk, 'w', zipfile.ZIP_DEFLATED) as archive:
                for library in ['librustdesk.so', 'libc++_shared.so', 'libflutter.so', 'libapp.so']:
                    archive.writestr('lib/arm64-v8a/' + library, jni_elf() if library == 'librustdesk.so' else elf())
                archive.writestr('classes.dex', dex_fixture(voice_classes()))
            before = hashlib.sha256(apk.read_bytes()).hexdigest()
            with patch.object(PACKAGE, 'analyzer_path', return_value='apkanalyzer'), \
                 patch.object(PACKAGE.subprocess, 'run') as run, \
                 patch.object(PACKAGE, 'signing_certificate', return_value='ab' * 32), \
                 contextlib.redirect_stdout(io.StringIO()):
                run.return_value.stdout = OwnedVoiceManifestTests().owned()
                PACKAGE.verify_apk(apk, 'io.nikodesk.android.dev', require_owned_voice=True,
                                   certificate_sha256='ab' * 32, report_output=report)
                value = PACKAGE.json.loads(report.read_text())
                self.assertTrue(value['owned_voice_native_abi_verified'])
                self.assertTrue(value['owned_voice_dex_abi_verified'])
                self.assertTrue(value['signature_verified'])
                with self.assertRaisesRegex(ValueError, 'signing identity changed'):
                    PACKAGE.verify_apk(apk, 'io.nikodesk.android.dev', require_owned_voice=True, certificate_sha256='cd' * 32)
                PACKAGE.verify_apk(apk, 'io.nikodesk.android.dev', unsigned=True,
                                   require_owned_voice=True, report_output=report)
                self.assertFalse(PACKAGE.json.loads(report.read_text())['signature_verified'])
                run.return_value.stdout = manifest()
                PACKAGE.verify_apk(apk, 'io.nikodesk.android.dev', unsigned=True, report_output=report)
                self.assertNotIn('owned_voice_dex_abi_verified', PACKAGE.json.loads(report.read_text()))
            self.assertEqual(before, hashlib.sha256(apk.read_bytes()).hexdigest())


if __name__ == '__main__':
    unittest.main()
