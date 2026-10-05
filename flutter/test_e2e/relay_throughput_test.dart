// How fast the path between the two profiles carries bytes, in the direction
// video travels (controlled side to controller) and back. It moves a file of
// random bytes through the same server path a session uses and prints the
// rate; nothing is asserted about the rate itself.
//   NIKODESK_E2E_MEGABYTES   file size, default 16
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'support/native.dart';

void main() {
  test('measure the byte rate of the session path', () async {
    final native = await NikoNative.instance();
    expect(native.profile, 'ctrl');
    final host =
        File('${env('NIKODESK_E2E_WORK')}/host/id').readAsStringSync().trim();
    final megabytes =
        int.parse(Platform.environment['NIKODESK_E2E_MEGABYTES'] ?? '16');
    final root = Directory('${env('NIKODESK_E2E_WORK')}/throughput');
    if (root.existsSync()) root.deleteSync(recursive: true);
    final local = Directory('${root.path}/local')..createSync(recursive: true);
    final remote = Directory('${root.path}/remote')
      ..createSync(recursive: true);
    addTearDown(() => root.deleteSync(recursive: true));
    final session = await NikoSession.open(native, host,
        password: env('NIKODESK_E2E_HOST_PASSWORD'), fileTransfer: true);
    addTearDown(session.close);
    await session.event((event) => event['name'] == 'peer_info',
        'peer info for the file session');

    final random = Random(20261005);
    final bytes = Uint8List(megabytes * 1024 * 1024);
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = random.nextInt(256);
    }

    Future<void> move(int id, String label, {required bool fromHost}) async {
      final source = File('${(fromHost ? remote : local).path}/$label.bin')
        ..writeAsBytesSync(bytes);
      final target = File('${(fromHost ? local : remote).path}/$label.bin');
      final clock = Stopwatch()..start();
      await native.bind.sessionSendFiles(
          sessionId: session.id,
          actId: id,
          path: source.path,
          to: target.path,
          fileNum: 0,
          includeHidden: false,
          isRemote: fromHost,
          isDir: false);
      final result = await session.event(
          (event) =>
              (event['name'] == 'job_done' || event['name'] == 'job_error') &&
              '${event['id']}' == '$id',
          'completion of the $label transfer',
          timeout: const Duration(minutes: 4));
      final seconds = clock.elapsedMilliseconds / 1000;
      expect(result['name'], 'job_done', reason: '$label failed: $result');
      expect(target.lengthSync(), bytes.length);
      // ignore: avoid_print
      print('E2E-THROUGHPUT $label megabytes=$megabytes '
          'seconds=${seconds.toStringAsFixed(1)} '
          'megabits_per_second=${(megabytes * 8 / seconds).toStringAsFixed(1)}');
    }

    await move(1, 'host-to-controller', fromHost: true);
    await move(2, 'controller-to-host', fromHost: false);
  }, timeout: const Timeout(Duration(minutes: 10)));
}
