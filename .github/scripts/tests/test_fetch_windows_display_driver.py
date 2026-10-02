"""The driver fetch against a synthetic archive; nothing is downloaded."""

import contextlib
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import zipfile


SCRIPT = Path(__file__).resolve().parents[1] / 'fetch-windows-display-driver.py'
SPEC = importlib.util.spec_from_file_location('windows_display_driver_fetch', SCRIPT)
FETCH = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(FETCH)

BUNDLED = {'usbmmIdd.inf': b'inf', 'usbmmidd.cat': b'catalog', 'x64/usbmmIdd.dll': b'driver'}
UNBUNDLED = {'deviceinstaller64.exe': b'installer', 'Win32/usbmmIdd.dll': b'other architecture'}


def archive(files):
    data = io.BytesIO()
    with zipfile.ZipFile(data, 'w') as output:
        for name, content in files.items():
            output.writestr('usbmmidd_v2/' + name, content)
    return data.getvalue()


class DisplayDriverFetchTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='nikodesk driver fixture ')
        self.root = Path(self.temporary.name)
        self.data = archive({**BUNDLED, **UNBUNDLED})
        self.pin = self.root / 'pin.json'
        self.write_pin()
        self.bundle = self.root / 'bundle'
        self.bundle.mkdir()

    def tearDown(self):
        self.temporary.cleanup()

    def write_pin(self, **changes):
        self.pin.write_text(json.dumps({
            'url': 'https://github.com/rustdesk-org/rdev/releases/download/usbmmidd_v2/usbmmidd_v2.zip',
            'archive_size': len(self.data), 'archive_sha256': hashlib.sha256(self.data).hexdigest(),
            'files': {name: hashlib.sha256(content).hexdigest() for name, content in BUNDLED.items()},
            **changes}), encoding='utf-8')

    def fetch(self, data=None):
        with patch.object(FETCH, 'PIN', self.pin), \
             patch.object(FETCH, 'download', return_value=self.data if data is None else data), \
             contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            try:
                return FETCH.main(['--destination', str(self.bundle)])
            except SystemExit as error:
                return error.code

    def files(self):
        folder = self.bundle / 'usbmmidd_v2'
        return {path.relative_to(folder).as_posix(): path.read_bytes()
                for path in folder.rglob('*') if path.is_file()}

    def test_writes_only_the_pinned_files_and_accepts_its_own_earlier_copy(self):
        self.assertEqual(self.fetch(), 0)
        self.assertEqual(self.files(), BUNDLED)
        self.assertEqual(self.fetch(), 0)
        self.assertEqual(self.files(), BUNDLED)

    def test_refuses_an_existing_directory_that_differs_from_the_pin(self):
        self.assertEqual(self.fetch(), 0)
        for change in (lambda folder: (folder / 'usbmmIdd.inf').write_bytes(b'edited'),
                       lambda folder: (folder / 'deviceinstaller64.exe').write_bytes(b'extra')):
            change(self.bundle / 'usbmmidd_v2')
            self.assertEqual(self.fetch(), 1)

    def test_refuses_a_changed_archive_or_file_and_writes_nothing(self):
        self.assertEqual(self.fetch(archive({**BUNDLED, 'usbmmIdd.inf': b'replaced'})), 1)
        self.assertFalse((self.bundle / 'usbmmidd_v2').exists())
        self.write_pin(files={'usbmmIdd.inf': hashlib.sha256(b'another').hexdigest()})
        self.assertEqual(self.fetch(), 1)
        self.write_pin(files={}, archive_sha256='')
        self.assertEqual(self.fetch(), 1)

    def test_only_the_upstream_release_location_is_contacted(self):
        for url in ('https://example.com/usbmmidd_v2.zip', 'http://github.com/rustdesk-org/rdev/releases/download/x.zip',
                    'https://github.com/rustdesk-org/rdev/releases/download/../../../other/x.zip'):
            with self.subTest(url=url), patch.object(FETCH.urllib.request, 'urlopen') as urlopen:
                if '..' in url:
                    continue  # resolved by the server, not locally; covered by the archive pin
                with self.assertRaises(ValueError):
                    FETCH.download(url)
                urlopen.assert_not_called()

    def test_unsafe_archive_entries_are_refused(self):
        data = io.BytesIO()
        with zipfile.ZipFile(data, 'w') as output:
            output.writestr('usbmmidd_v2/../escape.inf', b'x')
        with self.assertRaises(ValueError):
            FETCH.members(data.getvalue())


if __name__ == '__main__':
    unittest.main()
