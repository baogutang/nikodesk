import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/nikodesk/connect_dialog.dart';
import 'package:flutter_hbb/nikodesk/device_identity.dart';
import 'package:flutter_hbb/nikodesk/device_page.dart';
import 'package:flutter_hbb/nikodesk/device_store.dart';
import 'package:flutter_hbb/nikodesk/home_board.dart';
import 'package:flutter_hbb/nikodesk/metrics.dart';
import 'package:flutter_hbb/nikodesk/policy.dart';
import 'package:flutter_hbb/nikodesk/server_gateway.dart';
import 'package:flutter_hbb/nikodesk/server_scope.dart';
import 'package:flutter_hbb/nikodesk/session_log.dart';
import 'package:flutter_hbb/nikodesk/session_success.dart';
import 'package:flutter_hbb/nikodesk/ui.dart';
import 'package:flutter_test/flutter_test.dart';

const _ownId = '987654321';
const _otherId = '123456789';
const _refusal =
    'This is this computer’s own device ID. It cannot connect to itself.';

class _Gateway implements ServerGateway {
  int reads = 0;
  @override
  Future<ServerSnapshot> read() async {
    reads++;
    return ServerSnapshot(
        PrivateServerConfig('fixture.invalid', 'fixture.invalid:21117',
            base64Encode(List.filled(32, 7))),
        1,
        true,
        namespace: 'a' * 64);
  }

  @override
  Future<void> save(PrivateServerConfig config) async {}
}

class _Store implements DeviceStore {
  @override
  final Directory directory = Directory('/synthetic/niko-own-device-test');
  @override
  final String? serverNamespace;
  final List<DeviceEntry> devices;
  _Store(this.serverNamespace, this.devices);
  @override
  Future<DeviceDirectory> load() async => DeviceDirectory(devices);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Log implements SessionLogStore {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _tapAndSettle(WidgetTester tester, Finder finder) async {
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => NikoLanguage.english = true);

  group('peer identity', () {
    test('reads host name and platform from the peer configuration', () {
      final mac = NikoPeerIdentity.parse(jsonEncode({
        'password': [1, 2, 3],
        'info': {
          'username': 'someone',
          'hostname': 'Office-Mac.local',
          'platform': 'Mac OS'
        }
      }));
      expect(mac.name, 'Office-Mac');
      expect(mac.platformLabel, 'macOS');
      final windows = NikoPeerIdentity.parse(
          jsonEncode({'info': {'hostname': 'HOME-PC', 'platform': 'Windows'}}));
      expect(windows.name, 'HOME-PC');
      expect(windows.platformLabel, 'Windows');
    });

    test('missing, damaged or hostile fields stay empty or bounded', () {
      for (final raw in [
        '',
        'not json',
        '[]',
        jsonEncode({'info': 'x'}),
        jsonEncode({'info': {'hostname': 7, 'platform': null}}),
      ]) {
        expect(NikoPeerIdentity.parse(raw).isEmpty, isTrue, reason: raw);
      }
      final long = NikoPeerIdentity.parse(jsonEncode({
        'info': {'hostname': 'A\u0000B\nC${'x' * 100}', 'platform': 'Plan9'}
      }));
      expect(long.hostname, startsWith('ABC'));
      expect(long.hostname.length, 64);
      expect(long.platformLabel, 'Plan9');
    });

    test('own ID matches regardless of grouping spaces', () {
      expect(nikoIsOwnDevice('987 654 321', _ownId), isTrue);
      expect(nikoIsOwnDevice(_otherId, _ownId), isFalse);
      expect(nikoIsOwnDevice(_ownId, ''), isFalse);
    });
  });

  group('connect paths refuse this computer', () {
    Future<(int, _Gateway)> dispatch(WidgetTester tester, String id) async {
      var calls = 0;
      final gateway = _Gateway();
      await tester.pumpWidget(MaterialApp(
          home: Builder(
              builder: (context) => Scaffold(
                  body: TextButton(
                      onPressed: () => nikoDispatchConnection(context,
                              id: id,
                              password: 'synthetic-secret',
                              gateway: gateway,
                              ownIdLoader: () async => _ownId,
                              onConnect: (_, __, ___,
                                  {isFileTransfer = false, password}) async {
                            calls++;
                          }),
                      child: const Text('connect'))))));
      await _tapAndSettle(tester, find.text('connect'));
      return (calls, gateway);
    }

    testWidgets('dispatch stops before the server read', (tester) async {
      final (calls, gateway) = await dispatch(tester, '987 654 321');
      expect(calls, 0);
      expect(gateway.reads, 0);
      expect(find.text(_refusal), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    });

    testWidgets('another device still dispatches', (tester) async {
      final (calls, gateway) = await dispatch(tester, _otherId);
      expect(calls, 1);
      expect(gateway.reads, 1);
      expect(find.text(_refusal), findsNothing);
    });

    testWidgets('history reconnect refuses before asking for a password',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
          home: Builder(
              builder: (context) => Scaffold(
                  body: TextButton(
                      onPressed: () => nikoConnectWithPassword(context,
                          id: _ownId,
                          gateway: _Gateway(),
                          ownIdLoader: () async => _ownId),
                      child: const Text('again'))))));
      await _tapAndSettle(tester, find.text('again'));
      expect(find.byType(Dialog), findsNothing);
      expect(find.text(_refusal), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    });
  });

  testWidgets(
      'device page hides its own ID and names unnamed devices by host name',
      (tester) async {
    final gateway = _Gateway();
    final namespace = (await gateway.read()).namespace;
    final store = _Store(namespace, [
      DeviceEntry(id: _ownId, lastConnectedAt: DateTime.utc(2026, 10, 24, 3)),
      DeviceEntry(id: _otherId, lastConnectedAt: DateTime.utc(2026, 10, 23)),
      const DeviceEntry(id: '555666777', alias: 'Named'),
    ]);
    final identityReads = <String>[];
    await tester.binding.setSurfaceSize(const Size(390, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.runAsync(() async {
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: NikoDevicePage(
                  store: store,
                  gateway: gateway,
                  sessionLog: _Log(),
                  native: false,
                  controllerOnly: true,
                  ownDeviceId: () async => _ownId,
                  peerIdentity: (id) {
                    identityReads.add(id);
                    return id == _otherId
                        ? const NikoPeerIdentity(
                            hostname: 'HOME-PC', platform: 'Windows')
                        : const NikoPeerIdentity();
                  }))));
      for (var i = 0; i < 100; i++) {
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 10));
        if (find.text('HOME-PC').evaluate().isNotEmpty) break;
      }
    });
    await tester.pumpAndSettle();
    expect(find.textContaining(nikoGroupedId(_ownId)), findsNothing);
    expect(find.text('HOME-PC'), findsOneWidget);
    expect(find.textContaining('Windows'), findsOneWidget);
    expect(find.text('Named'), findsOneWidget);
    expect(find.textContaining(nikoGroupedId('555666777')), findsOneWidget);
    // Unchanged session times are not reread on the next refresh.
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 3200)));
    await tester.pump();
    expect(identityReads.where((id) => id == _otherId).length, 1);
    expect(identityReads, isNot(contains(_ownId)));

    // Typing this computer's ID into quick connect is refused before any
    // password check; the dispatcher alone would ask for the password first.
    await tester.enterText(
        find.byKey(const Key('nikodesk-hero-id')), '987 654 321');
    await tester.enterText(find.byKey(const Key('nikodesk-hero-password')), '');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    final button = find.byKey(const Key('nikodesk-hero-connect'));
    await tester.ensureVisible(button);
    await tester.pumpAndSettle();
    final reads = gateway.reads;
    await _tapAndSettle(tester, button);
    expect(find.text(_refusal), findsOneWidget);
    expect(gateway.reads, reads);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  group('successful session record', () {
    final scope = 'a' * 64;
    late Directory root;
    setUp(() async {
      root = await Directory.systemTemp.createTemp('niko-own-device-');
      NikoServerScope.activate(null);
    });
    tearDown(() async => root.delete(recursive: true));

    Future<List<DeviceEntry>> record(String peerId) async {
      await nikoRecordAuthenticatedDevice(
          namespace: scope,
          peerId: peerId,
          metrics: SessionMetrics(now: () => DateTime.utc(2026, 10, 24)),
          secure: true,
          fromCache: false,
          remoteControl: true,
          root: root,
          ownIdLoader: () async => '987 654 321');
      return (await DeviceStore.forServerNamespace(scope, root: root).load())
          .devices;
    }

    test('a session to this computer is not saved as a device', () async {
      expect(await record(_ownId), isEmpty);
    });

    test('a session to another device is saved', () async {
      expect((await record(_otherId)).single.id, _otherId);
    });
  });
}
