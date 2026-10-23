import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/nikodesk/alert_dialog.dart';
import 'package:flutter_hbb/nikodesk/nightline.dart';
import 'package:flutter_hbb/nikodesk/theme.dart';
import 'package:flutter_hbb/nikodesk/ui.dart';

void main() {
  tearDown(() => NikoLanguage.english = false);

  // Layout fixtures only; no dialog manager or session is involved.
  Future<void> pump(WidgetTester tester, Widget child,
      {Size size = const Size(1100, 760), double textScale = 1}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
        theme: nikoTheme(Brightness.light),
        builder: (context, app) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(textScale)),
            child: app!),
        home: Scaffold(body: Center(child: child))));
    await tester.pumpAndSettle();
  }

  Widget dialog(Widget content, {Widget? title}) => NikoAlertDialog(
          title: title,
          content: content,
          constraints: const BoxConstraints(maxWidth: 500),
          actions: [
            NikoDialogButton(
                label: nikoText('取消', 'Cancel'),
                onPressed: () {},
                primary: false),
            NikoDialogButton(
                label: nikoText('确定', 'OK'), onPressed: () {}, primary: true),
          ]);

  Rect button(WidgetTester tester, String label) =>
      tester.getRect(find.widgetWithText(NikoDialogButton, label));

  testWidgets('a wide dialog ends its row with the main action',
      (tester) async {
    NikoLanguage.english = true;
    await pump(
        tester,
        dialog(const NikoDialogText('Its saved password is removed too.'),
            title: const Text('Delete this device?')));
    final ok = button(tester, 'OK'), cancel = button(tester, 'Cancel');
    expect(ok.center.dy, cancel.center.dy);
    expect(ok.left, greaterThan(cancel.right));
  });

  testWidgets('a phone dialog stacks its actions, main one first',
      (tester) async {
    NikoLanguage.english = true;
    await pump(
        tester,
        dialog(const NikoDialogText('Its saved password is removed too.'),
            title: const Text('Delete this device?')),
        size: const Size(390, 844));
    final ok = button(tester, 'OK'), cancel = button(tester, 'Cancel');
    expect(ok.bottom, lessThan(cancel.top));
    expect(ok.left, cancel.left);
    expect(ok.width, cancel.width);
  });

  test('Cancel never leads', () {
    expect(nikoDialogPrimary('OK', isOutline: false), isTrue);
    expect(nikoDialogPrimary('Cancel', isOutline: false), isFalse);
    expect(nikoDialogPrimary('Retry', isOutline: true), isFalse);
  });

  testWidgets('a message box shows its type in icon and tone', (tester) async {
    for (final (type, icon, tone) in [
      ('error', NlIcons.circleX, (NlColors nl) => nl.danger),
      ('re-input-password', NlIcons.circleX, (NlColors nl) => nl.danger),
      ('success', NlIcons.circleCheck, (NlColors nl) => nl.ok),
      ('wait-uac', NlIcons.clock, (NlColors nl) => nl.warn),
      ('on-uac', NlIcons.shield, (NlColors nl) => nl.accent),
      ('custom-nocancel-info', NlIcons.info, (NlColors nl) => nl.accent),
    ]) {
      await pump(
          tester, NikoMsgboxContent(type: type, title: 'Title', text: 'Text'));
      final tile = tester.widget<NlIconTile>(find.byType(NlIconTile));
      expect(tile.icon, icon, reason: type);
      expect(tile.color, tone(NlColors.of(tester.element(find.text('Title')))),
          reason: type);
    }
    await pump(
        tester,
        const NikoMsgboxContent(
            type: 'input-password', title: 'Title', text: 'Text'));
    expect(find.byType(NlIconTile), findsNothing);
  });

  testWidgets('web addresses in dialog text become links', (tester) async {
    await pump(tester,
        const NikoDialogText('Read https://example.com/help. Then retry.'));
    final spans = tester
        .widget<SelectableText>(find.byType(SelectableText))
        .textSpan!
        .children!
        .cast<TextSpan>();
    expect(spans.map((s) => s.text),
        ['Read ', 'https://example.com/help.', ' Then retry.']);
    expect(spans[1].recognizer, isA<TapGestureRecognizer>());
    expect(spans[0].recognizer, isNull);

    await pump(tester, const NikoDialogText('No address here.'));
    expect(tester.widget<SelectableText>(find.byType(SelectableText)).data,
        'No address here.');
  });

  for (final english in [false, true]) {
    testWidgets('a message box fits 320px at 200% text ($english)',
        (tester) async {
      NikoLanguage.english = english;
      await pump(
          tester,
          dialog(NikoMsgboxContent(
              type: 'error',
              title: nikoText('连接错误', 'Connection error'),
              text: nikoText('无法通过中继服务器连接，请检查网络后重试。',
                  'Failed to connect via the relay server. Check the network and try again.'))),
          size: const Size(320, 640),
          textScale: 2);
      expect(tester.takeException(), isNull);
    });
  }
}
