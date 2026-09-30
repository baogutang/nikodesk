import importlib.util
import contextlib
import io
import struct
import tempfile
import unittest
from unittest.mock import patch
import zipfile
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


if __name__ == '__main__':
    unittest.main()
