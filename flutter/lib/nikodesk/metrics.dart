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
    'submittedFps': MetricSpec(
        'frames/s per display',
        'update_quality_status.fps',
        'Frames submitted by the client video thread, not screen presentation FPS; empty samples stay unknown.'),
    'applicationRttMs': MetricSpec('ms', 'update_quality_status.delay',
        'Application probe round trip; not ICMP ping, one-way or input-to-photon latency.'),
    'targetBitrateKbps': MetricSpec(
        'kbps',
        'update_quality_status.target_bitrate',
        'Target encoder bitrate snapshot; not measured throughput.'),
    'receivedCodec': MetricSpec('codec', 'update_quality_status.codec_format',
        'Received video codec; hardware implementation and fallback reason are unavailable.'),
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
    _samples.clear();
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
      if (fps.isNotEmpty) _put('submittedFps', fps);
    } catch (_) {
      // Malformed peer data does not replace the last valid sample.
    }
  }

  Map<String, Object?> export() => {
        'schemaVersion': 1,
        'application': 'NikoDesk',
        'exportedAt': _now().toUtc().toIso8601String(),
        'platforms': 'Desktop RustDesk-compatible quality events',
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
          'hardwareDecoder',
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
