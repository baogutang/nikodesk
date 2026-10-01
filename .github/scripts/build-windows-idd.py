#!/usr/bin/env python3
"""Compile NikoDesk's own IDD with pinned official kits, without installing it."""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import platform
import shutil
import stat
import struct
import subprocess
import tempfile
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[2]
VERSION = '10.0.26100.1'
PLATFORM_VERSION = '10.0.26100.0'
PACKAGES = {
    'microsoft.windows.wdk.x64': '247b2919ae451f65ba5f1cd51c7c39730fb0fc383d607f3e8ab317fddc8a8239',
    'microsoft.windows.sdk.cpp': 'b4730a467a8f29145fc0136b2b3f626767e985f6aa6e32f1352953c38d6ff5d2',
    'microsoft.windows.sdk.cpp.x64': '7670843ddee568ca1e89b0feb36046ede6a3df5dbf5fa0106ec2eee9e8224e38',
}


def sha(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def restore(cache, destination):
    cache.mkdir(parents=True, exist_ok=True)
    evidence = []
    for package, expected in PACKAGES.items():
        archive = cache / (package + '.nupkg')
        url = f'https://api.nuget.org/v3-flatcontainer/{package}/{VERSION}/{package}.{VERSION}.nupkg'
        if not archive.exists():
            with tempfile.NamedTemporaryFile(dir=cache, delete=False) as output:
                temporary = Path(output.name)
                try:
                    with urllib.request.urlopen(url, timeout=30) as response:
                        total = 0
                        while chunk := response.read(1024 * 1024):
                            total += len(chunk)
                            if total > 512 * 1024 * 1024:
                                raise ValueError('Driver dependency exceeds download budget')
                            output.write(chunk)
                    output.close()
                    if sha(temporary) != expected:
                        raise ValueError('Official driver dependency digest mismatch')
                    temporary.replace(archive)
                finally:
                    output.close()
                    temporary.unlink(missing_ok=True)
        if archive.is_symlink() or not archive.is_file() or sha(archive) != expected:
            raise ValueError('Cached driver dependency digest mismatch')
        target = destination / package
        with zipfile.ZipFile(archive) as bundle:
            entries = bundle.infolist()
            if sum(item.file_size for item in entries) > 2 * 1024 ** 3:
                raise ValueError('Expanded driver dependency exceeds budget')
            seen = set()
            for item in entries:
                path = PurePosixPath(item.filename)
                if (path.is_absolute() or '..' in path.parts or
                        '\\' in item.filename or ':' in item.filename or
                        stat.S_ISLNK(item.external_attr >> 16)):
                    raise ValueError('Unsafe driver dependency entry')
                if not item.is_dir():
                    key = item.filename.casefold()
                    if key in seen:
                        raise ValueError('Duplicate driver dependency entry')
                    seen.add(key)
            bundle.extractall(target)
        evidence.append({'package': package, 'version': VERSION,
                         'url': url, 'sha256': expected})
    required = [
        'microsoft.windows.wdk.x64/build/native/Microsoft.Windows.WDK.x64.props',
        'microsoft.windows.sdk.cpp/build/Microsoft.Windows.SDK.cpp.props',
        'microsoft.windows.sdk.cpp.x64/build/native/Microsoft.Windows.SDK.cpp.x64.props',
        'microsoft.windows.wdk.x64/c/Include/wdf/umdf/2.25/wdf.h',
        f'microsoft.windows.wdk.x64/c/Include/{PLATFORM_VERSION}/um/iddcx/1.4/IddCx.h',
    ]
    if any(not (destination / item).is_file() for item in required):
        raise ValueError('Pinned kit is missing required native inputs')
    return evidence


def msbuild_path():
    installer = Path(os.environ.get('ProgramFiles(x86)', '')) / 'Microsoft Visual Studio/Installer/vswhere.exe'
    if installer.is_file():
        result = subprocess.check_output([
            str(installer), '-products', '*', '-version', '[17.0,18.0)',
            '-requires', 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64',
            '-find', 'MSBuild/**/Bin/MSBuild.exe'], text=True)
        matches = [Path(line) for line in result.splitlines() if line.strip()]
        if matches:
            return matches[-1]
    value = shutil.which('msbuild.exe')
    if not value:
        raise ValueError('Visual Studio 2022 C++ MSBuild is unavailable')
    return Path(value)


def build(kit, output, compiler, dependencies):
    if os.name != 'nt' or platform.machine().lower() not in ('amd64', 'x86_64'):
        raise ValueError('The full driver build requires native Windows x64')
    output.mkdir(parents=True, exist_ok=False)
    source = ROOT / 'libs/nikodesk_idd'
    project = source / 'NikoDeskIddDriver.vcxproj'
    sources = {path.name: sha(path) for path in source.iterdir()
               if path.is_file() and path.suffix in ('.h', '.cpp', '.inf', '.vcxproj')}
    command = [str(compiler), str(project), '/m', '/t:Build',
               '/p:Configuration=Release', '/p:Platform=x64', '/p:SignMode=Off',
               '/p:EnableInf2Cat=false', '/p:WindowsTargetPlatformVersion=' + PLATFORM_VERSION,
               '/p:TargetPlatformVersion=' + PLATFORM_VERSION,
               '/p:NikoDriverKitRoot=' + str(kit),
               '/p:OutDir=' + str(output) + '\\',
               '/p:IntDir=' + str(kit / 'intermediate') + '\\']
    (output / 'build-command.json').write_text(json.dumps(command, indent=2) + '\n')
    with (output / 'msbuild.log').open('w', encoding='utf-8') as log:
        result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT)
    if result.returncode:
        raise ValueError(f'MSBuild failed with exit {result.returncode}; see msbuild.log')
    binary = output / 'NikoDeskIddDriver.dll'
    with binary.open('rb') as stream:
        header = stream.read(64)
        if len(header) != 64 or header[:2] != b'MZ':
            raise ValueError('Expected native driver DLL was not produced')
        stream.seek(struct.unpack_from('<I', header, 60)[0])
        pe = stream.read(24)
    if len(pe) != 24 or pe[:4] != b'PE\0\0' or struct.unpack_from('<H', pe, 4)[0] != 0x8664 or not struct.unpack_from('<H', pe, 22)[0] & 0x2000:
        raise ValueError('Driver output is not an x64 DLL')
    if any(sha(source / name) != digest for name, digest in sources.items()):
        raise ValueError('Driver source changed during compilation')
    for name in ('NikoDeskIddDriver.inf', 'LICENSE', 'NOTICE', 'upstream.json'):
        shutil.copyfile(source / name, output / name)
    report = {'scope': 'Unsigned MSBuild/WPP/DLL source validation only',
              'installed': False, 'production_signed': False,
              'dependencies': dependencies, 'source_sha256': sources,
              'outputs': {name: sha(output / name) for name in
                          ('NikoDeskIddDriver.dll', 'NikoDeskIddDriver.inf', 'LICENSE', 'NOTICE', 'upstream.json')}}
    (output / 'build-evidence.json').write_text(json.dumps(report, indent=2) + '\n')
    print('Native driver compilation completed. This unsigned DLL is not an installable driver package.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cache', type=Path, default=ROOT / '.tools/windows-idd-kit' / VERSION)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--msbuild', type=Path)
    parser.add_argument('--restore-only', action='store_true')
    options = parser.parse_args()
    if not options.restore_only and (os.name != 'nt' or not options.output):
        parser.error('A native Windows build and --output are required; --restore-only validates dependencies on other hosts')
    cache = options.cache.resolve()
    cache.mkdir(parents=True, exist_ok=True)
    compiler = None if options.restore_only else (options.msbuild or msbuild_path())
    with tempfile.TemporaryDirectory(prefix='idd-build-', dir=cache) as temporary:
        kit = Path(temporary)
        dependencies = restore(cache, kit)
        if options.restore_only:
            print(json.dumps({'restored': len(dependencies), 'native_build_executed': False, 'dependencies': dependencies}, indent=2))
        else:
            build(kit, options.output.resolve(), compiler, dependencies)


if __name__ == '__main__':
    main()
