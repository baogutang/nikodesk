import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart' show initGlobalFFI;
import 'package:flutter_hbb/generated_bridge.dart' show Rustdesk;
import 'package:flutter_hbb/mobile/pages/file_manager_page.dart'
    show BottomSheetBody, SelectMode;
import 'package:flutter_hbb/models/file_model.dart';
import 'package:flutter_hbb/models/native_model.dart' show PlatformFFI;
import 'package:flutter_hbb/nikodesk/file_tasks.dart';
import 'package:flutter_hbb/nikodesk/file_transfer.dart'
    show NikoTransferContext;
import 'package:flutter_hbb/nikodesk/mobile_file_pane.dart';
import 'package:flutter_hbb/nikodesk/nightline.dart';
import 'package:flutter_hbb/nikodesk/ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

import 'support/nikodesk_fake_bridge.dart';
import 'support/nikodesk_mobile_file_page.dart';

// The phone and iPad file page in the design system: the upstream mobile
// FileManagerView hands its rows, path bar, list tail and selection sheet to
// lib/nikodesk/mobile_file_pane.dart under the Nightline theme. The hooks are
// in the NikoDesk build only; run with --dart-define=NIKODESK=true.
const _niko = bool.fromEnvironment('NIKODESK');

Widget _app(Widget home, {ThemeData? theme}) => MaterialApp(
    theme: theme ??
        nightlineTheme(Brightness.light).copyWith(platform: TargetPlatform.iOS),
    home: home);

Finder _row(String name) => find.ancestor(
    of: find.text(name), matching: find.byType(NikoMobileFileRow));

/// Records the sends a task list dispatches; anything else fails loudly.
class _SendBridge implements Rustdesk {
  final sent = <(String, String, bool)>[];

  @override
  Future<void> sessionSendFiles(
          {required UuidValue sessionId,
          required int actId,
          required String path,
          required String to,
          required int fileNum,
          required bool includeHidden,
          required bool isRemote,
          required bool isDir,
          dynamic hint}) async =>
      sent.add((path, to, isRemote));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A window of [size] points at twice the density.
void _window(WidgetTester tester, Size size) {
  tester.view.physicalSize = size * 2;
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
}

NikoTestMobileFilePageState _page(WidgetTester tester) =>
    tester.state(find.byType(NikoTestMobileFilePage));

Finder _shown(String text) => find.text(text).hitTestable();

void main() {
  setUp(() async {
    NikoLanguage.english = true;
    PlatformFFI.instance.ffiBindForTesting = NikoFakeBridge();
    await initGlobalFFI();
  });
  tearDown(() => NikoLanguage.english = false);

  testWidgets('a long press selects the entry; taps then toggle entries',
      (tester) async {
    await tester.pumpWidget(_app(const NikoTestMobileFilePage()));
    await tester.pumpAndSettle();
    bool selected(String name) =>
        tester.widget<NikoMobileFileRow>(_row(name)).selected;
    expect(find.byType(NikoMobileFileRow), findsNWidgets(5));
    expect(find.byType(Card), findsNothing);
    expect(find.byType(NlCheckbox), findsNothing);
    await tester.longPress(find.text('notes.md'));
    await tester.pumpAndSettle();
    expect(find.byType(NlCheckbox), findsNWidgets(5));
    expect(selected('notes.md'), isTrue);
    expect(selected('Inbox'), isFalse);
    // While selecting, a folder tap chooses it rather than opening it.
    await tester.tap(find.text('Inbox'));
    await tester.pumpAndSettle();
    expect(selected('Inbox'), isTrue);
    await tester.tap(find.text('notes.md'));
    await tester.pumpAndSettle();
    expect(selected('notes.md'), isFalse);
    expect(tester.takeException(), isNull);
  }, skip: !_niko);

  testWidgets('the row menu selects, renames and deletes', (tester) async {
    await tester.pumpWidget(_app(const NikoTestMobileFilePage()));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(
        of: _row('notes.md'), matching: find.byTooltip('More actions')));
    await tester.pumpAndSettle();
    for (final label in ['Select', 'Rename', 'Delete']) {
      expect(find.text(label), findsOneWidget);
    }
    await tester.tap(find.text('Select'));
    await tester.pumpAndSettle();
    // Choosing Select from an entry's menu selects that entry, as a long
    // press does.
    expect(tester.widget<NikoMobileFileRow>(_row('notes.md')).selected, isTrue);
    expect(find.byType(NlCheckbox), findsNWidgets(5));
  }, skip: !_niko);

  testWidgets('sorting by the current key again reverses the order',
      (tester) async {
    await tester.pumpWidget(_app(const NikoTestMobileFilePage()));
    await tester.pumpAndSettle();
    double top(String name) => tester.getTopLeft(find.text(name)).dy;
    Future<void> sortBy(String key, {required String header}) async {
      await tester.tap(find.byTooltip('Sort'));
      await tester.pumpAndSettle();
      expect(find.text(header), findsOneWidget);
      await tester.tap(find.text(key));
      await tester.pumpAndSettle();
    }

    // The header names the order on screen: upstream sorts the largest
    // file first when ascending.
    await sortBy('Size', header: 'A → Z · choose again to reverse');
    expect(top('IMG_2041.HEIC'), lessThan(top('notes.md')));
    await sortBy('Size', header: 'Largest first · choose again to reverse');
    expect(top('notes.md'), lessThan(top('IMG_2041.HEIC')));
    await sortBy('Name', header: 'Smallest first · choose again to reverse');
    expect(top('IMG_2041.HEIC'), lessThan(top('notes.md')));
  }, skip: !_niko);

  testWidgets('the path bar shows the folders below home, the last one bold',
      (tester) async {
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
    expect(find.text('Documents'), findsNothing);
    expect(tester.widget<Text>(find.text('Inbox')).style!.fontWeight,
        FontWeight.w400);
    expect(tester.widget<Text>(find.text('2026')).style!.fontWeight,
        FontWeight.w600);
    for (final tooltip in ['Home folder', 'Back', 'Enclosing folder', 'Sort']) {
      expect(find.byTooltip(tooltip), findsOneWidget);
    }
  }, skip: !_niko);

  testWidgets('the selection bar draws Lucide actions above the home indicator',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844) * 3;
    tester.view.devicePixelRatio = 3;
    tester.view.padding = const FakeViewPadding(bottom: 34 * 3);
    addTearDown(tester.view.reset);
    var cancelled = 0, switched = 0;
    await tester.pumpWidget(_app(Scaffold(
        body: const SizedBox.expand(),
        bottomSheet: BottomSheetBody(
            leading: const Icon(Icons.check),
            title: 'Selected',
            text: '2 items [Local]',
            onCanceled: () => cancelled++,
            actions: [
              IconButton(
                  icon: const Icon(Icons.compare_arrows),
                  tooltip: 'Switch destination area',
                  onPressed: () => switched++),
              IconButton(
                  icon: const Icon(Icons.delete_forever),
                  tooltip: 'Delete selected files',
                  onPressed: () {}),
              IconButton(
                  icon: const Icon(Icons.star),
                  tooltip: 'Unmapped',
                  onPressed: () {}),
            ]))));
    await tester.pumpAndSettle();
    NlIconButton button(String tooltip) => tester.widget<NlIconButton>(find
        .ancestor(
            of: find.byTooltip(tooltip), matching: find.byType(NlIconButton))
        .first);
    expect(button('Switch destination area').icon, NlIcons.arrowLeftRight);
    expect(button('Delete selected files').icon, NlIcons.trash2);
    expect(button('Delete selected files').color, NlColors.light.dangerText);
    // A glyph without a match keeps the upstream button.
    expect(find.widgetWithIcon(IconButton, Icons.star), findsOneWidget);
    expect(find.byIcon(NlIcons.circleCheck), findsOneWidget);
    await tester.tap(find.byTooltip('Switch destination area'));
    await tester.tap(find.byTooltip('Cancel selection'));
    expect((switched, cancelled), (1, 1));
    final bar = tester.getRect(find
        .ancestor(
            of: find.text('Selected'), matching: find.byType(DecoratedBox))
        .first);
    expect(bar.bottom, 844 - 34);
  }, skip: !_niko);

  testWidgets('the file area guide opens in place; the result dismisses',
      (tester) async {
    var dismissed = 0;
    await tester.pumpWidget(_app(Scaffold(
        body: Column(children: [
      NikoAppFileAreaNotice(
          showGuide: true,
          status: 'Import files: 2 succeeded',
          onDismiss: () => dismissed++),
      const Expanded(child: SizedBox()),
    ]))));
    expect(find.byType(ExpansionTile), findsNothing);
    expect(find.textContaining('This area shows files'), findsNothing);
    await tester.tap(find.text('About the app file area'));
    await tester.pumpAndSettle();
    expect(find.textContaining('This area shows files'), findsOneWidget);
    await tester.ensureVisible(find.byTooltip('Dismiss result'));
    await tester.tap(find.byTooltip('Dismiss result'));
    expect(dismissed, 1);
  }, skip: !_niko);

  testWidgets('the app bar menu keeps the page items, in Lucide glyphs',
      (tester) async {
    final chosen = <String>[];
    await tester.pumpWidget(_app(NikoTestMobileFilePage(onAction: chosen.add)));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.close), findsNothing);
    expect(find.byIcon(Icons.more_vert), findsNothing);
    expect(find.byIcon(NlIcons.close), findsOneWidget);
    await tester.tap(find.byTooltip('File actions'));
    await tester.pumpAndSettle();
    for (final (label, glyph) in [
      ('Refresh File', NlIcons.refreshCw),
      ('Multi Select', NlIcons.circleCheck),
      ('Create Folder', NlIcons.folderPlus),
      ('Show Hidden Files', NlIcons.eye),
    ]) {
      expect(find.text(label), findsOneWidget);
      expect(find.byIcon(glyph), findsOneWidget);
    }
    // Hidden files are off: the item carries no check.
    expect(find.byIcon(NlIcons.check), findsNothing);
    await tester.tap(find.text('Create Folder'));
    await tester.pumpAndSettle();
    expect(chosen, ['folder']);
  }, skip: !_niko);

  testWidgets('a menu of another shape keeps the upstream button',
      (tester) async {
    await tester.pumpWidget(_app(Scaffold(
        body: Builder(
            builder: (context) => Row(children: [
                  nikoMobileActionsMenu(
                      context,
                      PopupMenuButton<String>(
                          itemBuilder: (_) => [const PopupMenuDivider()])),
                  nikoMobileActionsMenu(
                      context,
                      PopupMenuButton<String>(
                          enabled: false,
                          tooltip: 'Off',
                          itemBuilder: (_) => [
                                const PopupMenuItem(
                                    value: 'refresh', child: Text('Refresh'))
                              ])),
                ])))));
    expect(find.byType(PopupMenuButton<String>), findsOneWidget);
    expect(
        tester
            .widget<NlIconButton>(find.ancestor(
                of: find.byTooltip('Off'), matching: find.byType(NlIconButton)))
            .onPressed,
        isNull);
  }, skip: !_niko);

  testWidgets('outside the Nightline theme the upstream pieces stay',
      (tester) async {
    await tester.pumpWidget(_app(
        Scaffold(
            body: Builder(
                builder: (context) => Column(children: [
                      Text(
                          '${nikoSelectionSheet(context, title: '', text: '', leading: const SizedBox())}'),
                      NikoAppFileAreaNotice(showGuide: true, onDismiss: () {}),
                    ]))),
        theme: ThemeData.light()));
    expect(find.text('null'), findsOneWidget);
    expect(find.byType(ExpansionTile), findsOneWidget);
  }, skip: !_niko);

  // From 1000 points across, an iPad in landscape for one, both sides stand
  // next to each other: files chosen on one go to the folder open on the
  // other without switching.
  group('both sides next to each other', () {
    testWidgets('an iPad in landscape shows app files beside the remote side',
        (tester) async {
      _window(tester, const Size(1180, 820));
      await tester.pumpWidget(_app(const NikoTestMobileFilePage()));
      await tester.pumpAndSettle();
      expect(_shown('Inbox'), findsOneWidget);
      expect(_shown('Builds'), findsOneWidget);
      expect(find.byKey(const Key('niko-file-pane-1')), findsNothing);
      expect(_shown('App files'), findsOneWidget);
      expect(_shown('Remote'), findsOneWidget);
      // The remote side's ID and platform follow its name.
      expect(find.text('418 223 905 · macOS'), findsOneWidget);
      // The guide to the app file area stays while both sides show.
      expect(_shown('About the app file area'), findsOneWidget);
      // The tasks wait behind a Files | Tasks switch.
      expect(find.text('No transfers yet').hitTestable(), findsNothing);
      await tester.tap(find.byKey(const Key('niko-file-split-tasks')));
      await tester.pumpAndSettle();
      expect(_shown('No transfers yet'), findsOneWidget);
      // A touch screen has no drop from the system to point to.
      expect(find.textContaining('Long-press files to choose them'),
          findsOneWidget);
      expect(find.textContaining('drop files'), findsNothing);
      expect(_shown('Inbox'), findsNothing);
      await tester.tap(find.byKey(const Key('niko-file-split-files')));
      await tester.pumpAndSettle();
      expect(_shown('Inbox'), findsOneWidget);
      expect(_shown('Builds'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }, skip: !_niko);

    testWidgets('an iPad in portrait keeps one side at a time', (tester) async {
      _window(tester, const Size(820, 1180));
      await tester.pumpWidget(_app(const NikoTestMobileFilePage()));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('niko-file-pane-1')), findsOneWidget);
      expect(find.byKey(const Key('niko-file-split-tasks')), findsNothing);
      expect(_shown('Inbox'), findsOneWidget);
      expect(_shown('Builds'), findsNothing);
    }, skip: !_niko);

    testWidgets('turning to landscape keeps what is chosen', (tester) async {
      _window(tester, const Size(820, 1180));
      await tester.pumpWidget(_app(const NikoTestMobileFilePage()));
      await tester.pumpAndSettle();
      await tester.longPress(find.text('notes.md'));
      await tester.pumpAndSettle();
      tester.view.physicalSize = const Size(1180, 820) * 2;
      await tester.pumpAndSettle();
      expect(_shown('Builds'), findsOneWidget);
      expect(_shown('1 selected'), findsOneWidget);
      expect(_shown('To: Remote › Desktop'), findsOneWidget);
      expect(
          tester.widget<NikoMobileFileRow>(_row('notes.md')).selected, isTrue);
      expect(tester.takeException(), isNull);
    }, skip: !_niko);

    testWidgets('large text keeps one side at a time sooner', (tester) async {
      _window(tester, const Size(1180, 820));
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpWidget(_app(const NikoTestMobileFilePage()));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('niko-file-pane-1')), findsOneWidget);
    }, skip: !_niko);

    testWidgets('from 1240 points the tasks take a column beside both sides',
        (tester) async {
      _window(tester, const Size(1376, 1032));
      await tester.pumpWidget(_app(const NikoTestMobileFilePage()));
      await tester.pumpAndSettle();
      expect(_shown('Inbox'), findsOneWidget);
      expect(_shown('Builds'), findsOneWidget);
      expect(_shown('No transfers yet'), findsOneWidget);
      expect(find.byKey(const Key('niko-file-split-tasks')), findsNothing);
      // 300 points less the hairline before it.
      expect(tester.getSize(find.byType(NikoFileTasks)).width, 299);
    }, skip: !_niko);

    testWidgets('a touch picks the side the actions menu works on',
        (tester) async {
      _window(tester, const Size(1180, 820));
      await tester.pumpWidget(_app(const NikoTestMobileFilePage()));
      await tester.pumpAndSettle();
      Color? ink(String name) =>
          tester.widget<Text>(find.text(name)).style?.color;
      expect(ink('App files'), NlColors.light.fg);
      expect(ink('Remote'), NlColors.light.fg2);
      await tester.tap(find.text('Remote'));
      await tester.pumpAndSettle();
      expect(ink('App files'), NlColors.light.fg2);
      expect(ink('Remote'), NlColors.light.fg);
      await tester.tap(find.byTooltip('File actions'));
      await tester.pumpAndSettle();
      // The menu names the side it works on.
      expect(find.text('Remote'), findsNWidgets(2));
      expect(find.text('Refresh File'), findsOneWidget);
    }, skip: !_niko);

    testWidgets('files chosen on one side go to the folder open on the other',
        (tester) async {
      _window(tester, const Size(1180, 820));
      final bridge = _SendBridge();
      await tester.pumpWidget(_app(NikoTestMobileFilePage(jobs: (ffi) {
        final context = NikoTransferContext(
            sessionId: ffi.sessionId.toString(),
            namespace: 'a' * 64,
            peerId: ffi.id,
            connection: 1,
            ready: true,
            fileAllowed: true);
        return JobController(() => ffi.sessionId, () => null,
            nikoBridge: bridge)
          ..nikoContext = () => context;
      })));
      await tester.pumpAndSettle();
      final page = _page(tester);
      expect(find.byKey(const Key('niko-file-split-send')), findsNothing);
      await tester.longPress(find.text('notes.md'));
      await tester.pumpAndSettle();
      expect(page.selectMode.value, SelectMode.local);
      // Each side says its part, and the bar says where the files go.
      expect(_shown('From here'), findsOneWidget);
      expect(_shown('To here'), findsOneWidget);
      expect(_shown('1 selected'), findsOneWidget);
      expect(_shown('To: Remote › Desktop'), findsOneWidget);
      // Only the side choosing shows checkboxes; the other still browses.
      expect(find.byType(NlCheckbox), findsNWidgets(5));
      page.remote.directory.value = FileDirectory()
        ..path = '/Users/demo/Desktop/Builds';
      await tester.pumpAndSettle();
      expect(_shown('To: Remote › Builds'), findsOneWidget);
      await tester.tap(find.byKey(const Key('niko-file-split-send')));
      await tester.pumpAndSettle();
      expect(bridge.sent, [
        (
          '/var/mobile/Documents/notes.md',
          '/Users/demo/Desktop/Builds/notes.md',
          false
        )
      ]);
      expect(page.selectMode.value, SelectMode.none);
      expect(page.local.selectedItems.items, isEmpty);
      expect(find.byKey(const Key('niko-file-split-send')), findsNothing);
      expect(find.byType(NlCheckbox), findsNothing);
      // The task shows on the switch without leaving the files.
      expect(
          find.descendant(
              of: find.byKey(const Key('niko-file-split-tasks')),
              matching: find.text('1')),
          findsOneWidget);
      expect(_shown('Inbox'), findsOneWidget);
    }, skip: !_niko);

    testWidgets('choosing on the other side starts over there', (tester) async {
      _window(tester, const Size(1180, 820));
      await tester.pumpWidget(_app(const NikoTestMobileFilePage()));
      await tester.pumpAndSettle();
      final page = _page(tester);
      await tester.longPress(find.text('notes.md'));
      await tester.pumpAndSettle();
      await tester.longPress(find.text('build.log'));
      await tester.pumpAndSettle();
      expect(page.selectMode.value, SelectMode.remote);
      expect(page.local.selectedItems.items, isEmpty);
      expect(page.remote.selectedItems.items.map((entry) => entry.name),
          ['build.log']);
      expect(find.byType(NlCheckbox), findsNWidgets(4));
      expect(_shown('To: App files › Documents'), findsOneWidget);
      expect(_shown('Receive'), findsOneWidget);
    }, skip: !_niko);

    testWidgets('sending waits for a folder on the other side', (tester) async {
      _window(tester, const Size(1180, 820));
      await tester.pumpWidget(_app(const NikoTestMobileFilePage()));
      await tester.pumpAndSettle();
      final page = _page(tester);
      // A Windows peer at its drive list.
      page.remote.options.value = DirectoryOptions(home: '/', isWindows: true);
      page.remote.directory.value = FileDirectory()
        ..path = '/'
        ..entries = [
          Entry()
            ..name = 'C:'
            ..entryType = 3
        ];
      await tester.pumpAndSettle();
      await tester.longPress(find.text('notes.md'));
      await tester.pumpAndSettle();
      expect(_shown('Open a folder on the remote side first'), findsOneWidget);
      expect(
          tester
              .widget<NlButton>(find.byKey(const Key('niko-file-split-send')))
              .onPressed,
          isNull);
      // Letting the selection go leaves select mode.
      await tester.tap(find.byTooltip('Cancel selection'));
      await tester.pumpAndSettle();
      expect(page.selectMode.value, SelectMode.none);
      expect(page.local.selectedItems.items, isEmpty);
    }, skip: !_niko);
  });
}
