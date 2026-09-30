import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;

import 'file_transfer.dart';

enum NikoFileReceipt { confirmed, failed, unconfirmed }

/// The existing wire response has a path but no request ID or generation. An
/// uncertain path therefore cannot be reused in the same file session.
class NikoEmptyDirectoryReadGuard {
  final int maxRetiredPaths;
  final _retired = <String>{};
  bool _retiredAll = false;
  NikoEmptyDirectoryReadGuard({this.maxRetiredPaths = 4096});
  int get retiredCount => _retired.length;
  String _key(String path) => sha256.convert(utf8.encode(path)).toString();
  bool retired(String path) => _retiredAll || _retired.contains(_key(path));
  void retire(Iterable<String> paths) {
    if (_retiredAll) return;
    for (final path in paths) {
      if (_retired.length >= maxRetiredPaths) {
        _retiredAll = true;
        _retired.clear();
        return;
      }
      _retired.add(_key(path));
    }
  }
}

/// Dedicated IDs stop unrelated file jobs from acknowledging directory work.
class NikoFileTaskReceipts {
  final _pending = <int, Completer<NikoFileReceipt>>{};
  final _known = <int>{};
  Future<NikoFileReceipt> wait(int id, Duration timeout) {
    if (!_known.add(id)) throw StateError('duplicate directory request');
    final pending = Completer<NikoFileReceipt>();
    _pending[id] = pending;
    return pending.future.timeout(timeout, onTimeout: () {
      if (identical(_pending[id], pending)) _pending.remove(id);
      return NikoFileReceipt.unconfirmed;
    });
  }

  bool accept(int id, NikoFileReceipt receipt) {
    if (!_known.contains(id)) return false;
    final pending = _pending.remove(id);
    if (pending != null && !pending.isCompleted) pending.complete(receipt);
    return true;
  }

  void clear() {
    for (final pending in _pending.values) {
      if (!pending.isCompleted) pending.complete(NikoFileReceipt.unconfirmed);
    }
    _pending.clear();
    _known.clear();
  }
}

class NikoFolderFailure implements Exception {
  final NikoFolderIssue issue;
  const NikoFolderFailure(this.issue);
}

/// Converts only normalized paths within the captured source folder. Every
/// response is validated before any transfer or directory creation is sent.
List<String> nikoEmptyDirectoryDestinations(
    NikoTransferRequest request, Iterable<String> directories) {
  if (!request.hasDirectoryContext) {
    throw const NikoFolderFailure(NikoFolderIssue.invalidPaths);
  }
  final source = path.Context(
      style: request.sourceWindows! ? path.Style.windows : path.Style.posix);
  final destination = path.Context(
      style:
          request.destinationWindows! ? path.Style.windows : path.Style.posix);
  final root = source.normalize(request.source);
  final target = destination.normalize(request.destination);
  if (!source.isAbsolute(root) || !destination.isAbsolute(target)) {
    throw const NikoFolderFailure(NikoFolderIssue.invalidPaths);
  }
  final targets = <String>{};
  for (final directory in directories) {
    final normalized = source.normalize(directory);
    if (!source.isAbsolute(normalized) ||
        !(source.equals(root, normalized) ||
            source.isWithin(root, normalized))) {
      throw const NikoFolderFailure(NikoFolderIssue.invalidPaths);
    }
    final relative = source.relative(normalized, from: root);
    final mapped = destination.normalize(destination.joinAll(
        [target, ...source.split(relative).where((part) => part != '.')]));
    if (!(destination.equals(target, mapped) ||
        destination.isWithin(target, mapped))) {
      throw const NikoFolderFailure(NikoFolderIssue.invalidPaths);
    }
    targets.add(mapped);
    if (targets.length > 4096) {
      throw const NikoFolderFailure(NikoFolderIssue.invalidPaths);
    }
  }
  return targets.toList(growable: false);
}

class NikoDirectoryTransfer {
  final Future<void> Function(NikoTransferRequest) probe;
  final Future<List<String>> Function(NikoTransferRequest) readEmptyDirectories;
  final Future<NikoFileReceipt> Function(String) createDirectory;
  final Future<void> Function(NikoTransferRequest, String, String)?
      probeEmptyDirectory;
  final NikoFolderIssue? Function() blocked;
  final void Function(NikoFolderProgress) progress;
  const NikoDirectoryTransfer(
      {required this.probe,
      required this.readEmptyDirectories,
      required this.createDirectory,
      this.probeEmptyDirectory,
      required this.blocked,
      required this.progress});

  void _check() {
    final reason = blocked();
    if (reason != null) throw NikoFolderFailure(reason);
  }

  Future<void> send(
      NikoTransferRequest request, Future<void> Function() sendFiles) async {
    var expected = 0;
    var confirmed = 0;
    try {
      _check();
      progress(const NikoFolderProgress(NikoFolderState.preparing));
      await probe(request);
      _check();
      final directories = await readEmptyDirectories(request);
      _check();
      final targets = nikoEmptyDirectoryDestinations(request, directories);
      expected = targets.length;
      // Source and destination can change while the recursive listing is pending.
      await probe(request);
      _check();
      await sendFiles();
      _check();
      for (final target in targets) {
        _check();
        await probe(request);
        _check();
        final source = path.Context(
            style:
                request.sourceWindows! ? path.Style.windows : path.Style.posix);
        final destination = path.Context(
            style: request.destinationWindows!
                ? path.Style.windows
                : path.Style.posix);
        final relative = destination.relative(target,
            from: destination.normalize(request.destination));
        final sourceDirectory = source.normalize(source.joinAll([
          request.source,
          ...destination.split(relative).where((part) => part != '.')
        ]));
        await probeEmptyDirectory?.call(request, sourceDirectory, target);
        _check();
        progress(NikoFolderProgress(NikoFolderState.creating,
            expected: expected, confirmed: confirmed));
        final result = await createDirectory(target);
        _check();
        if (result == NikoFileReceipt.unconfirmed) {
          throw const NikoFolderFailure(NikoFolderIssue.timeout);
        }
        if (result == NikoFileReceipt.failed) {
          throw const NikoFolderFailure(NikoFolderIssue.nativeError);
        }
        confirmed++;
      }
      progress(NikoFolderProgress(NikoFolderState.confirmed,
          expected: expected, confirmed: confirmed));
    } catch (error) {
      final issue = blocked() ??
          (error is NikoFolderFailure
              ? error.issue
              : NikoFolderIssue.readFailed);
      final state = (issue == NikoFolderIssue.timeout ||
              issue == NikoFolderIssue.readUnconfirmed)
          ? NikoFolderState.unconfirmed
          : [
              NikoFolderIssue.sessionChanged,
              NikoFolderIssue.disconnected,
              NikoFolderIssue.permission,
              NikoFolderIssue.cancelled
            ].contains(issue)
              ? NikoFolderState.blocked
              : NikoFolderState.failed;
      progress(NikoFolderProgress(state,
          expected: expected, confirmed: confirmed, issue: issue));
      throw NikoFolderFailure(issue);
    }
  }
}
