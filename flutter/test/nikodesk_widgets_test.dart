import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/nikodesk/device_page.dart';
import 'package:flutter_hbb/nikodesk/device_store.dart';
import 'package:flutter_hbb/nikodesk/policy.dart';
import 'package:flutter_hbb/nikodesk/server_gateway.dart';
import 'package:flutter_hbb/nikodesk/server_settings.dart';
import 'package:flutter_hbb/nikodesk/ui.dart';

// Explicit UI-only test double. Production defaults to NativeServerGateway.
class _ServerDouble implements ServerGateway {
  ServerSnapshot snapshot;
  int saves = 0;
  Object? saveError;
  _ServerDouble(this.snapshot);
  @override
  Future<ServerSnapshot> read() async => snapshot;
  @override
  Future<void> save(PrivateServerConfig config) async {
    saves++;
    if (saveError != null) throw saveError!;
  }
}

void main() {
  late Directory directory;
  late DeviceStore store;
  setUp(() async {
    NikoLanguage.english = false;
    directory = await Directory.systemTemp.createTemp('nikodesk-widget-test-');
    store = DeviceStore(directory);
  });
  tearDown(() async => directory.delete(recursive: true));

  Future<void> loadPage(WidgetTester tester, Widget page,
      {ThemeData? theme, double scale = 1}) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(MaterialApp(
          theme: theme,
          home: Scaffold(
              body: MediaQuery(
                  data: MediaQueryData(textScaler: TextScaler.linear(scale)),
                  child: page))));
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

  testWidgets('unconfigured home shows setup and never starts a session',
      (tester) async {
    final gateway = _ServerDouble(
        const ServerSnapshot(PrivateServerConfig('', '', ''), null, false));
    await tester.runAsync(
        () => store.save(const DeviceEntry(id: '123456', alias: 'Office')));
    var calls = 0;
    await loadPage(
        tester,
        NikoDevicePage(
            store: store,
            gateway: gateway,
            onConnect: (_, __, ___, {isFileTransfer = false, password}) async {
              calls++;
            }));
    expect(find.text('先连接自己的服务器'), findsOneWidget);
    // Both connect entries must stay inert without a valid private server.
    await tester.tap(find.byKey(const Key('nikodesk-hero-connect')),
        warnIfMissed: false);
    await tester.tap(find.byKey(const Key('nikodesk-device-connect-123456')),
        warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(calls, 0);
    expect(find.textContaining('在线未知'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('default device order prioritizes favorites then recent authenticated use',
      (tester) async {
    await tester.runAsync(() async {
      for (final entry in [
        const DeviceEntry(id: '111111', alias: 'A favorite', favorite: true),
        DeviceEntry(id: '222222', alias: 'Z favorite', favorite: true,
            lastConnectedAt: DateTime.utc(2026, 9, 29)),
        DeviceEntry(id: '333333', alias: 'Z office',
            lastConnectedAt: DateTime.utc(2026, 9, 30)),
        DeviceEntry(id: '444444', alias: 'A laptop',
            lastConnectedAt: DateTime.utc(2026, 9, 28)),
        const DeviceEntry(id: '555555', alias: 'AAA new'),
      ]) await store.save(entry);
    });
    final gateway = _ServerDouble(ServerSnapshot(
        PrivateServerConfig('test.invalid:21116', 'test.invalid:21117',
            base64Encode(List.filled(32, 1))), 1, true));
    await loadPage(tester, NikoDevicePage(store: store, gateway: gateway));
    final keys = find.byWidgetPredicate((widget) => widget.key is ValueKey<String> &&
        (widget.key as ValueKey<String>).value.startsWith('nikodesk-device-connect-'));
    expect(keys.evaluate().map((element) => (element.widget.key as ValueKey<String>).value).toList(), [
      'nikodesk-device-connect-222222', 'nikodesk-device-connect-111111',
      'nikodesk-device-connect-333333', 'nikodesk-device-connect-444444',
      'nikodesk-device-connect-555555',
    ]);
    expect(find.text('自己的服务器，熟悉的工作空间。'), findsNothing);
    expect(find.byKey(const Key('nikodesk-hero-password')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'registered server stays distinct from device availability and connection attempts',
      (tester) async {
    final gateway = _ServerDouble(ServerSnapshot(
        PrivateServerConfig(
            'nas:21116', 'nas:21117', base64Encode(List.filled(32, 1))),
        1,
        true));
    await tester.runAsync(() => store.save(
        const DeviceEntry(id: '123456', alias: 'Office', forceRelay: true)));
    String? requested;
    String? usedPassword;
    await loadPage(
        tester,
        NikoDevicePage(
            store: store,
            gateway: gateway,
            onConnect: (_, id, forced,
                {isFileTransfer = false, password}) async {
              requested = id;
              usedPassword = password;
            }));
    expect(find.text('已注册'), findsOneWidget);
    await tester.tap(find.byKey(const Key('nikodesk-quick-connect')));
    await tester.pumpAndSettle();
    expect(find.textContaining('设备在线状态：未知'), findsOneWidget);
    await tester
        .ensureVisible(find.byKey(const Key('nikodesk-device-connect-123456')));
    await tester.tap(find.byKey(const Key('nikodesk-device-connect-123456')));
    await tester.pumpAndSettle();
    // The card path always demands the remote password in this client.
    expect(find.byKey(const Key('nikodesk-connect-password')), findsOneWidget);
    await tester.enterText(
        find.byKey(const Key('nikodesk-connect-password')), 'secret123');
    await tester.tap(find.byKey(const Key('nikodesk-connect-submit')));
    await tester.pumpAndSettle();
    expect(requested, '123456');
    expect(usedPassword, 'secret123');
    await tester.runAsync(() async =>
        expect((await store.load()).devices.single.lastConnectedAt, isNull));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'file transfer action requests a file session through the same gate',
      (tester) async {
    final gateway = _ServerDouble(ServerSnapshot(
        PrivateServerConfig(
            'nas:21116', 'nas:21117', base64Encode(List.filled(32, 1))),
        1,
        true));
    await tester.runAsync(
        () => store.save(const DeviceEntry(id: '123456', alias: 'Office')));
    String? requested;
    bool file = false;
    await loadPage(
        tester,
        NikoDevicePage(
            store: store,
            gateway: gateway,
            onConnect: (_, id, ___, {isFileTransfer = false, password}) async {
              requested = id;
              file = isFileTransfer;
            }));
    await tester.ensureVisible(find.byTooltip('文件传输'));
    await tester.tap(find.byTooltip('文件传输'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('nikodesk-connect-password')), 'secret123');
    await tester.tap(find.byKey(const Key('nikodesk-connect-submit')));
    await tester.pumpAndSettle();
    expect(requested, '123456');
    expect(file, isTrue);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'a server change while the credential dialog is open cannot retarget its device',
      (tester) async {
    final first = 'a' * 64, second = 'b' * 64;
    final scopedStore = DeviceStore(directory, serverNamespace: first);
    await tester.runAsync(() =>
        scopedStore.save(const DeviceEntry(id: '123456', alias: 'Office')));
    final gateway = _ServerDouble(ServerSnapshot(
        PrivateServerConfig(
            'nas:21116', 'nas:21117', base64Encode(List.filled(32, 1))),
        1,
        true,
        namespace: first));
    var calls = 0;
    await loadPage(
        tester,
        NikoDevicePage(
            store: scopedStore,
            gateway: gateway,
            native: false,
            onConnect: (_, __, ___, {isFileTransfer = false, password}) async {
              calls++;
            }));
    await tester
        .ensureVisible(find.byKey(const Key('nikodesk-device-connect-123456')));
    await tester.tap(find.byKey(const Key('nikodesk-device-connect-123456')));
    await tester.pumpAndSettle();
    gateway.snapshot = ServerSnapshot(
        PrivateServerConfig('other-nas:21116', 'other-nas:21117',
            base64Encode(List.filled(32, 2))),
        1,
        true,
        namespace: second);
    await tester.enterText(
        find.byKey(const Key('nikodesk-connect-password')), 'fixture-password');
    await tester.tap(find.byKey(const Key('nikodesk-connect-submit')));
    await tester.pumpAndSettle();
    expect(calls, 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('an empty password in the dialog never dispatches a session',
      (tester) async {
    final gateway = _ServerDouble(ServerSnapshot(
        PrivateServerConfig(
            'nas:21116', 'nas:21117', base64Encode(List.filled(32, 1))),
        1,
        true));
    await tester.runAsync(
        () => store.save(const DeviceEntry(id: '123456', alias: 'Office')));
    var calls = 0;
    await loadPage(
        tester,
        NikoDevicePage(
            store: store,
            gateway: gateway,
            onConnect: (_, __, ___, {isFileTransfer = false, password}) async {
              calls++;
            }));
    await tester
        .ensureVisible(find.byKey(const Key('nikodesk-device-connect-123456')));
    await tester.tap(find.byKey(const Key('nikodesk-device-connect-123456')));
    await tester.pumpAndSettle();
    // Submit with an empty password field: the policy must refuse.
    await tester.tap(find.byKey(const Key('nikodesk-connect-submit')));
    await tester.pumpAndSettle();
    expect(calls, 0);
    expect(find.textContaining('安全策略'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'search matches aliases and groups and has an honest empty result',
      (tester) async {
    await tester.runAsync(() => store.save(const DeviceEntry(
        id: '123456', alias: 'Design machine', group: 'Studio')));
    final gateway = _ServerDouble(
        const ServerSnapshot(PrivateServerConfig('', '', ''), null, false));
    await loadPage(tester, NikoDevicePage(store: store, gateway: gateway));
    await tester.enterText(find.byKey(const Key('nikodesk-search')), 'studio');
    await tester.pumpAndSettle();
    expect(find.text('Design machine'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('nikodesk-search')), 'missing');
    await tester.pumpAndSettle();
    expect(find.text('没有匹配的设备'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'server form rejects malformed values without invoking native write',
      (tester) async {
    final gateway = _ServerDouble(
        const ServerSnapshot(PrivateServerConfig('', '', ''), null, false));
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: PrivateServerForm(
                gateway: gateway,
                initial: const PrivateServerConfig(
                    'https://public', 'host:65536', 'bad-key')))));
    await tester.ensureVisible(find.text('保存并启用私服'));
    await tester.tap(find.text('保存并启用私服'));
    await tester.pumpAndSettle();
    expect(gateway.saves, 0);
    expect(find.textContaining('需要标准 Base64'), findsOneWidget);
    expect(find.textContaining('使用主机名或 IP'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  for (final dark in [false, true]) {
    testWidgets(
        'narrow ${dark ? 'dark' : 'light'} home handles long labels and 150% text',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(460, 620));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.runAsync(() => store.save(DeviceEntry(
          id: '123456',
          alias: 'Long device label ' * 5,
          group: 'Workgroup ' * 5)));
      final gateway = _ServerDouble(
          const ServerSnapshot(PrivateServerConfig('', '', ''), null, false));
      await loadPage(tester, NikoDevicePage(store: store, gateway: gateway),
          theme: dark ? ThemeData.dark() : ThemeData.light(), scale: 1.5);
      expect(tester.takeException(), isNull);
      await tester.drag(
          find.byType(SingleChildScrollView).first, const Offset(0, -400));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
  testWidgets('explicit English selection renders fallback copy',
      (tester) async {
    final gateway = _ServerDouble(
        const ServerSnapshot(PrivateServerConfig('', '', ''), null, false));
    await loadPage(tester, NikoDevicePage(store: store, gateway: gateway));
    await tester.ensureVisible(find.text('English'));
    await tester.tap(find.text('English'));
    await tester.pumpAndSettle();
    expect(find.text('My devices'), findsOneWidget);
    expect(find.text('Set up your private server'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('device card rechecks pause after password dialog',
      (tester) async {
    final gateway = _ServerDouble(ServerSnapshot(
        PrivateServerConfig(
            'nas:21116', 'nas:21117', base64Encode(List.filled(32, 1))),
        1,
        true));
    await tester.runAsync(
        () => store.save(const DeviceEntry(id: '123456', alias: 'Office')));
    var calls = 0;
    await loadPage(
        tester,
        NikoDevicePage(
            store: store,
            gateway: gateway,
            onConnect: (_, __, ___, {isFileTransfer = false, password}) async {
              calls++;
            }));
    await tester
        .ensureVisible(find.byKey(const Key('nikodesk-device-connect-123456')));
    await tester.tap(find.byKey(const Key('nikodesk-device-connect-123456')));
    await tester.pumpAndSettle();
    gateway.snapshot = ServerSnapshot(gateway.snapshot.config, 1, false);
    await tester.enterText(
        find.byKey(const Key('nikodesk-connect-password')), 'synthetic-secret');
    await tester.tap(find.byKey(const Key('nikodesk-connect-submit')));
    await tester.pumpAndSettle();
    expect(calls, 0);
    expect(find.textContaining('已暂停'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
  for (final stopped in [true, false]) {
    testWidgets('server form only claims pause when confirmed ($stopped)',
        (tester) async {
      final config = PrivateServerConfig('test.invalid:21116',
          'test.invalid:21117', base64Encode(List.filled(32, 1)));
      final gateway = _ServerDouble(ServerSnapshot(config, null, false))
        ..saveError = PrivateServerSaveException(stoppedVerified: stopped);
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: PrivateServerForm(gateway: gateway, initial: config))));
      await tester.ensureVisible(find.text('保存并启用私服'));
      await tester.tap(find.text('保存并启用私服'));
      await tester.pumpAndSettle();
      expect(gateway.saves, 1);
      expect(find.textContaining(stopped ? '已确认连接处于暂停状态' : '停止状态未知'),
          findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
