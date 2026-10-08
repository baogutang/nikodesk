import 'dart:async';
import 'dart:ffi' show DynamicLibrary;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/main.dart' as entrypoint;
import 'package:flutter_hbb/models/native_model.dart';
import 'package:flutter_hbb/nikodesk/startup_failure.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const windowChannel = MethodChannel('window_manager');
  const packageChannel =
      MethodChannel('dev.fluttercommunity.plus/package_info');
  final windowCalls = <MethodCall>[];

  setUp(() {
    windowCalls.clear();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(windowChannel,
        (call) async {
      windowCalls.add(call);
      if (call.method.startsWith('is')) return false;
      return null;
    });
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
        packageChannel,
        (_) async => {
              'appName': 'Synthetic fixture',
              'packageName': 'invalid.fixture',
              'version': '0.0.0',
              'buildNumber': '0',
            });
  });
  tearDown(() {
    binding.defaultBinaryMessenger
        .setMockMethodCallHandler(windowChannel, null);
    binding.defaultBinaryMessenger
        .setMockMethodCallHandler(packageChannel, null);
    binding.platformDispatcher.clearAllTestValues();
    desktopType = null;
    version = '';
  });

  testWidgets('successful initialization continues without a fallback window',
      (tester) async {
    var attempts = 0;
    final ready = await initializeNikoMainWindow(() async => attempts++);
    expect(ready, isTrue);
    expect(attempts, 1);
    expect(windowCalls, isEmpty);
    expect(find.byType(NikoStartupFailureApp), findsNothing);
  });

  testWidgets('failed initialization shows an opaque closable window once',
      (tester) async {
    final pending = Completer<void>();
    var attempts = 0;
    final startup = initializeNikoMainWindow(() {
      attempts++;
      return pending.future;
    });
    await tester.pump();
    expect(windowCalls, isEmpty);
    pending.completeError(StateError('synthetic-secret-do-not-display'));
    expect(await startup, isFalse);
    await tester.pumpAndSettle();
    expect(attempts, 1);
    expect(find.text('Unable to start'), findsOneWidget);
    expect(find.textContaining('synthetic-secret'), findsNothing);
    expect(find.byType(TextField), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(
        windowCalls.map((call) => call.method),
        containsAllInOrder([
          'waitUntilReadyToShow',
          'setTitleBarStyle',
          'setPreventClose',
          'setOpacity',
          'show',
          'focus'
        ]));
    expect(
        windowCalls
            .singleWhere((call) => call.method == 'setPreventClose')
            .arguments,
        {'isPreventClose': false});
    expect(
        windowCalls
            .singleWhere((call) => call.method == 'setOpacity')
            .arguments,
        {'opacity': 1.0});
    if (Platform.isMacOS) {
      expect(
          windowCalls
              .singleWhere((call) => call.method == 'setMovable')
              .arguments,
          {'isMovable': true});
    }
    expect(windowCalls.any((call) => call.method == 'destroy'), isFalse);
    await tester.tap(find.byKey(const Key('nikodesk-startup-quit')));
    await tester.pump();
    expect(windowCalls.last.method, 'destroy');
    expect(tester.takeException(), isNull);
  });

  testWidgets('Chinese failure page stays usable at narrow width and 200% text',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 260));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    binding.platformDispatcher.localeTestValue = const Locale('zh', 'CN');
    binding.platformDispatcher.textScaleFactorTestValue = 2;
    await tester.pumpWidget(const NikoStartupFailureApp());
    expect(find.text('启动失败'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('nikodesk-startup-quit')));
    await tester.tap(find.byKey(const Key('nikodesk-startup-quit')));
    await tester.pump();
    expect(windowCalls.single.method, 'destroy');
    expect(tester.takeException(), isNull);
  });

  testWidgets('unavailable window plugin does not escape the failure boundary',
      (tester) async {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
        windowChannel, (_) async => throw MissingPluginException());
    expect(
        await initializeNikoMainWindow(
            () async => throw StateError('Synthetic initialization failure')),
        isFalse);
    await tester.pumpAndSettle();
    expect(find.byType(NikoStartupFailureApp), findsOneWidget);
    await tester.tap(find.byKey(const Key('nikodesk-startup-quit')));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  // The Flutter test host lacks the core symbol, so this exercises the real
  // native initialization catch without loading or calling an installed core.
  final canTestMissingCore = Platform.isMacOS &&
      !DynamicLibrary.process().providesSymbol('session_get_rgba');
  testWidgets('missing core reaches the main fallback before global FFI setup',
      (tester) async {
    desktopType = DesktopType.main;
    version = '';
    if (const bool.fromEnvironment('NIKODESK')) {
      expect(
          await initializeNikoMainWindow(
              () => entrypoint.initEnv(kAppTypeMain)),
          isFalse);
      expect(version, isEmpty);
      await tester.pumpAndSettle();
      expect(find.byType(NikoStartupFailureApp), findsOneWidget);
      expect(find.byType(entrypoint.App), findsNothing);
      expect(tester.takeException(), isNull);
    } else {
      await PlatformFFI.instance.init(kAppTypeMain);
      expect(version, '0.0.0');
      expect(windowCalls, isEmpty);
    }
  }, skip: !canTestMissingCore);

  for (final entry in [
    (DesktopType.cm, kAppTypeConnectionManager),
    (DesktopType.remote, kAppTypeDesktopRemote),
    (null, kAppTypeMain), // The installer also uses appType main.
  ]) {
    test('preserves initialization handling for ${entry.$1 ?? 'installer'}',
        () async {
      desktopType = entry.$1;
      version = '';
      await PlatformFFI.instance.init(entry.$2);
      expect(version, '0.0.0');
    }, skip: !canTestMissingCore);
  }
}
