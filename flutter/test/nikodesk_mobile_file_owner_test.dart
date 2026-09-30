import 'dart:async';
import 'dart:convert';

import 'package:flutter_hbb/models/file_model.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/nikodesk/file_directory_transfer.dart';
import 'package:flutter_hbb/nikodesk/mobile_file_owner.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

// Explicit global owner double. No native initialization/configuration/network.
class _Globals implements FFI {
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

// Lifecycle double around the real FileModel/Fetcher; native close is injected.
class _Session implements FFI {
  @override
  final sessionId = const Uuid().v4obj();
  @override
  final String id;
  @override
  final String serverNamespace;
  @override
  bool closed = false;
  @override
  late final FileModel fileModel = FileModel(WeakReference(this));
  _Session(this.id, this.serverNamespace);
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final globals = _Globals();
  NikoMobileFileOwner open(_Session ffi, {Future<void> Function(FFI)? close}) =>
      NikoMobileFileOwner.open(
          globalOwner: globals,
          createFfi: (_) => ffi,
          closeFfi: close ?? (_) async {});

  test(
      'each file page invokes its factory and receives a new UUID/model/fetcher',
      () async {
    final created = <_Session>[];
    FFI factory(FFI globalOwner) {
      expect(globalOwner, same(globals));
      final session = _Session('123456789', 'a' * 64);
      created.add(session);
      return session;
    }

    final first = NikoMobileFileOwner.open(
        globalOwner: globals, createFfi: factory, closeFfi: (_) async {});
    await first.close();
    final second = NikoMobileFileOwner.open(
        globalOwner: globals, createFfi: factory, closeFfi: (_) async {});
    expect(created.length, 2);
    expect(second.ffi.sessionId, isNot(first.ffi.sessionId));
    expect(identical(second.ffi.fileModel, first.ffi.fileModel), isFalse);
    expect(
        identical(
            second.ffi.fileModel.fileFetcher, first.ffi.fileModel.fileFetcher),
        isFalse);
    await second.close();
  });

  test(
      'closing keeps the mobile guard active and repeated old dispose cannot close a new owner',
      () async {
    final pending = Completer<void>();
    final closedIds = <String>[];
    final first = open(_Session('123456789', 'a' * 64), close: (ffi) async {
      closedIds.add(ffi.sessionId.toString());
      await pending.future;
    });
    final closing = first.close();
    expect(first.ffi.closed, isTrue);
    expect(NikoMobileFileOwner.hasActiveSession, isTrue);
    expect(() => open(_Session('987654321', 'b' * 64)), throwsStateError);
    pending.complete();
    await closing;
    final second = open(_Session('987654321', 'b' * 64), close: (ffi) async {
      closedIds.add(ffi.sessionId.toString());
    });
    await first.close();
    expect(second.ffi.closed, isFalse);
    expect(NikoMobileFileOwner.hasActiveSession, isTrue);
    expect(closedIds, [first.ffi.sessionId.toString()]);
    await second.close();
    expect(NikoMobileFileOwner.hasActiveSession, isFalse);
  });

  test(
      'failed teardown releases only its owner and keeps its native identity closed',
      () async {
    final owner = open(_Session('123456789', 'a' * 64), close: (_) async {
      throw StateError('synthetic teardown failure');
    });
    await expectLater(owner.close(), throwsStateError);
    expect(owner.ffi.closed, isTrue);
    expect(NikoMobileFileOwner.hasActiveSession, isFalse);
  });

  for (final next in [
    ('123456789', 'a' * 64),
    ('987654321', 'a' * 64),
    ('123456789', 'b' * 64),
  ]) {
    test(
        'reopen ${next.$1}/${next.$2[0]} replaces retired paths and old replies cannot complete its new fetcher',
        () async {
      final first = open(_Session('123456789', 'a' * 64));
      final oldFetcher = first.ffi.fileModel.fileFetcher;
      final oldRead =
          oldFetcher.registerReadEmptyDirsTask(false, '/remote/folder');
      final failure = expectLater(oldRead, throwsA(isA<NikoFolderFailure>()));
      oldFetcher.failNikoEmptyDirectoryReads();
      await failure;
      expect(
          () => oldFetcher.registerReadEmptyDirsTask(false, '/remote/folder'),
          throwsA(isA<NikoFolderFailure>()));
      await first.close();
      final second = open(_Session(next.$1, next.$2));
      final fetcher = second.ffi.fileModel.fileFetcher;
      final read = fetcher.registerReadEmptyDirsTask(false, '/remote/folder');
      final response = {
        'value': jsonEncode({'path': '/remote/folder', 'empty_dirs': []}),
        'is_local': 'false'
      };
      first.ffi.fileModel.receiveEmptyDirs(response);
      expect(
          fetcher.remoteEmptyDirsTasks.containsKey('/remote/folder'), isTrue);
      expect(second.ffi.sessionId, isNot(first.ffi.sessionId));
      second.ffi.fileModel.receiveEmptyDirs(response);
      expect(await read, isEmpty);
      expect(fetcher.remoteEmptyDirsTasks, isEmpty);
      await second.close();
    }, skip: !const bool.fromEnvironment('NIKODESK'));
  }
}
