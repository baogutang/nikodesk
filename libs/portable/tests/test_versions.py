import importlib.util
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


PORTABLE = Path(__file__).resolve().parents[1]
REPO = PORTABLE.parents[1]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


BUILD = load('niko_windows_build', REPO / 'build.py')
GENERATOR = load('niko_portable_generator', PORTABLE / 'generate.py')


class ProductVersionTests(unittest.TestCase):
    def test_flutter_and_portable_receive_the_same_product_and_license_record(self):
        original = os.getcwd()
        # Windows cannot delete the working directory, so return to the original
        # one before the temporary directory is cleaned up.
        with tempfile.TemporaryDirectory() as temporary:
            try:
                root = Path(temporary)
                bundle = root / 'flutter/build/windows/x64/runner/Release'
                bundle.mkdir(parents=True)
                (root / 'libs/portable').mkdir(parents=True)
                (root / 'target/release/deps').mkdir(parents=True)
                (root / 'target/release/deps/dylib_virtual_display.dll').write_bytes(b'fixture')
                (root / 'target/release/rustdesk-portable-packer.exe').write_bytes(b'fixture')
                (root / 'LICENCE').write_text('license fixture')
                (root / 'libs/nikodesk_cpal').mkdir()
                for notice in ('LICENSE', 'NIKODESK-PROVENANCE.md', 'NIKODESK-PROVENANCE.json'):
                    (root / 'libs/nikodesk_cpal' / notice).write_text('notice fixture')
                (root / 'Cargo.toml').write_text('[package]\nversion = "1.5.0"\n')
                os.chdir(root)
                with patch.object(BUILD, 'skip_cargo', True), \
                     patch.object(BUILD, 'win_arch', 'x64', create=True), \
                     patch.object(BUILD, 'flutter_build_dir_2', 'flutter/build/windows/x64/runner/Release'), \
                     patch.object(BUILD, 'system2') as commands, \
                     patch.object(BUILD.subprocess, 'run') as run, \
                     patch.dict(os.environ, {'NIKODESK_SOURCE_REVISION': 'source-fixture', 'NIKODESK_SOURCE_DIRTY': 'True'}):
                    BUILD.build_flutter_windows('1.1.0', 'flutter,hwcodec,nikodesk', False, '2')
                    flutter_command = commands.call_args_list[0].args[0]
                    self.assertIn('--build-name 1.1.0 --build-number 2', flutter_command)
                    generator_command = run.call_args_list[-1].args[0]
                    self.assertIn('--nikodesk', generator_command)
                    self.assertEqual(generator_command[-4:], ['--product-version', '1.1.0', '--build-number', '2'])
                    # The pinned display driver joins the bundle before it is packed.
                    driver_command = run.call_args_list[0].args[0]
                    self.assertEqual(driver_command[1:], ['.github/scripts/fetch-windows-display-driver.py',
                                                          '--destination', 'flutter/build/windows/x64/runner/Release'])
                self.assertEqual((bundle / 'data/NikoDesk/licenses/cpal/LICENSE').read_text(), 'notice fixture')
                self.assertEqual((bundle / 'NikoDesk-LICENCE.txt').read_text(), 'license fixture')
                self.assertIn('Product 1.1.0+2; upstream native/protocol 1.5.0', (bundle / 'NikoDesk-source.txt').read_text())
                self.assertTrue((root / 'NikoDesk-windows-x64.exe').is_file())
                self.assertFalse((root / 'rustdesk-1.5.0-install.exe').exists())
            finally:
                os.chdir(original)

    def test_product_default_is_flutter_version_and_keeps_native_manifest_untouched(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'flutter').mkdir()
            (root / 'flutter/pubspec.yaml').write_text('version: 1.1.0+2\n')
            native = root / 'Cargo.toml'
            native.write_text('[package]\nversion = "1.5.0"\n')
            with patch.object(BUILD, 'REPO_ROOT', str(root)):
                self.assertEqual(BUILD.get_nikodesk_windows_version(), ('1.1.0', '2'))
            self.assertIn('1.5.0', native.read_text())

    def test_explicit_product_version_reaches_both_build_resolvers(self):
        self.assertEqual(BUILD.get_nikodesk_windows_version('1.2.3', 9), ('1.2.3', '9'))
        self.assertEqual(GENERATOR.product_version('1.2.3', 9), ('1.2.3', '9'))

    def test_invalid_versions_cannot_truncate_resources_or_inject_build_commands(self):
        for name, number in [('1.1.0;echo x', '2'), ('1.1.0', '2&echo x'),
                             ('65536.0.0', '2'), ('1.1.0', '65536'),
                             ('1.1.0', '0'), ('1.1', '2'), ('1.1.0-beta', '2')]:
            for resolve in (BUILD.get_nikodesk_windows_version, GENERATOR.product_version):
                with self.subTest(name=name, number=number, resolver=resolve.__name__), self.assertRaises(ValueError):
                    resolve(name, number)

    def test_packer_cargo_receives_product_version_without_changing_protocol(self):
        with patch.object(GENERATOR.subprocess, 'run') as run:
            GENERATOR.build_portable(str(PORTABLE), None, True, '1.1.0', '2')
            args, kwargs = run.call_args
            self.assertEqual(args[0], ['cargo', 'build', '--locked', '--release', '--features', 'nikodesk'])
            self.assertEqual(kwargs['env']['NIKODESK_PRODUCT_VERSION'], '1.1.0')
            self.assertEqual(kwargs['env']['NIKODESK_BUILD_NUMBER'], '2')
            self.assertNotIn('CARGO_PKG_VERSION', kwargs['env'])

    def test_metadata_records_product_build_separately_from_timestamp(self):
        with tempfile.TemporaryDirectory() as temporary:
            GENERATOR.write_app_metadata(temporary, '1.1.0', '2')
            text = (Path(temporary) / 'app_metadata.toml').read_text()
            self.assertIn('product_version = "1.1.0"\n', text)
            self.assertIn('build_number = 2\n', text)
            self.assertNotIn('1.5.0', text)

    def test_feature_off_metadata_retains_only_upstream_timestamp(self):
        with tempfile.TemporaryDirectory() as temporary:
            GENERATOR.write_app_metadata(temporary)
            text = (Path(temporary) / 'app_metadata.toml').read_text()
            self.assertTrue(text.startswith('timestamp = '))
            self.assertEqual(len(text.splitlines()), 1)


if __name__ == '__main__':
    unittest.main()
