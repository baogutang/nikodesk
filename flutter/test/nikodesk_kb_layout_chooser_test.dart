import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_hbb/desktop/widgets/kb_layout_type_chooser.dart';
import 'package:flutter_hbb/nikodesk/kb_layout_chooser.dart';
import 'package:flutter_hbb/nikodesk/nightline.dart';
import 'package:flutter_hbb/nikodesk/ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

// The local keyboard type chooser: the Nightline cards in the NikoDesk build,
// the stock drawings and radios otherwise.

const _nikodesk = bool.fromEnvironment('NIKODESK');

Widget _app(Widget body, {ThemeData? theme, double textScale = 1}) =>
    MaterialApp(
        theme: theme ?? nightlineTheme(Brightness.light),
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!),
        home: Scaffold(body: Center(child: body)));

void main() {
  setUp(() => NikoLanguage.english = true);
  tearDown(() => NikoLanguage.english = false);

  testWidgets('a card saves its type; a refused save keeps the old one',
      (tester) async {
    final chosen = ''.obs;
    final asked = <String>[];
    var accept = true;
    await tester.pumpWidget(_app(NikoKbLayoutChooser(
        chosenType: chosen,
        choose: (type) async {
          asked.add(type);
          return accept;
        })));
    await tester.tap(find.byKey(const Key('niko-kb-layout-Not ISO')));
    await tester.pump();
    expect(asked, ['Not ISO']);
    expect(chosen.value, 'Not ISO');
    final semantics = tester.ensureSemantics();
    // Read once: the card's own text, not a label on top of it.
    final card = tester
        .getSemantics(find.byKey(const Key('niko-kb-layout-Not ISO')))
        .getSemanticsData();
    expect(
        card.label, 'Not ISO\nA long left Shift with no extra key beside it.');
    expect(card.hasFlag(SemanticsFlag.isButton), isTrue);
    expect(card.hasFlag(SemanticsFlag.isSelected), isTrue);
    semantics.dispose();
    accept = false;
    await tester.tap(find.byKey(const Key('niko-kb-layout-ISO')));
    await tester.pump();
    expect(asked, ['Not ISO', 'ISO']);
    expect(chosen.value, 'Not ISO');
    expect(tester.takeException(), isNull);
  });

  testWidgets('the cards keep their text at 200% in a dialog-wide column',
      (tester) async {
    for (final brightness in Brightness.values) {
      await tester.pumpWidget(_app(
          NikoKbLayoutChooser(chosenType: 'ISO'.obs, choose: (_) async => true),
          theme: nightlineTheme(brightness),
          textScale: 2));
      expect(tester.takeException(), isNull);
      expect(find.text('ISO'), findsOneWidget);
    }
  });

  testWidgets('the stock chooser shows the cards only in the NikoDesk build',
      (tester) async {
    Widget stock() => KBLayoutTypeChooser(
        chosenType: 'ISO'.obs,
        width: 360,
        // Room for the stock column in the test font.
        height: 260,
        dividerWidth: 4,
        cb: (_) async => true);
    await tester.pumpWidget(_app(stock()));
    expect(find.byType(NikoKbLayoutChooser),
        _nikodesk ? findsOneWidget : findsNothing);
    // A fresh tree, so the theme does not animate between the two.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(_app(stock(), theme: ThemeData.light()));
    expect(find.byType(NikoKbLayoutChooser), findsNothing);
    expect(find.byType(Radio<String>), findsNWidgets(2));
  });
}
