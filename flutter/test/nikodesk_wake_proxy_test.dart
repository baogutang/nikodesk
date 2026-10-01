import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/nikodesk/theme.dart';
import 'package:flutter_hbb/nikodesk/ui.dart';
import 'package:flutter_hbb/nikodesk/wake_on_lan.dart';
import 'package:flutter_hbb/nikodesk/wake_on_lan_view.dart';
import 'package:flutter_hbb/nikodesk/wake_proxy.dart';
import 'package:flutter_hbb/nikodesk/wake_proxy_settings.dart';
import 'package:flutter_test/flutter_test.dart';

const scope =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const nic = '02:11:22:33:44:55';
const target = WakeProfile(nic, '192.168.1.255');
Map<String, Object> endpoint(int port,
        {String generation = '1', String phase = 'Listening'}) =>
    {
      'namespace': scope,
      'peer_id': '123456789',
      'local_port': port,
      'target': {'host': '127.0.0.1', 'port': 21128},
      'generation': generation,
      'revision': '1',
      'phase': phase,
      'reason': 'tunnel_listening',
      'remote_phase': 'Running',
      'local_resources_closed': false,
    };
String directory(List<Map<String, Object>> endpoints) => jsonEncode({
      'schema': 1,
      'namespace': scope,
      'endpoints': endpoints,
    });

class Gateway implements NikoWakeProxyGateway {
  String current = scope;
  var policy = NikoWakeProxyPolicy(scope, false, []);
  int saves = 0;
  bool ignoreSave = false;
  @override
  Future<String> namespace() async => current;
  @override
  Future<NikoWakeProxySnapshot> read(String namespace) async =>
      NikoWakeProxySnapshot(
          policy, 'b' * 64, policy.enabled ? 'unavailable' : 'disabled');
  @override
  Future<void> save(NikoWakeProxyPolicy next) async {
    saves++;
    if (!ignoreSave) policy = NikoWakeProxyPolicy.parse(next.toJson())!;
  }
}

Future<void> addTarget(WidgetTester tester) async {
  await tester.enterText(find.byKey(const Key('wake-proxy-mac')), nic);
  await tester.enterText(
      find.byKey(const Key('wake-proxy-broadcast')), '192.168.1.255');
  await tester.ensureVisible(find.byKey(const Key('wake-proxy-add')));
  await tester.tap(find.byKey(const Key('wake-proxy-add')));
  await tester.pumpAndSettle();
}

void main() {
  test(
      'policy rejects empty enabled, duplicates, public IP and unexpected fields',
      () {
    expect(
        NikoWakeProxyPolicy.parse(
            NikoWakeProxyPolicy(scope, true, []).toJson()),
        isNull);
    expect(
        NikoWakeProxyPolicy.parse(
            NikoWakeProxyPolicy(scope, true, [target, target]).toJson()),
        isNull);
    expect(
        NikoWakeProxyPolicy.parse(NikoWakeProxyPolicy(
            scope, true, [const WakeProfile(nic, '8.8.8.8')]).toJson()),
        isNull);
    final raw = NikoWakeProxyPolicy(scope, true, [target]).toJson();
    expect(NikoWakeProxyPolicy.parse(raw), isNotNull);
    raw['install'] = true;
    expect(NikoWakeProxyPolicy.parse(raw), isNull);
    expect(
        NikoWakeProxySnapshot.parse(
            jsonEncode({
              'schema': 1,
              'namespace': scope,
              'policy': NikoWakeProxyPolicy(scope, false, []).toJson(),
              'revision': 'b' * 64,
              'state': 'listening'
            }),
            scope),
        isNull);
  });
  test(
      'canonical policy order matches native numeric IPv4 and UDP port ordering',
      () {
    final policy = NikoWakeProxyPolicy.parse(NikoWakeProxyPolicy(scope, true, [
      const WakeProfile(nic, '10.12.0.255', port: 21),
      const WakeProfile(nic, '10.2.0.255'),
      const WakeProfile(nic, '10.12.0.255'),
    ]).toJson())!;
    expect(policy.targets.map((target) => '${target.broadcast}:${target.port}'),
        ['10.2.0.255:9', '10.12.0.255:9', '10.12.0.255:21']);
  });

  test(
      'discovery refuses queued, closed, duplicate-port and different-scope entries',
      () async {
    var raw = directory([endpoint(21129)]);
    final gateway = NikoWakeTunnelDirectory(scope, readStatus: () async => raw);
    expect((await gateway.read()).single.peerId, '123456789');
    for (final entries in [
      [endpoint(21129, phase: 'WaitingApproval')],
      [endpoint(21129, phase: 'Closed')],
      [endpoint(21129), endpoint(21129, generation: '2')],
      [
        {...endpoint(21129), 'namespace': 'c' * 64}
      ],
    ]) {
      raw = directory(entries);
      await expectLater(gateway.read(), throwsFormatException);
    }
  });

  test(
      'real loopback TCP sender preserves scope and refuses a rotated original tunnel',
      () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    var generation = '1';
    var rotate = false;
    var requests = 0;
    final subscription = server.listen((socket) async {
      final line =
          await utf8.decoder.bind(socket).transform(const LineSplitter()).first;
      final request = jsonDecode(line) as Map;
      expect(request['namespace'], scope);
      expect(request.containsKey('proxyId'), false);
      expect(request['mac'], nic);
      requests++;
      if (rotate) generation = '2';
      socket.write('${jsonEncode({
            'schema': 1,
            'request_id': request['request_id'],
            'sent': true,
            'packets': 3
          })}\n');
      await socket.flush();
      socket.destroy();
    });
    addTearDown(subscription.cancel);
    final gateway = NikoWakeTunnelDirectory(scope,
        readStatus: () async =>
            directory([endpoint(server.port, generation: generation)]));
    final original = (await gateway.read()).single;
    expect(await gateway.send(target, original), 3);
    rotate = true;
    await expectLater(gateway.send(target, original), throwsStateError);
    expect(requests, 2);
    // A stale stored port is rejected before opening a third TCP connection.
    await expectLater(gateway.send(target, original), throwsStateError);
    expect(requests, 2);
  });

  for (final english in [false, true]) {
    testWidgets(
        '320px 200% proxy settings save policy without claiming listener readiness $english',
        (tester) async {
      NikoLanguage.english = english;
      tester.view.physicalSize = const Size(320, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final gateway = Gateway();
      await tester.pumpWidget(MaterialApp(
          theme: nikoTheme(Brightness.dark),
          builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: const TextScaler.linear(2)),
              child: child!),
          home: Scaffold(
              body: SingleChildScrollView(
                  child: NikoWakeProxySettings(gateway: gateway)))));
      await tester.pumpAndSettle();
      expect(gateway.saves, 0);
      expect(
          tester
              .widget<SwitchListTile>(
                  find.byKey(const Key('wake-proxy-enabled')))
              .value,
          false);
      await addTarget(tester);
      await tester.ensureVisible(find.byKey(const Key('wake-proxy-enabled')));
      await tester.tap(find.byKey(const Key('wake-proxy-enabled')));
      await tester.pumpAndSettle();
      expect(gateway.saves, 0);
      final save = find.byKey(const Key('wake-proxy-save'));
      await tester.ensureVisible(save);
      expect(tester.getSize(save).height, greaterThanOrEqualTo(48));
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(gateway.saves, 1);
      expect(gateway.policy.enabled, true);
      expect(gateway.policy.targets.single.mac, nic);
      expect(find.text(english ? 'Proxy is running' : '代理正在运行'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets(
      'server switch blocks policy save and unconfirmed readback requires reload',
      (tester) async {
    NikoLanguage.english = true;
    final gateway = Gateway();
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: NikoWakeProxySettings(gateway: gateway)))));
    await tester.pumpAndSettle();
    await addTarget(tester);
    gateway.current = 'c' * 64;
    await tester.tap(find.byKey(const Key('wake-proxy-save')));
    await tester.pumpAndSettle();
    expect(gateway.saves, 0);
    expect(
        tester
            .widget<ElevatedButton>(find.byKey(const Key('wake-proxy-save')))
            .onPressed,
        isNull);
    gateway.current = scope;
    await tester.tap(find.byKey(const Key('wake-proxy-reload')));
    await tester.pumpAndSettle();
    await addTarget(tester);
    gateway.ignoreSave = true;
    await tester.tap(find.byKey(const Key('wake-proxy-save')));
    await tester.pumpAndSettle();
    expect(gateway.saves, 1);
    expect(
        tester
            .widget<ElevatedButton>(find.byKey(const Key('wake-proxy-save')))
            .onPressed,
        isNull);
    expect(tester.takeException(), isNull);
  });

  for (final hasDirectory in [false, true]) {
    testWidgets(
        'saved unavailable proxy cannot silently fall back to local broadcast $hasDirectory',
        (tester) async {
      NikoLanguage.english = true;
      var localSends = 0, saves = 0;
      await tester.pumpWidget(MaterialApp(
          home: Builder(
              builder: (context) => Scaffold(
                  body: TextButton(
                      onPressed: () => showWakeOnLan(context,
                              title: 'Wake target',
                              initial: const WakeProfile(nic, '192.168.1.255',
                                  proxyId: '123456789'),
                              proxies: hasDirectory
                                  ? NikoWakeTunnelDirectory(scope,
                                      readStatus: () async => directory([]))
                                  : null, save: (_) async {
                            saves++;
                          }, send: (_) async {
                            localSends++;
                            return 3;
                          }),
                      child: const Text('Open'))))));
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('wol-send')));
      await tester.pumpAndSettle();
      expect(localSends, 0);
      expect(saves, 0);
      expect(find.textContaining('Wake request unconfirmed.'), findsOneWidget);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }
}
