import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/nikodesk/nightline.dart';
import 'package:flutter_hbb/nikodesk/permission_guide.dart';
import 'package:flutter_hbb/nikodesk/ui.dart';

// Probe and callback doubles; the macOS checks themselves are native.
void main() {
  setUp(() => NikoLanguage.english = true);

  late bool screen;
  late bool input;
  late List<String> calls;

  Future<void> load(WidgetTester tester) async {
    calls = [];
    await tester.binding.setSurfaceSize(const Size(900, 760));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
        theme: nightlineTheme(Brightness.dark),
        home: Scaffold(
            body: NikoPermissionGuide(
                screenRecording: () => screen,
                accessibility: () => input,
                requestScreenRecording: () => calls.add('screen'),
                requestAccessibility: () => calls.add('input'),
                onContinue: () => calls.add('continue'),
                onSilence: () => calls.add('silence')))));
    await tester.pump();
  }

  testWidgets('missing permissions open their own settings panes',
      (tester) async {
    screen = false;
    input = false;
    await load(tester);
    expect(find.text('Let this Mac be controlled remotely'), findsOneWidget);
    expect(find.text('Open System Settings'), findsNWidgets(2));
    await tester.tap(find.text('Open System Settings').first);
    await tester.tap(find.text('Open System Settings').last);
    expect(calls, ['screen', 'input']);
    expect(find.textContaining('remove it with "−"'), findsOneWidget);
  });

  testWidgets('rows follow the system checks while the guide is open',
      (tester) async {
    screen = false;
    input = true;
    await load(tester);
    expect(find.text('Open System Settings'), findsOneWidget);
    expect(find.text('Allowed'), findsOneWidget);
    screen = true;
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Open System Settings'), findsNothing);
    expect(find.text('Allowed'), findsNWidgets(2));
    expect(find.text('This Mac can now be controlled'), findsOneWidget);
    expect(find.text('Skip for now'), findsNothing);
    expect(find.text('Don\'t remind me'), findsNothing);
    await tester.tap(find.text('Open NikoDesk'));
    expect(calls, ['continue']);
  });

  testWidgets('skipping and silencing are separate choices', (tester) async {
    screen = false;
    input = false;
    await load(tester);
    await tester.tap(find.text('Skip for now'));
    await tester.tap(find.text('Don\'t remind me'));
    expect(calls, ['continue', 'silence']);
  });

  testWidgets('the guide fits a narrow window with large text',
      (tester) async {
    screen = false;
    input = false;
    calls = [];
    await tester.binding.setSurfaceSize(const Size(420, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
        theme: nightlineTheme(Brightness.light),
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(1.5)),
            child: child!),
        home: Scaffold(
            body: NikoPermissionGuide(
                screenRecording: () => screen,
                accessibility: () => input,
                requestScreenRecording: () {},
                requestAccessibility: () {},
                onContinue: () {},
                onSilence: () {}))));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
