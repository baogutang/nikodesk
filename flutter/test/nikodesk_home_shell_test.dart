import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/nikodesk/device_store.dart';
import 'package:flutter_hbb/nikodesk/home_shell.dart';
import 'package:flutter_hbb/nikodesk/policy.dart';
import 'package:flutter_hbb/nikodesk/server_gateway.dart';
import 'package:flutter_hbb/nikodesk/session_log.dart';
import 'package:flutter_hbb/nikodesk/ui.dart';

class _ServerDouble implements ServerGateway {
  ServerSnapshot snapshot;
  _ServerDouble(this.snapshot);
  @override
  Future<ServerSnapshot> read() async => snapshot;
  @override
  Future<void> save(PrivateServerConfig config) async {
    snapshot = ServerSnapshot(config, null, true);
  }
}

void main() {
  late Directory directory;
  late DeviceStore store;
  late SessionLogStore sessionLog;
  setUp(() async {
    NikoLanguage.english = false;
    directory = await Directory.systemTemp.createTemp('nikodesk-shell-test-');
    store = DeviceStore(directory);
    sessionLog = SessionLogStore(directory);
  });
  tearDown(() async => directory.delete(recursive: true));

  Future<void> loadShell(WidgetTester tester, NikoHomeShell shell, {Size size = const Size(1100, 800), double scale = 1, bool deferSetup = true}) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.runAsync(() async {
      await tester.pumpWidget(MaterialApp(builder: (context, child) => MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)), child: child!), home: Scaffold(body: shell)));
      for (var i = 0; i < 250; i++) {
        await tester.pump();
        if (deferSetup && find.text('稍后配置').evaluate().isNotEmpty) {
          await tester.ensureVisible(find.text('稍后配置'));
          await tester.tap(find.text('稍后配置'));
          await tester.pump();
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
        if (find
            .byType(CircularProgressIndicator, skipOffstage: false)
            .evaluate()
            .isEmpty) break;
      }
    });
    await tester.pumpAndSettle();
  }

  NikoHomeShell shell(_ServerDouble gateway,
          {String deviceId = '1000000001',
          Future<void> Function(BuildContext, String, bool,
                  {bool isFileTransfer, String? password})?
              onConnect}) =>
      NikoHomeShell(
          store: store,
          gateway: gateway,
          sessionLog: sessionLog,
          onConnect: onConnect,
          deviceIdProvider: () => deviceId,
          temporaryPasswordProvider: () async => '12345678',
          screenRecordingProbe: () => true,
          accessibilityProbe: () => true);

  testWidgets('shell shows local identity, permissions and server state',
      (tester) async {
    final gateway = _ServerDouble(ServerSnapshot(
        PrivateServerConfig('private.example', 'private.example:21117',
            base64Encode(List.filled(32, 1))),
        1,
        true));
    await loadShell(tester, shell(gateway));
    expect(find.text('NikoDesk'), findsOneWidget);
    expect(find.text('1000000001'), findsOneWidget);
    expect(find.text('设置永久密码'), findsOneWidget);
    expect(find.text('已就绪'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('first desktop setup saves then opens the device workspace',
      (tester) async {
    final gateway = _ServerDouble(
        const ServerSnapshot(PrivateServerConfig('', '', ''), null, false));
    await loadShell(tester, shell(gateway), deferSetup: false);
    expect(find.text('连接自己的服务器'), findsOneWidget);
    expect(find.text('我的设备'), findsNothing);
    await tester.enterText(find.byType(TextFormField).at(0), 'test.invalid:21116');
    await tester.enterText(find.byType(TextFormField).at(1), 'test.invalid:21117');
    await tester.enterText(
        find.byType(TextFormField).at(2), base64Encode(List.filled(32, 1)));
    await tester.ensureVisible(find.text('保存并启用私服'));
    await tester.runAsync(() async {
      await tester.tap(find.text('保存并启用私服'));
      for (var i = 0; i < 30; i++) {
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    await tester.pumpAndSettle();
    expect(gateway.snapshot.config.isValid, isTrue);
    expect(find.text('我的设备'), findsOneWidget);
    expect(find.text('连接自己的服务器'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  for (final scale in [1.0, 2.0]) {
    testWidgets('local ID is fully painted at ${scale * 100}% text size',
        (tester) async {
      const id = '1 234 567 890 123 456';
      final gateway = _ServerDouble(
          const ServerSnapshot(PrivateServerConfig('', '', ''), null, false));
      await loadShell(tester, shell(gateway, deviceId: id),
          size: scale == 1 ? const Size(1100, 800) : const Size(800, 600),
          scale: scale);
      if (scale == 2) {
        await tester.tap(find.byTooltip('打开导航'));
        await tester.pumpAndSettle();
      }
      final paragraph = tester.renderObject<RenderParagraph>(find.text(id));
      expect(paragraph.didExceedMaxLines, isFalse);
      expect(paragraph.textScaler.scale(19), 19 * scale);
      for (var offset = 0; offset < id.length; offset++) {
        if (id[offset] == ' ') continue;
        final boxes = paragraph.getBoxesForSelection(
            TextSelection(baseOffset: offset, extentOffset: offset + 1));
        expect(boxes, isNotEmpty, reason: 'Digit $offset must be painted');
        for (final box in boxes) {
          expect(box.left, greaterThanOrEqualTo(-.01));
          expect(box.right, lessThanOrEqualTo(paragraph.size.width + .01));
          expect(box.bottom, lessThanOrEqualTo(paragraph.size.height + .01));
        }
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('navigation covers devices, sessions, settings and advanced',
      (tester) async {
    final gateway = _ServerDouble(
        const ServerSnapshot(PrivateServerConfig('', '', ''), null, false));
    await loadShell(tester, shell(gateway));
    expect(find.text('我的设备'), findsOneWidget);

    await tester.tap(find.text('会话'));
    await tester.pumpAndSettle();
    expect(find.text('还没有连接记录'), findsOneWidget);

    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    expect(find.text('配置服务器'), findsOneWidget);

    await tester.tap(find.text('高级设置'));
    await tester.pumpAndSettle();
    // Widget tests never construct the upstream page (it reads native
    // options); the shell shows an explicit placeholder instead.
    expect(find.textContaining('高级设置仅在应用内提供'), findsOneWidget);

    await tester.tap(find.text('设备'));
    await tester.pumpAndSettle();
    expect(find.text('我的设备'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('device settings icon routes into the shell settings page',
      (tester) async {
    final gateway = _ServerDouble(
        const ServerSnapshot(PrivateServerConfig('', '', ''), null, false));
    await loadShell(tester, shell(gateway));
    await tester.tap(find.byTooltip('设置'));
    await tester.pumpAndSettle();
    expect(find.text('配置服务器'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('recorded sessions surface in the history page', (tester) async {
    await tester.runAsync(() => sessionLog.record(SessionLogEntry(
        id: '123456',
        alias: 'Office',
        fileTransfer: true,
        forceRelay: true,
        startedAt: DateTime.utc(2026, 9, 29, 1, 2, 3))));
    String? requested;
    String? usedPassword;
    bool file = false;
    final gateway = _ServerDouble(ServerSnapshot(
        PrivateServerConfig(
            'nas:21116', 'nas:21117', base64Encode(List.filled(32, 1))),
        1,
        true));
    await loadShell(
        tester,
        shell(gateway, onConnect: (_, id, relay,
            {isFileTransfer = false, password}) async {
          requested = id;
          file = isFileTransfer;
          usedPassword = password;
        }));
    await tester.tap(find.text('会话'));
    await tester.pumpAndSettle();
    expect(find.text('Office'), findsOneWidget);
    await tester.tap(find.text('传文件'));
    await tester.pumpAndSettle();
    // Reconnecting from history also requires the remote password here.
    await tester.enterText(
        find.byKey(const Key('nikodesk-connect-password')), 'secret123');
    await tester.tap(find.byKey(const Key('nikodesk-connect-submit')));
    await tester.pumpAndSettle();
    expect(requested, '123456');
    expect(file, isTrue);
    expect(usedPassword, 'secret123');
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('server card opens settings and history refreshes when selected',
      (tester) async {
    final gateway = _ServerDouble(
        const ServerSnapshot(PrivateServerConfig('', '', ''), null, false));
    await loadShell(tester, shell(gateway));
    await tester.tap(find.text('私有服务器'));
    await tester.pumpAndSettle();
    expect(find.text('配置服务器'), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.text('会话'));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 150));
    });
    await tester.pumpAndSettle();
    expect(find.text('还没有连接记录'), findsOneWidget);
    await tester.tap(find.text('设备'));
    await tester.pump();
    await tester.runAsync(() => sessionLog.record(SessionLogEntry(
        id: '234567',
        alias: 'Newly initiated',
        startedAt: DateTime.utc(2026, 9, 30))));
    await tester.runAsync(() async {
      await tester.tap(find.text('会话'));
      await tester.pump();
      for (var i = 0; i < 20; i++) {
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    await tester.pumpAndSettle();
    expect(find.text('Newly initiated'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('settings language change updates the shell immediately',
      (tester) async {
    final gateway = _ServerDouble(
        const ServerSnapshot(PrivateServerConfig('', '', ''), null, false));
    await loadShell(tester, shell(gateway));
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('English'));
    await tester.tap(find.text('English'));
    await tester.pumpAndSettle();
    expect(find.text('Devices'), findsOneWidget);
    expect(find.text('Sessions'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('narrow desktop navigation remains reachable at 200% text', (tester) async {
    final gateway = _ServerDouble(ServerSnapshot(
        PrivateServerConfig('private.example', 'private.example:21117', base64Encode(List.filled(32, 1))), 1, true));
    await tester.runAsync(() => store.save(const DeviceEntry(id: '123456', alias: 'Office')));
    await loadShell(tester, shell(gateway), size: const Size(800, 600), scale: 2);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('打开导航'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('会话').first);
    await tester.tap(find.text('会话').first);
    await tester.pumpAndSettle();
    expect(find.text('还没有连接记录'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('favorite remains on the first desktop screen at 800x600/150%',
      (tester) async {
    await tester.runAsync(() => store.save(
        const DeviceEntry(id: '123456', alias: 'Office', favorite: true)));
    final gateway = _ServerDouble(ServerSnapshot(
        PrivateServerConfig('test.invalid:21116', 'test.invalid:21117',
            base64Encode(List.filled(32, 1))), 1, true));
    await loadShell(tester, shell(gateway), size: const Size(800, 600), scale: 1.5);
    expect(find.byKey(const Key('nikodesk-device-connect-123456')).hitTestable(), findsOneWidget);
    expect(find.byKey(const Key('nikodesk-hero-password')), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

}
