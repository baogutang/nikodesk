import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart' show initGlobalFFI;
import 'package:flutter_hbb/models/file_model.dart';
import 'package:flutter_hbb/models/native_model.dart' show PlatformFFI;
import 'package:flutter_hbb/nikodesk/file_tasks.dart';
import 'package:flutter_hbb/nikodesk/mobile_file_pane.dart';
import 'package:flutter_hbb/nikodesk/nightline.dart';
import 'package:flutter_hbb/nikodesk/privacy_style.dart';
import 'package:flutter_hbb/nikodesk/session_quick_actions_view.dart';
import 'package:flutter_hbb/nikodesk/ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/nikodesk_fake_bridge.dart';
import 'support/nikodesk_mobile_file_page.dart';

// Controls that show their own text are read once by a screen reader: the
// text names them, with no label of the same words on top. The phone file
// page pieces are handed over in the NikoDesk build only; run with
// --dart-define=NIKODESK=true as well.
const _niko = bool.fromEnvironment('NIKODESK');

Widget _app(Widget home) => MaterialApp(
    theme:
        nightlineTheme(Brightness.light).copyWith(platform: TargetPlatform.iOS),
    home: home);

String _label(WidgetTester tester, Finder finder) =>
    tester.getSemantics(finder).getSemanticsData().label;

void main() {
  setUp(() async {
    NikoLanguage.english = true;
    PlatformFFI.instance.ffiBindForTesting = NikoFakeBridge();
    await initGlobalFFI();
  });
  tearDown(() => NikoLanguage.english = false);

  testWidgets('a shortcut reads its name and keys once', (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(_app(Scaffold(
        body: NikoShortcutKey(name: 'Copy', keys: '⌘C', onPressed: () {}))));
    expect(_label(tester, find.byType(NikoShortcutKey)), 'Copy\n⌘C');
    semantics.dispose();
  });

  testWidgets('a privacy preset reads its name once', (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(_app(Scaffold(
        body: SingleChildScrollView(
            child: SizedBox(
                width: 400,
                child: NikoPrivacyStyleEditor(
                    allowed: true, active: false, onApply: (_) async {}))))));
    expect(
        _label(tester, find.byKey(const ValueKey('privacy-preset-graphite'))),
        'Graphite');
    semantics.dispose();
  });

  testWidgets('the file area guide reads its title once', (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(_app(Scaffold(
        body: Column(children: [
      NikoAppFileAreaNotice(showGuide: true, onDismiss: () {}),
      const Expanded(child: SizedBox()),
    ]))));
    expect(_label(tester, find.text('About the app file area')),
        'About the app file area');
    semantics.dispose();
  });

  testWidgets('a file row and a path folder read their names once',
      (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(_app(const NikoTestMobileFilePage()));
    await tester.pumpAndSettle();
    final row = _label(tester, find.text('notes.md')).split('\n');
    expect(row.first, 'notes.md');
    expect(row.where((line) => line == 'notes.md'), hasLength(1));

    final ffi = NikoTestFileFFI();
    final controller = nikoTestFileController(
        ffi, JobController(() => ffi.sessionId, () => null),
        local: true, path: '/var/mobile/Documents');
    controller.directory.value = FileDirectory()
      ..path = '/var/mobile/Documents/Inbox/2026';
    await tester.pumpWidget(_app(Scaffold(
        body: Builder(
            builder: (context) => nikoMobilePathBar(context, controller)!))));
    await tester.pumpAndSettle();
    expect(_label(tester, find.text('Inbox')), 'Inbox');
    semantics.dispose();
  }, skip: !_niko);
}
