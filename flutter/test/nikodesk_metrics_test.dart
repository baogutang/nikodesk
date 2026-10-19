import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/nikodesk/metrics.dart';

void main() {
  late SessionMetrics metrics;
  late Duration tick;
  setUp(() {
    tick = Duration.zero;
    metrics =
        SessionMetrics(now: () => DateTime.utc(2026, 9, 29), tick: () => tick);
  });
  test('unknown fields are null and are never invented zeros', () {
    for (final key in SessionMetrics.specs.keys) {
      expect(metrics.current(key), isNull);
    }
    expect(metrics.secure, isNull);
  });
  test('controlled-side stats are bounded and name what caps the frame rate',
      () {
    metrics.hostVideo(jsonEncode({
      'display': 0,
      'width': 3200,
      'height': 1800,
      'encoder': 'H265',
      'hardware': true,
      'fps': 54.2,
      'limit': 60.0,
      'refreshHz': 75.0,
      'captureMs': 3.0,
      'convertMs': 2.0,
      'encodeMs': 1.0,
      'captureIncludesWait': false,
    }));
    final host =
        (metrics.current('hostVideo') as Map<String, NikoHostVideo>)['0']!;
    expect(host.processingMaxFps, closeTo(166.7, 0.1));
    expect(
        nikoFrameCap(
                limit: host.limit,
                refreshHz: host.refreshHz,
                hostMaxFps: host.processingMaxFps)!
            .reason,
        NikoFrameCapReason.setting);
    final display = nikoFrameCap(limit: 120, refreshHz: 75, hostMaxFps: 160)!;
    expect((display.fps, display.reason), (75.0, NikoFrameCapReason.display));
    expect(nikoFrameCap(limit: 120, refreshHz: 120, hostMaxFps: 90)!.reason,
        NikoFrameCapReason.hostProcessing);
    expect(nikoFrameCap(limit: 120, localDecodeMs: 12.5)!.reason,
        NikoFrameCapReason.localDecode);
    expect(nikoFrameCap(), isNull);

    // Waiting for a new picture is not work: Windows capture excludes it.
    final waiting = NikoHostVideo.parse(jsonEncode({
      'display': 1,
      'width': 3840,
      'height': 2160,
      'captureMs': 15.0,
      'convertMs': 2.0,
      'encodeMs': 2.0,
      'captureIncludesWait': true,
    }))!;
    expect(waiting.processingMaxFps, 250);

    for (final bad in [
      'not json',
      jsonEncode({'display': -1, 'width': 10, 'height': 10}),
      jsonEncode({'display': 0, 'width': 0, 'height': 10}),
      jsonEncode({'display': 0, 'width': 99999, 'height': 10}),
    ]) {
      expect(NikoHostVideo.parse(bad), isNull, reason: bad);
    }
    final odd = NikoHostVideo.parse(jsonEncode({
      'display': 0,
      'width': 10,
      'height': 10,
      'encoder': '<b>x</b>',
      'fps': -3,
      'refreshHz': 5000,
    }))!;
    expect((odd.encoder, odd.fps, odd.refreshHz), ('', null, null));
  });

  test('quality event units preserve real values and per-display missingness',
      () {
    metrics.update({
      'speed': '12.50kB/s',
      'fps': '{"0":30,"2":0}',
      'delay': '27',
      'target_bitrate': '1400',
      'codec_format': 'VP9',
      'chroma': '4:2:0'
    });
    expect(metrics.current('receiveKiBps'), 12.5);
    expect(metrics.current('decodedCallbackFps'), {'0': 30, '2': 0});
    expect(metrics.current('applicationRttMs'), 27);
    expect(metrics.current('targetBitrateKbps'), 1400);
    expect(metrics.current('receivedCodec'), 'VP9');
  });
  test('each field expires from its own monotonic receipt time', () {
    metrics.update({'speed': '1.00kB/s', 'delay': '35'});
    tick = const Duration(seconds: 9);
    metrics.update({'speed': '2.00kB/s', 'delay': ''});
    tick = const Duration(seconds: 11);
    expect(metrics.current('receiveKiBps'), 2);
    expect(metrics.current('applicationRttMs'), isNull);
    expect(metrics.isStale('applicationRttMs'), isTrue);
    expect(metrics.export()['metrics'], isA<Map>());
  });
  test('malformed or private strings cannot enter diagnostic exports', () {
    metrics.update({
      'speed': 'secret-password',
      'delay': '10;192.168.1.1',
      'fps': '{"secret-device":42}',
      'codec_format': 'Bearer secret',
      'chroma': 'clipboard content',
      'target_bitrate': '-1',
      'password': 'never-export',
      'peer_id': '123456789'
    });
    metrics.connection(secure: true, direct: false, transport: '192.168.1.1');
    final report = jsonEncode(metrics.export());
    for (final forbidden in [
      'secret-password',
      '192.168.1.1',
      'secret-device',
      'Bearer secret',
      'clipboard content',
      'never-export',
      '123456789'
    ]) {
      expect(report, isNot(contains(forbidden)));
    }
    expect(metrics.transport, isNull);
  });
  test('independent partial events do not overwrite valid FPS with empty maps',
      () {
    metrics.update({'fps': '{"0":24}'});
    metrics.update({'fps': '{}', 'delay': '20'});
    expect(metrics.current('decodedCallbackFps'), {'0': 24});
    metrics.update({'fps': '{broken'});
    expect(metrics.current('decodedCallbackFps'), {'0': 24});
  });
  test('reconnect and close clear telemetry and authentication samples', () {
    metrics.connection(secure: true, direct: true, transport: 'UDP');
    expect(metrics.markAuthenticated(), isTrue);
    expect(metrics.markAuthenticated(), isFalse);
    metrics.update({'speed': '1.00kB/s'});
    metrics.connection(secure: true, direct: false, transport: 'Relay');
    expect(metrics.current('receiveKiBps'), isNull);
    expect(metrics.authenticatedAt, isNull);
    expect(metrics.transport, 'Relay');
    metrics.clear();
    expect(metrics.secure, isNull);
    expect(metrics.connectionSampledAt, isNull);
  });
  test(
      'reports distinguish target bitrate, application RTT and unsupported timing',
      () {
    final report = metrics.export();
    final specs = report['metrics'] as Map;
    expect(specs['receiveKiBps']['unit'], 'KiB/s');
    expect(specs['applicationRttMs']['limitation'], contains('not ICMP ping'));
    expect(report['unsupported'], contains('inputToPhotonLatency'));
  });
}
