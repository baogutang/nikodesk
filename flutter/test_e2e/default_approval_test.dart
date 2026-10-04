// With the default acceptance rule nobody is at the controlled side to click:
// the development build approves only terminal and tunnel requests by itself.
// A session that reaches video therefore proves the password alone was enough.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/native.dart';

void main() {
  late NikoNative native;
  late String host;
  late String password;

  setUpAll(() async {
    native = await NikoNative.instance();
    expect(native.profile, 'ctrl');
    host =
        File('${env('NIKODESK_E2E_WORK')}/host/id').readAsStringSync().trim();
    password = env('NIKODESK_E2E_HOST_PASSWORD');
  });

  test('by default the right password connects without a click', () async {
    final session = await NikoSession.open(native, host, password: password);
    addTearDown(session.close);
    await session.event(
        (event) => event['name'] == 'peer_info', 'peer info after login');
    await session.until(() => session.frames > 0, 'first decoded frame');
    expect(session.named('connection_ready').last['secure'], 'true');
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('by default a wrong password is still refused', () async {
    final session =
        await NikoSession.open(native, host, password: 'wrong-$password');
    addTearDown(session.close);
    await session.event(
        (event) =>
            event['name'] == 'msgbox' &&
            event['type'] == 're-input-password' &&
            event['title'] == 'Wrong Password',
        'wrong-password prompt');
    expect(session.named('peer_info'), isEmpty);
    expect(session.frames, 0);
  }, timeout: const Timeout(Duration(minutes: 2)));
}
