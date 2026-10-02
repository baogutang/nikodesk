// Two-factor login against the real controlled side: required after the
// password, wrong codes refused, and an accepted code never accepted twice.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/native.dart';
import 'support/totp.dart';

void main() {
  late NikoNative native;
  late String host;
  late String password;
  late Totp totp;

  setUpAll(() async {
    native = await NikoNative.instance();
    expect(native.profile, 'ctrl');
    host =
        File('${env('NIKODESK_E2E_WORK')}/host/id').readAsStringSync().trim();
    password = env('NIKODESK_E2E_HOST_PASSWORD');
    totp = Totp.load();
  });

  Future<NikoSession> untilCodeRequested() async {
    final session = await NikoSession.open(native, host, password: password);
    await session.event(
        (event) =>
            event['name'] == 'msgbox' &&
            event['type'] == 'input-2fa' &&
            event['title'] == '2FA Required',
        'two-factor prompt after the password');
    expect(session.named('peer_info'), isEmpty);
    return session;
  }

  Future<void> send(NikoSession session, String code) => native.bind
      .sessionSend2Fa(sessionId: session.id, code: code, trustThisDevice: false);

  test('a wrong code is refused, a fresh code logs in, a reused code does not',
      () async {
    final first = await untilCodeRequested();
    addTearDown(first.close);
    final step = await totp.freshStep();
    final good = totp.code(step);
    final wrong = good == '000000' ? '111111' : '000000';
    var seen = first.events.length;
    await send(first, wrong);
    await first.event(
        (event) =>
            first.events.indexOf(event) >= seen &&
            event['name'] == 'msgbox' &&
            event['type'] == 'input-2fa' &&
            event['title'] == 'Wrong 2FA Code',
        'refusal of a wrong code');
    expect(first.named('peer_info'), isEmpty);

    await send(first, good);
    await first.event(
        (event) => event['name'] == 'peer_info', 'login with a fresh code');
    await first.close();

    // Still inside the window in which the code is valid by time alone.
    final second = await untilCodeRequested();
    addTearDown(second.close);
    seen = second.events.length;
    await send(second, good);
    await second.event(
        (event) =>
            second.events.indexOf(event) >= seen &&
            event['name'] == 'msgbox' &&
            event['type'] == 'input-2fa' &&
            event['title'] == 'Wrong 2FA Code',
        'refusal of an already used code');
    expect(second.named('peer_info'), isEmpty);
  }, timeout: const Timeout(Duration(minutes: 4)));
}
