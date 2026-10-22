import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/models/native_model.dart';
import 'package:flutter_hbb/nikodesk/file_conflict_dialog.dart';
import 'package:flutter_hbb/nikodesk/file_pane.dart';
import 'package:flutter_hbb/nikodesk/nightline.dart';
import 'package:flutter_hbb/nikodesk/ui.dart';
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
      {Brightness brightness = Brightness.dark, bool withJobs = true}) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
        theme: nightlineTheme(brightness),
        home: NikoTestFileWindow(withJobs: withJobs)));
    await tester.pumpAndSettle();
  }

  testWidgets('a new window keeps both panes and every pane tool in view',
      (tester) async {
    // 1280 x 720 is the size a new file transfer window opens at.
    await load(tester, const Size(1280, 720));
    expect(find.byKey(const Key('niko-file-pane-0')), findsNothing);
    expect(find.text('TRANSFERS'), findsOneWidget);
    for (final tool in ['Refresh File', 'Search', 'More']) {
      expect(find.byTooltip(tool).hitTestable(), findsNWidgets(2), reason: tool);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('a narrow window shows one pane at a time and counts tasks',
      (tester) async {
    await load(tester, const Size(900, 640));
    expect(find.text('TRANSFERS').hitTestable(), findsNothing);
    final tasks = find.byKey(const Key('niko-file-pane-2'));
    expect(find.descendant(of: tasks, matching: find.text('3')), findsOneWidget);
    await tester.tap(tasks);
    await tester.pumpAndSettle();
    expect(find.text('TRANSFERS').hitTestable(), findsOneWidget);
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
    await load(tester, const Size(1280, 720), withJobs: false);
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
      expect(find.text('MAC OS'), findsOneWidget);
      expect(find.text('WINDOWS'), findsOneWidget);
      final send = tester
          .widget<NlButton>(find.byKey(const Key('niko-file-send-local')));
      final receive = tester
          .widget<NlButton>(find.byKey(const Key('niko-file-send-remote')));
      expect(send.onPressed, isNotNull, reason: 'a local file is selected');
      expect(receive.onPressed, isNull, reason: 'nothing remote is selected');
    });

    for (final brightness in Brightness.values) {
      testWidgets('a selected row uses the accent wash (${brightness.name})',
          (tester) async {
        await load(tester, const Size(1280, 720), brightness: brightness);
        final nl = NlColors.forBrightness(brightness);
        final row = tester.widget<Container>(
            find.byKey(const ValueKey('Quarterly report.pdf')));
        expect((row.decoration as BoxDecoration).color, nl.solid(nl.accentSoft));
        final unselected =
            tester.widget<Container>(find.byKey(const ValueKey('notes.md')));
        expect((unselected.decoration as BoxDecoration).color, nl.surface);
      });
    }
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
    for (final brightness in Brightness.values) {
      final nl = NlColors.forBrightness(brightness);
      await tester.pumpWidget(MaterialApp(
          theme: nightlineTheme(brightness),
          home: Scaffold(
              body: NikoFileConflictDialog(
                  path: '/remote/file.txt',
                  identical: false,
                  showRemember: false,
                  remember: false,
                  onRemember: (_) {},
                  onDecision: (_) {}))));
      final overwrite = tester.widget<FilledButton>(find.byType(FilledButton));
      expect(overwrite.style!.backgroundColor!.resolve({}), nl.dangerFill);
      expect(overwrite.style!.foregroundColor!.resolve({}), nl.onDanger);
    }
  });
}
