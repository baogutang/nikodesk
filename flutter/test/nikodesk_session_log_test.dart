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
    await store.record(SessionLogEntry(
        id: '123456', alias: 'Office', startedAt: first));
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
    await store
        .record(SessionLogEntry(id: '123456', startedAt: a));
    await store
        .record(SessionLogEntry(id: '654321', startedAt: b));
    await store.removeAt(a);
    final loaded = (await store.load()).entries;
    expect(loaded.length, 1);
    expect(loaded.single.id, '654321');
  });

  test('autostart writes and removes a user-level launch agent', () async {
    final home = await Directory.systemTemp.createTemp('nikodesk-home-');
    addTearDown(() => home.delete(recursive: true));
    final managed = NikoAutostart(homeOverride: home.path);
    expect(managed.enabled, isFalse);
    expect(await managed.enable(), isTrue);
    expect(managed.enabled, isTrue);
    final content =
        await File('${home.path}/Library/LaunchAgents/io.nikodesk.NikoDesk.plist')
            .readAsString();
    expect(content, contains('io.nikodesk.macos'));
    expect(content, contains('RunAtLoad'));
    expect(content, contains('LimitLoadToSessionType'));
    expect(content, isNot(contains('root')));
    expect(await managed.disable(), isTrue);
    expect(managed.enabled, isFalse);
  });
}
