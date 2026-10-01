"""Voice package policy fixtures; never open audio devices or launch a bundle."""
import importlib.util
import os
import plistlib
import json
import shutil
import subprocess
import sys
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
        self.assertFalse(report["voice_private_coreaudio_license_and_provenance_verified"])
        self.assertFalse(report["voice_microphone_runtime_verified"])
        self.assertFalse(report["voice_playback_runtime_verified"])

    def test_new_bundle_purpose_license_provenance_and_version(self):
        PREPARE.prepare(self.app)
        PACKAGE.prepare_coreaudio_licenses(self.app)
        info = plistlib.loads(self.info.read_bytes())
        self.assertEqual(info["NSMicrophoneUsageDescription"], PREPARE.MICROPHONE_PURPOSE)
        self.assertEqual(info["CFBundleVersion"], "3")
        for name in PREPARE.VOICE_LICENSE_FILES:
            self.assertEqual((self.licenses / name).read_bytes(), (PREPARE.VOICE_SOURCE / name).read_bytes())
        self.assertTrue(self.verify()["voice_metadata_license_and_entitlement_verified"])
        self.assertTrue(self.verify()["voice_private_coreaudio_license_and_provenance_verified"])

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

    def prepare_all(self):
        PREPARE.prepare(self.app)
        PACKAGE.prepare_coreaudio_licenses(self.app)
        return self.contents / "Resources/NikoDesk/licenses/coreaudio-rs"

    def test_coreaudio_complete_fixed_licenses_source_and_modification_notice(self):
        target = self.prepare_all()
        for name in ("LICENSE-MIT", "LICENSE-APACHE", "NIKODESK-PROVENANCE.json"):
            self.assertEqual((target / name).read_bytes(), (PACKAGE.COREAUDIO_SOURCE / name).read_bytes())
        notice = (target / "NIKODESK-PROVENANCE.md").read_text()
        for expected in ("coreaudio-rs 0.11.3", "https://github.com/RustAudio/coreaudio-rs",
                         "libs/nikodesk_coreaudio", "src/audio_unit/owned_cleanup.rs",
                         "Stop/Uninitialize/Dispose", "stock CPAL"):
            self.assertIn(expected, notice)
        self.assertTrue(self.verify()["voice_metadata_license_and_entitlement_verified"])

    def test_coreaudio_missing_changed_and_swapped_materials_are_rejected(self):
        target = self.prepare_all()
        for name in PACKAGE.coreaudio_notices():
            file = target / name
            original = file.read_bytes()
            file.unlink()
            with self.subTest(name=name), self.assertRaisesRegex(ValueError, "Missing or aliased CoreAudio"):
                self.verify()
            file.write_bytes(original + b"\n")
            with self.subTest(name=name), self.assertRaisesRegex(ValueError, "CoreAudio license/provenance differs"):
                self.verify()
            file.write_bytes(original)
        (target / "LICENSE-MIT").write_bytes((target / "LICENSE-APACHE").read_bytes())
        with self.assertRaisesRegex(ValueError, "CoreAudio license/provenance differs"):
            self.verify()

    def test_coreaudio_preparation_and_validation_refuse_aliases_without_outside_writes(self):
        target = self.prepare_all()
        outside = self.root / "outside-coreaudio"
        outside.write_bytes(b"preserved external bytes")
        for name in PACKAGE.coreaudio_notices():
            for kind in ("symlink", "hardlink"):
                file = target / name
                original = file.read_bytes()
                file.unlink()
                if kind == "symlink": file.symlink_to(outside)
                else: os.link(outside, file)
                with self.subTest(name=name, kind=kind), self.assertRaisesRegex(ValueError, "must not alias"):
                    PACKAGE.prepare_coreaudio_licenses(self.app)
                with self.subTest(name=name, kind=kind), self.assertRaisesRegex(ValueError, "Missing or aliased CoreAudio"):
                    self.verify()
                self.assertEqual(outside.read_bytes(), b"preserved external bytes")
                file.unlink()
                file.write_bytes(original)

    def test_coreaudio_directory_alias_does_not_receive_files(self):
        PREPARE.prepare(self.app)
        outside = self.root / "outside-coreaudio-directory"
        outside.mkdir()
        target = self.contents / "Resources/NikoDesk/licenses/coreaudio-rs"
        target.symlink_to(outside, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "ordinary and bundled"):
            PACKAGE.prepare_coreaudio_licenses(self.app)
        self.assertEqual(list(outside.iterdir()), [])

    def test_coreaudio_source_package_version_license_pin_and_actual_change_hash_checked(self):
        source = self.root / "source-coreaudio"
        shutil.copytree(PACKAGE.COREAUDIO_SOURCE, source)
        provenance_file = source / "NIKODESK-PROVENANCE.json"
        original = provenance_file.read_bytes()
        for package, version in (("another-package", "0.11.3"), ("coreaudio-rs", "0.11.2")):
            provenance = json.loads(original)
            provenance["package"], provenance["version"] = package, version
            provenance_file.write_text(json.dumps(provenance))
            with patch.object(PACKAGE, "COREAUDIO_SOURCE", source), self.assertRaisesRegex(ValueError, "fixed private source"):
                PACKAGE.prepare_coreaudio_licenses(self.app)
        provenance_file.write_bytes(original)
        (source / "LICENSE-MIT").write_bytes(b"short incomplete license")
        with patch.object(PACKAGE, "COREAUDIO_SOURCE", source), self.assertRaisesRegex(ValueError, "complete fixed upstream bytes"):
            PACKAGE.prepare_coreaudio_licenses(self.app)
        (source / "LICENSE-MIT").write_bytes((PACKAGE.COREAUDIO_SOURCE / "LICENSE-MIT").read_bytes())
        (source / "src/audio_unit/owned_cleanup.rs").write_bytes(b"changed source not in provenance")
        with patch.object(PACKAGE, "COREAUDIO_SOURCE", source), self.assertRaisesRegex(ValueError, "modification differs"):
            PACKAGE.prepare_coreaudio_licenses(self.app)
        self.assertFalse((self.contents / "Resources/NikoDesk/licenses/coreaudio-rs").exists())

    def test_coreaudio_cli_prepares_unsigned_fixture_and_never_calls_binary_tools(self):
        subprocess.run([sys.executable, str(SCRIPTS / "package-macos.py"), str(self.app),
                        "--prepare-coreaudio-licenses"], check=True, capture_output=True)
        target = self.contents / "Resources/NikoDesk/licenses/coreaudio-rs"
        self.assertEqual(sorted(p.name for p in target.iterdir()), sorted(PACKAGE.coreaudio_notices()))
        before = self.info.read_bytes()
        info = plistlib.loads(before)
        info["CFBundleIdentifier"] = "com.carriez.rustdesk"
        self.info.write_bytes(plistlib.dumps(info))
        stock_info = self.info.read_bytes()
        with self.assertRaisesRegex(ValueError, "only prepared for NikoDesk"):
            PACKAGE.prepare_coreaudio_licenses(self.app)
        self.assertEqual(self.info.read_bytes(), stock_info)

    def test_coreaudio_verification_never_repairs_signed_or_historical_resources(self):
        PREPARE.prepare(self.app)
        before = self.info.read_bytes()
        with self.assertRaisesRegex(ValueError, "CoreAudio license directory"):
            self.verify()
        self.assertEqual(self.info.read_bytes(), before)
        self.assertFalse((self.contents / "Resources/NikoDesk/licenses/coreaudio-rs").exists())
        self.assertFalse(self.verify(False)["voice_metadata_license_and_entitlement_verified"])


if __name__ == "__main__":
    unittest.main()
