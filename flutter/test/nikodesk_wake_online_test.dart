import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/nikodesk/ui.dart';
import 'package:flutter_hbb/nikodesk/wake_on_lan.dart';
import 'package:flutter_hbb/nikodesk/wake_on_lan_view.dart';
import 'package:flutter_hbb/nikodesk/wake_online.dart';
import 'package:flutter_test/flutter_test.dart';

const namespace =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const peer = '123456789';
String reply(String state, String observation, {String scope = namespace}) =>
    jsonEncode({
      'schema': 1,
      'namespace': scope,
      'peer_id': peer,
      'state': state,
      'observation': observation
    });

void main() {
  test(
      'online status requires the exact peer, private server and a real observation',
      () {
    expect(NikoWakeOnlineSnapshot.parse(reply('online', '0'), namespace, peer),
        isNull);
    expect(NikoWakeOnlineSnapshot.parse(reply('online', '01'), namespace, peer),
        isNull);
    expect(
        NikoWakeOnlineSnapshot.parse(
            reply('online', '18446744073709551616'), namespace, peer),
        isNull);
    expect(
        NikoWakeOnlineSnapshot.parse(
            reply('online', '1', scope: 'b' * 64), namespace, peer),
        isNull);
    expect(
        NikoWakeOnlineSnapshot.parse(reply('unknown', '0'), namespace, peer)!
            .state,
        'unknown');
  });
  test(
      'cached online state cannot complete a new wake; queue failure is not offline',
      () async {
    var raw = reply('online', '1'), scope = namespace, requests = 0;
    final monitor = NikoWakeOnlineMonitor(namespace, peer,
        readNamespace: () async => scope,
        readStatus: () async => raw,
        request: () async {
          requests++;
          throw StateError('queue full');
        });
    addTearDown(monitor.close);
    await monitor.prepare();
    expect(await monitor.poll(), isNull);
    expect(requests, 1);
    raw = reply('offline', '2');
    expect(await monitor.poll(), false);
    raw = reply('online', '3');
    expect(await monitor.poll(), true);
    scope = 'b' * 64;
    await expectLater(monitor.poll(), throwsStateError);
    expect(requests, 1);
  });
  test(
      'a delayed native result is rejected when its server changes while reading',
      () async {
    var scope = namespace;
    var raw = reply('unknown', '0');
    Completer<String>? held;
    final monitor = NikoWakeOnlineMonitor(namespace, peer,
        readNamespace: () async => scope,
        readStatus: () => held?.future ?? Future.value(raw),
        request: () async {});
    addTearDown(monitor.close);
    await monitor.prepare();
    held = Completer();
    final pending = monitor.poll();
    await Future<void>.delayed(Duration.zero);
    scope = 'b' * 64;
    held.complete(reply('online', '1'));
    await expectLater(pending, throwsStateError);
  });
  testWidgets(
      'private server change stops waiting before a cached online callback can report success',
      (tester) async {
    final oldLanguage = NikoLanguage.english;
    NikoLanguage.english = true;
    addTearDown(() => NikoLanguage.english = oldLanguage);
    var current = true, online = false, sends = 0;
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => Scaffold(
                body: TextButton(
                    onPressed: () => showWakeOnLan(context,
                        title: 'Wake',
                        initial: const WakeProfile(
                            '02:11:22:33:44:55', '192.168.1.255'),
                        isCurrent: () async => current,
                        isOnline: () => online,
                        send: (_) async {
                          sends++;
                          return 3;
                        }),
                    child: const Text('Open'))))));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('wol-send')));
    await tester.pumpAndSettle();
    expect(sends, 1);
    current = false;
    online = true;
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(find.textContaining('online checks stopped.'), findsOneWidget);
    expect(find.textContaining('reports this device online'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
