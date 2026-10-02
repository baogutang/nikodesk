"""Synthetic PE/orchestrator failures; no Windows build, elevation or install."""

import importlib.util
import json
import os
from pathlib import Path
import shutil
import stat
import struct
import subprocess
import unittest
from unittest.mock import patch


SCRIPTS = Path(__file__).resolve().parents[1]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


BUILD = load('windows_product_build', SCRIPTS / 'build-windows-product.py')
FIXTURES = load('windows_setup_fixtures', SCRIPTS / 'tests/test_prepare_windows_setup.py')
PE = FIXTURES.FIXTURE


def native(name, dependencies=(), pins=b'', flags=0xA00, level='asInvoker'):
    blob = bytearray(80)
    struct.pack_into('<I', blob, 0, 80)
    struct.pack_into('<H', blob, 78, flags)
    import_rva = 0x2000 + len(blob)
    names_at = len(blob) + (len(dependencies) + 1) * 20
    descriptors, names = bytearray(), bytearray()
    for dependency in dependencies:
        descriptors.extend(struct.pack('<5I', 0, 0, 0, 0x2000 + names_at + len(names), 0))
        names.extend(dependency.encode() + b'\0')
    blob.extend(descriptors + bytes(20) + names + pins)
    data = bytearray(PE.pe(resources={
        (16, 1, 1033): PE.version(strings={'OriginalFilename': name,
            'FileVersion': '1.1.0.2', 'ProductVersion': '1.1.0.2'}),
        (24, 1, 1033): PE.manifest(level=level)}, blob=blob))
    struct.pack_into('<II', data, 0x98 + 112 + 10 * 8, 0x2000, 80)
    if dependencies:
        struct.pack_into('<II', data, 0x98 + 120, import_rva, (len(dependencies) + 1) * 20)
    return bytes(data)


class WindowsProductTests(unittest.TestCase):
    def setUp(self):
        self.fixture = FIXTURES.SetupPreparationTests()
        self.fixture.setUp()
        self.root = self.fixture.root
        (self.root / 'flutter').mkdir()
        (self.root / 'flutter/pubspec.yaml').write_text('version: 1.1.0+2\n', encoding='utf-8')
        self.gui = self.root / 'flutter/build/windows/x64/runner/Release'
        shutil.copytree(self.fixture.gui, self.gui)
        self.target = self.root / 'target/release'
        self.target.mkdir(parents=True)
        self.cargo_output(self.target / BUILD.HOST, native(BUILD.HOST, ['librustdesk.dll']))
        self.output = self.root / 'setup-validation'
        self.system = self.root / 'system32'
        self.system.mkdir()
        self.calls = []

    def tearDown(self):
        self.fixture.tearDown()

    @staticmethod
    def cargo_output(path, data):
        """Cargo's final artifact is a hard link to its file under deps/."""
        deps = path.parent / 'deps'
        deps.mkdir(parents=True, exist_ok=True)
        original = deps / (path.stem + '-0123456789abcdef' + path.suffix)
        original.write_bytes(data)
        if path.exists():
            path.unlink()
        os.link(original, path)

    def runner(self, argv, *, cwd, env, check):
        self.calls.append((argv, env.copy()))
        if argv[-1] == 'nikodesk-setup':
            self.cargo_output(self.target / BUILD.SETUP, native(BUILD.SETUP,
                pins=env['NIKODESK_SETUP_RELEASE_JSON'].encode()))
        if argv[-1] == 'nikodesk-installer':
            path = self.target / 'rustdesk-portable-packer.exe'
            self.cargo_output(path, PE.pe(resources={
                (16, 1, 1033): PE.version(strings={'FileDescription': 'NikoDesk Installation Assistant'}),
                (24, 1, 1033): PE.manifest()},
                blob=Path(env['NIKODESK_INSTALLER_PAYLOAD']).read_bytes()))
        return subprocess.CompletedProcess(argv, 0)

    def build(self, runner=None, output=None, mode=BUILD.VALIDATION_MODE, reuse_client=False):
        with patch.object(BUILD, 'ROOT', self.root), \
             patch.object(BUILD, 'windows_tools', return_value=('fixture/rc.exe', self.system)), \
             patch.object(BUILD.subprocess, 'run', side_effect=runner or self.runner), \
             patch.dict(os.environ, {}, clear=True):
            return BUILD.build('1.1.0', 2, output or self.output, mode, reuse_client)

    def test_real_static_gate_build_order_closure_and_complete_archive(self):
        report = self.build()
        self.assertEqual([call[0][-1] for call in self.calls], ['nikodesk-host', '2', 'nikodesk-setup', 'nikodesk-installer'])
        self.assertNotIn('NIKODESK_SETUP_RELEASE_JSON', self.calls[0][1])
        self.assertNotIn('NIKODESK_SETUP_RELEASE_JSON', self.calls[1][1])
        document = json.loads(self.calls[2][1]['NIKODESK_SETUP_RELEASE_JSON'])
        self.assertEqual(set(document['service_payload']['files']), {BUILD.HOST, 'librustdesk.dll'})
        self.assertTrue(report['compiled_release_bytes_present'])
        self.assertFalse(report['installation_verified'])
        self.assertFalse(report['publisher_authentication_verified'])
        self.assertTrue(self.output.with_suffix('.zip').is_file())
        self.assertTrue(self.output.with_suffix('.exe').is_file())
        self.assertTrue(report['installer_bootstrap']['complete_payload_verified'])
        self.assertNotIn('NIKODESK_SETUP_RELEASE_JSON', self.calls[3][1])
        self.assertEqual((self.output / 'librustdesk.dll').read_bytes(), self.fixture.files['librustdesk.dll'])

    def test_setup_can_be_built_from_the_client_bundle_already_packaged(self):
        report = self.build(reuse_client=True)
        self.assertEqual([call[0][-1] for call in self.calls], ['nikodesk-host', 'nikodesk-setup', 'nikodesk-installer'])
        self.assertTrue(report['installer_bootstrap']['complete_payload_verified'])
        with patch.object(BUILD, 'windows_tools', return_value=('fixture/rc.exe', self.system)), \
             self.assertRaisesRegex(ValueError, 'Only a setup build'):
            BUILD.build('1.1.0', 2, reuse_client=True)

    def test_system_modules_are_identified_without_reading_their_resources(self):
        # winspool.drv is what a binary that can print imports; its resources
        # are Windows' own and are not held to NikoDesk's limits.
        oversized = PE.pe(dll=True, resources={(10, 'SYSTEM', 1033): bytes(2 * 1024 * 1024)})
        with self.assertRaisesRegex(ValueError, 'Excessive PE resource size'):
            BUILD.PACKAGE.PE(oversized, dll=True)
        (self.system / 'winspool.drv').write_bytes(oversized)
        self.cargo_output(self.target / BUILD.HOST, native(BUILD.HOST, ['WINSPOOL.DRV']))
        report = self.build()
        self.assertEqual(report['service_system_imports'], ['winspool.drv'])
        (self.system / 'winspool.drv').write_bytes(PE.pe(dll=True, machine=0xaa64))
        with self.assertRaisesRegex(ValueError, 'winspool.drv: Expected x64 PE DLL'):
            self.build(output=self.root / 'setup-arm')

    def test_pins_absent_from_setup_fails_before_any_archive_report(self):
        def runner(argv, **kwargs):
            self.runner(argv, **kwargs)
            if argv[-1] == 'nikodesk-setup':
                (self.target / BUILD.SETUP).write_bytes(native(BUILD.SETUP))
        with self.assertRaisesRegex(ValueError, 'exact compiled release pins'):
            self.build(runner)
        self.assertFalse(self.output.with_suffix('.zip').exists())
        self.assertFalse(self.output.with_suffix('.json').exists())

    def test_setup_dependency_cannot_use_unpinned_gui_dll_or_missing_dll(self):
        for dependency in ('flutter_windows.dll', 'missing.dll'):
            def runner(argv, **kwargs):
                self.runner(argv, **kwargs)
                if argv[-1] == 'nikodesk-setup':
                    (self.target / BUILD.SETUP).write_bytes(native(BUILD.SETUP, [dependency],
                        pins=kwargs['env']['NIKODESK_SETUP_RELEASE_JSON'].encode()))
            output = self.root / ('setup-' + dependency)
            with self.subTest(dependency=dependency), self.assertRaises(ValueError):
                self.build(runner, output)
            self.assertFalse(output.with_suffix('.zip').exists())

    def test_setup_compile_must_not_replace_original_gui_or_service(self):
        def runner(argv, **kwargs):
            self.runner(argv, **kwargs)
            if argv[-1] == 'nikodesk-setup':
                path = self.output / 'librustdesk.dll'
                path.chmod(stat.S_IRUSR | stat.S_IWUSR)
                path.write_bytes(PE.pe(dll=True, blob=b'different output'))
        with self.assertRaisesRegex(ValueError, 'Frozen GUI/service changed'):
            self.build(runner)
        self.assertFalse(self.output.with_suffix('.zip').exists())

    def test_failed_host_does_not_build_gui_setup_or_emit_success(self):
        def runner(argv, **kwargs):
            self.calls.append(argv)
            raise subprocess.CalledProcessError(101, argv)
        with self.assertRaises(subprocess.CalledProcessError):
            self.build(runner)
        self.assertEqual(len(self.calls), 1)
        self.assertFalse(self.output.exists())

    def test_manifest_cannot_elevate_on_double_click_or_weaken_pre_main_imports(self):
        for data in (native(BUILD.HOST, level='requireAdministrator'),
                     native(BUILD.HOST, flags=0), native(BUILD.SETUP)):
            with self.subTest(data_sha=BUILD.hashlib.sha256(data).hexdigest()), self.assertRaises(ValueError):
                BUILD.native_exe(data, (1, 1, 0, 2), BUILD.HOST)
        BUILD.native_exe(native(BUILD.HOST), (1, 1, 0, 2), BUILD.HOST)

    def test_service_dependency_missing_from_gui_and_system_refuses(self):
        (self.target / BUILD.HOST).write_bytes(native(BUILD.HOST, ['missing.dll']))
        with self.assertRaisesRegex(ValueError, 'Missing HOST dependency'):
            self.build()
        self.assertFalse(self.output.exists())

    def test_delay_imports_are_copied_as_dependencies_and_unsafe_names_refuse(self):
        data = bytearray(PE.pe(dll=True, blob=struct.pack('<8I', 1, 0x2040, 0, 0, 0, 0, 0, 0)
                             + bytes(32) + b'late.dll\0'))
        struct.pack_into('<II', data, 0x98 + 112 + 13 * 8, 0x2000, 64)
        self.assertEqual(BUILD.import_names(bytes(data), dll=True), {'late.dll'})
        with self.assertRaises(ValueError):
            BUILD.import_names(native(BUILD.HOST, ['../bad.dll']))

    def test_product_version_and_existing_output_refuse_before_build(self):
        (self.root / 'flutter/pubspec.yaml').write_text('version: 1.1.0+3\n', encoding='utf-8')
        with self.assertRaisesRegex(ValueError, 'snapshot pubspec'):
            self.build()
        self.assertEqual(self.calls, [])
        (self.root / 'flutter/pubspec.yaml').write_text('version: 1.1.0+2\n', encoding='utf-8')
        self.output.mkdir()
        with self.assertRaisesRegex(ValueError, 'outputs must be new'):
            self.build()
        self.assertEqual(self.calls, [])

    def test_production_signature_is_not_fabricated_by_a_mode_argument(self):
        with self.assertRaisesRegex(ValueError, 'production signing is not configured'):
            self.build(mode='signed-production')
        self.assertEqual(self.calls, [])

    def test_gui_only_preserves_original_build_without_installation_artifacts(self):
        with patch.object(BUILD, 'ROOT', self.root), \
             patch.object(BUILD, 'windows_tools', return_value=('fixture/rc.exe', self.system)), \
             patch.object(BUILD.subprocess, 'run', side_effect=self.runner), \
             patch.dict(os.environ, {'NIKODESK_SETUP_RELEASE_JSON': 'untrusted ambient input'}, clear=True):
            result = BUILD.build('1.1.0', 2)
        self.assertEqual(len(self.calls), 1)
        self.assertEqual(self.calls[0][0][2:5], ['--flutter', '--hwcodec', '--nikodesk'])
        self.assertNotIn('NIKODESK_SETUP_RELEASE_JSON', self.calls[0][1])
        self.assertFalse(result['setup_requested'])
        self.assertFalse(self.output.exists())


if __name__ == '__main__':
    unittest.main()
