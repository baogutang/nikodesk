import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/nikodesk/device_screens.dart';
import 'package:flutter_hbb/nikodesk/device_store.dart';

void main() {
  test('screens live under a valid scope beside the device directory', () {
    expect(nikoDeviceScreensDirectory(null), isNull);
    expect(nikoDeviceScreensDirectory('../x'), isNull);
    expect(nikoDeviceScreensDirectory('A' * 64), isNull);
    final namespace = 'a' * 64;
    final directory = nikoDeviceScreensDirectory(namespace)!;
    expect(directory.path,
        '${DeviceStore.privateDirectory.path}/scopes/$namespace/thumbnails');
    // The device directory of the same scope sits one level up.
    expect(directory.parent.path,
        DeviceStore.forServerNamespace(namespace).directory.path);
  });

  testWidgets('the core keeps the screens under its own option name',
      (tester) async {
    // src/nikodesk/peer_thumbnail.rs reads the same key.
    expect(nikoDeviceScreensOption, 'nikodesk-peer-thumbnails');
    await tester.pumpWidget(const SizedBox());
  });
}
