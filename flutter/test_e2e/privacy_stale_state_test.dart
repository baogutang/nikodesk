// A session that ends while its privacy screen is on must not make the next
// session look protected.
//
// The controlled side ties its privacy screen to the connection that asked
// for it and ends it when that connection goes away, but the controller never
// hears "off" after it has gone. Reported on 2026-10-19: the controller kept
// showing the privacy screen as on in later sessions, skipped the automatic
// request because of it, and the controlled Mac stayed visible.
//
// This covers this Mac's display for a few seconds when the host profile
// is allowed to; otherwise the first request fails and the scenario cannot
// set up the stale state, which it reports instead of passing silently.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_hbb/nikodesk/privacy_screen_policy.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/native.dart';
import 'support/privacy_cover.dart';

void main() {
  test('a privacy screen left on by an ended session is not shown as on later',
      () async {
    final native = await NikoNative.instance();
    expect(native.profile, 'ctrl');
    final host =
        File('${env('NIKODESK_E2E_WORK')}/host/id').readAsStringSync().trim();
    final password = env('NIKODESK_E2E_HOST_PASSWORD');

    final first = await NikoSession.open(native, host, password: password);
    var firstClosed = false;
    addTearDown(() async {
      if (!firstClosed) await first.close();
    });
    final info = await first.event(
        (event) => event['name'] == 'peer_info', 'peer info after login');
    await first.until(() => first.frames > 0, 'first decoded frame');
    final additions =
        jsonDecode('${info['platform_additions']}') as Map<String, dynamic>;
    final picked =
        nikoPrivacyScreenImpl(additions['supported_privacy_mode_impl'], null);
    expect(picked, isNotNull, reason: 'the host offers a privacy screen');

    bool on(NikoSession session) => native.bind
        .sessionGetToggleOptionSync(sessionId: session.id, arg: 'privacy-mode');

    final seen = first.events.length;
    await native.bind.sessionTogglePrivacyMode(
        sessionId: first.id, implKey: picked!, on: true);
    final answer = await first.event(
        (event) =>
            first.events.indexOf(event) >= seen &&
            event['name'] == 'msgbox' &&
            event['title'] == 'Privacy mode',
        'an answer from the controlled side',
        timeout: const Duration(seconds: 20));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    // ignore: avoid_print
    print('E2E-PRIVACY-STALE first answer=${answer['text']} '
        'state=${on(first) ? 'on' : 'off'}');
    if (answer['text'] != 'Enter privacy mode') {
      fail('Could not turn the privacy screen on, so the stale state was not '
          'reproduced: ${answer['type']}/${answer['text']}');
    }
    expect(on(first), isTrue);
    final coveredWhileOn = await nikoPrivacyCoverWindows();
    // ignore: avoid_print
    print('E2E-PRIVACY-STALE first session cover windows $coveredWhileOn');
    if (Platform.isMacOS) expect(coveredWhileOn, greaterThan(0));

    // End the session without turning it off, as an abrupt disconnect does.
    await first.close();
    firstClosed = true;

    // The controlled side must remove its cover once the owner is gone.
    int? covers;
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    do {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      covers = await nikoPrivacyCoverWindows();
    } while (covers != null && covers > 0 && DateTime.now().isBefore(deadline));
    // ignore: avoid_print
    print('E2E-PRIVACY-STALE after the first session: cover windows $covers');
    if (Platform.isMacOS) {
      expect(covers, 0,
          reason: 'the controlled screen stayed covered after its owner left');
    }

    final second = await NikoSession.open(native, host, password: password);
    addTearDown(second.close);
    await second.event(
        (event) => event['name'] == 'peer_info', 'peer info after login');
    await second.until(() => second.frames > 0, 'first decoded frame');
    final shown = second.named('update_privacy_mode').length;
    // ignore: avoid_print
    print('E2E-PRIVACY-STALE second session state=${on(second) ? 'on' : 'off'} '
        'updates=$shown');
    expect(on(second), isFalse,
        reason: 'a new session showed the ended session\'s privacy screen');
  }, timeout: const Timeout(Duration(minutes: 3)));
}
