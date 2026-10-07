// With the controlled side on its default policy, a controller is told the
// privacy screen is not allowed, and asking anyway neither turns it on nor
// leaves the controller believing it is on.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_hbb/nikodesk/privacy_screen_policy.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/native.dart';

void main() {
  test('the default policy refuses the privacy screen and says so', () async {
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
    final denied = await session.event(
        (event) =>
            event['name'] == 'permission' && event['privacy_mode'] == 'false',
        'the controlled side reporting that the privacy screen is not allowed');
    final additions =
        jsonDecode('${info['platform_additions']}') as Map<String, dynamic>;
    final key =
        nikoPrivacyScreenImpl(additions['supported_privacy_mode_impl'], null);
    expect(
        nikoPrivacyScreenStatus(
            supported: true,
            allowed: denied['privacy_mode'] != 'false',
            viewOnly: false,
            active: ''),
        NikoPrivacyScreenStatus.notAllowed);

    // The interface offers no switch in this state; a request sent anyway
    // must be refused by the controlled side itself.
    final seen = session.events.length;
    await native.bind.sessionTogglePrivacyMode(
        sessionId: session.id, implKey: key!, on: true);
    addTearDown(() => native.bind.sessionTogglePrivacyMode(
        sessionId: session.id, implKey: key, on: false));
    final answer = await session.event(
        (event) =>
            session.events.indexOf(event) >= seen &&
            event['name'] == 'msgbox' &&
            event['title'] == 'Privacy mode',
        'a refusal from the controlled side',
        timeout: const Duration(seconds: 20));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final on = native.bind
        .sessionGetToggleOptionSync(sessionId: session.id, arg: 'privacy-mode');
    // ignore: avoid_print
    print('E2E-PRIVACY denied: answer type=${answer['type']} '
        'text=${answer['text']} state=${on ? 'on' : 'off'}');
    expect('${answer['type']}', contains('error'));
    expect(on, isFalse);
  }, timeout: const Timeout(Duration(minutes: 3)));
}
