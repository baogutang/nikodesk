// Restarts the controlled side's capture many times in a row, at 60 frames a
// second, by changing the requested picture size. After each restart the
// hardware encoder returns nothing for its first frames; the stream must stay
// on the hardware encoder instead of falling back to a software one.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/native.dart';

void main() {
  test('the hardware encoder survives repeated capture restarts', () async {
    final native = await NikoNative.instance();
    expect(native.profile, 'ctrl');
    final host =
        File('${env('NIKODESK_E2E_WORK')}/host/id').readAsStringSync().trim();
    final restarts =
        int.parse(Platform.environment['NIKODESK_E2E_RESTARTS'] ?? '14');
    final session = await NikoSession.open(native, host,
        password: env('NIKODESK_E2E_HOST_PASSWORD'));
    addTearDown(session.close);
    Future<void> ask(String width) => native.bind.sessionPeerOption(
        sessionId: session.id, name: 'nikodesk-capture-width', value: width);
    addTearDown(() => ask(''));
    addTearDown(() => native.bind
        .sessionSetImageQuality(sessionId: session.id, value: 'balanced'));
    await session.event(
        (event) => event['name'] == 'peer_info', 'peer info after login');
    await session.until(() => session.frames > 0, 'first decoded frame');
    await native.bind
        .sessionSetImageQuality(sessionId: session.id, value: 'custom');
    await native.bind
        .sessionSetCustomImageQuality(sessionId: session.id, value: 90);
    await native.bind.sessionSetCustomFps(sessionId: session.id, fps: 60);
    await Future<void>.delayed(const Duration(seconds: 3));
    final before = session.quality()['codec_format'];

    for (var i = 0; i < restarts; i++) {
      await ask(i.isEven ? '3840' : '65535');
      await Future<void>.delayed(const Duration(milliseconds: 1300));
    }
    await ask('65535');
    final frames = session.frames;
    await session.until(() => session.frames > frames + 5,
        'frames after the last restart');
    await Future<void>.delayed(const Duration(seconds: 2));

    // Both ends run on this machine, so the controlled side's log is at hand.
    final log = File('${Platform.environment['HOME']}'
            '/Library/Logs/NikoDesk-host/NikoDesk_rCURRENT.log')
        .readAsStringSync();
    final empty = RegExp(r'encode fail: no valid frame, times: (\d+)')
        .allMatches(log)
        .map((match) => int.parse(match.group(1)!))
        .toList();
    final longest = empty.isEmpty ? 0 : empty.reduce((a, b) => a > b ? a : b);
    final fallbacks = 'switch due to encoding fails'.allMatches(log).length;
    final started = RegExp('new encoder: ').allMatches(log).length;
    final software =
        RegExp(r'new encoder: (AOM|VPX)').allMatches(log).length;
    final after = session.quality()['codec_format'];
    // ignore: avoid_print
    print('E2E-RESTART requested=$restarts encoders_started=$started '
        'empty_encodes=${empty.length} longest_run=$longest '
        'fallbacks=$fallbacks software_encoders=$software '
        'codec_before=$before codec_after=$after');
    expect(fallbacks, 0, reason: 'the hardware encoder was given up on');
    expect(software, 0);
    expect(after, before);
  }, timeout: const Timeout(Duration(minutes: 4)));
}
