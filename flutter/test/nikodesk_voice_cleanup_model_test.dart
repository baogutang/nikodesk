import 'dart:async';
import 'dart:convert';

import 'package:flutter_hbb/generated_bridge.dart';
import 'package:flutter_hbb/nikodesk/voice_cleanup_model.dart';
import 'package:flutter_hbb/nikodesk/voice_cleanup_native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

import 'nikodesk_voice_session_model_test.dart' show voiceStatus;

const cleanupSession = '11111111-1111-4111-8111-111111111111';
Map<String, dynamic> cleanupEntry(
        {String sessionId = cleanupSession,
        String namespace = 'a',
        String phase = 'Stopped',
        String revision = '1',
        String joinState = 'pending',
        String callNonce = '3'}) =>
    {
      'session_id': sessionId,
      'status':
          voiceStatus(phase: phase, revision: revision, namespace: namespace)
            ..['wire'] = {'call_nonce': callNonce * 32, 'call_epoch': '1'},
      'join_state': joinState
    };
String cleanupList([List<Map<String, dynamic>>? pending]) => jsonEncode({
      'ok': true,
      'pending': pending ?? [cleanupEntry()]
    });
String cleanupQueued(String command) {
  final raw = jsonDecode(command);
  return jsonEncode({
    'ok': true,
    'status': 'queued',
    'identity': raw['identity'],
    'revision': raw['revision']
  });
}

class _CleanupBridge implements Rustdesk {
  int reads = 0;
  final sessions = <UuidValue>[];
  final commands = <Map<String, dynamic>>[];
  @override
  Future<String> voicePendingCleanup({dynamic hint}) async {
    reads++;
    return cleanupList();
  }

  @override
  Future<String> sessionVoiceCommand(
      {required UuidValue sessionId,
      required String json,
      dynamic hint}) async {
    sessions.add(sessionId);
    commands.add(jsonDecode(json));
    return cleanupQueued(json);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('Stopped is retained until native join list removes the original owner',
      () async {
    var raw = cleanupList();
    final commands = <String>[];
    final model = NikoVoiceCleanupModel(
        readPending: () async => raw,
        command: (session, json) async {
          expect(session, cleanupSession);
          commands.add(json);
          return cleanupQueued(json);
        });
    addTearDown(model.dispose);
    expect(await model.refresh(), true);
    expect(model.pending.single.status.phase, 'Stopped');
    for (final op in ['query', 'retry_cleanup']) {
      expect(await model.send(model.pending.single, op), true);
      await Future<void>.delayed(Duration.zero);
      expect(model.pending.single.joinState, 'pending');
      expect(model.message(model.pending.single), 'queued');
    }
    expect(
        commands.map((c) => jsonDecode(c)['op']), ['query', 'retry_cleanup']);
    raw = cleanupList([]);
    expect(await model.refresh(), true);
    expect(model.visible, false);
  });
  test('strict native list rejects ambiguous, malformed and oversized entries',
      () {
    final invalid = <String>[
      '{}',
      '{"ok":false,"pending":[]}',
      '{"ok":true,"pending":[],"ready":true}',
      cleanupList([cleanupEntry(joinState: 'stopped')]),
      cleanupList([cleanupEntry(sessionId: 'not-a-uuid')]),
      cleanupList(
          [cleanupEntry(sessionId: '00000000-0000-0000-0000-000000000000')]),
      cleanupList([cleanupEntry()..['status'] = {}]),
      cleanupList([cleanupEntry(), cleanupEntry()]),
      cleanupList(List.generate(129, (_) => cleanupEntry())),
      ' ' * 1048577,
    ];
    for (final value in invalid) {
      expect(NikoVoiceCleanupSnapshot.parse(value), isNull);
    }
    expect(NikoVoiceCleanupSnapshot.parse(cleanupList([]))!.pending, isEmpty);
  });
  test('multiple retired calls under one UUID keep their separate full anchors',
      () {
    final snapshot = NikoVoiceCleanupSnapshot.parse(cleanupList(
        [cleanupEntry(), cleanupEntry(callNonce: '4', joinState: 'failed')]));
    expect(snapshot!.pending.length, 2);
    expect(snapshot.pending[0].key, isNot(snapshot.pending[1].key));
  });
  test('construction does not enumerate, prepare, request permission or read',
      () {
    var calls = 0;
    final model = NikoVoiceCleanupModel(readPending: () async {
      calls++;
      return cleanupList();
    }, command: (_, __) async {
      calls++;
      return '{}';
    });
    addTearDown(model.dispose);
    expect(calls, 0);
    expect(model.visible, false);
  });
  test('cross-server cleanup sends the original UUID, identity and revision',
      () async {
    final commands = <Map<String, dynamic>>[];
    final model = NikoVoiceCleanupModel(
        readPending: () async => cleanupList([
              cleanupEntry(namespace: 'a'),
              cleanupEntry(namespace: 'b', revision: '9')
            ]),
        command: (session, json) async {
          expect(session, cleanupSession);
          commands.add(jsonDecode(json));
          return cleanupQueued(json);
        });
    addTearDown(model.dispose);
    await model.refresh();
    for (final entry in [...model.pending]) {
      expect(await model.send(entry, 'retry_cleanup'), true);
      await Future<void>.delayed(Duration.zero);
    }
    expect(commands[0]['identity']['namespace'], 'a' * 64);
    expect(commands[1]['identity']['namespace'], 'b' * 64);
    expect(commands.map((c) => c['revision']), ['1', '9']);
    for (final json in commands) {
      expect(json.keys.toSet(), {'identity', 'revision', 'op'});
    }
  });
  test('cleanup authority has only query and retry, with no new-call powers',
      () async {
    var calls = 0;
    final model = NikoVoiceCleanupModel(
        readPending: () async => cleanupList(),
        command: (_, json) async {
          calls++;
          return cleanupQueued(json);
        });
    addTearDown(model.dispose);
    await model.refresh();
    for (final op in [
      'prepare',
      'approve',
      'enumerate',
      'request_permission',
      'mute',
      'revoke'
    ]) {
      expect(await model.send(model.pending.single, op), false);
    }
    expect(calls, 0);
  });
  test('unknown read, error and timeout retain last pending owners', () async {
    Future<String> Function() next = () async => cleanupList();
    final model = NikoVoiceCleanupModel(
        timeout: const Duration(milliseconds: 10),
        readPending: () => next(),
        command: (_, __) async => '{}');
    addTearDown(model.dispose);
    await model.refresh();
    for (final reader in <Future<String> Function()>[
      () async => '{"ok":false,"pending":[],"reason":"worker_failed"}',
      () async => 'broken',
      () async => throw StateError('synthetic read failure'),
      () => Completer<String>().future
    ]) {
      next = reader;
      expect(await model.refresh(), false);
      expect(model.pending.length, 1);
      expect(model.readUnconfirmed, true);
      expect(model.reading, false);
    }
    next = () async => cleanupList([]);
    expect(await model.refresh(), true);
    expect(model.visible, false);
  });
  test('timed-out command releases busy without inventing cleanup success',
      () async {
    final reply = Completer<String>();
    late String sent;
    final model = NikoVoiceCleanupModel(
        timeout: const Duration(milliseconds: 10),
        readPending: () async => cleanupList(),
        command: (_, json) {
          sent = json;
          return reply.future;
        });
    addTearDown(model.dispose);
    await model.refresh();
    final entry = model.pending.single;
    final result = model.send(entry, 'retry_cleanup');
    expect(model.busy(entry), true);
    expect(await result, false);
    await Future<void>.delayed(Duration.zero);
    expect(model.busy(entry), false);
    expect(model.message(entry), 'operation_unconfirmed');
    reply.complete(cleanupQueued(sent));
    await Future<void>.delayed(Duration.zero);
    expect(model.pending.length, 1);
    expect(model.message(entry), 'operation_unconfirmed');
  });
  test('a read started before cleanup cannot apply its late empty result',
      () async {
    final oldRead = Completer<String>();
    var reads = 0;
    final model = NikoVoiceCleanupModel(
        readPending: () =>
            ++reads == 2 ? oldRead.future : Future.value(cleanupList()),
        command: (_, json) async => cleanupQueued(json));
    addTearDown(model.dispose);
    await model.refresh();
    final pendingRead = model.refresh();
    await model.send(model.pending.single, 'retry_cleanup');
    oldRead.complete(cleanupList([]));
    expect(await pendingRead, false);
    await Future<void>.delayed(Duration.zero);
    expect(reads, 3);
    expect(model.pending.length, 1);
  });
  test('a late command cannot attach to a newer status snapshot', () async {
    final reply = Completer<String>();
    var raw = cleanupList();
    late String sent;
    final model = NikoVoiceCleanupModel(
        readPending: () async => raw,
        command: (_, json) {
          sent = json;
          return reply.future;
        });
    addTearDown(model.dispose);
    await model.refresh();
    final result = model.send(model.pending.single, 'query');
    raw = cleanupList([cleanupEntry(revision: '2', joinState: 'failed')]);
    await model.refresh();
    reply.complete(cleanupQueued(sent));
    expect(await result, false);
    await Future<void>.delayed(Duration.zero);
    expect(model.pending.single.status.revision, '2');
    expect(model.message(model.pending.single), isNull);
    expect(model.pending.single.joinState, 'failed');
  });
  test('mismatched, malformed and stale queue replies never remove owners',
      () async {
    String Function(String) answer = (_) => '{}';
    final model = NikoVoiceCleanupModel(
        readPending: () async => cleanupList(),
        command: (_, json) async => answer(json));
    addTearDown(model.dispose);
    await model.refresh();
    for (final change in [
      (Map<String, dynamic> raw) => raw['identity']['namespace'] = 'b' * 64,
      (Map<String, dynamic> raw) => raw['revision'] = '2',
      (Map<String, dynamic> raw) => raw['ok'] = 'true',
      (Map<String, dynamic> raw) => raw['reason'] = 'raw device / secret',
      (Map<String, dynamic> raw) => raw['status'] = 'Running'
    ]) {
      answer = (json) {
        final raw = jsonDecode(cleanupQueued(json)) as Map<String, dynamic>;
        change(raw);
        return jsonEncode(raw);
      };
      expect(await model.send(model.pending.single, 'query'), false);
      await Future<void>.delayed(Duration.zero);
      expect(model.pending.length, 1);
      expect(model.message(model.pending.single), 'operation_unconfirmed');
    }
  });
  test(
      'revision/resource regression and stopped resurrection reject whole read',
      () async {
    var raw = cleanupList([cleanupEntry(revision: '3')]);
    final model = NikoVoiceCleanupModel(
        readPending: () async => raw, command: (_, __) async => '{}');
    addTearDown(model.dispose);
    await model.refresh();
    for (final entry in [
      cleanupEntry(revision: '2'),
      cleanupEntry(revision: '3')
        ..['status']['reason'] = 'changed_without_revision',
      cleanupEntry(revision: '4', phase: 'Pending')
    ]) {
      raw = cleanupList([entry]);
      expect(await model.refresh(), false);
      expect(model.pending.single.status.revision, '3');
    }
  });
  test('overlapping reads are coalesced into one subsequent bounded read',
      () async {
    final read = Completer<String>();
    var count = 0;
    final model = NikoVoiceCleanupModel(
        readPending: () =>
            ++count == 1 ? read.future : Future.value(cleanupList([])),
        command: (_, __) async => '{}');
    addTearDown(model.dispose);
    final first = model.refresh();
    for (var i = 0; i < 5; i++) {
      expect(await model.refresh(), false);
    }
    expect(count, 1);
    read.complete(cleanupList());
    expect(await first, true);
    await Future<void>.delayed(Duration.zero);
    expect(count, 2);
    expect(model.pending, isEmpty);
  });
  test('disposed read and command cannot notify or revive their old model',
      () async {
    final read = Completer<String>();
    final model = NikoVoiceCleanupModel(
        readPending: () => read.future, command: (_, __) async => '{}');
    var notifications = 0;
    model.addListener(() => notifications++);
    final future = model.refresh();
    model.dispose();
    read.complete(cleanupList());
    expect(await future, false);
    expect(notifications, 1);
    expect(model.pending, isEmpty);
    expect(await model.refresh(), false);
  });
  test('production adapter uses actual sixth API and original UUID command',
      () async {
    final bridge = _CleanupBridge();
    final transport = NativeNikoVoiceCleanupTransport(bridge: bridge);
    final model = transport.createModel();
    addTearDown(model.dispose);
    expect(bridge.reads, 0);
    expect(bridge.sessions, isEmpty);
    await model.refresh();
    expect(await model.send(model.pending.single, 'retry_cleanup'), true);
    await Future<void>.delayed(Duration.zero);
    expect(bridge.sessions.single, UuidValue(cleanupSession));
    expect(bridge.commands.single, {
      'identity': model.pending.single.status.identity.toJson(),
      'revision': '1',
      'op': 'retry_cleanup'
    });
    expect(bridge.reads, 2);
  });
  test('initial retired metadata cannot render an active call or grant', () {
    final snapshot = NikoVoiceCleanupSnapshot.parse(
        cleanupList([cleanupEntry(phase: 'Running')]));
    expect(snapshot!.pending.single.status.localReady, true);
    // The list, rather than this transitional raw phase, owns cleanup state.
    expect(snapshot.pending.single.joinState, 'pending');
  });
  test('disposed in-flight command cannot modify a replacement cleanup model',
      () async {
    final reply = Completer<String>();
    late String sent;
    final old = NikoVoiceCleanupModel(
        readPending: () async => cleanupList(),
        command: (_, json) {
          sent = json;
          return reply.future;
        });
    await old.refresh();
    final command = old.send(old.pending.single, 'retry_cleanup');
    old.dispose();
    final current = NikoVoiceCleanupModel(
        readPending: () async => cleanupList([cleanupEntry(namespace: 'b')]),
        command: (_, __) async => '{}');
    addTearDown(current.dispose);
    await current.refresh();
    reply.complete(cleanupQueued(sent));
    expect(await command, false);
    expect(current.pending.single.status.identity.namespace, 'b' * 64);
    expect(current.message(current.pending.single), isNull);
    expect(current.busy(current.pending.single), false);
  });
}
