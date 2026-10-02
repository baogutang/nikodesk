#!/usr/bin/env python3
"""Fetch the signed Amyuni virtual-display driver that upstream RustDesk ships.

The archive and every bundled file are pinned by SHA-256 in
res/windows-display-driver.json. Only pinned files are written, into
<destination>/usbmmidd_v2, the directory upstream's installer reads beside the
executable. --inspect prints the hashes of whatever the URL serves, without
writing anything, so a reviewer can record or re-check the pin.
"""

import argparse
import hashlib
import io
import json
from pathlib import Path
import sys
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[2]
PIN = ROOT / 'res/windows-display-driver.json'
MAX_ARCHIVE = 8 * 1024 * 1024
MAX_FILE = 8 * 1024 * 1024
FOLDER = 'usbmmidd_v2'


def download(url):
    if not url.startswith('https://github.com/rustdesk-org/rdev/releases/download/'):
        raise ValueError('The driver may only come from the upstream release location')
    with urllib.request.urlopen(url, timeout=60) as response:
        data = response.read(MAX_ARCHIVE + 1)
    if len(data) > MAX_ARCHIVE:
        raise ValueError('Driver archive is larger than expected')
    return data


def members(data):
    result = {}
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        for info in archive.infolist():
            if info.is_dir():
                continue
            name = info.filename.replace('\\', '/')
            if (name.startswith('/') or '..' in name.split('/') or info.file_size > MAX_FILE
                    or name in result):
                raise ValueError('Unsafe driver archive entry: ' + name)
            result[name] = archive.read(info)
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--inspect', action='store_true')
    parser.add_argument('--destination', type=Path)
    args = parser.parse_args(argv)
    pin = json.loads(PIN.read_text(encoding='utf-8'))
    try:
        data = download(pin['url'])
        digest = hashlib.sha256(data).hexdigest()
        files = members(data)
        if args.inspect:
            print(json.dumps({'archive_sha256': digest, 'archive_size': len(data),
                              'files': {name: {'sha256': hashlib.sha256(content).hexdigest(),
                                               'size': len(content)}
                                        for name, content in sorted(files.items())}}, indent=2))
            return 0
        if not args.destination:
            raise ValueError('--destination is required')
        if not pin.get('archive_sha256') or not pin.get('files'):
            raise ValueError('The driver is not pinned yet; record the --inspect output first')
        if digest != pin['archive_sha256'] or len(data) != pin['archive_size']:
            raise ValueError('Driver archive differs from its pin')
        target = args.destination / FOLDER
        if target.exists():
            # A rebuild of the same bundle finds its own earlier copy.
            present = {path.relative_to(target).as_posix():
                       hashlib.sha256(path.read_bytes()).hexdigest()
                       for path in target.rglob('*') if path.is_file()}
            if present != pin['files']:
                raise ValueError('An existing driver directory differs from the pin')
            print('Pinned driver files already present in {}'.format(target))
            return 0
        for name, expected in pin['files'].items():
            content = files.get(FOLDER + '/' + name)
            if content is None or hashlib.sha256(content).hexdigest() != expected:
                raise ValueError('Driver file differs from its pin: ' + name)
            path = target / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(content)
        print('Bundled {} pinned driver files into {}'.format(len(pin['files']), target))
    except (OSError, ValueError, KeyError, zipfile.BadZipFile) as error:
        parser.exit(1, 'Display driver fetch failed: {}\n'.format(error))
    return 0


if __name__ == '__main__':
    sys.exit(main())
