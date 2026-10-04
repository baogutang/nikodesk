// A controlled side that explicitly chose click-only must keep waiting for a
// click even when the controller has the right password. Nobody clicks here.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/native.dart';

void main() {
  test('click-only still waits for a click with the right password', () async {
    final native = await NikoNative.instance();
    expect(native.profile, 'ctrl');
    final host =
        File('${env('NIKODESK_E2E_WORK')}/host/id').readAsStringSync().trim();
    final session = await NikoSession.open(native, host,
        password: env('NIKODESK_E2E_HOST_PASSWORD'));
    addTearDown(session.close);
    await Future<void>.delayed(const Duration(seconds: 12));
    expect(session.named('peer_info'), isEmpty,
        reason: 'the password logged in although click-only was chosen');
    expect(session.frames, 0);
  }, timeout: const Timeout(Duration(minutes: 2)));
}
