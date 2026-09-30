import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/nikodesk/autostart.dart';
import 'package:flutter_hbb/nikodesk/session_log.dart';

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('nikodesk-log-test-');
  });
  tearDown(() async => directory.delete(recursive: true));

  test('records sessions newest-first and survives reload', () async {
    final store = SessionLogStore(directory);
    final first = DateTime.utc(2026, 9, 29, 8);
    final second = DateTime.utc(2026, 9, 29, 9);
    await store.record(
        SessionLogEntry(id: '123456', alias: 'Office', startedAt: first));
    await store.record(SessionLogEntry(
        id: '654321',
        alias: '',
        fileTransfer: true,
        forceRelay: true,
        startedAt: second));
    final loaded = (await store.load()).entries;
    expect(loaded.length, 2);
    expect(loaded.first.id, '654321');
    expect(loaded.first.fileTransfer, isTrue);
    expect(loaded.first.forceRelay, isTrue);
    expect(loaded.first.title, '654321');
    expect(loaded.last.alias, 'Office');
  });

  test('caps the history at the documented maximum', () async {
    final store = SessionLogStore(directory);
    for (var i = 0; i < SessionLogStore.keepMax + 25; i++) {
      await store.record(SessionLogEntry(
          id: '123456',
          startedAt: DateTime.utc(2026, 9, 29).add(Duration(seconds: i))));
    }
    expect((await store.load()).entries.length, SessionLogStore.keepMax);
  });

  test('rejects malformed records instead of inventing history', () async {
    final store = SessionLogStore(directory);
    await (await File('${directory.path}/sessions.json')
            .create(recursive: true))
        .writeAsString('[{"id":"not numeric"}]', flush: true);
    final result = await store.load();
    expect(result.entries, isEmpty);
    expect(result.recovered, isTrue);
  });

  test('removeAt deletes exactly one record', () async {
    final store = SessionLogStore(directory);
    final a = DateTime.utc(2026, 9, 29, 8);
    final b = DateTime.utc(2026, 9, 29, 9);
    await store.record(SessionLogEntry(id: '123456', startedAt: a));
    await store.record(SessionLogEntry(id: '654321', startedAt: b));
    await store.removeAt(a);
    final loaded = (await store.load()).entries;
    expect(loaded.length, 1);
    expect(loaded.single.id, '654321');
  });

  test('independent stores serialize writes without losing session attempts',
      () async {
    await Future.wait(List.generate(
        12,
        (index) => SessionLogStore(directory).record(SessionLogEntry(
            id: (100000 + index).toString(),
            startedAt:
                DateTime.utc(2026, 9, 30).add(Duration(seconds: index))))));
    final entries = (await SessionLogStore(directory).load()).entries;
    expect(entries.length, 12);
    expect(entries.map((entry) => entry.id).toSet().length, 12);
    expect(directory.listSync().where((file) => file.path.contains('.tmp.')),
        isEmpty);
  });

  test('recovery preserves corruption and the valid backup after later writes',
      () async {
    final store = SessionLogStore(directory);
    await store
        .record(SessionLogEntry(id: '123456', startedAt: DateTime.utc(2026)));
    await store.record(
        SessionLogEntry(id: '654321', startedAt: DateTime.utc(2026, 2)));
    await store.file.writeAsString('{corrupt');
    final loaded = await store.load();
    expect(loaded.recovered, isTrue);
    expect(loaded.entries.single.id, '123456');
    final corrupt = directory
        .listSync()
        .singleWhere((entry) => entry.path.contains('.corrupt.'));
    expect(await File(corrupt.path).readAsString(), '{corrupt');
    await store.record(
        SessionLogEntry(id: '234567', startedAt: DateTime.utc(2026, 3)));
    final backup =
        jsonDecode(await File('${store.file.path}.bak').readAsString()) as List;
    expect(backup.single['id'], '123456');
  });

  test('failed recovery never overwrites the valid backup or poisons the queue',
      () async {
    final store = SessionLogStore(directory);
    await store
        .record(SessionLogEntry(id: '123456', startedAt: DateTime.utc(2026)));
    await store.record(
        SessionLogEntry(id: '654321', startedAt: DateTime.utc(2026, 2)));
    final backup = File('${store.file.path}.bak');
    final bytes = await backup.readAsBytes();
    await store.file.delete();
    final blocked = await Directory(store.file.path).create();
    await expectLater(store.load(), throwsA(isA<FileSystemException>()));
    expect(await backup.readAsBytes(), bytes);
    await blocked.delete();
    final restored = await store.load();
    expect(restored.recovered, isTrue);
    expect(restored.entries.single.id, '123456');
  });

  test('invalid backup is not replaced with empty history', () async {
    final store = SessionLogStore(directory);
    await store.file.writeAsString('{corrupt');
    final backup = File('${store.file.path}.bak');
    await backup.writeAsString('[42]');
    await expectLater(store.load(), throwsFormatException);
    expect(await store.file.readAsString(), '{corrupt');
    expect(await backup.readAsString(), '[42]');
  });

  test(
      'a malformed member invalidates the whole history instead of being skipped',
      () async {
    final store = SessionLogStore(directory);
    await store.file.writeAsString('[42]');
    final result = await store.load();
    expect(result.recovered, isTrue);
    expect(result.entries, isEmpty);
    expect(
        directory
            .listSync()
            .where((entry) => entry.path.contains('.corrupt.'))
            .length,
        1);
  });

  test('autostart writes and removes a user-level launch agent', () async {
    final home = await Directory.systemTemp.createTemp('nikodesk-home-');
    addTearDown(() => home.delete(recursive: true));
    final managed = NikoAutostart(homeOverride: home.path);
    expect(managed.enabled, isFalse);
    expect(await managed.enable(), isTrue);
    expect(managed.enabled, isTrue);
    final content = await File(
            '${home.path}/Library/LaunchAgents/io.nikodesk.NikoDesk.plist')
        .readAsString();
    expect(content, contains('io.nikodesk.macos'));
    expect(content, contains('RunAtLoad'));
    expect(content, contains('LimitLoadToSessionType'));
    expect(content, isNot(contains('root')));
    expect(await managed.disable(), isTrue);
    expect(managed.enabled, isFalse);
  }, skip: !Platform.isMacOS);

  test(
      'autostart does not report malformed or unexpected configuration as enabled',
      () async {
    final home = await Directory.systemTemp.createTemp('nikodesk-home-');
    addTearDown(() => home.delete(recursive: true));
    final managed = NikoAutostart(homeOverride: home.path);
    await managed.plist.parent.create(recursive: true);
    await managed.plist.writeAsString('<plist><dict></plist>');
    expect(managed.enabled, isFalse);
    expect(await managed.enable(), isTrue);
    final content = await managed.plist.readAsString();
    await managed.plist
        .writeAsString(content.replaceFirst('RunAtLoad', 'NotRunAtLoad'));
    expect(managed.enabled, isFalse);
    expect(
        managed.plist.parent
            .listSync()
            .where((entry) => entry.path.contains('.tmp.')),
        isEmpty);
  }, skip: !Platform.isMacOS);

  test('autostart refuses links and preserves the linked configuration',
      () async {
    final home = await Directory.systemTemp.createTemp('nikodesk-home-');
    addTearDown(() => home.delete(recursive: true));
    final managed = NikoAutostart(homeOverride: home.path);
    await managed.plist.parent.create(recursive: true);
    final other = File('${home.path}/unrelated.plist');
    await other.writeAsString('preserve');
    await Link(managed.plist.path).create(other.path);
    expect(managed.enabled, isFalse);
    expect(await managed.enable(), isFalse);
    expect(await other.readAsString(), 'preserve');
  }, skip: !Platform.isMacOS);
}
