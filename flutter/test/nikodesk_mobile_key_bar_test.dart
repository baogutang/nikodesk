import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/nikodesk/mobile_key_bar.dart';
import 'package:flutter_hbb/nikodesk/nightline.dart';
import 'package:flutter_hbb/nikodesk/theme.dart';
import 'package:flutter_hbb/nikodesk/ui.dart';

void main() {
  tearDown(() => NikoLanguage.english = false);

  // Layout and callback fixtures only; no key reaches a session.
  Widget host(Widget bar, {double textScale = 1}) => MaterialApp(
      theme: nikoTheme(Brightness.dark).copyWith(platform: TargetPlatform.iOS),
      builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!),
      home: Scaffold(body: Align(alignment: Alignment.topCenter, child: bar)));

  Widget bar(List<String> calls,
          {String platform = kPeerPlatformWindows,
          Set<NikoModifier> down = const {},
          bool more = true,
          bool fn = false}) =>
      NikoKeyBar(
          peerPlatform: platform,
          down: down,
          more: more,
          fn: fn,
          onModifier: (modifier) => calls.add(modifier.name),
          onKey: calls.add,
          onShortcut: (key) => calls.add('shortcut $key'),
          onMore: () => calls.add('more'),
          onFn: () => calls.add('fn'),
          onPin: () => calls.add('pin'));

  Finder key(String name) => find.byKey(ValueKey('nikodesk-key-$name'));

  testWidgets('keys send their virtual key names', (tester) async {
    final calls = <String>[];
    await tester.pumpWidget(host(bar(calls)));
    for (final name in [
      'control',
      'VK_ESCAPE',
      'VK_LEFT',
      'VK_HOME',
      'VK_SNAPSHOT',
      'VK_ENTER',
      'shortcut-C',
      'toggle-fn',
      'toggle-more',
      'toggle-pin',
    ]) {
      await tester.ensureVisible(key(name));
      await tester.pumpAndSettle();
      await tester.tap(key(name));
    }
    expect(calls, [
      'control',
      'VK_ESCAPE',
      'VK_LEFT',
      'VK_HOME',
      'VK_SNAPSHOT',
      'VK_ENTER',
      'shortcut VK_C',
      'fn',
      'more',
      'pin',
    ]);
    expect(find.text('Ctrl+C'), findsOneWidget);
    expect(find.text('Win'), findsOneWidget);
  });

  testWidgets('a Mac peer gets its symbols and no PC-only keys',
      (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(host(
        bar([], platform: kPeerPlatformMacOS, down: {NikoModifier.command})));
    for (final symbol in ['⌃', '⌥', '⇧', '⌘', '⌘C', '⌘V', '⌘S']) {
      expect(find.text(symbol), findsOneWidget);
    }
    expect(key('VK_SNAPSHOT'), findsNothing);
    expect(
        tester
            .getSemantics(key('command'))
            .getSemanticsData()
            .hasFlag(SemanticsFlag.isSelected),
        isTrue);
    expect(tester.getSemantics(key('command')).label, 'Command');
    semantics.dispose();
  });

  testWidgets('rows follow the more and function toggles', (tester) async {
    await tester.pumpWidget(host(bar([], more: false)));
    expect(key('VK_HOME'), findsNothing);
    expect(key('VK_F1'), findsNothing);
    expect(key('VK_ESCAPE'), findsOneWidget);
    await tester.pumpWidget(host(bar([], more: false, fn: true)));
    expect(key('VK_F1'), findsOneWidget);
    expect(key('VK_F12'), findsOneWidget);
  });

  testWidgets('the strip is as wide as its keys, up to the screen',
      (tester) async {
    addTearDown(tester.view.reset);
    for (final (width, platform) in [
      (1180.0, kPeerPlatformMacOS),
      (390.0, kPeerPlatformWindows),
    ]) {
      tester.view.physicalSize = Size(width, 820);
      tester.view.devicePixelRatio = 1;
      await tester.pumpWidget(MaterialApp(
          theme: nikoTheme(Brightness.light)
              .copyWith(platform: TargetPlatform.iOS),
          home: Scaffold(
              body: NikoKeyBarFrame(
                  keyboardIsVisible: true,
                  stripKey: const Key('strip'),
                  child: bar([], platform: platform)))));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final strip = tester.getRect(find.byKey(const Key('strip')));
      expect(strip.top, 24);
      if (width > 860) {
        expect(strip.width, lessThan(860));
        expect(strip.center.dx, moreOrLessEquals(width / 2, epsilon: 1));
      } else {
        expect(strip.width, width - 16);
      }
      // Dark in a light app, like the dock.
      expect(NlColors.of(tester.element(key('VK_ESCAPE'))).isDark, isTrue);
    }
  });

  for (final english in [false, true]) {
    testWidgets('bar fits 320px at 200% text ($english)', (tester) async {
      NikoLanguage.english = english;
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester
          .pumpWidget(host(bar([], more: true, fn: false), textScale: 2));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      // The toggles stay reachable while the rows scroll.
      expect(tester.getRect(key('toggle-pin')).right, lessThanOrEqualTo(320));
    });
  }
}
