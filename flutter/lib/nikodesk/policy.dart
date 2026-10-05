import 'dart:convert';
import 'dart:io';

String normalizeDeviceId(String value) => value.trim().replaceAll(' ', '');

bool validDeviceId(String value) =>
    RegExp(r'^[0-9]{6,16}$').hasMatch(normalizeDeviceId(value));

/// A server endpoint, never a URL or an ID with an alternate server suffix.
bool validServerEndpoint(String value) {
  if (value.isEmpty || value != value.trim() || value.length > 260) {
    return false;
  }
  String host;
  String? port;
  if (value.startsWith('[')) {
    final match = RegExp(r'^\[([^\]]+)\](?::([0-9]+))?$').firstMatch(value);
    if (match == null) return false;
    host = match[1]!;
    port = match[2];
    if (InternetAddress.tryParse(host)?.type != InternetAddressType.IPv6) {
      return false;
    }
  } else {
    final parts = value.split(':');
    if (parts.length > 2) return false;
    host = parts[0];
    if (parts.length == 2) port = parts[1];
    if (InternetAddress.tryParse(host) == null) {
      if (host.length > 253 ||
          !host.split('.').every((part) =>
              RegExp(r'^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?$')
                  .hasMatch(part))) return false;
      if (RegExp(r'^[0-9.]+$').hasMatch(host)) return false;
    }
  }
  final lower = host.toLowerCase();
  if (lower == 'public' ||
      lower == 'rustdesk.com' ||
      lower.endsWith('.rustdesk.com')) return false;
  final ip = InternetAddress.tryParse(host);
  if (ip != null &&
      (ip.isMulticast || ip.rawAddress.every((byte) => byte == 0))) {
    return false;
  }
  if (port != null) {
    final number = int.tryParse(port);
    if (number == null || number < 1 || number > 65535) return false;
  }
  return true;
}

bool validServerKey(String value) {
  if (!RegExp(r'^[A-Za-z0-9+/]{43}=$').hasMatch(value)) return false;
  try {
    final bytes = base64Decode(value);
    return bytes.length == 32 &&
        bytes.any((byte) => byte != 0) &&
        base64Encode(bytes) == value;
  } catch (_) {
    return false;
  }
}

class PrivateServerConfig {
  final String idServer;
  final String relayServer;
  final String publicKey;

  const PrivateServerConfig(this.idServer, this.relayServer, this.publicKey);

  factory PrivateServerConfig.fromOptions(Map<String, dynamic> options) =>
      PrivateServerConfig(
        options['custom-rendezvous-server'] as String? ?? '',
        options['relay-server'] as String? ?? '',
        options['key'] as String? ?? '',
      );

  bool get isValid =>
      validServerEndpoint(idServer) &&
      validServerEndpoint(relayServer) &&
      validServerKey(publicKey);
}

enum PictureMode { office, smooth, constrained, custom }

class PictureRequest {
  final PictureMode mode;
  final String imageQuality;
  final int? bitratePercent;
  final int? fps;
  final bool originalScale;

  const PictureRequest(this.mode, this.imageQuality,
      {this.bitratePercent, this.fps, this.originalScale = false});

  factory PictureRequest.forMode(PictureMode mode,
      {int customPercent = 50, int customFps = 30}) {
    if (customPercent < 10 ||
        customPercent > 100 ||
        customFps < 5 ||
        customFps > 60) {
      throw ArgumentError('Picture parameters are outside supported bounds');
    }
    switch (mode) {
      case PictureMode.office:
        return PictureRequest(mode, 'best', originalScale: true);
      case PictureMode.smooth:
        // Any non-custom quality is held to 30 frames a second by the session.
        return PictureRequest(mode, 'custom', bitratePercent: 50, fps: 60);
      case PictureMode.constrained:
        return PictureRequest(mode, 'custom', bitratePercent: 30, fps: 15);
      case PictureMode.custom:
        return PictureRequest(mode, 'custom',
            bitratePercent: customPercent, fps: customFps);
    }
  }

  /// FPS only applies to the upstream custom-quality path.
  bool get requestsCustomFps => imageQuality == 'custom' && fps != null;

  static PictureMode observedMode(String? saved,
      {required String? quality,
      required int? percent,
      required int? fps,
      required String? viewStyle,
      required String? codecPreference,
      required bool supportsFps}) {
    PictureMode? mode;
    for (final candidate in PictureMode.values) {
      if (candidate.name == saved) mode = candidate;
    }
    if (mode == null ||
        mode == PictureMode.custom ||
        codecPreference == null ||
        (codecPreference.isNotEmpty && codecPreference != 'auto')) {
      return PictureMode.custom;
    }
    final request = PictureRequest.forMode(mode);
    if (quality != request.imageQuality ||
        (request.originalScale && viewStyle != 'original') ||
        (request.bitratePercent != null && percent != request.bitratePercent) ||
        (request.requestsCustomFps && supportsFps && fps != request.fps)) {
      return PictureMode.custom;
    }
    return mode;
  }

  static bool supportsCustomFps(String peerVersion) {
    final match = RegExp(r'^(\d+)\.(\d+)\.(\d+)').firstMatch(peerVersion);
    if (match == null) return false;
    final major = int.parse(match[1]!);
    final minor = int.parse(match[2]!);
    return major > 1 || (major == 1 && minor >= 2);
  }
}
