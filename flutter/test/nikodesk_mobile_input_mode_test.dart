import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/nikodesk/mobile_input_mode.dart';
import 'package:flutter_hbb/nikodesk/theme.dart';
import 'package:flutter_hbb/nikodesk/ui.dart';

void main() {
  for (final size in [const Size(320, 700), const Size(844, 390)]) {
    for (final brightness in [Brightness.light, Brightness.dark]) {
      testWidgets('input mode is readable and reachable at $size/$brightness', (tester) async {
        await tester.binding.setSurfaceSize(size);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        NikoLanguage.english = true;
        addTearDown(() => NikoLanguage.english = false);
        final semantics = tester.ensureSemantics();
        var touch = false;
        final changed = <bool>[];
        await tester.pumpWidget(MaterialApp(
          theme: nikoTheme(brightness),
          builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(2)), child: child!),
          home: Scaffold(body: Padding(
            padding: const EdgeInsets.all(12),
            child: StatefulBuilder(builder: (context, setState) => NikoMobileInputMode(
              touchMode: touch,
              onChanged: (value) => setState(() {
                touch = value;
                changed.add(value);
              }),
            )),
          )),
        ));
        await tester.pumpAndSettle();
        final mouse = find.byKey(const ValueKey('nikodesk-mobile-input-mode-false'));
        final finger = find.byKey(const ValueKey('nikodesk-mobile-input-mode-true'));
        expect(tester.getSize(finger).height, greaterThanOrEqualTo(48));
        expect(tester.getSemantics(mouse).getSemanticsData().hasFlag(SemanticsFlag.isChecked), isTrue);
        expect(tester.getSemantics(mouse).getSemanticsData().hasFlag(SemanticsFlag.isSelected), isTrue);
        expect(finger.hitTestable(), findsOneWidget);
        await tester.tap(finger);
        await tester.pumpAndSettle();
        expect(changed, [true]);
        expect(tester.getSemantics(finger).getSemanticsData().hasFlag(SemanticsFlag.isChecked), isTrue);
        expect(tester.getSemantics(finger).getSemanticsData().hasFlag(SemanticsFlag.isSelected), isTrue);
        expect(tester.getSemantics(mouse).getSemanticsData().hasFlag(SemanticsFlag.isChecked), isFalse);
        await tester.tap(finger);
        expect(changed, [true]);
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.sendKeyEvent(LogicalKeyboardKey.space);
        await tester.pumpAndSettle();
        expect(changed, [true, false]);
        expect(tester.takeException(), isNull);
        semantics.dispose();
      });
    }
  }
}
