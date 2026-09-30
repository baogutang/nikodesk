import 'dart:async';
import 'dart:io';

class NikoUpdateCancelled implements Exception {}

class NikoUpdateCancellation {
  final _signal = Completer<void>();
  bool get isCancelled => _signal.isCompleted;
  void cancel() {
    if (!isCancelled) _signal.complete();
  }

  void check() {
    if (isCancelled) throw NikoUpdateCancelled();
  }
}

class NikoUpdateLimits {
  final Duration connectionTimeout;
  final Duration idleTimeout;
  final Duration totalTimeout;
  final Duration processTimeout;
  final int metadataBytes;
  final int downloadBytes;
  final int archiveEntries;
  final int expandedBytes;
  final int entryBytes;

  const NikoUpdateLimits({
    this.connectionTimeout = const Duration(seconds: 15),
    this.idleTimeout = const Duration(seconds: 30),
    this.totalTimeout = const Duration(minutes: 10),
    this.processTimeout = const Duration(minutes: 2),
    this.metadataBytes = 2 * 1024 * 1024,
    this.downloadBytes = 256 * 1024 * 1024,
    this.archiveEntries = 20000,
    this.expandedBytes = 1024 * 1024 * 1024,
    this.entryBytes = 128 * 1024 * 1024,
  });
}

class NikoUpdateTask {
  final NikoUpdateLimits limits;
  final NikoUpdateCancellation cancellation;
  final _elapsed = Stopwatch()..start();

  NikoUpdateTask(this.limits, NikoUpdateCancellation? cancellation)
      : cancellation = cancellation ?? NikoUpdateCancellation();

  void check() {
    cancellation.check();
    if (_elapsed.elapsed >= limits.totalTimeout) {
      throw TimeoutException('Update exceeded its time limit');
    }
  }

  Future<T> wait<T>(Future<T> future, {Duration? timeout}) {
    check();
    final remaining = limits.totalTimeout - _elapsed.elapsed;
    final phase = timeout ?? limits.idleTimeout;
    return Future.any<T>([
      future,
      cancellation._signal.future.then<T>((_) => throw NikoUpdateCancelled()),
    ]).timeout(phase < remaining ? phase : remaining);
  }

  Future<T> read<T>(Stream<List<int>> stream,
      FutureOr<void> Function(List<int>) onChunk, T Function() result,
      {Duration? idleTimeout}) async {
    final iterator = StreamIterator(stream);
    try {
      while (await wait(iterator.moveNext(), timeout: idleTimeout)) {
        check();
        await onChunk(iterator.current);
      }
      check();
      return result();
    } finally {
      await iterator.cancel();
    }
  }

  Future<ProcessResult> run(String executable, List<String> arguments,
      Future<ProcessResult> Function(String, List<String>)? injected) async {
    if (injected != null) {
      return wait(injected(executable, arguments),
          timeout: limits.processTimeout);
    }
    // Keep ownership even if cancellation happens while the OS creates it.
    final starting = Process.start(executable, arguments);
    Process? process;
    try {
      final running = await wait(starting, timeout: limits.connectionTimeout);
      process = running;
      final stdout = <int>[];
      final stderr = <int>[];
      Future<void> output(Stream<List<int>> stream, List<int> target) =>
          read(stream, (chunk) {
            if (target.length + chunk.length > limits.metadataBytes) {
              throw const FormatException('Update command output is too large');
            }
            target.addAll(chunk);
          }, () {}, idleTimeout: limits.processTimeout);
      final values = await wait(
          Future.wait([
            running.exitCode,
            output(running.stdout, stdout),
            output(running.stderr, stderr),
          ]),
          timeout: limits.processTimeout);
      return ProcessResult(running.pid, values[0] as int,
          String.fromCharCodes(stdout), String.fromCharCodes(stderr));
    } finally {
      if (process == null) {
        starting.then((lateProcess) async {
          lateProcess.kill(ProcessSignal.sigkill);
          await lateProcess.exitCode.timeout(const Duration(seconds: 5));
        }).catchError((Object _) {});
      } else {
        process.kill(ProcessSignal.sigkill);
        await process.exitCode.timeout(const Duration(seconds: 5));
      }
    }
  }
}
