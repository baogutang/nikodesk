import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/nikodesk/session_audit.dart';
import 'package:flutter_hbb/nikodesk/session_audit_view.dart';
import 'package:flutter_hbb/nikodesk/ui.dart';
import 'package:flutter_test/flutter_test.dart';

const scope =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const session = '12345678-1234-1234-1234-123456789abc';
Map<String, Object?> row(
        {String phase = 'disconnected', String peer = '123456789'}) =>
    {
      'session': session,
      'peerId': peer,
      'role': 'controller',
      'kind': 'desktop',
      'phase': phase,
      'startedAt': 1790838000000,
      'authenticatedAt': 1790838001000,
      'endedAt': phase == 'authenticated' ? null : 1790838003000,
      'durationMs': phase == 'authenticated' ? null : 3000,
    };
String snapshot(
        {String namespace = scope,
        String status = 'ready',
        List<Object?>? rows,
        List<Object?>? activities}) =>
    jsonEncode({
      'ok': status != 'conflict',
      'status': status,
      'namespace': namespace,
      'revision': 'b' * 64,
      'incomplete': false,
      'entries': rows ?? [row()],
      if (activities != null) 'activities': activities,
    });

Map<String, Object?> activity(
        {String stage = 'approved',
        String kind = 'camera',
        String id = '23456789-1234-1234-1234-123456789abc',
        int sequence = 1}) =>
    {
      'id': id,
      'session': session,
      'operation': '34567890-1234-1234-1234-123456789abc',
      'sequence': sequence,
      'peerId': '123456789',
      'role': 'receiver',
      'kind': kind,
      'stage': stage,
      'at': 1790838002000,
    };

class FakeAudit implements SessionAuditApi {
  Future<String> Function(String) onRead =
      (namespace) async => snapshot(namespace: namespace);
  Future<String> Function(String, String) onClear =
      (namespace, revision) async =>
          snapshot(namespace: namespace, status: 'cleared', rows: []);
  final calls = <String>[];
  @override
  Future<String> read(String namespace) => onRead(namespace);
  @override
  Future<String> clear(String namespace, String revision) {
    calls.add('$namespace/$revision');
    return onClear(namespace, revision);
  }
}

Widget page(SessionAuditApi api,
        {String namespace = scope,
        bool active = true,
        Future<void> Function(String, bool, String)? onReconnect}) =>
    MaterialApp(
        home: Scaffold(
      body: MediaQuery(
          data: const MediaQueryData(
              size: Size(320, 900), textScaler: TextScaler.linear(2)),
          child: NikoNativeSessionHistory(
              namespace: namespace,
              api: api,
              active: active,
              onReconnect: onReconnect)),
    ));

void main() {
  setUp(() => NikoLanguage.english = false);
  test(
      'legacy history is readable and sensitive or malformed capability rows fail closed',
      () {
    expect(SessionAuditSnapshot.parse(snapshot(), scope).activities, isEmpty);
    final event =
        SessionAuditSnapshot.parse(snapshot(activities: [activity()]), scope)
            .activities
            .single;
    expect(event.stage, 'approved');
    expect(event.session, session);
    final invalid = <Object?>[
      {...activity(), 'request_nonce': 'private-request-token'},
      activity(id: '00000000-0000-0000-0000-000000000000'),
      activity(stage: 'started', kind: 'camera'),
      {...activity(), 'stage': 'unknown'},
      {...activity(), 'peerId': 'server.example/private'},
    ];
    for (final event in invalid) {
      expect(
          () =>
              SessionAuditSnapshot.parse(snapshot(activities: [event]), scope),
          throwsFormatException);
    }
    expect(
        () => SessionAuditSnapshot.parse(
            snapshot(activities: [activity(), activity()]), scope),
        throwsFormatException);
    expect(
        () => SessionAuditSnapshot.parse(
            snapshot(
                activities:
                    List.generate(201, (i) => activity(sequence: i + 1))),
            scope),
        throwsFormatException);
  });
  testWidgets(
      'capability history distinguishes approval, start and incomplete cleanup on a small screen',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = FakeAudit()
      ..onRead = (_) async => snapshot(rows: [], activities: [
            activity(stage: 'cleanup_pending'),
            activity(
                stage: 'approved',
                id: '45678901-1234-1234-1234-123456789abc',
                sequence: 2),
          ]);
    await tester.pumpWidget(page(api));
    await tester.pumpAndSettle();
    await tester
        .ensureVisible(find.byKey(const ValueKey('niko-audit-activities')));
    await tester.tap(find.byKey(const ValueKey('niko-audit-activities')));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
        find.byKey(const ValueKey(
            'niko-audit-event-23456789-1234-1234-1234-123456789abc')),
        250,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('清理尚未确认'), findsOneWidget);
    await tester.scrollUntilVisible(
        find.byKey(const ValueKey(
            'niko-audit-event-45678901-1234-1234-1234-123456789abc')),
        250,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('本机已批准，启动尚未确认'), findsOneWidget);
    expect(find.text('本机资源已启动'), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
      'capability-only records can be cleared and new events preserve a conflicting clear',
      (tester) async {
    final api = FakeAudit();
    api.onRead = (_) async => snapshot(rows: [], activities: [activity()]);
    api.onClear = (_, __) async {
      final updated = snapshot(
          status: 'conflict', rows: [], activities: [activity(stage: 'stopped')]);
      api.onRead = (_) async => updated;
      return updated;
    };
    await tester.pumpWidget(page(api));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('niko-audit-clear')));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 4));
    await tester.tap(find.byKey(const ValueKey('niko-audit-confirm-clear')));
    await tester.pumpAndSettle();
    expect(api.calls, ['$scope/${'b' * 64}']);
    expect(find.textContaining('记录未清空'), findsOneWidget);
    await tester
        .ensureVisible(find.byKey(const ValueKey('niko-audit-activities')));
    await tester.tap(find.byKey(const ValueKey('niko-audit-activities')));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
        find.byKey(const ValueKey(
            'niko-audit-event-23456789-1234-1234-1234-123456789abc')),
        250,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('本机资源停止已确认'), findsOneWidget);
  });
  test('native results require the original scope and consistent lifecycle',
      () {
    final result = SessionAuditSnapshot.parse(snapshot(), scope);
    expect(result.entries.single.phase, 'disconnected');
    expect(result.entries.single.durationMs, 3000);
    expect(
        () => SessionAuditSnapshot.parse(snapshot(namespace: 'c' * 64), scope),
        throwsFormatException);
    expect(
        () => SessionAuditSnapshot.parse(
            snapshot(rows: [row(phase: 'connecting')]), scope),
        throwsFormatException);
    expect(
        () => SessionAuditSnapshot.parse(
            snapshot(rows: [row(peer: 'password-at-server')]), scope),
        throwsFormatException);
    expect(
        () => SessionAuditSnapshot.parse(snapshot(rows: [row(), row()]), scope),
        throwsFormatException);
  });
  testWidgets(
      'real results distinguish authentication and close at 320px and 200% text',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(page(FakeAudit()));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
        find.byKey(const ValueKey('niko-audit-phase-$session')), 250,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('已认证并断开'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('a conflicting clear preserves newly recorded results',
      (tester) async {
    final api = FakeAudit()
      ..onClear = (_, __) async =>
          snapshot(status: 'conflict', rows: [row(peer: '987654321')]);
    await tester.pumpWidget(page(api));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('niko-audit-clear')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('niko-audit-confirm-clear')));
    await tester.pumpAndSettle();
    expect(api.calls, ['$scope/${'b' * 64}']);
    expect(find.textContaining('记录未清空'), findsOneWidget);
    expect(find.textContaining('已清空本机'), findsNothing);
  });
  testWidgets(
      'a late response from the old namespace cannot replace current results',
      (tester) async {
    final delayed = Completer<String>();
    final api = FakeAudit()
      ..onRead = (namespace) => namespace == scope
          ? delayed.future
          : Future.value(snapshot(namespace: namespace, rows: []));
    await tester.pumpWidget(page(api));
    await tester.pump();
    await tester.pumpWidget(page(api, namespace: 'c' * 64));
    await tester.pumpAndSettle();
    delayed.complete(snapshot());
    await tester.pumpAndSettle();
    expect(find.text('尚无已保存的原生会话结果。'), findsOneWidget);
    expect(find.text('123456789'), findsNothing);
  });
  testWidgets('returning to the history page reads new native events',
      (tester) async {
    final api = FakeAudit();
    var reads = 0;
    api.onRead = (namespace) async {
      reads++;
      return snapshot(namespace: namespace, rows: []);
    };
    Widget visibility(bool active) => MaterialApp(
        home: Scaffold(
            body: NikoNativeSessionHistory(
                namespace: scope, api: api, active: active)));
    await tester.pumpWidget(visibility(false));
    await tester.pumpAndSettle();
    expect(reads, 0);
    await tester.pumpWidget(visibility(true));
    await tester.pumpAndSettle();
    expect(reads, 1);
    await tester.pumpWidget(visibility(false));
    await tester.pumpAndSettle();
    await tester.pumpWidget(visibility(true));
    await tester.pumpAndSettle();
    expect(reads, 2);
  });

  testWidgets('visible history refreshes and stops while hidden or unfocused',
      (tester) async {
    addTearDown(() => tester.binding
        .handleAppLifecycleStateChanged(AppLifecycleState.resumed));
    final api = FakeAudit();
    var reads = 0;
    api.onRead = (namespace) async {
      reads++;
      return snapshot(
          namespace: namespace,
          rows: reads == 1 ? [] : [row(peer: '987654321')]);
    };
    await tester.pumpWidget(page(api));
    await tester.pumpAndSettle();
    expect(reads, 1);
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(reads, 2);
    await tester.ensureVisible(find.text('987654321'));
    expect(find.text('987654321'), findsOneWidget);

    await tester.pumpWidget(page(api, active: false));
    await tester.pump(const Duration(seconds: 9));
    expect(reads, 2);
    await tester.pumpWidget(page(api));
    await tester.pumpAndSettle();
    expect(reads, 3);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump(const Duration(seconds: 9));
    expect(reads, 3);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(reads, 4);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 9));
    expect(reads, 4);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a covering route pauses history and popping refreshes immediately',
      (tester) async {
    var reads = 0;
    final api = FakeAudit()
      ..onRead = (namespace) async {
        reads++;
        return snapshot(namespace: namespace, rows: []);
      };
    await tester.pumpWidget(page(api));
    await tester.pumpAndSettle();
    expect(reads, 1);
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    navigator.push(MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('Remote session'))));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 12));
    expect(reads, 1);
    navigator.pop();
    await tester.pumpAndSettle();
    expect(reads, 2);
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(reads, 3);
    expect(tester.takeException(), isNull);
  });

  testWidgets('slow reads do not overlap and hidden or disposed replies expire',
      (tester) async {
    final first = Completer<String>();
    final second = Completer<String>();
    var reads = 0;
    final api = FakeAudit()
      ..onRead = (_) => ++reads == 1 ? first.future : second.future;
    await tester.pumpWidget(page(api));
    await tester.pump(const Duration(seconds: 12));
    expect(reads, 1);
    await tester.pumpWidget(page(api, active: false));
    first.complete(snapshot());
    await tester.pumpAndSettle();
    expect(find.text('123456789'), findsNothing);
    await tester.pumpWidget(page(api));
    await tester.pump();
    expect(reads, 2);
    await tester.pumpWidget(const SizedBox());
    second.complete(snapshot());
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 9));
    expect(reads, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('authenticated controller cards reconnect safely at narrow width',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    for (final kind in ['desktop', 'file_transfer']) {
      final api = FakeAudit()
        ..onRead = (_) async => snapshot(rows: [
              {...row(), 'kind': kind}
            ]);
      final dispatched = <List<Object>>[];
      final pending = Completer<void>();
      await tester
          .pumpWidget(page(api, onReconnect: (id, files, namespace) async {
        dispatched.add([id, files, namespace]);
        await pending.future;
      }));
      await tester.pumpAndSettle();
      final button =
          find.byKey(const ValueKey('niko-audit-reconnect-$session'));
      await tester.scrollUntilVisible(button, 250,
          scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      await tester.tap(button);
      await tester.pump();
      await tester.tap(button);
      await tester.pump(const Duration(seconds: 4));
      expect(dispatched, [
        ['123456789', kind == 'file_transfer', scope]
      ]);
      expect(find.text('已认证并断开'), findsOneWidget);
      pending.complete();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    }
  });

  testWidgets(
      'receiver, unauthenticated and unsupported cards cannot reconnect',
      (tester) async {
    final cases = [
      {...row(), 'role': 'receiver'},
      {...row(), 'peerId': null},
      {...row(), 'kind': 'camera'},
      {...row(), 'kind': 'terminal'},
      {...row(), 'kind': 'tunnel'},
      {...row(), 'phase': 'not_authenticated', 'authenticatedAt': null},
      {
        ...row(),
        'phase': 'connecting',
        'authenticatedAt': null,
        'endedAt': null,
        'durationMs': null
      },
    ];
    var dispatched = 0;
    for (final item in cases) {
      final api = FakeAudit()..onRead = (_) async => snapshot(rows: [item]);
      await tester.pumpWidget(
          page(api, onReconnect: (_, __, ___) async => dispatched++));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
          find.byKey(const ValueKey('niko-audit-phase-$session')), 250,
          scrollable: find.byType(Scrollable).first);
      expect(find.byKey(const ValueKey('niko-audit-reconnect-$session')),
          findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    }
    expect(dispatched, 0);
  });

  testWidgets(
      'late reconnect callbacks cannot update a changed scope or disposal',
      (tester) async {
    final api = FakeAudit()
      ..onRead = (namespace) async => snapshot(
          namespace: namespace, rows: namespace == scope ? [row()] : []);
    final reconnects = <Completer<void>>[];
    Future<void> connect(String id, bool files, String namespace) {
      expect(namespace, scope);
      final result = Completer<void>();
      reconnects.add(result);
      return result.future;
    }

    await tester.pumpWidget(page(api, onReconnect: connect));
    await tester.pumpAndSettle();
    final button = find.byKey(const ValueKey('niko-audit-reconnect-$session'));
    await tester.scrollUntilVisible(button, 250,
        scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    await tester.tap(button);
    await tester.pump();
    await tester
        .pumpWidget(page(api, namespace: 'c' * 64, onReconnect: connect));
    reconnects.single.completeError(StateError('Old scope response'));
    await tester.pumpAndSettle();
    expect(find.text('尚无已保存的原生会话结果。'), findsOneWidget);
    expect(find.text('无法发起连接，请重试。'), findsNothing);
    await tester.pumpWidget(page(api, onReconnect: connect));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(button, 250,
        scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    await tester.tap(button);
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    reconnects.last.completeError(StateError('Disposed response'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
