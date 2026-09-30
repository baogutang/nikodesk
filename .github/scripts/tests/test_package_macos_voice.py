"""Voice package policy fixtures; never open audio devices or launch a bundle."""
import importlib.util
import os
import plistlib
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1]


def module(name, file):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / file)
    loaded = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(loaded)
    return loaded


PACKAGE = module("voice_package_policy", "package-macos.py")
PREPARE = module("voice_metadata_prepare", "prepare-macos-camera.py")


class VoicePackageTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="niko-voice-package-")
        self.root = Path(self.temporary.name).resolve()
        self.app = self.root / "NikoDesk.app"
        self.contents = self.app / "Contents"
        self.contents.mkdir(parents=True)
        self.info = self.contents / "Info.plist"
        self.info.write_bytes(plistlib.dumps({"CFBundleIdentifier": "io.nikodesk.macos",
            "CFBundleExecutable": "NikoDesk", "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.1.0", "CFBundleVersion": "3"}))
        for name in ["MacOS/NikoDesk", "Frameworks/liblibrustdesk.dylib"]:
            file = self.contents / name
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_bytes(b"package-policy-fixture"); file.chmod(0o755)
        self.entitlements = {"com.apple.security.device.camera": True,
                             "com.apple.security.device.audio-input": True}
        self.licenses = self.contents / "Resources/NikoDesk/licenses/cpal"

    def tearDown(self):
        self.temporary.cleanup()

    def command(self, *args):
        if args[0] == "file":
            return "Mach-O arm64 " + ("shared library" if args[-1].endswith(".dylib") else "executable")
        if args[0] == "lipo": return "arm64"
        if args[0] == "otool":
            return args[-1] + ":\n" + ("\t@rpath/liblibrustdesk.dylib (compatibility 1.0)\n" if args[-1].endswith("/NikoDesk") else "")
        if args[0] == "codesign":
            return plistlib.dumps(self.entitlements).decode() if "--entitlements" in args else ""
        if args[0] == "nm": return ""
        raise AssertionError(args)

    def verify(self, required=True):
        with patch.object(PACKAGE, "command", side_effect=self.command):
            return PACKAGE.verify_bundle(self.app, require_voice=required)

    def test_historical_mic_purpose_does_not_require_new_license(self):
        info = plistlib.loads(self.info.read_bytes()); info["NSMicrophoneUsageDescription"] = "legacy purpose"
        self.info.write_bytes(plistlib.dumps(info))
        report = self.verify(False)
        self.assertFalse(report["voice_metadata_license_and_entitlement_verified"])
        self.assertFalse(report["voice_microphone_runtime_verified"])
        self.assertFalse(report["voice_playback_runtime_verified"])

    def test_new_bundle_purpose_license_provenance_and_version(self):
        PREPARE.prepare(self.app)
        info = plistlib.loads(self.info.read_bytes())
        self.assertEqual(info["NSMicrophoneUsageDescription"], PREPARE.MICROPHONE_PURPOSE)
        self.assertEqual(info["CFBundleVersion"], "3")
        for name in PREPARE.VOICE_LICENSE_FILES:
            self.assertEqual((self.licenses / name).read_bytes(), (PREPARE.VOICE_SOURCE / name).read_bytes())
        self.assertTrue(self.verify()["voice_metadata_license_and_entitlement_verified"])

    def test_missing_or_empty_mic_purpose_rejected(self):
        with self.assertRaisesRegex(ValueError, "NSMicrophoneUsageDescription"): self.verify()
        PREPARE.prepare(self.app)
        for value in ["", " ", False, 7]:
            info = plistlib.loads(self.info.read_bytes()); info["NSMicrophoneUsageDescription"] = value
            self.info.write_bytes(plistlib.dumps(info))
            with self.subTest(value=value), self.assertRaisesRegex(ValueError, "NSMicrophoneUsageDescription"):
                self.verify()

    def test_signed_mic_entitlement_must_be_boolean_true(self):
        PREPARE.prepare(self.app)
        for value in [None, False, "true"]:
            if value is None:
                self.entitlements.pop("com.apple.security.device.audio-input", None)
            else:
                self.entitlements["com.apple.security.device.audio-input"] = value
            with self.subTest(value=value), self.assertRaisesRegex(ValueError, "signed microphone entitlement"):
                self.verify()

    def test_missing_and_changed_license_or_provenance_rejected(self):
        PREPARE.prepare(self.app)
        for name in PREPARE.VOICE_LICENSE_FILES:
            file = self.licenses / name; original = file.read_bytes(); file.unlink()
            with self.subTest(name=name), self.assertRaisesRegex(ValueError, "Missing or aliased"): self.verify()
            file.write_bytes(b"wrong source")
            with self.subTest(name=name), self.assertRaisesRegex(ValueError, "differs from the fixed source"): self.verify()
            file.write_bytes(original)

    def test_preparation_and_validation_reject_license_symlink(self):
        PREPARE.prepare(self.app)
        outside = self.root / "outside-license"; outside.write_bytes(b"outside-preserved")
        file = self.licenses / "LICENSE"; file.unlink(); file.symlink_to(outside)
        with self.assertRaisesRegex(ValueError, "must not alias"): PREPARE.prepare(self.app)
        with self.assertRaisesRegex(ValueError, "Missing or aliased"): self.verify()
        self.assertEqual(outside.read_bytes(), b"outside-preserved")

    def test_preparation_rejects_external_resource_directory(self):
        outside = self.root / "outside"; outside.mkdir()
        (self.contents / "Resources").symlink_to(outside, target_is_directory=True)
        before = self.info.read_bytes()
        with self.assertRaisesRegex(ValueError, "directory must not alias"): PREPARE.prepare(self.app)
        self.assertEqual(self.info.read_bytes(), before)
        self.assertEqual(list(outside.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
