import 'dart:convert';
import 'dart:io';

import 'package:flutter_hbb/generated_bridge.dart';
import 'package:flutter_hbb/nikodesk/device_store.dart';
import 'package:flutter_hbb/nikodesk/server_gateway.dart';
import 'package:flutter_hbb/nikodesk/server_scope.dart';
import 'package:flutter_hbb/nikodesk/session_log.dart';
import 'package:flutter_test/flutter_test.dart';

class _ScopeBridge implements Rustdesk {
  final Object? namespace;
  _ScopeBridge(this.namespace);
  @override
  Future<String> mainGetOptions({dynamic hint}) async => jsonEncode({
        'custom-rendezvous-server': 'private.example',
        'relay-server': 'private.example',
        'key': base64Encode(List.filled(32, 7)),
        'stop-service': 'N',
        'nikodesk-server-namespace': namespace,
      });
  @override
  Future<String> mainGetConnectStatus({dynamic hint}) async =>
      '{"status_num":1}';
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final a = 'a' * 64;
  final b = 'b' * 64;
  late Directory root;
  setUp(() async {
    NikoServerScope.activate(null);
    root = await Directory.systemTemp.createTemp('niko-scope-test-');
  });
  tearDown(() async {
    NikoServerScope.activate(null);
    await root.delete(recursive: true);
  });
  DeviceStore devices(String scope) =>
      DeviceStore(Directory('${root.path}/scopes/$scope'),
          serverNamespace: scope);
  SessionLogStore history(String scope) =>
      SessionLogStore(Directory('${root.path}/scopes/$scope'),
          serverNamespace: scope);

  test('only the native lowercase SHA256 namespace can select a directory', () {
    for (final bad in [
      null,
      '',
      '../outside',
      'A' * 64,
      'a' * 63,
      '$a/',
      ' $a',
      123
    ]) {
      NikoServerScope.activate(bad);
      expect(NikoServerScope.current, isNull);
    }
    NikoServerScope.activate(a);
    expect(NikoServerScope.current, a);
  });

  test(
      'default stores capture their original namespace when the server changes',
      () {
    NikoServerScope.activate(a);
    final device = DeviceStore.instance;
    final log = SessionLogStore.instance;
    NikoServerScope.activate(b);
    expect(device.serverNamespace, a);
    expect(log.serverNamespace, a);
    expect(device.directory.path, endsWith('/scopes/$a'));
    expect(log.directory.path, device.directory.path);
    expect(DeviceStore.instance.serverNamespace, b);
    expect(SessionLogStore.instance.directory.path, endsWith('/scopes/$b'));
    NikoServerScope.activate(null);
    expect(
        DeviceStore.instance.directory.path, endsWith('/scopes/unconfigured'));
  });

  test(
      'same numeric IDs on different servers keep separate devices and history',
      () async {
    await devices(a).save(const DeviceEntry(id: '123456', alias: 'Server A'));
    await devices(b).save(const DeviceEntry(id: '123456', alias: 'Server B'));
    await history(a).record(
        SessionLogEntry(id: '123456', startedAt: DateTime.utc(2026, 9, 30)));
    expect((await devices(a).load()).devices.single.alias, 'Server A');
    expect((await devices(b).load()).devices.single.alias, 'Server B');
    expect((await history(a).load()).entries, hasLength(1));
    expect((await history(b).load()).entries, isEmpty);
  });

  test(
      'explicit device import preserves the source and existing scoped records',
      () async {
    final old = DeviceStore(Directory('${root.path}/legacy'));
    await old.save(const DeviceEntry(id: '123456', alias: 'Old alias'));
    await old.save(const DeviceEntry(id: '234567', alias: 'Imported'));
    final source = await old.file.readAsBytes();
    final target = devices(a);
    await target.save(const DeviceEntry(
        id: '123456', alias: 'Current alias', favorite: true));
    expect(await target.importUnscoped(old.directory), 1);
    expect(await target.importUnscoped(old.directory), 0);
    final loaded = (await target.load()).devices;
    expect(loaded.first.alias, 'Current alias');
    expect(loaded.first.favorite, isTrue);
    expect(loaded.last.alias, 'Imported');
    expect(await old.file.readAsBytes(), source);
    expect((await devices(b).load()).devices, isEmpty);
  });

  test(
      'invalid or newer legacy data is preserved without a partial device import',
      () async {
    final old = DeviceStore(Directory('${root.path}/legacy'));
    await old.directory.create();
    await old.file.writeAsString('{"version":99,"devices":[]}');
    final target = devices(a);
    await target.save(const DeviceEntry(id: '123456', alias: 'Current'));
    final previous = await target.file.readAsBytes();
    await expectLater(target.importUnscoped(old.directory),
        throwsA(isA<FutureDeviceSchema>()));
    expect(await old.file.readAsString(), '{"version":99,"devices":[]}');
    expect(await target.file.readAsBytes(), previous);
  });

  test('unconfigured imports cannot assign legacy IDs to a server', () async {
    final old = DeviceStore(Directory('${root.path}/legacy'));
    await old.save(const DeviceEntry(id: '123456'));
    await expectLater(
        DeviceStore(Directory('${root.path}/unknown'))
            .importUnscoped(old.directory),
        throwsStateError);
    await expectLater(
        SessionLogStore(Directory('${root.path}/unknown'))
            .importUnscoped(old.directory),
        throwsStateError);
    expect((await old.load()).devices.single.id, '123456');
  });

  test('history import is idempotent and keeps newer attempts first', () async {
    final old = SessionLogStore(Directory('${root.path}/legacy'));
    final earlier = SessionLogEntry(
        id: '123456', alias: 'Earlier', startedAt: DateTime.utc(2026, 9, 28));
    final latest = SessionLogEntry(
        id: '123456', alias: 'Latest', startedAt: DateTime.utc(2026, 9, 30));
    await old.record(earlier);
    final source = await old.file.readAsBytes();
    final target = history(a);
    await target.record(latest);
    expect(await target.importUnscoped(old.directory), 1);
    expect(await target.importUnscoped(old.directory), 0);
    expect((await target.load()).entries.map((e) => e.alias),
        ['Latest', 'Earlier']);
    expect(await old.file.readAsBytes(), source);
  });

  test(
      'damaged legacy history is read without repairing or replacing the source',
      () async {
    final old = SessionLogStore(Directory('${root.path}/legacy'));
    await old.directory.create();
    await old.file.writeAsString('[broken');
    final target = history(a);
    await expectLater(
        target.importUnscoped(old.directory), throwsFormatException);
    expect(await old.file.readAsString(), '[broken');
    expect(await target.file.exists(), isFalse);
    expect(old.directory.listSync().where((e) => e.path.contains('.corrupt.')),
        isEmpty);
  });

  test(
      'an old session records into its captured server after the active server changes',
      () async {
    final old = history(a);
    NikoServerScope.activate(b);
    await old.record(
        SessionLogEntry(id: '123456', startedAt: DateTime.utc(2026, 9, 30)));
    expect((await history(a).load()).entries, hasLength(1));
    expect((await history(b).load()).entries, isEmpty);
  });

  test('linked legacy files and aliased self-import are rejected', () async {
    final target = devices(a);
    await target.save(const DeviceEntry(id: '123456', alias: 'Preserved'));
    final old = Directory('${root.path}/legacy');
    await old.create();
    await Link('${old.path}/devices.json').create(target.file.path);
    await expectLater(target.importUnscoped(old), throwsFormatException);
    final alias = Directory('${root.path}/alias');
    await Link(alias.path).create(target.directory.path);
    await expectLater(target.importUnscoped(alias), throwsStateError);
    expect((await target.load()).devices.single.alias, 'Preserved');
  }, skip: Platform.isWindows);

  test(
      'gateway exposes only a valid native namespace and fixtures do not mutate global scope',
      () async {
    final valid = await NativeServerGateway(bridge: _ScopeBridge(a)).read();
    expect(valid.namespace, a);
    expect(NikoServerScope.current, isNull);
    for (final invalid in ['../outside', 'B' * 64, null, 12]) {
      expect(
          (await NativeServerGateway(bridge: _ScopeBridge(invalid)).read())
              .namespace,
          isNull);
    }
  });
}
