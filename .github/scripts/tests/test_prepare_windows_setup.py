"""Synthetic PE/package fixtures; never compile/run an installer or install a service."""

import ast
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import stat
import struct
import subprocess
import sys
import tempfile
import types
import unittest
from unittest.mock import patch


SCRIPTS = Path(__file__).resolve().parents[1]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


PREPARE = load('prepare_windows_setup', SCRIPTS / 'prepare-windows-setup.py')
# Reuse the existing exact synthetic PE builders, without importing the
# unrelated portable/Brotli test dependency or executing its test classes.
fixture_source = Path(__file__).parent / 'test_package_windows.py'
fixture_functions = {'node', 'version', 'manifest', 'resource_section', 'pe', 'product_pe', 'elf'}
fixture_tree = ast.parse(fixture_source.read_text(encoding='utf-8'))
FIXTURE = types.ModuleType('synthetic_windows_pe')
FIXTURE.struct = struct
exec(compile(ast.Module(body=[node for node in fixture_tree.body
                             if isinstance(node, ast.FunctionDef) and node.name in fixture_functions],
                        type_ignores=[]), str(fixture_source), 'exec'), FIXTURE.__dict__)
TEMP_ROOT = PREPARE.ROOT / 'target' / 'setup-package-tests'


def inner_gui():
    blob = struct.pack('<5I', 0, 0, 0, 0x2028, 0) + bytes(20) + b'flutter_windows.dll\0'
    data = bytearray(FIXTURE.product_pe(blob=blob))
    struct.pack_into('<II', data, 0x98 + 120, 0x2000, 40)
    return bytes(data)


def host(version_resource=None, **kwargs):
    version_resource = version_resource or FIXTURE.version(strings={
        'OriginalFilename': 'nikodesk-host.exe', 'FileVersion': '1.1.0.2', 'ProductVersion': '1.1.0.2'})
    return FIXTURE.pe(resources={(16, 1, 1033): version_resource}, **kwargs)


class SetupPreparationTests(unittest.TestCase):
    def setUp(self):
        TEMP_ROOT.mkdir(parents=True, exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(prefix='synthetic setup ', dir=TEMP_ROOT)
        self.root = Path(self.temporary.name)
        self.gui = self.root / 'gui'
        self.service = self.root / 'service'
        self.output = self.root / 'frozen'
        self.gui.mkdir()
        self.service.mkdir()
        self.pubspec = self.root / 'pubspec.yaml'
        self.pubspec.write_text('name: fixture\nversion: 1.1.0+2\n', encoding='utf-8')
        self.files = {'NikoDesk.exe': inner_gui(), 'librustdesk.dll': FIXTURE.pe(dll=True),
                      'flutter_windows.dll': FIXTURE.pe(dll=True), 'dylib_virtual_display.dll': FIXTURE.pe(dll=True),
                      'data/app.so': FIXTURE.elf(), 'data/icudtl.dat': bytes(128),
                      'data/flutter_assets/AssetManifest.bin': b'synthetic assets',
                      'NikoDesk-LICENCE.txt': (PREPARE.ROOT / 'LICENCE').read_bytes(),
                      'NikoDesk-source.txt': ('Product 1.1.0+2; upstream native/protocol 1.5.0\nSource ' + 'a' * 40 + '; dirty=false\n').encode()}
        for notice in PREPARE.PACKAGE.CPAL_NOTICES:
            self.files[notice] = (PREPARE.PACKAGE.CPAL_SOURCE / Path(notice).name).read_bytes()
        for name, data in self.files.items():
            path = self.gui / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        (self.service / PREPARE.HOST).write_bytes(host())
        (self.service / 'librustdesk.dll').write_bytes(self.files['librustdesk.dll'])

    def tearDown(self):
        # Synthetic read-only outputs must be removed on Windows too.
        for path in self.root.rglob('*'):
            if path.is_file() and not path.is_symlink():
                path.chmod(stat.S_IRUSR | stat.S_IWUSR)
        self.temporary.cleanup()

    def prepare(self, mode='reviewed-local-unsigned-validation'):
        return PREPARE.prepare(self.gui, self.service, self.output, mode, self.pubspec)

    def test_actual_copied_bytes_define_pins_and_service_never_includes_gui_data(self):
        document = self.prepare()
        self.assertEqual(document['product_version'], '1.1.0')
        self.assertEqual(document['product_build'], 2)
        self.assertEqual(set(document), {'schema', 'product_version', 'product_build', 'trust_mode', 'ui_runner', 'service_payload'})
        self.assertEqual(set(document['service_payload']['files']), {PREPARE.HOST, 'librustdesk.dll'})
        for name, pin in document['service_payload']['files'].items():
            copied = (self.output / name).read_bytes()
            self.assertEqual(pin, {'sha256': hashlib.sha256(copied).hexdigest(), 'length': len(copied)})
        self.assertEqual((self.output / 'data/app.so').read_bytes(), self.files['data/app.so'])
        self.assertFalse((self.output / PREPARE.HOST).stat().st_mode & stat.S_IWUSR)
        evidence = json.loads((self.output / 'setup-release-evidence.json').read_text())
        self.assertFalse(evidence['publisher_authorized'])
        self.assertFalse(evidence['production_signature_verified'])
        self.assertFalse(evidence['setup_built_or_run'])
        self.assertFalse(evidence['dependency_product_versions_verified'])
        self.assertEqual(evidence['pubspec_sha256'], hashlib.sha256(self.pubspec.read_bytes()).hexdigest())
        self.assertEqual(document, json.loads((self.output / 'setup-release.json').read_text()))

    def test_empty_gui_asset_preserved_but_empty_service_binary_rejected(self):
        asset = self.gui / 'data/flutter_assets/empty-asset'
        asset.write_bytes(b'')
        self.prepare()
        self.assertEqual((self.output / asset.relative_to(self.gui)).read_bytes(), b'')
        (self.service / 'empty.dll').write_bytes(b'')
        with self.assertRaisesRegex(ValueError, 'Empty'):
            PREPARE.inventory(self.service, flat=True)

    def test_case_fold_collision_rejected_on_case_insensitive_fixture_filesystem(self):
        entries = list(self.service.rglob('*'))
        # Inject the repeated directory-entry spelling; check precedes its stat.
        # This covers the same Windows-name collision on case-insensitive macOS.
        entries.append(self.service / 'LIBRUSTDESK.DLL')
        with patch.object(Path, 'rglob', return_value=iter(entries)):
            with self.assertRaisesRegex(ValueError, 'case-insensitive'):
                PREPARE.inventory(self.service, flat=True)

    def test_signed_mode_is_only_a_native_verification_requirement_not_proof(self):
        document = self.prepare('signed-production')
        self.assertEqual(document['trust_mode'], 'signed-production')
        self.assertFalse(json.loads((self.output / 'setup-release-evidence.json').read_text())['production_signature_verified'])

    def test_missing_or_wrong_host_version_resources_are_rejected(self):
        examples = [FIXTURE.pe(), host(FIXTURE.version((1, 5, 0, 0))),
                    host(FIXTURE.version(strings={'OriginalFilename': 'rustdesk.exe'})),
                    host(FIXTURE.version(strings={'ProductName': 'RustDesk'})),
                    host(FIXTURE.version(strings={'OriginalFilename': PREPARE.HOST,
                                                'FileVersion': '1.1.0+2', 'ProductVersion': '1.1.0+2'}))]
        for data in examples:
            with self.subTest(data=data[-64:]):
                (self.service / PREPARE.HOST).write_bytes(data)
                with self.assertRaises(ValueError):
                    self.prepare()
                self.assertFalse(self.output.exists())

    def test_wrong_gui_version_or_portable_wrapper_cannot_be_ui_pin(self):
        for data in [FIXTURE.product_pe(), FIXTURE.pe(resources={(16, 1, 1033): FIXTURE.version((1, 5, 0, 0)),
                                                                              (24, 1, 1033): FIXTURE.manifest()})]:
            (self.gui / 'NikoDesk.exe').write_bytes(data)
            with self.assertRaises(ValueError):
                self.prepare()
            self.assertFalse(self.output.exists())

    def test_service_rejects_gui_tree_nested_files_and_extra_executable(self):
        with self.assertRaises(ValueError):
            PREPARE.prepare(self.gui, self.gui, self.output, 'signed-production', self.pubspec)
        for name in ['data', 'second.exe', 'driver.sys', 'settings.json', '.hidden.dll', 'bad name.dll', 'CLOCK$.dll']:
            path = self.service / name
            if name == 'data':
                path.mkdir()
            else:
                path.write_bytes(FIXTURE.pe(dll=True))
            with self.subTest(name=name), self.assertRaises(ValueError):
                self.prepare()
            path.rmdir() if path.is_dir() else path.unlink()

    def test_service_rejects_wrong_architecture_or_image_kind(self):
        for data in [FIXTURE.pe(dll=True, machine=0xaa64), FIXTURE.pe(), b'MZ']:
            (self.service / 'librustdesk.dll').write_bytes(data)
            with self.subTest(data=data[:16]), self.assertRaises(ValueError):
                self.prepare()
        (self.service / 'librustdesk.dll').write_bytes(self.files['librustdesk.dll'])
        (self.service / PREPARE.HOST).write_bytes(host(dll=True))
        with self.assertRaises(ValueError):
            self.prepare()

    def test_case_collisions_and_conflicting_shared_dll_bytes_rejected(self):
        (self.service / 'librustdesk.dll').write_bytes(FIXTURE.pe(dll=True, blob=b'different native binary'))
        with self.assertRaisesRegex(ValueError, 'collision'):
            self.prepare()
        (self.service / 'librustdesk.dll').write_bytes(self.files['librustdesk.dll'])
        duplicate = self.service / 'LIBRUSTDESK.DLL'
        if not duplicate.exists():
            duplicate.write_bytes(FIXTURE.pe(dll=True))
            with self.assertRaisesRegex(ValueError, 'case-insensitive'):
                self.prepare()

    def test_links_reparse_attributes_and_hardlinks_rejected(self):
        path = self.service / 'linked.dll'
        try:
            path.symlink_to(self.service / 'librustdesk.dll')
        except OSError:
            pass  # Windows ordinary fixture users might not have symlink privilege.
        else:
            with self.assertRaises(ValueError):
                self.prepare()
            path.unlink()
        os.link(self.service / 'librustdesk.dll', path)
        with self.assertRaises(ValueError):
            self.prepare()
        path.unlink()
        real = (self.service / PREPARE.HOST).lstat()
        class Reparse:
            st_mode, st_nlink, st_file_attributes = real.st_mode, real.st_nlink, 0x400
        with patch.object(Path, 'lstat', return_value=Reparse()), self.assertRaises(ValueError):
            PREPARE.ordinary(self.service / PREPARE.HOST)

    def test_parent_symlink_or_existing_output_never_overwritten(self):
        self.output.mkdir()
        marker = self.output / 'old-pins'
        marker.write_bytes(b'unchanged')
        with self.assertRaises(ValueError):
            self.prepare()
        self.assertEqual(marker.read_bytes(), b'unchanged')
        self.output = self.gui / 'nested'
        with self.assertRaises(ValueError):
            self.prepare()
        link = self.root / 'linked-parent'
        try:
            link.symlink_to(self.service, target_is_directory=True)
        except OSError:
            return
        with self.assertRaises(ValueError):
            PREPARE.inventory(link)

    def test_malformed_or_overflow_pubspec_fails_before_copying(self):
        for scalar in ['1.1.0+0', '1.1.0+65536', '1.1.0-rc.1+2', '01.1.0+2']:
            self.pubspec.write_text('version: ' + scalar)
            with self.subTest(scalar=scalar), self.assertRaises(ValueError):
                self.prepare()
            self.assertFalse(self.output.exists())

    def test_input_changed_after_inspection_does_not_mint_release_pins(self):
        original = PREPARE.gui_records
        def mutate(*args):
            result = original(*args)
            (self.gui / 'data/app.so').write_bytes(b'changed after inspect')
            return result
        with patch.object(PREPARE, 'gui_records', side_effect=mutate), self.assertRaises(ValueError):
            self.prepare()
        self.assertFalse((self.output / 'setup-release.json').exists())

    def test_cli_does_not_accept_unverified_sha_or_version_override(self):
        for argument in ['--ui-sha256', '--service-sha256', '--product-version']:
            result = subprocess.run([sys.executable, str(SCRIPTS / 'prepare-windows-setup.py'), argument, 'a' * 64],
                                    capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
        with self.assertRaises(ValueError):
            self.prepare('unverified-test-pins')

    def test_real_cli_freezes_synthetic_package_from_unrelated_working_directory(self):
        result = subprocess.run([sys.executable, str(SCRIPTS / 'prepare-windows-setup.py'),
                                 '--gui-bundle', str(self.gui), '--service-payload', str(self.service),
                                 '--output', str(self.output), '--pubspec', str(self.pubspec),
                                 '--trust-mode', 'reviewed-local-unsigned-validation'], cwd=self.root,
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        reply = json.loads(result.stdout)
        self.assertEqual(reply['product_build'], 2)
        self.assertFalse(reply['setup_built_or_run'])
        self.assertTrue(Path(reply['release_json']).is_file())


if __name__ == '__main__':
    unittest.main()
