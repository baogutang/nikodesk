import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/nikodesk/mobile_control_bar.dart';
import 'package:flutter_hbb/nikodesk/theme.dart';

void main() {
  // Layout/action fixtures only; no remote session or native input is started.
  Widget dock(
          {required int actions,
          VoidCallback? onMore,
          VoidCallback? onEnd,
          EdgeInsets? padding,
          double textScale = 1,
          Brightness brightness = Brightness.dark}) =>
      MaterialApp(
        theme: nikoTheme(brightness).copyWith(platform: TargetPlatform.iOS),
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!),
        home: Scaffold(
            bottomNavigationBar: BottomAppBar(
                padding: padding,
                child: NikoMobileControlBar(
                  actions: Row(children: [
                    for (var i = 0; i < actions; i++)
                      IconButton(
                          tooltip: 'Action $i',
                          icon: const Icon(Icons.tv),
                          onPressed: () {}),
                  ]),
                  more: IconButton(
                      tooltip: 'More actions',
                      icon: const Icon(Icons.more_horiz),
                      onPressed: onMore),
                  collapse: IconButton(
                      tooltip: 'Hide controls',
                      icon: const Icon(Icons.expand_more),
                      onPressed: () {}),
                  endSession: IconButton(
                      tooltip: 'End session',
                      icon: const Icon(Icons.close),
                      onPressed: onEnd),
                ))),
      );

  for (final size in [const Size(320, 700), const Size(844, 390)]) {
    for (final brightness in [Brightness.light, Brightness.dark]) {
      testWidgets(
          'mobile controls keep actions reachable at $size/$brightness',
          (tester) async {
        await tester.binding.setSurfaceSize(size);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final semantics = tester.ensureSemantics();
        var ended = 0;
        var more = 0;
        await tester.pumpWidget(dock(
            actions: 5,
            onMore: () => more++,
            onEnd: () => ended++,
            textScale: 2,
            brightness: brightness));
        await tester.pumpAndSettle();
        final end = find.widgetWithIcon(IconButton, Icons.close);
        final initialEnd = tester.getRect(end);
        expect(tester.getSize(end), const Size.square(44));
        expect(tester.getSemantics(end).hasFlag(SemanticsFlag.isButton),
            isTrue);
        expect(end.hitTestable(), findsOneWidget);
        // More stays at the end with collapsing and ending the session.
        final moreButton = find.widgetWithIcon(IconButton, Icons.more_horiz);
        expect(moreButton.hitTestable(), findsOneWidget);
        final last = find.byTooltip('Action 4');
        final fade = find.byKey(const Key('nikodesk-mobile-control-fade'));
        if (size.width == 320) {
          expect(last.hitTestable(), findsNothing);
          expect(fade, findsOneWidget);
          await tester.drag(
              find.byKey(const Key('nikodesk-mobile-control-scroll')),
              const Offset(-220, 0));
          await tester.pumpAndSettle();
          expect(tester.getRect(end), initialEnd);
          expect(last.hitTestable(), findsOneWidget);
        } else {
          expect(fade, findsNothing);
        }
        await tester.tap(moreButton);
        await tester.tap(end);
        expect(more, 1);
        expect(ended, 1);
        expect(tester.takeException(), isNull);
        semantics.dispose();
      });
    }
  }

  testWidgets('a 390 pt phone shows the whole session dock', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(dock(
        actions: 5, padding: const EdgeInsets.symmetric(horizontal: 8)));
    await tester.pumpAndSettle();
    for (var i = 0; i < 5; i++) {
      expect(find.byTooltip('Action $i').hitTestable(), findsOneWidget);
    }
    expect(find.byKey(const Key('nikodesk-mobile-control-fade')), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
