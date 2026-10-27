import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/nikodesk/nightline.dart';
import 'package:flutter_hbb/nikodesk/theme.dart';
import 'package:flutter_hbb/nikodesk/ui.dart';

double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  return (la > lb ? la + .05 : lb + .05) / (la > lb ? lb + .05 : la + .05);
}

/// Pointer density (macOS) unless [platform] says otherwise; flutter_test
/// defaults to Android, which is a touch platform.
Widget _host(Widget child,
        {Brightness brightness = Brightness.dark,
        bool reduceMotion = false,
        TargetPlatform platform = TargetPlatform.macOS}) =>
    MaterialApp(
        theme: nightlineTheme(brightness).copyWith(platform: platform),
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

Future<BuildContext> _context(WidgetTester tester,
    {Brightness brightness = Brightness.dark}) async {
  late BuildContext captured;
  await tester.pumpWidget(_host(Builder(builder: (context) {
    captured = context;
    return const SizedBox();
  }), brightness: brightness));
  return captured;
}

const _palettes = [
  NlColors.orbitLight,
  NlColors.orbitDark,
];

void main() {
  group('tokens', () {
    test('the 3.0 look carries the DESIGN.md values', () {
      expect(NlColors.active, NlPreset.orbit);
      expect(NlColors.dark, same(NlColors.orbitDark));
      expect(NlColors.light, same(NlColors.orbitLight));
      const light = NlColors.orbitLight;
      expect(light.bg, const Color(0xFFF0F3F7));
      expect(light.surface, const Color(0xFFFDFEFF));
      expect(light.fg, const Color(0xFF191D24));
      expect(light.accentFill, const Color(0xFF076DF1));
      expect(light.accentText, const Color(0xFF0260D9));
      expect(light.dangerFill, const Color(0xFFBE2323));
      expect(light.brand, const Color(0xFF005BD4));
      const dark = NlColors.orbitDark;
      expect(dark.bg, const Color(0xFF0A0C11));
      expect(dark.surface, const Color(0xFF13161B));
      expect(dark.fg, const Color(0xFFEAEDF2));
      expect(dark.accentFill, const Color(0xFF146AE3));
      expect(dark.accentText, const Color(0xFF73ABFF));
      expect(dark.brand, const Color(0xFF00398D));
      for (final nl in _palettes) {
        expect(nl.preset, NlPreset.orbit);
        expect(NlColors.palette(NlPreset.orbit, nl.brightness), same(nl));
        // Devices are told apart by name and picture, never by colour.
        expect(nl.tiles, hasLength(1));
        expect(nl.glow, isEmpty);
      }
    });

    test('a 2.x clay preference loads the one look', () {
      addTearDown(() => NlColors.active = NlPreset.orbit);
      NikoAppearance.usePreference('clay');
      expect(NlColors.active, NlPreset.orbit);
      expect(nightlineTheme(Brightness.light).extension<NlColors>(),
          same(NlColors.orbitLight));
      expect(nikoAppTheme(Brightness.dark).extension<NlColors>(),
          same(NlColors.orbitDark));
      NikoAppearance.usePreference('unknown');
      expect(NlColors.active, NlPreset.orbit);
    });

    test('white type on the brand panel reads in both modes', () {
      for (final nl in _palettes) {
        expect(_contrast(nl.brandInk, nl.brand), greaterThanOrEqualTo(4.5));
        expect(_contrast(nl.brandInk2, nl.brand), greaterThanOrEqualTo(4.5));
        expect(_contrast(nl.brand, nl.brandInk), greaterThanOrEqualTo(4.5));
      }
    });

    // Text 4.5:1 (WCAG AA); accent and danger marks 3:1 (WCAG 1.4.11).
    for (final nl in _palettes) {
      test('${nl.preset.name} ${nl.brightness.name} meets AA contrast', () {
        final soft = Color.alphaBlend(nl.accentSoft, nl.bg);
        final pairs = <(String, Color, Color, double)>[
          for (final (name, surface) in [
            ('bg', nl.bg),
            ('bg2', nl.bg2),
            ('surface', nl.surface),
            ('surface2', nl.surface2),
            ('overlay', nl.overlay),
          ]) ...[
            ('fg/$name', nl.fg, surface, 4.5),
            ('fg2/$name', nl.fg2, surface, 4.5),
            ('fg3/$name', nl.fg3, surface, 4.5),
          ],
          ('onAccent/accentFill', nl.onAccent, nl.accentFill, 4.5),
          ('onAccent/accentHover', nl.onAccent, nl.accentHover, 4.5),
          ('onDanger/dangerFill', nl.onDanger, nl.dangerFill, 4.5),
          ('onDanger/dangerHover', nl.onDanger, nl.dangerHover, 4.5),
          ('accentText/bg', nl.accentText, nl.bg, 4.5),
          ('accentText/bg2', nl.accentText, nl.bg2, 4.5),
          ('accentText/surface', nl.accentText, nl.surface, 4.5),
          ('accentText/accentSoft', nl.accentText, soft, 4.5),
          ('okText/bg', nl.okText, nl.bg, 4.5),
          ('okText/surface', nl.okText, nl.surface, 4.5),
          ('warnText/bg', nl.warnText, nl.bg, 4.5),
          ('warnText/surface', nl.warnText, nl.surface, 4.5),
          ('dangerText/surface', nl.dangerText, nl.surface, 4.5),
          ('dangerText/overlay', nl.dangerText, nl.overlay, 4.5),
          ('accent/bg (UI)', nl.accent, nl.bg, 3),
          ('accent/bg2 (UI)', nl.accent, nl.bg2, 3),
          ('accent/surface (UI)', nl.accent, nl.surface, 3),
          ('danger/surface (UI)', nl.danger, nl.surface, 3),
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
      expect(NlRadius.all, [4, 6, 10, 12, 999]);
      expect(NlMotion.durations, [
        const Duration(milliseconds: 80),
        const Duration(milliseconds: 120),
        const Duration(milliseconds: 200),
        const Duration(milliseconds: 300),
        const Duration(milliseconds: 420),
      ]);
      expect(NlMotion.ease, const Cubic(.16, 1, .3, 1));
      expect(NlMotion.exit, const Cubic(.3, 0, .8, .15));
      for (final space in [
        NlSpace.s1, NlSpace.s2, NlSpace.s3, NlSpace.s4, NlSpace.s5,
        NlSpace.s6, NlSpace.s8, NlSpace.s10, NlSpace.s12, NlSpace.s16,
      ]) {
        expect(space % 4, 0);
      }
      for (final nl in _palettes) {
        expect(nl.shadow(0), same(nl.shadow1));
        expect(nl.shadow(1), same(nl.shadow1));
        expect(nl.shadow(2), same(nl.shadow2));
        expect(nl.shadow(3), same(nl.shadow3));
        expect(nl.shadow(4), same(nl.shadow3));
      }
      // Dark surfaces separate by tone; a resting shadow would vanish.
      expect(NlColors.orbitDark.shadow1, isEmpty);
      expect(NlColors.orbitLight.shadow1, isNotEmpty);
    });

    test('size classes and density follow the window and platform', () {
      expect(NlLayout.sizeOf(390), NlSize.compact);
      expect(NlLayout.sizeOf(599), NlSize.compact);
      expect(NlLayout.sizeOf(600), NlSize.medium);
      expect(NlLayout.sizeOf(999), NlSize.medium);
      expect(NlLayout.sizeOf(1000), NlSize.expanded);
      expect(NlLayout.sizeOf(1440), NlSize.expanded);
    });

    test('type helpers use the bundled families and Inter tracking', () {
      final ui = NlType.text(NlType.s3);
      expect(ui.fontFamily, 'Inter');
      expect(ui.fontFamilyFallback, contains('PingFang SC'));
      expect(ui.height! * NlType.s3, closeTo(18, 1e-9));
      // Slightly open at caption sizes, tighter as text grows.
      expect(NlType.text(NlType.s1).letterSpacing, greaterThan(0));
      expect(NlType.text(NlType.s7).letterSpacing, lessThan(0));
      expect(NlType.tracking(NlType.s6), lessThan(NlType.tracking(NlType.s4)));
      final mono = NlType.monoText(NlType.s7);
      expect(mono.fontFamily, 'JetBrains Mono');
      expect(mono.height! * NlType.s7, closeTo(36, 1e-9));
      expect(mono.letterSpacing, 0);
      expect(mono.fontFeatures, contains(const FontFeature.tabularFigures()));
    });

    test('icons come from the bundled Lucide font', () {
      for (final icon in [
        NlIcons.search,
        NlIcons.monitor,
        NlIcons.settings,
        NlIcons.close,
        NlIcons.chevronRight,
      ]) {
        expect(icon.fontFamily, 'Lucide');
        expect(icon.codePoint, inInclusiveRange(0xE000, 0xF8FF));
      }
      expect(NlIcons.search.codePoint, isNot(NlIcons.monitor.codePoint));
    });

    test('device marks share one neutral colour', () {
      final nl = NlColors.orbitLight;
      expect(nl.tile('123 456 789'), nl.tile('987 654 321'));
      final seen = {for (var i = 0; i < 64; i++) nl.tile('device-$i')};
      expect(seen, {nl.tiles.single});
    });

    test('colours interpolate and copy', () {
      final dark = NlColors.dark;
      final light = NlColors.light;
      expect(dark.lerp(light, 0).accent, dark.accent);
      expect(dark.lerp(light, 1).accent, light.accent);
      expect(dark.lerp(light, .5).bg, Color.lerp(dark.bg, light.bg, .5));
      expect(dark.lerp(light, 1).accentFill, light.accentFill);
      expect(dark.lerp(null, .5), same(dark));
      final copy = dark.copyWith(accent: const Color(0xFF123456));
      expect(copy.accent, const Color(0xFF123456));
      expect(copy.bg, dark.bg);
      expect(copy.brightness, Brightness.dark);
      expect(copy.preset, dark.preset);
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

    test('fonts and their licences ship with the app', () {
      final pubspec = File('pubspec.yaml').readAsStringSync();
      for (final font in [
        'Inter-Regular.ttf',
        'Inter-Medium.ttf',
        'Inter-SemiBold.ttf',
        'JetBrainsMono-Regular.ttf',
        'JetBrainsMono-Medium.ttf',
        'Lucide.ttf',
      ]) {
        expect(pubspec, contains('assets/fonts/$font'));
        expect(File('assets/fonts/$font').existsSync(), isTrue, reason: font);
      }
      expect(pubspec, contains('family: Inter'));
      expect(pubspec, contains('family: JetBrains Mono'));
      expect(pubspec, contains('family: Lucide'));
      expect(pubspec, contains('- assets/fonts/licenses/'));
      for (final licence in ['Inter-OFL.txt', 'JetBrainsMono-OFL.txt']) {
        final text = File('assets/fonts/licenses/$licence').readAsStringSync();
        expect(text, contains('SIL OPEN FONT LICENSE Version 1.1'));
        expect(text, startsWith('Copyright'));
      }
      final lucide =
          File('assets/fonts/licenses/Lucide-LICENSE.txt').readAsStringSync();
      expect(lucide, contains('ISC License'));
      expect(lucide, contains('Feather'));
    });
  });

  group('theme entry point', () {
    for (final brightness in Brightness.values) {
      testWidgets('nightlineTheme(${brightness.name}) carries the tokens',
          (tester) async {
        final captured = await _context(tester, brightness: brightness);
        final nl = NlColors.forBrightness(brightness);
        final theme = Theme.of(captured);
        expect(NlColors.maybeOf(captured), same(nl));
        expect(theme.colorScheme.primary, nl.accentFill);
        expect(theme.colorScheme.onPrimary, nl.onAccent);
        expect(theme.colorScheme.surface, nl.surface);
        expect(theme.colorScheme.onSurface, nl.fg);
        expect(theme.colorScheme.error, nl.danger);
        expect(theme.scaffoldBackgroundColor, nl.bg);
        expect(theme.textTheme.bodyMedium!.fontFamily, 'Inter');
        expect(theme.textTheme.bodyMedium!.fontSize, NlType.s3);
        expect(theme.textTheme.headlineMedium!.fontSize, NlType.s6);
        expect(theme.textTheme.labelLarge!.fontWeight, FontWeight.w500);
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

    test('every NikoDesk window takes the design-system theme', () {
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

    test('iPad and iPhone keep the native back swipe', () {
      final builders = nightlineTheme(Brightness.light).pageTransitionsTheme.builders;
      expect(builders[TargetPlatform.iOS], isA<CupertinoPageTransitionsBuilder>());
      expect(builders[TargetPlatform.macOS], isA<NlPageTransitionsBuilder>());
      expect(builders[TargetPlatform.windows], isA<NlPageTransitionsBuilder>());
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

    testWidgets('existing cards and primary actions adopt the tokens when hosted',
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
      expect((ink.decoration! as BoxDecoration).color, NlColors.dark.accentFill);
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
      expect(_decorationOf(tester, button).color, NlColors.dark.accentFill);
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

    testWidgets('hover deepens the primary fill', (tester) async {
      await tester.pumpWidget(_host(NlButton(onPressed: () {}, label: 'Go')));
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(gesture.removePointer);
      await gesture.addPointer(location: Offset.zero);
      await gesture.moveTo(tester.getCenter(find.byType(NlButton)));
      await tester.pumpAndSettle();
      expect(_decorationOf(tester, find.byType(NlButton)).color,
          NlColors.dark.accentHover);
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
      final nl = NlColors.light;
      final ghost = _decorationOf(tester, find.byKey(const Key('ghost')));
      expect(ghost.color, nl.overlay);
      expect(ghost.border, Border.all(color: nl.line2));
      expect(ghost.boxShadow, nl.shadow1);
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

    testWidgets('touch platforms get larger targets', (tester) async {
      await tester.pumpWidget(_host(
          Column(mainAxisSize: MainAxisSize.min, children: [
            NlButton(onPressed: () {}, label: 'Go'),
            NlIconButton(icon: NlIcons.copy, tooltip: 'Copy', onPressed: () {}),
            NlSwitch(value: true, onChanged: (_) {}),
          ]),
          platform: TargetPlatform.iOS));
      // A 40-point button inside a 48-point hit area.
      expect(tester.getSize(find.byType(NlButton)).height, 48);
      expect(
          tester
              .getSize(find.descendant(
                  of: find.byType(NlButton),
                  matching: find.byType(AnimatedContainer)))
              .height,
          NlButton.height + 8);
      expect(tester.getSize(find.byType(NlIconButton)), const Size.square(44));
      expect(tester.getSize(find.byType(NlSwitch)), const Size(46, 28));
    });

    testWidgets('icon button names itself with its tooltip', (tester) async {
      final semantics = tester.ensureSemantics();
      var calls = 0;
      await tester.pumpWidget(_host(NlIconButton(
          icon: NlIcons.copy, tooltip: 'Copy ID', onPressed: () => calls++)));
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

    testWidgets('segmented control slides its thumb to the selection',
        (tester) async {
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
      AnimatedAlign thumb() => tester.widget<AnimatedAlign>(find.descendant(
          of: find.byType(NlSegmented<String>),
          matching: find.byType(AnimatedAlign)));
      expect(thumb().alignment, const Alignment(-1, 0));
      // Segments share the width equally.
      expect(tester.getSize(find.byType(Expanded).first).width,
          tester.getSize(find.byType(Expanded).last).width);
      await tester.tap(find.text('Online'));
      await tester.pumpAndSettle();
      expect(selected, 'online');
      expect(thumb().alignment, const Alignment(1, 0));
      final on = tester.getSemantics(find.text('Online'));
      expect(on.hasFlag(SemanticsFlag.isSelected), isTrue);
      expect(on.hasFlag(SemanticsFlag.isInMutuallyExclusiveGroup), isTrue);
      expect(
          tester.getSemantics(find.text('All')).hasFlag(SemanticsFlag.isSelected),
          isFalse);
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

    testWidgets('switch toggles and announces its state', (tester) async {
      final semantics = tester.ensureSemantics();
      var value = false;
      await tester.pumpWidget(StatefulBuilder(
          builder: (context, setState) => _host(NlSwitch(
              value: value,
              semanticLabel: 'Force relay',
              onChanged: (next) => setState(() => value = next)))));
      expect(tester.getSize(find.byType(NlSwitch)), const Size(32, 18));
      expect(_decorationOf(tester, find.byType(NlSwitch)).color,
          NlColors.dark.line2);
      await tester.tap(find.byType(NlSwitch));
      await tester.pumpAndSettle();
      expect(value, isTrue);
      expect(_decorationOf(tester, find.byType(NlSwitch)).color,
          NlColors.dark.accent);
      final node = tester.getSemantics(find.bySemanticsLabel('Force relay'));
      expect(node.hasFlag(SemanticsFlag.isToggled), isTrue);
      semantics.dispose();
    });

    testWidgets('text field labels itself, rings on focus and reveals',
        (tester) async {
      final controller = TextEditingController(text: 'secret');
      addTearDown(controller.dispose);
      await tester.pumpWidget(_host(SizedBox(
          width: 320,
          child: NlTextField(
              controller: controller,
              label: 'Password',
              helper: 'Eight characters or more',
              obscure: true,
              revealLabel: 'Show',
              hideLabel: 'Hide',
              fieldKey: const Key('pw')))));
      expect(find.text('Password'), findsOneWidget);
      expect(find.text('Eight characters or more'), findsOneWidget);
      EditableText editable() =>
          tester.widget<EditableText>(find.byType(EditableText));
      expect(editable().obscureText, isTrue);
      BoxDecoration box() => _decorationOf(tester, find.byType(NlTextField));
      expect(box().border, Border.all(color: NlColors.dark.line2));
      await tester.tap(find.byKey(const Key('pw')));
      await tester.pumpAndSettle();
      expect(box().border, Border.all(color: NlColors.dark.accent));
      expect(box().boxShadow, isNotEmpty);
      await tester.tap(find.byTooltip('Show'));
      await tester.pump();
      expect(editable().obscureText, isFalse);
      expect(find.byTooltip('Hide'), findsOneWidget);
    });

    testWidgets('text field error replaces the helper', (tester) async {
      await tester.pumpWidget(_host(const SizedBox(
          width: 320,
          child: NlTextField(
              label: 'ID', helper: 'Nine digits', error: 'Not a NikoDesk ID'))));
      expect(find.text('Nine digits'), findsNothing);
      final error = tester.widget<Text>(find.text('Not a NikoDesk ID'));
      expect(error.style!.color, NlColors.dark.dangerText);
      expect(_decorationOf(tester, find.byType(NlTextField)).border,
          Border.all(color: NlColors.dark.danger));
    });

    testWidgets('slider track runs to the thumb edge, not the halo',
        (tester) async {
      await tester.pumpWidget(_host(SizedBox(
          width: 300, child: Slider(value: .5, onChanged: (_) {}))));
      final context = tester.element(find.byType(Slider));
      final theme = SliderTheme.of(context);
      final rect = theme.trackShape!.getPreferredRect(
          parentBox: tester.renderObject<RenderBox>(find.byType(Slider)),
          sliderTheme: theme.copyWith(
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 10)),
          isEnabled: true);
      expect(rect.left, 10);
      expect(rect.width, 280);
      expect(rect.height, 4);
    });

    testWidgets('field labels keep one line height whatever the script',
        (tester) async {
      await tester.pumpWidget(_host(const Row(children: [
        Expanded(child: NlTextField(label: '局域网广播地址')),
        Expanded(
            child: NlSelect<int>(
                label: 'UDP 端口',
                placeholder: '9',
                value: null,
                options: [],
                onChanged: null)),
      ])));
      for (final label in ['局域网广播地址', 'UDP 端口']) {
        expect(tester.widget<Text>(find.text(label)).strutStyle?.forceStrutHeight,
            isTrue);
      }
    });

    testWidgets('search field clears itself', (tester) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      final changes = <String>[];
      await tester.pumpWidget(_host(SizedBox(
          width: 320,
          child: NlSearchField(
              controller: controller,
              hint: 'Search devices',
              clearLabel: 'Clear',
              onChanged: changes.add))));
      expect(find.text('Search devices'), findsOneWidget);
      expect(find.byTooltip('Clear'), findsNothing);
      await tester.enterText(find.byType(TextField), 'office');
      await tester.pumpAndSettle();
      expect(changes.last, 'office');
      await tester.tap(find.byTooltip('Clear'));
      await tester.pumpAndSettle();
      expect(controller.text, isEmpty);
      expect(changes.last, isEmpty);
    });

    testWidgets('panel elevation maps to ring, then shadows', (tester) async {
      await tester.pumpWidget(_host(const Column(mainAxisSize: MainAxisSize.min, children: [
        NlPanel(key: Key('one'), child: Text('1')),
        NlPanel(key: Key('three'), elevation: 3, child: Text('3')),
      ]), brightness: Brightness.light));
      BoxDecoration of(String key) => tester
          .widget<Container>(find.descendant(
              of: find.byKey(Key(key)), matching: find.byType(Container)))
          .decoration! as BoxDecoration;
      final nl = NlColors.light;
      expect(of('one').color, nl.surface);
      expect(of('one').border, Border.all(color: nl.ring));
      expect(of('one').borderRadius, BorderRadius.circular(NlRadius.r3));
      expect(of('one').boxShadow, nl.shadow1);
      expect(of('three').color, nl.overlay);
      expect(of('three').border, isNull);
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
                chevron: true,
                onTap: () => taps++),
            const NlListRow(key: Key('dense'), dense: true, title: 'Screen'),
          ]))));
      expect(find.text('desk.example.net'), findsOneWidget);
      expect(find.byIcon(NlIcons.chevronRight), findsOneWidget);
      expect(tester.getSize(find.byKey(const Key('first'))).height,
          greaterThanOrEqualTo(44));
      expect(tester.getSize(find.byKey(const Key('dense'))).height, 32);
      Finder hairline(String key) => find.descendant(
          of: find.byKey(Key(key)),
          matching: find.byWidgetPredicate(
              (w) => w is Container && w.color == NlColors.dark.line));
      expect(hairline('first'), findsNothing);
      expect(hairline('dense'), findsOneWidget);
      await tester.tap(find.text('Private server'));
      expect(taps, 1);
    });

    testWidgets('kbd uses the UI face; state labels stay in sentence case',
        (tester) async {
      await tester.pumpWidget(_host(const Column(mainAxisSize: MainAxisSize.min, children: [
        NlKbd('⌘K'),
        NlMonoLabel('This computer'),
        NlMonoLabel('ready', tone: NlTone.ok, leading: NlLed(NlLedState.ok)),
        NlSectionLabel('Recent sessions'),
      ])));
      expect(tester.widget<Text>(find.text('⌘K')).style!.fontFamily, NlType.ui);
      // Tracked capitals read as generated; labels keep their own case.
      final label = tester.widget<Text>(find.text('This computer'));
      expect(label.style!.fontFamily, NlType.ui);
      expect(label.style!.color, NlColors.dark.fg3);
      expect(tester.widget<Text>(find.text('ready')).style!.color,
          NlColors.dark.okText);
      final section = tester.widget<Text>(find.text('Recent sessions'));
      expect(section.style!.color, NlColors.dark.fg3);
      expect(section.style!.fontWeight, FontWeight.w500);
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

    testWidgets('device glyph shows kind and presence', (tester) async {
      await tester.pumpWidget(_host(const Row(mainAxisSize: MainAxisSize.min, children: [
        NlDeviceGlyph(key: Key('on'), id: '111', kind: NlDeviceKind.laptop, online: true),
        NlDeviceGlyph(key: Key('off'), id: '111', online: false),
        NlDeviceGlyph(key: Key('unknown'), id: '111'),
      ])));
      expect(find.byIcon(NlIcons.laptop), findsOneWidget);
      Finder dot(String key) => find.descendant(
          of: find.byKey(Key(key)),
          matching: find.byWidgetPredicate((w) =>
              w is Container &&
              (w.decoration as BoxDecoration?)?.shape == BoxShape.circle));
      expect(dot('on'), findsOneWidget);
      expect(dot('off'), findsOneWidget);
      expect(dot('unknown'), findsNothing);
    });

    testWidgets('empty state offers one action', (tester) async {
      var taps = 0;
      await tester.pumpWidget(_host(NlEmptyState(
          icon: NlIcons.monitor,
          title: 'No devices yet',
          message: 'Connect once and the device appears here.',
          action: NlButton(onPressed: () => taps++, label: 'Connect'))));
      expect(find.text('No devices yet'), findsOneWidget);
      await tester.tap(find.text('Connect'));
      expect(taps, 1);
    });
  });

  group('surfaces', () {
    testWidgets('menu opens under its anchor, follows the keys and closes',
        (tester) async {
      final picked = <String>[];
      await tester.pumpWidget(_host(Builder(
          builder: (context) => NlButton.ghost(
              label: 'More',
              onPressed: () => showNlMenu(context,
                      anchor: nlAnchorOf(context),
                      entries: [
                        const NlMenuHeader('Device'),
                        NlMenuItem(
                            label: 'Rename',
                            icon: NlIcons.pencil,
                            shortcut: '⌘R',
                            onSelected: () => picked.add('rename')),
                        const NlMenuItem(label: 'Pin', enabled: false),
                        const NlMenuDivider(),
                        NlMenuItem(
                            label: 'Remove',
                            danger: true,
                            onSelected: () => picked.add('remove')),
                      ])))));
      await tester.tap(find.text('More'));
      await tester.pumpAndSettle();
      expect(find.text('Rename'), findsOneWidget);
      expect(find.text('Device'), findsOneWidget);
      expect(tester.getTopLeft(find.text('Rename')).dy,
          greaterThan(tester.getBottomLeft(find.text('More')).dy));
      expect(tester.widget<Text>(find.text('Remove')).style!.color,
          NlColors.dark.dangerText);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(picked, ['rename']);
      expect(find.text('Rename'), findsNothing);

      await tester.tap(find.text('More'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Pin'), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(find.text('Rename'), findsOneWidget);
      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();
      expect(picked, ['rename', 'remove']);

      await tester.tap(find.text('More'));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('Rename'), findsNothing);
      expect(picked, ['rename', 'remove']);
    });

    testWidgets('confirm resolves true only on the confirm button',
        (tester) async {
      final context = await _context(tester);
      Future<bool> ask() => nlConfirm(context,
          title: 'Forget this device?',
          message: 'Its saved password is removed too.',
          confirm: 'Forget',
          cancel: 'Cancel',
          destructive: true,
          icon: NlIcons.trash2);

      final cancelled = ask();
      await tester.pumpAndSettle();
      expect(find.text('Forget this device?'), findsOneWidget);
      expect(_decorationOf(tester, find.widgetWithText(NlButton, 'Forget')).color,
          NlColors.dark.dangerFill);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(await cancelled, isFalse);

      final confirmed = ask();
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(await confirmed, isTrue);

      final dismissed = ask();
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(await dismissed, isFalse);
      expect(find.text('Forget this device?'), findsNothing);
    });

    testWidgets('toast rises in, gives way to the next and leaves',
        (tester) async {
      final context = await _context(tester);
      expect(NlToast.show(context, 'ID copied', tone: NlToastTone.ok), isTrue);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('ID copied'), findsOneWidget);
      expect(find.byIcon(NlIcons.circleCheck), findsOneWidget);

      NlToast.show(context, 'Saved');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Saved'), findsOneWidget);
      expect(find.text('ID copied'), findsNothing);

      await tester.pump(const Duration(seconds: 7));
      await tester.pumpAndSettle();
      expect(find.text('Saved'), findsNothing);
    });

    testWidgets('stock toasts take the capsule on the Nightline theme',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
          navigatorKey: globalKey,
          theme: nightlineTheme(Brightness.light),
          home: const Scaffold()));
      showToast('Copied to clipboard');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      final text = tester.widget<Text>(find.text('Copied to clipboard'));
      expect(text.style?.fontFamily, NlType.ui);
      // A second toast replaces the first, as NlToast does.
      showToast('Saved');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Copied to clipboard'), findsNothing);
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      expect(find.text('Saved'), findsNothing);
    }, skip: !const bool.fromEnvironment('NIKODESK'));

    testWidgets('sheet is a bottom sheet on phones and a dialog elsewhere',
        (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      var context = await _context(tester);
      showNlSheet<void>(
          context: context, builder: (_) => const Text('Temporary access'));
      await tester.pumpAndSettle();
      expect(find.text('Temporary access'), findsOneWidget);
      expect(tester.getBottomLeft(find.text('Temporary access')).dy,
          greaterThan(844 / 2));
      Navigator.of(context).pop();
      await tester.pumpAndSettle();

      tester.view.physicalSize = const Size(1440, 900);
      context = await _context(tester);
      showNlSheet<void>(
          context: context, builder: (_) => const Text('Temporary access'));
      await tester.pumpAndSettle();
      final centre = tester.getCenter(find.text('Temporary access'));
      expect(centre.dy, lessThan(900 * .75));
      Navigator.of(context).pop();
      await tester.pumpAndSettle();
    });

    testWidgets('command palette filters as you type and runs on Enter',
        (tester) async {
      final context = await _context(tester);
      final ran = <String>[];
      final commands = [
        NlCommand(title: 'New session', run: () => ran.add('new')),
        NlCommand(title: 'Settings', run: () => ran.add('settings')),
        NlCommand(
            title: 'Office PC',
            subtitle: '123 456 789',
            keywords: const ['work'],
            run: () => ran.add('office')),
      ];
      final first = showNlCommandPalette(context,
          commands: commands, hint: 'Search', empty: 'No matches');
      await tester.pumpAndSettle();
      expect(find.text('Search'), findsOneWidget);
      // A prefix match outranks a later word.
      await tester.enterText(
          find.byKey(const Key('nikodesk-command-palette-query')), 'se');
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      await first;
      expect(ran, ['settings']);

      final second = showNlCommandPalette(context,
          commands: commands, hint: 'Search', empty: 'No matches');
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const Key('nikodesk-command-palette-query')), 'work');
      await tester.pump();
      expect(find.textContaining('Office PC', findRichText: true), findsOneWidget);
      expect(find.textContaining('Settings', findRichText: true), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      await second;
      expect(ran, ['settings', 'office']);

      final third = showNlCommandPalette(context,
          commands: commands, hint: 'Search', empty: 'No matches');
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const Key('nikodesk-command-palette-query')), 'zzz');
      await tester.pump();
      expect(find.text('No matches'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await third;
      expect(ran, ['settings', 'office']);
    });

    test('command scores rank prefix, word, substring, then details', () {
      final command = NlCommand(
          title: 'Connect to Office PC',
          subtitle: '123 456 789',
          keywords: const ['work'],
          run: () {});
      expect(command.score(''), 1);
      expect(command.score('conn'), 400);
      expect(command.score('off'), 300);
      expect(command.score('ffice'), 200);
      expect(command.score('456'), 100);
      expect(command.score('work'), 100);
      expect(command.score('zzz'), 0);
    });
  });

  group('navigation', () {
    testWidgets('sidebar items mark the selection', (tester) async {
      final semantics = tester.ensureSemantics();
      var taps = 0;
      await tester.pumpWidget(_host(SizedBox(
          height: 400,
          child: NlSidebar(children: [
            NlSidebarSection(title: 'Library', children: [
              NlSidebarItem(
                  icon: NlIcons.monitor,
                  label: 'Devices',
                  count: '12',
                  selected: true,
                  onTap: () => taps++),
              NlSidebarItem(
                  icon: NlIcons.history, label: 'History', onTap: () {}),
            ]),
          ]))));
      expect(find.text('Library'), findsOneWidget);
      expect(find.text('12'), findsOneWidget);
      final devices = tester.getSemantics(find.text('Devices'));
      expect(devices.hasFlag(SemanticsFlag.isSelected), isTrue);
      expect(tester.widget<Text>(find.text('Devices')).style!.fontWeight,
          FontWeight.w600);
      expect(tester.widget<Text>(find.text('History')).style!.fontWeight,
          FontWeight.w400);
      expect(tester.getSize(find.byType(NlSidebarItem).first).height, 38);
      await tester.tap(find.text('Devices'));
      expect(taps, 1);
      semantics.dispose();
    });

    testWidgets('tab bar switches tabs', (tester) async {
      var index = 0;
      await tester.pumpWidget(StatefulBuilder(
          builder: (context, setState) => _host(
              NlTabBar(
                  items: const [
                    NlTabItem(icon: NlIcons.monitor, label: 'Devices'),
                    NlTabItem(icon: NlIcons.settings, label: 'Settings'),
                  ],
                  index: index,
                  onChanged: (next) => setState(() => index = next)),
              platform: TargetPlatform.iOS)));
      expect(tester.widget<Text>(find.text('Devices')).style!.color,
          NlColors.dark.accentText);
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();
      expect(index, 1);
      expect(tester.widget<Text>(find.text('Settings')).style!.color,
          NlColors.dark.accentText);
    });

    testWidgets('side panel slides without reflowing its content',
        (tester) async {
      var open = false;
      late StateSetter set;
      await tester.pumpWidget(StatefulBuilder(builder: (context, setState) {
        set = setState;
        return _host(SizedBox(
            height: 200,
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              NlSidePanel(
                  open: open,
                  width: 300,
                  child: const SizedBox(key: Key('content'), width: 300)),
            ])));
      }));
      expect(find.byKey(const Key('content')), findsNothing);
      set(() => open = true);
      await tester.pump();
      await tester.pump(NlMotion.slow ~/ 2);
      expect(tester.getSize(find.byType(NlSidePanel)).width,
          allOf(greaterThan(0), lessThan(300)));
      expect(tester.getSize(find.byKey(const Key('content'))).width, 300);
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byType(NlSidePanel)).width, 300);
      set(() => open = false);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('content')), findsNothing);
    });
  });
}
