import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/nikodesk/startup_shell.dart';
import 'package:flutter_test/flutter_test.dart';

class _ReadyPage extends StatefulWidget {
  final VoidCallback onInit;
  final VoidCallback onTap;
  const _ReadyPage({required this.onInit, required this.onTap});

  @override
  State<_ReadyPage> createState() => _ReadyPageState();
}

class _ReadyPageState extends State<_ReadyPage> {
  @override
  void initState() {
    super.initState();
    widget.onInit();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
      home: Scaffold(
          body: Center(
              child: TextButton(
                  onPressed: widget.onTap,
                  child: const Text('Ready fixture')))));
}

void main() {
  late Completer<void> visible;
  late Completer<void> ready;
  var builds = 0;
  var initializations = 0;
  var taps = 0;
  setUp(() {
    builds = 0;
    initializations = 0;
    taps = 0;
  });
  tearDown(() => TestWidgetsFlutterBinding.instance.platformDispatcher
      .clearAllTestValues());

  Future<void> mount(WidgetTester tester) {
    visible = Completer<void>();
    ready = Completer<void>();
    return tester.pumpWidget(NikoStartupShell(
        visible: visible.future,
        ready: ready.future,
        buildReady: () {
          builds++;
          return _ReadyPage(
              onInit: () => initializations++, onTap: () => taps++);
        }));
  }

  double logoScale(WidgetTester tester) => tester
      .widget<Transform>(find.byKey(const Key('nikodesk-startup-logo')))
      .transform
      .storage[0];

  testWidgets('entry waits for the actual window visibility signal',
      (tester) async {
    await mount(tester);
    await tester.pump(const Duration(milliseconds: 900));
    expect(logoScale(tester), .75);
    expect(tester.hasRunningAnimations, isFalse);
    expect(builds, 0);
    visible.complete();
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(logoScale(tester), greaterThan(.75));
    expect(tester.hasRunningAnimations, isTrue);
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  testWidgets('ready before visibility replaces the shell without waiting',
      (tester) async {
    await mount(tester);
    ready.complete();
    await tester.pump();
    await tester.pump();
    expect(find.text('Ready fixture'), findsOneWidget);
    expect(find.byKey(const Key('nikodesk-startup-opacity')), findsNothing);
    expect(tester.hasRunningAnimations, isFalse);
    visible.complete();
    await tester.pump(const Duration(seconds: 3));
    expect(builds, 1);
    expect(initializations, 1);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('fast ready interrupts entry without remounting or click-through',
      (tester) async {
    await mount(tester);
    visible.complete();
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    ready.complete();
    await tester.pump();
    await tester.pump();
    expect(find.text('Ready fixture'), findsOneWidget);
    expect(builds, 1);
    expect(initializations, 1);
    expect(find.byKey(const Key('nikodesk-startup-opacity')), findsOneWidget);
    await tester.tap(find.text('Ready fixture'), warnIfMissed: false);
    expect(taps, 0);
    await tester.pump(const Duration(milliseconds: 260));
    await tester.pump();
    expect(find.byKey(const Key('nikodesk-startup-opacity')), findsNothing);
    expect(builds, 1);
    expect(initializations, 1);
    await tester.tap(find.text('Ready fixture'));
    expect(taps, 1);
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  testWidgets('slow work explains the wait and never manufactures readiness',
      (tester) async {
    tester.binding.platformDispatcher.localeTestValue = const Locale('zh');
    await mount(tester);
    visible.complete();
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1999));
    expect(find.text('正在准备工作空间…'), findsNothing);
    await tester.pump(const Duration(milliseconds: 1));
    expect(find.text('正在准备工作空间…'), findsOneWidget);
    final calls = <MethodCall>[];
    const channel = MethodChannel('window_manager');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,
        (call) async {
      calls.add(call);
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    await tester.tap(find.byKey(const Key('nikodesk-startup-slow-quit')));
    await tester.pump();
    expect(calls.single.method, 'destroy');
    expect(builds, 0);
    await tester.pump(const Duration(seconds: 8));
    expect(builds, 0);
    expect(find.text('Ready fixture'), findsNothing);
    ready.complete();
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 260));
    await tester.pump();
    expect(find.text('正在准备工作空间…'), findsNothing);
    expect(initializations, 1);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('reduced motion keeps a static logo and has no exit animation',
      (tester) async {
    tester.binding.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    await mount(tester);
    visible.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(logoScale(tester), 1);
    final icon = tester.getRect(find.byType(Image));
    final brand = tester.getRect(find.text('NikoDesk'));
    final tagline = tester.getRect(find.text('Your computer, right here.'));
    expect(icon.size, const Size(86, 86));
    expect(brand.top - icon.bottom, closeTo(22, .01));
    expect(tagline.top - brand.bottom, closeTo(10, .01));
    expect(find.byKey(const Key('nikodesk-startup-orbits')), findsNothing);
    expect(tester.hasRunningAnimations, isFalse);
    ready.complete();
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('nikodesk-startup-opacity')), findsNothing);
    expect(find.text('Ready fixture'), findsOneWidget);
    expect(initializations, 1);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('changing reduced motion stops an in-flight entrance',
      (tester) async {
    await mount(tester);
    visible.complete();
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    tester.binding.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    await tester.pump();
    expect(logoScale(tester), 1);
    expect(tester.hasRunningAnimations, isFalse);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('late readiness and visibility do nothing after disposal',
      (tester) async {
    await mount(tester);
    await tester.pumpWidget(const SizedBox());
    visible.complete();
    ready.complete();
    await tester.pump(const Duration(seconds: 3));
    expect(builds, 0);
    expect(initializations, 0);
    expect(tester.takeException(), isNull);
  });
}
