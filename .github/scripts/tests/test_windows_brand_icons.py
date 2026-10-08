"""Platform consumers must carry the existing blue brand, including tiny icons."""
import importlib.util
import plistlib
import shutil
import struct
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SPEC = importlib.util.spec_from_file_location('brand_icons', ROOT / '.github/scripts/sync-brand-icons.py')
BRAND = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BRAND)


def entries(path):
    data = path.read_bytes()
    reserved, kind, count = struct.unpack_from('<HHH', data, 0)
    assert (reserved, kind) == (0, 1), path
    found = {}
    for index in range(count):
        width, height, _, _, _, bits, size, offset = struct.unpack_from('<BBBBHHII', data, 6 + 16 * index)
        assert width == height and offset + size <= len(data), path
        found[width or 256] = (bits, data[offset:offset + size])
    return found


def resources(raw):
    count = struct.unpack_from('<H', raw, 4)[0]
    group = bytearray(struct.pack('<HHH', 0, 1, count))
    result = {}
    for index in range(count):
        entry = struct.unpack_from('<BBBBHHII', raw, 6 + 16 * index)
        # Resource IDs/language need not be the original compiler defaults.
        resource_id = index + 41
        group += struct.pack('<BBBBHHIH', *entry[:7], resource_id)
        result[(3, resource_id, 2052)] = raw[entry[7]:entry[7] + entry[6]]
    result[(14, 101, 2052)] = bytes(group)
    return result


class BrandIcons(unittest.TestCase):
    def test_all_source_consumers_match_pinned_brand(self):
        self.assertEqual(BRAND.check(), 22)

    def test_stale_output_and_changed_canonical_source_are_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            shutil.copytree(ROOT / BRAND.BRAND, root / BRAND.BRAND)
            data = BRAND.manifest(root)
            for name in list(data['copies']) + list(data['generated']):
                target = root / name
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(ROOT / name, target)
            BRAND.check(root)
            target = root / BRAND.APP_ICO
            target.write_bytes((ROOT / 'res/icon.ico').read_bytes())
            with self.assertRaisesRegex(ValueError, 'Generated brand icon differs'):
                BRAND.check(root)
            shutil.copyfile(ROOT / BRAND.APP_ICO, target)
            (root / BRAND.BRAND / 'windows/app-16.png').write_bytes(b'changed')
            with self.assertRaisesRegex(ValueError, 'Canonical brand source changed'):
                BRAND.check(root)

    def test_fresh_autocrlf_checkout_preserves_exact_brand_and_consumer_bytes(self):
        with tempfile.TemporaryDirectory() as folder:
            seed, checkout = Path(folder) / 'seed', Path(folder) / 'checkout'
            seed.mkdir()
            checkout.mkdir()
            shutil.copyfile(ROOT / '.gitattributes', seed / '.gitattributes')
            shutil.copytree(ROOT / BRAND.BRAND, seed / BRAND.BRAND)
            data = BRAND.manifest(seed)
            for name in list(data['copies']) + list(data['generated']):
                target = seed / name
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(ROOT / name, target)
            (seed / 'control.txt').write_bytes(b'ordinary text\nsecond line\n')
            # Real clean/smudge filters and a new worktree; no source commit,
            # repository configuration or installed application is changed.
            for arguments in (['init'], ['-c', 'core.autocrlf=false', 'add', '-f', '.'],
                              ['-c', 'core.autocrlf=true', '-c', 'core.eol=crlf',
                               '--work-tree=' + str(checkout), 'checkout-index', '--all']):
                subprocess.run(['git', *arguments], cwd=seed, check=True,
                               capture_output=True)
            self.assertEqual((checkout / 'control.txt').read_bytes(),
                             b'ordinary text\r\nsecond line\r\n')
            self.assertEqual(BRAND.check(checkout), 22)

    def test_windows_program_portable_and_tray_keep_compatible_small_bitmaps(self):
        for name, sizes in ((BRAND.APP_ICO, BRAND.APP_SIZES), (BRAND.TRAY_ICO, BRAND.TRAY_SIZES)):
            found = entries(ROOT / name)
            self.assertEqual(set(found), set(sizes))
            for size in sizes:
                bits, data = found[size]
                self.assertEqual(bits, 32)
                if size <= 64:
                    self.assertEqual(struct.unpack_from('<IiiHH', data), (40, size, size * 2, 1, 32))
                else:
                    self.assertEqual(data[:8], b'\x89PNG\r\n\x1a\n')
        build = (ROOT / 'libs/portable/build.rs').read_text(encoding='utf-8')
        self.assertIn('flutter/windows/runner/resources/app_icon.ico', build)
        self.assertIn('cargo:rerun-if-changed=../../flutter/windows/runner/resources/app_icon.ico', build)
        self.assertIn('resources\\\\app_icon.ico', (ROOT / 'flutter/windows/runner/Runner.rc').read_text(encoding='utf-8'))
        self.assertIn('../res/nikodesk-tray.ico', (ROOT / 'src/tray.rs').read_text(encoding='utf-8'))

    def test_package_icon_checks_follow_resource_ids_and_reject_old_pixels(self):
        raw = (ROOT / BRAND.APP_ICO).read_bytes()
        current = resources(raw)
        BRAND.verify_windows_resources(current, raw)
        for changed in ({}, {**current, (3, 41, 2052): b'old icon pixels'},
                        {**current, (14, 101, 2052): current[(14, 101, 2052)][:-1]}):
            with self.assertRaises(ValueError):
                BRAND.verify_windows_resources(changed, raw)

    def test_macos_bundle_checks_the_plist_selected_resource(self):
        with tempfile.TemporaryDirectory() as folder:
            app = Path(folder) / 'NikoDesk.app'
            resources_dir = app / 'Contents/Resources'
            resources_dir.mkdir(parents=True)
            (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
                'CFBundleIdentifier': 'io.nikodesk.macos', 'CFBundleIconFile': 'AppIcon.icns'}))
            icon = resources_dir / 'AppIcon.icns'
            shutil.copyfile(ROOT / BRAND.MAC_ICNS, icon)
            BRAND.verify_macos_app(app)
            icon.write_bytes(b'icns stale bundle resource')
            with self.assertRaisesRegex(ValueError, 'stale/different'):
                BRAND.verify_macos_app(app)

    def test_android_flavor_owns_adaptive_round_and_monochrome_resources(self):
        flavor = ROOT / 'flutter/android/app/src/nikodesk/res'
        android = '{http://schemas.android.com/apk/res/android}'
        for density, size in (('mdpi', 48), ('hdpi', 72), ('xhdpi', 96), ('xxhdpi', 144), ('xxxhdpi', 192)):
            for name in ('ic_launcher', 'ic_launcher_round'):
                data = (flavor / f'mipmap-{density}' / f'{name}.png').read_bytes()
                self.assertEqual(struct.unpack_from('>II', data, 16), (size, size))
        for version in (26, 33):
            for name in ('ic_launcher', 'ic_launcher_round'):
                tree = ET.parse(flavor / f'mipmap-anydpi-v{version}' / f'{name}.xml').getroot()
                self.assertEqual([x.tag for x in tree], ['background', 'foreground'] + (['monochrome'] if version == 33 else []))
                for node in tree:
                    resource = node.attrib[android + 'drawable'].removeprefix('@drawable/')
                    self.assertTrue((flavor / 'drawable' / f'{resource}.xml').is_file())
        app = ET.parse(flavor.parent / 'AndroidManifest.xml').getroot().find('application')
        self.assertEqual(app.attrib[android + 'roundIcon'], '@mipmap/ic_launcher_round')


if __name__ == '__main__':
    unittest.main()
