import 'dart:io';

import 'package:flutter_hbb/nikodesk/device_store.dart';
import 'package:flutter_hbb/nikodesk/metrics.dart';
import 'package:flutter_hbb/nikodesk/server_scope.dart';
import 'package:flutter_hbb/nikodesk/session_success.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final scopeA = 'a' * 64;
  final scopeB = 'b' * 64;
  late Directory root;
  late DateTime now;
  late SessionMetrics metrics;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('niko-session-success-');
    NikoServerScope.activate(null);
    now = DateTime.utc(2026, 10, 8, 1);
    metrics = SessionMetrics(now: () => now);
  });
  tearDown(() async {
    NikoServerScope.activate(null);
    await root.delete(recursive: true);
  });
  Future<void> record(
          {String? namespace,
          bool cache = false,
          bool secure = true,
          bool remoteControl = true}) =>
      nikoRecordAuthenticatedDevice(
          namespace: namespace ?? scopeA,
          peerId: '123456',
          metrics: metrics,
          secure: secure,
          fromCache: cache,
          remoteControl: remoteControl,
          root: root);

  test('independent engine with no global scope records the captured server',
      () async {
    await record();
    final store = DeviceStore.forServerNamespace(scopeA, root: root);
    expect((await store.load()).devices.single.lastConnectedAt, now);
    expect(NikoServerScope.current, isNull);
    expect(await Directory('${root.path}/scopes/unconfigured').exists(), false);
  });

  test('another active server cannot redirect a successful session record',
      () async {
    NikoServerScope.activate(scopeB);
    final other = DeviceStore.forServerNamespace(scopeB, root: root);
    await other.save(const DeviceEntry(id: '123456', alias: 'Other server'));
    await record();
    expect((await other.load()).devices.single.lastConnectedAt, isNull);
    expect(
        (await DeviceStore.forServerNamespace(scopeA, root: root).load())
            .devices
            .single
            .lastConnectedAt,
        now);
    expect(NikoServerScope.current, scopeB);
  });

  test('failed, cached and non-control observations never become success',
      () async {
    await record(secure: false);
    await record(cache: true);
    await record(remoteControl: false);
    await record(namespace: '../unconfigured');
    expect(metrics.authenticatedAt, isNull);
    expect(await root.list().isEmpty, isTrue);
  });

  test('duplicate authenticated callbacks are idempotent per connection',
      () async {
    await record();
    final store = DeviceStore.forServerNamespace(scopeA, root: root);
    final before = await store.file.readAsString();
    now = now.add(const Duration(minutes: 1));
    await record();
    expect(await store.file.readAsString(), before);
    expect((await store.load()).devices, hasLength(1));
  });

  test('successful reconnect advances the same scoped device', () async {
    await record();
    now = now.add(const Duration(minutes: 1));
    metrics.connection(secure: true, direct: false, transport: 'Relay');
    expect(metrics.authenticatedAt, isNull);
    await record();
    final devices =
        (await DeviceStore.forServerNamespace(scopeA, root: root).load())
            .devices;
    expect(devices, hasLength(1));
    expect(devices.single.lastConnectedAt, now);
  });

  test('late older writes cannot move the last successful time backwards',
      () async {
    final newer = now.add(const Duration(minutes: 1));
    await DeviceStore.forServerNamespace(scopeA, root: root)
        .recordSuccess('123456', newer);
    await record();
    expect(
        (await DeviceStore.forServerNamespace(scopeA, root: root).load())
            .devices
            .single
            .lastConnectedAt,
        newer);
  });

  test('an invalid namespace never selects an unconfigured or outside path',
      () {
    for (final invalid in ['', '../outside', 'A' * 64]) {
      expect(() => DeviceStore.forServerNamespace(invalid, root: root),
          throwsArgumentError);
    }
  });
}
