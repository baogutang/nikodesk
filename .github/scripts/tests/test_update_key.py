import base64
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / 'update-key.py'
WORKFLOW = SCRIPT.parents[1] / 'workflows/release.yml'


def build_step():
    """Execute the actual CI shell body with a recording Flutter substitute."""
    lines = WORKFLOW.read_text().splitlines()
    start = lines.index('      - name: Build the Flutter app')
    for index in range(start + 1, len(lines)):
        if lines[index] == '        run: |':
            body = []
            for line in lines[index + 1:]:
                if line and not line.startswith('          '):
                    break
                body.append(line)
            return textwrap.dedent('\n'.join(body))
    raise ValueError('The Flutter build step has no executable body')


class UpdateKeyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.keys = tempfile.TemporaryDirectory(prefix='niko-key-test-fixtures-')
        root = Path(cls.keys.name)
        cls.public_keys = {}
        for bits in (1024, 2048):
            private = root / ('synthetic-private-{}.pem'.format(bits))
            subprocess.run(['openssl', 'genrsa', '-out', str(private), str(bits)],
                           check=True, capture_output=True)
            if bits == 2048:
                cls.synthetic_private_key = private.read_bytes()
            cls.public_keys[bits] = subprocess.run(
                ['openssl', 'rsa', '-in', str(private), '-pubout'],
                check=True, capture_output=True).stdout

    @classmethod
    def tearDownClass(cls):
        cls.keys.cleanup()

    def setUp(self):
        self.workspace = tempfile.TemporaryDirectory(prefix='niko-update-key-test-')
        self.addCleanup(self.workspace.cleanup)
        self.root = Path(self.workspace.name)
        scripts = self.root / '.github/scripts'
        scripts.mkdir(parents=True)
        self.script = scripts / SCRIPT.name
        shutil.copyfile(SCRIPT, self.script)
        (self.root / 'res').mkdir()
        (self.root / 'flutter').mkdir()
        self.key = self.root / 'res/nikodesk-update-public.pem'
        self.calls = self.root / 'flutter-calls.jsonl'
        executables = self.root / 'test-bin'
        executables.mkdir()
        flutter = executables / 'flutter'
        flutter.write_text('#!/usr/bin/env python3\n'
                           'import json, os, sys\n'
                           'with open(os.environ["NIKO_TEST_FLUTTER_CALLS"], "a") as out:\n'
                           '    out.write(json.dumps(sys.argv[1:]) + "\\n")\n')
        flutter.chmod(0o700)
        self.environment = dict(os.environ,
            PATH=str(executables) + os.pathsep + os.environ['PATH'],
            NIKO_TEST_FLUTTER_CALLS=str(self.calls),
            PRODUCT_VERSION='1.0.7', PRODUCT_BUILD_NUMBER='16')

    def run_key(self):
        return subprocess.run([sys.executable, str(self.script)],
                              capture_output=True, text=True)

    def run_build(self):
        if self.calls.exists():
            self.calls.unlink()
        result = subprocess.run(
            ['bash', '--noprofile', '--norc', '-e', '-o', 'pipefail', '-c', build_step()],
            cwd=self.root / 'flutter', env=self.environment,
            capture_output=True, text=True)
        calls = [json.loads(line) for line in self.calls.read_text().splitlines()] \
            if self.calls.exists() else []
        return result, [call for call in calls if call[:2] == ['build', 'macos']]

    def test_absent_key_keeps_manual_download_build_usable(self):
        result, builds = self.run_build()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(builds), 1)
        self.assertIn('--dart-define=NIKODESK_UPDATE_PUBLIC_KEY_BASE64=', builds[0])

    def test_valid_key_is_pinned_byte_for_byte(self):
        self.key.write_bytes(self.public_keys[2048])
        result, builds = self.run_build()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(builds), 1)
        expected = base64.b64encode(self.public_keys[2048]).decode('ascii')
        self.assertIn('--dart-define=NIKODESK_UPDATE_PUBLIC_KEY_BASE64=' + expected,
                      builds[0])

    def test_invalid_key_stops_ci_before_flutter_build(self):
        for content in (b'not a public key', self.public_keys[1024],
                        self.synthetic_private_key, b'x' * 8193):
            with self.subTest(size=len(content)):
                self.key.write_bytes(content)
                result, builds = self.run_build()
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(builds, [])

    def test_symlink_to_valid_key_is_rejected(self):
        target = self.root / 'synthetic-public.pem'
        target.write_bytes(self.public_keys[2048])
        self.key.symlink_to(target)
        result = self.run_key()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, '')


if __name__ == '__main__':
    unittest.main()
