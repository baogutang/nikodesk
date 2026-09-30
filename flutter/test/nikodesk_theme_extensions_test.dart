import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/nikodesk/theme.dart';

// The connection-manager window and other hosted upstream pages resolve
// ColorThemeExtension / TabbarTheme from the ambient theme with non-null
// assertions. A NikoDesk theme without those extensions rendered as a grey
// window in release builds; this locks the regression.
void main() {
  for (final brightness in [Brightness.light, Brightness.dark]) {
    testWidgets(
        'nikoTheme(${brightness.name}) provides the upstream extensions',
        (tester) async {
      Color? borderColor;
      await tester.pumpWidget(MaterialApp(
          theme: nikoTheme(brightness),
          home: Builder(builder: (context) {
            borderColor = MyTheme.color(context).border;
            MyTheme.tabbar(context);
            return const SizedBox();
          })));
      expect(tester.takeException(), isNull);
      expect(borderColor, brightness == Brightness.light ? NikoPalette.lightLine : NikoPalette.darkLine);
      final tabTheme = nikoTheme(brightness).extension<ColorThemeExtension>();
      expect(tabTheme, isNotNull);
    });
  }
  testWidgets('primary action exposes a button and activates with keyboard', (tester) async {
    final semantics = tester.ensureSemantics();

    var calls = 0;
    await tester.pumpWidget(MaterialApp(theme: nikoTheme(Brightness.light),
        home: Scaffold(body: Center(child: NikoPrimaryButton(
            compact: true, onPressed: () => calls++, child: const Text('Connect'))))));
    final button = find.byType(NikoPrimaryButton);
    expect(tester.getSize(button).height, greaterThanOrEqualTo(48));
    expect(tester.getSemantics(button).hasFlag(SemanticsFlag.isButton), isTrue);
    expect(tester.getSemantics(button).hasFlag(SemanticsFlag.isEnabled), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(calls, 1);
    semantics.dispose();
  });

  testWidgets('disabled primary action remains named and never invokes callback', (tester) async {
    final semantics = tester.ensureSemantics();

    await tester.pumpWidget(MaterialApp(theme: nikoTheme(Brightness.dark),
        home: const Scaffold(body: Center(child: NikoPrimaryButton(
            onPressed: null, child: Text('Connect'))))));
    final node = tester.getSemantics(find.byType(NikoPrimaryButton));
    expect(node.hasFlag(SemanticsFlag.isButton), isTrue);
    expect(node.hasFlag(SemanticsFlag.hasEnabledState), isTrue);
    expect(node.hasFlag(SemanticsFlag.isEnabled), isFalse);
    expect(node.label, 'Connect');
    semantics.dispose();
  });

  testWidgets('shared theme follows system brightness without a fixed child Theme', (tester) async {
    addTearDown(tester.binding.platformDispatcher.clearPlatformBrightnessTestValue);
    tester.binding.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    Color? primary;
    Widget application() => MaterialApp(theme: nikoTheme(Brightness.light), darkTheme: nikoTheme(Brightness.dark),
        themeMode: ThemeMode.system, home: Builder(builder: (context) {
          primary = Theme.of(context).colorScheme.primary;
          return const SizedBox();
        }));
    await tester.pumpWidget(application());
    expect(primary, NikoPalette.lightSeed);
    tester.binding.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    await tester.pumpAndSettle();
    expect(primary, NikoPalette.darkSeed);
  });

  test('white primary labels remain readable across the action gradient', () {
    for (final color in NikoPalette.primaryGradient.colors) {
      final contrast = (Colors.white.computeLuminance() + .05) / (color.computeLuminance() + .05);
      expect(contrast, greaterThanOrEqualTo(4.5));
    }
  });

  test('small status labels remain readable on the light glass surfaces', () {
    for (final canvas in NikoPalette.lightCanvas.colors) {
      final surface = Color.alphaBlend(NikoPalette.lightCard, canvas);
      for (final foreground in [NikoPalette.lightMuted, NikoPalette.lightSuccessText,
        NikoPalette.lightWarningText, NikoPalette.lightOfflineText]) {
        final contrast = (surface.computeLuminance() + .05) / (foreground.computeLuminance() + .05);
        expect(contrast, greaterThanOrEqualTo(4.5));
      }
    }
  });

}
