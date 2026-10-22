// Observes a real desktop session for a while and prints what was measured.
// Nothing here is a pass threshold: frame counts depend on how much the
// controlled screen changes. The assertions only require a working stream.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/native.dart';

int percentile(List<int> sorted, double p) =>
    sorted.isEmpty ? -1 : sorted[((sorted.length - 1) * p).round()];

void main() {
  test('observe steady-state video', () async {
    final native = await NikoNative.instance();
    expect(native.profile, 'ctrl');
    final host =
        File('${env('NIKODESK_E2E_WORK')}/host/id').readAsStringSync().trim();
    final seconds =
        int.parse(Platform.environment['NIKODESK_E2E_SECONDS'] ?? '30');
    final quality = Platform.environment['NIKODESK_E2E_IMAGE_QUALITY'] ?? '';
    final session = await NikoSession.open(native, host,
        password: env('NIKODESK_E2E_HOST_PASSWORD'));
    addTearDown(session.close);
    await session.event(
        (event) => event['name'] == 'peer_info', 'peer info after login');
    await session.until(() => session.frames > 0, 'first decoded frame');
    if (quality.isNotEmpty) {
      await native.bind
          .sessionSetImageQuality(sessionId: session.id, value: quality);
    }
    // Optional baseline settings, as in host_video_stats_test.
    final fps = Platform.environment['NIKODESK_E2E_FPS'] ?? '';
    if (fps.isNotEmpty) {
      await native.bind
          .sessionSetCustomFps(sessionId: session.id, fps: int.parse(fps));
    }
    final width = Platform.environment['NIKODESK_E2E_CAPTURE_WIDTH'] ?? '';
    if (width.isNotEmpty) {
      await native.bind.sessionPeerOption(
          sessionId: session.id, name: 'nikodesk-capture-width', value: width);
      addTearDown(() => native.bind.sessionPeerOption(
          sessionId: session.id, name: 'nikodesk-capture-width', value: ''));
    }
    // Let the stream settle before sampling; the frame limit ramps up for
    // about fifteen seconds after a session starts.
    await Future<void>.delayed(
        Duration(seconds: fps.isNotEmpty || width.isNotEmpty ? 15 : 3));

    final arrivals = <int>[];
    final perSecond = <int>[];
    final clock = Stopwatch()..start();
    var last = session.frames;
    var lastSecond = session.frames;
    while (clock.elapsed < Duration(seconds: seconds)) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
      if (session.frames != last) {
        arrivals.add(clock.elapsedMicroseconds);
        last = session.frames;
      }
      if (clock.elapsed.inSeconds > perSecond.length) {
        perSecond.add(session.frames - lastSecond);
        lastSecond = session.frames;
      }
    }
    final intervals = [
      for (var i = 1; i < arrivals.length; i++)
        (arrivals[i] - arrivals[i - 1]) ~/ 1000
    ]..sort();
    final delays = session
        .named('update_quality_status')
        .map((event) => int.tryParse('${event['delay']}'))
        .whereType<int>()
        .toList()
      ..sort();
    expect(arrivals, isNotEmpty, reason: 'no frames during the observation');
    // ignore: avoid_print
    print(
        'E2E-VIDEO seconds=$seconds quality=${quality.isEmpty ? 'default' : quality} '
        'fps_limit=${fps.isEmpty ? 'default' : fps} capture_width=${width.isEmpty ? 'default' : width} '
        'frames=${arrivals.length} '
        'interval_ms p50=${percentile(intervals, 0.5)} p95=${percentile(intervals, 0.95)} '
        'max=${intervals.isEmpty ? -1 : intervals.last} '
        'rtt_ms p50=${percentile(delays, 0.5)} p95=${percentile(delays, 0.95)} '
        'per_second=$perSecond last=${session.quality()}');
  }, timeout: const Timeout(Duration(minutes: 10)));
}
