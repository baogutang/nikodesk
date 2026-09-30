import 'dart:async';
import 'dart:convert';

import 'package:flutter_hbb/models/file_model.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/nikodesk/file_directory_transfer.dart';
import 'package:flutter_hbb/nikodesk/file_transfer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

final _session = UuidValue('00000000-0000-4000-8000-000000000003');

class _FileFfiDouble implements FFI {
  @override
  UuidValue get sessionId => _session;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

NikoTransferRequest _folder(
        {bool sourceWindows = false, bool targetWindows = false}) =>
    NikoTransferRequest(
        context: NikoTransferContext(
            sessionId: _session.toString(),
            namespace: 'a' * 64,
            peerId: '1000000001',
            connection: 1,
            ready: true,
            fileAllowed: true),
        source: sourceWindows ? r'C:\source\folder' : '/source/folder',
        destination: targetWindows ? r'D:\target\folder' : '/target/folder',
        remoteToLocal: false,
        includeHidden: true,
        isDirectory: true,
        size: 0,
        sourceWindows: sourceWindows,
        destinationWindows: targetWindows,
        destinationWasDirectory: false,
        destinationExisted: false);

void main() {
  test(
      'unconfirmed-path guard has bounded memory and refuses all paths at its limit',
      () {
    final guard = NikoEmptyDirectoryReadGuard(maxRetiredPaths: 2);
    guard.retire(['/one', '/two']);
    expect(guard.retired('/one'), isTrue);
    expect(guard.retired('/three'), isFalse);
    guard.retire(['/three']);
    expect(guard.retired('/fresh'), isTrue);
    expect(guard.retiredCount, lessThanOrEqualTo(2));
  });

  test(
      'unconfirmed directory reads require reopening the file session before retry',
      () {
    final request = _folder();
    final ledger = NikoFileTransferLedger()..capture(1, request);
    ledger.updateFolder(
        1,
        const NikoFolderProgress(NikoFolderState.unconfirmed,
            issue: NikoFolderIssue.readUnconfirmed));
    expect(ledger.retryBlock(1, true, request.context),
        NikoRetryBlock.readUnconfirmed);
  });
  test(
      'empty directory mapping keeps the captured root across Windows and POSIX',
      () {
    expect(
        nikoEmptyDirectoryDestinations(_folder(), [
          '/source/folder',
          '/source/folder/a/empty',
          '/source/folder/a/empty'
        ]),
        ['/target/folder', '/target/folder/a/empty']);
    expect(
        nikoEmptyDirectoryDestinations(_folder(sourceWindows: true),
            [r'C:\source\folder', r'C:\source\folder\a\empty']),
        ['/target/folder', '/target/folder/a/empty']);
    expect(
        nikoEmptyDirectoryDestinations(
            _folder(targetWindows: true), ['/source/folder/empty']),
        [r'D:\target\folder\empty']);
  });

  for (final invalid in [
    '/source/another',
    '/source/folder/../../outside',
    'relative/folder',
    '/source/folder-sibling/empty'
  ]) {
    test('out-of-root response is rejected before all side effects: $invalid',
        () async {
      final sent = <String>[];
      final progress = <NikoFolderProgress>[];
      await expectLater(
          NikoDirectoryTransfer(
                  probe: (_) async {},
                  readEmptyDirectories: (_) async =>
                      ['/source/folder/valid', invalid],
                  createDirectory: (target) async {
                    sent.add(target);
                    return NikoFileReceipt.confirmed;
                  },
                  blocked: () => null,
                  progress: progress.add)
              .send(_folder(), () async {
            sent.add('file send');
          }),
          throwsA(isA<NikoFolderFailure>()));
      expect(sent, isEmpty);
      expect(progress.last.issue, NikoFolderIssue.invalidPaths);
    });
  }

  for (final issue in [
    NikoFolderIssue.sessionChanged,
    NikoFolderIssue.disconnected,
    NikoFolderIssue.permission,
    NikoFolderIssue.cancelled
  ]) {
    test(
        'late listing after ${issue.name} cannot send files or create directories',
        () async {
      final pending = Completer<List<String>>();
      NikoFolderIssue? blocked;
      var sent = 0;
      var creates = 0;
      final progress = <NikoFolderProgress>[];
      final request = NikoDirectoryTransfer(
              probe: (_) async {},
              readEmptyDirectories: (_) => pending.future,
              createDirectory: (_) async {
                creates++;
                return NikoFileReceipt.confirmed;
              },
              blocked: () => blocked,
              progress: progress.add)
          .send(_folder(), () async {
        sent++;
      });
      final result = expectLater(request, throwsA(isA<NikoFolderFailure>()));
      await Future<void>.delayed(Duration.zero);
      blocked = issue;
      pending.complete(['/source/folder/empty']);
      await result;
      expect(sent, 0);
      expect(creates, 0);
      expect(progress.last.state, NikoFolderState.blocked);
      expect(progress.last.issue, issue);
    });
  }

  test(
      'source or destination type change during listing stops the whole new request',
      () async {
    for (final issue in [
      NikoFolderIssue.sourceChanged,
      NikoFolderIssue.destinationChanged
    ]) {
      var probes = 0;
      var sends = 0;
      final progress = <NikoFolderProgress>[];
      await expectLater(
          NikoDirectoryTransfer(
                  probe: (_) async {
                    if (++probes > 1) throw NikoFolderFailure(issue);
                  },
                  readEmptyDirectories: (_) async => ['/source/folder/empty'],
                  createDirectory: (_) async => NikoFileReceipt.confirmed,
                  blocked: () => null,
                  progress: progress.add)
              .send(_folder(), () async {
            sends++;
          }),
          throwsA(isA<NikoFolderFailure>()));
      expect(sends, 0);
      expect(progress.last.issue, issue);
    }
  });

  test('directory changes between acknowledgements stop subsequent creation',
      () async {
    var probes = 0;
    final created = <String>[];
    final progress = <NikoFolderProgress>[];
    await expectLater(
        NikoDirectoryTransfer(
                probe: (_) async {
                  if (++probes == 4) {
                    throw const NikoFolderFailure(
                        NikoFolderIssue.destinationChanged);
                  }
                },
                readEmptyDirectories: (_) async =>
                    ['/source/folder/a', '/source/folder/b'],
                createDirectory: (target) async {
                  created.add(target);
                  return NikoFileReceipt.confirmed;
                },
                blocked: () => null,
                progress: progress.add)
            .send(_folder(), () async {}),
        throwsA(isA<NikoFolderFailure>()));
    expect(created, ['/target/folder/a']);
    expect(progress.last.confirmed, 1);
    expect(progress.last.expected, 2);
  });

  test('cancel during the first receipt never sends the second directory',
      () async {
    NikoFolderIssue? blocked;
    final receipt = Completer<NikoFileReceipt>();
    final created = <String>[];
    final progress = <NikoFolderProgress>[];
    final future = NikoDirectoryTransfer(
            probe: (_) async {},
            readEmptyDirectories: (_) async =>
                ['/source/folder/a', '/source/folder/b'],
            createDirectory: (target) {
              created.add(target);
              return receipt.future;
            },
            blocked: () => blocked,
            progress: progress.add)
        .send(_folder(), () async {});
    final result = expectLater(future, throwsA(isA<NikoFolderFailure>()));
    await Future<void>.delayed(Duration.zero);
    expect(created, ['/target/folder/a']);
    blocked = NikoFolderIssue.cancelled;
    receipt.complete(NikoFileReceipt.confirmed);
    await result;
    expect(created, ['/target/folder/a']);
    expect(progress.last.state, NikoFolderState.blocked);
    expect(progress.last.confirmed, 0);
  });

  test('each listed child is verified by its captured source before creation',
      () async {
    final checked = <String>[];
    final created = <String>[];
    final progress = <NikoFolderProgress>[];
    await expectLater(
        NikoDirectoryTransfer(
                probe: (_) async {},
                readEmptyDirectories: (_) async =>
                    ['/source/folder/a', '/source/folder/b'],
                probeEmptyDirectory: (_, source, target) async {
                  checked.add('$source -> $target');
                  if (source.endsWith('/b')) {
                    throw const NikoFolderFailure(
                        NikoFolderIssue.sourceChanged);
                  }
                },
                createDirectory: (target) async {
                  created.add(target);
                  return NikoFileReceipt.confirmed;
                },
                blocked: () => null,
                progress: progress.add)
            .send(_folder(), () async {}),
        throwsA(isA<NikoFolderFailure>()));
    expect(checked, [
      '/source/folder/a -> /target/folder/a',
      '/source/folder/b -> /target/folder/b'
    ]);
    expect(created, ['/target/folder/a']);
    expect(progress.last.issue, NikoFolderIssue.sourceChanged);
    expect(progress.last.confirmed, 1);
  });

  test('Windows source checks use captured path style instead of the host OS',
      () async {
    final checked = <String>[];
    await NikoDirectoryTransfer(
            probe: (_) async {},
            readEmptyDirectories: (_) async => [r'C:\source\folder\child'],
            probeEmptyDirectory: (_, source, target) async =>
                checked.add('$source -> $target'),
            createDirectory: (_) async => NikoFileReceipt.confirmed,
            blocked: () => null,
            progress: (_) {})
        .send(_folder(sourceWindows: true), () async {});
    expect(checked, [r'C:\source\folder\child -> /target/folder/child']);
  });

  test('dispatch return never substitutes for directory acknowledgement',
      () async {
    final progress = <NikoFolderProgress>[];
    for (final receipt in [
      NikoFileReceipt.unconfirmed,
      NikoFileReceipt.failed
    ]) {
      await expectLater(
          NikoDirectoryTransfer(
                  probe: (_) async {},
                  readEmptyDirectories: (_) async => ['/source/folder/empty'],
                  createDirectory: (_) async => receipt,
                  blocked: () => null,
                  progress: progress.add)
              .send(_folder(), () async {}),
          throwsA(isA<NikoFolderFailure>()));
      expect(progress.last.confirmed, 0);
      expect(
          progress.last.state,
          receipt == NikoFileReceipt.unconfirmed
              ? NikoFolderState.unconfirmed
              : NikoFolderState.failed);
    }
  });

  test('all matching native acknowledgements confirm the empty-directory phase',
      () async {
    final created = <String>[];
    final progress = <NikoFolderProgress>[];
    await NikoDirectoryTransfer(
            probe: (_) async {},
            readEmptyDirectories: (_) async =>
                ['/source/folder', '/source/folder/empty'],
            createDirectory: (target) async {
              created.add(target);
              return NikoFileReceipt.confirmed;
            },
            blocked: () => null,
            progress: progress.add)
        .send(_folder(), () async {});
    expect(created, ['/target/folder', '/target/folder/empty']);
    expect(progress.last.state, NikoFolderState.confirmed);
    expect(progress.last.confirmed, 2);
  });

  test(
      'unrelated or late result IDs never acknowledge a different directory request',
      () async {
    final receipts = NikoFileTaskReceipts();
    final first = receipts.wait(1, const Duration(milliseconds: 5));
    expect(receipts.accept(2, NikoFileReceipt.confirmed), isFalse);
    expect(await first, NikoFileReceipt.unconfirmed);
    final next = receipts.wait(2, const Duration(seconds: 1));
    expect(receipts.accept(1, NikoFileReceipt.confirmed), isTrue);
    expect(receipts.accept(2, NikoFileReceipt.failed), isTrue);
    expect(await next, NikoFileReceipt.failed);
    receipts.clear();
  });

  if (const bool.fromEnvironment('NIKODESK')) {
    test(
        'a fast real empty-directory event is matched before native dispatch returns',
        () async {
      late FileFetcher fetcher;
      fetcher = FileFetcher(() => _session,
          nikoReadRemoteEmptyDirectories: (_, source, hidden) async {
        expect(source, '/captured/folder');
        expect(hidden, isTrue);
        fetcher.tryCompleteEmptyDirsTask(
            jsonEncode({
              'path': source,
              'empty_dirs': [
                {'path': '/captured/folder/empty', 'id': 0, 'entries': []}
              ]
            }),
            'false');
      });
      expect(
          (await fetcher.readEmptyDirs('/captured/folder', false, true))
              .single
              .path,
          '/captured/folder/empty');
      expect(fetcher.remoteEmptyDirsTasks, isEmpty);
    });

    test(
        'session invalidation releases pending directory reads without accepting a late response',
        () async {
      final fetcher = FileFetcher(() => _session,
          nikoReadRemoteEmptyDirectories: (_, __, ___) async {});
      final pending = fetcher.readEmptyDirs('/captured/folder', false, true);
      final result = expectLater(pending, throwsStateError);
      fetcher.beginRemoteSession();
      fetcher.tryCompleteEmptyDirsTask(
          jsonEncode({'path': '/captured/folder', 'empty_dirs': []}), 'false');
      await result;
      expect(fetcher.remoteEmptyDirsTasks, isEmpty);
      await expectLater(fetcher.readEmptyDirs('/captured/folder', false, true),
          throwsA(isA<NikoFolderFailure>()));
    });

    test(
        'production error sentinel aborts only unconfirmed empty reads and ignores late responses',
        () async {
      final model = FileModel(WeakReference(_FileFfiDouble()));
      final pending =
          model.fileFetcher.registerReadEmptyDirsTask(false, '/source/folder');
      final result = expectLater(pending, throwsA(isA<NikoFolderFailure>()));
      final ordinary = Completer<FileDirectory>();
      model.fileFetcher.readRecursiveTasks[55] = ordinary;
      model.jobController.jobTable.add(JobProgress()
        ..id = 7
        ..state = JobState.inProgress);
      final unrelated = model.jobController.jobResultListener.start();
      model.handleJobError({
        'id': '-1',
        'file_num': '-1',
        'err': 'NIKODESK_EMPTY_DIRECTORY_READ_FAILED'
      });
      await result;
      expect(model.jobController.jobTable.single.state, JobState.inProgress);
      expect(ordinary.isCompleted, isFalse);
      expect(model.jobController.jobResultListener.isListening, isTrue);
      model.jobController.jobResultListener.complete({'unrelated': true});
      await unrelated;
      model.fileFetcher.tryCompleteEmptyDirsTask(
          jsonEncode({'path': '/source/folder', 'empty_dirs': []}), 'false');
      await expectLater(
          model.fileFetcher.readEmptyDirs('/source/folder', false, true),
          throwsA(isA<NikoFolderFailure>()));
      expect(model.fileFetcher.remoteEmptyDirsTasks, isEmpty);
      model.fileFetcher.readRecursiveTasks.clear();
    });

    testWidgets(
        'timed-out reads cannot be re-registered or completed by late directory replies',
        (tester) async {
      var dispatches = 0;
      final fetcher = FileFetcher(() => _session,
          nikoReadRemoteEmptyDirectories: (_, __, ___) async {
        dispatches++;
      });
      final pending = fetcher.readEmptyDirs('/captured/folder', false, true);
      final result = expectLater(pending, throwsA(isA<NikoFolderFailure>()));
      await tester.pump(const Duration(seconds: 31));
      await result;
      fetcher.tryCompleteEmptyDirsTask(
          jsonEncode({'path': '/captured/folder', 'empty_dirs': []}), 'false');
      await expectLater(fetcher.readEmptyDirs('/captured/folder', false, true),
          throwsA(isA<NikoFolderFailure>()));
      expect(dispatches, 1);
      expect(fetcher.remoteEmptyDirsTasks, isEmpty);
    });

    test(
        'remote dispatch failure retires the path because queued completion is unknown',
        () async {
      var sends = 0;
      final fetcher = FileFetcher(() => _session,
          nikoReadRemoteEmptyDirectories: (_, __, ___) async {
        sends++;
        throw StateError('explicit bridge double failure');
      });
      await expectLater(fetcher.readEmptyDirs('/captured/folder', false, true),
          throwsA(isA<NikoFolderFailure>()));
      await expectLater(fetcher.readEmptyDirs('/captured/folder', false, true),
          throwsA(isA<NikoFolderFailure>()));
      expect(sends, 1);
      expect(fetcher.remoteEmptyDirsTasks, isEmpty);
    });

    test(
        'directory read error cannot dispatch file data or create an empty directory',
        () async {
      final progress = <NikoFolderProgress>[];
      var sends = 0;
      var creates = 0;
      await expectLater(
          NikoDirectoryTransfer(
                  probe: (_) async {},
                  readEmptyDirectories: (_) async =>
                      throw const NikoFolderFailure(
                          NikoFolderIssue.readUnconfirmed),
                  createDirectory: (_) async {
                    creates++;
                    return NikoFileReceipt.confirmed;
                  },
                  blocked: () => null,
                  progress: progress.add)
              .send(_folder(), () async {
            sends++;
          }),
          throwsA(isA<NikoFolderFailure>()));
      expect(sends, 0);
      expect(creates, 0);
      expect(progress.last.state, NikoFolderState.unconfirmed);
    });
  }
}
