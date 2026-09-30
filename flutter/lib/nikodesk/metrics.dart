import 'dart:convert';

class MetricSample {
  final Object value;
  final DateTime sampledAt;
  final Duration tick;
  const MetricSample(this.value, this.sampledAt, this.tick);
}

class MetricSpec {
  final String unit;
  final String source;
  final String limitation;
  const MetricSpec(this.unit, this.source, this.limitation);
}

/// Numeric/enum allowlists keep peer-supplied strings out of exported reports.
class SessionMetrics {
  static const staleAfter = Duration(seconds: 10);
  static const specs = <String, MetricSpec>{
    'receiveKiBps': MetricSpec('KiB/s', 'update_quality_status.speed',
        'All received protocol messages; approximately one-second window, not video bitrate.'),
    'decodedCallbackFps': MetricSpec(
        'frames/s per display',
        'update_quality_status.fps',
        'Decoded video callbacks counted before renderer submission; not accepted or presented frames; empty samples stay unknown.'),
    'applicationRttMs': MetricSpec('ms', 'update_quality_status.delay',
        'Application probe round trip; not ICMP ping, one-way or input-to-photon latency.'),
    'targetBitrateKbps': MetricSpec(
        'kbps',
        'update_quality_status.target_bitrate',
        'Target encoder bitrate snapshot; not measured throughput.'),
    'receivedCodec': MetricSpec('codec', 'update_quality_status.codec_format',
        'Received codec family; this field alone does not identify hardware implementation or explain fallback.'),
    'decoderBackend': MetricSpec(
        'backend per display',
        'native decoder instance after successful output',
        'Actual implementation, not requested codec settings; MediaCodec hardware classification stays unknown.'),
    'hardwareDecoder': MetricSpec(
        'boolean per display',
        'successful decoder instance device descriptor',
        'Selected hardware device implementation; not GPU utilization or proof of presentation; MediaCodec stays unknown.'),
    'decodeConvertMeanMs': MetricSpec(
        'ms per display',
        'native Decoder.handle_video_frame call',
        'Decode plus color conversion, including failed calls; first up to 8 bounded samples per approximately one-second window, durations capped at 60 seconds; excludes recorder and rendering.'),
    'nativeSubmitMeanMs': MetricSpec(
        'ms per display',
        'native renderer C API invocation',
        'Call duration only; a void API supplies no accepted-frame or presentation confirmation; first up to 8 samples per window, capped at 60 seconds.'),
    'deltaQueuePeak': MetricSpec(
        'entries per display',
        'client non-keyframe ArrayQueue',
        'Nonzero observed peak after insertion; zero stays unknown without an observation marker; capacity 120; keyframes use another queue and are excluded.'),
    'deltaOverflow': MetricSpec(
        'events per window per display',
        'ArrayQueue.force_push evicted an entry',
        'Observed non-keyframe overflow only, not total lost or dropped frames.'),
    'renderSkips': MetricSpec(
        'events per window per display',
        'native no-target/pointer/size/plugin and soft busy/no-consumer branches',
        'Observed skipped paths; multi-window fanout can count more than one branch per decoded callback; excludes unknown plugin-internal drops.'),
    'nativeVideo': MetricSpec(
        'bounded per-display snapshot',
        'local native telemetry; current session/scope/epoch/revision/sequence readback',
        'Counts and bounded duration histograms only while local diagnostics are enabled; the first window after a toggle may be partial; host capture/encode and actual presentation remain unavailable.'),
    'decodedChroma': MetricSpec('chroma', 'update_quality_status.chroma',
        'Decoded chroma format; 4:4:4 does not mean lossless.'),
  };
  final DateTime Function() _now;
  final Duration Function()? _tick;
  final Map<String, MetricSample> _samples = {};
  final Stopwatch _watch = Stopwatch()..start();
  bool? secure;
  bool? direct;
  String? transport;
  DateTime? connectionSampledAt;
  DateTime? authenticatedAt;
  bool connectionFromCache = false;
  BigInt? _nativeEpoch;
  BigInt? _highestNativeEpoch;
  String? _nativeNamespace;
  bool _nativeVisible = false;
  int _nativeReadSerial = 0;
  static final _uint64Max = BigInt.parse('18446744073709551615');
  static const _nativeKeys = [
    'decoderBackend',
    'hardwareDecoder',
    'decodeConvertMeanMs',
    'nativeSubmitMeanMs',
    'deltaQueuePeak',
    'deltaOverflow',
    'renderSkips',
    'nativeVideo'
  ];

  static BigInt? _uint64(Object? raw, {bool positive = false}) {
    if (raw is! String ||
        raw.length > 20 ||
        !RegExp(r'^(0|[1-9][0-9]*)$').hasMatch(raw)) return null;
    final value = BigInt.tryParse(raw);
    return value != null &&
            value <= _uint64Max &&
            (!positive || value > BigInt.zero)
        ? value
        : null;
  }

  bool connectionFromNative(
      Map<String, dynamic> event, String? expectedNamespace) {
    final namespace = event['niko_video_namespace'];
    final epoch = _uint64(event['niko_video_epoch'], positive: true);
    if (expectedNamespace == null ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(expectedNamespace) ||
        namespace != expectedNamespace ||
        epoch == null ||
        _uint64(event['niko_video_revision']) == null ||
        (_highestNativeEpoch != null &&
            (epoch < _highestNativeEpoch! ||
                (epoch == _highestNativeEpoch && _nativeEpoch == null)))) {
      return false;
    }
    connection(
        secure: event['secure'] == 'true',
        direct: event['direct'] == 'true',
        transport: event['stream_type'] ?? '');
    connectionFromCache = event['niko_video_existing'] == 'true';
    _nativeEpoch = epoch;
    _highestNativeEpoch = epoch;
    _nativeNamespace = namespace;
    return true;
  }

  void nativeVisibility(bool visible) {
    if (_nativeVisible != visible) clearNative();
    _nativeVisible = visible;
  }

  void clearNative() {
    _nativeReadSerial++;
    for (final key in _nativeKeys) {
      _samples.remove(key);
    }
  }

  Future<bool> readNative(Object? raw, Future<Object?> Function() readAuthority,
      String? expectedNamespace,
      {required bool Function() isCurrent}) async {
    final serial = ++_nativeReadSerial;
    try {
      final binding = await readAuthority();
      if (serial != _nativeReadSerial || !isCurrent()) return false;
      return updateNative(raw, binding, expectedNamespace);
    } catch (_) {
      if (serial == _nativeReadSerial && isCurrent()) clearNative();
      return false;
    }
  }

  bool updateNative(Object? raw, Object? authority, String? expectedNamespace) {
    if (!_nativeVisible ||
        _nativeEpoch == null ||
        expectedNamespace != _nativeNamespace) {
      clearNative();
      return false;
    }
    try {
      if (raw is! String ||
          raw.length > 65536 ||
          authority is! String ||
          authority.length > 2048) {
        clearNative();
        return false;
      }
      final event = jsonDecode(raw);
      final binding = jsonDecode(authority);
      if (event is! Map<String, dynamic> ||
          binding is! Map<String, dynamic> ||
          event['schemaVersion'] != 1 ||
          binding['enabled'] != true ||
          event['namespace'] != _nativeNamespace ||
          binding['namespace'] != _nativeNamespace ||
          _uint64(event['epoch'], positive: true) != _nativeEpoch ||
          _uint64(binding['epoch'], positive: true) != _nativeEpoch ||
          _uint64(event['revision']) == null ||
          event['revision'] != binding['revision'] ||
          _uint64(event['sequence'], positive: true) == null ||
          event['sequence'] != binding['sequence'] ||
          !_integer(binding['sampleAgeMs'], 0, 3000) ||
          !_integer(event['windowMs'], 1, 60000) ||
          event['displayLimit'] != 16 ||
          event['displays'] is! List ||
          (event['displays'] as List).length > 16) {
        clearNative();
        return false;
      }
      final displays = <String, Map<String, Object?>>{};
      for (final row in event['displays']) {
        if (row is! Map<String, dynamic> || !_integer(row['display'], 0, 15)) {
          throw const FormatException();
        }
        final key = row['display'].toString();
        if (displays.containsKey(key)) throw const FormatException();
        final backend = row['decoderBackend'];
        if (backend != null &&
            !const [
              'vpx-vp8',
              'vpx-vp9',
              'aom-av1',
              'vram',
              'ffmpeg-hw-device',
              'ffmpeg-software',
              'mediacodec',
              'unknown'
            ].contains(backend)) throw const FormatException();
        final hardware = row['hardwareDecoder'];
        if (hardware != null && hardware is! bool) {
          throw const FormatException();
        }
        if ((backend == null ||
                backend == 'mediacodec' ||
                backend == 'unknown') &&
            hardware != null) throw const FormatException();
        if (const ['vpx-vp8', 'vpx-vp9', 'aom-av1', 'ffmpeg-software']
                .contains(backend) &&
            hardware != false) throw const FormatException();
        if (const ['vram', 'ffmpeg-hw-device'].contains(backend) &&
            hardware != true) throw const FormatException();
        final safe = <String, Object?>{
          'decoderBackend': backend,
          'hardwareDecoder': hardware
        };
        for (final count in const [
          'decodedCallbacks',
          'decodeErrors',
          'deltaOverflow',
          'refreshDiscard',
          'nativeCalls',
          'noTarget',
          'noPointer',
          'sizeMismatch',
          'missingPlugin',
          'softBusy',
          'softNoConsumer'
        ]) {
          if (!_integer(row[count], 0, 9007199254740991)) {
            throw const FormatException();
          }
          safe[count] = row[count];
        }
        if (!_integer(row['deltaQueueMax'], 0, 120)) {
          throw const FormatException();
        }
        safe['deltaQueueMax'] =
            row['deltaQueueMax'] == 0 ? null : row['deltaQueueMax'];
        safe['decodeConvert'] = _stage(row['decodeConvert']);
        safe['nativeSubmit'] = _stage(row['nativeSubmit']);
        displays[key] = safe;
      }
      clearNative();
      _put('nativeVideo', {
        'windowMs': event['windowMs'],
        'displayLimit': 16,
        'stageSampleLimit': 8,
        'displays': displays
      });
      for (final metric in _nativeKeys.where((key) => key != 'nativeVideo')) {
        final values = <String, Object?>{};
        for (final display in displays.entries) {
          final row = display.value;
          values[display.key] = switch (metric) {
            'decoderBackend' => row['decoderBackend'],
            'hardwareDecoder' => row['hardwareDecoder'],
            'decodeConvertMeanMs' => (row['decodeConvert'] as Map)['meanMs'],
            'nativeSubmitMeanMs' => (row['nativeSubmit'] as Map)['meanMs'],
            'deltaQueuePeak' => row['deltaQueueMax'],
            'deltaOverflow' => row['deltaOverflow'],
            'renderSkips' => [
                'noTarget',
                'noPointer',
                'sizeMismatch',
                'missingPlugin',
                'softBusy',
                'softNoConsumer'
              ].fold<int>(0, (sum, key) => sum + (row[key] as int)),
            _ => null,
          };
        }
        if (values.isNotEmpty) _put(metric, values);
      }
      return true;
    } catch (_) {
      clearNative();
      return false;
    }
  }

  static bool _integer(Object? value, int min, int max) =>
      value is int && value >= min && value <= max;
  static Map<String, Object?> _stage(Object? raw) {
    if (raw is! Map<String, dynamic> ||
        !_integer(raw['samples'], 0, 8) ||
        !_integer(raw['totalUs'], 0, 480000000) ||
        !_integer(raw['maxUs'], 0, 60000000) ||
        raw['histogramUsLog2'] is! List ||
        (raw['histogramUsLog2'] as List).length != 32) {
      throw const FormatException();
    }
    final histogram = <int>[];
    for (final bin in raw['histogramUsLog2']) {
      if (!_integer(bin, 0, 8)) throw const FormatException();
      histogram.add(bin);
    }
    final samples = raw['samples'] as int;
    if ((raw['maxUs'] as int) > (raw['totalUs'] as int) ||
        (raw['totalUs'] as int) > samples * 60000000 ||
        histogram.fold<int>(0, (a, b) => a + b) != samples ||
        (samples == 0 && (raw['totalUs'] != 0 || raw['maxUs'] != 0))) {
      throw const FormatException();
    }
    return {
      'samples': samples,
      'meanMs': samples == 0 ? null : (raw['totalUs'] as int) / samples / 1000,
      'maxMs': samples == 0 ? null : (raw['maxUs'] as int) / 1000,
      'histogramUsLog2': histogram
    };
  }

  SessionMetrics({DateTime Function()? now, Duration Function()? tick})
      : _now = now ?? DateTime.now,
        _tick = tick;

  // Tests provide an explicit monotonic clock. Production uses Stopwatch.
  Duration get _elapsed => _tick?.call() ?? _watch.elapsed;

  MetricSample? sample(String name) => _samples[name];
  bool isStale(String name) =>
      _samples[name] != null && _elapsed - _samples[name]!.tick > staleAfter;
  Object? current(String name) => isStale(name) ? null : _samples[name]?.value;

  void clear() {
    _nativeReadSerial++;
    _samples.clear();
    _nativeEpoch = null;
    _nativeNamespace = null;
    secure = null;
    direct = null;
    transport = null;
    connectionSampledAt = null;
    authenticatedAt = null;
    connectionFromCache = false;
  }

  bool markAuthenticated() {
    if (authenticatedAt != null) return false;
    authenticatedAt = _now().toUtc();
    return true;
  }

  void connection(
      {required bool secure,
      required bool direct,
      required String transport,
      bool fromCache = false}) {
    if (fromCache && _nativeEpoch != null) return;
    clear();
    this.secure = secure;
    this.direct = direct;
    this.transport = const [
      'TCP',
      'UDP',
      'IPv6',
      'Relay',
      'KCP',
      'WebRTC',
      'WebRTC/IPv6',
      'WebSocket'
    ].contains(transport)
        ? transport
        : null;
    connectionSampledAt = _now().toUtc();
    connectionFromCache = fromCache;
  }

  void _put(String name, Object value) =>
      _samples[name] = MetricSample(value, _now().toUtc(), _elapsed);

  void _number(Map<String, dynamic> event, String rawKey, String name,
      {bool speed = false}) {
    final raw = event[rawKey];
    if (raw == null || raw == '') return;
    final match =
        RegExp(speed ? r'^(\d+(?:\.\d+)?)kB/s$' : r'^(\d+(?:\.\d+)?)$')
            .firstMatch(raw.toString());
    final value = match == null ? null : double.tryParse(match[1]!);
    if (value != null && value.isFinite) _put(name, value);
  }

  void update(Map<String, dynamic> event) {
    _number(event, 'speed', 'receiveKiBps', speed: true);
    _number(event, 'delay', 'applicationRttMs');
    _number(event, 'target_bitrate', 'targetBitrateKbps');
    final codec = event['codec_format']?.toString().toUpperCase();
    if (const ['VP8', 'VP9', 'AV1', 'H264', 'H265', 'H.264', 'H.265']
        .contains(codec)) {
      _put('receivedCodec', codec!);
    }
    final chroma = event['chroma'];
    if (chroma == '4:4:4' || chroma == '4:2:0') _put('decodedChroma', chroma);
    try {
      final raw = event['fps'];
      if (raw is! String || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return;
      final fps = <String, int>{};
      for (final entry in decoded.entries) {
        final display = int.tryParse(entry.key);
        final value = entry.value;
        if (display != null &&
            display >= 0 &&
            display < 256 &&
            value is int &&
            value >= 0 &&
            value <= 1000) {
          fps[display.toString()] = value;
        }
      }
      // Empty maps accompany unrelated events; they are not a measured zero FPS.
      if (fps.isNotEmpty) _put('decodedCallbackFps', fps);
    } catch (_) {
      // Malformed peer data does not replace the last valid sample.
    }
  }

  Map<String, Object?> export() => {
        'schemaVersion': 2,
        'application': 'NikoDesk',
        'exportedAt': _now().toUtc().toIso8601String(),
        'platforms':
            'RustDesk-compatible quality events and local native client telemetry when enabled',
        'connection': {
          'encrypted': secure,
          'direct': direct,
          'transport': transport,
          'sampledAt': connectionSampledAt?.toIso8601String(),
          'authenticatedAt': authenticatedAt?.toIso8601String(),
          'source': connectionFromCache
              ? 'cached_peer_data; sample time is cache receipt, not a new handshake'
              : 'connection_ready; metadata reset on reconnect',
        },
        'metrics': {
          for (final entry in specs.entries)
            entry.key: {
              'value': current(entry.key),
              'state': sample(entry.key) == null
                  ? 'unknown'
                  : isStale(entry.key)
                      ? 'stale'
                      : 'sampled',
              'sampledAt': sample(entry.key)?.sampledAt.toIso8601String(),
              'unit': entry.value.unit,
              'source': entry.value.source,
              'limitation': entry.value.limitation,
            },
        },
        'unsupported': [
          'hardwareEncoder',
          'fallbackReason',
          'captureTime',
          'encodeTime',
          'decodeTime',
          'presentationTime',
          'inputToPhotonLatency',
          'queueDepth',
          'droppedFrames',
          'networkPing',
          'relayAddress'
        ],
      };
}
