import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


GENERATOR = Path(__file__).resolve().parents[1] / 'generate.py'


class NikoDeskPayloadTests(unittest.TestCase):
    def generate(self, folder, executable, output):
        return subprocess.run([
            sys.executable, str(GENERATOR), '--folder', str(folder),
            '--executable', str(executable), '--package', str(output), '--nikodesk',
        ], capture_output=True, text=True)

    def test_rejects_missing_runner_instead_of_generating_a_broken_payload(self):
        with tempfile.TemporaryDirectory(prefix='nikodesk portable ') as temporary:
            folder = Path(temporary)
            (folder / 'NikoDesk.exe').write_bytes(b'MZ-test-runner')
            output = folder / 'payload.bin'
            result = self.generate(folder, folder / 'rustdesk.exe', output)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(output.exists())

    def test_payload_launches_the_runner_that_was_actually_bundled(self):
        with tempfile.TemporaryDirectory(prefix='nikodesk portable ') as temporary:
            folder = Path(temporary)
            runner = folder / 'NikoDesk.exe'
            runner.write_bytes(b'MZ-test-runner')
            (folder / 'librustdesk.dll').write_bytes(b'MZ-test-core')
            output = folder / 'payload.bin'
            result = self.generate(folder, runner, output)
            self.assertEqual(result.returncode, 0, result.stderr)
            blob = output.read_bytes()
            self.assertIn(b'NikoDesk.exe', blob)
            self.assertIn(b'librustdesk.dll', blob)
            self.assertTrue(blob.endswith(b'rustdesk./NikoDesk.exe') or
                            blob.endswith(b'rustdesk.\\NikoDesk.exe'))


if __name__ == '__main__':
    unittest.main()
