#!/usr/bin/env python3
"""Read the shared numeric product version without overriding the pubspec."""

import argparse
import json
import os
from pathlib import Path
import re
import sys


PUBSPEC = Path(__file__).resolve().parents[2] / 'flutter' / 'pubspec.yaml'
VERSION_KEY = re.compile(r'^version[ \t]*:')
VERSION_LINE = re.compile(
    r'^version[ \t]*:[ \t]*(?:"([^"\r\n]*)"|\'([^\'\r\n]*)\'|([^#\r\n]*?))'
    r'[ \t]*(?:#.*)?$'
)
NUMERIC_VERSION = re.compile(
    r'(0|[1-9][0-9]{0,4})\.(0|[1-9][0-9]{0,4})\.(0|[1-9][0-9]{0,4})'
    r'\+([1-9][0-9]{0,4})'
)


def product_version(text):
    declarations = [line for line in text.splitlines() if VERSION_KEY.match(line)]
    if len(declarations) != 1:
        raise ValueError('pubspec must declare exactly one top-level version')
    declaration = VERSION_LINE.fullmatch(declarations[0])
    if declaration is None:
        raise ValueError('pubspec product version must be a numeric scalar')
    scalar = next(value for value in declaration.groups() if value is not None).strip()
    version = NUMERIC_VERSION.fullmatch(scalar)
    if version is None:
        raise ValueError('pubspec version must be MAJOR.MINOR.PATCH+BUILD with canonical numeric components')
    parts = tuple(int(value) for value in version.groups())
    if any(value > 65535 for value in parts):
        raise ValueError('Windows product version components and build must fit 16 bits')
    return {'version_name': '.'.join(str(value) for value in parts[:3]),
            'build_number': parts[3]}


def write_github_output(version, environment):
    if environment.get('GITHUB_ACTIONS') != 'true':
        raise ValueError('--github-output requires a GitHub Actions job')
    ref_type = environment.get('GITHUB_REF_TYPE')
    if ref_type not in ('branch', 'tag'):
        raise ValueError('GitHub Actions ref type must be branch or tag')
    if ref_type == 'tag' and environment.get('GITHUB_REF_NAME') != 'v' + version['version_name']:
        raise ValueError('release tag must match the product version in flutter/pubspec.yaml')
    output_name = environment.get('GITHUB_OUTPUT')
    if not output_name:
        raise ValueError('GitHub Actions did not provide GITHUB_OUTPUT')
    output = Path(output_name)
    if not output.is_absolute() or output.is_symlink() or not output.is_file():
        raise ValueError('GITHUB_OUTPUT must be an existing regular job output file')
    with output.open('a', encoding='utf-8', newline='\n') as stream:
        stream.write('version_name={}\nbuild_number={}\n'.format(
            version['version_name'], version['build_number']))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pubspec', type=Path, default=PUBSPEC)
    parser.add_argument('--github-output', action='store_true')
    args = parser.parse_args(argv)
    try:
        version = product_version(args.pubspec.read_text(encoding='utf-8'))
        if args.github_output:
            write_github_output(version, os.environ)
    except (OSError, UnicodeError, ValueError) as error:
        print('Product version error: {}'.format(error), file=sys.stderr)
        return 1
    print(json.dumps(version, sort_keys=True))
    return 0


if __name__ == '__main__':
    sys.exit(main())
