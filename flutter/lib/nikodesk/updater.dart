import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:io' as io show ZLibDecoder;

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;

import 'update_transfer.dart';
export 'update_transfer.dart'
    show NikoUpdateCancellation, NikoUpdateCancelled, NikoUpdateLimits;

enum NikoUpdateChannel { stable, nightly }

class _UpdateHttpException extends HttpException {
  final int statusCode;
  _UpdateHttpException(this.statusCode) : super('HTTP $statusCode');
}

/// GitHub-Releases-based update check for NikoDesk.
///
/// Security rules (fail closed):
///  - https only, host must be in the allowlist (no localhost/loopback or
///    private addresses by construction, and every redirect target is
///    re-validated);
///  - the downloaded bundle must match the SHA256 published in the same
///    release's SHA256SUMS asset, otherwise nothing is installed;
///  - verified macOS bundles are shown for manual installation; the running
///    installation is never overwritten by this updater.
class NikoUpdater {
  const NikoUpdater(
      {this.owner = 'baogutang',
      this.repo = 'nikodesk',
      this.limits = const NikoUpdateLimits(),
      @visibleForTesting
      Future<ProcessResult> Function(String, List<String>)? runProcess})
      : _runProcess = runProcess;

  final String owner;
  final String repo;
  final NikoUpdateLimits limits;
  final Future<ProcessResult> Function(String, List<String>)? _runProcess;

  Future<ProcessResult> _run(String executable, List<String> arguments,
          {NikoUpdateTask? task}) =>
      (task ?? NikoUpdateTask(limits, null))
          .run(executable, arguments, _runProcess);

  static const _allowedHosts = {
    'api.github.com',
    'github.com',
    'objects.githubusercontent.com',
    'release-assets.githubusercontent.com',
  };

  static bool isAllowedUri(Uri uri) {
    if (!uri.isScheme('HTTPS')) return false;
    if (!_allowedHosts.contains(uri.host)) return false;
    // Belt and braces: literal loopback/private hosts never match the
    // allowlist, but keep the explicit guard for clarity.
    final host = uri.host.toLowerCase();
    if (host == 'localhost' || host == '::1' || host.endsWith('.local')) {
      return false;
    }
    return true;
  }

  Uri _api(String path) {
    final uri = Uri.https('api.github.com', path);
    if (!isAllowedUri(uri)) throw const FormatException('blocked host');
    return uri;
  }

  Future<List<int>> _readBytes(
      HttpClientResponse response, NikoUpdateTask task, int maximum) async {
    if (response.contentLength > maximum) {
      throw const FormatException('Update response is too large');
    }
    final bytes = <int>[];
    return task.read(response, (chunk) {
      if (bytes.length + chunk.length > maximum) {
        throw const FormatException('Update response is too large');
      }
      bytes.addAll(chunk);
    }, () => bytes);
  }

  Future<HttpClientResponse> _response(HttpClient client, Uri uri,
      NikoUpdateTask task, Map<String, String>? headers) async {
    var current = uri;
    for (var hops = 0; hops <= 5; hops++) {
      if (!isAllowedUri(current)) throw const FormatException('blocked host');
      final request = await task.wait(client.getUrl(current),
          timeout: limits.connectionTimeout);
      request.followRedirects = false;
      headers?.forEach(request.headers.set);
      request.headers.set('Accept', 'application/vnd.github+json');
      final response = await task.wait(request.close());
      if (!response.isRedirect) {
        if (response.statusCode != 200) {
          throw _UpdateHttpException(response.statusCode);
        }
        return response;
      }
      final location = response.headers.value(HttpHeaders.locationHeader);
      if (location == null || hops == 5) {
        throw const FormatException('Invalid update redirect');
      }
      final next = current.resolve(location);
      if (!isAllowedUri(next)) {
        throw const FormatException('redirect to blocked host');
      }
      await _readBytes(response, task, limits.metadataBytes);
      current = next;
    }
    throw const FormatException('Invalid update redirect');
  }

  Future<String> _getString(Uri uri, NikoUpdateTask task,
      {Map<String, String>? headers}) async {
    final client = HttpClient()..connectionTimeout = limits.connectionTimeout;
    try {
      final response = await _response(client, uri, task, headers);
      return utf8
          .decode(await _readBytes(response, task, limits.metadataBytes));
    } finally {
      client.close(force: true);
    }
  }

  /// Latest release info, or null when there is no published release.
  Future<NikoReleaseInfo?> checkLatest(
      {NikoUpdateChannel channel = NikoUpdateChannel.stable,
      NikoUpdateCancellation? cancellation}) async {
    final task = NikoUpdateTask(limits, cancellation);
    final endpoint =
        channel == NikoUpdateChannel.nightly ? 'tags/nightly' : 'latest';
    final String body;
    try {
      body = await _getString(
          _api('/repos/$owner/$repo/releases/$endpoint'), task);
    } on _UpdateHttpException catch (error) {
      if (error.statusCode == 404) return null;
      rethrow;
    }
    final json = jsonDecode(body);
    if (json is! Map<String, dynamic>) {
      throw const FormatException('Invalid update release metadata');
    }
    final tag = json['tag_name'];
    if (tag is! String || tag.isEmpty) {
      throw const FormatException('Invalid update release tag');
    }
    if (json['draft'] == true ||
        (channel == NikoUpdateChannel.nightly && tag != 'nightly') ||
        (channel == NikoUpdateChannel.stable &&
            (tag == 'nightly' || json['prerelease'] == true))) {
      return null;
    }
    if (channel == NikoUpdateChannel.stable &&
        !RegExp(r'^[vV]?\d+\.\d+\.\d+$').hasMatch(tag)) {
      throw const FormatException('Invalid stable update version');
    }
    final assets = <NikoReleaseAsset>[];
    final rawAssets = json['assets'];
    if (rawAssets is List) {
      for (final asset in rawAssets) {
        if (asset is Map<String, dynamic>) {
          final name = asset['name'];
          final url = asset['browser_download_url'];
          if (name is String && url is String) {
            final uri = Uri.parse(url);
            if (isAllowedUri(uri)) {
              assets.add(NikoReleaseAsset(name, uri));
            }
          }
        }
      }
    } else {
      throw const FormatException('Invalid update release assets');
    }
    return NikoReleaseInfo(
      tag: tag,
      notes: json['body'] is String ? json['body'] as String : '',
      assets: assets,
      name: json['name'] is String ? json['name'] as String : null,
      publishedAt: json['published_at'] is String
          ? DateTime.tryParse(json['published_at'] as String)
          : null,
    );
  }

  Uri releasePage(NikoReleaseInfo release) => Uri(
      scheme: 'https',
      host: 'github.com',
      pathSegments: [owner, repo, 'releases', 'tag', release.tag]);

  /// Numeric-aware comparison of dotted versions; tags may carry a v prefix.
  bool isNewer(String currentVersion, String tag) {
    List<int> parse(String value) => value
        .trim()
        .replaceFirst(RegExp('^[vV]'), '')
        .split(RegExp('[+.-]'))
        .map((part) => int.tryParse(part) ?? 0)
        .toList();
    final a = parse(currentVersion);
    final b = parse(tag);
    for (var i = 0; i < a.length || i < b.length; i++) {
      final left = i < a.length ? a[i] : 0;
      final right = i < b.length ? b[i] : 0;
      if (right != left) return right > left;
    }
    return false;
  }

  /// Fetch the release's SHA256SUMS text and return the digest for [asset].
  Future<String?> _expectedDigest(NikoReleaseInfo release,
      NikoReleaseAsset asset, NikoUpdateTask task) async {
    final sums = release.assets
        .where((a) => a.name == 'SHA256SUMS' || a.name.endsWith('SHA256SUMS'))
        .toList();
    if (sums.isEmpty) return null;
    try {
      final text = await _getString(sums.first.url, task);
      for (final line in text.split('\n')) {
        final parts = line.trim().split(RegExp(r'\s+'));
        if (parts.length == 2 &&
            parts[1] == asset.name &&
            RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(parts[0])) {
          return parts[0].toLowerCase();
        }
      }
    } on NikoUpdateCancelled {
      rethrow;
    } on TimeoutException {
      rethrow;
    } catch (_) {}
    return null;
  }

  Future<File> downloadAsset(NikoReleaseAsset asset, Directory target,
          void Function(int received, int total)? onProgress,
          {NikoUpdateCancellation? cancellation}) =>
      _downloadAsset(
          asset, target, onProgress, NikoUpdateTask(limits, cancellation));

  Future<File> _downloadAsset(
      NikoReleaseAsset asset,
      Directory target,
      void Function(int received, int total)? onProgress,
      NikoUpdateTask task) async {
    task.check();
    if (!isAllowedUri(asset.url)) {
      throw const FormatException('blocked asset host');
    }
    if (asset.name.isEmpty ||
        path.basename(asset.name) != asset.name ||
        asset.name.contains('\\') ||
        asset.name == '.' ||
        asset.name == '..') {
      throw const FormatException('invalid asset filename');
    }
    await target.create(recursive: true);
    final file = File('${target.path}/${asset.name}');
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw const FileSystemException('Update destination already exists');
    }
    final partial =
        File('${file.path}.$pid.${DateTime.now().microsecondsSinceEpoch}.part');
    final client = HttpClient()..connectionTimeout = limits.connectionTimeout;
    try {
      final response = await _response(client, asset.url, task, null);
      final total = response.contentLength;
      if (total > limits.downloadBytes) {
        throw const FormatException('Update download is too large');
      }
      var received = 0;
      final sink = partial.openWrite();
      try {
        await task.read(response, (chunk) async {
          received += chunk.length;
          if (received > limits.downloadBytes) {
            throw const FormatException('Update download is too large');
          }
          sink.add(chunk);
          await task.wait(sink.flush());
          onProgress?.call(received, total);
        }, () {});
      } finally {
        await sink.close();
      }
      if (total >= 0 && received != total) {
        throw const FormatException('Incomplete update download');
      }
      task.check();
      await partial.rename(file.path);
      return file;
    } finally {
      client.close(force: true);
      if (await partial.exists()) await partial.delete();
    }
  }

  /// Verify and stage a macOS update without touching the installed app.
  Future<bool> verifyAndStageMacUpdate(
      NikoReleaseInfo release, NikoReleaseAsset asset, Directory staging,
      {void Function(int received, int total)? onProgress,
      NikoUpdateCancellation? cancellation}) async {
    final task = NikoUpdateTask(limits, cancellation);
    final staged = Directory('${staging.path}/mac');
    if (await FileSystemEntity.type(staged.path, followLinks: false) !=
        FileSystemEntityType.notFound) return false;
    File? zip;
    var succeeded = false;
    var ownsStage = false;
    try {
      zip = await _downloadAsset(asset, staging, onProgress, task);
      final expected = await _expectedDigest(release, asset, task);
      if (expected == null) return false;
      final digest = await task.wait(sha256.bind(zip.openRead()).first);
      if (digest.toString() != expected) return false;
      task.check();
      final bytes = await task.wait(zip.readAsBytes());
      await _validateZip(bytes, task);
      await staged.create();
      ownsStage = true;
      final result = await _run(
          '/usr/bin/unzip', ['-q', '-o', zip.path, '-d', staged.path],
          task: task);
      if (result.exitCode != 0 ||
          !await _validMacBundle(staged,
              expectedVersion: release.tag, task: task)) return false;
      task.check();
      succeeded = true;
      return true;
    } on NikoUpdateCancelled {
      rethrow;
    } on TimeoutException {
      rethrow;
    } catch (_) {
      return false;
    } finally {
      if (!succeeded) {
        if (ownsStage && await staged.exists()) {
          await staged.delete(recursive: true);
        }
        if (zip != null && await zip.exists()) await zip.delete();
      }
    }
  }

  Future<void> revealStagedMacUpdate(Directory staging,
      {NikoUpdateCancellation? cancellation}) async {
    final task = NikoUpdateTask(limits, cancellation);
    task.check();
    final staged = Directory('${staging.path}/mac');
    if (!await _validMacBundle(staged, task: task)) {
      throw const FormatException('invalid staged bundle');
    }
    final result = await _run(
        '/usr/bin/open', ['-R', '${staged.path}/NikoDesk.app'],
        task: task);
    if (result.exitCode != 0) {
      throw const FileSystemException(
          'Cannot show the verified update in Finder');
    }
  }

  Future<bool> _validMacBundle(Directory staged,
      {String? expectedVersion, NikoUpdateTask? task}) async {
    task ??= NikoUpdateTask(limits, null);
    task.check();
    final bundle = '${staged.path}/NikoDesk.app';
    if (await FileSystemEntity.type(staged.path, followLinks: false) !=
            FileSystemEntityType.directory ||
        await FileSystemEntity.type(bundle, followLinks: false) !=
            FileSystemEntityType.directory) return false;
    final root = await staged.resolveSymbolicLinks();
    await for (final entry
        in staged.list(recursive: true, followLinks: false)) {
      task.check();
      if (entry is Link) {
        try {
          if (!path.isWithin(root, await entry.resolveSymbolicLinks())) {
            return false;
          }
        } on FileSystemException {
          return false;
        }
      }
    }
    final binaries = [
      '$bundle/Contents/MacOS/NikoDesk',
      '$bundle/Contents/Frameworks/liblibrustdesk.dylib'
    ];
    for (final binary in binaries) {
      if (await FileSystemEntity.type(binary, followLinks: false) !=
          FileSystemEntityType.file) return false;
      final arch = await _run('/usr/bin/lipo', ['-archs', binary], task: task);
      if (arch.exitCode != 0 ||
          !(arch.stdout as String)
              .trim()
              .split(RegExp(r'\s+'))
              .contains('arm64')) {
        return false;
      }
    }
    for (final field in {
      'CFBundleIdentifier': 'io.nikodesk.macos',
      'CFBundleExecutable': 'NikoDesk',
      if (expectedVersion != null)
        'CFBundleShortVersionString':
            expectedVersion.replaceFirst(RegExp('^[vV]'), '')
    }.entries) {
      final value = await _run(
          '/usr/bin/plutil',
          [
            '-extract',
            field.key,
            'raw',
            '-o',
            '-',
            '$bundle/Contents/Info.plist'
          ],
          task: task);
      if (value.exitCode != 0 ||
          (value.stdout as String).trim() != field.value) {
        return false;
      }
    }
    final signature = await _run(
        '/usr/bin/codesign', ['--verify', '--deep', '--strict', bundle],
        task: task);
    return signature.exitCode == 0;
  }

  Future<void> _validateZip(List<int> bytes, NikoUpdateTask task) async {
    final entries = await _zipEntries(bytes, task);
    final links = entries
        .where((entry) => entry.isLink)
        .map((entry) => entry.name)
        .toSet();
    for (final entry in entries) {
      var parent = path.posix.dirname(entry.name);
      while (parent != '.') {
        if (links.contains(parent)) {
          throw const FormatException('archive writes through a symlink');
        }
        parent = path.posix.dirname(parent);
      }
      if (!entry.isLink) continue;
      final target = entry.linkTarget!;
      final resolved = path.posix
          .normalize(path.posix.join(path.posix.dirname(entry.name), target));
      if (target.isEmpty ||
          target.contains(RegExp(r'[\x00\r\n\\]')) ||
          path.posix.isAbsolute(target) ||
          !(resolved == 'NikoDesk.app' ||
              path.posix.isWithin('NikoDesk.app', resolved))) {
        throw const FormatException('archive symlink escapes the bundle');
      }
    }
  }
}

class _ZipEntry {
  final String name;
  final String? linkTarget;
  bool get isLink => linkTarget != null;
  const _ZipEntry(this.name, this.linkTarget);
}

Future<List<_ZipEntry>> _zipEntries(
    List<int> bytes, NikoUpdateTask task) async {
  task.check();
  final directory = ZipDirectory.read(InputStream(bytes));
  final limits = task.limits;
  if (directory.numberOfThisDisk != 0 ||
      directory.diskWithTheStartOfTheCentralDirectory != 0 ||
      directory.fileHeaders.length != directory.totalCentralDirectoryEntries ||
      directory.fileHeaders.isEmpty ||
      directory.fileHeaders.length > limits.archiveEntries) {
    throw const FormatException('unsupported ZIP directory');
  }
  final entries = <_ZipEntry>[];
  final names = <String>{};
  var expanded = 0;
  final archiveBytes = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
  for (final header in directory.fileHeaders) {
    task.check();
    final declared = header.uncompressedSize;
    if (declared == null ||
        declared < 0 ||
        declared > limits.entryBytes ||
        (expanded += declared) > limits.expandedBytes ||
        header.file?.uncompressedSize != declared ||
        header.file?.compressedSize != header.compressedSize ||
        header.file?.compressionMethod != header.compressionMethod) {
      throw const FormatException('ZIP exceeds its resource limit');
    }
    final offset = header.localHeaderOffset;
    if (offset == null || offset < 0 || offset + 30 > bytes.length) {
      throw const FormatException('Invalid ZIP local header');
    }
    final local = ByteData.sublistView(archiveBytes, offset);
    final length = local.getUint16(26, Endian.little);
    if (offset + 30 + length > bytes.length ||
        utf8.decode(bytes.sublist(offset + 30, offset + 30 + length)) !=
            header.filename ||
        local.getUint16(6, Endian.little) != header.generalPurposeBitFlag ||
        local.getUint16(8, Endian.little) != header.compressionMethod) {
      throw const FormatException('Inconsistent ZIP local header');
    }
    final name = header.filename;
    final normalized =
        name.endsWith('/') ? name.substring(0, name.length - 1) : name;
    if (normalized.isEmpty ||
        name.contains(RegExp(r'[\x00\r\n\\*?\[\]]')) ||
        path.posix.isAbsolute(name) ||
        name.split('/').any((part) => part == '..' || part == '.') ||
        !(normalized == 'NikoDesk.app' ||
            path.posix.isWithin('NikoDesk.app', normalized) ||
            normalized == '__MACOSX' ||
            path.posix.isWithin('__MACOSX', normalized)) ||
        !names.add(normalized) ||
        header.file?.filename != name ||
        header.generalPurposeBitFlag & 1 != 0 ||
        ![0, 8].contains(header.compressionMethod)) {
      throw const FormatException('unsafe ZIP entry');
    }
    final isLink =
        ((header.externalFileAttributes ?? 0) >> 16) & 0xf000 == 0xa000;
    if (isLink && !path.posix.isWithin('NikoDesk.app', normalized)) {
      throw const FormatException('unsafe ZIP root symlink');
    }
    if (isLink && (header.uncompressedSize ?? 0) > 4096) {
      throw const FormatException('invalid ZIP symlink');
    }
    final content = <int>[];
    var actual = 0;
    var crc = 0;
    Stream<List<int>> compressed() async* {
      final input = header.file!.rawContent!;
      while (!input.isEOS) {
        task.check();
        final remaining = input.length - input.position;
        yield input
            .readBytes(remaining > 16384 ? 16384 : remaining)
            .toUint8List();
      }
    }

    final stream = header.compressionMethod == 8
        ? compressed().transform(io.ZLibDecoder(raw: true))
        : compressed();
    await task.read(stream, (chunk) {
      actual += chunk.length;
      if (actual > declared || (isLink && actual > 4096)) {
        throw const FormatException('Invalid ZIP expanded size');
      }
      crc = getCrc32(chunk, crc);
      if (isLink) content.addAll(chunk);
    }, () {});
    if (actual != declared || crc != header.crc32) {
      throw const FormatException('Invalid ZIP content');
    }
    entries.add(_ZipEntry(normalized, isLink ? utf8.decode(content) : null));
  }
  return entries;
}

class NikoReleaseAsset {
  final String name;
  final Uri url;
  const NikoReleaseAsset(this.name, this.url);
}

class NikoReleaseInfo {
  final String tag;
  final String notes;
  final List<NikoReleaseAsset> assets;
  final String? name;
  final DateTime? publishedAt;
  const NikoReleaseInfo(
      {required this.tag,
      required this.notes,
      required this.assets,
      this.name,
      this.publishedAt});

  bool get isNightly => tag == 'nightly';
  String get displayName => name?.trim().isNotEmpty == true ? name! : tag;

  NikoReleaseAsset? assetFor(String platform) {
    final prefix = 'NikoDesk-$platform';
    final extensions = platform.startsWith('windows')
        ? ['.exe', '.zip']
        : platform.startsWith('android')
            ? ['.apk']
            : ['.zip'];
    for (final extension in extensions) {
      for (final asset in assets) {
        if (asset.name == '$prefix$extension') {
          return asset;
        }
      }
    }
    return null;
  }
}
