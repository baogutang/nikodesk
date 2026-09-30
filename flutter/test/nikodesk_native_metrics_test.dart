import 'dart:async';
import 'dart:convert';

import 'package:flutter_hbb/nikodesk/metrics.dart';
import 'package:flutter_test/flutter_test.dart';

const scope =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
Map<String, dynamic> header({String epoch = '1', String namespace = scope}) => {
      'secure': 'true',
      'direct': 'true',
      'stream_type': 'TCP',
      'niko_video_namespace': namespace,
      'niko_video_epoch': epoch,
      'niko_video_revision': '0',
    };
Map<String, dynamic> authority(
        {String epoch = '1',
        String revision = '0',
        String sequence = '1',
        int age = 0,
        bool enabled = true}) =>
    {
      'namespace': scope,
      'epoch': epoch,
      'revision': revision,
      'sequence': sequence,
      'sampleAgeMs': age,
      'enabled': enabled,
    };
Map<String, dynamic> stage({int samples = 1}) => {
      'samples': samples,
      'totalUs': samples * 1200,
      'maxUs': samples == 0 ? 0 : 1200,
      'histogramUsLog2': List<int>.generate(32, (i) => i == 11 ? samples : 0),
    };
Map<String, dynamic> row(
        {int display = 0,
        String? backend = 'vpx-vp9',
        bool? hardware = false}) =>
    {
      'display': display,
      'decoderBackend': backend,
      'hardwareDecoder': hardware,
      'decodedCallbacks': 30,
      'decodeErrors': 1,
      'deltaOverflow': 2,
      'refreshDiscard': 3,
      'nativeCalls': 25,
      'noTarget': 0,
      'noPointer': 1,
      'sizeMismatch': 0,
      'missingPlugin': 0,
      'softBusy': 2,
      'softNoConsumer': 0,
      'deltaQueueMax': 12,
      'decodeConvert': stage(),
      'nativeSubmit': stage(samples: 0),
    };
Map<String, dynamic> snapshot(
        {String epoch = '1',
        String revision = '0',
        String sequence = '1',
        List<Map<String, dynamic>>? rows}) =>
    {
      'schemaVersion': 1,
      'namespace': scope,
      'epoch': epoch,
      'revision': revision,
      'sequence': sequence,
      'windowMs': 1030,
      'displayLimit': 16,
      'displays': rows ?? [row()],
    };
SessionMetrics ready({String epoch = '1'}) {
  final metrics = SessionMetrics();
  expect(metrics.connectionFromNative(header(epoch: epoch), scope), isTrue);
  metrics.nativeVisibility(true);
  return metrics;
}

void main() {
  test('native data requires a real matching header and current binding', () {
    final metrics = SessionMetrics()..nativeVisibility(true);
    expect(
        metrics.updateNative(
            jsonEncode(snapshot()), jsonEncode(authority()), scope),
        isFalse);
    expect(metrics.current('nativeVideo'), isNull);
    expect(metrics.connectionFromNative(header(), scope), isTrue);
    expect(
        metrics.updateNative(
            jsonEncode(snapshot()), jsonEncode(authority()), scope),
        isTrue);
    expect(metrics.current('decoderBackend'), {'0': 'vpx-vp9'});
    expect(metrics.current('hardwareDecoder'), {'0': false});
    expect(metrics.current('decodeConvertMeanMs'), {'0': 1.2});
    expect(metrics.current('nativeSubmitMeanMs'), {'0': null});
    expect(metrics.current('deltaQueuePeak'), {'0': 12});
    expect(metrics.current('renderSkips'), {'0': 3});
  });
  test(
      'an unobserved zero delta peak stays unknown and accepts no fake empty proof',
      () {
    final metrics = ready();
    expect(
        metrics.updateNative(
            jsonEncode(snapshot(rows: [
              {...row(), 'deltaQueueMax': 0}
            ])),
            jsonEncode(authority()),
            scope),
        isTrue);
    expect(metrics.current('deltaQueuePeak'), {'0': null});
  });
  test('MediaCodec hardware remains unknown and missing displays stay unknown',
      () {
    final metrics = ready();
    expect(
        metrics.updateNative(
            jsonEncode(snapshot(rows: [
              row(display: 3, backend: 'mediacodec', hardware: null)
            ])),
            jsonEncode(authority()),
            scope),
        isTrue);
    expect(metrics.current('hardwareDecoder'), {'3': null});
    expect(metrics.current('decoderBackend'), {'3': 'mediacodec'});
    expect(
        metrics.updateNative(
            jsonEncode(
                snapshot(rows: [row(backend: 'mediacodec', hardware: true)])),
            jsonEncode(authority()),
            scope),
        isFalse);
  });
  test('reconnect headers use exact uint64 strings and cannot roll back', () {
    final metrics = ready(epoch: '18446744073709551614');
    expect(
        metrics.connectionFromNative(
            header(epoch: '18446744073709551615'), scope),
        isTrue);
    expect(
        metrics.connectionFromNative(
            header(epoch: '18446744073709551614'), scope),
        isFalse);
    expect(
        metrics.connectionFromNative(
            header(epoch: '18446744073709551616'), scope),
        isFalse);
    expect(
        metrics.updateNative(
            jsonEncode(snapshot(epoch: '18446744073709551615')),
            jsonEncode(authority(epoch: '18446744073709551615')),
            scope),
        isTrue);
    metrics.clear();
    expect(
        metrics.connectionFromNative(
            header(epoch: '18446744073709551615'), scope),
        isFalse);
  });
  test(
      'cached peer data never invents or erases an authoritative native binding',
      () {
    final metrics = ready();
    metrics.connection(
        secure: false, direct: false, transport: 'Relay', fromCache: true);
    expect(metrics.secure, isTrue);
    expect(
        metrics.updateNative(
            jsonEncode(snapshot()), jsonEncode(authority()), scope),
        isTrue);
    final unbound = SessionMetrics();
    unbound.connection(
        secure: true, direct: true, transport: 'TCP', fromCache: true);
    unbound.nativeVisibility(true);
    expect(
        unbound.updateNative(
            jsonEncode(snapshot()), jsonEncode(authority()), scope),
        isFalse);
    expect(
        unbound.connectionFromNative(
            {...header(), 'niko_video_existing': 'true'}, scope),
        isTrue);
    expect(unbound.authenticatedAt, isNull);
    expect(unbound.connectionFromCache, isTrue);
  });
  test(
      'late revision, window, age, namespace and disabled bindings are rejected',
      () {
    for (final binding in [
      authority(revision: '1'),
      authority(sequence: '2'),
      authority(age: 3001),
      authority(enabled: false),
      {...authority(), 'namespace': 'b' * 64},
      authority(epoch: '2')
    ]) {
      final metrics = ready();
      metrics.updateNative(
          jsonEncode(snapshot()), jsonEncode(authority()), scope);
      expect(
          metrics.updateNative(
              jsonEncode(snapshot()), jsonEncode(binding), scope),
          isFalse);
      expect(metrics.current('nativeVideo'), isNull);
    }
    final metrics = ready();
    metrics.nativeVisibility(false);
    metrics.nativeVisibility(true);
    expect(metrics.current('nativeVideo'), isNull);
    expect(
        metrics.updateNative(jsonEncode(snapshot()),
            jsonEncode(authority(revision: '2')), scope),
        isFalse);
    expect(
        metrics.updateNative(jsonEncode(snapshot(revision: '2')),
            jsonEncode(authority(revision: '2')), scope),
        isTrue);
  });
  test(
      'fixed-size counters, samples, histograms and enums reject invalid payloads',
      () {
    final invalidRows = [
      row(display: 16),
      row(backend: 'Bearer private-value'),
      {...row(), 'deltaQueueMax': 121},
      {...row(), 'nativeCalls': -1},
      {...row(), 'decodeConvert': stage(samples: 9)},
      {
        ...row(),
        'nativeSubmit': {
          ...stage(),
          'histogramUsLog2': [1]
        }
      },
      {
        ...row(),
        'nativeSubmit': {...stage(samples: 0), 'totalUs': 10}
      },
    ];
    for (final invalid in invalidRows) {
      final metrics = ready();
      expect(
          metrics.updateNative(jsonEncode(snapshot(rows: [invalid])),
              jsonEncode(authority()), scope),
          isFalse);
      expect(metrics.current('nativeVideo'), isNull);
    }
    final metrics = ready();
    expect(
        metrics.updateNative(jsonEncode(snapshot(rows: [row(), row()])),
            jsonEncode(authority()), scope),
        isFalse);
    expect(
        metrics.updateNative(
            jsonEncode(
                snapshot(rows: List.generate(17, (i) => row(display: i)))),
            jsonEncode(authority()),
            scope),
        isFalse);
    expect(
        metrics.updateNative(
            'invalid private text', jsonEncode(authority()), scope),
        isFalse);
  });
  test(
      'exports preserve source limits and exclude native identifiers and extras',
      () {
    final metrics = ready();
    final payload = snapshot(rows: [
      {...row(), 'password': 'never-export', 'path': '/private/device'}
    ]);
    expect(
        metrics.updateNative(
            jsonEncode(payload), jsonEncode(authority()), scope),
        isTrue);
    final report = jsonEncode(metrics.export());
    expect(report, isNot(contains(scope)));
    expect(report, isNot(contains('never-export')));
    expect(report, isNot(contains('/private/device')));
    expect(report, contains('void API'));
    expect(report, contains('presentationTime'));
    expect(report, contains('captureTime'));
    expect(report, contains('encodeTime'));
    expect(report, isNot(contains('submittedFps')));
  });
  test(
      'out-of-order async readbacks and panel-close cannot overwrite new samples',
      () async {
    final metrics = ready();
    final old = Completer<Object?>();
    final pending = metrics.readNative(
        jsonEncode(snapshot()), () => old.future, scope,
        isCurrent: () => true);
    expect(
        await metrics.readNative(jsonEncode(snapshot(sequence: '2')),
            () async => jsonEncode(authority(sequence: '2')), scope,
            isCurrent: () => true),
        isTrue);
    old.complete(jsonEncode(authority()));
    expect(await pending, isFalse);
    expect(metrics.current('nativeVideo'), isNotNull);
    final closed = Completer<Object?>();
    final closing = metrics.readNative(
        jsonEncode(snapshot(sequence: '2')), () => closed.future, scope,
        isCurrent: () => true);
    metrics.nativeVisibility(false);
    closed.complete(jsonEncode(authority(sequence: '2')));
    expect(await closing, isFalse);
    expect(metrics.current('nativeVideo'), isNull);
  });
  test(
      'binding failures and owner destruction clear or reject without stale reuse',
      () async {
    final metrics = ready();
    metrics.updateNative(
        jsonEncode(snapshot()), jsonEncode(authority()), scope);
    expect(
        await metrics.readNative(jsonEncode(snapshot()),
            () async => throw StateError('unavailable'), scope,
            isCurrent: () => true),
        isFalse);
    expect(metrics.current('nativeVideo'), isNull);
    expect(
        await metrics.readNative(
            jsonEncode(snapshot()), () async => jsonEncode(authority()), scope,
            isCurrent: () => false),
        isFalse);
    expect(metrics.current('nativeVideo'), isNull);
  });
}
