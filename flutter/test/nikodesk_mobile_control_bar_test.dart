import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/nikodesk/mobile_control_bar.dart';
import 'package:flutter_hbb/nikodesk/theme.dart';

void main() {
  // Layout/action fixtures only; no remote session or native input is started.
  for (final size in [const Size(320, 700), const Size(844, 390)]) {
    for (final brightness in [Brightness.light, Brightness.dark]) {
      testWidgets('mobile controls keep actions reachable at $size/$brightness', (tester) async {
        await tester.binding.setSurfaceSize(size);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final semantics = tester.ensureSemantics();
        var ended = 0;
        var more = 0;
        await tester.pumpWidget(MaterialApp(
          theme: nikoTheme(brightness),
          builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(2)), child: child!),
          home: Scaffold(bottomNavigationBar: BottomAppBar(child: NikoMobileControlBar(
            actions: Row(children: [
              for (var i = 0; i < 4; i++)
                IconButton(tooltip: 'Action $i', icon: const Icon(Icons.tv), onPressed: () {}),
              IconButton(tooltip: 'More actions', icon: const Icon(Icons.more_vert), onPressed: () => more++),
            ]),
            collapse: IconButton(tooltip: 'Hide controls', icon: const Icon(Icons.expand_more), onPressed: () {}),
            endSession: IconButton(tooltip: 'End session', icon: const Icon(Icons.close), onPressed: () => ended++),
          ))),
        ));
        await tester.pumpAndSettle();
        final end = find.widgetWithIcon(IconButton, Icons.close);
        final initialEnd = tester.getRect(end);
        expect(tester.getSize(end).width, greaterThanOrEqualTo(48));
        expect(tester.getSize(end).height, greaterThanOrEqualTo(48));
        expect(tester.getSemantics(end).hasFlag(SemanticsFlag.isButton), isTrue);
        expect(end.hitTestable(), findsOneWidget);
        final moreButton = find.widgetWithIcon(IconButton, Icons.more_vert);
        if (size.width == 320) {
          expect(moreButton.hitTestable(), findsNothing);
          await tester.drag(find.byKey(const Key('nikodesk-mobile-control-scroll')), const Offset(-220, 0));
          await tester.pumpAndSettle();
          expect(tester.getRect(end), initialEnd);
        }
        expect(moreButton.hitTestable(), findsOneWidget);
        await tester.tap(moreButton);
        await tester.tap(end);
        expect(more, 1);
        expect(ended, 1);
        expect(tester.takeException(), isNull);
        semantics.dispose();
      });
    }
  }
}
