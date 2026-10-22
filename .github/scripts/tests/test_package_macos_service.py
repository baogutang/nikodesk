"""Service daemon package policy; synthetic bundles do not prove a real app build."""
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

SYSTEM_ONLY = ('\t/System/Library/Frameworks/Security.framework/Versions/A/Security (compatibility version 1.0.0)\n'
               '\t/usr/lib/libbsm.0.dylib (compatibility version 1.0.0)\n'
               '\t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0)\n')


class ServicePackageTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='nikodesk-service-policy-')
        self.root = Path(self.temporary.name).resolve()
        self.app = self.root / 'NikoDesk.app'
        contents = self.app / 'Contents'
        contents.mkdir(parents=True)
        (contents / 'Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': 'io.nikodesk.macos', 'CFBundleExecutable': 'NikoDesk',
            'CFBundlePackageType': 'APPL', 'CFBundleShortVersionString': '2.0.0', 'CFBundleVersion': '23'}))
        for name in ('MacOS/NikoDesk', 'Frameworks/liblibrustdesk.dylib'):
            path = contents / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b'policy-fixture')
            path.chmod(0o755)
        self.service = contents / 'MacOS/nikodesk-service'
        self.service_libraries = SYSTEM_ONLY

    def tearDown(self):
        self.temporary.cleanup()

    def add_service(self):
        self.service.write_bytes(b'service-fixture')
        self.service.chmod(0o755)

    def command(self, *args):
        if args[0] == 'file':
            return 'Mach-O 64-bit arm64 ' + ('shared library' if args[-1].endswith('.dylib') else 'executable')
        if args[0] == 'lipo':
            return 'arm64'
        if args[0] == 'otool':
            if args[-1].endswith('/nikodesk-service'):
                return args[-1] + ':\n' + self.service_libraries
            return args[-1] + ':\n' + ('\t@rpath/liblibrustdesk.dylib (compatibility version 1.0.0)\n'
                                        if args[-1].endswith('/NikoDesk') else '')
        if args[0] == 'codesign':
            return ''
        raise AssertionError(args)

    def verify(self, required=False):
        with patch.object(PACKAGE, 'command', side_effect=self.command) as commands:
            report = PACKAGE.verify_bundle(self.app, require_service=required)
        return report, [call.args for call in commands.call_args_list]

    def test_older_builds_without_the_daemon_stay_inspectable(self):
        report, _ = self.verify()
        self.assertFalse(report['privileged_service_present'])
        self.assertFalse(report['privileged_service_runtime_verified'])

    def test_a_new_build_without_the_daemon_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'requires its privileged service'):
            self.verify(True)

    def test_the_daemon_needs_its_own_signed_identifier(self):
        self.add_service()
        report, commands = self.verify(True)
        self.assertTrue(report['privileged_service_present'])
        self.assertIn(('codesign', '--verify', '--strict', '-R', '=identifier "io.nikodesk.service"', str(self.service)),
                      commands)

    def test_the_daemon_may_not_load_the_interface_or_the_core(self):
        self.add_service()
        for library in ('/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit',
                        '@rpath/liblibrustdesk.dylib', '@rpath/FlutterMacOS.framework/FlutterMacOS',
                        '/opt/homebrew/lib/libssl.3.dylib'):
            with self.subTest(library=library), self.assertRaisesRegex(ValueError, 'must not load'):
                self.service_libraries = SYSTEM_ONLY + f'\t{library} (compatibility version 1.0.0)\n'
                self.verify(True)

    def test_a_linked_daemon_is_rejected(self):
        self.service.symlink_to(self.app / 'Contents/MacOS/NikoDesk')
        with self.assertRaisesRegex(ValueError, 'ordinary bundled executable'):
            self.verify(True)

    def test_the_upstream_service_is_still_refused(self):
        upstream = self.app / 'Contents/MacOS/service'
        upstream.write_bytes(b'upstream')
        upstream.chmod(0o755)
        with self.assertRaisesRegex(ValueError, 'upstream privileged service'):
            self.verify()


if __name__ == '__main__':
    unittest.main()
