"""The Windows program, portable package and tray, and the Android launcher,
must carry NikoDesk's icon. They shipped with the upstream one through 1.0.5
because the files were never replaced when the names were."""
import struct
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]


def entries(path):
    data = path.read_bytes()
    reserved, kind, count = struct.unpack_from('<HHH', data, 0)
    assert (reserved, kind) == (0, 1), path
    found = {}
    for index in range(count):
        width, height, _, _, _, bits, size, offset = struct.unpack_from('<BBBBHHII', data, 6 + 16 * index)
        found[width or 256] = (bits, data[offset:offset + size])
    return found


def edge_pixel(bitmap, size):
    """Blue, green, red, alpha of the middle of the left edge of a 32-bit entry."""
    header = struct.unpack_from('<I', bitmap, 0)[0]
    row = size // 2  # rows are stored bottom-up; the middle row is the same either way
    return struct.unpack_from('<BBBB', bitmap, header + (row * size + 1) * 4)


class BrandIcons(unittest.TestCase):
    def assert_nikodesk_ico(self, relative, sizes):
        found = entries(ROOT / relative)
        self.assertTrue(set(sizes) <= set(found), f'{relative} has sizes {sorted(found)}')
        blue, green, red, alpha = edge_pixel(found[16][1], 16)
        # NikoDesk's background is a dark teal; the upstream icon is blue on white.
        self.assertEqual(alpha, 255, relative)
        self.assertLess(red, 60, relative)
        self.assertGreater(green, 70, relative)
        self.assertLess(abs(green - blue), 30, relative)

    def test_windows_program_and_portable_icon(self):
        self.assert_nikodesk_ico('flutter/windows/runner/resources/app_icon.ico', (16, 32, 48, 256))
        build = (ROOT / 'libs/portable/build.rs').read_text(encoding='utf-8')
        self.assertIn('flutter/windows/runner/resources/app_icon.ico', build)
        self.assertIn('resources\\\\app_icon.ico', (ROOT / 'flutter/windows/runner/Runner.rc').read_text(encoding='utf-8'))

    def test_windows_tray_icon(self):
        self.assert_nikodesk_ico('res/nikodesk-tray.ico', (16, 32))
        self.assertIn('../res/nikodesk-tray.ico', (ROOT / 'src/tray.rs').read_text(encoding='utf-8'))

    def test_android_launcher_icon_is_overridden_for_the_nikodesk_flavor(self):
        flavor = ROOT / 'flutter/android/app/src/nikodesk/res'
        for density in ('mdpi', 'hdpi', 'xhdpi', 'xxhdpi', 'xxxhdpi'):
            for name in ('ic_launcher', 'ic_launcher_round', 'ic_launcher_foreground', 'ic_launcher_monochrome'):
                image = flavor / f'mipmap-{density}' / f'{name}.png'
                self.assertEqual(image.read_bytes()[:8], b'\x89PNG\r\n\x1a\n', image)
                main = ROOT / 'flutter/android/app/src/main/res' / f'mipmap-{density}' / f'{name}.png'
                if main.exists():
                    self.assertNotEqual(image.read_bytes(), main.read_bytes(), image)
        self.assertIn('#0F615C', (flavor / 'values/ic_launcher_background.xml').read_text(encoding='utf-8'))
        for name in ('ic_launcher', 'ic_launcher_round'):
            self.assertIn('@mipmap/ic_launcher_monochrome',
                          (flavor / 'mipmap-anydpi-v26' / f'{name}.xml').read_text(encoding='utf-8'))


if __name__ == '__main__':
    unittest.main()
