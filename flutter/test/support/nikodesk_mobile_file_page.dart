// The phone and iPad file transfer page as FileManagerPage builds it in the
// NikoDesk build: its app bar, the app file area notice, and the file area
// (one side at a time, or both next to each other on a wide screen) over
// the real mobile FileManagerView on file controllers with fixed
// directories (nikoTestFileController). [selecting] opens multi-select on
// the app files with two of them chosen, and shows the page's selection
// sheet. No session or native call is made; install NikoFakeBridge before
// pumping it.
import 'package:flutter/material.dart';
import 'package:flutter_hbb/mobile/pages/file_manager_page.dart'
    show BottomSheetBody, FileManagerView, SelectMode, SelectModeEq;
import 'package:flutter_hbb/models/file_model.dart';
import 'package:flutter_hbb/models/model.dart' show FFI, FfiModel;
import 'package:flutter_hbb/nikodesk/file_tasks.dart';
import 'package:flutter_hbb/nikodesk/mobile_file_pane.dart';
import 'package:flutter_hbb/nikodesk/ui.dart';
import 'package:get/get.dart';
import 'package:uuid/uuid.dart';

/// The session a file controller reads: an id, a session id, the peer's
/// version and platform, and the file model holding both sides. Anything
/// else fails loudly through noSuchMethod.
class NikoTestFileFFI implements FFI {
  @override
  String id = '418223905';
  @override
  UuidValue get sessionId => UuidValue('00000000-0000-0000-0000-000000000000');
  @override
  late final FfiModel ffiModel = FfiModel(WeakReference(this))
    ..pi.version = '1.4.0'
    ..pi.platform = 'Mac OS';
  @override
  late FileModel fileModel;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The two sides of a test session's file model.
class NikoTestFileModel implements FileModel {
  @override
  final FileController localController;
  @override
  final FileController remoteController;
  NikoTestFileModel(this.localController, this.remoteController);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A file controller on [path] holding [entries] as (name, type, size), each
/// modified a day before the one above it.
FileController nikoTestFileController(NikoTestFileFFI ffi, JobController jobs,
    {required bool local,
    required String path,
    List<(String, int, int)> entries = const []}) {
  final modified =
      DateTime(2026, 10, 21, 14, 32).millisecondsSinceEpoch ~/ 1000;
  final controller = FileController(
      isLocal: local,
      getSessionID: () => ffi.sessionId,
      rootState: WeakReference(ffi),
      jobController: jobs,
      fileFetcher: FileFetcher(() => ffi.sessionId),
      getOtherSideDirectoryData: () =>
          DirectoryData(FileDirectory(), DirectoryOptions()));
  controller.options.value = DirectoryOptions(home: path);
  controller.directory.value = FileDirectory()
    ..path = path
    ..entries = [
      for (final (index, (name, type, size)) in entries.indexed)
        Entry()
          ..name = name
          ..entryType = type
          ..size = size
          ..modifiedTime = modified - index * 86400
    ]
    ..format(false);
  return controller;
}

class NikoTestMobileFilePage extends StatefulWidget {
  final bool selecting;

  /// Receives the value of the actions menu item chosen.
  final ValueChanged<String>? onAction;

  /// The session's task list; a fresh one without a bridge by default.
  final JobController Function(NikoTestFileFFI ffi)? jobs;
  const NikoTestMobileFilePage(
      {super.key, this.selecting = false, this.onAction, this.jobs});
  @override
  State<NikoTestMobileFilePage> createState() => NikoTestMobileFilePageState();
}

class NikoTestMobileFilePageState extends State<NikoTestMobileFilePage> {
  final _ffi = NikoTestFileFFI();
  final selectMode = SelectMode.none.obs;
  late final jobs = widget.jobs?.call(_ffi) ??
      JobController(() => _ffi.sessionId, () => null);
  late final local = nikoTestFileController(_ffi, jobs,
      local: true,
      path: '/var/mobile/Documents',
      entries: [
        ('Inbox', 0, 0),
        ('Screenshots', 0, 0),
        ('Quarterly report.pdf', 4, 2516582),
        ('IMG_2041.HEIC', 4, 3355443),
        ('notes.md', 4, 6144),
      ]);
  late final remote = nikoTestFileController(_ffi, jobs,
      local: false,
      path: '/Users/demo/Desktop',
      entries: [
        ('Builds', 0, 0),
        ('Shared', 0, 0),
        ('build.log', 4, 48213),
        ('NikoDesk-2.1.0.dmg', 4, 62914560),
      ]);
  int _pane = 0;
  bool _localActive = true;

  @override
  void initState() {
    super.initState();
    _ffi.fileModel = NikoTestFileModel(local, remote);
    if (widget.selecting) {
      selectMode.value = SelectMode.local;
      final entries = local.directory.value.entries;
      local.selectedItems.add(entries[2]);
      local.selectedItems.add(entries[3]);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(
          leading: Row(children: [
            nikoMobileIconButton(
                context,
                IconButton(
                    icon: const Icon(Icons.close),
                    tooltip: nikoText('关闭文件会话', 'Close file session'),
                    onPressed: () {})),
          ]),
          centerTitle: true,
          title: Text(nikoText('文件传输', 'File transfer')),
          actions: [
            nikoMobileActionsMenu(
                context,
                PopupMenuButton<String>(
                    tooltip: nikoText('文件操作', 'File actions'),
                    icon: const Icon(Icons.more_vert),
                    itemBuilder: (context) => [
                          // The page's items off Android, with its labels.
                          for (final (value, icon, label) in [
                            (
                              'refresh',
                              Icons.refresh,
                              nikoText('刷新文件', 'Refresh File')
                            ),
                            (
                              'select',
                              Icons.check,
                              nikoText('多选', 'Multi Select')
                            ),
                            (
                              'folder',
                              Icons.folder_outlined,
                              nikoText('创建文件夹', 'Create Folder')
                            ),
                            (
                              'hidden',
                              Icons.check_box_outline_blank,
                              nikoText('显示隐藏文件', 'Show Hidden Files')
                            ),
                          ])
                            PopupMenuItem(
                                value: value,
                                child: Row(children: [
                                  Icon(icon),
                                  const SizedBox(width: 5),
                                  Flexible(child: Text(label)),
                                ])),
                        ],
                    onSelected: widget.onAction),
                header: nikoMobileMenuSide(context, _localActive)),
          ]),
      body: Column(children: [
        NikoAppFileAreaNotice(
            showGuide:
                (_localActive || nikoMobileFileSplit(context)) && _pane != 2,
            onDismiss: () {}),
        Expanded(
            child: NikoMobileFileArea(
                pane: _pane,
                localActive: _localActive,
                onPaneChanged: (pane) => setState(() {
                      _pane = pane;
                      if (pane < 2) _localActive = pane == 0;
                    }),
                selecting: () => selectMode.value == SelectMode.none
                    ? null
                    : selectMode.value == SelectMode.local,
                localController: local,
                remoteController: remote,
                jobs: jobs.jobTable,
                local:
                    FileManagerView(controller: local, selectMode: selectMode),
                remote:
                    FileManagerView(controller: remote, selectMode: selectMode),
                tasks: NikoFileTasks(controller: jobs))),
      ]),
      // Both sides showing: the page's selection bar for them, as it
      // builds it off Android.
      bottomSheet: nikoMobileFileSplit(context)
          ? Obx(() {
              if (selectMode.value == SelectMode.none || _pane == 2) {
                return const SizedBox.shrink();
              }
              final chosenLocal = selectMode.value.eq(true);
              return nikoSplitSelectionBar(context,
                      source: chosenLocal ? local : remote,
                      destination: chosenLocal ? remote : local,
                      onDone: () =>
                          setState(() => selectMode.value = SelectMode.none)) ??
                  const SizedBox.shrink();
            })
          : widget.selecting
              ? BottomSheetBody(
                  leading: const Icon(Icons.check),
                  title: nikoText('已选择', 'Selected'),
                  text: nikoText('2 项 [本机]', '2 items [Local]'),
                  onCanceled: () {},
                  actions: [
                      IconButton(
                          icon: const Icon(Icons.compare_arrows),
                          tooltip:
                              nikoText('切换目标文件区', 'Switch destination area'),
                          onPressed: () {}),
                      IconButton(
                          icon: const Icon(Icons.delete_forever),
                          tooltip: nikoText('删除所选文件', 'Delete selected files'),
                          onPressed: () {}),
                    ])
              : null);
}
