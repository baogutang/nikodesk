#!/usr/bin/env python3
"""Build the real Windows client and, explicitly requested, its local setup tree.

This never runs a product executable, elevates, installs, signs, or uploads.
The setup tree is a validation bundle initiated by its included ordinary GUI;
nikodesk-setup.exe is not a standalone, double-click installation interface.
"""

import argparse
import ctypes
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import re
import shutil
import struct
import subprocess
import sys
import zipfile


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    'windows_setup_preparation', ROOT / '.github/scripts/prepare-windows-setup.py')
PREPARE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PREPARE)
PACKAGE = PREPARE.PACKAGE
HOST, SETUP = 'nikodesk-host.exe', 'nikodesk-setup.exe'
VALIDATION_MODE = 'reviewed-local-unsigned-validation'
FEATURES = 'flutter,hwcodec,nikodesk'


def directory_entry(pe, index):
    header = PACKAGE.unpack('<I', pe.data, 0x3c)[0]
    optional = header + 24
    count = PACKAGE.unpack('<I', pe.data, optional + 108)[0]
    size = PACKAGE.unpack('<H', pe.data, header + 20)[0]
    if count > 16 or size < 112 + count * 8:
        raise ValueError('PE directories exceed the optional header')
    if count <= index:
        return 0, 0
    return PACKAGE.unpack('<II', pe.data, optional + 112 + 8 * index)


def import_names(data, dll=False):
    """Inspect ordinary and delay imports without loading the PE image."""
    pe, names = PACKAGE.PE(data, dll=dll), set()
    optional = PACKAGE.unpack('<I', pe.data, 0x3c)[0] + 24
    image_base = PACKAGE.unpack('<Q', pe.data, optional + 24)[0]
    for index, width in ((1, 20), (13, 32)):
        rva, size = directory_entry(pe, index)
        if not rva and not size:
            continue
        if not rva or size < width or size > 1024 * 1024:
            raise ValueError('Invalid PE import directory')
        for at in range(min(size // width, 512)):
            row = PACKAGE.unpack('<' + 'I' * (width // 4), data,
                                 pe.rva_offset(rva + at * width, width))
            if not any(row):
                break
            if index == 1:
                name_rva = row[3]
            elif row[0] in (0, 1):
                name_rva = row[1] if row[0] == 1 else row[1] - image_base
            else:
                raise ValueError('Unsupported delay import attributes')
            name = bytearray()
            for offset in range(261):
                char = PACKAGE.checked(data, pe.rva_offset(name_rva + offset, 1), 1)
                if char == b'\0':
                    break
                name.extend(char)
            else:
                raise ValueError('Excessive PE import name')
            value = name.decode('ascii')
            if ('/' in value or not value.casefold().endswith('.dll') or
                    not value or PACKAGE.windows_path(value) != value.casefold()):
                raise ValueError('Unsafe PE import name')
            names.add(value.casefold())
        else:
            raise ValueError('Unterminated or excessive PE import table')
    return names


def native_exe(data, parts, name):
    pe = PACKAGE.PE(data)
    versions = [raw for key, raw in pe.resources.items() if key[0] == 16]
    manifests = [raw for key, raw in pe.resources.items() if key[:2] == (24, 1)]
    if not versions or not manifests:
        raise ValueError('Missing native executable version or default manifest')
    for raw in versions:
        node, _ = PACKAGE.version_node(raw)
        if node['key'] != 'VS_VERSION_INFO' or len(node['value']) != 52:
            raise ValueError('Invalid native executable version')
        fixed = struct.unpack('<13I', node['value'])
        numeric = lambda a, b: (a >> 16, a & 65535, b >> 16, b & 65535)
        if (fixed[0] != 0xfeef04bd or numeric(fixed[2], fixed[3]) != parts or
                numeric(fixed[4], fixed[5]) != parts):
            raise ValueError('Native executable version does not match product')
        tables = [table for block in node['children'] if block['key'] == 'StringFileInfo'
                  for table in block['children']]
        if not tables:
            raise ValueError('Missing native product strings')
        for table in tables:
            strings = {}
            for item in table['children']:
                if item['kind'] != 1 or item['key'] in strings:
                    raise ValueError('Duplicate or invalid native product strings')
                strings[item['key']] = item['value'].decode('utf-16le').rstrip('\0')
            expected = {'ProductName': 'NikoDesk', 'OriginalFilename': name,
                        'FileVersion': '.'.join(map(str, parts)),
                        'ProductVersion': '.'.join(map(str, parts))}
            if any(strings.get(key) != value for key, value in expected.items()):
                raise ValueError('Wrong native product identity')
    for raw in manifests:
        PACKAGE.ordinary_user_manifest(raw)
    rva, size = directory_entry(pe, 10)
    if not rva or size < 80:
        raise ValueError('Missing native dependent-load flags')
    offset = pe.rva_offset(rva, 80)
    declared, = PACKAGE.unpack('<I', data, offset)
    if declared < 80 or declared > size or PACKAGE.unpack('<H', data, offset + 78)[0] != 0xA00:
        raise ValueError('Native imports must restrict loader search to app/System32')


def service_payload(host, gui, output, system_directory):
    """Copy only the real HOST and its transitive app-local DLL dependencies."""
    PREPARE.ordinary_parents(output)
    output.mkdir()
    PREPARE.ordinary(host)
    root_files = {}
    for path in gui.iterdir():
        if path.suffix.casefold() == '.dll':
            PREPARE.ordinary(path)
            key = PACKAGE.windows_path(path.name)
            if key in root_files:
                raise ValueError('Duplicate root DLL spelling')
            root_files[key] = path
    queue, copied, system = [(HOST, host, False)], {}, set()
    while queue:
        name, source, dll = queue.pop()
        key = PACKAGE.windows_path(name)
        if key in copied:
            continue
        original = PREPARE.stamp(PREPARE.ordinary(source))
        record, data = PREPARE.read_file(source, original)
        PACKAGE.PE(data, dll=dll)
        copied[key] = record
        PREPARE.read_file(source, original, output / name)
        for dependency in sorted(import_names(data, dll=dll)):
            if dependency in root_files:
                path = root_files[dependency]
                queue.append((path.name, path, True))
            elif re.fullmatch(r'(api-ms-win|ext-ms-win)-[a-z0-9-]+\.dll', dependency):
                system.add(dependency)
            else:
                path = system_directory / dependency
                if not path.is_file():
                    raise ValueError('Missing HOST dependency: ' + dependency)
                # Windows system files can have WinSxS hardlinks; none are copied.
                PACKAGE.PE(path.read_bytes(), dll=True)
                system.add(dependency)
    return sorted(system)


def verify_frozen(tree, document, gui_records, parts, serialized):
    expected = {record['path']: {'sha256': record['sha256'], 'length': record['size']}
                for record in gui_records.values()}
    expected.update(document['service_payload']['files'])
    keys, observed = set(), {}
    PREPARE.ordinary_parents(tree)
    PREPARE.ordinary(tree, directory=True)
    for path in sorted(tree.rglob('*')):
        name = path.relative_to(tree).as_posix()
        key = PACKAGE.windows_path(name)
        if key in keys:
            raise ValueError('Case-insensitive setup path collision')
        keys.add(key)
        if path.is_dir():
            PREPARE.ordinary(path, directory=True)
            continue
        record, _ = PREPARE.read_file(path)
        observed[name] = record
    reserved = {'setup-release.json', 'setup-release-evidence.json', SETUP}
    if set(observed) != set(expected) | reserved:
        raise ValueError('Incomplete or extra setup bundle files')
    for name, record in expected.items():
        if observed[name] != record:
            raise ValueError('Frozen GUI/service changed after compiling setup: ' + name)
    if (tree / 'setup-release.json').read_text(encoding='utf-8') != serialized:
        raise ValueError('Release manifest differs from setup compilation input')
    runner = document['ui_runner']
    if observed[runner['name']] != {k: runner[k] for k in ('sha256', 'length')}:
        raise ValueError('GUI identity differs from native setup pin')
    for name in (HOST, SETUP):
        _, data = PREPARE.read_file(tree / name)
        native_exe(data, parts, name)
        if name == SETUP and serialized.encode('utf-8') not in data:
            raise ValueError('Setup executable lacks the exact compiled release pins')
    PACKAGE.product_exe((tree / runner['name']).read_bytes(), parts)
    return observed


def verify_setup_imports(tree, document, system_directory):
    local = {path.name.casefold(): path for path in tree.iterdir()
             if path.suffix.casefold() == '.dll'}
    pins = {name.casefold() for name in document['service_payload']['files']}
    pending, seen, system = [(tree / SETUP, False)], set(), set()
    while pending:
        path, dll = pending.pop()
        if path.name.casefold() in seen:
            continue
        seen.add(path.name.casefold())
        for name in import_names(PREPARE.read_file(path)[1], dll=dll):
            if name in local:
                if name not in pins:
                    raise ValueError('Setup app-local dependency is not fixed in the release: ' + name)
                pending.append((local[name], True))
            elif re.fullmatch(r'(api-ms-win|ext-ms-win)-[a-z0-9-]+\.dll', name):
                system.add(name)
            else:
                dependency = system_directory / name
                if not dependency.is_file():
                    raise ValueError('Missing setup dependency: ' + name)
                PACKAGE.PE(dependency.read_bytes(), dll=True)
                system.add(name)
    return sorted(system)


def archive_tree(tree, records):
    archive = tree.with_suffix('.zip')
    with zipfile.ZipFile(archive, 'x', compression=zipfile.ZIP_DEFLATED) as output:
        for name in sorted(records):
            output.write(tree / name, arcname=name)
    PACKAGE.inspect_zip(archive, {
        PACKAGE.windows_path(name): {'path': name, 'size': record['length'],
                                    'sha256': record['sha256']}
        for name, record in records.items()})
    return archive


def installer_bootstrap(tree, records, parts, env, system_directory):
    """Embed the complete fixed tree in a separate ordinary-user launcher."""
    generator = PREPARE.load('setup_portable_generator',
                            Path(__file__).resolve().parents[2] / 'libs/portable/generate.py')
    blob = tree.with_suffix('.payload.bin')
    generator.write_blob(generator.generate_md5_table(str(tree), 6), str(blob), './NikoDesk.exe')
    expected = {PACKAGE.windows_path(name): {'path': name, 'size': value['length'],
                                            'sha256': value['sha256']}
                for name, value in records.items()}
    PACKAGE.inspect_payload(PREPARE.read_file(blob)[1], expected)
    build_env = {**env, 'NIKODESK_INSTALLER_PAYLOAD': str(blob.resolve()),
                 'NIKODESK_PRODUCT_VERSION': '.'.join(map(str, parts[:3])),
                 'NIKODESK_BUILD_NUMBER': str(parts[3])}
    build_env.pop('NIKODESK_SETUP_RELEASE_JSON', None)
    # The bootstrap must start before any app-local DLLs have been extracted.
    build_env['RUSTFLAGS'] = env.get('RUSTFLAGS', '') + ' -C target-feature=+crt-static'
    packer = ROOT / 'libs/portable'
    subprocess.run(['cargo', '+1.88.0', 'build', '--locked', '--release', '--features',
                    'nikodesk-installer'], cwd=packer, env=build_env, check=True)
    source = packer / 'target/release/rustdesk-portable-packer.exe'
    _, data = PREPARE.read_file(source)
    pe = PACKAGE.product_exe(data, parts)
    for key, raw in pe.resources.items():
        if key[0] != 16:
            continue
        root, _ = PACKAGE.version_node(raw)
        tables = [table for block in root['children'] if block['key'] == 'StringFileInfo'
                  for table in block['children']]
        for table in tables:
            values = {item['key']: item['value'].decode('utf-16le').rstrip('\0')
                      for item in table['children']}
            if values.get('FileDescription') != 'NikoDesk Installation Assistant':
                raise ValueError('Wrong installer bootstrap executable identity')
    if any(key[0] == 10 and key[1] == 'RDPKG' for key in pe.resources):
        raise ValueError('Installer cannot override the fixed payload using RDPKG')
    payload = PREPARE.read_file(blob)[1]
    matches = sum(data[section['raw']:section['raw'] + section['size']].count(payload)
                  for section in pe.sections if section['flags'] & 0x40000000 and section['flags'] & 0x40)
    if matches != 1:
        raise ValueError('Complete installer payload is not embedded exactly once')
    system_imports = sorted(import_names(data))
    for name in system_imports:
        if name.startswith(('vcruntime', 'msvcp')) or name == 'ucrtbased.dll':
            raise ValueError('Installer bootstrap must use the static C/C++ runtime: ' + name)
        if re.fullmatch(r'(api-ms-win|ext-ms-win)-[a-z0-9-]+\.dll', name):
            continue
        dependency = system_directory / name
        if not dependency.is_file():
            raise ValueError('Installer bootstrap requires an unavailable DLL: ' + name)
        PACKAGE.PE(dependency.read_bytes(), dll=True)
    destination = tree.with_suffix('.exe')
    PREPARE.read_file(source, destination=destination)
    return {'path': str(destination), **PREPARE.read_file(destination)[0],
            'payload_sha256': PREPARE.read_file(blob)[0]['sha256'],
            'system_dependencies': system_imports,
            'complete_payload_verified': True, 'ordinary_user_manifest_verified': True,
            'extraction_and_gui_launch_verified': False, 'installation_verified': False}


def windows_tools():
    if sys.platform != 'win32' or platform.machine().upper() not in ('AMD64', 'X86_64'):
        raise ValueError('A native Windows x64 build is required; this is not a cross-build')
    rc = os.environ.get('NIKODESK_WINDOWS_RC') or shutil.which('rc.exe')
    if not rc:
        import winreg
        with winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE,
                           r'SOFTWARE\Microsoft\Windows Kits\Installed Roots') as key:
            kits, _ = winreg.QueryValueEx(key, 'KitsRoot10')
        candidates = [(tuple(map(int, folder.name.split('.'))), folder / 'x64/rc.exe')
                      for folder in (Path(kits) / 'bin').iterdir()
                      if re.fullmatch(r'\d+\.\d+\.\d+\.\d+', folder.name)
                      and (folder / 'x64/rc.exe').is_file()]
        rc = str(max(candidates)[1]) if candidates else None
    if not rc or not Path(rc).is_file() or Path(rc).name.casefold() != 'rc.exe':
        raise ValueError('Missing actual Windows SDK rc.exe')
    buffer = ctypes.create_unicode_buffer(32768)
    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    kernel.GetSystemDirectoryW.argtypes = [ctypes.c_wchar_p, ctypes.c_uint]
    kernel.GetSystemDirectoryW.restype = ctypes.c_uint
    length = kernel.GetSystemDirectoryW(buffer, len(buffer))
    if not 0 < length < len(buffer):
        raise OSError('Cannot read the real Windows system DLL directory')
    return rc, Path(buffer.value)


def build(version_name, build_number, output=None, trust_mode=None):
    rc, system_directory = windows_tools()
    if bool(output) != bool(trust_mode):
        raise ValueError('Setup requires both an output directory and explicit trust mode')
    if trust_mode and trust_mode != VALIDATION_MODE:
        raise ValueError('Only explicit local unsigned validation is configured; production signing is not configured')
    parts = PACKAGE.version_parts(version_name, build_number)
    version = PREPARE.VERSION.product_version((ROOT / 'flutter/pubspec.yaml').read_text(encoding='utf-8'))
    if output and (version['version_name'] != version_name or version['build_number'] != build_number):
        raise ValueError('Setup version must match the snapshot pubspec for GUI/HOST/setup')
    if os.environ.get('CARGO_TARGET_DIR') or os.environ.get('CARGO_BUILD_TARGET'):
        raise ValueError('Windows Flutter uses host target/release; unset Cargo target overrides for this build')
    if output:
        output = output.absolute()
        PREPARE.ordinary_parents(output)
        for candidate in (output, output.with_suffix('.zip'), output.with_suffix('.json'), output.with_suffix('.txt'),
                          output.with_suffix('.exe'), output.with_suffix('.payload.bin')):
            if candidate.exists() or candidate.is_symlink():
                raise ValueError('Setup outputs must be new; existing validation artifacts are preserved')
    env = {**os.environ, 'NIKODESK_BUILD_PYTHON': sys.executable,
           'NIKODESK_WINDOWS_RC': rc, 'RUSTUP_TOOLCHAIN': '1.88.0'}
    env.pop('NIKODESK_SETUP_RELEASE_JSON', None)
    cargo = ['cargo', '+1.88.0', 'build', '--locked', '--release', '--features', FEATURES]
    if output:
        subprocess.run(cargo + ['--bin', 'nikodesk-host'], cwd=ROOT, env=env, check=True)
    subprocess.run([sys.executable, str(ROOT / 'build.py'), '--flutter', '--hwcodec', '--nikodesk',
                    '--build-name', version_name, '--build-number', str(build_number)],
                   cwd=ROOT, env=env, check=True)
    if not output:
        return {'setup_requested': False, 'client_build_exit': 0, 'client_run_verified': False}
    gui = ROOT / 'flutter/build/windows/x64/runner/Release'
    gui_records = PREPARE.gui_records(gui, parts)
    service = output.parent / (output.name + '-service-input')
    system_imports = service_payload(ROOT / 'target/release' / HOST, gui, service, system_directory)
    document = PREPARE.prepare(gui, service, output, trust_mode, ROOT / 'flutter/pubspec.yaml')
    serialized = (output / 'setup-release.json').read_text(encoding='utf-8')
    subprocess.run(cargo + ['--bin', 'nikodesk-setup'], cwd=ROOT,
                   env={**env, 'NIKODESK_SETUP_RELEASE_JSON': serialized}, check=True)
    _, data = PREPARE.read_file(ROOT / 'target/release' / SETUP)
    native_exe(data, parts, SETUP)
    PREPARE.read_file(ROOT / 'target/release' / SETUP, destination=output / SETUP)
    records = verify_frozen(output, document, gui_records, parts, serialized)
    setup_system_imports = verify_setup_imports(output, document, system_directory)
    installer = installer_bootstrap(output, records, parts, env, system_directory)
    verify_frozen(output, document, gui_records, parts, serialized)
    archive = archive_tree(output, records)
    report = {'schema': 'nikodesk-windows-setup-validation-v1', 'product_version': version_name,
              'product_build': build_number, 'trust_mode': trust_mode,
              'release_json_sha256': hashlib.sha256(serialized.encode()).hexdigest(),
              'service_system_imports': system_imports, 'setup_system_imports': setup_system_imports,
              'files': records,
              'archive': {'path': str(archive), **PREPARE.read_file(archive)[0]},
              'installer_bootstrap': installer,
              'compiled_release_bytes_present': True, 'gui_service_pins_unchanged': True,
              'native_version_manifest_load_flags_verified': True,
              'publisher_authentication_verified': False, 'production_signature_verified': False,
              'client_run_verified': False, 'installation_verified': False, 'services_installed': False,
              'note': 'Complete single-EXE installation assistant and inspection ZIP. The assistant opens the ordinary GUI; service installation requires its visible consent. Byte pins and static PE checks are not Windows runtime acceptance.'}
    output.with_suffix('.json').write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    output.with_suffix('.txt').write_text(
        'NikoDesk Windows unattended validation bundle\n'
        'Run the setup-validation EXE as an ordinary user. It extracts the complete application and opens the visible installation assistant.\n'
        'Confirm your private server in the assistant, then explicitly choose unattended installation.\n'
        'The ZIP contains the same complete application for inspection or manual extraction; run NikoDesk.exe and use Settings > Service.\n'
        'Set the unattended password and review the native local confirmation and UAC prompts.\n'
        'Starting the service after installation is optional and off by default.\n'
        'Do not directly run nikodesk-host.exe or nikodesk-setup.exe; their original GUI authorization is required.\n'
        'This unsigned test bundle has not passed actual Windows installation or unattended remote-session acceptance.\n', encoding='utf-8')
    return report


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build-name', required=True)
    parser.add_argument('--build-number', type=int, required=True)
    parser.add_argument('--setup-output', type=Path)
    parser.add_argument('--setup-trust-mode', choices=PREPARE.TRUST_MODES)
    args = parser.parse_args(argv)
    try:
        report = build(args.build_name, args.build_number, args.setup_output, args.setup_trust_mode)
    except (OSError, ValueError, subprocess.CalledProcessError, UnicodeError, PACKAGE.ET.ParseError) as error:
        parser.exit(1, 'Windows product build failed: {}\n'.format(error))
    print(json.dumps({key: report[key] for key in ('product_version', 'product_build', 'installation_verified')
                      if key in report} or report, sort_keys=True))
    return 0


if __name__ == '__main__':
    sys.exit(main())
