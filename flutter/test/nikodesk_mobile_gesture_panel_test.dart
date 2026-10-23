import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/nikodesk/mobile_gesture_panel.dart';
import 'package:flutter_hbb/nikodesk/nightline.dart';
import 'package:flutter_hbb/nikodesk/theme.dart';
import 'package:flutter_hbb/nikodesk/ui.dart';

void main() {
  tearDown(() => NikoLanguage.english = false);

  // Layout and callback fixtures only; no session or native input starts.
  Widget host(Widget panel, {double textScale = 1}) => MaterialApp(
      theme: nikoTheme(Brightness.dark).copyWith(platform: TargetPlatform.iOS),
      builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!),
      home: Scaffold(
          body: SingleChildScrollView(
              padding: const EdgeInsets.all(16), child: panel)));

  testWidgets('mode switch reports a change and is operable by keyboard',
      (tester) async {
    NikoLanguage.english = true;
    final semantics = tester.ensureSemantics();
    var touch = false;
    final changed = <bool>[];
    await tester.pumpWidget(host(StatefulBuilder(
        builder: (context, setState) => NikoGesturePanel(
            touchMode: touch,
            onTouchMode: (value) => setState(() {
                  touch = value;
                  changed.add(value);
                })))));
    await tester.pumpAndSettle();
    final mouse =
        find.byKey(const ValueKey('nikodesk-mobile-input-mode-false'));
    final finger =
        find.byKey(const ValueKey('nikodesk-mobile-input-mode-true'));
    expect(find.text('Double-tap and move'), findsOneWidget);
    expect(
        tester
            .getSemantics(mouse)
            .getSemanticsData()
            .hasFlag(SemanticsFlag.isSelected),
        isTrue);
    await tester.tap(finger);
    await tester.pumpAndSettle();
    await tester.tap(finger);
    expect(changed, [true]);
    expect(find.text('One-finger move'), findsOneWidget);
    expect(
        tester
            .getSemantics(finger)
            .getSemanticsData()
            .hasFlag(SemanticsFlag.isSelected),
        isTrue);

    // Shift-Tab back to mouse mode and press Space, as a hardware keyboard
    // on an iPad would.
    bool focused() => tester
        .getSemantics(mouse)
        .getSemanticsData()
        .hasFlag(SemanticsFlag.isFocused);
    for (var i = 0; i < 6 && !focused(); i++) {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shift);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shift);
      await tester.pumpAndSettle();
    }
    expect(focused(), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(changed, [true, false]);
    semantics.dispose();
  });

  testWidgets('on-screen mouse rows follow the mode and each other',
      (tester) async {
    NikoLanguage.english = true;
    final calls = <String>[];
    Widget panel(
            {required bool touch,
            bool? mouse = true,
            bool joystick = false,
            bool? relative = false}) =>
        NikoGesturePanel(
            touchMode: touch,
            onTouchMode: (_) {},
            virtualMouse: mouse,
            onVirtualMouse: (v) => calls.add('mouse $v'),
            mouseScale: 1.2,
            onMouseScale: (v) => calls.add('scale'),
            joystick: joystick,
            onJoystick: (v) => calls.add('joystick $v'),
            relative: relative,
            onRelative: (v) => calls.add('relative $v'));
    final size = find.byKey(const Key('nikodesk-virtual-mouse-size'));
    final stick = find.byKey(const Key('nikodesk-virtual-joystick'));
    final relative = find.byKey(const Key('nikodesk-relative-mouse'));

    await tester.pumpWidget(host(panel(touch: true, mouse: null)));
    expect(find.byKey(const Key('nikodesk-virtual-mouse')), findsNothing);

    await tester.pumpWidget(host(panel(touch: true)));
    expect(size, findsOneWidget);
    expect(stick, findsNothing);
    await tester.drag(size, const Offset(60, 0));
    expect(calls, contains('scale'));

    calls.clear();
    await tester.pumpWidget(host(panel(touch: false)));
    expect(size, findsNothing);
    expect(relative, findsNothing);
    await tester.tap(stick);
    expect(calls, ['joystick true']);

    calls.clear();
    await tester.pumpWidget(host(panel(touch: false, joystick: true)));
    await tester.ensureVisible(relative);
    await tester.tap(relative);
    await tester.tap(find.byKey(const Key('nikodesk-virtual-mouse')));
    expect(calls, ['relative true', 'mouse false']);

    await tester
        .pumpWidget(host(panel(touch: false, joystick: true, relative: null)));
    expect(relative, findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final english in [false, true]) {
    for (final touch in [false, true]) {
      testWidgets('panel fits 320px at 200% text ($english/$touch)',
          (tester) async {
        NikoLanguage.english = english;
        await tester.binding.setSurfaceSize(const Size(320, 700));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(host(
            NikoGesturePanel(
                touchMode: touch,
                onTouchMode: (_) {},
                virtualMouse: true,
                onVirtualMouse: (_) {},
                joystick: true,
                onJoystick: (_) {},
                relative: false,
                onRelative: (_) {}),
            textScale: 2));
        await tester.pumpAndSettle();
        expect(find.byType(NlSegmented<bool>), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
