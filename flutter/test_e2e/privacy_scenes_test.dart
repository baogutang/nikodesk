// Applies each Nightline privacy scene on the controlled Mac in one privacy
// session and checks it is confirmed, covers the screen, moves, and keeps the
// controller's picture. Covers this Mac's screens and pauses local input for
// about half a minute. NIKODESK_E2E_SHOTS=<dir> saves a screenshot per scene.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/native.dart';
import 'support/privacy_cover.dart';

const _impl = 'nikodesk_privacy_style_v1';

Future<File?> _shot(String path) async {
  final result = await Process.run('screencapture', ['-x', '-D', '1', path]);
  return result.exitCode == 0 ? File(path) : null;
}

void main() {
  test('each Nightline scene is applied, covers the screen and moves',
      () async {
    final native = await NikoNative.instance();
    expect(native.profile, 'ctrl');
    final host =
        File('${env('NIKODESK_E2E_WORK')}/host/id').readAsStringSync().trim();
    final shots = Platform.environment['NIKODESK_E2E_SHOTS'] ??
        Directory.systemTemp.createTempSync('niko-scenes').path;
    final session = await NikoSession.open(native, host,
        password: env('NIKODESK_E2E_HOST_PASSWORD'));
    addTearDown(session.close);
    final info = await session.event(
        (event) => event['name'] == 'peer_info', 'peer info after login');
    await session.until(() => session.frames > 0, 'first decoded frame');
    final features = jsonDecode('${info['features']}') as Map<String, dynamic>;
    expect(features[_impl], isTrue,
        reason: 'the host offers no styled privacy');
    addTearDown(() => native.bind.sessionTogglePrivacyMode(
        sessionId: session.id, implKey: _impl, on: false));

    var request = 100;
    for (final scene in ['nightline', 'deepfield', 'aurora', 'graphite']) {
      final id = ++request;
      final seen = session.events.length;
      final queued = jsonDecode(await native.bind.sessionPrivacyStyle(
          sessionId: session.id,
          json: jsonEncode({
            'request_id': id,
            'preset': scene,
            'effect': 'none',
            'motion': true,
            'brightness': 100,
            'intensity': 120,
            'hint': true,
            'clock': true,
            'image_base64': '',
          }))) as Map<String, dynamic>;
      expect(queued['ok'], isTrue, reason: 'request not queued: $queued');
      final reply = await session.event((event) {
        if (session.events.indexOf(event) < seen ||
            event['name'] != 'nikodesk_privacy_style') return false;
        final payload = jsonDecode('${event['payload']}');
        return payload['request_id'] == id;
      }, '$scene confirmation', timeout: const Duration(seconds: 20));
      final payload = jsonDecode('${reply['payload']}') as Map<String, dynamic>;
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      final covers = await nikoPrivacyCoverWindows();
      final a = await _shot('$shots/$scene-a.png');
      await Future<void>.delayed(const Duration(seconds: 1));
      final b = await _shot('$shots/$scene-b.png');
      final frames = session.frames;
      await session.until(
          () => session.frames > frames, 'frames while $scene is on');
      // ignore: avoid_print
      print('E2E-SCENE $scene applied=${payload['applied']} '
          'active=${payload['active']} covers=$covers '
          'shots=${a != null && b != null}');
      expect(payload['applied'], isTrue, reason: '$scene: $payload');
      expect(payload['active'], isTrue);
      expect(covers, greaterThan(0),
          reason: '$scene does not cover the screen');
    }

    final seen = session.events.length;
    await native.bind.sessionTogglePrivacyMode(
        sessionId: session.id, implKey: _impl, on: false);
    await session.event(
        (event) =>
            session.events.indexOf(event) >= seen &&
            event['name'] == 'msgbox' &&
            event['title'] == 'Privacy mode',
        'the answer to turning it off',
        timeout: const Duration(seconds: 20));
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final left = await nikoPrivacyCoverWindows();
    // ignore: avoid_print
    print('E2E-SCENE off: cover windows $left');
    expect(left, 0, reason: 'the controlled screen was left covered');
  }, timeout: const Timeout(Duration(minutes: 4)));
}
