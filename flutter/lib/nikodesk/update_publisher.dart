import 'dart:convert';
import 'dart:io';

/// The public key is pinned in the installed binary, never in release metadata.
class NikoUpdatePublisher {
  const NikoUpdatePublisher({
    this.publicKeyBase64 =
        const String.fromEnvironment('NIKODESK_UPDATE_PUBLIC_KEY_BASE64'),
  });

  final String publicKeyBase64;

  String? get _publicKey {
    try {
      if (publicKeyBase64.isEmpty || publicKeyBase64.length > 12000)
        return null;
      final pem = utf8.decode(base64Decode(publicKeyBase64));
      if (!RegExp(
              r'^-----BEGIN PUBLIC KEY-----\r?\n[A-Za-z0-9+/=\r\n]+\r?\n-----END PUBLIC KEY-----\s*$')
          .hasMatch(pem)) return null;
      return pem;
    } catch (_) {
      return null;
    }
  }

  bool get configured => _publicKey != null;

  static String? digest(String manifest, String tag, String asset) {
    if (manifest.length > 65536 || !RegExp(r'^v\d+\.\d+\.\d+$').hasMatch(tag))
      return null;
    final lines = const LineSplitter().convert(manifest);
    if (lines.isEmpty || lines.first != '# NikoDesk release $tag') return null;
    final entries = <String, String>{};
    for (final line in lines.skip(1)) {
      if (line.isEmpty) continue;
      final match = RegExp(r'^([0-9a-f]{64})  ([A-Za-z0-9][A-Za-z0-9._-]*)$')
          .firstMatch(line);
      if (match == null || entries.containsKey(match[2])) return null;
      entries[match[2]!] = match[1]!;
    }
    return entries[asset];
  }

  Future<String?> verify({
    required String manifest,
    required String signatureBase64,
    required String tag,
    required String asset,
    required Directory workspace,
    required Future<ProcessResult> Function(String, List<String>) run,
    required void Function() check,
  }) async {
    final key = _publicKey;
    final expected = digest(manifest, tag, asset);
    if (key == null || expected == null || signatureBase64.length > 4096) {
      return null;
    }
    final List<int> signature;
    try {
      signature = base64Decode(signatureBase64.trim());
    } catch (_) {
      return null;
    }
    if (signature.isEmpty || signature.length > 1024) return null;
    check();
    final directory = await workspace.createTemp('publisher-');
    try {
      final keyPath = '${directory.path}/publisher.pem';
      final signaturePath = '${directory.path}/manifest.sig';
      final manifestPath = '${directory.path}/SHA256SUMS';
      await File(keyPath).writeAsString(key);
      await File(signaturePath).writeAsBytes(signature);
      await File(manifestPath).writeAsString(manifest);
      check();
      final result = await run('/usr/bin/openssl', [
        'dgst',
        '-sha256',
        '-verify',
        keyPath,
        '-signature',
        signaturePath,
        manifestPath,
      ]);
      check();
      return result.exitCode == 0 ? expected : null;
    } finally {
      await directory.delete(recursive: true);
    }
  }
}
