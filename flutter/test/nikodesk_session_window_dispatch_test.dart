import 'dart:async';
import 'dart:convert';

import 'package:flutter_hbb/nikodesk/session_window_dispatch.dart';
import 'package:flutter_hbb/nikodesk/window_scope.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final a = 'a' * 64;
  final b = 'b' * 64;

  test('all session kinds send the captured namespace to the child engine', () {
    for (final type in [1, 2, 3, 4, 5]) {
      final message = nikoSessionWindowMessage({
        'type': type,
        'id': '1000000001',
        'forceRelay': true,
        'session_id': 'origin-session',
        'serverNamespace': b,
      }, a);
      final received = jsonDecode(message) as Map<String, dynamic>;
      expect(nikoWindowNamespace(received), a);
      expect(received['type'], type);
      expect(received['session_id'], 'origin-session');
      expect(received['forceRelay'], true);
    }
  });

  test('missing identity fails before any window RPC or serialization',
      () async {
    var calls = 0;
    expect(() => nikoSessionWindowMessage({'id': '1000000001'}, null),
        throwsStateError);
    await expectLater(
        nikoActivatePeerWindow([1], null, (_) async {
          calls++;
          return a;
        }, (_) async {
          calls++;
          return true;
        }),
        throwsStateError);
    expect(calls, 0);
  });
  test(
      'child window preserves only the credential choice and its private server scope',
      () {
    final choice = jsonEncode({
      'nikodesk_credentials': {'schema': 1, 'namespace': a, 'remember': true}
    });
    final message = nikoSessionWindowMessage(
        {'type': 1, 'id': '1000000001', 'connToken': choice}, a);
    final received = jsonDecode(message) as Map<String, dynamic>;
    expect(received['connToken'], choice);
    expect(
        jsonDecode(received['connToken'])['nikodesk_credentials']['namespace'],
        nikoWindowNamespace(received));
    expect((jsonDecode(choice)['nikodesk_credentials'] as Map).keys.toSet(),
        {'schema', 'namespace', 'remember'});
  });

  test('same numeric peer on another server is never activated', () async {
    final activated = <int>[];
    final result = await nikoActivatePeerWindow(
        [1, 2, 3], a, (window) async => {1: b, 2: a, 3: a}[window],
        (window) async {
      activated.add(window);
      return true;
    });
    expect(result, 2);
    expect(activated, [2]);
  });

  test('closing matching windows cannot force reuse of a foreign window',
      () async {
    final activated = <int>[];
    final result =
        await nikoActivatePeerWindow([1, 2, 3, 4], a, (window) async {
      if (window == 4) throw StateError('Closed');
      return window == 2 ? b : a;
    }, (window) async {
      activated.add(window);
      if (window == 1) throw StateError('Closed after identity query');
      return false;
    });
    expect(result, isNull);
    expect(activated, [1, 3]);
  });

  test('queries use a stable window list while windows are being added',
      () async {
    final first = Completer<Object?>();
    final windows = [1, 2];
    final activated = <int>[];
    final pending = nikoActivatePeerWindow(
        windows, a, (window) => window == 1 ? first.future : Future.value(a),
        (window) async {
      activated.add(window);
      return true;
    });
    windows.add(3);
    first.complete(b);
    expect(await pending, 2);
    expect(activated, [2]);
  });
}
