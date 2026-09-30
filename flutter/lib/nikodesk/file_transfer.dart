import 'server_scope.dart';
import 'package:path/path.dart' as path;

enum NikoCancelState { none, requesting, requested, failed }

enum NikoRetryBlock {
  notFailed,
  missingRequest,
  directoryNeedsSelection,
  changedSession,
  disconnected,
  permission,
  cancelled,
  busy,
  readUnconfirmed
}

class NikoTransferContext {
  final String sessionId;
  final String namespace;
  final String peerId;
  final int connection;
  final bool ready;
  final bool fileAllowed;
  const NikoTransferContext(
      {required this.sessionId,
      required this.namespace,
      required this.peerId,
      required this.connection,
      required this.ready,
      required this.fileAllowed});

  bool matches(NikoTransferContext other) =>
      sessionId == other.sessionId &&
      namespace == other.namespace &&
      peerId == other.peerId &&
      connection == other.connection;
}

class NikoTransferRequest {
  final NikoTransferContext context;
  final String source;
  final String destination;
  final bool remoteToLocal;
  final bool includeHidden;
  final bool isDirectory;
  final int size;
  final bool? sourceWindows;
  final bool? destinationWindows;
  final bool? destinationWasDirectory;
  final bool? destinationExisted;
  bool get hasPathContext =>
      sourceWindows != null &&
      destinationWindows != null &&
      destinationExisted != null;
  bool get hasDirectoryContext =>
      hasPathContext && destinationWasDirectory != null;
  bool get hasAbsolutePaths =>
      hasPathContext &&
      path.Context(
              style: sourceWindows! ? path.Style.windows : path.Style.posix)
          .isAbsolute(source) &&
      path.Context(
              style:
                  destinationWindows! ? path.Style.windows : path.Style.posix)
          .isAbsolute(destination);
  const NikoTransferRequest(
      {required this.context,
      required this.source,
      required this.destination,
      required this.remoteToLocal,
      required this.includeHidden,
      required this.isDirectory,
      required this.size,
      this.sourceWindows,
      this.destinationWindows,
      this.destinationWasDirectory,
      this.destinationExisted});
}

enum NikoFolderState {
  preparing,
  creating,
  confirmed,
  failed,
  unconfirmed,
  blocked
}

enum NikoFolderIssue {
  sourceChanged,
  destinationChanged,
  invalidPaths,
  sessionChanged,
  disconnected,
  permission,
  cancelled,
  nativeError,
  timeout,
  readFailed,
  readUnconfirmed
}

class NikoFolderProgress {
  final NikoFolderState state;
  final int expected;
  final int confirmed;
  final NikoFolderIssue? issue;
  const NikoFolderProgress(this.state,
      {this.expected = 0, this.confirmed = 0, this.issue});
  bool get pending =>
      state == NikoFolderState.preparing || state == NikoFolderState.creating;
  bool get incomplete =>
      state == NikoFolderState.failed ||
      state == NikoFolderState.unconfirmed ||
      state == NikoFolderState.blocked;
}

/// Only in-memory requests from this authenticated file session are restartable.
class NikoFileTransferLedger {
  final Map<int, NikoTransferRequest> _requests = {};
  final Map<int, NikoCancelState> _cancellations = {};
  final Set<int> _retrying = {};
  final Map<int, NikoFolderProgress> _folders = {};
  final Map<int, NikoFolderIssue> _failures = {};

  NikoTransferRequest? request(int id) => _requests[id];
  NikoCancelState cancellation(int id) =>
      _cancellations[id] ?? NikoCancelState.none;
  NikoFolderProgress? folder(int id) => _folders[id];
  NikoFolderIssue? failure(int id) => _failures[id];
  void updateFailure(int id, NikoFolderIssue issue) => _failures[id] = issue;
  void updateFolder(int id, NikoFolderProgress progress) =>
      _folders[id] = progress;

  void capture(int id, NikoTransferRequest request) {
    if (request.source.isEmpty ||
        request.destination.isEmpty ||
        !request.context.ready ||
        !request.context.fileAllowed ||
        request.context.sessionId.isEmpty ||
        request.context.peerId.isEmpty ||
        NikoServerScope.validate(request.context.namespace) == null) return;
    if (request.hasPathContext && !request.hasAbsolutePaths) return;
    _requests[id] = request;
    if (request.isDirectory) {
      _folders[id] = const NikoFolderProgress(NikoFolderState.preparing);
    }
  }

  NikoRetryBlock? retryBlock(
      int id, bool failed, NikoTransferContext? current) {
    if (!failed) return NikoRetryBlock.notFailed;
    if (_retrying.contains(id)) return NikoRetryBlock.busy;
    if (cancellation(id) != NikoCancelState.none) {
      return NikoRetryBlock.cancelled;
    }
    final original = _requests[id];
    if (original == null) return NikoRetryBlock.missingRequest;
    if (original.isDirectory && !original.hasDirectoryContext) {
      return NikoRetryBlock.directoryNeedsSelection;
    }
    if (!original.hasPathContext) return NikoRetryBlock.missingRequest;
    if (_folders[id]?.pending == true) return NikoRetryBlock.busy;
    if (_folders[id]?.issue == NikoFolderIssue.readUnconfirmed) {
      return NikoRetryBlock.readUnconfirmed;
    }
    if (current == null || !original.context.matches(current)) {
      return NikoRetryBlock.changedSession;
    }
    if (!current.ready) return NikoRetryBlock.disconnected;
    if (!current.fileAllowed) return NikoRetryBlock.permission;
    return null;
  }

  Future<void> cancel(
      int id, Future<void> Function(int) send, void Function() refresh) async {
    if (cancellation(id) == NikoCancelState.requesting ||
        cancellation(id) == NikoCancelState.requested) return;
    _cancellations[id] = NikoCancelState.requesting;
    refresh();
    try {
      await send(id);
      _cancellations[id] = NikoCancelState.requested;
    } catch (_) {
      _cancellations[id] = NikoCancelState.failed;
    }
    refresh();
  }

  Future<int> resend(int id,
      {required bool failed,
      required NikoTransferContext? Function() current,
      required int Function() nextId,
      required void Function(int, NikoTransferRequest) add,
      required Future<void> Function(int, NikoTransferRequest) send,
      required void Function() refresh}) async {
    final blocked = retryBlock(id, failed, current());
    if (blocked != null) throw StateError(blocked.name);
    final original = _requests[id]!;
    _retrying.add(id);
    refresh();
    try {
      final newId = nextId();
      if (newId == id || _requests.containsKey(newId)) {
        throw StateError('duplicate job');
      }
      final beforeDispatch = current();
      if (!identical(_requests[id], original) ||
          cancellation(id) != NikoCancelState.none ||
          beforeDispatch == null ||
          !original.context.matches(beforeDispatch) ||
          !beforeDispatch.ready ||
          !beforeDispatch.fileAllowed) {
        throw StateError('session changed');
      }
      capture(newId, original);
      add(newId, original);
      final atDispatch = current();
      if (!identical(_requests[id], original) ||
          cancellation(id) != NikoCancelState.none ||
          atDispatch == null ||
          !original.context.matches(atDispatch) ||
          !atDispatch.ready ||
          !atDispatch.fileAllowed) {
        throw StateError('session changed');
      }
      await send(newId, original);
      return newId;
    } finally {
      _retrying.remove(id);
      refresh();
    }
  }

  void remove(int id) {
    _requests.remove(id);
    _cancellations.remove(id);
    _folders.remove(id);
    _failures.remove(id);
  }

  void clear() {
    _requests.clear();
    _cancellations.clear();
    _retrying.clear();
    _folders.clear();
    _failures.clear();
  }
}

class NikoDocumentOutcome {
  final int succeeded;
  final int failed;
  final int skipped;
  final bool cancelled;
  final bool incomplete;
  final String? errorCode;
  const NikoDocumentOutcome(
      {this.succeeded = 0,
      this.failed = 0,
      this.skipped = 0,
      this.cancelled = false,
      this.incomplete = false,
      this.errorCode});
}

NikoDocumentOutcome nikoDocumentExportOutcome(Map<dynamic, dynamic> reply) {
  final succeeded = reply['exported'];
  final failed = reply['failed'];
  if (succeeded is! int || failed is! int || succeeded < 0 || failed < 0) {
    return const NikoDocumentOutcome(
        incomplete: true, errorCode: 'invalid_document_result');
  }
  return NikoDocumentOutcome(succeeded: succeeded, failed: failed);
}
