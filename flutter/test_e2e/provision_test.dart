// Prepares one development profile: saves the private server and records the
// profile's device ID. Needs no running app for that profile.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/native.dart';

void main() {
  test('provision this development profile', () async {
    final native = await NikoNative.instance();
    await native.configureServer();
    final id = await native.bind.mainGetMyId();
    expect(RegExp(r'^\d{6,16}$').hasMatch(id), isTrue,
        reason: 'the profile has no numeric device ID');
    File('${env('NIKODESK_E2E_WORK')}/${native.profile}/id')
        .writeAsStringSync(id);
  }, timeout: const Timeout(Duration(minutes: 2)));
}
