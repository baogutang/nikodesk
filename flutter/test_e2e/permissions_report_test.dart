// The controlled Mac reports its Screen Recording and Accessibility state at
// login, so the controller can say why a picture is empty or input does
// nothing. A host started from this harness inherits the terminal's grants,
// so here both are expected to be granted; the missing case is covered by
// widget tests.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_hbb/nikodesk/remote_permissions.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/native.dart';

void main() {
  test('the controlled Mac reports its system permissions', () async {
    final native = await NikoNative.instance();
    expect(native.profile, 'ctrl');
    final host =
        File('${env('NIKODESK_E2E_WORK')}/host/id').readAsStringSync().trim();
    final session = await NikoSession.open(native, host,
        password: env('NIKODESK_E2E_HOST_PASSWORD'));
    addTearDown(session.close);
    final info = await session.event(
        (event) => event['name'] == 'peer_info', 'peer info after login');
    final additions =
        jsonDecode('${info['platform_additions']}') as Map<String, dynamic>;
    final reported = additions['nikodesk_permissions'];
    // ignore: avoid_print
    print('E2E-PERMISSIONS reported=$reported '
        'missing=${nikoRemoteMissingPermissions(additions)}');
    expect(reported, isA<Map>());
    expect(reported['screen_recording'], isA<bool>());
    expect(reported['accessibility'], isA<bool>());
    await session.until(() => session.frames > 0, 'first decoded frame');
    expect(reported['screen_recording'], isTrue,
        reason: 'frames arrived, so capture is allowed on this host');
  }, timeout: const Timeout(Duration(minutes: 2)));
}
