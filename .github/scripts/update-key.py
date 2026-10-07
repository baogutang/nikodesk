#!/usr/bin/env python3
"""Return the source-controlled public update key for Flutter's compile-time pin."""
import base64
from pathlib import Path
import re
import subprocess

key = Path(__file__).resolve().parents[2] / 'res/nikodesk-update-public.pem'
if key.exists():
    pem = key.read_bytes()
    if key.is_symlink() or len(pem) > 8192 or b'PRIVATE KEY' in pem:
        raise SystemExit('Expected a regular public key file')
    result = subprocess.run(['openssl', 'rsa', '-pubin', '-in', str(key), '-text', '-noout'],
                            check=True, capture_output=True, text=True)
    size = re.search(r'(?:Public-Key|RSA Public-Key): \((\d+) bit\)', result.stdout)
    if not size or not 2048 <= int(size[1]) <= 8192:
        raise SystemExit('Expected a 2048 to 8192 bit RSA publisher public key')
    print(base64.b64encode(pem).decode('ascii'))
else:
    # Local and fork builds remain usable, with manual downloads only.
    print('')
