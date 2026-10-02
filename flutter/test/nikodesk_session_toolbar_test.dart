import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/nikodesk/session_toolbar.dart';
import 'package:flutter_hbb/nikodesk/theme.dart';
import 'package:flutter_hbb/nikodesk/ui.dart';

void main() {
  // Layout, native Material menus and action fixtures only; no FFI session starts.
  for (final axis in Axis.values) {
    for (final brightness in Brightness.values) {
      testWidgets('docked toolbar keeps end-session fixed for $axis/$brightness', (tester) async {
        await tester.binding.setSurfaceSize(const Size(320, 600));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final semantics = tester.ensureSemantics();
        var ended = 0;
        var more = 0;
        await tester.pumpWidget(MaterialApp(
          theme: nikoTheme(brightness),
          builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(2)), child: child!),
          home: Scaffold(body: Center(child: SizedBox(
            width: axis == Axis.horizontal ? 280 : null,
            height: axis == Axis.vertical ? 180 : null,
            child: Material(child: NikoSessionToolbar(direction: axis,
              actions: [
                for (var i = 0; i < 10; i++) NikoToolbarButton(
                  label: 'Action $i', icon: const Icon(Icons.tv), onPressed: () {}),
                NikoToolbarButton(key: const Key('more'), label: 'More actions',
                    icon: const Icon(Icons.more_vert), onPressed: () => more++),
              ],
              endSession: NikoToolbarButton(key: const Key('end'), label: 'End session',
                  tone: NikoToolbarTone.danger, icon: const Icon(Icons.close), onPressed: () => ended++),
            )),
          ))),
        ));
        await tester.pumpAndSettle();
        final end = find.byKey(const Key('end'));
        final before = tester.getRect(end);
        expect(end.hitTestable(), findsOneWidget);
        expect(tester.getSemantics(find.bySemanticsLabel('End session')).getSemanticsData()
            .hasFlag(SemanticsFlag.isButton), isTrue);
        expect(find.byKey(const Key('more')).hitTestable(), findsNothing);
        await tester.drag(find.byKey(const Key('nikodesk-session-toolbar-scroll')),
            axis == Axis.horizontal ? const Offset(-1000, 0) : const Offset(0, -1000));
        await tester.pumpAndSettle();
        expect(tester.getRect(end), before);
        expect(find.byKey(const Key('more')).hitTestable(), findsOneWidget);
        await tester.tap(find.byKey(const Key('more')));
        await tester.tap(end);
        await tester.pumpAndSettle();
        expect(more, 1);
        expect(ended, 1);
        expect(tester.takeException(), isNull);
        semantics.dispose();
      });
    }
  }

  testWidgets('pin state, button name and keyboard action are exposed', (tester) async {
    NikoLanguage.usePreference('en');
    addTearDown(() => NikoLanguage.english = false);
    final semantics = tester.ensureSemantics();
    var pinned = false;
    await tester.pumpWidget(MaterialApp(theme: nikoTheme(Brightness.dark),
      home: Scaffold(body: StatefulBuilder(builder: (context, setState) => NikoToolbarButton(
        key: const Key('pin'), label: nikoText('固定工具栏', 'Pin toolbar'), selected: pinned,
        tone: pinned ? NikoToolbarTone.action : NikoToolbarTone.inactive,
        icon: const Icon(Icons.push_pin), onPressed: () => setState(() => pinned = !pinned),
      ))),
    ));
    await tester.pumpAndSettle();
    final pinSemantics = find.bySemanticsLabel('Pin toolbar');
    expect(tester.getSemantics(pinSemantics).getSemanticsData().label, 'Pin toolbar');
    expect(tester.getSemantics(pinSemantics).getSemanticsData().hasFlag(SemanticsFlag.isToggled), isFalse);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(pinned, isTrue);
    expect(tester.getSemantics(pinSemantics).getSemanticsData().hasFlag(SemanticsFlag.isToggled), isTrue);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('toolbar menu opens and invokes its native Material action', (tester) async {
    var opened = 0;
    await tester.pumpWidget(MaterialApp(theme: nikoTheme(Brightness.light),
      home: Scaffold(body: Center(child: NikoToolbarMenu(
        key: const Key('clipboard'), label: 'Clipboard', icon: const Icon(Icons.content_paste),
        children: [MenuItemButton(onPressed: () => opened++, child: const Text('Sync text clipboard'))],
      ))),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('clipboard')));
    await tester.pumpAndSettle();
    expect(find.text('Sync text clipboard').hitTestable(), findsOneWidget);
    await tester.tap(find.text('Sync text clipboard'));
    await tester.pumpAndSettle();
    expect(opened, 1);
    expect(tester.takeException(), isNull);
  });

  for (final brightness in Brightness.values) {
    testWidgets('toolbar icon contrast for $brightness', (tester) async {
      await tester.pumpWidget(MaterialApp(theme: nikoTheme(brightness),
        home: Scaffold(body: Column(children: [
          for (final tone in NikoToolbarTone.values) NikoToolbarButton(
              icon: const Icon(Icons.tv), label: tone.name, tone: tone, onPressed: () {}),
        ])),
      ));
      await tester.pumpAndSettle();
      expect(find.byType(IconButton), findsNWidgets(NikoToolbarTone.values.length));
      for (final button in tester.widgetList<IconButton>(find.byType(IconButton))) {
        final foreground = button.style!.foregroundColor!.resolve({})!.computeLuminance();
        final background = button.style!.backgroundColor!.resolve({})!.computeLuminance();
        final ratio = ((foreground > background ? foreground : background) + .05) /
            ((foreground < background ? foreground : background) + .05);
        expect(ratio, greaterThanOrEqualTo(4.5));
      }
      expect(tester.takeException(), isNull);
    });
  }
}
