"""Helper package policy boundaries; synthetic bundles do not prove a real app build."""
import importlib.util
import plistlib
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('package_macos', SCRIPTS / 'package-macos.py')
PACKAGE = importlib.util.module_from_spec(spec)
spec.loader.exec_module(PACKAGE)
spec = importlib.util.spec_from_file_location('build_watchdog', SCRIPTS / 'build-macos-privacy-watchdog.py')
BUILD = importlib.util.module_from_spec(spec)
spec.loader.exec_module(BUILD)


class WatchdogPackageTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='nikodesk-package-policy-')
        self.root = Path(self.temporary.name).resolve()
        self.app = self.root / 'NikoDesk.app'
        contents = self.app / 'Contents'
        contents.mkdir(parents=True)
        (contents / 'Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier':'io.nikodesk.macos', 'CFBundleExecutable':'NikoDesk',
            'CFBundlePackageType':'APPL', 'CFBundleShortVersionString':'1.1.0', 'CFBundleVersion':'2'}))
        for name in ('MacOS/NikoDesk','Frameworks/liblibrustdesk.dylib'):
            path = contents / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b'policy-fixture'); path.chmod(0o755)
        self.helper = contents / 'Helpers/NikoDeskPrivacyWatchdog'

    def tearDown(self):
        self.temporary.cleanup()

    def helper_bytes(self, data=b'nikodesk-privacy-watchdog-v1-production'):
        self.helper.parent.mkdir(exist_ok=True)
        self.helper.write_bytes(data); self.helper.chmod(0o755)

    def command(self, *args):
        # Native/signature behavior is covered separately by compiled binaries;
        # this policy fixture only models the verifier's external tool results.
        if args[0] == 'file':
            return 'Mach-O 64-bit arm64 ' + ('shared library' if args[-1].endswith('.dylib') else 'executable')
        if args[0] == 'lipo': return 'arm64'
        if args[0] == 'otool':
            return args[-1]+':\n'+ ('\t@rpath/liblibrustdesk.dylib (compatibility version 1.0.0)\n' if args[-1].endswith('/NikoDesk') else '')
        if args[0] == 'codesign': return ''
        raise AssertionError(args)

    def verify(self, required=False):
        with patch.object(PACKAGE, 'command', side_effect=self.command) as commands:
            report = PACKAGE.verify_bundle(self.app, required)
        return report, [call.args for call in commands.call_args_list]

    def test_historical_without_helper_reports_missing_and_unverified_runtime(self):
        report, _ = self.verify()
        self.assertFalse(report['privacy_watchdog_present'])
        self.assertIsNone(report['privacy_watchdog_protocol_version'])
        self.assertFalse(report['privacy_gamma_recovery_runtime_verified'])

    def test_new_build_missing_helper_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'requires its independent'):
            self.verify(True)

    def test_production_helper_requires_identity_and_outer_resource_seal(self):
        self.helper_bytes()
        report, commands = self.verify(True)
        self.assertTrue(report['privacy_watchdog_present'])
        self.assertEqual(report['privacy_watchdog_protocol_version'], 1)
        self.assertIn(('codesign','--verify','--strict','-R','=identifier "io.nikodesk.privacy-watchdog"',str(self.helper)), commands)
        self.assertIn(('codesign','--verify','--deep','--strict',str(self.app)), commands)

    def test_fake_provider_or_missing_production_marker_is_rejected(self):
        for data in (b'nikodesk-privacy-watchdog-v1-test-provider',
                     b'nikodesk-privacy-watchdog-v1-production nikodesk-privacy-watchdog-v1-test-provider', b'other'):
            with self.subTest(data=data), self.assertRaisesRegex(ValueError, 'production protocol/provider'):
                self.helper_bytes(data); self.verify(True)

    def test_existing_and_dangling_helper_symlinks_are_rejected_even_for_history(self):
        self.helper.parent.mkdir()
        for target in (self.app / 'Contents/MacOS/NikoDesk', self.root / 'missing'):
            with self.subTest(target=target), self.assertRaisesRegex(ValueError, 'ordinary bundled binary'):
                self.helper.symlink_to(target); self.verify()
            self.helper.unlink()

    def test_helper_signature_failure_is_not_suppressed(self):
        self.helper_bytes()
        import subprocess
        with patch.object(PACKAGE, 'command', side_effect=subprocess.CalledProcessError(1, ['codesign'])):
            with self.assertRaises(subprocess.CalledProcessError):
                PACKAGE.verify_bundle(self.app, True)

    def test_compiler_rejects_non_niko_bundle_before_invoking_compiler(self):
        (self.app / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'com.carriez.rustdesk'}))
        with patch.object(BUILD.subprocess, 'check_output') as command:
            with self.assertRaisesRegex(ValueError, 'only packaged in a NikoDesk'):
                BUILD.build(self.app, 'arm64')
            command.assert_not_called()

    def test_compiler_rejects_redirected_helper_directory(self):
        outside = self.root / 'outside'; outside.mkdir()
        self.helper.parent.symlink_to(outside, target_is_directory=True)
        with patch.object(BUILD.subprocess, 'check_output', return_value='/synthetic-sdk'):
            with self.assertRaisesRegex(ValueError, 'inside the app bundle'):
                BUILD.build(self.app, 'arm64')
        self.assertEqual(list(outside.iterdir()), [])


if __name__ == '__main__': unittest.main()
