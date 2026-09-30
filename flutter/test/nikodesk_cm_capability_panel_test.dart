import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_hbb/nikodesk/cm_capabilities.dart';
import 'package:flutter_hbb/nikodesk/cm_capability_panel.dart';
import 'package:flutter_hbb/nikodesk/ui.dart';
import 'package:flutter_test/flutter_test.dart';

NikoCapabilityStatus _status(
        {String phase = 'Pending', String namespace = 'a'}) =>
    NikoCapabilityStatus(
        NikoCapabilityIdentity(
            12, namespace * 64, '123456789', 'b' * 32, 'c' * 32, '1'),
        'Local user UID 501',
        phase,
        'Native status',
        '1');

Widget _host(NikoCapabilityStatus status, Future<String> Function(String) send,
        {double scale = 1}) =>
    MaterialApp(
        home: Builder(
            builder: (context) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(scale)),
                child: Scaffold(
                    body: SingleChildScrollView(
                        child: NikoTerminalCapabilityPanel(
                            status: status,
                            sendDecision: send,
                            sendRevoke: send))))));

void main() {
  tearDown(() => NikoLanguage.english = false);
  testWidgets('unresponsive local decision remains unconfirmed and can retry',
      (tester) async {
    final response = Completer<String>();
    await tester.pumpWidget(_host(_status(), (_) => response.future));
    await tester.tap(find.text('拒绝'));
    await tester.pump();
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull);
    await tester.pump(const Duration(seconds: 5));
    await tester.pump();
    expect(find.text('请求结果尚未确认，请查看实际终端状态。'), findsOneWidget);
    expect(find.text('终端正在运行'), findsNothing);
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNotNull);
    response.complete('{"ok":true,"status":"queued"}');
    await tester.pump();
    expect(find.text('请求结果尚未确认，请查看实际终端状态。'), findsOneWidget);
    expect(find.text('请求已发送，等待实际资源状态确认。'), findsNothing);
  });
  testWidgets('replaced request retires busy action and ignores its late reply',
      (tester) async {
    final first = Completer<String>();
    final second = Completer<String>();
    final sent = <String>[];
    Future<String> send(String json) {
      sent.add(json);
      return sent.length == 1 ? first.future : second.future;
    }

    await tester.pumpWidget(_host(_status(), send));
    await tester.tap(find.text('拒绝'));
    await tester.pump();
    await tester.pumpWidget(_host(_status(namespace: 'd'), send));
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNotNull);
    await tester.tap(find.text('拒绝'));
    await tester.pump();
    expect(sent, hasLength(2));
    expect(jsonDecode(sent.last)['identity'],
        _status(namespace: 'd').identity.toJson());
    first.complete('{"ok":true,"status":"queued"}');
    await tester.pump();
    expect(find.text('请求已发送，等待实际资源状态确认。'), findsNothing);
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull);
    second.complete('{"ok":true,"status":"queued"}');
    await tester.pump();
    expect(find.text('请求已发送，等待实际资源状态确认。'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNotNull);
  });
  testWidgets('approval requires confirmation and queued is never running',
      (tester) async {
    final sent = <String>[];
    Future<String> send(String json) async {
      sent.add(json);
      return '{"ok":true,"status":"queued"}';
    }

    await tester.pumpWidget(_host(_status(), send));
    await tester.tap(find.text('允许此会话'));
    await tester.pumpAndSettle();
    expect(sent, isEmpty);
    await tester.tap(find.descendant(
        of: find.byType(AlertDialog), matching: find.text('允许此会话')));
    await tester.pumpAndSettle();
    expect(jsonDecode(sent.single)['identity'], _status().identity.toJson());
    expect(jsonDecode(sent.single)['approve'], isTrue);
    expect(find.text('请求已发送，等待实际资源状态确认。'), findsOneWidget);
    expect(find.text('终端等待本机授权'), findsOneWidget);
    expect(find.text('终端正在运行'), findsNothing);
  });
  testWidgets('dialog never grants a request replaced with another namespace',
      (tester) async {
    final sent = <String>[];
    Future<String> send(String json) async {
      sent.add(json);
      return '{"ok":true,"status":"queued"}';
    }

    await tester.pumpWidget(_host(_status(), send));
    await tester.tap(find.text('允许此会话'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(_host(_status(namespace: 'd'), send));
    await tester.tap(find.descendant(
        of: find.byType(AlertDialog), matching: find.text('允许此会话')));
    await tester.pumpAndSettle();
    expect(sent, isEmpty);
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNotNull);
  });
  testWidgets(
      'unknown cleanup retries original identity and waits for actual stopped event',
      (tester) async {
    final sent = <String>[];
    Future<String> send(String json) async {
      sent.add(json);
      return '{"ok":true,"status":"queued"}';
    }

    await tester.pumpWidget(_host(_status(phase: 'RecoveryRequired'), send));
    await tester.tap(find.text('重试清理'));
    await tester.pumpAndSettle();
    expect(jsonDecode(sent.single), _status().identity.toJson());
    expect(find.text('终端清理尚未确认'), findsOneWidget);
    expect(find.text('终端已停止'), findsNothing);
    await tester.pumpWidget(_host(_status(phase: 'Stopped'), send));
    await tester.pumpAndSettle();
    expect(find.text('终端已停止'), findsOneWidget);
    expect(find.text('请求已发送，等待实际资源状态确认。'), findsNothing);
  });
  testWidgets('transport failure cannot imply a grant or cleanup success',
      (tester) async {
    await tester.pumpWidget(_host(
        _status(phase: 'Running'), (_) async => throw StateError('offline')));
    await tester.tap(find.text('撤销终端访问'));
    await tester.pumpAndSettle();
    expect(find.text('本机授权通道不可用，请重试。'), findsOneWidget);
    expect(find.text('终端正在运行'), findsOneWidget);
    expect(find.text('终端已停止'), findsNothing);
  });
  testWidgets('approval remains usable in English at 320px and 200% scaling',
      (tester) async {
    NikoLanguage.english = true;
    await tester.binding.setSurfaceSize(const Size(320, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_host(
        _status(), (_) async => '{"ok":true,"status":"queued"}',
        scale: 2));
    await tester.tap(find.text('Allow this session'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Terminal waiting for local approval'), findsOneWidget);
  });
}
