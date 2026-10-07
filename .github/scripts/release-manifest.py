#!/usr/bin/env python3
"""Create candidate checksums or verify an offline-signed, accepted release.

Private keys are deliberately not handled here. SHA256SUMS.sig contains base64
of an OpenSSL SHA-256/RSA signature over the exact SHA256SUMS bytes.
"""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile


PACKAGES = {
    'NikoDesk-macos-arm64.dmg', 'NikoDesk-macos-arm64.zip',
    'NikoDesk-windows-x64.exe', 'NikoDesk-windows-x64.zip',
    'NikoDesk-android-arm64.apk',
    'NikoDesk-windows-x64-setup-validation.exe',
    'NikoDesk-windows-x64-setup-validation.zip',
}
GATES = {
    'source-review', 'security-regression', 'macos-package-settings',
    'windows-package-settings', 'android-upgrade', 'private-network-session',
    'permissions-revocation', 'privacy-physical-recovery', 'display-and-input',
    'macos-signing-continuity', 'windows-unattended-install',
}


def checksum(path):
    with path.open('rb') as stream:
        digest = hashlib.sha256()
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def entries(directory, tag):
    manifest = directory / 'SHA256SUMS'
    if manifest.stat().st_size > 65536:
        raise ValueError('manifest exceeds size limit')
    lines = manifest.read_text(encoding='ascii').splitlines()
    if not lines or lines[0] != '# NikoDesk release ' + tag:
        raise ValueError('manifest does not bind the requested version')
    result = {}
    for line in lines[1:]:
        if not line:
            continue
        match = re.fullmatch(r'([0-9a-f]{64})  ([A-Za-z0-9][A-Za-z0-9._-]*)', line)
        if not match or match[2] in result:
            raise ValueError('invalid or duplicate manifest entry')
        result[match[2]] = match[1]
    return result


def create(directory, tag):
    files = sorted(p for p in directory.iterdir()
                   if p.name not in {'SHA256SUMS', 'SHA256SUMS.sig'})
    if not files or any(p.is_symlink() or not p.is_file() or
                        not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]*', p.name)
                        for p in files):
        raise ValueError('candidate directory must contain named regular files only')
    content = '# NikoDesk release ' + tag + '\n'
    content += ''.join('{}  {}\n'.format(checksum(p), p.name) for p in files)
    (directory / 'SHA256SUMS').write_text(content, encoding='ascii', newline='\n')


def verify(directory, tag, public_key, commit):
    hashes = entries(directory, tag)
    required = PACKAGES | {'release-acceptance.json', 'build-provenance.json'}
    if required != hashes.keys():
        raise ValueError('missing or unexpected files outside the acceptance scope')
    actual = {p.name for p in directory.iterdir()} - {'SHA256SUMS', 'SHA256SUMS.sig'}
    if actual != hashes.keys():
        raise ValueError('unsigned or missing candidate files')
    for name, digest in hashes.items():
        path = directory / name
        if path.is_symlink() or not path.is_file() or checksum(path) != digest:
            raise ValueError('candidate checksum mismatch: ' + name)
    signature = directory / 'SHA256SUMS.sig'
    if signature.stat().st_size > 4096:
        raise ValueError('signature exceeds size limit')
    raw = base64.b64decode(signature.read_bytes().strip(), validate=True)
    if not 256 <= len(raw) <= 1024:
        raise ValueError('expected an RSA signature of at least 2048 bits')
    with tempfile.TemporaryDirectory(prefix='niko-release-signature-') as temporary:
        binary = Path(temporary) / 'signature'
        binary.write_bytes(raw)
        subprocess.run(['openssl', 'dgst', '-sha256', '-verify', str(public_key),
                        '-signature', str(binary), str(directory / 'SHA256SUMS')],
                       check=True, capture_output=True)
    acceptance = json.loads((directory / 'release-acceptance.json').read_text())
    provenance = json.loads((directory / 'build-provenance.json').read_text())
    for record in (acceptance, provenance):
        if record.get('tag') != tag or record.get('commit') != commit:
            raise ValueError('evidence does not describe this tag and commit')
    if provenance.get('publisher_public_key_sha256') != checksum(public_key):
        raise ValueError('candidate was not built with the trusted publisher key')
    for gate in GATES:
        result = acceptance.get('gates', {}).get(gate, {})
        if result.get('status') != 'passed' or not result.get('evidence'):
            raise ValueError('release gate incomplete: ' + gate)
    if acceptance.get('package_sha256') != {name: hashes[name] for name in PACKAGES}:
        raise ValueError('acceptance must describe the exact candidate bytes')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['create', 'verify'])
    parser.add_argument('directory', type=Path)
    parser.add_argument('--tag', required=True)
    parser.add_argument('--public-key', type=Path)
    parser.add_argument('--commit')
    args = parser.parse_args()
    if not re.fullmatch(r'v\d+\.\d+\.\d+', args.tag):
        parser.error('expected a stable vMAJOR.MINOR.PATCH tag')
    if args.command == 'create':
        create(args.directory, args.tag)
    else:
        if not args.public_key or not re.fullmatch(r'[0-9a-f]{40}', args.commit or ''):
            parser.error('verification requires a public key and full commit SHA')
        verify(args.directory, args.tag, args.public_key, args.commit)
    print('Release manifest {} passed'.format(args.command))


if __name__ == '__main__':
    main()
