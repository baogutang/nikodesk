import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/nikodesk/nightline.dart';
import 'package:flutter_hbb/nikodesk/theme.dart';

double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  return (la > lb ? la + .05 : lb + .05) / (la > lb ? lb + .05 : la + .05);
}

Widget _host(Widget child,
        {Brightness brightness = Brightness.dark, bool reduceMotion = false}) =>
    MaterialApp(
        theme: nightlineTheme(brightness),
        builder: (context, app) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(disableAnimations: reduceMotion),
            child: app!),
        home: Scaffold(body: Center(child: child)));

BoxDecoration _decorationOf(WidgetTester tester, Finder finder) {
  final container = tester.widget<AnimatedContainer>(find
      .descendant(of: finder, matching: find.byType(AnimatedContainer))
      .first);
  return container.decoration! as BoxDecoration;
}

void main() {
  group('tokens', () {
    test('colours are the frozen Nightline draft values', () {
      const dark = NlColors.dark;
      const light = NlColors.light;
      expect(dark.bg, const Color(0xFF0B0D10));
      expect(dark.surface, const Color(0xFF13171B));
      expect(dark.fg, const Color(0xFFE6EDF2));
      expect(dark.accent, const Color(0xFF2FD8EE));
      expect(dark.onAccent, const Color(0xFF031317));
      expect(dark.accentText, const Color(0xFF5CE6F7));
      expect(dark.ok, const Color(0xFF3DDC97));
      expect(dark.warn, const Color(0xFFFFB547));
      expect(dark.danger, const Color(0xFFFF5D6C));
      expect(light.bg, const Color(0xFFF3F5F7));
      expect(light.surface, const Color(0xFFFFFFFF));
      expect(light.fg, const Color(0xFF0E1418));
      expect(light.accent, const Color(0xFF0A7F95));
      expect(light.accentText, const Color(0xFF07707F));
      expect(light.danger, const Color(0xFFD2283B));
      expect(NlColors.forBrightness(Brightness.dark), same(dark));
      expect(NlColors.forBrightness(Brightness.light), same(light));
    });

    // The pairs and thresholds of the draft's own contrast table.
    for (final nl in [NlColors.dark, NlColors.light]) {
      test('${nl.brightness.name} text meets the draft contrast table', () {
        final pairs = <(String, Color, Color, double)>[
          ('fg/bg', nl.fg, nl.bg, 4.5),
          ('fg-2/bg', nl.fg2, nl.bg, 4.5),
          ('fg-2/surface', nl.fg2, nl.surface, 4.5),
          // AA for small text everywhere fg-3 is drawn (the draft only
          // asked 3:1 here).
          ('fg-3/bg', nl.fg3, nl.bg, 4.5),
          ('fg-3/bg-2', nl.fg3, nl.bg2, 4.5),
          ('fg-3/surface', nl.fg3, nl.surface, 4.5),
          ('fg-3/surface-2', nl.fg3, nl.surface2, 4.5),
          ('fg-3/overlay', nl.fg3, nl.overlay, 4.5),
          ('on-danger/danger-fill', nl.onDanger, nl.dangerFill, 4.5),
          ('on-danger/danger-fill hover', nl.onDanger,
              Color.lerp(nl.dangerFill, nl.fg, .08)!, 4.5),
          ('on-accent/accent hover', nl.onAccent,
              Color.lerp(nl.accent, nl.fg, .08)!, 4.5),
          ('danger-fill/surface (UI)', nl.dangerFill, nl.surface, 3),
          ('accent-text/bg', nl.accentText, nl.bg, 4.5),
          ('accent-text/surface', nl.accentText, nl.surface, 4.5),
          ('on-accent/accent', nl.onAccent, nl.accent, 4.5),
          ('ok-text/surface', nl.okText, nl.surface, 4.5),
          ('warn-text/surface', nl.warnText, nl.surface, 4.5),
          ('danger-text/surface', nl.dangerText, nl.surface, 4.5),
          ('fg/overlay', nl.fg, nl.overlay, 4.5),
        ];
        for (final (name, fg, bg, need) in pairs) {
          expect(_contrast(fg, bg), greaterThanOrEqualTo(need), reason: name);
        }
      });
    }

    test('scales stay within the design-system limits', () {
      expect(NlType.scale, hasLength(7));
      for (var i = 1; i < NlType.scale.length; i++) {
        expect(NlType.scale[i], greaterThan(NlType.scale[i - 1]));
      }
      expect(NlRadius.all, hasLength(4));
      expect(NlMotion.durations, [
        const Duration(milliseconds: 100),
        const Duration(milliseconds: 180),
        const Duration(milliseconds: 280),
      ]);
      expect(NlMotion.ease, const Cubic(.16, 1, .3, 1));
      for (final space in [
        NlSpace.s1, NlSpace.s2, NlSpace.s3, NlSpace.s4,
        NlSpace.s5, NlSpace.s6, NlSpace.s8, NlSpace.s12,
      ]) {
        expect(space % 4, 0);
      }
      for (final nl in [NlColors.dark, NlColors.light]) {
        expect(nl.shadow(1), isEmpty);
        expect(nl.shadow(2), same(nl.shadow2));
        expect(nl.shadow(3), same(nl.shadow3));
        expect(nl.shadow(4), same(nl.shadow3));
      }
    });

    test('type helpers use the bundled families', () {
      final ui = NlType.text(NlType.s3);
      expect(ui.fontFamily, 'Inter');
      expect(ui.fontFamilyFallback, contains('PingFang SC'));
      expect(ui.height! * NlType.s3, 18);
      final mono = NlType.monoText(NlType.s7);
      expect(mono.fontFamily, 'JetBrains Mono');
      expect(mono.height! * NlType.s7, 36);
      expect(mono.fontFeatures, contains(const FontFeature.tabularFigures()));
    });

    test('colours interpolate and copy', () {
      const dark = NlColors.dark;
      const light = NlColors.light;
      expect(dark.lerp(light, 0).accent, dark.accent);
      expect(dark.lerp(light, 1).accent, light.accent);
      expect(dark.lerp(light, .5).bg, Color.lerp(dark.bg, light.bg, .5));
      expect(dark.lerp(null, .5), same(dark));
      final copy = dark.copyWith(accent: const Color(0xFF123456));
      expect(copy.accent, const Color(0xFF123456));
      expect(copy.bg, dark.bg);
      expect(copy.brightness, Brightness.dark);
    });

    testWidgets('reduced motion zeroes every duration', (tester) async {
      Duration? normal;
      Duration? reduced;
      await tester.pumpWidget(_host(Builder(builder: (context) {
        normal = NlMotion.of(context, NlMotion.base);
        return const SizedBox();
      })));
      await tester.pumpWidget(_host(Builder(builder: (context) {
        reduced = NlMotion.of(context, NlMotion.base);
        return const SizedBox();
      }), reduceMotion: true));
      expect(normal, NlMotion.base);
      expect(reduced, Duration.zero);
    });

    test('fonts and their OFL licences ship with the app', () {
      final pubspec = File('pubspec.yaml').readAsStringSync();
      for (final font in [
        'Inter-Regular.ttf',
        'Inter-SemiBold.ttf',
        'JetBrainsMono-Regular.ttf',
        'JetBrainsMono-Medium.ttf',
      ]) {
        expect(pubspec, contains('assets/fonts/$font'));
        expect(File('assets/fonts/$font').existsSync(), isTrue, reason: font);
      }
      expect(pubspec, contains('family: Inter'));
      expect(pubspec, contains('family: JetBrains Mono'));
      expect(pubspec, contains('- assets/fonts/licenses/'));
      for (final licence in ['Inter-OFL.txt', 'JetBrainsMono-OFL.txt']) {
        final text = File('assets/fonts/licenses/$licence').readAsStringSync();
        expect(text, contains('SIL OPEN FONT LICENSE Version 1.1'));
        expect(text, startsWith('Copyright'));
      }
    });
  });

  group('theme entry point', () {
    for (final brightness in Brightness.values) {
      testWidgets('nightlineTheme(${brightness.name}) carries the tokens',
          (tester) async {
        late BuildContext captured;
        await tester.pumpWidget(_host(Builder(builder: (context) {
          captured = context;
          return const SizedBox();
        }), brightness: brightness));
        final nl = NlColors.forBrightness(brightness);
        final theme = Theme.of(captured);
        expect(NlColors.maybeOf(captured), same(nl));
        expect(theme.colorScheme.primary, nl.accent);
        expect(theme.colorScheme.onPrimary, nl.onAccent);
        expect(theme.colorScheme.surface, nl.surface);
        expect(theme.colorScheme.onSurface, nl.fg);
        expect(theme.scaffoldBackgroundColor, nl.bg);
        expect(theme.textTheme.bodyMedium!.fontFamily, 'Inter');
        expect(theme.textTheme.bodyMedium!.fontSize, NlType.s3);
        expect(theme.textTheme.headlineMedium!.fontSize, NlType.s6);
        expect(theme.splashFactory, same(NoSplash.splashFactory));
        // Upstream pages hosted in the shell assert these exist.
        expect(MyTheme.color(captured).border, nl.line);
        expect(MyTheme.tabbar(captured).selectedTextColor, nl.fg);
        final sizes = <double>{
          for (final style in [
            theme.textTheme.displayLarge, theme.textTheme.headlineMedium,
            theme.textTheme.titleLarge, theme.textTheme.titleMedium,
            theme.textTheme.titleSmall, theme.textTheme.bodyLarge,
            theme.textTheme.bodyMedium, theme.textTheme.bodySmall,
            theme.textTheme.labelLarge, theme.textTheme.labelMedium,
            theme.textTheme.labelSmall,
          ])
            style!.fontSize!
        };
        expect(NlType.scale, containsAll(sizes));
      });
    }

    test('desktop windows take the Nightline theme app-wide', () {
      for (final brightness in Brightness.values) {
        final theme = nikoAppTheme(brightness);
        final nl = NlColors.forBrightness(brightness);
        expect(theme.extension<NlColors>(), same(nl));
        // DesktopTabPage paints the window strip (tab bar) from this.
        // ignore: deprecated_member_use
        expect(theme.colorScheme.background, nl.bg);
        expect(theme.scaffoldBackgroundColor, nl.bg);
      }
    });

    test('session windows stay dark in both modes', () {
      addTearDown(() => nikoSessionWindow = false);
      nikoSessionWindow = true;
      for (final brightness in Brightness.values) {
        expect(nikoAppTheme(brightness).brightness, Brightness.dark);
        expect(nikoAppTheme(brightness).extension<NlColors>(), same(NlColors.dark));
      }
      nikoSessionWindow = false;
      expect(nikoAppTheme(Brightness.light).brightness, Brightness.light);
    });

    testWidgets('previous NikoDesk theme keeps its own look', (tester) async {
      late BuildContext captured;
      await tester.pumpWidget(MaterialApp(
          theme: nikoTheme(Brightness.dark),
          home: Builder(builder: (context) {
            captured = context;
            return const NikoGlassCard(child: Text('card'));
          })));
      expect(NlColors.maybeOf(captured), isNull);
      final box = tester.widget<Container>(find.descendant(
          of: find.byType(NikoGlassCard), matching: find.byType(Container)));
      expect((box.decoration! as BoxDecoration).color, NikoPalette.darkCard);
    });

    testWidgets('existing cards and primary actions adopt Nightline when hosted',
        (tester) async {
      await tester.pumpWidget(_host(Column(mainAxisSize: MainAxisSize.min, children: [
        const NikoGlassCard(child: Text('card')),
        NikoPrimaryButton(onPressed: () {}, child: const Text('Go')),
      ])));
      final box = tester.widget<Container>(find.descendant(
          of: find.byType(NikoGlassCard), matching: find.byType(Container)));
      final decoration = box.decoration! as BoxDecoration;
      expect(decoration.color, NlColors.dark.surface);
      expect(decoration.borderRadius, BorderRadius.circular(NlRadius.r3));
      final ink = tester.widget<Ink>(find.descendant(
          of: find.byType(NikoPrimaryButton), matching: find.byType(Ink)));
      expect((ink.decoration! as BoxDecoration).color, NlColors.dark.accent);
      expect(tester.getSize(find.byType(NikoPrimaryButton)).height,
          greaterThanOrEqualTo(48));
      final label = tester.widget<DefaultTextStyle>(find
          .ancestor(of: find.text('Go'), matching: find.byType(DefaultTextStyle))
          .first);
      expect(label.style.fontFamily, NlType.ui);
    });
  });

  group('components', () {
    testWidgets('button is a named, keyboard-activated control',
        (tester) async {
      final semantics = tester.ensureSemantics();
      var calls = 0;
      await tester.pumpWidget(
          _host(NlButton(onPressed: () => calls++, label: 'Connect', shortcut: '⏎')));
      final button = find.byType(NlButton);
      expect(tester.getSize(button).height, NlButton.height);
      final node = tester.getSemantics(button);
      expect(node.hasFlag(SemanticsFlag.isButton), isTrue);
      expect(node.hasFlag(SemanticsFlag.isEnabled), isTrue);
      expect(node.label, 'Connect');
      expect(find.byType(NlKbd), findsOneWidget);
      expect(_decorationOf(tester, button).color, NlColors.dark.accent);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      expect(_decorationOf(tester, button).boxShadow, NlColors.dark.focusRing);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(calls, 1);
      await tester.tap(button);
      expect(calls, 2);
      semantics.dispose();
    });

    testWidgets('ghost, danger, small and disabled buttons', (tester) async {
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(_host(Column(mainAxisSize: MainAxisSize.min, children: [
        NlButton.ghost(
            key: const Key('ghost'), onPressed: () {}, label: 'Cancel'),
        NlButton.danger(
            key: const Key('danger'), onPressed: () {}, label: 'End'),
        NlButton(
            key: const Key('small'), small: true, onPressed: () {}, label: 'S'),
        const NlButton(key: Key('off'), onPressed: null, label: 'Off'),
      ]), brightness: Brightness.light));
      const nl = NlColors.light;
      final ghost = _decorationOf(tester, find.byKey(const Key('ghost')));
      expect(ghost.color, Colors.transparent);
      expect(ghost.border, Border.all(color: nl.line2));
      expect(_decorationOf(tester, find.byKey(const Key('danger'))).color,
          nl.dangerFill);
      expect(tester.getSize(find.byKey(const Key('small'))).height,
          NlButton.smallHeight);
      final off = tester.getSemantics(find.byKey(const Key('off')));
      expect(off.hasFlag(SemanticsFlag.hasEnabledState), isTrue);
      expect(off.hasFlag(SemanticsFlag.isEnabled), isFalse);
      await tester.tap(find.byKey(const Key('off')), warnIfMissed: false);
      semantics.dispose();
    });

    testWidgets('icon button names itself with its tooltip', (tester) async {
      final semantics = tester.ensureSemantics();
      var calls = 0;
      await tester.pumpWidget(_host(NlIconButton(
          icon: Icons.copy_rounded, tooltip: 'Copy ID', onPressed: () => calls++)));
      expect(find.byTooltip('Copy ID'), findsOneWidget);
      final node = tester.getSemantics(find.bySemanticsLabel('Copy ID'));
      expect(node.hasFlag(SemanticsFlag.isButton), isTrue);
      expect(node.hasFlag(SemanticsFlag.isEnabled), isTrue);
      await tester.tap(find.byType(NlIconButton));
      expect(calls, 1);
      expect(tester.getSize(find.byType(NlIconButton)),
          const Size.square(NlIconButton.size));
      semantics.dispose();
    });

    testWidgets('segmented control selects one value', (tester) async {
      final semantics = tester.ensureSemantics();
      var selected = 'all';
      await tester.pumpWidget(StatefulBuilder(
          builder: (context, setState) => _host(NlSegmented<String>(
              segments: const [
                NlSegment(value: 'all', label: 'All', count: '8'),
                NlSegment(value: 'online', label: 'Online', count: '5'),
              ],
              selected: selected,
              onChanged: (value) => setState(() => selected = value)))));
      expect(find.text('8'), findsOneWidget);
      await tester.tap(find.text('Online'));
      await tester.pumpAndSettle();
      expect(selected, 'online');
      final on = tester.getSemantics(find.text('Online'));
      expect(on.hasFlag(SemanticsFlag.isSelected), isTrue);
      expect(on.hasFlag(SemanticsFlag.isInMutuallyExclusiveGroup), isTrue);
      expect(
          tester.getSemantics(find.text('All')).hasFlag(SemanticsFlag.isSelected),
          isFalse);
      final fill = tester.widget<AnimatedContainer>(find
          .ancestor(of: find.text('Online'), matching: find.byType(AnimatedContainer))
          .first);
      expect((fill.decoration! as BoxDecoration).color, NlColors.dark.accentSoft);
      semantics.dispose();
    });

    testWidgets('chip toggles and strikes through when revoked',
        (tester) async {
      final semantics = tester.ensureSemantics();
      var on = true;
      await tester.pumpWidget(StatefulBuilder(
          builder: (context, setState) => _host(NlChip(
              label: 'Files',
              selected: on,
              strikeWhenOff: true,
              onChanged: (value) => setState(() => on = value)))));
      TextStyle style() => tester.widget<Text>(find.text('Files')).style!;
      expect(style().decoration, isNot(TextDecoration.lineThrough));
      expect(tester.getSemantics(find.byType(NlChip)).hasFlag(SemanticsFlag.isToggled),
          isTrue);
      await tester.tap(find.byType(NlChip));
      await tester.pumpAndSettle();
      expect(on, isFalse);
      expect(style().decoration, TextDecoration.lineThrough);
      expect(tester.getSemantics(find.byType(NlChip)).hasFlag(SemanticsFlag.isToggled),
          isFalse);
      semantics.dispose();
    });

    testWidgets('panel elevation maps to ring, then shadows', (tester) async {
      await tester.pumpWidget(_host(const Column(mainAxisSize: MainAxisSize.min, children: [
        NlPanel(key: Key('one'), child: Text('1')),
        NlPanel(key: Key('three'), elevation: 3, child: Text('3')),
      ])));
      BoxDecoration of(String key) => tester
          .widget<Container>(find.descendant(
              of: find.byKey(Key(key)), matching: find.byType(Container)))
          .decoration! as BoxDecoration;
      const nl = NlColors.dark;
      expect(of('one').color, nl.surface);
      expect(of('one').border, Border.all(color: nl.ring));
      expect(of('one').borderRadius, BorderRadius.circular(NlRadius.r3));
      expect(of('one').boxShadow, isEmpty);
      expect(of('three').color, nl.overlay);
      expect(of('three').boxShadow, nl.shadow3);
    });

    testWidgets('list row lays out title, detail, trailing and divider',
        (tester) async {
      var taps = 0;
      await tester.pumpWidget(_host(SizedBox(
          width: 400,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            NlListRow(
                key: const Key('first'),
                divider: false,
                title: 'Private server',
                subtitle: 'desk.example.net',
                trailing: const Text('Ready'),
                onTap: () => taps++),
            const NlListRow(key: Key('dense'), dense: true, title: 'Screen'),
          ]))));
      expect(find.text('desk.example.net'), findsOneWidget);
      expect(tester.getSize(find.byKey(const Key('first'))).height,
          greaterThanOrEqualTo(48));
      expect(tester.getSize(find.byKey(const Key('dense'))).height, 32);
      BoxDecoration row(String key) => tester
          .widget<Container>(find
              .descendant(of: find.byKey(Key(key)), matching: find.byType(Container))
              .first)
          .decoration! as BoxDecoration;
      expect(row('first').border, isNull);
      expect(row('dense').border,
          Border(top: BorderSide(color: NlColors.dark.line)));
      await tester.tap(find.text('Private server'));
      expect(taps, 1);
    });

    testWidgets('kbd and mono labels use the mono family', (tester) async {
      await tester.pumpWidget(_host(const Column(mainAxisSize: MainAxisSize.min, children: [
        NlKbd('⌘K'),
        NlMonoLabel('This computer'),
        NlMonoLabel('ready', tone: NlTone.ok, leading: NlLed(NlLedState.ok)),
      ])));
      expect(tester.widget<Text>(find.text('⌘K')).style!.fontFamily, NlType.mono);
      final label = tester.widget<Text>(find.text('THIS COMPUTER'));
      expect(label.style!.fontFamily, NlType.mono);
      expect(label.style!.letterSpacing, closeTo(1.32, .001));
      expect(label.style!.color, NlColors.dark.fg3);
      expect(tester.widget<Text>(find.text('READY')).style!.color,
          NlColors.dark.okText);
    });

    testWidgets('LEDs show state and only pulse when motion is allowed',
        (tester) async {
      BoxDecoration dot(Key key) => tester
          .widget<Container>(find.descendant(
              of: find.byKey(key), matching: find.byType(Container)))
          .decoration! as BoxDecoration;
      await tester.pumpWidget(_host(const Row(mainAxisSize: MainAxisSize.min, children: [
        NlLed(NlLedState.off, key: Key('off')),
        NlLed(NlLedState.warn, key: Key('warn')),
      ])));
      expect(dot(const Key('off')).color, isNull);
      expect(dot(const Key('off')).border, isNotNull);
      expect(dot(const Key('warn')).color, NlColors.dark.warn);
      expect(tester.hasRunningAnimations, isFalse);

      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(_host(const NlLed(NlLedState.live)));
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.hasRunningAnimations, isTrue);

      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
          _host(const NlLed(NlLedState.live), reduceMotion: true));
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.hasRunningAnimations, isFalse);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('brand mark paints at any size', (tester) async {
      await tester.pumpWidget(_host(const Row(mainAxisSize: MainAxisSize.min, children: [
        NlMark(size: 28),
        NlMark(),
        NlMark(size: 52),
      ])));
      expect(tester.takeException(), isNull);
      expect(tester.getSize(find.byType(NlMark).last), const Size.square(52));
    });
  });
}
