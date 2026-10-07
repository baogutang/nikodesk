// The privacy screen as the controller's interface drives it: what the
// controlled side says it offers and allows, a request for it chosen by the
// production picker, and the answer that comes back.
//
// A development build started by this harness has no permission to pause the
// local keyboard and mouse, which the Mac's privacy screen requires before it
// blacks anything out. On such a host the request must come back as a
// failure with the state still off; where it does succeed, the test turns it
// off again at once and checks that too. Either way the screen is not left
// black.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_hbb/nikodesk/privacy_screen_policy.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/native.dart';

// The brightest value in the main display's colour table: 0 while the Mac's
// privacy screen has it blacked out. Both ends run on this machine, so the
// test can look. Null when it cannot be read.
Future<double?> _brightest() async {
  final result = await Process.run('swift', [
    '-e',
    'import CoreGraphics; let d = CGMainDisplayID(); '
        'let c = CGDisplayGammaTableCapacity(d); '
        'var r = [CGGammaValue](repeating: 0, count: Int(c)); var g = r; var b = r; '
        'var n: UInt32 = 0; '
        'if CGGetDisplayTransferByTable(d, c, &r, &g, &b, &n) == .success '
        '{ print(max(r.max() ?? 0, g.max() ?? 0, b.max() ?? 0)) }'
  ]);
  return result.exitCode == 0 ? double.tryParse('${result.stdout}'.trim()) : null;
}

void main() {
  test('a privacy screen request reaches the controlled side and is answered',
      () async {
    final native = await NikoNative.instance();
    expect(native.profile, 'ctrl');
    final host =
        File('${env('NIKODESK_E2E_WORK')}/host/id').readAsStringSync().trim();
    final session = await NikoSession.open(native, host,
        password: env('NIKODESK_E2E_HOST_PASSWORD'));
    addTearDown(session.close);
    final info = await session.event(
        (event) => event['name'] == 'peer_info', 'peer info after login');
    await session.until(() => session.frames > 0, 'first decoded frame');

    final features = jsonDecode('${info['features']}') as Map<String, dynamic>;
    final additions =
        jsonDecode('${info['platform_additions']}') as Map<String, dynamic>;
    final offered = additions['supported_privacy_mode_impl'];
    final allowed = session.events.lastWhere(
        (event) =>
            event['name'] == 'permission' && event.containsKey('privacy_mode'),
        orElse: () => const {})['privacy_mode'];
    final key = nikoPrivacyScreenImpl(offered, null);
    // ignore: avoid_print
    print('E2E-PRIVACY supported=${features['privacy_mode']} offered=$offered '
        'allowed=${allowed ?? 'not reported'} picked=$key');
    expect(features['privacy_mode'], isTrue);
    expect(key, isNotNull);
    expect(key, isNotEmpty);
    expect(allowed, isNot('false'),
        reason: 'the host setup allows the privacy screen');
    expect(
        nikoPrivacyScreenStatus(
            supported: true,
            allowed: allowed != 'false',
            viewOnly: false,
            active: ''),
        NikoPrivacyScreenStatus.off);

    bool on() => native.bind
        .sessionGetToggleOptionSync(sessionId: session.id, arg: 'privacy-mode');
    expect(on(), isFalse, reason: 'a new session starts with it off');

    Future<Map<String, dynamic>> answer(int after) => session.event(
        (event) =>
            session.events.indexOf(event) >= after &&
            event['name'] == 'msgbox' &&
            event['title'] == 'Privacy mode',
        'an answer from the controlled side',
        timeout: const Duration(seconds: 20));

    var seen = session.events.length;
    await native.bind.sessionTogglePrivacyMode(
        sessionId: session.id, implKey: key!, on: true);
    // Whatever happens next, do not leave the screen black.
    addTearDown(() => native.bind.sessionTogglePrivacyMode(
        sessionId: session.id, implKey: key, on: false));
    final turnedOn = await answer(seen);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    // ignore: avoid_print
    print('E2E-PRIVACY on-request answer type=${turnedOn['type']} '
        'text=${turnedOn['text']} state=${on() ? 'on' : 'off'}');
    if (turnedOn['text'] == 'Enter privacy mode') {
      expect(on(), isTrue);
      final framesWhileOn = session.frames;
      final dark = await _brightest();
      // ignore: avoid_print
      print('E2E-PRIVACY while on: brightest colour value $dark');
      if (Platform.isMacOS && dark != null) {
        expect(dark, 0, reason: 'the controlled screen is not blacked out');
      }
      // The controller still gets the picture while the screen is black.
      await session.until(() => session.frames > framesWhileOn,
          'frames while the privacy screen is on');
      seen = session.events.length;
      await native.bind.sessionTogglePrivacyMode(
          sessionId: session.id, implKey: key, on: false);
      final turnedOff = await answer(seen);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      // ignore: avoid_print
      print('E2E-PRIVACY off-request answer type=${turnedOff['type']} '
          'text=${turnedOff['text']} state=${on() ? 'on' : 'off'}');
      expect(turnedOff['text'], 'Exit privacy mode');
      expect(on(), isFalse);
      final restored = await _brightest();
      // ignore: avoid_print
      print('E2E-PRIVACY after off: brightest colour value $restored');
      if (Platform.isMacOS && restored != null) {
        expect(restored, greaterThan(0.5),
            reason: 'the controlled screen was left dark');
      }
    } else {
      // Refused or failed: the controller must not think it is on.
      expect('${turnedOn['type']}', contains('error'));
      expect(on(), isFalse);
    }
    // The picture keeps arriving either way.
    final frames = session.frames;
    await session.until(() => session.frames > frames, 'frames afterwards');
  }, timeout: const Timeout(Duration(minutes: 3)));
}
