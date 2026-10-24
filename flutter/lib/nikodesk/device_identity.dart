import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_hbb/models/platform_model.dart';

import 'policy.dart';
import 'ui.dart';

/// This computer's own device ID, or empty when the service does not answer.
Future<String> nikoOwnDeviceId() async {
  try {
    return normalizeDeviceId(
        await bind.mainGetMyId().timeout(const Duration(seconds: 2)));
  } catch (_) {
    return '';
  }
}

bool nikoIsOwnDevice(String id, String ownId) =>
    ownId.isNotEmpty && normalizeDeviceId(id) == normalizeDeviceId(ownId);

/// A session to this computer's own ID would show and control this screen
/// inside itself, so every connect path refuses it.
void nikoRefuseOwnDevice(BuildContext context) => nikoNotice(
    context,
    nikoText('这是本机的设备 ID，不能连接自己。',
        'This is this computer’s own device ID. It cannot connect to itself.'));

/// Host name and platform the peer reported in its last session.
class NikoPeerIdentity {
  final String hostname;
  final String platform;
  const NikoPeerIdentity({this.hostname = '', this.platform = ''});

  bool get isEmpty => hostname.isEmpty && platform.isEmpty;

  /// Host name without the mDNS suffix macOS reports.
  String get name => hostname.toLowerCase().endsWith('.local')
      ? hostname.substring(0, hostname.length - 6)
      : hostname;

  String get platformLabel => switch (platform.toLowerCase()) {
        'mac os' || 'macos' => 'macOS',
        'windows' => 'Windows',
        'linux' => 'Linux',
        'android' => 'Android',
        'ios' => 'iOS',
        _ => platform,
      };

  /// [raw] is the peer configuration JSON; only its `info` fields are read.
  static NikoPeerIdentity parse(String raw) {
    try {
      final info = (jsonDecode(raw) as Map)['info'];
      if (info is! Map) return const NikoPeerIdentity();
      String field(Object? value) {
        if (value is! String) return '';
        final text = value.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '').trim();
        return text.length > 64 ? text.substring(0, 64) : text;
      }

      return NikoPeerIdentity(
          hostname: field(info['hostname']), platform: field(info['platform']));
    } catch (_) {
      return const NikoPeerIdentity();
    }
  }
}

NikoPeerIdentity nikoPeerIdentity(String id) {
  try {
    return NikoPeerIdentity.parse(bind.mainGetPeerSync(id: id));
  } catch (_) {
    return const NikoPeerIdentity();
  }
}
