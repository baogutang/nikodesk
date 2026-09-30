#!/usr/bin/env python3

import os
import optparse
import subprocess
from hashlib import md5
import brotli
import datetime
import re
from pathlib import Path

# 4GB maximum
length_count = 4
# encoding
encoding = 'utf-8'

# output: {path: (compressed_data, file_md5)}


def normalize(path: str) -> str:
    path = path.replace('\\', '/')
    while path.startswith('./'):
        path = path[2:]
    return path.lower()


def generate_md5_table(folder: str, level, exclude: str = None) -> dict:
    res: dict = dict()
    skip = normalize(exclude) if exclude else None
    excluded = False
    # os.curdir is the literal ".", so restoring it left us inside `folder`.
    curdir = os.getcwd()
    os.chdir(folder)
    for root, _, files in os.walk('.'):
        # remove ./
        for f in files:
            md5_generator = md5()
            full_path = os.path.join(root, f)
            if skip and normalize(full_path) == skip:
                print(f"Excluding {full_path}...")
                excluded = True
                continue
            print(f"Processing {full_path}...")
            f = open(full_path, "rb")
            content = f.read()
            content_compressed = brotli.compress(
                content, quality=level)
            md5_generator.update(content)
            md5_code = md5_generator.hexdigest().encode(encoding=encoding)
            res[full_path] = (content_compressed, md5_code)
    os.chdir(curdir)
    if skip and not excluded:
        raise ValueError(f"excluded file was not found in {folder}: {exclude}")
    return res


def write_package_metadata(md5_table: dict, output_folder: str, exe: str):
    write_blob(md5_table, os.path.join(output_folder, "data.bin"), exe)


def write_blob(md5_table: dict, output_path: str, exe: str):
    with open(output_path, "wb") as f:
        f.write("rustdesk".encode(encoding=encoding))
        for path in md5_table.keys():
            (compressed_data, md5_code) = md5_table[path]
            data_length = len(compressed_data)
            path = path.encode(encoding=encoding)
            # path length & path
            f.write((len(path)).to_bytes(length=length_count, byteorder='big'))
            f.write(path)
            # data length & compressed data
            f.write(data_length.to_bytes(
                length=length_count, byteorder='big'))
            f.write(compressed_data)
            # md5 code
            f.write(md5_code)
        # end
        f.write("rustdesk".encode(encoding=encoding))
        # executable
        f.write(exe.encode(encoding='utf-8'))
    print(f"Metadata has been written to {output_path}")

def product_version(name=None, number=None):
    pubspec = Path(__file__).resolve().parents[2] / 'flutter/pubspec.yaml'
    declared = re.search(r'^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$', pubspec.read_text(encoding='utf-8'), re.MULTILINE)
    if not declared:
        raise ValueError('NikoDesk pubspec must declare the product version and build number')
    name = name if name is not None else declared.group(1)
    number = str(number) if number is not None else declared.group(2)
    if not re.fullmatch(r'\d+\.\d+\.\d+', name) or not re.fullmatch(r'\d+', number):
        raise ValueError('Invalid NikoDesk product version/build number')
    parts = [int(part) for part in name.split('.')] + [int(number)]
    if any(part > 65535 for part in parts) or parts[-1] < 1:
        raise ValueError('NikoDesk Windows version components must fit 16 bits, with a positive build')
    return '.'.join(str(part) for part in parts[:3]), str(parts[-1])


def write_app_metadata(output_folder: str, version=None, build_number=None):
    output_path = os.path.join(output_folder, "app_metadata.toml")
    with open(output_path, "w") as f:
        f.write(f"timestamp = {int(datetime.datetime.now().timestamp() * 1000)}\n")
        if version is not None:
            f.write(f'product_version = "{version}"\nbuild_number = {build_number}\n')
    print(f"App metadata has been written to {output_path}")

def build_portable(output_folder: str, target: str, nikodesk=False, version=None, build_number=None):
    if nikodesk:
        version, build_number = product_version(version, build_number)
    current_dir = os.getcwd()
    try:
        os.chdir(output_folder)
        cmd = ["cargo", "build", "--locked", "--release"]
        if nikodesk:
            cmd.extend(["--features", "nikodesk"])
        if target:
            cmd.extend(["--target", target])
        environment = os.environ.copy()
        if nikodesk:
            environment['NIKODESK_PRODUCT_VERSION'] = version
            environment['NIKODESK_BUILD_NUMBER'] = build_number
        subprocess.run(cmd, check=True, env=environment)
    finally:
        os.chdir(current_dir)

# Linux: python3 generate.py -f ../rustdesk-portable-packer/test -o . -e ./test/main.py
# Windows: python3 .\generate.py -f ..\rustdesk\flutter\build\windows\runner\Debug\ -o . -e ..\rustdesk\flutter\build\windows\runner\Debug\rustdesk.exe


if __name__ == '__main__':
    parser = optparse.OptionParser()
    parser.add_option("-f", "--folder", dest="folder",
                      help="folder to compress")
    parser.add_option("-o", "--output", dest="output_folder",
                      help="the root of portable packer project, default is './'")
    parser.add_option("-e", "--executable", dest="executable",
                      help="specify startup file in --folder, default is rustdesk.exe")
    parser.add_option("-t", "--target", dest="target",
                      help="the target used by cargo")
    parser.add_option("-l", "--level", dest="level", type="int",
                      help="compression level, default is 11, highest", default=11)
    parser.add_option("--package", dest="package",
                      help="write the per-customer blob to this path instead of "
                           "data.bin, and skip the cargo build. Injected into the "
                           "template's RDPKG resource so customizing needs no rebuild")
    parser.add_option("--exclude-exe", dest="exclude_exe", action="store_true",
                      default=False,
                      help="omit the executable from the blob, for a template whose "
                           "executable ships in the package instead")
    parser.add_option("--nikodesk", dest="nikodesk", action="store_true", default=False,
                      help="build the isolated NikoDesk user-mode portable wrapper")
    parser.add_option("--product-version", dest="product_version", help="NikoDesk product version, independent of native protocol")
    parser.add_option("--build-number", dest="build_number", help="NikoDesk Windows build number")
    (options, args) = parser.parse_args()
    folder = options.folder or './rustdesk'
    output_folder = os.path.abspath(options.output_folder or './')
    version, build_number = (product_version(options.product_version, options.build_number)
                             if options.nikodesk else (None, None))
    if not options.nikodesk and (options.product_version is not None or options.build_number is not None):
        parser.error('Product version parameters require --nikodesk')

    if not options.executable:
        options.executable = 'rustdesk.exe'
    if not options.executable.startswith(folder):
        options.executable = folder + '/' + options.executable
    # Note: the simple check `options.executable.startswith(folder)` is incorrect.
    # `python generate.py -f rustdesk -e rustdesk.exe` or `python generate.py -f rustdesk`
    # will result the print "Executable path: ..exe".
    # So we need to check if the executable is in the folder, and if so, concat again.
    if os.path.exists(os.path.join(folder, options.executable)):
        options.executable = os.path.join(folder, options.executable)
    folder_path = os.path.abspath(folder)
    exe: str = os.path.abspath(options.executable)
    try:
        in_source_folder = os.path.commonpath([folder_path, exe]) == folder_path
    except ValueError:
        in_source_folder = False
    if not in_source_folder:
        print("The executable must locate in source folder")
        exit(-1)
    if options.nikodesk and (not os.path.isfile(exe) or os.path.basename(exe).lower() != 'nikodesk.exe'):
        raise ValueError('NikoDesk packaging requires the existing NikoDesk.exe runner')
    exe = '.' + exe[len(folder_path):]
    print("Executable path: " + exe)
    print("Compression level: " + str(options.level))
    md5_table = generate_md5_table(
        folder, options.level, exe if options.exclude_exe else None)
    if options.package:
        write_blob(md5_table, os.path.abspath(options.package), exe)
    else:
        write_package_metadata(md5_table, output_folder, exe)
        write_app_metadata(output_folder, version, build_number)
        build_portable(output_folder, options.target, options.nikodesk, version, build_number)
