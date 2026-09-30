import 'dart:async';
import 'dart:io';

import 'package:flutter_hbb/generated_bridge.dart';
import 'package:flutter_hbb/models/file_model.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/nikodesk/file_directory_transfer.dart';
import 'package:flutter_hbb/nikodesk/file_drop.dart';
import 'package:flutter_hbb/nikodesk/file_transfer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

final _session = UuidValue('00000000-0000-4000-8000-000000000001');
final _otherSession = UuidValue('00000000-0000-4000-8000-000000000002');
final _scope = 'a' * 64;

class _FileFfiDouble implements FFI {
  @override
  UuidValue get sessionId => _session;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

NikoTransferContext _context(
        {String? scope,
        String peer = '1000000001',
        UuidValue? session,
        int connection = 1,
        bool ready = true,
        bool allowed = true}) =>
    NikoTransferContext(
        sessionId: (session ?? _session).toString(),
        namespace: scope ?? _scope,
        peerId: peer,
        connection: connection,
        ready: ready,
        fileAllowed: allowed);

NikoTransferRequest _request({bool download = false}) => NikoTransferRequest(
    context: _context(),
    source: download ? '/remote/source' : '/app/source',
    destination: download ? '/app/destination' : '/remote/destination',
    remoteToLocal: download,
    includeHidden: true,
    isDirectory: false,
    size: 240,
    sourceWindows: false,
    destinationWindows: false,
    destinationExisted: false);

JobProgress _job(int id, {JobState state = JobState.error}) => JobProgress()
  ..id = id
  ..type = JobType.transfer
  ..state = state
  ..err = 'disk full';

// Explicit bridge double: this never initializes FFI, connects a peer or uses SAF.
class _TransferBridge implements Rustdesk {
  final sent = <Map<String, Object>>[];
  final cancelled = <int>[];
  bool failSend = false;
  bool failCancel = false;
  Completer<void>? pendingSend;
  Completer<void>? pendingCancel;
  Future<void> Function(int)? onSend;
  Future<void> Function(int, String, bool)? onCreate;
  final created = <Map<String, Object>>[];

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
      dynamic hint}) async {
    sent.add({
      'session': sessionId.toString(),
      'id': actId,
      'path': path,
      'to': to,
      'fileNum': fileNum,
      'hidden': includeHidden,
      'remote': isRemote,
      'directory': isDir
    });
    if (failSend) throw StateError('synthetic dispatch failure');
    await onSend?.call(actId);
    await pendingSend?.future;
  }

  @override
  Future<void> sessionCreateDir(
      {required UuidValue sessionId,
      required int actId,
      required String path,
      required bool isRemote,
      dynamic hint}) async {
    expect(sessionId, _session);
    created.add({'id': actId, 'path': path, 'remote': isRemote});
    await onCreate?.call(actId, path, isRemote);
  }

  @override
  Future<void> sessionCancelJob(
      {required UuidValue sessionId, required int actId, dynamic hint}) async {
    expect(sessionId, _session);
    cancelled.add(actId);
    if (failCancel) throw StateError('synthetic dispatch failure');
    await pendingCancel?.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late _TransferBridge bridge;
  late JobController controller;
  NikoTransferContext? current;
  var next = 20;
  setUp(() {
    bridge = _TransferBridge();
    current = _context();
    next = 20;
    controller = JobController(() => _session, () => null,
        nikoBridge: bridge, nikoNextId: () => ++next)
      ..nikoContext = () => current;
    controller.jobTable.add(_job(10));
    controller.niko.capture(10, _request());
  });

  test(
      'production OS drop boundary sends local files and folders to the captured remote destination',
      () async {
    final temporary = await Directory.systemTemp.createTemp('nikodesk-drop-');
    addTearDown(() => temporary.delete(recursive: true));
    final file =
        await File('${temporary.path}/source.txt').writeAsString('content');
    final folder = await Directory('${temporary.path}/folder').create();
    final target = DirectoryData(FileDirectory()..path = '/remote/original',
        DirectoryOptions()..isWindows = false);
    final request = nikoSendLocalDrop(
        droppedOnLocal: false,
        files: [
          NikoDroppedFile(file.path, 'source.txt'),
          NikoDroppedFile(folder.path, 'folder')
        ],
        destination: target,
        capturedContext: _context(),
        currentContext: _context,
        send: (items, destination) async {
          expect(items.isLocal, isTrue);
          expect(
              items.items.map((item) => item.path), [file.path, folder.path]);
          expect(items.items.first.isFile, isTrue);
          expect(items.items.first.size, 7);
          expect(items.items.last.isDirectory, isTrue);
          expect(destination.directory.path, '/remote/original');
          expect(destination.options.isWindows, isFalse);
        });
    target.directory.path = '/remote/browsed-later';
    target.options.isWindows = true;
    await request;
  });

  test(
      'production OS drop boundary ignores local pane and rejects stale sessions or unreadable sources',
      () async {
    final target =
        DirectoryData(FileDirectory()..path = '/remote', DirectoryOptions());
    var sent = 0;
    await nikoSendLocalDrop(
        droppedOnLocal: true,
        files: const [],
        destination: target,
        capturedContext: null,
        currentContext: () => null,
        send: (_, __) async {
          sent++;
        });
    await expectLater(
        nikoSendLocalDrop(
            droppedOnLocal: false,
            files: const [],
            destination: target,
            capturedContext: _context(),
            currentContext: () => _context(connection: 2),
            send: (_, __) async {
              sent++;
            }),
        throwsStateError);
    final temporary =
        await Directory.systemTemp.createTemp('nikodesk-drop-missing-');
    addTearDown(() => temporary.delete(recursive: true));
    await expectLater(
        nikoSendLocalDrop(
            droppedOnLocal: false,
            files: [NikoDroppedFile('${temporary.path}/missing', 'missing')],
            destination: target,
            capturedContext: _context(),
            currentContext: _context,
            send: (_, __) async {
              sent++;
            }),
        throwsStateError);
    expect(sent, 0);
    final realFile =
        await File('${temporary.path}/source').writeAsString('content');
    var checks = 0;
    await expectLater(
        nikoSendLocalDrop(
            droppedOnLocal: false,
            files: [NikoDroppedFile(realFile.path, 'source')],
            destination: target,
            capturedContext: _context(),
            currentContext: () =>
                ++checks < 3 ? _context() : _context(connection: 2),
            send: (_, __) async {
              sent++;
            }),
        throwsStateError);
    expect(sent, 0);
  });

  for (final download in [false, true]) {
    test(
        'production resend hook retains ${download ? 'download' : 'upload'} request and starts a fresh task',
        () async {
      final request = _request(download: download);
      controller.niko.capture(10, request);
      controller.registerTransferConflictBatch([10, 11]);
      controller.rememberTransferConflictBatch(10, true);
      expect(await controller.nikoResendJob(10), isTrue);
      expect(bridge.sent.single, {
        'session': _session.toString(),
        'id': 21,
        'path': request.source,
        'to': request.destination,
        'fileNum': 0,
        'hidden': true,
        'remote': download,
        'directory': false
      });
      expect(controller.jobTable.map((j) => j.id), [10, 21]);
      expect(controller.jobTable.first.state, JobState.error);
      final added = controller.jobTable.last;
      expect(added.finishedSize, 0);
      expect(added.recvJobRes, isFalse);
      expect(added.totalSize, 240);
      expect(added.isRemoteToLocal, download);
      expect(controller.transferConflictBatchId(21),
          isNot(controller.transferConflictBatchId(10)));
      expect(
          controller.isTransferConflictRememberBatch(
              controller.transferConflictBatchId(21)),
          isFalse);
    });
  }

  test('relative source or destination cannot become a dispatchable transfer',
      () async {
    for (final relativeSource in [false, true]) {
      final request = NikoTransferRequest(
          context: _context(),
          source: relativeSource ? 'relative/source' : '/source',
          destination: relativeSource ? '/destination' : 'relative/destination',
          remoteToLocal: false,
          includeHidden: true,
          isDirectory: false,
          size: 0,
          sourceWindows: false,
          destinationWindows: false,
          destinationExisted: false);
      controller.niko.remove(10);
      controller.niko.capture(10, request);
      expect(controller.niko.request(10), isNull);
      expect(await controller.nikoResendJob(10), isFalse);
    }
    expect(bridge.sent, isEmpty);
  });

  for (final changed in <String, NikoTransferContext?>{
    'same peer on another server': _context(scope: 'b' * 64),
    'another peer on the same server': _context(peer: '1000000002'),
    'another session': _context(session: _otherSession),
    'a reauthenticated connection': _context(connection: 2),
    'disconnected': _context(ready: false),
    'file permission revoked': _context(allowed: false),
    'no captured identity': null,
  }.entries) {
    test('resend never dispatches after ${changed.key}', () async {
      current = changed.value;
      expect(await controller.nikoResendJob(10), isFalse);
      expect(bridge.sent, isEmpty);
      expect(controller.jobTable, hasLength(1));
    });
  }

  test(
      'old paused tasks, incomplete requests and non-transfer errors cannot resend',
      () async {
    for (final job in [
      JobProgress()
        ..id = 11
        ..type = JobType.transfer
        ..state = JobState.paused,
      _job(12),
      _job(13)..type = JobType.deleteFile
    ]) {
      controller.jobTable.add(job);
      expect(await controller.nikoResendJob(job.id), isFalse);
    }
    expect(bridge.sent, isEmpty);
  });

  test(
      'invalid or unready captured identity never becomes a restartable request',
      () {
    final ledger = NikoFileTransferLedger();
    for (final context in [
      _context(scope: '../scope'),
      _context(ready: false),
      _context(allowed: false),
      _context(peer: '')
    ]) {
      ledger.capture(
          1,
          NikoTransferRequest(
              context: context,
              source: '/source',
              destination: '/dest',
              remoteToLocal: false,
              includeHidden: false,
              isDirectory: false,
              size: 1));
      expect(ledger.request(1), isNull);
    }
  });

  test('folder retry is explicit about the unrecorded empty-directory phase',
      () async {
    controller.niko.capture(
        10,
        NikoTransferRequest(
            context: _context(),
            source: '/app/folder',
            destination: '/remote/folder',
            remoteToLocal: false,
            includeHidden: true,
            isDirectory: true,
            size: 0));
    expect(controller.nikoRetryBlock(controller.jobTable.first),
        NikoRetryBlock.directoryNeedsSelection);
    expect(await controller.nikoResendJob(10), isFalse);
    expect(bridge.sent, isEmpty);
  });

  test('repeated clicks create only one new request while dispatch is pending',
      () async {
    bridge.pendingSend = Completer<void>();
    final first = controller.nikoResendJob(10);
    expect(controller.nikoRetryBlock(controller.jobTable.first),
        NikoRetryBlock.busy);
    expect(await controller.nikoResendJob(10), isFalse);
    expect(bridge.sent, hasLength(1));
    bridge.pendingSend!.complete();
    expect(await first, isTrue);
  });

  test('a failed new dispatch retains both errors without claiming progress',
      () async {
    bridge.failSend = true;
    expect(await controller.nikoResendJob(10), isFalse);
    expect(controller.jobTable, hasLength(2));
    expect(controller.jobTable.last.state, JobState.error);
    expect(controller.jobTable.last.finishedSize, 0);
    expect(controller.jobTable.last.err, contains('could not be sent'));
  });

  test('new ID collision does not overwrite an existing task', () async {
    controller.jobTable.add(_job(21));
    expect(await controller.nikoResendJob(10), isFalse);
    expect(bridge.sent, isEmpty);
    expect(controller.jobTable.map((job) => job.id), [10, 21]);
  });

  test('single-task cancel is only a request and never clears sibling tasks',
      () async {
    controller.jobTable.first.state = JobState.inProgress;
    controller.jobTable.add(_job(11, state: JobState.inProgress));
    bridge.pendingCancel = Completer<void>();
    final cancel = controller.nikoCancelJob(10);
    expect(controller.niko.cancellation(10), NikoCancelState.requesting);
    await controller.nikoCancelJob(10);
    expect(bridge.cancelled, [10]);
    expect(controller.jobTable.map((job) => job.id), [10, 11]);
    bridge.pendingCancel!.complete();
    await cancel;
    expect(controller.niko.cancellation(10), NikoCancelState.requested);
    expect(controller.jobTable.first.state, JobState.inProgress);
    expect(controller.niko.cancellation(11), NikoCancelState.none);
    controller.nikoRemoveRecord(10);
    expect(controller.jobTable.map((job) => job.id), [11]);
    controller.nikoRemoveRecord(11);
    expect(controller.jobTable.map((job) => job.id), [11]);
  });

  test('cancel dispatch failure is visible and may be requested again',
      () async {
    bridge.failCancel = true;
    await controller.nikoCancelJob(10);
    expect(controller.niko.cancellation(10), NikoCancelState.failed);
    expect(await controller.nikoResendJob(10), isFalse);
    bridge.failCancel = false;
    await controller.nikoCancelJob(10);
    expect(bridge.cancelled, [10, 10]);
    expect(controller.niko.cancellation(10), NikoCancelState.requested);
    await controller.nikoCancelJob(999);
    expect(bridge.cancelled, [10, 10]);
  });

  test(
      'scope or permission changed during record creation stops native dispatch',
      () async {
    for (final changed in [
      _context(scope: 'b' * 64),
      _context(allowed: false)
    ]) {
      final ledger = NikoFileTransferLedger()..capture(1, _request());
      var actual = _context();
      var sent = 0;
      await expectLater(
          ledger.resend(1,
              failed: true,
              current: () => actual,
              nextId: () => 2,
              add: (_, __) => actual = changed,
              send: (_, __) async {
                sent++;
              },
              refresh: () {}),
          throwsStateError);
      expect(sent, 0);
    }
  });

  for (final cancel in [false, true]) {
    test(
        'original request ${cancel ? 'cancelled' : 'removed'} during addition cannot dispatch a new job',
        () async {
      final ledger = NikoFileTransferLedger()..capture(1, _request());
      var sent = 0;
      await expectLater(
          ledger.resend(1,
              failed: true,
              current: _context,
              nextId: () => 2,
              add: (_, __) {
                if (cancel) {
                  unawaited(ledger.cancel(1, (_) async {}, () {}));
                } else {
                  ledger.remove(1);
                }
              },
              send: (_, __) async {
                sent++;
              },
              refresh: () {}),
          throwsStateError);
      expect(sent, 0);
    });
  }

  if (const bool.fromEnvironment('NIKODESK')) {
    test(
        'production batch captures every source and destination before the first native await',
        () async {
      final first = Entry()
        ..path = '/app/a'
        ..name = 'a'
        ..size = 4;
      final second = Entry()
        ..path = '/app/b'
        ..name = 'b'
        ..size = 8;
      final selected = SelectedItems(isLocal: true)
        ..add(first)
        ..add(second);
      final targetDirectory = FileDirectory()
        ..path = '/remote'
        ..entries = [
          Entry()
            ..name = 'b'
            ..entryType = 4
        ];
      final targetOptions = DirectoryOptions(showHidden: true);
      final target = DirectoryData(targetDirectory, targetOptions);
      final fileController = FileController(
          isLocal: true,
          getSessionID: () => _session,
          rootState: WeakReference<FFI>(_FileFfiDouble()),
          jobController: controller,
          fileFetcher: FileFetcher(() => _session),
          getOtherSideDirectoryData: () => target);
      bridge.onSend = (id) async {
        if (id == 21) {
          second.path = '/app/browsed-later';
          second.name = 'renamed';
          second.size = 99;
          targetDirectory.path = '/remote/browsed-later';
          targetDirectory.entries.clear();
          targetOptions.isWindows = true;
          targetOptions.showHidden = false;
          fileController.options.value.showHidden = true;
          selected.clear();
        }
      };
      await fileController.sendFiles(selected, target);
      expect(bridge.sent, hasLength(2));
      expect(bridge.sent.last['path'], '/app/b');
      expect(bridge.sent.last['to'], '/remote/b');
      expect(bridge.sent.last['hidden'], isFalse);
      expect(bridge.sent.last['remote'], isFalse);
      expect(controller.niko.request(22)?.size, 8);
      expect(controller.niko.request(22)?.destinationExisted, isTrue);
      expect(controller.niko.request(22)?.destinationWindows, isFalse);
    });
    for (final issue in [
      NikoFolderIssue.sourceChanged,
      NikoFolderIssue.destinationChanged
    ]) {
      test('production single-file probe rejects ${issue.name} before dispatch',
          () async {
        controller.nikoRequestProbe = (_, request) async {
          expect(request.source, '/app/source');
          expect(request.destination, '/remote/destination');
          throw NikoFolderFailure(issue);
        };
        expect(await controller.nikoResendJob(10), isFalse);
        expect(bridge.sent, isEmpty);
        expect(controller.niko.failure(21), issue);
        expect(controller.jobTable.last.state, JobState.error);
        expect(controller.jobTable.first.err, 'disk full');
      });
    }
    NikoTransferRequest folderRequest() => NikoTransferRequest(
        context: _context(),
        source: '/source/folder',
        destination: '/target/folder',
        remoteToLocal: false,
        includeHidden: true,
        isDirectory: true,
        size: 0,
        sourceWindows: false,
        destinationWindows: false,
        destinationWasDirectory: false,
        destinationExisted: false);

    void folderHook({Future<List<String>> Function()? read}) {
      controller.nikoFolderTransfer = (id, request, send) =>
          NikoDirectoryTransfer(
                  probe: (_) async {},
                  readEmptyDirectories: (_) =>
                      read?.call() ??
                      Future.value(['/source/folder/a', '/source/folder/b']),
                  createDirectory: (target) =>
                      controller.nikoCreateDirectory(id, request, target),
                  blocked: () => controller.nikoFolderBlocked(id, request),
                  progress: (progress) =>
                      controller.niko.updateFolder(id, progress))
              .send(request, send);
      controller.niko.capture(10, folderRequest());
      controller.niko.updateFolder(
          10,
          const NikoFolderProgress(NikoFolderState.failed,
              issue: NikoFolderIssue.nativeError));
    }

    test(
        'production folder resend waits for matching native IDs and retains captured destinations',
        () async {
      folderHook();
      bridge.onSend = (id) async {
        await controller.jobDone({'id': '$id', 'file_num': '0'});
      };
      bridge.onCreate = (id, _, __) async {
        await controller.jobDone({'id': '$id', 'file_num': '-1'});
      };
      expect(await controller.nikoResendJob(10), isTrue);
      expect(bridge.sent.single['to'], '/target/folder');
      expect(bridge.sent.single['fileNum'], 0);
      expect(bridge.created, [
        {'id': 22, 'path': '/target/folder/a', 'remote': true},
        {'id': 23, 'path': '/target/folder/b', 'remote': true}
      ]);
      expect(controller.niko.folder(21)?.state, NikoFolderState.confirmed);
      expect(controller.niko.folder(21)?.confirmed, 2);
      expect(controller.jobTable.last.state, JobState.done);
      expect(controller.jobTable.first.state, JobState.error);
    });

    test('cancel during a production folder listing prevents all late sends',
        () async {
      final listing = Completer<List<String>>();
      folderHook(read: () => listing.future);
      final resend = controller.nikoResendJob(10);
      await Future<void>.delayed(Duration.zero);
      await controller.nikoCancelJob(21);
      listing.complete(['/source/folder/a']);
      expect(await resend, isFalse);
      expect(bridge.sent, isEmpty);
      expect(bridge.created, isEmpty);
      expect(bridge.cancelled, [21]);
      expect(controller.niko.folder(21)?.issue, NikoFolderIssue.cancelled);
    });

    test('native file completion cannot confirm an unacknowledged folder phase',
        () async {
      controller = JobController(() => _session, () => null,
          nikoBridge: bridge,
          nikoNextId: () => ++next,
          nikoDirectoryTimeout: const Duration(milliseconds: 5))
        ..nikoContext = () => current;
      controller.jobTable.add(_job(10));
      folderHook();
      bridge.onSend = (id) async {
        await controller.jobDone({'id': '$id', 'file_num': '0'});
      };
      expect(await controller.nikoResendJob(10), isFalse);
      expect(controller.jobTable.last.state, JobState.done);
      expect(controller.niko.folder(21)?.state, NikoFolderState.unconfirmed);
      expect(controller.niko.folder(21)?.confirmed, 0);
      expect(bridge.created, hasLength(1));
      expect(controller.nikoRetryBlock(controller.jobTable.last), isNull);
      // A late directory reply is consumed by its old ID, not another global job listener.
      final unrelated = controller.jobResultListener.start();
      final failure = expectLater(unrelated, throwsA('Cancel manually'));
      await controller.jobDone({'id': '22', 'file_num': '-1'});
      expect(controller.jobResultListener.isListening, isTrue);
      expect(controller.niko.folder(21)?.state, NikoFolderState.unconfirmed);
      controller.jobResultListener.clear();
      await failure;
    });

    test('initial production dispatch failure becomes a real task error',
        () async {
      controller.jobTable.first.state = JobState.none;
      bridge.failSend = true;
      expect(await controller.nikoSendInitial(10), isFalse);
      expect(controller.jobTable.first.state, JobState.error);
      expect(controller.jobTable.first.err, contains('could not be sent'));
      expect(controller.jobTable.first.finishedSize, 0);
    });

    test(
        'cancel conflict batch sends only its active jobs, preserving other tasks',
        () async {
      controller.jobTable.first.state = JobState.inProgress;
      controller.jobTable.addAll([
        _job(11, state: JobState.inProgress),
        _job(12, state: JobState.done),
        _job(13, state: JobState.inProgress)
      ]);
      controller.registerTransferConflictBatch([10, 11, 12]);
      controller.registerTransferConflictBatch([13]);
      await controller.cancelTransferConflictBatch(10);
      expect(bridge.cancelled, [10, 11]);
      expect(controller.jobTable, hasLength(4));
      expect(controller.jobTable.first.state, JobState.inProgress);
      expect(controller.niko.cancellation(13), NikoCancelState.none);
    });
  }
}
