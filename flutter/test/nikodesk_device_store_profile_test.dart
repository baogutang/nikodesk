import 'dart:io';

import 'package:flutter_hbb/nikodesk/device_store.dart';
import 'package:flutter_test/flutter_test.dart';

// A development profile keeps saved devices and session history next to its
// own configuration, never in the product's. Run once plainly and once with
// NIKODESK_DEV_PROFILE=<name> set to cover both sides.

void main() {
  test('the private directory follows the development profile', () {
    final profile = Platform.environment['NIKODESK_DEV_PROFILE'];
    final path = DeviceStore.privateDirectory.path;
    if (!Platform.isMacOS) return;
    final home = Platform.environment['HOME']!;
    if (profile != null && RegExp(r'^[a-z0-9]{1,16}$').hasMatch(profile)) {
      expect(path, '$home/Library/Preferences/io.nikodesk.NikoDesk-$profile');
    } else {
      expect(path, '$home/Library/Preferences/io.nikodesk.NikoDesk');
    }
  });
}
