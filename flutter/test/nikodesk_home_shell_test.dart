import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/nikodesk/device_store.dart';
import 'package:flutter_hbb/nikodesk/home_shell.dart';
import 'package:flutter_hbb/nikodesk/history_kit.dart';
import 'package:flutter_hbb/nikodesk/nightline.dart';
import 'package:flutter_hbb/nikodesk/policy.dart';
import 'package:flutter_hbb/nikodesk/server_gateway.dart';
import 'package:flutter_hbb/nikodesk/session_log.dart';
import 'package:flutter_hbb/nikodesk/ui.dart';

class _ServerDouble implements ServerGateway {
  ServerSnapshot snapshot;
  bool failRead = false;
  Future<ServerSnapshot> Function()? onRead;
  _ServerDouble(this.snapshot);
  @override
  Future<ServerSnapshot> read() async {
    if (onRead != null) return onRead!();
    if (failRead) throw const FormatException('Unconfirmed native settings');
    return snapshot;
  }
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
    // Granted permissions read like the server's state, not as a code.
    expect(find.text('已授权'), findsNWidgets(Platform.isMacOS ? 2 : 0));
    expect(find.text('OK'), findsNothing);
    expect(find.byType(BackdropFilter, skipOffstage: false), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('failed settings read stays unknown rather than unconfigured',
      (tester) async {
    final gateway = _ServerDouble(ServerSnapshot(
        PrivateServerConfig('private.example', 'private.example:21117',
            base64Encode(List.filled(32, 1))),
        1,
        true))..failRead = true;
    await loadShell(tester, shell(gateway));
    await tester.runAsync(() async {
      await tester.tap(find.text('进入首页'));
      for (var i = 0; i < 30; i++) {
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    await tester.pumpAndSettle();
    expect(find.text('配置状态未知'), findsOneWidget);
    expect(find.text('未配置'), findsNothing);
    expect(find.text('已就绪'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('late status read cannot replace a newer server observation',
      (tester) async {
    final oldRead = Completer<ServerSnapshot>();
    final old = ServerSnapshot(
        PrivateServerConfig('old.example', 'old.example:21117',
            base64Encode(List.filled(32, 1))), 1, true);
    final current = ServerSnapshot(
        PrivateServerConfig('current.example', 'current.example:21117',
            base64Encode(List.filled(32, 2))), 1, true);
    var blockNextRead = false;
    final gateway = _ServerDouble(old);
    gateway.onRead = () {
      if (blockNextRead) {
        blockNextRead = false;
        return oldRead.future;
      }
      return Future.value(gateway.snapshot);
    };
    await loadShell(tester, shell(gateway));
    blockNextRead = true;
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 3100));
      gateway.snapshot = current;
      await Future<void>.delayed(const Duration(milliseconds: 3100));
      await tester.pump();
    });
    await tester.pumpAndSettle();
    expect(find.text('current.example'), findsOneWidget);
    oldRead.complete(old);
    await tester.pumpAndSettle();
    expect(find.text('current.example'), findsOneWidget);
    expect(find.text('old.example'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('first desktop setup saves then opens the device workspace',
      (tester) async {
    final gateway = _ServerDouble(
        const ServerSnapshot(PrivateServerConfig('', '', ''), null, false));
    await loadShell(tester, shell(gateway), deferSetup: false);
    expect(find.text('连接自己的服务器'), findsOneWidget);
    expect(find.text('我的设备'), findsNothing);
    await tester.enterText(
        find.byKey(const ValueKey('niko-server-id')), 'test.invalid:21116');
    await tester.enterText(
        find.byKey(const ValueKey('niko-server-relay')), 'test.invalid:21117');
    await tester.enterText(find.byKey(const ValueKey('niko-server-key')),
        base64Encode(List.filled(32, 1)));
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
    expect(find.text('语言'), findsOneWidget);

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

  testWidgets('command palette routes into the shell settings page',
      (tester) async {
    final gateway = _ServerDouble(
        const ServerSnapshot(PrivateServerConfig('', '', ''), null, false));
    await loadShell(tester, shell(gateway));
    await tester.tap(find.text('搜索与命令'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(EditableText).last, '设置');
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
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

  Future<void> loadThemedShell(WidgetTester tester, NikoHomeShell shell,
      {required Brightness brightness, bool reduceMotion = false}) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.runAsync(() async {
      await tester.pumpWidget(MaterialApp(
          theme: ThemeData(brightness: brightness),
          builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(disableAnimations: reduceMotion),
              child: child!),
          home: Scaffold(body: shell)));
      for (var i = 0; i < 250; i++) {
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        if (find
            .byType(CircularProgressIndicator, skipOffstage: false)
            .evaluate()
            .isEmpty) break;
      }
    });
    await tester.pumpAndSettle();
  }

  for (final brightness in Brightness.values) {
    testWidgets('shell hosts its pages in the Nightline ${brightness.name} theme',
        (tester) async {
      final gateway = _ServerDouble(ServerSnapshot(
          PrivateServerConfig('private.example', 'private.example:21117',
              base64Encode(List.filled(32, 1))),
          1,
          true));
      await loadThemedShell(tester, shell(gateway), brightness: brightness);
      final page = tester.element(find.text('我的设备'));
      expect(NlColors.maybeOf(page), same(NlColors.forBrightness(brightness)));
      expect(find.byType(NlMark), findsOneWidget);
      expect(find.text('我的设备'), findsOneWidget);
      expect(find.text('READY'), findsOneWidget);
      expect(find.text('private.example'), findsOneWidget);
      await tester.tap(find.text('会话'));
      await tester.pumpAndSettle();
      expect(find.text('会话记录'), findsOneWidget);
      expect(find.text('还没有连接记录'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  for (final reduceMotion in [false, true]) {
    testWidgets(
        'page switch ${reduceMotion ? 'is instant with reduced motion' : 'slides in'}',
        (tester) async {
      final gateway = _ServerDouble(ServerSnapshot(
          PrivateServerConfig('private.example', 'private.example:21117',
              base64Encode(List.filled(32, 1))),
          1,
          true));
      await loadThemedShell(tester, shell(gateway),
          brightness: Brightness.dark, reduceMotion: reduceMotion);
      double opacity() => tester
          .widget<Opacity>(find.byKey(const ValueKey('nikodesk-shell-page')))
          .opacity;
      expect(opacity(), 1);
      await tester.tap(find.text('设置'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      if (reduceMotion) {
        expect(opacity(), 1);
      } else {
        expect(opacity(), lessThan(1));
      }
      await tester.pumpAndSettle();
      expect(opacity(), 1);
      expect(find.text('语言'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('settings and history pages render in Nightline inside the shell',
      (tester) async {
    await tester.runAsync(() => sessionLog.record(SessionLogEntry(
        id: '123456',
        alias: 'Office',
        forceRelay: true,
        startedAt: DateTime.utc(2026, 9, 29, 1, 2, 3))));
    final gateway = _ServerDouble(ServerSnapshot(
        PrivateServerConfig('private.example', 'private.example:21117',
            base64Encode(List.filled(32, 1))),
        1,
        true));
    await loadThemedShell(tester, shell(gateway), brightness: Brightness.dark);
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(NlSidebarItem, '外观'), findsOneWidget);
    await tester.tap(find.byKey(const Key('nikodesk-settings-nav-appearance')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('nikodesk-preset-orbit')), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.text('会话'));
      for (var i = 0; i < 20; i++) {
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    await tester.pumpAndSettle();
    expect(
        find.ancestor(
            of: find.text('Office'), matching: find.byType(NikoHistoryRow)),
        findsOneWidget);
    expect(find.text('中继'), findsOneWidget);
    expect(find.widgetWithText(NlButton, '连接'), findsOneWidget);
    expect(find.byTooltip('删除该记录'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('missing macOS permissions show the guide before the workspace',
      (tester) async {
    final gateway = _ServerDouble(ServerSnapshot(
        PrivateServerConfig('private.example', 'private.example:21117',
            base64Encode(List.filled(32, 1))),
        1,
        true));
    await loadShell(
        tester,
        NikoHomeShell(
            store: store,
            gateway: gateway,
            sessionLog: sessionLog,
            deviceIdProvider: () => '1000000001',
            temporaryPasswordProvider: () async => '12345678',
            screenRecordingProbe: () => false,
            accessibilityProbe: () => true));
    expect(find.text('让这台 Mac 可以被远程控制'), findsOneWidget);
    expect(find.text('1000000001'), findsNothing);
    await tester.tap(find.text('跳过，进入 NikoDesk'));
    // The device page reads its store from disk once it is shown.
    await tester.runAsync(() async {
      for (var i = 0; i < 250; i++) {
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        if (find
            .byType(CircularProgressIndicator, skipOffstage: false)
            .evaluate()
            .isEmpty) break;
      }
    });
    await tester.pumpAndSettle();
    expect(find.text('让这台 Mac 可以被远程控制'), findsNothing);
    expect(find.text('1000000001'), findsOneWidget);
    await tester.tap(find.text('授权'));
    await tester.pumpAndSettle();
    expect(find.text('让这台 Mac 可以被远程控制'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  }, skip: !Platform.isMacOS);

  // Last in the file: the loaded font stays registered for any test after it.
  group('with the bundled mono font', () {
    setUpAll(() async {
      final font = FontLoader(NlType.mono)
        ..addFont(rootBundle.load('assets/fonts/JetBrainsMono-Medium.ttf'));
      await font.load();
    });

    testWidgets('a grouped ten-digit local ID stays on one line',
        (tester) async {
      const id = '1 362 993 690';
      final gateway = _ServerDouble(
          const ServerSnapshot(PrivateServerConfig('', '', ''), null, false));
      await loadShell(tester, shell(gateway, deviceId: id));
      final paragraph = tester.renderObject<RenderParagraph>(find.text(id));
      final first = paragraph.getBoxesForSelection(
          const TextSelection(baseOffset: 0, extentOffset: 1));
      final last = paragraph.getBoxesForSelection(
          TextSelection(baseOffset: id.length - 1, extentOffset: id.length));
      expect(last.single.top, first.single.top);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
