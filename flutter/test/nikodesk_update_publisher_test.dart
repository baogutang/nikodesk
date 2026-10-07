import 'dart:convert';
import 'dart:io';

import 'package:flutter_hbb/nikodesk/update_publisher.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final digest = 'a' * 64;
  const asset = 'NikoDesk-macos-arm64.zip';
  final manifest = '# NikoDesk release v1.0.7\n$digest  $asset\n';

  test('manifest binds version, exact asset, digest and unique entries', () {
    expect(NikoUpdatePublisher.digest(manifest, 'v1.0.7', asset), digest);
    for (final invalid in [
      manifest.replaceFirst('v1.0.7', 'v1.0.6'),
      '$manifest$digest  $asset\n',
      manifest.replaceFirst(digest, 'A' * 64),
      manifest.replaceFirst(asset, '../$asset'),
      '$manifest unexpected-line\n',
      ' ' * 65537,
    ]) {
      expect(NikoUpdatePublisher.digest(invalid, 'v1.0.7', asset), isNull);
    }
    expect(NikoUpdatePublisher.digest(manifest, 'nightly', asset), isNull);
    expect(NikoUpdatePublisher.digest(manifest, 'v1.0.7', 'other.zip'), isNull);
    expect(const NikoUpdatePublisher().configured, isFalse);
    expect(const NikoUpdatePublisher(publicKeyBase64: 'invalid').configured,
        isFalse);
  });

  test(
      'real signature rejects modified content, wrong key and corrupt signature',
      () async {
    final directory = await Directory.systemTemp.createTemp('niko-publisher-');
    Future<ProcessResult> run(String program, List<String> args) =>
        Process.run(program, args);
    Future<void> openssl(List<String> args) async {
      final result = await run('/usr/bin/openssl', args);
      expect(result.exitCode, 0, reason: '${result.stderr}');
    }

    try {
      final key = '${directory.path}/test-only-private.pem';
      final public = '${directory.path}/public.pem';
      final source = '${directory.path}/SHA256SUMS';
      final signature = '${directory.path}/signature';
      await openssl(['genrsa', '-out', key, '2048']);
      await openssl(['rsa', '-in', key, '-pubout', '-out', public]);
      final publisher = NikoUpdatePublisher(
          publicKeyBase64: base64Encode(await File(public).readAsBytes()));
      await File(source).writeAsString(manifest);
      await openssl(
          ['dgst', '-sha256', '-sign', key, '-out', signature, source]);
      final signed = base64Encode(await File(signature).readAsBytes());
      Future<String?> verify(NikoUpdatePublisher verifier, String content,
              String signatureText) =>
          verifier.verify(
              manifest: content,
              signatureBase64: signatureText,
              tag: 'v1.0.7',
              asset: asset,
              workspace: directory,
              run: run,
              check: () {});
      expect(await verify(publisher, manifest, signed), digest);
      expect(
          await verify(
              publisher, manifest.replaceFirst(digest, 'b' * 64), signed),
          isNull);
      expect(await verify(publisher, manifest, 'not-base64'), isNull);
      expect(
          await verify(publisher, manifest, base64Encode([1, 2, 3])), isNull);
      await openssl(['genrsa', '-out', key, '2048']);
      await openssl(['rsa', '-in', key, '-pubout', '-out', public]);
      final wrong = NikoUpdatePublisher(
          publicKeyBase64: base64Encode(await File(public).readAsBytes()));
      expect(await verify(wrong, manifest, signed), isNull);
      expect(directory.listSync().whereType<Directory>(), isEmpty);
    } finally {
      await directory.delete(recursive: true);
    }
  }, skip: !Platform.isMacOS && !Platform.isLinux);
}
