// The native diagnostics bundle reads this profile's real logs and must leave
// no IPv4 address or device-ID-length number in them.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/native.dart';

void main() {
  test('diagnostics carry recent logs with addresses and IDs removed',
      () async {
    final native = await NikoNative.instance();
    expect(native.profile, 'ctrl');
    final host =
        File('${env('NIKODESK_E2E_WORK')}/host/id').readAsStringSync().trim();
    // A session first, so the log has addresses and the peer ID in it.
    final session = await NikoSession.open(native, host,
        password: env('NIKODESK_E2E_HOST_PASSWORD'));
    await session.until(() => session.frames > 0, 'first decoded frame');
    await session.close();

    final raw = await native.bind.mainGetNikodeskDiagnostics();
    final bundle = jsonDecode(raw) as Map<String, dynamic>;
    final logs = bundle['logs'] as Map<String, dynamic>;
    final text = logs.values.join('\n');
    // ignore: avoid_print
    print('E2E-DIAGNOSTICS logs=${logs.keys.toList()} bytes=${raw.length} '
        'redacted=${'<ip>'.allMatches(text).length} ips, '
        '${'<id>'.allMatches(text).length} ids');
    expect(logs, isNotEmpty);
    expect(RegExp(r'\b(?:\d{1,3}\.){3}\d{1,3}\b').hasMatch(text), isFalse);
    expect(text.contains(host), isFalse, reason: 'the peer ID leaked');
    expect(bundle['core'], isNotEmpty);
  }, timeout: const Timeout(Duration(minutes: 2)));
}
