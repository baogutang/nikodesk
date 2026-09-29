import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

/// GitHub-Releases-based update check for NikoDesk.
///
/// Security rules (fail closed):
///  - https only, host must be in the allowlist (no localhost/loopback or
///    private addresses by construction, and every redirect target is
///    re-validated);
///  - the downloaded bundle must match the SHA256 published in the same
///    release's SHA256SUMS asset, otherwise nothing is installed;
///  - only the macOS bundle is auto-applied; other platforms are directed to
///    the release page.
class NikoUpdater {
  const NikoUpdater({this.owner = 'baogutang', this.repo = 'nikodesk'});

  final String owner;
  final String repo;

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

  Future<String> _getString(Uri uri,
      {Map<String, String>? headers}) async {
    final client = HttpClient();
    try {
      var request = await client.getUrl(uri);
      headers?.forEach(request.headers.set);
      request.headers.set('Accept', 'application/vnd.github+json');
      var response = await request.close();
      // Follow redirects only within the allowlist.
      var hops = 0;
      while (response.isRedirect && hops < 5) {
        final location = response.headers.value(HttpHeaders.locationHeader);
        if (location == null) break;
        final next = Uri.parse(location);
        if (!isAllowedUri(next)) {
          throw const FormatException('redirect to blocked host');
        }
        request = await client.getUrl(next);
        response = await request.close();
        hops++;
      }
      if (response.statusCode != 200) {
        throw HttpException('HTTP ${response.statusCode}');
      }
      return await response.transform(utf8.decoder).join();
    } finally {
      client.close(force: true);
    }
  }

  /// Latest release info, or null when there is no published release.
  Future<NikoReleaseInfo?> checkLatest() async {
    final body =
        await _getString(_api('/repos/$owner/$repo/releases/latest'));
    final json = jsonDecode(body);
    if (json is! Map<String, dynamic>) return null;
    final tag = json['tag_name'];
    if (tag is! String || tag.isEmpty) return null;
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
    }
    return NikoReleaseInfo(
      tag: tag,
      notes: json['body'] is String ? json['body'] as String : '',
      assets: assets,
    );
  }

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
  Future<String?> _expectedDigest(
      NikoReleaseInfo release, NikoReleaseAsset asset) async {
    final sums = release.assets
        .where((a) => a.name == 'SHA256SUMS' || a.name.endsWith('SHA256SUMS'))
        .toList();
    if (sums.isEmpty) return null;
    try {
      final text = await _getString(sums.first.url);
      for (final line in text.split('\n')) {
        final parts = line.trim().split(RegExp(r'\s+'));
        if (parts.length == 2 && parts[1] == asset.name) {
          return parts[0].toLowerCase();
        }
      }
    } catch (_) {}
    return null;
  }

  Future<File> downloadAsset(NikoReleaseAsset asset, Directory target,
      void Function(int received, int total)? onProgress) async {
    if (!isAllowedUri(asset.url)) {
      throw const FormatException('blocked asset host');
    }
    await target.create(recursive: true);
    final file = File('${target.path}/${asset.name}');
    final client = HttpClient();
    try {
      var request = await client.getUrl(asset.url);
      var response = await request.close();
      var hops = 0;
      while (response.isRedirect && hops < 5) {
        final location =
            response.headers.value(HttpHeaders.locationHeader);
        if (location == null) break;
        final next = Uri.parse(location);
        if (!isAllowedUri(next)) {
          throw const FormatException('redirect to blocked host');
        }
        request = await client.getUrl(next);
        response = await request.close();
        hops++;
      }
      if (response.statusCode != 200) {
        throw HttpException('HTTP ${response.statusCode}');
      }
      final total = response.contentLength;
      var received = 0;
      final sink = file.openWrite();
      try {
        await for (final chunk in response) {
          sink.add(chunk);
          received += chunk.length;
          onProgress?.call(received, total);
        }
      } finally {
        await sink.close();
      }
    } finally {
      client.close(force: true);
    }
    return file;
  }

  /// Verify then apply a macOS update: unzip to a staging dir, spawn a
  /// detached swap script, and let the caller exit the app.
  Future<bool> verifyAndStageMacUpdate(
      NikoReleaseInfo release, NikoReleaseAsset asset, Directory staging,
      {void Function(int received, int total)? onProgress}) async {
    final zip = await downloadAsset(asset, staging, onProgress);
    final expected = await _expectedDigest(release, asset);
    if (expected == null) {
      debugPrint('nikodesk update: release has no SHA256SUMS, refusing');
      return false;
    }
    final digest = sha256.convert(await zip.readAsBytes()).toString();
    if (digest != expected) {
      debugPrint('nikodesk update: digest mismatch, refusing');
      return false;
    }
    final staged = Directory('${staging.path}/mac');
    if (await staged.exists()) {
      await staged.delete(recursive: true);
    }
    final result = await Process.run('/usr/bin/unzip',
        ['-q', '-o', zip.path, '-d', staged.path]);
    if (result.exitCode != 0) {
      debugPrint('nikodesk update: unzip failed ${result.stderr}');
      return false;
    }
    if (!await File('${staged.path}/NikoDesk.app/Contents/MacOS/NikoDesk')
        .exists()) {
      debugPrint('nikodesk update: bundle missing executable');
      return false;
    }
    return true;
  }

  /// Swap /Applications/NikoDesk.app with the staged bundle and relaunch.
  /// The script runs detached so it survives this app exiting.
  void applyStagedMacUpdate(Directory staging) {
    final script = '''
sleep 1
rm -rf /Applications/NikoDesk.app
ditto "${staging.path}/mac/NikoDesk.app" /Applications/NikoDesk.app
open /Applications/NikoDesk.app
rm -rf "${staging.path}"
''';
    final file = File('${staging.path}/apply.sh');
    file.writeAsStringSync(script, flush: true);
    Process.start('/bin/sh', [file.path], mode: ProcessStartMode.detached);
  }
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
  const NikoReleaseInfo(
      {required this.tag, required this.notes, required this.assets});

  NikoReleaseAsset? assetFor(String platform) {
    final prefix = 'NikoDesk-$platform';
    for (final asset in assets) {
      if (asset.name.startsWith(prefix) && asset.name.endsWith('.zip')) {
        return asset;
      }
    }
    return null;
  }
}
