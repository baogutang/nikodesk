// Real file transfer between the two profiles. Both run on this Mac as the
// same user, so the "remote" directory is readable here and transferred bytes
// can be compared directly.
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/native.dart';

String sha256Of(File file) => sha256.convert(file.readAsBytesSync()).toString();

void main() {
  late NikoNative native;
  late NikoSession session;
  late Directory local;
  late Directory remote;

  setUpAll(() async {
    native = await NikoNative.instance();
    expect(native.profile, 'ctrl');
    final host =
        File('${env('NIKODESK_E2E_WORK')}/host/id').readAsStringSync().trim();
    final root = Directory('${env('NIKODESK_E2E_WORK')}/transfer');
    if (root.existsSync()) root.deleteSync(recursive: true);
    local = Directory('${root.path}/local')..createSync(recursive: true);
    remote = Directory('${root.path}/remote')..createSync(recursive: true);
    session = await NikoSession.open(native, host,
        password: env('NIKODESK_E2E_HOST_PASSWORD'), fileTransfer: true);
    await session.event((event) => event['name'] == 'peer_info',
        'peer info for the file session');
  });

  tearDownAll(() => session.close());

  Future<void> job(int id) async {
    final result = await session.event(
        (event) =>
            (event['name'] == 'job_done' || event['name'] == 'job_error') &&
            '${event['id']}' == '$id',
        'completion of transfer job $id',
        timeout: const Duration(seconds: 60));
    expect(result['name'], 'job_done', reason: 'job $id failed: $result');
  }

  test('uploads a file whose bytes arrive intact', () async {
    final random = Random(20261002);
    final source = File('${local.path}/upload.bin')
      ..writeAsBytesSync(Uint8List.fromList(
          List.generate(3 * 1024 * 1024 + 17, (_) => random.nextInt(256))));
    final target = File('${remote.path}/upload.bin');
    await native.bind.sessionSendFiles(
        sessionId: session.id,
        actId: 1,
        path: source.path,
        to: target.path,
        fileNum: 0,
        includeHidden: false,
        isRemote: false,
        isDir: false);
    await job(1);
    expect(target.existsSync(), isTrue);
    expect(sha256Of(target), sha256Of(source));
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('downloads a file whose bytes arrive intact', () async {
    final random = Random(7);
    final source = File('${remote.path}/download.bin')
      ..writeAsBytesSync(Uint8List.fromList(
          List.generate(2 * 1024 * 1024 + 5, (_) => random.nextInt(256))));
    final target = File('${local.path}/download.bin');
    await native.bind.sessionSendFiles(
        sessionId: session.id,
        actId: 2,
        path: source.path,
        to: target.path,
        fileNum: 0,
        includeHidden: false,
        isRemote: true,
        isDir: false);
    await job(2);
    expect(target.existsSync(), isTrue);
    expect(sha256Of(target), sha256Of(source));
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('lists the remote directory', () async {
    final seen = session.events.length;
    await native.bind.sessionReadRemoteDir(
        sessionId: session.id, path: remote.path, includeHidden: false);
    final listing = await session.event(
        (event) =>
            event['name'] == 'file_dir' &&
            session.events.indexOf(event) >= seen &&
            '${event['value']}'.contains('download.bin'),
        'remote directory listing');
    expect('${listing['value']}', contains('upload.bin'));
  }, timeout: const Timeout(Duration(minutes: 1)));
}
