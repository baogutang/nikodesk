import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/models/native_model.dart';
import 'package:flutter_hbb/nikodesk/alert_dialog.dart';
import 'package:flutter_hbb/nikodesk/file_conflict_dialog.dart';
import 'package:flutter_hbb/nikodesk/file_pane.dart';
import 'package:flutter_hbb/nikodesk/nightline.dart';
import 'package:flutter_hbb/nikodesk/ui.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/nikodesk_fake_bridge.dart';
import 'support/nikodesk_file_window.dart';

// The desktop file window on Nightline, built from the real upstream panes
// and NikoDesk task list over an in-memory bridge.
void main() {
  const nikodesk = bool.fromEnvironment('NIKODESK');

  setUp(() async {
    NikoLanguage.english = true;
    PlatformFFI.instance.ffiBindForTesting = NikoFakeBridge();
    await initGlobalFFI();
  });
  tearDown(() => NikoLanguage.english = false);

  Future<void> load(WidgetTester tester, Size size,
      {Brightness brightness = Brightness.dark,
      bool withJobs = true,
      TargetPlatform? platform}) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
        theme: nightlineTheme(brightness).copyWith(platform: platform),
        home: NikoTestFileWindow(withJobs: withJobs)));
    await tester.pumpAndSettle();
  }

  testWidgets('a new window keeps both panes and every pane tool in view',
      (tester) async {
    // 1280 x 720 is the size a new file transfer window opens at.
    await load(tester, const Size(1280, 720));
    expect(find.byKey(const Key('niko-file-pane-0')), findsNothing);
    expect(find.text('Transfers'), findsOneWidget);
    for (final tool in ['Refresh File', 'Search', 'More']) {
      expect(find.byTooltip(tool).hitTestable(), findsNWidgets(2), reason: tool);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('a narrow window shows one pane at a time and counts tasks',
      (tester) async {
    await load(tester, const Size(900, 640));
    expect(find.text('Transfers').hitTestable(), findsNothing);
    final tasks = find.byKey(const Key('niko-file-pane-2'));
    expect(find.descendant(of: tasks, matching: find.text('3')), findsOneWidget);
    await tester.tap(tasks);
    await tester.pumpAndSettle();
    expect(find.text('Transfers').hitTestable(), findsOneWidget);
    expect(find.text('1 active · 3'), findsOneWidget);
  });

  testWidgets('task cards keep their actions and show readable sizes',
      (tester) async {
    await load(tester, const Size(1440, 900));
    expect(find.byKey(const Key('niko-file-cancel-1')), findsOneWidget);
    expect(find.byKey(const Key('niko-file-resend-3')), findsOneWidget);
    expect(find.byKey(const Key('niko-file-remove-2')), findsOneWidget);
    expect(find.byKey(const Key('niko-file-remove-1')), findsNothing);
    expect(find.byTooltip('Remove record'), findsNWidgets(2));
    expect(find.text('1.50 MB / 2.40 MB · 825.39 KB/s'), findsOneWidget);
    expect(find.byTooltip('1572864/2516582 B · 845200 B/s'), findsOneWidget);
    expect(find.text('Error: Not enough space on the destination disk'),
        findsOneWidget);
  });

  testWidgets('an empty transfer list says how a transfer starts',
      (tester) async {
    await load(tester, const Size(1280, 720),
        withJobs: false, platform: TargetPlatform.macOS);
    expect(find.text('No transfers yet'), findsOneWidget);
    expect(find.textContaining('drop files on the remote side'), findsOneWidget);
  });

  testWidgets('upstream pane icons take the Nightline label colour',
      (tester) async {
    for (final brightness in Brightness.values) {
      final nl = NlColors.forBrightness(brightness);
      expect(nightlineTheme(brightness).tabBarTheme.labelColor, nl.fg2);
    }
  });

  if (nikodesk) {
    testWidgets('the pane header and send button replace the upstream ones',
        (tester) async {
      await load(tester, const Size(1280, 720));
      expect(find.byType(NikoFilePaneHeader), findsNWidgets(2));
      expect(find.text('Local Computer'), findsNothing);
      expect(find.text('This device'), findsOneWidget);
      expect(find.text('418 223 905'), findsOneWidget);
      expect(find.text('macOS'), findsOneWidget);
      expect(find.text('Windows'), findsOneWidget);
      final send = tester
          .widget<NlButton>(find.byKey(const Key('niko-file-send-local')));
      final receive = tester
          .widget<NlButton>(find.byKey(const Key('niko-file-send-remote')));
      expect(send.onPressed, isNotNull, reason: 'a local file is selected');
      expect(receive.onPressed, isNull, reason: 'nothing remote is selected');
    });

    Color? fill(WidgetTester tester, String name) {
      final box = tester.widget<Container>(find
          .descendant(
              of: find.byKey(ValueKey(name)), matching: find.byType(Container))
          .first);
      return (box.decoration as BoxDecoration).color;
    }

    for (final brightness in Brightness.values) {
      testWidgets('a selected row uses the accent wash (${brightness.name})',
          (tester) async {
        await load(tester, const Size(1280, 720), brightness: brightness);
        final nl = NlColors.forBrightness(brightness);
        expect(fill(tester, 'Quarterly report.pdf'), nl.solid(nl.accentSoft));
        // Other rows sit on the page until hovered.
        expect(fill(tester, 'notes.md'), Colors.transparent);
        final mouse =
            await tester.createGesture(kind: PointerDeviceKind.mouse);
        addTearDown(mouse.removePointer);
        await mouse.addPointer(location: Offset.zero);
        await mouse.moveTo(tester.getCenter(find.text('notes.md')));
        await tester.pump();
        expect(fill(tester, 'notes.md'), nl.hover);
      });
    }

    testWidgets('the toolbars draw Lucide glyphs with the upstream tooltips',
        (tester) async {
      await load(tester, const Size(1280, 720));
      for (final (icon, tooltip) in [
        (NlIcons.arrowLeft, 'Back'),
        (NlIcons.cornerLeftUp, 'Parent directory'),
        (NlIcons.search, 'Search'),
        (NlIcons.refreshCw, 'Refresh File'),
        (NlIcons.house, 'Home'),
        (NlIcons.folderPlus, 'Create Folder'),
        (NlIcons.trash2, 'Delete'),
        (NlIcons.ellipsis, 'More'),
      ]) {
        final buttons = find.byWidgetPredicate((widget) =>
            widget is NlIconButton &&
            widget.icon == icon &&
            widget.tooltip == tooltip);
        expect(buttons, findsNWidgets(2), reason: tooltip);
      }
      // Only the two platform marks are still upstream artwork.
      expect(find.byType(SvgPicture), findsNWidgets(2));
      // Delete follows the selection: one local file, nothing remote.
      final delete = tester.widgetList<NlIconButton>(find.byWidgetPredicate(
          (widget) => widget is NlIconButton && widget.tooltip == 'Delete'));
      expect(delete.map((button) => button.onPressed != null), [true, false]);
    });

    testWidgets('a row reports taps to the pane, which moves the selection',
        (tester) async {
      await load(tester, const Size(1280, 720));
      NikoFileRow row(String name) =>
          tester.widget<NikoFileRow>(find.byKey(ValueKey(name)));
      expect(row('Quarterly report.pdf').selected, isTrue);
      await tester.tap(find.text('notes.md'));
      await tester.pump();
      expect(row('notes.md').selected, isTrue);
      expect(row('Quarterly report.pdf').selected, isFalse);
    });

    testWidgets('a pointer gets compact rows; touch keeps 48 px',
        (tester) async {
      await load(tester, const Size(1280, 720),
          platform: TargetPlatform.macOS);
      expect(tester.getSize(find.byKey(const ValueKey('notes.md'))).height, 32);
      await load(tester, const Size(1280, 720),
          platform: TargetPlatform.iOS);
      expect(tester.getSize(find.byKey(const ValueKey('notes.md'))).height, 48);
    });
  } else {
    testWidgets('without the NikoDesk build the upstream pane stays',
        (tester) async {
      await load(tester, const Size(1280, 720));
      expect(find.byType(NikoFilePaneHeader), findsNothing);
      expect(find.text('Local Computer'), findsOneWidget);
      final row = tester.widget<Container>(
          find.byKey(const ValueKey('Quarterly report.pdf')));
      expect((row.decoration as BoxDecoration).color, MyTheme.button);
    });
  }

  testWidgets('overwrite is the destructive choice in the conflict dialog',
      (tester) async {
    final decisions = <bool?>[];
    var remember = false;
    await tester.pumpWidget(MaterialApp(
        theme: nightlineTheme(Brightness.light),
        home: Scaffold(
            body: NikoFileConflictDialog(
                path: r'C:\Users\demo\Desktop\Quarterly report.pdf',
                identical: true,
                showRemember: true,
                remember: false,
                onRemember: (value) => remember = value,
                onDecision: decisions.add))));
    await tester.pumpAndSettle();
    NlButton button(String label) =>
        tester.widget<NlButton>(find.widgetWithText(NlButton, label));
    expect(button('Overwrite').tone, NlButtonTone.danger);
    expect(button('Skip').tone, NlButtonTone.ghost);
    expect(button('Cancel batch').tone, NlButtonTone.ghost);
    expect(button('Cancel batch').autofocus, isTrue);
    // Overwrite comes last, after the choices that keep the destination.
    final actions = tester
        .widget<NikoDialogActions>(find.byType(NikoDialogActions))
        .actions
        .cast<NikoDialogButton>();
    expect(actions.map((action) => action.label),
        ['Cancel batch', 'Skip', 'Overwrite']);
    expect(actions.last.danger, isTrue);
    expect(find.textContaining('identical content'), findsOneWidget);
    // The label toggles the remember box.
    await tester.tap(find.textContaining('remaining conflicts'));
    expect(remember, isTrue);
    // Enter takes the focused choice, which never overwrites.
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(decisions, [false]);
  });
}
