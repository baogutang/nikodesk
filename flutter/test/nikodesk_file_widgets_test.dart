import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/mobile/pages/file_manager_page.dart'
    show BottomSheetBody;
import 'package:flutter_hbb/models/file_model.dart';
import 'package:flutter_hbb/nikodesk/file_conflict_dialog.dart';
import 'package:flutter_hbb/nikodesk/file_tasks.dart';
import 'package:flutter_hbb/nikodesk/file_transfer.dart';
import 'package:flutter_hbb/nikodesk/theme.dart';
import 'package:flutter_hbb/nikodesk/ui.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(Widget child,
        {Brightness brightness = Brightness.light,
        double scale = 2,
        Size? size}) =>
    MaterialApp(
        theme: nikoTheme(brightness),
        home: Builder(
            builder: (context) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(scale), size: size),
                child: Scaffold(body: child))));

JobProgress _failed() => JobProgress()
  ..id = 7
  ..type = JobType.transfer
  ..state = JobState.error
  ..jobName = '/source/very-long-file-name.txt'
  ..fileName = 'very-long-file-name.txt'
  ..err = 'Destination is full'
  ..finishedSize = 24
  ..totalSize = 240
  ..isRemoteToLocal = true;

void main() {
  tearDown(() => NikoLanguage.english = false);

  for (final english in [false, true]) {
    for (final brightness in [Brightness.light, Brightness.dark]) {
      testWidgets(
          'failed task remains usable at 320/200% ${english ? 'en' : 'zh'} ${brightness.name}',
          (tester) async {
        NikoLanguage.english = english;
        await tester.binding.setSurfaceSize(const Size(320, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final semantics = tester.ensureSemantics();
        final job = _failed();
        var retries = 0;
        var removes = 0;
        await tester.pumpWidget(_host(
            SingleChildScrollView(
                child: NikoFileTaskCard(
                    job: job,
                    request: NikoTransferRequest(
                        context: NikoTransferContext(
                            sessionId: 'test-session',
                            namespace: 'a' * 64,
                            peerId: 'test-peer',
                            connection: 1,
                            ready: true,
                            fileAllowed: true),
                        source: '/remote/a/long/source/path/file.txt',
                        destination: '/app/destination/file.txt',
                        remoteToLocal: true,
                        includeHidden: true,
                        isDirectory: false,
                        size: 240),
                    onRetry: () => retries++,
                    onRemove: () => removes++)),
            brightness: brightness));
        expect(tester.takeException(), isNull);
        expect(find.textContaining('Destination is full'), findsOneWidget);
        expect(find.text(english ? 'Remote → local file area' : '远端 → 本地文件区'),
            findsOneWidget);
        expect(job.finishedSize, 24);
        final retry = find.byKey(const Key('niko-file-resend-7'));
        await tester.ensureVisible(retry);
        expect(tester.getSize(retry).height, greaterThanOrEqualTo(48));
        expect(
            tester.getSemantics(retry).hasFlag(SemanticsFlag.isButton), isTrue);
        await tester.tap(retry);
        await tester.tap(find.byKey(const Key('niko-file-remove-7')));
        expect(retries, 1);
        expect(removes, 1);
        semantics.dispose();
      });

      testWidgets(
          'file data completion leaves unconfirmed folder structure visible at 320/200% ${english ? 'en' : 'zh'} ${brightness.name}',
          (tester) async {
        NikoLanguage.english = english;
        await tester.binding.setSurfaceSize(const Size(320, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final job = _failed()..state = JobState.done;
        await tester.pumpWidget(_host(
            SingleChildScrollView(
                child: NikoFileTaskCard(
                    job: job,
                    folder: const NikoFolderProgress(
                        NikoFolderState.unconfirmed,
                        expected: 2,
                        confirmed: 1,
                        issue: NikoFolderIssue.timeout),
                    onRetry: () {},
                    onRemove: () {})),
            brightness: brightness));
        expect(tester.takeException(), isNull);
        expect(
            find.text(english
                ? 'File data completed; folder structure unconfirmed'
                : '文件数据已完成；文件夹结构未确认'),
            findsOneWidget);
        expect(
            find.textContaining(
                english ? 'remote completion is unconfirmed' : '远端是否完成尚未确认'),
            findsOneWidget);
        expect(find.byType(LinearProgressIndicator), findsNothing);
        await tester.ensureVisible(find.byKey(const Key('niko-file-resend-7')));
        expect(
            tester.getSize(find.byKey(const Key('niko-file-resend-7'))).height,
            greaterThanOrEqualTo(48));
        expect(job.finishedSize, 24);
      });

      testWidgets(
          'conflict dialog keeps all decisions reachable at 320/200% ${english ? 'en' : 'zh'} ${brightness.name}',
          (tester) async {
        NikoLanguage.english = english;
        await tester.binding.setSurfaceSize(const Size(320, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final decisions = <bool?>[];
        var remember = false;
        await tester.pumpWidget(_host(
            Center(
                child: NikoFileConflictDialog(
                    path: '/app/existing-file.txt',
                    identical: true,
                    showRemember: true,
                    remember: remember,
                    onRemember: (value) => remember = value,
                    onDecision: decisions.add)),
            brightness: brightness));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final checkbox = find.byType(CheckboxListTile);
        await tester.ensureVisible(checkbox);
        await tester.tap(checkbox);
        expect(remember, isTrue);
        for (final title in [
          english ? 'Cancel batch' : '取消本批',
          english ? 'Skip' : '跳过',
          english ? 'Overwrite' : '覆盖'
        ]) {
          await tester.ensureVisible(find.text(title));
          await tester.tap(find.text(title));
          await tester.pump();
        }
        expect(decisions, [false, null, true]);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('default conflict keyboard action cancels rather than overwrites',
      (tester) async {
    final decisions = <bool?>[];
    await tester.pumpWidget(_host(
        Center(
            child: NikoFileConflictDialog(
                path: '/destination/file',
                identical: false,
                showRemember: false,
                remember: false,
                onRemember: (_) {},
                onDecision: decisions.add)),
        scale: 1));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(decisions, [false]);
  });

  testWidgets(
      'cancellation request exposes uncertainty and keeps actual byte count',
      (tester) async {
    NikoLanguage.english = true;
    final job = _failed()
      ..state = JobState.inProgress
      ..recvJobRes = true;
    await tester.pumpWidget(_host(
        NikoFileTaskCard(
            job: job, cancellation: NikoCancelState.requested, onRemove: () {}),
        scale: 1));
    expect(find.text('Cancellation requested; remote status unconfirmed'),
        findsOneWidget);
    expect(find.byKey(const Key('niko-file-cancel-7')), findsNothing);
    expect(find.byKey(const Key('niko-file-resend-7')), findsNothing);
    expect(job.finishedSize, 24);
  });

  testWidgets(
      'missing request and revoked permissions explain why resend is unavailable',
      (tester) async {
    NikoLanguage.english = true;
    for (final reason in [
      NikoRetryBlock.missingRequest,
      NikoRetryBlock.changedSession,
      NikoRetryBlock.disconnected,
      NikoRetryBlock.permission
    ]) {
      await tester.pumpWidget(_host(
          NikoFileTaskCard(job: _failed(), retryBlock: reason),
          scale: 1));
      expect(find.text(nikoFileRetryReason(reason)), findsOneWidget);
      expect(find.byKey(const Key('niko-file-resend-7')), findsNothing);
    }
  });

  testWidgets(
      'narrow workspace preserves both real pane subtrees and excludes hidden focus',
      (tester) async {
    NikoLanguage.english = true;
    await tester.binding.setSurfaceSize(const Size(320, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final local = TextEditingController(text: '/app/selected-folder');
    final remote = TextEditingController(text: '/remote/selected-folder');
    addTearDown(local.dispose);
    addTearDown(remote.dispose);
    await tester.pumpWidget(_host(NikoFileWorkspace(
        local: TextField(key: const Key('local-pane'), controller: local),
        remote: TextField(key: const Key('remote-pane'), controller: remote),
        tasks: const Text('Actual task list'))));
    await tester.tap(find.byKey(const Key('niko-file-pane-1')));
    await tester.pump();
    expect(find.byKey(const Key('local-pane')).hitTestable(), findsNothing);
    final hidden = tester.widget<ExcludeFocus>(find.ancestor(
        of: find.byKey(const Key('local-pane'), skipOffstage: false),
        matching: find.byType(ExcludeFocus, skipOffstage: false)));
    expect(hidden.excluding, isTrue);
    await tester.tap(find.byKey(const Key('niko-file-pane-2')));
    await tester.pump();
    expect(find.text('Actual task list').hitTestable(), findsOneWidget);
    await tester.tap(find.byKey(const Key('niko-file-pane-0')));
    await tester.pump();
    expect(local.text, '/app/selected-folder');
    expect(remote.text, '/remote/selected-folder');
    expect(find.byKey(const Key('local-pane')).hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('wide workspace shows both directories and tasks at once',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_host(
        const NikoFileWorkspace(
            local: Text('Local directory'),
            remote: Text('Remote directory'),
            tasks: Text('Tasks')),
        scale: 1));
    for (final name in ['Local directory', 'Remote directory', 'Tasks']) {
      expect(find.text(name).hitTestable(), findsOneWidget);
    }
    expect(find.byType(ChoiceChip), findsNothing);
  });

  testWidgets('mobile controlled pane follows selection destination changes',
      (tester) async {
    var selected = 0;
    await tester.pumpWidget(_host(
        StatefulBuilder(
            builder: (context, setState) => NikoFileWorkspace(
                alwaysCompact: true,
                selectedPane: selected,
                onPaneChanged: (pane) => setState(() => selected = pane),
                local: TextButton(
                    onPressed: () => setState(() => selected = 1),
                    child: const Text('Choose remote destination')),
                remote: const Text('Remote destination'),
                tasks: const Text('Tasks'))),
        scale: 1));
    await tester.tap(find.text('Choose remote destination'));
    await tester.pump();
    expect(find.text('Remote destination').hitTestable(), findsOneWidget);
    await tester.tap(find.byKey(const Key('niko-file-pane-2')));
    await tester.pump();
    expect(selected, 2);
  });

  test(
      'system document feedback preserves native counts and safe error categories',
      () {
    NikoLanguage.english = true;
    expect(
        nikoDocumentFeedback(
            'Import files',
            const NikoDocumentOutcome(
                succeeded: 2, failed: 1, skipped: 3, cancelled: true)),
        'Import files: 2 succeeded, 1 failed, 3 skipped; operation cancelled');
    expect(
        nikoDocumentFeedback(
            'Import',
            const NikoDocumentOutcome(
                succeeded: 2, errorCode: 'directory_refresh_failed')),
        contains('2 succeeded, 0 failed'));
    expect(
        nikoDocumentFeedback('Export',
            const NikoDocumentOutcome(errorCode: 'private/path/token')),
        isNot(contains('private/path/token')));
    expect(
        nikoDocumentFeedback('Export',
            const NikoDocumentOutcome(errorCode: 'picker_in_progress')),
        contains('another file picker is open'));
    final reply = nikoDocumentExportOutcome({'exported': 3, 'failed': 2});
    expect(reply.succeeded, 3);
    expect(reply.failed, 2);
    for (final invalid in [
      {'exported': 3},
      {'exported': -1, 'failed': 0},
      {'exported': '3', 'failed': 0}
    ]) {
      final unknown = nikoDocumentExportOutcome(invalid);
      expect(unknown.incomplete, isTrue);
      expect(unknown.succeeded, 0);
      expect(nikoDocumentFeedback('Export', unknown),
          contains('outcomes are unconfirmed'));
    }
  });

  testWidgets('mobile app file guide and operation result fit 320/200%',
      (tester) async {
    NikoLanguage.english = true;
    await tester.binding.setSurfaceSize(const Size(320, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var dismisses = 0;
    await tester.pumpWidget(_host(Column(children: [
      NikoAppFileAreaNotice(
          showGuide: true,
          status: nikoDocumentFeedback('Import',
              const NikoDocumentOutcome(succeeded: 2, failed: 1, skipped: 1)),
          onDismiss: () => dismisses++),
      const Expanded(child: Text('File directory'))
    ])));
    await tester.tap(find.text('About the app file area'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.byTooltip('Dismiss result'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Dismiss result'));
    expect(dismisses, 1);
    expect(find.textContaining('2 succeeded, 1 failed'), findsOneWidget);
  });

  testWidgets('narrow directory columns retain scalable row and header extents',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_host(NikoFileDirectoryTable(
        child: Builder(
            builder: (context) => Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(
                          key: const Key('table-header'),
                          height: nikoFileRowExtent(context, 25),
                          child: const Text('Name · Modified · Size')),
                      SizedBox(
                          key: const Key('table-row'),
                          height: nikoFileRowExtent(context, 30),
                          child: const Text('A real directory row')),
                      const Expanded(child: SizedBox())
                    ])))));
    expect(tester.takeException(), isNull);
    expect(tester.getSize(find.byKey(const Key('table-header'))).height, 58);
    expect(tester.getSize(find.byKey(const Key('table-row'))).height, 68);
    expect(tester.getSize(find.byKey(const Key('table-row'))).width, 1080);
  });

  testWidgets(
      'mobile landscape keeps the actual file workspace available below the guide',
      (tester) async {
    NikoLanguage.english = true;
    await tester.binding.setSurfaceSize(const Size(800, 350));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_host(
        Column(children: [
          NikoAppFileAreaNotice(
              showGuide: true,
              onDismiss: () {},
              status:
                  'Import files: 2 succeeded, 1 failed; remaining outcomes unconfirmed'),
          const Expanded(
              child: NikoFileWorkspace(
                  key: Key('landscape-workspace'),
                  alwaysCompact: true,
                  local: Text('App files'),
                  remote: Text('Remote files'),
                  tasks: Text('Tasks')))
        ]),
        size: const Size(800, 350)));
    expect(tester.takeException(), isNull);
    expect(tester.getSize(find.byKey(const Key('landscape-workspace'))).height,
        greaterThan(200));
    await tester.tap(find.byKey(const Key('niko-file-pane-1')));
    await tester.pump();
    expect(find.text('Remote files'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  if (const bool.fromEnvironment('NIKODESK')) {
    testWidgets(
        'mobile selection actions wrap with 48px targets without mutating caller actions',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      var calls = 0;
      final actions = [
        for (var i = 0; i < 3; i++)
          IconButton(
              tooltip: 'Action $i',
              onPressed: () => calls++,
              icon: const Icon(Icons.copy))
      ];
      await tester.pumpWidget(_host(BottomSheetBody(
          leading: const Icon(Icons.check),
          title: 'Selected destination',
          text: '3 selected files in the remote file area',
          actions: actions,
          onCanceled: () {})));
      expect(tester.takeException(), isNull);
      expect(actions, hasLength(3));
      for (var i = 0; i < 3; i++) {
        expect(
            tester
                .getSize(find.ancestor(
                    of: find.byTooltip('Action $i'),
                    matching: find.byType(IconButton)))
                .height,
            greaterThanOrEqualTo(48));
        await tester.tap(find.byTooltip('Action $i'));
      }
      expect(calls, 3);
      expect(actions, hasLength(3));
    });
  }
}
