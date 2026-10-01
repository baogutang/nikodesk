import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_hbb/nikodesk/cm_camera.dart';
import 'package:flutter_hbb/nikodesk/cm_camera_panel.dart';
import 'package:flutter_hbb/nikodesk/theme.dart';
import 'package:flutter_hbb/nikodesk/ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'nikodesk_cm_camera_test.dart'
    show cameraStatus, cameraCatalog, cameraIdentity, macFormat;

NikoCameraStatus _status(
        {String phase = 'Pending',
        String revision = '1',
        String namespace = 'a'}) =>
    NikoCameraStatus.parse(jsonEncode(
        cameraStatus(phase: phase, revision: revision, namespace: namespace)))!;
NikoCameraCatalog _catalog(
        {String revision = '1',
        String namespace = 'a',
        String authorization = 'authorized',
        bool mac = false}) =>
    NikoCameraCatalog.parse(jsonEncode(cameraCatalog(
        revision: revision,
        namespace: namespace,
        authorization: authorization,
        formats: mac ? [macFormat()] : null)))!;
String _queued(String json) {
  final request = jsonDecode(json);
  return jsonEncode({
    'ok': true,
    'status': 'queued',
    'identity': request['identity'],
    'revision': request['revision'],
    'reason': '',
  });
}

Widget _host(NikoCameraStatus status, Future<String> Function(String) command,
        {NikoCameraCatalog? catalog,
        double scale = 1,
        bool dark = false,
        bool canRequestSystemPermission = false,
        bool cleanupUnconfirmed = false,
        bool cleanupOnly = false,
        Future<bool> Function()? refreshStatus}) =>
    MaterialApp(
        theme: nikoTheme(dark ? Brightness.dark : Brightness.light),
        home: Builder(
            builder: (context) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(scale)),
                child: Scaffold(
                    body: SingleChildScrollView(
                        child: NikoCameraCapabilityPanel(
                            status: status,
                            catalog: catalog,
                            canRequestSystemPermission:
                                canRequestSystemPermission,
                            cleanupUnconfirmed: cleanupUnconfirmed,
                            cleanupOnly: cleanupOnly,
                            refreshStatus: refreshStatus,
                            sendCommand: command))))));

Future<void> _chooseWindows(WidgetTester tester) async {
  await tester.ensureVisible(find.byKey(const ValueKey('niko-camera-device')));
  await tester.tap(find.byKey(const ValueKey('niko-camera-device')));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Camera name').last);
  await tester.pumpAndSettle();
  await tester.ensureVisible(find.byKey(const ValueKey('niko-camera-format')));
  await tester.tap(find.byKey(const ValueKey('niko-camera-format')));
  await tester.pumpAndSettle();
  await tester.tap(find.text('1920 × 1080 · 30000/1001 FPS').last);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
      'retired camera panel only retries cleanup and cannot rediscover or approve',
      (tester) async {
    final sent = <String>[];
    await tester.pumpWidget(
        _host(_status(phase: 'RecoveryRequired', revision: '2'), (json) async {
      sent.add(json);
      return _queued(json);
    }, cleanupOnly: true, catalog: _catalog(revision: '2')));
    expect(find.text('读取本机摄像头'), findsNothing);
    expect(find.text('选择并授权此会话'), findsNothing);
    expect(find.byKey(const ValueKey('niko-camera-device')), findsNothing);
    await tester.tap(find.text('重试摄像头清理'));
    await tester.pumpAndSettle();
    expect(jsonDecode(sent.single)['op'], 'retry_cleanup');
    expect(jsonDecode(sent.single)['identity'], cameraIdentity());
    await tester.pumpWidget(
        _host(_status(phase: 'Stopped', revision: '3'), (json) async {
      sent.add(json);
      return _queued(json);
    }, cleanupOnly: true));
    expect(find.text('重试摄像头清理'), findsNothing);
    expect(find.text('读取本机摄像头'), findsNothing);
    expect(sent.length, 1);
  });

  tearDown(() => NikoLanguage.english = false);
  testWidgets(
      'opening panel never enumerates, asks OS permission or starts capture',
      (tester) async {
    final sent = <String>[];
    await tester.pumpWidget(_host(_status(), (json) async {
      sent.add(json);
      return _queued(json);
    }));
    await tester.pumpAndSettle();
    expect(sent, isEmpty);
    await tester.tap(find.text('读取本机摄像头'));
    await tester.pumpAndSettle();
    expect(jsonDecode(sent.single)['op'], 'enumerate');
    expect(find.text('摄像头等待本机授权'), findsOneWidget);
    expect(find.text('本机摄像头正在运行'), findsNothing);
  });
  testWidgets('system permission is a separate explicit local command',
      (tester) async {
    final sent = <String>[];
    await tester.pumpWidget(_host(_status(), (json) async {
      sent.add(json);
      return _queued(json);
    },
        catalog: _catalog(authorization: 'not_determined'),
        canRequestSystemPermission: true));
    expect(sent, isEmpty);
    await tester.tap(find.text('请求本机系统许可'));
    await tester.pumpAndSettle();
    final request = jsonDecode(sent.single);
    expect(request['op'], 'request_permission');
    expect(request.containsKey('format_token'), isFalse);
    expect(find.text('本机摄像头正在运行'), findsNothing);
  });
  testWidgets(
      'approval requires device, exact format and confirmation without a default',
      (tester) async {
    final sent = <String>[];
    await tester.pumpWidget(_host(_status(), (json) async {
      sent.add(json);
      return _queued(json);
    }, catalog: _catalog()));
    expect(find.byType(FilledButton), findsNothing);
    await _chooseWindows(tester);
    await tester.tap(find.text('选择并授权此会话'));
    await tester.pumpAndSettle();
    expect(sent, isEmpty);
    await tester.tap(find.descendant(
        of: find.byType(AlertDialog), matching: find.text('允许此会话')));
    await tester.pumpAndSettle();
    final request = jsonDecode(sent.single);
    expect(request['identity'], cameraIdentity());
    expect(request['op'], 'approve');
    expect(request['uid'], 'native-exact-uid');
    expect(request['roster_revision'], '7');
    expect(request['format_token'], 'd' * 32);
    expect(request.containsKey('fps'), isFalse);
    expect(find.text('本机摄像头正在运行'), findsNothing);
  });
  testWidgets(
      'Mac integer FPS must be explicitly entered within selected native range',
      (tester) async {
    final sent = <String>[];
    await tester.pumpWidget(_host(_status(), (json) async {
      sent.add(json);
      return _queued(json);
    }, catalog: _catalog(mac: true)));
    await tester.tap(find.byKey(const ValueKey('niko-camera-device')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Camera name').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('niko-camera-format')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('1280 × 720 · 15.0–60.0 FPS').last);
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull);
    await tester.enterText(find.byKey(const ValueKey('niko-camera-fps')), '14');
    await tester.pump();
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull);
    await tester.enterText(find.byKey(const ValueKey('niko-camera-fps')), '30');
    await tester.pump();
    await tester.ensureVisible(find.text('选择并授权此会话'));
    await tester.tap(find.text('选择并授权此会话'));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(
        of: find.byType(AlertDialog), matching: find.text('允许此会话')));
    await tester.pumpAndSettle();
    expect(jsonDecode(sent.single)['fps'], 30);
    expect(jsonDecode(sent.single)['format_token'], 'e' * 32);
  });
  testWidgets(
      'confirmation cannot grant an identity or roster replaced while dialog is open',
      (tester) async {
    final sent = <String>[];
    Future<String> send(String json) async {
      sent.add(json);
      return _queued(json);
    }

    await tester.pumpWidget(_host(_status(), send, catalog: _catalog()));
    await _chooseWindows(tester);
    await tester.tap(find.text('选择并授权此会话'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(_host(_status(namespace: 'f'), send,
        catalog: _catalog(namespace: 'f')));
    await tester.tap(find.descendant(
        of: find.byType(AlertDialog), matching: find.text('允许此会话')));
    await tester.pumpAndSettle();
    expect(sent, isEmpty);
    expect(find.byType(FilledButton), findsNothing);
  });
  testWidgets(
      'unconfirmed revoke blocks reselection until authoritative stopped, late reply cannot unblock',
      (tester) async {
    final pending = Completer<String>();
    final sent = <String>[];
    Future<String> send(String json) {
      sent.add(json);
      return pending.future;
    }

    await tester.pumpWidget(_host(_status(phase: 'Running'), send));
    await tester.tap(find.text('停止并撤销摄像头访问'));
    await tester.pump();
    expect(jsonDecode(sent.single)['op'], 'revoke');
    await tester.pump(const Duration(seconds: 5));
    await tester.pump();
    expect(find.text('本机摄像头正在运行'), findsOneWidget);
    await tester.pumpWidget(
        _host(_status(revision: '2'), send, catalog: _catalog(revision: '2')));
    expect(find.byKey(const ValueKey('niko-camera-device')), findsNothing);
    expect(find.text('重试摄像头清理'), findsOneWidget);
    pending.complete(_queued(sent.single));
    await tester.pump();
    expect(find.byKey(const ValueKey('niko-camera-device')), findsNothing);
    await tester
        .pumpWidget(_host(_status(phase: 'Stopped', revision: '3'), send));
    expect(find.text('本机摄像头已停止'), findsOneWidget);
    expect(find.text('重试摄像头清理'), findsNothing);
  });
  testWidgets(
      'old action result cannot alter a new namespace or release its busy action',
      (tester) async {
    final old = Completer<String>();
    final current = Completer<String>();
    final sent = <String>[];
    Future<String> send(String json) {
      sent.add(json);
      return sent.length == 1 ? old.future : current.future;
    }

    await tester.pumpWidget(_host(_status(), send));
    await tester.tap(find.text('拒绝本次请求'));
    await tester.pump();
    await tester.pumpWidget(_host(_status(namespace: 'f'), send));
    await tester.tap(find.text('拒绝本次请求'));
    await tester.pump();
    old.complete(_queued(sent.first));
    await tester.pump();
    expect(find.text('请求已发送，等待原生资源状态确认。'), findsNothing);
    expect(
        tester
            .widget<OutlinedButton>(
                find.widgetWithText(OutlinedButton, '拒绝本次请求'))
            .onPressed,
        isNull);
    current.complete(_queued(sent.last));
    await tester.pump();
    expect(find.text('请求已发送，等待原生资源状态确认。'), findsOneWidget);
  });
  testWidgets(
      'recovery is distinct from stopped and retry only targets captured identity',
      (tester) async {
    final sent = <String>[];
    await tester
        .pumpWidget(_host(_status(phase: 'RecoveryRequired'), (json) async {
      sent.add(json);
      return _queued(json);
    }));
    expect(find.text('摄像头停止尚未确认'), findsOneWidget);
    expect(find.text('读取本机摄像头'), findsNothing);
    await tester.tap(find.text('重试摄像头清理'));
    await tester.pumpAndSettle();
    expect(jsonDecode(sent.single)['identity'], cameraIdentity());
    expect(jsonDecode(sent.single)['op'], 'retry_cleanup');
    expect(find.text('本机摄像头已停止'), findsNothing);
  });
  testWidgets('backend raw errors are not displayed', (tester) async {
    await tester.pumpWidget(_host(_status(),
        (_) async => throw StateError('/Users/private-camera/secret')));
    await tester.tap(find.text('读取本机摄像头'));
    await tester.pumpAndSettle();
    expect(find.textContaining('private-camera'), findsNothing);
    expect(find.text('本机摄像头授权通道不可用，请查看会话状态后重试。'), findsOneWidget);
  });
  testWidgets(
      'Windows permission guidance is explicit and never implies an OS popup',
      (tester) async {
    final sent = <String>[];
    await tester.pumpWidget(_host(_status(), (json) async {
      sent.add(json);
      return _queued(json);
    }, catalog: _catalog(authorization: 'denied')));
    expect(find.text('请求本机系统许可'), findsNothing);
    await tester.tap(find.text('查看系统许可要求'));
    await tester.pumpAndSettle();
    expect(jsonDecode(sent.single)['op'], 'request_permission');
    expect(find.text('本机摄像头正在运行'), findsNothing);
  });
  testWidgets(
      'metadata-only Windows device probe sends only current captured UID and identity',
      (tester) async {
    final sent = <String>[];
    final catalog =
        NikoCameraCatalog.parse(jsonEncode(cameraCatalog(formats: [])))!;
    await tester.pumpWidget(_host(_status(), (json) async {
      sent.add(json);
      return _queued(json);
    }, catalog: catalog));
    await tester.tap(find.byKey(const ValueKey('niko-camera-device')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Camera name').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('读取所选设备格式'));
    await tester.pumpAndSettle();
    final request = jsonDecode(sent.single);
    expect(request['op'], 'probe');
    expect(request['uid'], 'native-exact-uid');
    expect(request['identity'], cameraIdentity());
    expect(request['revision'], '1');
    expect(request.containsKey('roster_revision'), isFalse);
    expect(request.containsKey('format_token'), isFalse);
    expect(request.containsKey('fps'), isFalse);
    expect(find.byType(FilledButton), findsNothing);
  });
  testWidgets('a recreated panel respects connection-owned unconfirmed cleanup',
      (tester) async {
    await tester.pumpWidget(_host(_status(), (json) async => _queued(json),
        catalog: _catalog(), cleanupUnconfirmed: true));
    expect(find.byKey(const ValueKey('niko-camera-device')), findsNothing);
    expect(find.text('读取本机摄像头'), findsNothing);
    expect(find.text('重试摄像头清理'), findsOneWidget);
  });
  testWidgets(
      'camera local action has readable button semantics, keyboard activation and 48px target',
      (tester) async {
    final semantics = tester.ensureSemantics();
    try {
      final sent = <String>[];
      await tester.pumpWidget(_host(_status(), (json) async {
        sent.add(json);
        return _queued(json);
      }));
      final button = find.widgetWithText(OutlinedButton, '读取本机摄像头');
      expect(tester.getSize(button).height, greaterThanOrEqualTo(48));
      expect(
          tester
              .getSemantics(button)
              .getSemanticsData()
              .hasAction(SemanticsAction.tap),
          isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(jsonDecode(sent.single)['op'], 'enumerate');
    } finally {
      semantics.dispose();
    }
  });
  testWidgets(
      'status refresh has finite wait and late result cannot alter replacement identity',
      (tester) async {
    final old = Completer<bool>();
    await tester.pumpWidget(_host(_status(), (json) async => _queued(json),
        refreshStatus: () => old.future));
    await tester.tap(find.text('刷新本机会话状态'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 5));
    await tester.pump();
    expect(find.text('会话状态读取未确认，选择与启动保持原有限制。'), findsOneWidget);
    await tester.pumpWidget(_host(
        _status(namespace: 'f'), (json) async => _queued(json),
        refreshStatus: () async => true));
    old.complete(true);
    await tester.pump();
    expect(find.text('已读取本机会话状态，请按上方状态操作。'), findsNothing);
    await tester.tap(find.text('刷新本机会话状态'));
    await tester.pumpAndSettle();
    expect(find.text('已读取本机会话状态，请按上方状态操作。'), findsOneWidget);
  });
  for (final english in [false, true]) {
    for (final dark in [false, true]) {
      testWidgets(
          'camera panel 320px 200% with choices english=$english dark=$dark',
          (tester) async {
        NikoLanguage.english = english;
        await tester.binding.setSurfaceSize(const Size(320, 1200));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(_host(_status(), (json) async => _queued(json),
            catalog: _catalog(), scale: 2, dark: dark));
        await _chooseWindows(tester);
        final allow =
            find.text(english ? 'Select and approve this session' : '选择并授权此会话');
        await tester.ensureVisible(allow);
        await tester.tap(allow);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.tap(find.descendant(
            of: find.byType(AlertDialog),
            matching: find.text(english ? 'Cancel' : '取消')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      });
    }
  }
}
