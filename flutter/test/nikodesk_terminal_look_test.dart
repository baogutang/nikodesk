import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_hbb/nikodesk/nightline.dart';
import 'package:flutter_hbb/nikodesk/terminal_look.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

// The remote terminal's colours and face under the Nightline theme.

double _contrast(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  return (math.max(la, lb) + .05) / (math.min(la, lb) + .05);
}

void main() {
  const nikodesk = bool.fromEnvironment('NIKODESK');

  Future<({TerminalTheme theme, TerminalStyle style})?> look(
      WidgetTester tester, ThemeData theme) async {
    ({TerminalTheme theme, TerminalStyle style})? found;
    await tester.pumpWidget(MaterialApp(
        theme: theme,
        home: Builder(builder: (context) {
          found = nikoTerminalLook(context);
          return const SizedBox.shrink();
        })));
    return found;
  }

  testWidgets('the stock look stays outside Nightline', (tester) async {
    expect(await look(tester, ThemeData.dark()), isNull);
  });

  testWidgets('Nightline gives the window background and JetBrains Mono',
      (tester) async {
    final found = await look(tester, nightlineTheme(Brightness.dark));
    if (!nikodesk) {
      expect(found, isNull);
      return;
    }
    expect(found!.theme.background, NlColors.orbitDark.bg);
    expect(found.theme.foreground, NlColors.orbitDark.fg);
    expect(found.style.fontFamily, NlType.mono);
    // Rows and columns stay what the stock style gives.
    expect(found.style.fontSize, const TerminalStyle().fontSize);
    expect(found.style.height, const TerminalStyle().height);
  });

  test('every ANSI colour reads on its background in both palettes', () {
    for (final nl in [
      NlColors.orbitLight,
      NlColors.orbitDark,
    ]) {
      final t = nikoTerminalTheme(nl);
      final colours = {
        'foreground': t.foreground,
        // Black on a dark terminal is a background shade, as elsewhere.
        if (!nl.isDark) 'black': t.black,
        'red': t.red,
        'green': t.green,
        'yellow': t.yellow,
        'blue': t.blue,
        'magenta': t.magenta,
        'cyan': t.cyan,
        'white': t.white,
        'brightBlack': t.brightBlack,
        'brightRed': t.brightRed,
        'brightGreen': t.brightGreen,
        'brightYellow': t.brightYellow,
        'brightBlue': t.brightBlue,
        'brightMagenta': t.brightMagenta,
        'brightCyan': t.brightCyan,
        'brightWhite': t.brightWhite,
      };
      for (final MapEntry(:key, :value) in colours.entries) {
        expect(_contrast(value, t.background), greaterThanOrEqualTo(3),
            reason: '${nl.preset.name} ${nl.brightness.name} $key');
      }
    }
  });
}
