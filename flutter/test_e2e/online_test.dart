// The device list's online state comes from a real query to the private
// server, sent and parsed the way the device page does it: the running
// controlled profile is online, an unknown ID is not.
import 'dart:io';

import 'package:flutter_hbb/nikodesk/peer_event_scope.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/native.dart';

void main() {
  test('the private server reports the running host online and a stranger offline',
      () async {
    final native = await NikoNative.instance();
    expect(native.profile, 'ctrl');
    final namespace = await native.configureServer();
    final host =
        File('${env('NIKODESK_E2E_WORK')}/host/id').readAsStringSync().trim();
    const stranger = '100000001';
    final reply = native.globalEvents
        .map((event) => event['name'] == 'callback_query_onlines'
            ? nikoScopedOnlineEvent(event, namespace)
            : null)
        .firstWhere((event) => event != null)
        .timeout(const Duration(seconds: 30));
    await native.bind
        .queryOnlines(ids: ['nikodesk-scope:$namespace', host, stranger]);
    final event = (await reply)!;
    expect(event.onlines, contains(host));
    expect(event.offlines, contains(stranger));
  }, timeout: const Timeout(Duration(minutes: 2)));
}
