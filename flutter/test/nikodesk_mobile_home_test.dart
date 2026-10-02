import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/nikodesk/device_store.dart';
import 'package:flutter_hbb/nikodesk/mobile_home.dart';
import 'package:flutter_hbb/nikodesk/policy.dart';
import 'package:flutter_hbb/nikodesk/server_gateway.dart';
import 'package:flutter_hbb/nikodesk/session_log.dart';
import 'package:flutter_hbb/nikodesk/session_history.dart';
import 'package:flutter_hbb/nikodesk/theme.dart';
import 'package:flutter_hbb/nikodesk/ui.dart';
import 'package:package_info_plus/package_info_plus.dart';

// UI-only gateway; these tests do not represent an Android remote session.
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
    NikoLanguage.english = true;
    directory = await Directory.systemTemp.createTemp('nikodesk-mobile-test-');
    store = DeviceStore(directory);
    sessionLog = SessionLogStore(directory);
  });
  tearDown(() async => directory.delete(recursive: true));

  _ServerDouble configured() => _ServerDouble(ServerSnapshot(
      PrivateServerConfig('nas.example.net:21116', 'nas.example.net:21117',
          base64Encode(List.filled(32, 1))),
      1,
      true));

  Future<void> load(WidgetTester tester, _ServerDouble gateway,
      {Brightness brightness = Brightness.light,
      double scale = 1,
      bool deferSetup = true,
      Future<void> Function(BuildContext, String, bool,
              {bool isFileTransfer, String? password})?
          onConnect}) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(MaterialApp(
          theme: ThemeData(brightness: brightness),
          builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!),
          home: NikoMobileHome(
              store: store,
              gateway: gateway,
              sessionLog: sessionLog,
              onConnect: onConnect)));
      for (var i = 0; i < 250; i++) {
        await tester.pump();
        if (deferSetup && find.text('Set up later').evaluate().isNotEmpty) {
          await tester.ensureVisible(find.text('Set up later'));
          await tester.tap(find.text('Set up later'));
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

  Future<void> revealScrollable(WidgetTester tester, Finder target, {Finder? page}) async {
    final scrollable = find.descendant(
        of: page ?? find.byKey(const Key('nikodesk-mobile-settings-scroll')),
        matching: find.byType(Scrollable)).first;
    for (var i = 0; i < 30 && target.hitTestable().evaluate().isEmpty; i++) {
      final above = target.evaluate().isNotEmpty &&
          tester.getCenter(target).dy < tester.getTopLeft(scrollable).dy;
      await tester.drag(scrollable, Offset(0, above ? 120 : -120));
      await tester.pumpAndSettle();
    }
    expect(target.hitTestable(), findsOneWidget);
  }

  testWidgets('first Android setup saves then opens the controller workspace',
      (tester) async {
    final gateway = _ServerDouble(
        const ServerSnapshot(PrivateServerConfig('', '', ''), null, false));
    await load(tester, gateway, deferSetup: false);
    expect(find.text('Connect to your server'), findsOneWidget);
    expect(find.text('Devices'), findsNothing);
    await tester.enterText(find.byType(TextFormField).at(0), 'test.invalid:21116');
    await tester.enterText(find.byType(TextFormField).at(1), 'test.invalid:21117');
    await tester.enterText(
        find.byType(TextFormField).at(2), base64Encode(List.filled(32, 1)));
    await tester.ensureVisible(find.text('Save and enable private server'));
    await tester.runAsync(() async {
      await tester.tap(find.text('Save and enable private server'));
      for (var i = 0; i < 30; i++) {
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    await tester.pumpAndSettle();
    expect(find.text('Controller configuration enabled'), findsOneWidget);
    expect(find.text('Devices'), findsOneWidget);
    expect(find.text('Registered'), findsNothing);
    expect(find.text('Connect to your server'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Android settings exposes installed product/build separately',
      (tester) async {
    // Platform-channel fixture only; this is not native package acceptance.
    PackageInfo.setMockInitialValues(
        appName: 'NikoDesk', packageName: 'fixture.example',
        version: '9.8.7', buildNumber: '42', buildSignature: '');
    addTearDown(() => PackageInfo.setMockInitialValues(
        appName: '', packageName: '', version: '', buildNumber: '',
        buildSignature: ''));
    await load(tester, configured());
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    await revealScrollable(tester, find.text('About NikoDesk'));
    expect(find.text('NikoDesk 9.8.7+42'), findsOneWidget);
    // The injected UI gateway deliberately cannot read a native protocol.
    expect(find.text('RustDesk Unknown'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  for (final size in [
    const Size(320, 700),
    const Size(390, 844),
    const Size(844, 390),
  ]) {
    for (final brightness in [Brightness.light, Brightness.dark]) {
      testWidgets(
          'mobile ${size.width}x${size.height} $brightness fits English',
          (tester) async {
        await tester.binding.setSurfaceSize(size);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.runAsync(() => store.save(DeviceEntry(
            id: '123456',
            alias: 'Office computer with a long label',
            group: 'Remote work devices')));
        await load(tester, configured(), brightness: brightness);
        expect(find.text('Controller configuration enabled'), findsOneWidget);
        expect(find.text('Registered'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('Sessions'));
        await tester.runAsync(() async {
          await tester.pump();
          await Future<void>.delayed(const Duration(milliseconds: 100));
        });
        await tester.pumpAndSettle();
        expect(find.text('No sessions yet'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('Settings'));
        await tester.pumpAndSettle();
        expect(find.text('Configure server'), findsOneWidget);
        await revealScrollable(tester, find.byKey(const Key('nikodesk-controller-guide-toggle')));
        await tester.tap(find.byKey(const Key('nikodesk-controller-guide-toggle')));
        await tester.pumpAndSettle();
        await revealScrollable(tester, find.textContaining('local screen capture'));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });
    }
  }

  testWidgets('mobile refuses unconfigured and passwordless dispatch',
      (tester) async {
    final gateway = _ServerDouble(
        const ServerSnapshot(PrivateServerConfig('', '', ''), null, false));
    var calls = 0;
    await load(tester, gateway,
        onConnect: (_, __, ___, {isFileTransfer = false, password}) async {
      calls++;
    });
    expect(find.text('Set up your private server'), findsOneWidget);
    await tester.tap(find.byKey(const Key('nikodesk-hero-connect')),
        warnIfMissed: false);
    expect(calls, 0);
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    expect(find.text('Setup required'), findsOneWidget);
    await tester.tap(find.text('Configure server'));
    await tester.pumpAndSettle();
    expect(find.text('Connect to your server'), findsOneWidget);
    expect(find.text('Advanced settings'), findsNothing);
    await tester.ensureVisible(find.text('Cancel'));
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    gateway.snapshot = configured().snapshot;
    await tester.runAsync(() async {
      await tester.tap(find.text('Devices'));
      await tester.pump();
      for (var i = 0; i < 250; i++) {
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        if (find.text('Controller configuration enabled').evaluate().isNotEmpty) {
          break;
        }
      }
    });
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('nikodesk-hero-id')), '123456');
    await tester.ensureVisible(find.byKey(const Key('nikodesk-hero-connect')));
    await tester.tap(find.byKey(const Key('nikodesk-hero-connect')));
    await tester.pumpAndSettle();
    expect(calls, 0);
    expect(find.textContaining('remote password is required'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('mobile file dispatch forwards password and records an attempt',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    String? requested;
    String? usedPassword;
    bool files = false;
    await load(tester, configured(),
        onConnect: (_, id, relay, {isFileTransfer = false, password}) async {
      requested = id;
      usedPassword = password;
      files = isFileTransfer;
    });
    await tester.tap(find.text('Files'));
    await tester.enterText(find.byKey(const Key('nikodesk-hero-id')), '123456');
    await tester.enterText(
        find.byKey(const Key('nikodesk-hero-password')), 'test-only-password');
    await tester.ensureVisible(find.byKey(const Key('nikodesk-hero-connect')));
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('nikodesk-hero-connect')));
      await Future<void>.delayed(const Duration(milliseconds: 150));
    });
    await tester.pumpAndSettle();
    expect(requested, '123456');
    expect(usedPassword, 'test-only-password');
    expect(files, isTrue);
    await tester.runAsync(() async {
      final entries = (await sessionLog.load()).entries;
      expect(entries.single.id, '123456');
      expect(entries.single.fileTransfer, isTrue);
      expect(await sessionLog.file.readAsString(),
          isNot(contains('test-only-password')));
    });
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('history rechecks server configuration after password entry',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.runAsync(() => sessionLog.record(SessionLogEntry(
        id: '123456', alias: 'Office', startedAt: DateTime.utc(2026, 9, 30))));
    final gateway = configured();
    var calls = 0;
    await load(tester, gateway,
        onConnect: (_, __, ___, {isFileTransfer = false, password}) async {
      calls++;
    });
    await tester.runAsync(() async {
      await tester.tap(find.text('Sessions'));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 150));
    });
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();
    gateway.snapshot =
        const ServerSnapshot(PrivateServerConfig('', '', ''), null, false);
    await tester.enterText(find.byKey(const Key('nikodesk-connect-password')),
        'test-only-password');
    await tester
        .ensureVisible(find.byKey(const Key('nikodesk-connect-submit')));
    await tester.tap(find.byKey(const Key('nikodesk-connect-submit')));
    await tester.pumpAndSettle();
    expect(calls, 0);
    expect(
        find.text('The private server is not ready or connections are paused.'),
        findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('mobile tab changes preserve IDs and clear passwords',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await load(tester, configured());
    await tester.enterText(find.byKey(const Key('nikodesk-hero-id')), '123456');
    await tester.enterText(
        find.byKey(const Key('nikodesk-hero-password')), 'synthetic-secret');
    final passwordField = find.byKey(const Key('nikodesk-hero-password'));
    await tester.tap(passwordField);
    await tester.pump();
    final hiddenEditor = tester.state<EditableTextState>(find.descendant(of: passwordField, matching: find.byType(EditableText)));
    expect(hiddenEditor.widget.focusNode.hasFocus, isTrue);
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    expect(hiddenEditor.widget.focusNode.hasFocus, isFalse);
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.text('Devices'));
      for (var i = 0; i < 10; i++) {
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<TextField>(find.byKey(const Key('nikodesk-hero-id')))
            .controller!
            .text,
        '123456');
    expect(
        tester
            .widget<TextField>(find.byKey(const Key('nikodesk-hero-password')))
            .controller!
            .text,
        isEmpty);
    await tester.pumpWidget(const SizedBox());
  });
  for (final english in [false, true]) {
    testWidgets('mobile narrow 200% text keeps controls reachable ($english)', (tester) async {
      NikoLanguage.english = english;
      await tester.binding.setSurfaceSize(const Size(320, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.runAsync(() => store.save(const DeviceEntry(id: '123456', alias: 'Office', favorite: true)));
      await load(tester, configured(), brightness: Brightness.dark, scale: 2);
      expect(tester.takeException(), isNull);

      await tester.ensureVisible(find.byKey(const Key('nikodesk-device-connect-123456')));
      expect(tester.getSize(find.byKey(const Key('nikodesk-device-connect-123456'))).height, greaterThanOrEqualTo(48));
      await tester.tap(find.text(english ? 'Settings' : '设置').last);
      await tester.pumpAndSettle();
      await revealScrollable(tester, find.byKey(const Key('nikodesk-touch-guide-toggle')));
      await tester.tap(find.byKey(const Key('nikodesk-touch-guide-toggle')));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('saved mobile devices are available on the first screen', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.runAsync(() => store.save(const DeviceEntry(id: '123456', alias: 'Office')));
    await load(tester, configured());
    final action = find.byKey(const Key('nikodesk-device-connect-123456'));
    expect(action.hitTestable(), findsOneWidget);
    expect(find.byKey(const Key('nikodesk-hero-password')), findsNothing);
    await tester.tap(find.byKey(const Key('nikodesk-quick-connect-toggle')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('nikodesk-hero-id')), '654321');
    await tester.enterText(find.byKey(const Key('nikodesk-hero-password')), 'synthetic-secret');
    await tester.ensureVisible(find.byKey(const Key('nikodesk-quick-connect-toggle')));
    await tester.tap(find.byKey(const Key('nikodesk-quick-connect-toggle')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('nikodesk-quick-connect-toggle')));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byKey(const Key('nikodesk-hero-id'))).controller!.text, '654321');
    expect(tester.widget<TextField>(find.byKey(const Key('nikodesk-hero-password'))).controller!.text, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('tab switches retain search, favorite filter and relay preference', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.runAsync(() async {
      await store.save(const DeviceEntry(id: '123456', alias: 'Office', favorite: true));
      await store.save(const DeviceEntry(id: '654321', alias: 'Guest'));
    });
    await load(tester, configured());
    await tester.enterText(find.byKey(const Key('nikodesk-search')), 'Office');
    await tester.tap(find.byTooltip('Favorites'));
    await tester.ensureVisible(find.byKey(const Key('nikodesk-quick-connect-toggle')));
    await tester.tap(find.byKey(const Key('nikodesk-quick-connect-toggle')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byType(Switch).first);
    await tester.tap(find.byType(Switch).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Devices'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byKey(const Key('nikodesk-search'))).controller!.text, 'Office');
    expect(tester.widget<Switch>(find.byType(Switch).first).value, isTrue);
    expect(tester.widget<ChoiceChip>(find.byWidgetPredicate((widget) => widget is ChoiceChip && widget.tooltip == 'Favorites')).selected, isTrue);
    expect(find.byKey(const Key('nikodesk-device-connect-123456')), findsOneWidget);
    expect(find.byKey(const Key('nikodesk-device-connect-654321')), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  for (final english in [false, true]) {
    testWidgets('history with records fits 320 width at 200% text ($english)', (tester) async {
      NikoLanguage.english = english;
      await tester.binding.setSurfaceSize(const Size(320, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.runAsync(() => sessionLog.record(SessionLogEntry(id: '123456',
          alias: 'Office computer with a long label', forceRelay: true,
          fileTransfer: true, startedAt: DateTime.utc(2026, 9, 30))));
      await load(tester, configured(), brightness: Brightness.dark, scale: 2);
      await tester.tap(find.text(english ? 'Sessions' : '会话'));
      await tester.pumpAndSettle();
      final history = find.byType(NikoSessionHistoryPage);
      final action = find.descendant(of: history, matching: find.byType(NikoPrimaryButton));
      await revealScrollable(tester, action, page: history);
      expect(tester.getSize(action).height, greaterThanOrEqualTo(48));
      await revealScrollable(tester, find.byTooltip(english ? 'Delete record' : '删除该记录'), page: history);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

}
