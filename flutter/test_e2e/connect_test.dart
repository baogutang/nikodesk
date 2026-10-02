// Real sessions from the "ctrl" profile to the running "host" profile through
// the configured private server. Nothing is mocked on either side.
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

  test('a wrong password is refused and never yields a session', () async {
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

  test('the right password gives an authenticated desktop session with video',
      () async {
    final started = DateTime.now();
    final session = await NikoSession.open(native, host, password: password);
    addTearDown(session.close);
    final info = await session.event(
        (event) => event['name'] == 'peer_info', 'peer info after login');
    final authenticated = DateTime.now().difference(started);
    expect(info['platform'], 'Mac OS');
    await session.until(() => session.frames >= 30, '30 decoded frames',
        timeout: const Duration(seconds: 30));
    final firstFrame = session.firstFrame!.difference(started);
    final ready = session.named('connection_ready').last;
    expect(ready['secure'], 'true');

    // Ten seconds of steady state. The numbers are observations for the run
    // log, not pass thresholds: a mostly static desktop legitimately sends few
    // frames.
    final before = session.frames;
    await Future<void>.delayed(const Duration(seconds: 10));
    final decoded = session.frames - before;
    // ignore: avoid_print
    print('E2E login=${authenticated.inMilliseconds}ms '
        'first_frame=${firstFrame.inMilliseconds}ms '
        'direct=${ready['direct']} stream=${ready['stream_type']} '
        'decoded_in_10s=$decoded quality=${session.quality()}');
  }, timeout: const Timeout(Duration(minutes: 3)));
}
