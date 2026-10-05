// The picture modes are requests built by the production mapping. This checks
// on a real session that the controlled side actually changes what it sends.
import 'dart:io';

import 'package:flutter_hbb/nikodesk/policy.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/native.dart';

void main() {
  test('each picture mode changes the stream the controlled side sends',
      () async {
    final native = await NikoNative.instance();
    expect(native.profile, 'ctrl');
    final host =
        File('${env('NIKODESK_E2E_WORK')}/host/id').readAsStringSync().trim();
    final session = await NikoSession.open(native, host,
        password: env('NIKODESK_E2E_HOST_PASSWORD'));
    addTearDown(session.close);
    // The mode is saved per device; leave the default behind for later runs.
    addTearDown(() => native.bind
        .sessionSetImageQuality(sessionId: session.id, value: 'balanced'));
    await session.event(
        (event) => event['name'] == 'peer_info', 'peer info after login');
    await session.until(() => session.frames > 0, 'first decoded frame');

    Future<({int bitrate, double fps})> observe(PictureMode mode) async {
      final request = PictureRequest.forMode(mode);
      await native.bind.sessionSetImageQuality(
          sessionId: session.id, value: request.imageQuality);
      if (request.bitratePercent != null) {
        await native.bind.sessionSetCustomImageQuality(
            sessionId: session.id, value: request.bitratePercent!);
      }
      if (request.requestsCustomFps) {
        await native.bind
            .sessionSetCustomFps(sessionId: session.id, fps: request.fps!);
      }
      // Give the controlled side time to apply the request and report it.
      await Future<void>.delayed(const Duration(seconds: 4));
      final before = session.frames;
      await Future<void>.delayed(const Duration(seconds: 5));
      final fps = (session.frames - before) / 5;
      final bitrate = int.parse(session.quality()['target_bitrate'] ?? '0');
      // ignore: avoid_print
      print('E2E-MODE ${mode.name}: request=${request.imageQuality}'
          '${request.bitratePercent == null ? '' : ' ${request.bitratePercent}%'}'
          '${request.fps == null ? '' : ' ${request.fps}fps'} '
          'target_bitrate=${bitrate}kbps decoded_fps=${fps.toStringAsFixed(1)}');
      return (bitrate: bitrate, fps: fps);
    }

    final smooth = await observe(PictureMode.smooth);
    final office = await observe(PictureMode.office);
    final constrained = await observe(PictureMode.constrained);
    expect(smooth.bitrate, greaterThan(0));
    expect(office.bitrate, greaterThan(smooth.bitrate),
        reason: 'office clarity should request more bitrate than smooth');
    expect(constrained.bitrate, lessThan(smooth.bitrate),
        reason: 'the weak-network mode should request less bitrate');
    expect(constrained.fps, lessThanOrEqualTo(15 * 1.3),
        reason: 'the weak-network mode caps the frame rate at 15');
    // Above 30 only shows when the controlled screen is changing that often
    // and the path carries it; the request itself is what is checked here.
    expect(PictureRequest.forMode(PictureMode.smooth).fps, 60);
  }, timeout: const Timeout(Duration(minutes: 4)));
}
