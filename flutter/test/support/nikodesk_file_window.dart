// The desktop file window body as FileManagerPage builds it in the NikoDesk
// build, on real file controllers with fixed directories and three tasks:
// one sending, one finished, one failed that can be resent. No session or
// native call is made; install NikoFakeBridge before pumping it.
import 'package:flutter/material.dart';
import 'package:flutter_hbb/desktop/pages/file_manager_page.dart'
    show FileManagerView, MouseFocusScope;
import 'package:flutter_hbb/models/file_model.dart';
import 'package:flutter_hbb/models/model.dart' show FFI;
import 'package:flutter_hbb/nikodesk/file_tasks.dart';
import 'package:flutter_hbb/nikodesk/file_transfer.dart';
import 'package:get/get.dart';
import 'package:uuid/uuid.dart';

class _FileFFI implements FFI {
  @override
  String id = '418223905';
  @override
  UuidValue get sessionId => UuidValue('00000000-0000-0000-0000-000000000000');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class NikoTestFileWindow extends StatefulWidget {
  final bool withJobs;
  const NikoTestFileWindow({super.key, this.withJobs = true});
  @override
  State<NikoTestFileWindow> createState() => _NikoTestFileWindowState();
}

class _NikoTestFileWindowState extends State<NikoTestFileWindow> {
  final _ffi = _FileFFI();
  final _focus = Rx<MouseFocusScope>(MouseFocusScope.none);
  late final _jobs = JobController(() => _ffi.sessionId, () => null);
  late final _local = _files(true, '/Users/demo/Documents', [
    ('Invoices', 0, 0),
    ('Projects', 0, 0),
    ('Screenshots', 0, 0),
    ('Quarterly report.pdf', 4, 2516582),
    ('notes.md', 4, 6144),
    ('roadmap-2027.key', 4, 18874368),
  ]);
  late final _remote = _files(false, r'C:\Users\demo\Desktop', [
    ('Builds', 0, 0),
    ('Shared', 0, 0),
    ('build.log', 4, 48213),
    ('setup-1.0.11.exe', 4, 31457280),
  ], windows: true);

  FileController _files(bool local, String path, List<(String, int, int)> list,
      {bool windows = false}) {
    final modified =
        DateTime(2026, 10, 21, 14, 32).millisecondsSinceEpoch ~/ 1000;
    final controller = FileController(
        isLocal: local,
        getSessionID: () => _ffi.sessionId,
        rootState: WeakReference(_ffi),
        jobController: _jobs,
        fileFetcher: FileFetcher(() => _ffi.sessionId),
        getOtherSideDirectoryData: () =>
            DirectoryData(FileDirectory(), DirectoryOptions()));
    controller.options.value = DirectoryOptions(home: path, isWindows: windows);
    controller.directory.value = FileDirectory()
      ..path = path
      ..entries = [
        for (final (index, (name, type, size)) in list.indexed)
          Entry()
            ..name = name
            ..entryType = type
            ..size = size
            ..modifiedTime = modified - index * 86400
      ]
      ..format(windows);
    return controller;
  }

  @override
  void initState() {
    super.initState();
    const context = NikoTransferContext(
        sessionId: 'shot',
        namespace:
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        peerId: '418223905',
        connection: 1,
        ready: true,
        fileAllowed: true);
    _jobs.nikoContext = () => context;
    _local.selectedItems.add(_local.directory.value.entries[3]);
    if (!widget.withJobs) return;
    _jobs.jobTable.addAll([
      JobProgress()
        ..id = 1
        ..type = JobType.transfer
        ..state = JobState.inProgress
        ..recvJobRes = true
        ..jobName = '/Users/demo/Documents/Quarterly report.pdf'
        ..fileName = 'Quarterly report.pdf'
        ..finishedSize = 1572864
        ..totalSize = 2516582
        ..speed = 845200,
      JobProgress()
        ..id = 2
        ..type = JobType.transfer
        ..state = JobState.done
        ..jobName = r'C:\Users\demo\Desktop\build.log'
        ..fileName = 'build.log'
        ..finishedSize = 48213
        ..totalSize = 48213
        ..isRemoteToLocal = true,
      JobProgress()
        ..id = 3
        ..type = JobType.transfer
        ..state = JobState.error
        ..jobName = '/Users/demo/Documents/roadmap-2027.key'
        ..fileName = 'roadmap-2027.key'
        ..err = 'Not enough space on the destination disk'
        ..finishedSize = 9437184
        ..totalSize = 18874368,
    ]);
    for (final (id, name, size) in [
      (1, 'Quarterly report.pdf', 2516582),
      (3, 'roadmap-2027.key', 18874368),
    ]) {
      _jobs.niko.capture(
          id,
          NikoTransferRequest(
              context: context,
              source: '/Users/demo/Documents/$name',
              destination: 'C:\\Users\\demo\\Desktop\\$name',
              remoteToLocal: false,
              includeHidden: false,
              isDirectory: false,
              size: size,
              sourceWindows: false,
              destinationWindows: true,
              destinationExisted: false));
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: NikoFileWorkspace(
          local: FileManagerView(_local, _ffi, _focus),
          remote: FileManagerView(_remote, _ffi, _focus),
          tasks: NikoFileTasks(controller: _jobs),
          jobs: _jobs.jobTable));
}

