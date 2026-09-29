import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/nikodesk/device_store.dart';

void main() {
  late Directory directory;
  late DeviceStore store;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('nikodesk-store-test-');
    store = DeviceStore(directory);
  });
  tearDown(() async => directory.delete(recursive: true));

  test('fresh store is empty and saves only allowed non-sensitive fields',
      () async {
    expect((await store.load()).devices, isEmpty);
    await store.save(const DeviceEntry(
        id: '123456789', alias: 'Home', group: 'Personal', favorite: true));
    final restored = (await DeviceStore(directory).load()).devices.single;
    expect(restored.alias, 'Home');
    expect(restored.favorite, isTrue);
    final json = jsonDecode(await store.file.readAsString());
    expect((json['devices'][0] as Map).keys.toSet(),
        {'id', 'alias', 'group', 'favorite', 'forceRelay'});
  });
  test('version zero migrates through a subsequent save without losing alias',
      () async {
    await store.file.writeAsString(jsonEncode({
      'version': 0,
      'devices': [
        {'id': '123456', 'name': 'Old alias'}
      ]
    }));
    final entry = (await store.load()).devices.single;
    expect(entry.alias, 'Old alias');
    await store.save(entry.copyWith(group: 'Migrated'));
    expect(jsonDecode(await store.file.readAsString())['version'], 1);
  });
  test('future schema is never replaced or renamed, including on writes',
      () async {
    const future = '{"version":2,"devices":[],"futureField":true}';
    await store.file.writeAsString(future);
    expect(store.load(), throwsA(isA<FutureDeviceSchema>()));
    await expectLater(store.save(const DeviceEntry(id: '123456')),
        throwsA(isA<FutureDeviceSchema>()));
    expect(await store.file.readAsString(), future);
    expect(
        directory.listSync().where((f) => f.path.contains('corrupt')), isEmpty);
  });
  test('corrupt file is preserved and last known valid backup is restored',
      () async {
    await store.save(const DeviceEntry(id: '123456', alias: 'Known'));
    await store.save(const DeviceEntry(id: '234567', alias: 'Latest'));
    await store.file.writeAsString('{corrupt');
    final loaded = await store.load();
    expect(loaded.recovered, isTrue);
    expect(loaded.devices.single.alias, 'Known');
    final corrupt = directory
        .listSync()
        .where((file) => file.path.contains('.corrupt.'))
        .single;
    expect(await File(corrupt.path).readAsString(), '{corrupt');
    expect((await store.load()).devices.single.id, '123456');
  });
  test(
      'corruption without a backup recovers empty and preserves original bytes',
      () async {
    await store.file.writeAsString('invalid');
    final loaded = await store.load();
    expect(loaded.devices, isEmpty);
    expect(loaded.recovered, isTrue);
    expect(
        directory
            .listSync()
            .where((file) => file.path.contains('.corrupt.'))
            .length,
        1);
  });
  test('invalid backup is never replaced with invented device records',
      () async {
    await store.file.writeAsString('invalid');
    await File('${store.file.path}.bak').writeAsString('also invalid');
    await expectLater(store.load(), throwsFormatException);
    expect(await store.file.readAsString(), 'invalid');
  });
  test('same-process stores serialize concurrent writes without lost devices',
      () async {
    await Future.wait(List.generate(
        12,
        (index) => DeviceStore(directory).save(DeviceEntry(
            id: (100000 + index).toString(), alias: 'Device $index'))));
    expect((await store.load()).devices.length, 12);
    expect(directory.listSync().where((file) => file.path.contains('.tmp.')),
        isEmpty);
  });
  test(
      'success timestamps come only from an explicit authenticated-session record',
      () async {
    await store.save(const DeviceEntry(id: '123456', alias: 'Work'));
    expect((await store.load()).devices.single.lastConnectedAt, isNull);
    final time = DateTime.utc(2026, 9, 29, 9);
    await store.recordSuccess('123456', time);
    final oldEditor = const DeviceEntry(id: '123456', alias: 'Renamed');
    await store.save(oldEditor);
    expect((await store.load()).devices.single.lastConnectedAt, time);
    await store.remove('123456');
    expect((await store.load()).devices, isEmpty);
  });
  test(
      'temporary success creates a recent record but invalid IDs never persist',
      () async {
    await store.recordSuccess('234567', DateTime.utc(2026));
    await store.recordSuccess('127.0.0.1', DateTime.utc(2026));
    expect((await store.load()).devices.single.id, '234567');
  });
}
