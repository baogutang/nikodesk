"""Parser/boundary fixtures are synthetic, not Windows build/runtime evidence."""

import hashlib
import importlib.util
import os
import struct
import tempfile
import unittest
import unittest.mock
import warnings
import zipfile
from pathlib import Path

import brotli


SCRIPT = Path(__file__).resolve().parents[1] / 'verify-package-windows.py'
SPEC = importlib.util.spec_from_file_location('windows_package', SCRIPT)
PACKAGE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PACKAGE)


def node(key, value=b'', children=(), text=False):
    data = bytearray(struct.pack('<HHH', 0, len(value) // 2 if text else len(value), int(text)))
    data.extend((key + '\0').encode('utf-16le'))
    data.extend(bytes(-len(data) % 4))
    data.extend(value)
    for child in children:
        data.extend(bytes(-len(data) % 4))
        data.extend(child)
    struct.pack_into('<H', data, 0, len(data))
    return bytes(data)


def version(parts=(1, 1, 0, 2), strings=None):
    ms, ls = parts[0] << 16 | parts[1], parts[2] << 16 | parts[3]
    fixed = struct.pack('<13I', 0xfeef04bd, 0x10000, ms, ls, ms, ls, 0x3f, 0, 0x40004, 1, 0, 0, 0)
    values = {'ProductName': 'NikoDesk', 'OriginalFilename': 'NikoDesk.exe',
              'FileVersion': '1.1.0+2', 'ProductVersion': '1.1.0+2'}
    values.update(strings or {})
    table = node('040904e4', children=[node(k, (v + '\0').encode('utf-16le'), text=True) for k, v in values.items()])
    return node('VS_VERSION_INFO', fixed, [node('StringFileInfo', children=[table])])


def manifest(level='asInvoker', ui_access='false', duplicate=False):
    element = f'<requestedExecutionLevel level="{level}" uiAccess="{ui_access}" />'
    return (f'<assembly xmlns="urn:schemas-microsoft-com:asm.v1">'
            f'<trustInfo xmlns="urn:schemas-microsoft-com:asm.v3"><security><requestedPrivileges>'
            f'{element}{element if duplicate else ""}</requestedPrivileges></security></trustInfo></assembly>').encode()


def resource_section(resources):
    tree = {}
    for keys, value in resources.items():
        tree.setdefault(keys[0], {}).setdefault(keys[1], {})[keys[2]] = value
    data = bytearray()

    def allocate(length):
        data.extend(bytes(-len(data) % 4))
        start = len(data)
        data.extend(bytes(length))
        return start

    def directory(tree):
        start = allocate(16 + len(tree) * 8)
        struct.pack_into('<HH', data, start + 12, sum(isinstance(x, str) for x in tree), sum(isinstance(x, int) for x in tree))
        for index, (key, value) in enumerate(sorted(tree.items(), key=lambda x: (isinstance(x[0], int), str(x[0])))):
            if isinstance(key, str):
                encoded = key.encode('utf-16le')
                name = allocate(2 + len(encoded))
                struct.pack_into('<H', data, name, len(encoded) // 2)
                data[name + 2:name + 2 + len(encoded)] = encoded
                name |= 0x80000000
            else:
                name = key
            if isinstance(value, dict):
                target = directory(value) | 0x80000000
            else:
                target = allocate(16)
                content = allocate(len(value))
                data[content:content + len(value)] = value
                struct.pack_into('<IIII', data, target, 0x1000 + content, len(value), 0, 0)
            struct.pack_into('<II', data, start + 16 + index * 8, name, target)
        return start
    directory(tree)
    return bytes(data)


def pe(dll=False, resources=None, blob=b'fixture-data', machine=0x8664):
    rsrc = resource_section(resources) if resources else b''
    sections = [(b'.rsrc', 0x1000, rsrc), (b'.rdata', 0x2000, blob or b'empty')]
    data = bytearray(512)
    data[:2] = b'MZ'
    struct.pack_into('<I', data, 0x3c, 0x80)
    data[0x80:0x84] = b'PE\0\0'
    struct.pack_into('<HHIIIHH', data, 0x84, machine, 2, 0, 0, 0, 240, 2 | (0x2000 if dll else 0))
    optional = 0x98
    struct.pack_into('<H', data, optional, 0x20b)
    struct.pack_into('<I', data, optional + 108, 16)
    if rsrc:
        struct.pack_into('<II', data, optional + 128, 0x1000, len(rsrc))
    for index, (name, rva, content) in enumerate(sections):
        raw = len(data)
        raw_size = (len(content) + 511) & ~511
        at = optional + 240 + index * 40
        data[at:at + 8] = name.ljust(8, b'\0')
        struct.pack_into('<IIII', data, at + 8, len(content), rva, raw_size, raw)
        struct.pack_into('<I', data, at + 36, 0x40000040)
        data.extend(content)
        data.extend(bytes(raw_size - len(content)))
    return bytes(data)


def product_pe(**kwargs):
    resources = {(16, 1, 1033): version(), (24, 1, 1033): manifest()}
    resources.update(kwargs.pop('resources', {}))
    return pe(resources=resources, **kwargs)


def elf():
    data = bytearray(120)
    data[:6] = b'\x7fELF\x02\x01'
    struct.pack_into('<HH', data, 16, 3, 62)
    struct.pack_into('<Q', data, 32, 64)
    struct.pack_into('<HH', data, 54, 56, 1)
    struct.pack_into('<IIQQQQQQ', data, 64, 1, 5, 0, 0, 0, 120, 120, 4096)
    return bytes(data)


def payload(files, executable='./NikoDesk.exe'):
    data = bytearray(b'rustdesk')
    for name, value in files.items():
        path = ('./' + name).encode()
        compressed = brotli.compress(value)
        data.extend(struct.pack('>I', len(path)) + path + struct.pack('>I', len(compressed)) + compressed)
        data.extend(hashlib.md5(value).hexdigest().encode())
    return bytes(data) + b'rustdesk' + executable.encode()


class ParserTests(unittest.TestCase):
    def test_product_resources_and_manifest_are_parsed_without_loading(self):
        PACKAGE.product_exe(product_pe(), (1, 1, 0, 2))

    def test_rejects_wrong_machine_image_kind_and_truncated_pe(self):
        for data in (pe(machine=0xaa64), pe(dll=True), product_pe()[:300], b'MZ'):
            with self.subTest(data=data[:20]), self.assertRaises(ValueError):
                PACKAGE.product_exe(data, (1, 1, 0, 2))

    def test_rejects_numeric_and_string_native_protocol_version_mix(self):
        for value in (version((1, 5, 0, 0)), version(strings={'ProductVersion': '1.5.0'})):
            with self.subTest(value=value[:20]), self.assertRaises(ValueError):
                PACKAGE.product_exe(product_pe(resources={(16, 1, 1033): value}), (1, 1, 0, 2))

    def test_rejects_wrong_product_identity_and_original_filename(self):
        for strings in ({'ProductName': 'RustDesk'}, {'OriginalFilename': 'rustdesk.exe'}):
            with self.subTest(strings=strings), self.assertRaises(ValueError):
                PACKAGE.product_version_resource(version(strings=strings), (1, 1, 0, 2))

    def test_rejects_elevation_uiaccess_duplicate_and_missing_manifests(self):
        for value in (manifest('requireAdministrator'), manifest(ui_access='true'), manifest(duplicate=True), b'<assembly/>'):
            with self.subTest(value=value), self.assertRaises(ValueError):
                PACKAGE.ordinary_user_manifest(value)
        with self.assertRaises(ValueError):
            PACKAGE.product_exe(pe(resources={(16, 1, 1033): version()}), (1, 1, 0, 2))

    def test_rejects_resource_rva_outside_image_and_directory_cycle(self):
        data = bytearray(product_pe())
        struct.pack_into('<I', data, 0x98 + 128, 0xffff0000)
        with self.assertRaises(ValueError):
            PACKAGE.PE(data)
        data = bytearray(product_pe())
        struct.pack_into('<I', data, 512 + 20, 0x80000000)
        with self.assertRaises(ValueError):
            PACKAGE.PE(data)

    def test_rejects_malformed_version_lengths(self):
        value = bytearray(version())
        struct.pack_into('<H', value, 0, 65535)
        with self.assertRaises(ValueError):
            PACKAGE.product_version_resource(value, (1, 1, 0, 2))

    def test_rejects_unsafe_windows_paths_and_version_overflow(self):
        for name in ('../escape', '/absolute', 'C:relative', 'a\\..\\escape', 'NUL.txt', 'a.', 'a ', 'a//b', 'a\0b'):
            with self.subTest(name=name), self.assertRaises(ValueError):
                PACKAGE.windows_path(name)
        for name, build in [('1.1', 2), ('65536.0.0', 2), ('1.1.0', 0), ('1.1.0', 65536), ('1.1.0', -1)]:
            with self.subTest(name=name, build=build), self.assertRaises(ValueError):
                PACKAGE.version_parts(name, build)

    @unittest.skipUnless(os.environ.get('NIKODESK_OLD_PUBLIC_PE'), 'Cached real public PE is not supplied; no network download in tests')
    def test_real_old_public_runner_is_rejected_for_wrong_product_version(self):
        data = Path(os.environ['NIKODESK_OLD_PUBLIC_PE']).read_bytes()
        self.assertEqual(hashlib.sha256(data).hexdigest(), '2e372f2a32ee3c40aeb1d75a70d359d2aac5514efc24ff0c41e5a61b0e21b564')
        with self.assertRaisesRegex(ValueError, 'numeric product version'):
            PACKAGE.product_exe(data, (1, 1, 0, 2))


class PackageBoundaryTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='nikodesk static fixture ')
        self.root = Path(self.temporary.name)
        self.bundle = self.root / 'bundle'
        self.bundle.mkdir()
        self.license = self.root / 'LICENCE'
        self.license.write_bytes(b'Fixture license, not a real distribution\n')
        self.files = {'NikoDesk.exe': product_pe(), 'librustdesk.dll': pe(dll=True),
                      'flutter_windows.dll': pe(dll=True), 'dylib_virtual_display.dll': pe(dll=True),
                      'data/app.so': elf(), 'data/icudtl.dat': bytes(128),
                      'data/flutter_assets/AssetManifest.bin': b'fixture assets',
                      'NikoDesk-LICENCE.txt': self.license.read_bytes(),
                      'NikoDesk-source.txt': ('Product 1.1.0+2; upstream native/protocol 1.5.0\nSource ' + 'a' * 40 + '; dirty=False\n').encode()}
        self.files.update({name: (PACKAGE.CPAL_SOURCE / Path(name).name).read_bytes()
                           for name in PACKAGE.CPAL_NOTICES})
        for name, value in self.files.items():
            path = self.bundle / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(value)
        self.blob = self.root / 'data.bin'
        self.blob.write_bytes(payload(self.files))
        self.portable = self.root / 'portable.exe'
        self.portable.write_bytes(product_pe(blob=self.blob.read_bytes()))
        self.archive = self.root / 'bundle.zip'
        self.write_zip(self.files)

    def tearDown(self):
        self.temporary.cleanup()

    def write_zip(self, files):
        with zipfile.ZipFile(self.archive, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
            for name, data in files.items():
                archive.writestr(name, data)

    def records(self, require_display_driver=False):
        return PACKAGE.inspect_bundle(self.bundle, (1, 1, 0, 2), self.license, 'a' * 40, False, '1.5.0',
                                      require_display_driver)

    def bundle_driver(self, pins):
        """Stand-in driver files; the real pins belong to the upstream archive."""
        files = {'usbmmidd_v2/' + name: b'fixture ' + name.encode() for name in pins}
        for name, value in files.items():
            path = self.bundle / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(value)
        return files

    def verify(self):
        return PACKAGE.verify_package(self.bundle, self.portable, self.archive, self.blob,
                                      '1.1.0', 2, self.license, 'a' * 40, False, '1.5.0')

    def test_synthetic_fixture_checks_report_runtime_as_unverified(self):
        result = self.verify()
        self.assertTrue(result['portable_embedded_payload_verified'])
        for key in ('client_launch_verified', 'remote_session_verified', 'unattended_verified', 'production_signature_verified'):
            self.assertFalse(result[key])

    def test_package_notice_can_be_added_after_the_portable_is_built(self):
        (self.bundle / 'EXPERIMENTAL.txt').write_bytes(b'Runtime acceptance pending')
        self.write_zip({**self.files, 'EXPERIMENTAL.txt': b'Runtime acceptance pending'})
        self.verify()

    def test_rejects_missing_core_dart_assets_and_virtual_display_library(self):
        for name in ('librustdesk.dll', 'data/app.so', 'data/flutter_assets/AssetManifest.bin', 'dylib_virtual_display.dll'):
            path = self.bundle / name
            path.unlink()
            with self.subTest(name=name), self.assertRaises(ValueError):
                self.records()
            path.write_bytes(self.files[name])

    def test_rejects_service_helper_driver_extra_executable_and_symlink(self):
        for name in ('rustdesk.exe', 'service.exe', 'RuntimeBroker_rustdesk.exe', 'installer.msi', 'driver.sys', 'driver.inf'):
            path = self.bundle / name
            path.write_bytes(pe())
            with self.subTest(name=name), self.assertRaises(ValueError):
                self.records()
            path.unlink()
        link = self.bundle / 'linked.txt'
        try:
            link.symlink_to(self.license)
        except OSError:
            return  # Windows ordinary-user CI may not grant symlink creation.
        with self.assertRaises(ValueError):
            self.records()

    def test_accepts_only_the_complete_pinned_display_driver(self):
        names = ('License.txt', 'usbmmIdd.inf', 'usbmmidd.cat', 'x64/usbmmIdd.dll')
        pins = {('usbmmidd_v2/' + name).casefold():
                hashlib.sha256(b'fixture ' + name.encode()).hexdigest() for name in names}
        with unittest.mock.patch.object(PACKAGE, 'DRIVER_FILES', pins):
            with self.assertRaisesRegex(ValueError, 'missing or incomplete'):
                self.records(require_display_driver=True)
            files = self.bundle_driver(names)
            records = self.records(require_display_driver=True)
            self.assertEqual({key for key in records if key.startswith('usbmmidd_v2/')}, set(pins))
            self.files.update(files)
            self.write_zip(self.files)
            self.blob.write_bytes(payload(self.files))
            self.portable.write_bytes(product_pe(blob=self.blob.read_bytes()))
            PACKAGE.verify_package(self.bundle, self.portable, self.archive, self.blob, '1.1.0', 2,
                                   self.license, 'a' * 40, False, '1.5.0', True)
            changed = self.bundle / 'usbmmidd_v2/usbmmIdd.inf'
            changed.write_bytes(b'another driver')
            with self.assertRaisesRegex(ValueError, 'Not a pinned display driver file'):
                self.records()
            changed.write_bytes(files['usbmmidd_v2/usbmmIdd.inf'])
            for extra in ('usbmmidd_v2/deviceinstaller64.exe', 'usbmmidd_v2/extra.sys', 'usbmmidd_v2/notes.txt'):
                path = self.bundle / extra
                path.write_bytes(b'not pinned')
                with self.subTest(extra=extra), self.assertRaisesRegex(ValueError, 'Not a pinned display driver file'):
                    self.records()
                path.unlink()
            (self.bundle / 'usbmmidd_v2/usbmmidd.cat').unlink()
            for required in (False, True):
                with self.subTest(required=required), self.assertRaisesRegex(ValueError, 'missing or incomplete'):
                    self.records(require_display_driver=required)

    def test_the_real_driver_pin_names_only_the_signed_package_files(self):
        self.assertEqual(set(PACKAGE.DRIVER_FILES), {
            'usbmmidd_v2/license.txt', 'usbmmidd_v2/idd_instructions.txt', 'usbmmidd_v2/usbmmidd.inf',
            'usbmmidd_v2/usbmmidd.cat', 'usbmmidd_v2/x64/usbmmidd.dll'})
        for digest in PACKAGE.DRIVER_FILES.values():
            self.assertRegex(digest, r'^[0-9a-f]{64}$')

    def test_rejects_non_x64_dll_and_non_dart_app_so(self):
        path = self.bundle / 'librustdesk.dll'
        path.write_bytes(pe(dll=True, machine=0xaa64))
        with self.assertRaises(ValueError):
            self.records()
        path.write_bytes(self.files['librustdesk.dll'])
        (self.bundle / 'data/app.so').write_bytes(b'fake-aot')
        with self.assertRaises(ValueError):
            self.records()

    def test_rejects_license_and_source_identity_drift(self):
        for name in ('NikoDesk-LICENCE.txt', 'NikoDesk-source.txt') + PACKAGE.CPAL_NOTICES:
            path = self.bundle / name
            path.write_bytes(b'incorrect identity')
            with self.subTest(name=name), self.assertRaises(ValueError):
                self.records()
            path.write_bytes(self.files[name])

    def test_rejects_self_reported_source_sha_dirty_and_protocol_mismatch(self):
        for revision, dirty, protocol in [('b' * 40, False, '1.5.0'),
                                          ('a' * 40, True, '1.5.0'),
                                          ('a' * 40, False, '1.1.0')]:
            with self.subTest(revision=revision, dirty=dirty, protocol=protocol), self.assertRaisesRegex(ValueError, 'source revision/dirty record'):
                PACKAGE.inspect_bundle(self.bundle, (1, 1, 0, 2), self.license, revision, dirty, protocol)

    def test_rejects_zip_missing_extra_and_changed_entries(self):
        for changed in ({k: v for k, v in self.files.items() if k != 'librustdesk.dll'},
                        {**self.files, 'unexpected.txt': b'extra'},
                        {**self.files, 'data/icudtl.dat': bytes([1]) * 128}):
            self.write_zip(changed)
            with self.assertRaises(ValueError):
                PACKAGE.inspect_zip(self.archive, self.records())

    def test_rejects_zip_duplicates_and_windows_case_aliases(self):
        for name in ('NikoDesk.exe', 'nikodesk.EXE', '../escape', 'NUL.txt'):
            self.write_zip(self.files)
            with warnings.catch_warnings():
                warnings.simplefilter('ignore', UserWarning)
                with zipfile.ZipFile(self.archive, 'a') as archive:
                    archive.writestr(name, self.files['NikoDesk.exe'])
            with self.subTest(name=name), self.assertRaises(ValueError):
                PACKAGE.inspect_zip(self.archive, self.records())

    def test_rejects_portable_blob_not_embedded_and_resource_override(self):
        self.portable.write_bytes(product_pe())
        with self.assertRaisesRegex(ValueError, 'not embedded'):
            self.verify()
        self.portable.write_bytes(product_pe(blob=self.blob.read_bytes(), resources={(10, 'RDPKG', 1033): b'override'}))
        with self.assertRaisesRegex(ValueError, 'RDPKG'):
            self.verify()

    def test_rejects_portable_blob_missing_changed_or_duplicate_files(self):
        cases = [payload({k: v for k, v in self.files.items() if k != 'librustdesk.dll'}),
                 payload({**self.files, 'data/icudtl.dat': bytes([1]) * 128}),
                 payload({**self.files, 'nikodesk.EXE': self.files['NikoDesk.exe']})]
        for blob in cases:
            with self.assertRaises(ValueError):
                PACKAGE.inspect_payload(blob, self.records())

    def test_accepts_payload_whose_tail_expands_beyond_one_output_buffer(self):
        # A valid stream can end with a whole output buffer still inside the
        # decoder when its input runs out; the drain loop must keep pumping on
        # empty input. The real build 9 bundle failed verification on 19 of 105
        # files (every plugin DLL and the large data files) through this exit.
        expanding = bytes((i * 31 ^ i >> 6) & 0xff for i in range(131072)) + bytes(393216)
        name = 'data/flutter_assets/AssetManifest.bin'
        (self.bundle / name).write_bytes(expanding)
        PACKAGE.inspect_payload(payload({**self.files, name: expanding}), self.records())

    def test_rejects_portable_launch_path_truncation_bad_md5_and_decompression_overflow(self):
        bad_md5 = bytearray(self.blob.read_bytes())
        path_length = struct.unpack_from('>I', bad_md5, 8)[0]
        compressed_at = 12 + path_length
        compressed_length = struct.unpack_from('>I', bad_md5, compressed_at)[0]
        bad_md5[compressed_at + 4 + compressed_length] = ord('x')
        for blob in (payload(self.files, './rustdesk.exe'), self.blob.read_bytes()[:40], bytes(bad_md5),
                     payload({**self.files, 'data/icudtl.dat': bytes(4 * 1024 * 1024)})):
            with self.assertRaises(ValueError):
                PACKAGE.inspect_payload(blob, self.records())


if __name__ == '__main__':
    unittest.main()
