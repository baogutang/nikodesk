import base64
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location(
    'release_manifest', Path(__file__).parents[1] / 'release-manifest.py')
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class ReleaseManifestTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.keys = tempfile.TemporaryDirectory(prefix='niko-test-keys-')
        cls.private = Path(cls.keys.name) / 'test-private.pem'
        cls.public = Path(cls.keys.name) / 'test-public.pem'
        subprocess.run(['openssl', 'genrsa', '-out', str(cls.private), '2048'],
                       check=True, capture_output=True)
        subprocess.run(['openssl', 'rsa', '-in', str(cls.private), '-pubout',
                        '-out', str(cls.public)], check=True, capture_output=True)

    @classmethod
    def tearDownClass(cls):
        cls.keys.cleanup()

    def setUp(self):
        self.workspace = tempfile.TemporaryDirectory(prefix='niko-candidate-test-')
        self.addCleanup(self.workspace.cleanup)
        self.directory = Path(self.workspace.name)
        self.tag = 'v1.0.7'
        self.commit = 'a' * 40
        for name in release.PACKAGES:
            (self.directory / name).write_bytes(b'synthetic package')
        self.acceptance = {
            'tag': self.tag, 'commit': self.commit,
            'gates': {g: {'status': 'passed', 'evidence': 'synthetic-test-only'}
                      for g in release.GATES},
            'package_sha256': {n: release.checksum(self.directory / n)
                               for n in release.PACKAGES},
        }
        (self.directory / 'build-provenance.json').write_text(json.dumps({
            'tag': self.tag, 'commit': self.commit, 'workflow_run': 'test-only',
            'publisher_public_key_sha256': release.checksum(self.public)}))
        self.sign()

    def sign(self):
        (self.directory / 'release-acceptance.json').write_text(json.dumps(self.acceptance))
        release.create(self.directory, self.tag)
        signature = subprocess.run(['openssl', 'dgst', '-sha256', '-sign',
                                    str(self.private), str(self.directory / 'SHA256SUMS')],
                                   check=True, capture_output=True).stdout
        (self.directory / 'SHA256SUMS.sig').write_bytes(base64.b64encode(signature))

    def verify(self):
        release.verify(self.directory, self.tag, self.public, self.commit)

    def test_candidate_without_the_current_publisher_pin_cannot_be_promoted(self):
        path = self.directory / 'build-provenance.json'
        for pin in (None, '0' * 64):
            record = json.loads(path.read_text())
            record['publisher_public_key_sha256'] = pin
            path.write_text(json.dumps(record))
            self.sign()
            with self.assertRaisesRegex(ValueError, 'trusted publisher key'):
                self.verify()

    def test_exact_signed_and_accepted_bytes_pass(self):
        self.verify()

    def test_modified_package_or_unsigned_extra_file_fails(self):
        package = self.directory / next(iter(release.PACKAGES))
        package.write_bytes(b'replaced package')
        with self.assertRaises(ValueError):
            self.verify()
        package.write_bytes(b'synthetic package')
        (self.directory / 'extra.exe').write_bytes(b'unsigned')
        with self.assertRaises(ValueError):
            self.verify()

    def test_unknown_gate_blocks_even_valid_publisher_signature(self):
        for status in ('untested', 'failed', 'waived', ''):
            self.acceptance['gates']['privacy-physical-recovery']['status'] = status
            self.sign()
            with self.assertRaisesRegex(ValueError, 'gate incomplete'):
                self.verify()

    def test_acceptance_must_bind_exact_source_and_package(self):
        self.acceptance['commit'] = 'b' * 40
        self.sign()
        with self.assertRaisesRegex(ValueError, 'tag and commit'):
            self.verify()
        self.acceptance['commit'] = self.commit
        self.acceptance['package_sha256']['NikoDesk-macos-arm64.zip'] = '0' * 64
        self.sign()
        with self.assertRaisesRegex(ValueError, 'exact candidate bytes'):
            self.verify()

    def test_resigned_setup_packages_still_require_fresh_acceptance(self):
        for name in ('NikoDesk-windows-x64-setup-validation.exe',
                     'NikoDesk-windows-x64-setup-validation.zip'):
            with self.subTest(package=name):
                package = self.directory / name
                package.write_bytes(b'changed installer after acceptance')
                self.sign()
                with self.assertRaisesRegex(ValueError, 'exact candidate bytes'):
                    self.verify()
                self.acceptance['package_sha256'][name] = release.checksum(package)
                self.sign()
                self.verify()

    def test_unattended_install_requires_its_own_completed_gate(self):
        gate = self.acceptance['gates'].pop('windows-unattended-install')
        self.sign()
        with self.assertRaisesRegex(ValueError, 'windows-unattended-install'):
            self.verify()
        self.acceptance['gates']['windows-unattended-install'] = gate
        gate['status'] = 'untested'
        self.sign()
        with self.assertRaisesRegex(ValueError, 'windows-unattended-install'):
            self.verify()

    def test_signed_extra_packages_are_outside_acceptance_regardless_of_case(self):
        for suffix in ('.exe', '.zip', '.dmg', '.apk', '.EXE', '.ZIP', '.DMG', '.APK'):
            with self.subTest(suffix=suffix):
                package = self.directory / ('Unaccepted' + suffix)
                try:
                    package.write_bytes(b'signed but never accepted')
                    self.sign()
                    with self.assertRaisesRegex(ValueError, 'outside the acceptance scope'):
                        self.verify()
                finally:
                    package.unlink()

    def test_duplicate_or_other_version_manifest_fails(self):
        path = self.directory / 'SHA256SUMS'
        content = path.read_text()
        path.write_text(content + content.splitlines()[1] + '\n')
        with self.assertRaisesRegex(ValueError, 'duplicate'):
            self.verify()
        path.write_text(content.replace(self.tag, 'v1.0.6'))
        with self.assertRaisesRegex(ValueError, 'version'):
            self.verify()

    def test_changed_manifest_with_recomputed_hashes_needs_publisher_signature(self):
        (self.directory / 'NikoDesk-macos-arm64.zip').write_bytes(b'replaced')
        release.create(self.directory, self.tag)
        with self.assertRaises(subprocess.CalledProcessError):
            self.verify()


if __name__ == '__main__':
    unittest.main()
