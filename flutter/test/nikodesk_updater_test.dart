import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_hbb/nikodesk/updater.dart';
import 'package:flutter_hbb/nikodesk/update_transfer.dart' show NikoUpdateTask;
import 'package:flutter_test/flutter_test.dart';

class _Headers implements HttpHeaders {
  final String? location;
  _Headers([this.location]);
  @override
  String? value(String name) =>
      name == HttpHeaders.locationHeader ? location : null;
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Response extends Stream<List<int>> implements HttpClientResponse {
  final Stream<List<int>> body;
  @override
  final int statusCode;
  @override
  final int contentLength;
  @override
  final HttpHeaders headers;
  _Response(List<int> bytes, {this.statusCode = 200, String? location})
      : body = Stream.value(bytes),
        contentLength = bytes.length,
        headers = _Headers(location);
  _Response.stream(this.body, {this.contentLength = -1})
      : statusCode = 200,
        headers = _Headers();
  @override
  bool get isRedirect => [301, 302, 303, 307, 308].contains(statusCode);
  @override
  StreamSubscription<List<int>> listen(void Function(List<int>)? onData,
          {Function? onError, void Function()? onDone, bool? cancelOnError}) =>
      body.listen(onData,
          onError: onError, onDone: onDone, cancelOnError: cancelOnError);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Request implements HttpClientRequest {
  final _Response response;
  _Request(this.response);
  @override
  bool followRedirects = true;
  @override
  final HttpHeaders headers = _Headers();
  @override
  Future<HttpClientResponse> close() async {
    if (followRedirects) {
      throw StateError('Implicit redirects must be disabled before sending');
    }
    return response;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Client implements HttpClient {
  final List<_Response> responses;
  final requested = <Uri>[];
  bool closed = false;
  @override
  Duration? connectionTimeout;
  _Client(this.responses);
  @override
  Future<HttpClientRequest> getUrl(Uri uri) async {
    requested.add(uri);
    return _Request(responses[requested.length - 1]);
  }

  @override
  void close({bool force = false}) => closed = force;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<T> _http<T>(_Client client, Future<T> Function() action) =>
    HttpOverrides.runZoned(action, createHttpClient: (_) => client);

List<int> _zip(Map<String, String> files,
    {Map<String, String> links = const {}}) {
  final archive = Archive();
  for (final entry in files.entries) {
    archive.addFile(ArchiveFile.string(entry.key, entry.value)..mode = 0x81ed);
  }
  for (final entry in links.entries) {
    archive.addFile(ArchiveFile.string(entry.key, entry.value)..mode = 0xa1ff);
  }
  return ZipEncoder().encode(archive)!;
}

const _bundleFiles = {
  'NikoDesk.app/Contents/MacOS/NikoDesk': 'executable',
  'NikoDesk.app/Contents/Frameworks/liblibrustdesk.dylib': 'core',
  'NikoDesk.app/Contents/Info.plist': 'plist',
  '__MACOSX/._NikoDesk.app': 'metadata',
};

class _Processes {
  final calls = <(String, List<String>)>[];
  int signatureExit = 0;
  String identifier = 'io.nikodesk.macos';
  String architecture = 'arm64';
  String? injectedLink;
  Future<ProcessResult> run(String executable, List<String> args) async {
    calls.add((executable, List.of(args)));
    if (executable == '/usr/bin/unzip') {
      final archive =
          ZipDecoder().decodeBytes(await File(args[2]).readAsBytes());
      final root = args[4];
      for (final entry in archive) {
        final target = '$root/${entry.name}';
        await Directory(File(target).parent.path).create(recursive: true);
        if (entry.isSymbolicLink) {
          await Link(target).create(entry.nameOfLinkedFile);
        } else if (entry.isFile) {
          await File(target).writeAsBytes(entry.content as List<int>);
        }
      }
      if (injectedLink != null) {
        await Link('$root/NikoDesk.app/escape').create(injectedLink!);
      }
    }
    var stdout = '';
    var code = 0;
    if (executable == '/usr/bin/lipo') stdout = architecture;
    if (executable == '/usr/bin/plutil') {
      stdout = {
        'CFBundleIdentifier': identifier,
        'CFBundleExecutable': 'NikoDesk',
        'CFBundleShortVersionString': '1.1.0'
      }[args[1]]!;
    }
    if (executable == '/usr/bin/codesign') code = signatureExit;
    return ProcessResult(1, code, stdout, '');
  }
}

void main() {
  test('a silent owned process uses its process deadline and is reaped',
      () async {
    final elapsed = Stopwatch()..start();
    final task = NikoUpdateTask(
        const NikoUpdateLimits(
            idleTimeout: Duration(milliseconds: 5),
            processTimeout: Duration(milliseconds: 100)),
        null);
    await expectLater(
        task.run('/bin/cat', [], null), throwsA(isA<TimeoutException>()));
    expect(elapsed.elapsedMilliseconds, greaterThanOrEqualTo(80));
    expect(elapsed.elapsed, lessThan(const Duration(seconds: 3)));
  }, skip: Platform.isWindows);

  test('cancelling an owned process waits for termination', () async {
    final cancellation = NikoUpdateCancellation();
    final task = NikoUpdateTask(const NikoUpdateLimits(), cancellation);
    final timer = Timer(const Duration(milliseconds: 50), cancellation.cancel);
    try {
      await expectLater(
          task.run('/bin/cat', [], null), throwsA(isA<NikoUpdateCancelled>()));
    } finally {
      timer.cancel();
    }
  }, skip: Platform.isWindows);

  test('release selection prefers the standalone Windows executable', () {
    final zip = NikoReleaseAsset(
        'NikoDesk-windows-x64.zip', Uri.parse('https://github.com/legacy.zip'));
    final exe = NikoReleaseAsset('NikoDesk-windows-x64.exe',
        Uri.parse('https://github.com/portable.exe'));
    final release =
        NikoReleaseInfo(tag: 'v1.1.0', notes: '', assets: [zip, exe]);
    expect(release.assetFor('windows-x64'), same(exe));
    expect(
        NikoReleaseInfo(tag: 'v1.0.0', notes: '', assets: [zip])
            .assetFor('windows-x64'),
        same(zip));
  });

  test('release selection accepts Android APK and keeps macOS ZIP only', () {
    final apk = NikoReleaseAsset('NikoDesk-android-arm64.apk',
        Uri.parse('https://github.com/mobile.apk'));
    final dmg = NikoReleaseAsset(
        'NikoDesk-macos-arm64.dmg', Uri.parse('https://github.com/manual.dmg'));
    final zip = NikoReleaseAsset(
        'NikoDesk-macos-arm64.zip', Uri.parse('https://github.com/update.zip'));
    final release =
        NikoReleaseInfo(tag: 'v1.1.0', notes: '', assets: [apk, dmg, zip]);
    expect(release.assetFor('android-arm64'), same(apk));
    expect(release.assetFor('macos-arm64'), same(zip));
    expect(release.assetFor('linux-x64'), isNull);
  });

  late Directory directory;
  final asset = NikoReleaseAsset(
      'NikoDesk-macos-arm64.zip',
      Uri.parse(
          'https://github.com/owner/repo/releases/download/v1.1.0/NikoDesk-macos-arm64.zip'));
  final sums = NikoReleaseAsset(
      'SHA256SUMS', Uri.parse('https://github.com/owner/repo/SHA256SUMS'));
  setUp(() async => directory =
      await Directory.systemTemp.createTemp('nikodesk-updater-test-'));
  tearDown(() async => directory.delete(recursive: true));

  test(
      'update checks disable implicit redirects and resolve relative locations',
      () async {
    final client = _Client([
      _Response([], statusCode: 302, location: '/next'),
      _Response(utf8.encode('{"tag_name":"v1.1.0","assets":[]}')),
    ]);
    final release =
        await _http(client, () => const NikoUpdater().checkLatest());
    expect(release!.tag, 'v1.1.0');
    expect(client.requested.last, Uri.parse('https://api.github.com/next'));
    expect(client.closed, isTrue);
  });

  for (final blocked in [
    'http://github.com/file',
    'https://example.net/file',
    'https://127.0.0.1/file'
  ]) {
    test(
        'checks and downloads refuse redirect to $blocked before requesting it',
        () async {
      final check =
          _Client([_Response([], statusCode: 302, location: blocked)]);
      await expectLater(_http(check, () => const NikoUpdater().checkLatest()),
          throwsFormatException);
      expect(check.requested, hasLength(1));
      expect(check.closed, isTrue);
      final download =
          _Client([_Response([], statusCode: 302, location: blocked)]);
      await expectLater(
          _http(download,
              () => const NikoUpdater().downloadAsset(asset, directory, null)),
          throwsFormatException);
      expect(download.requested, hasLength(1));
      expect(download.closed, isTrue);
      expect(directory.listSync(), isEmpty);
    });
  }

  test(
      'asset redirects resolve relative URLs and leave only a complete download',
      () async {
    final client = _Client([
      _Response([], statusCode: 302, location: '/download'),
      _Response([1, 2, 3])
    ]);
    final result = await _http(client,
        () => const NikoUpdater().downloadAsset(asset, directory, null));
    expect(await result.readAsBytes(), [1, 2, 3]);
    expect(client.requested.last, Uri.parse('https://github.com/download'));
    expect(directory.listSync().where((entry) => entry.path.endsWith('.part')),
        isEmpty);
  });

  test('failed download removes partial bytes', () async {
    final client = _Client([
      _Response([1, 2, 3])
    ]);
    await expectLater(
        _http(
            client,
            () => const NikoUpdater().downloadAsset(asset, directory,
                (_, __) => throw StateError('progress callback failed'))),
        throwsStateError);
    expect(directory.listSync(), isEmpty);
    expect(client.closed, isTrue);
  });

  test('oversized metadata fails before returning a release', () async {
    final client = _Client([_Response(List.filled(33, 32))]);
    await expectLater(
        _http(
            client,
            () => const NikoUpdater(limits: NikoUpdateLimits(metadataBytes: 32))
                .checkLatest()),
        throwsFormatException);
    expect(client.closed, isTrue);
  });

  test('unknown-length oversized download is bounded and removed', () async {
    final client = _Client([
      _Response.stream(
          Stream.fromIterable([List.filled(12, 1), List.filled(12, 2)]))
    ]);
    await expectLater(
        _http(
            client,
            () => const NikoUpdater(limits: NikoUpdateLimits(downloadBytes: 16))
                .downloadAsset(asset, directory, null)),
        throwsFormatException);
    expect(client.closed, isTrue);
    expect(directory.listSync(), isEmpty);
  });

  test('a truncated known-length download is never returned as complete',
      () async {
    final client = _Client([
      _Response.stream(Stream.value([1, 2, 3]), contentLength: 9)
    ]);
    await expectLater(
        _http(client,
            () => const NikoUpdater().downloadAsset(asset, directory, null)),
        throwsFormatException);
    expect(client.closed, isTrue);
    expect(directory.listSync(), isEmpty);
  });

  test('a stalled response times out and releases its stream and partial file',
      () async {
    final body = StreamController<List<int>>();
    var cancelled = false;
    body.onCancel = () => cancelled = true;
    final client = _Client([_Response.stream(body.stream)]);
    await expectLater(
        _http(
            client,
            () => const NikoUpdater(
                    limits: NikoUpdateLimits(
                        idleTimeout: Duration(milliseconds: 50)))
                .downloadAsset(asset, directory, null)),
        throwsA(isA<TimeoutException>()));
    expect(cancelled, isTrue);
    expect(client.closed, isTrue);
    expect(directory.listSync(), isEmpty);
    await body.close();
  });

  test(
      'cancellation during transfer releases bytes without completing an asset',
      () async {
    final cancellation = NikoUpdateCancellation();
    final client = _Client([
      _Response([1, 2, 3])
    ]);
    await expectLater(
        _http(
            client,
            () => const NikoUpdater().downloadAsset(
                asset, directory, (_, __) => cancellation.cancel(),
                cancellation: cancellation)),
        throwsA(isA<NikoUpdateCancelled>()));
    expect(client.closed, isTrue);
    expect(directory.listSync(), isEmpty);
  });

  test('an already cancelled update never opens a connection', () async {
    final cancellation = NikoUpdateCancellation()..cancel();
    final client = _Client([]);
    await expectLater(
        _http(
            client,
            () => const NikoUpdater().downloadAsset(asset, directory, null,
                cancellation: cancellation)),
        throwsA(isA<NikoUpdateCancelled>()));
    expect(client.requested, isEmpty);
    expect(directory.listSync(), isEmpty);
  });

  test('total budget stops a continuously active slow download', () async {
    Stream<List<int>> slow() async* {
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        yield [i];
      }
    }

    final client = _Client([_Response.stream(slow())]);
    await expectLater(
        _http(
            client,
            () => const NikoUpdater(
                    limits: NikoUpdateLimits(
                        idleTimeout: Duration(seconds: 1),
                        totalTimeout: Duration(milliseconds: 90)))
                .downloadAsset(asset, directory, null)),
        throwsA(isA<TimeoutException>()));
    expect(client.closed, isTrue);
    expect(directory.listSync(), isEmpty);
  });

  Future<bool> stage(List<int> bytes, _Processes processes, {String? digest}) {
    final client = _Client([
      _Response(bytes),
      _Response(
          utf8.encode('${digest ?? sha256.convert(bytes)}  ${asset.name}\n'))
    ]);
    final release =
        NikoReleaseInfo(tag: 'v1.1.0', notes: '', assets: [asset, sums]);
    return _http(
        client,
        () => NikoUpdater(runProcess: processes.run)
            .verifyAndStageMacUpdate(release, asset, directory));
  }

  test(
      'verified bundle only reveals the staging directory and never replaces the installation',
      () async {
    final processes = _Processes();
    expect(await stage(_zip(_bundleFiles), processes), isTrue);
    await NikoUpdater(runProcess: processes.run)
        .revealStagedMacUpdate(directory);
    expect(processes.calls.last.$1, '/usr/bin/open');
    expect(
        processes.calls.last.$2, ['-R', '${directory.path}/mac/NikoDesk.app']);
    expect(
        processes.calls.any((call) =>
            call.$1.contains('sh') ||
            call.$2.any((arg) => arg.contains('/Applications/'))),
        isFalse);
    expect(
        directory
            .listSync(recursive: true)
            .where((entry) => entry.path.endsWith('apply.sh')),
        isEmpty);
    expect(
        processes.calls.any((call) =>
            call.$1 == '/usr/bin/codesign' &&
            call.$2.take(3).join(' ') == '--verify --deep --strict'),
        isTrue);
  });

  test('digest mismatch refuses extraction', () async {
    final processes = _Processes();
    expect(
        await stage(_zip(_bundleFiles), processes, digest: '0' * 64), isFalse);
    expect(processes.calls, isEmpty);
    expect(directory.listSync(), isEmpty);
  });

  test('understated expanded ZIP sizes fail before extraction', () async {
    final bytes = Uint8List.fromList(_zip(_bundleFiles));
    final data = ByteData.sublistView(bytes);
    for (var offset = 0; offset + 46 < bytes.length; offset++) {
      final signature = data.getUint32(offset, Endian.little);
      if (signature == 0x04034b50) {
        data.setUint32(offset + 22, 1, Endian.little);
      } else if (signature == 0x02014b50) {
        data.setUint32(offset + 24, 1, Endian.little);
      }
    }
    final processes = _Processes();
    expect(await stage(bytes, processes), isFalse);
    expect(processes.calls, isEmpty);
    expect(directory.listSync(), isEmpty);
  });

  test('cancelling while verifying a staged bundle never opens Finder',
      () async {
    final processes = _Processes();
    expect(await stage(_zip(_bundleFiles), processes), isTrue);
    final cancellation = NikoUpdateCancellation()..cancel();
    await expectLater(
        NikoUpdater(runProcess: processes.run)
            .revealStagedMacUpdate(directory, cancellation: cancellation),
        throwsA(isA<NikoUpdateCancelled>()));
    expect(processes.calls.any((call) => call.$1 == '/usr/bin/open'), isFalse);
  });

  for (final limit in [
    const NikoUpdateLimits(archiveEntries: 2),
    const NikoUpdateLimits(expandedBytes: 8),
    const NikoUpdateLimits(entryBytes: 4),
  ]) {
    test('archive resource budget is checked before extraction $limit',
        () async {
      final bytes = _zip(_bundleFiles);
      final processes = _Processes();
      final client = _Client([
        _Response(bytes),
        _Response(utf8.encode('${sha256.convert(bytes)}  ${asset.name}\n'))
      ]);
      final release =
          NikoReleaseInfo(tag: 'v1.1.0', notes: '', assets: [asset, sums]);
      expect(
          await _http(
              client,
              () => NikoUpdater(limits: limit, runProcess: processes.run)
                  .verifyAndStageMacUpdate(release, asset, directory)),
          isFalse);
      expect(processes.calls, isEmpty);
      expect(directory.listSync(), isEmpty);
    });
  }

  test('post-extraction verification failure removes the owned staging bundle',
      () async {
    final processes = _Processes()..signatureExit = 1;
    expect(await stage(_zip(_bundleFiles), processes), isFalse);
    expect(directory.listSync(), isEmpty);
  });

  for (final name in [
    '/tmp/escape',
    '../escape',
    'NikoDesk.app/../escape',
    'NikoDesk.app\\escape'
  ]) {
    test('unsafe ZIP path $name is rejected before extraction', () async {
      final processes = _Processes();
      expect(await stage(_zip({..._bundleFiles, name: 'unsafe'}), processes),
          isFalse);
      expect(processes.calls, isEmpty);
    });
  }

  test('escaping symlink is rejected before extraction', () async {
    final processes = _Processes();
    expect(
        await stage(
            _zip(_bundleFiles, links: {'NikoDesk.app/escape': '../../outside'}),
            processes),
        isFalse);
    expect(processes.calls, isEmpty);
  });

  test('writing through a symlink is rejected before extraction', () async {
    final processes = _Processes();
    expect(
        await stage(
            _zip({..._bundleFiles, 'NikoDesk.app/link/file': 'unsafe'},
                links: {'NikoDesk.app/link': 'Contents'}),
            processes),
        isFalse);
    expect(processes.calls, isEmpty);
  });

  for (final failure in [
    'signature',
    'identifier',
    'architecture',
    'core',
    'symlink'
  ]) {
    test('staged bundle with invalid $failure is refused', () async {
      final processes = _Processes();
      if (failure == 'signature') processes.signatureExit = 1;
      if (failure == 'identifier') {
        processes.identifier = 'com.carriez.rustdesk';
      }
      if (failure == 'architecture') processes.architecture = 'x86_64';
      if (failure == 'symlink') processes.injectedLink = directory.parent.path;
      final files = Map.of(_bundleFiles);
      if (failure == 'core') {
        files.remove('NikoDesk.app/Contents/Frameworks/liblibrustdesk.dylib');
      }
      expect(await stage(_zip(files), processes), isFalse);
      expect(
          processes.calls.any((call) => call.$1 == '/usr/bin/open'), isFalse);
    });
  }
}
