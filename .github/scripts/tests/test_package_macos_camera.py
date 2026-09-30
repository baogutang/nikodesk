"""Camera metadata/signature policy tests; synthetic bundles are not build evidence."""
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


PACKAGE = module("package_camera_policy", "package-macos.py")
PREPARE = module("prepare_camera_policy", "prepare-macos-camera.py")


class CameraPackageTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="nikodesk-camera-policy-")
        self.root = Path(self.temporary.name)
        self.app = self.root / "NikoDesk.app"
        self.info = self.app / "Contents/Info.plist"
        self.info.parent.mkdir(parents=True)
        self.info.write_bytes(plistlib.dumps({"CFBundleIdentifier":"io.nikodesk.macos",
            "CFBundleExecutable":"NikoDesk", "CFBundlePackageType":"APPL"}))
        for name in ("MacOS/NikoDesk", "Frameworks/liblibrustdesk.dylib"):
            path=self.info.parent/name;path.parent.mkdir();path.write_bytes(b"fixture");path.chmod(0o755)
        self.entitlements={"com.apple.security.device.camera":True}
        self.symbols="_NKCameraEnumerate\n_NKCameraStart\n"

    def tearDown(self):
        self.temporary.cleanup()

    def command(self,*args):
        if args[0]=="file":
            return "Mach-O 64-bit arm64 " + ("shared library" if args[-1].endswith(".dylib") else "executable")
        if args[0]=="lipo":return "arm64"
        if args[0]=="otool":return args[-1]+":\n"+ ("\t@rpath/liblibrustdesk.dylib (compatibility version 1.0.0)\n" if args[-1].endswith("/NikoDesk") else "")
        if args[0]=="codesign":return plistlib.dumps(self.entitlements).decode() if "--entitlements" in args else ""
        if args[0]=="nm":return self.symbols
        raise AssertionError(args)

    def verify(self,required=True):
        with patch.object(PACKAGE,"command",side_effect=self.command):
            return PACKAGE.verify_bundle(self.app,require_camera=required)

    def test_new_build_requires_purpose_metadata(self):
        with self.assertRaisesRegex(ValueError,"NSCameraUsageDescription"):self.verify()

    def test_historical_build_remains_inspectable_and_reports_no_camera_evidence(self):
        report=self.verify(False)
        self.assertFalse(report["camera_metadata_and_entitlement_verified"])
        self.assertFalse(report["camera_capture_runtime_verified"])
        self.assertFalse(report["camera_tcc_runtime_verified"])

    def test_preparation_preserves_product_identity_version_and_stock_plist(self):
        info=plistlib.loads(self.info.read_bytes());info["CFBundleVersion"]="3";self.info.write_bytes(plistlib.dumps(info))
        stock=self.root/"stock.plist";stock.write_bytes(plistlib.dumps({"CFBundleIdentifier":"com.carriez.rustdesk"}))
        before=stock.read_bytes();PREPARE.prepare(self.app)
        updated=plistlib.loads(self.info.read_bytes());self.assertEqual(updated["CFBundleVersion"],"3")
        self.assertEqual(updated["NSCameraUsageDescription"],PREPARE.PURPOSE);self.assertEqual(before,stock.read_bytes())
        self.assertTrue(self.verify()["camera_metadata_and_entitlement_verified"])

    def test_unsigned_or_false_camera_entitlement_is_rejected(self):
        PREPARE.prepare(self.app)
        for value in [{},{"com.apple.security.device.camera":False},{"com.apple.security.device.camera":"true"}]:
            self.entitlements=value
            with self.subTest(value=value),self.assertRaisesRegex(ValueError,"signed camera entitlement"):self.verify()

    def test_invalid_purpose_is_rejected_even_without_require_flag(self):
        for value in ["", " ", 1, True]:
            info=plistlib.loads(self.info.read_bytes());info["NSCameraUsageDescription"]=value;self.info.write_bytes(plistlib.dumps(info))
            with self.subTest(value=value),self.assertRaisesRegex(ValueError,"NSCameraUsageDescription"):self.verify(False)

    def test_test_provider_exports_are_rejected(self):
        PREPARE.prepare(self.app);self.symbols+="_NKCameraTestCreate\n"
        with self.assertRaisesRegex(ValueError,"test-provider exports"):self.verify()

    def test_preparation_refuses_stock_and_wrong_executable_without_writes(self):
        for key,value in [("CFBundleIdentifier","com.carriez.rustdesk"),("CFBundleExecutable","RustDesk")]:
            info={"CFBundleIdentifier":"io.nikodesk.macos","CFBundleExecutable":"NikoDesk"};info[key]=value
            self.info.write_bytes(plistlib.dumps(info));before=self.info.read_bytes()
            with self.subTest(key=key),self.assertRaisesRegex(ValueError,"only prepared"):PREPARE.prepare(self.app)
            self.assertEqual(before,self.info.read_bytes())

    def test_preparation_refuses_external_symlink_and_hardlink(self):
        original=self.info.read_bytes();outside=self.root/"outside.plist";outside.write_bytes(original)
        for link in ["symlink","hardlink"]:
            self.info.unlink()
            if link=="symlink":self.info.symlink_to(outside)
            else:os.link(outside,self.info)
            with self.subTest(link=link),self.assertRaises(ValueError):PREPARE.prepare(self.app)
            self.assertEqual(outside.read_bytes(),original)

    def test_signature_errors_are_not_suppressed(self):
        import subprocess
        PREPARE.prepare(self.app)
        with patch.object(PACKAGE,"command",side_effect=subprocess.CalledProcessError(1,["codesign"])):
            with self.assertRaises(subprocess.CalledProcessError):PACKAGE.verify_bundle(self.app,require_camera=True)


if __name__=="__main__":unittest.main()
