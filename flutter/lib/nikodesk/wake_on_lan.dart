import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'device_store.dart' show withNikoStoreLock;
import 'policy.dart' show validDeviceId;
import 'tunnel_controller.dart';

class WakeProfile {
  final String mac, broadcast;
  final int port;
  final String? proxyId;
  const WakeProfile(this.mac, this.broadcast, {this.port = 9, this.proxyId});

  static WakeProfile? parse(String mac, String broadcast,
      {int port = 9, String? proxyId}) {
    if (proxyId != null && !validDeviceId(proxyId)) return null;
    final parts = mac.trim().replaceAll('-', ':').split(':');
    if (parts.length != 6 ||
        parts.any((p) => !RegExp(r'^[0-9a-fA-F]{2}$').hasMatch(p))) return null;
    final bytes = parts.map((p) => int.parse(p, radix: 16)).toList();
    final address = InternetAddress.tryParse(broadcast.trim());
    if (bytes.every((b) => b == 0) ||
        bytes.first & 1 != 0 ||
        address == null ||
        address.type != InternetAddressType.IPv4 ||
        address.isMulticast ||
        address.rawAddress.every((b) => b == 0) ||
        port < 1 ||
        port > 65535) return null;
    final ip = address.rawAddress;
    final local = address.isLoopback ||
        ip[0] == 10 ||
        (ip[0] == 172 && ip[1] >= 16 && ip[1] <= 31) ||
        (ip[0] == 192 && ip[1] == 168) ||
        (ip[0] == 169 && ip[1] == 254) ||
        ip.every((b) => b == 255);
    if (!local) return null;
    return WakeProfile(
        parts.map((p) => p.toUpperCase()).join(':'), address.address,
        port: port, proxyId: proxyId);
  }

  Uint8List packet() {
    final normalized = parse(mac, broadcast, port: port);
    if (normalized == null) throw const FormatException('Invalid wake profile');
    final address =
        normalized.mac.split(':').map((p) => int.parse(p, radix: 16)).toList();
    return Uint8List.fromList(
        [...List.filled(6, 255), for (var i = 0; i < 16; i++) ...address]);
  }

  Map<String, Object> toJson() =>
      {'mac': mac, 'broadcast': broadcast, 'port': port};
}

// Non-secret settings use a separate file so existing device writers preserve them.
class WakeProfileStore {
  final Directory directory;
  final String namespace;
  const WakeProfileStore(this.directory, this.namespace);
  File get _file => File('${directory.path}/wake-profiles-$namespace.json');

  Future<Map<String, dynamic>> _read() async {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(namespace)) {
      throw StateError('Invalid server scope');
    }
    if (!await _file.exists()) return {};
    if (await _file.length() > 256 * 1024) {
      throw const FormatException('Wake profiles exceed limit');
    }
    final value = jsonDecode(await _file.readAsString());
    if (value is! Map<String, dynamic> ||
        value['version'] != 1 ||
        value['namespace'] != namespace ||
        value['devices'] is! Map<String, dynamic>) {
      throw const FormatException('Unsupported wake profiles');
    }
    return Map<String, dynamic>.from(value['devices']);
  }

  Future<WakeProfile?> load(String id) async {
    final value = (await _read())[id];
    if (value == null) return null;
    if (value is! Map ||
        value['mac'] is! String ||
        value['broadcast'] is! String ||
        value['port'] is! int ||
        value['proxyId'] != null && value['proxyId'] is! String) {
      throw const FormatException('Invalid saved wake profile');
    }
    final profile = WakeProfile.parse(value['mac'], value['broadcast'],
        port: value['port'], proxyId: value['proxyId'] as String?);
    if (profile == null) {
      throw const FormatException('Invalid saved wake profile');
    }
    return profile;
  }

  Future<void> save(String id, WakeProfile profile) async {
    if (!validDeviceId(id) ||
        WakeProfile.parse(profile.mac, profile.broadcast,
                port: profile.port, proxyId: profile.proxyId) ==
            null) {
      throw const FormatException('Invalid wake profile');
    }
    await directory.create(recursive: true);
    await withNikoStoreLock('${directory.path}/wake-profiles.lock', () async {
      final devices = await _read();
      devices[id] = {
        ...profile.toJson(),
        if (profile.proxyId != null) 'proxyId': profile.proxyId
      };
      if (devices.length > 1000) {
        throw const FormatException('Too many wake profiles');
      }
      final temporary = File('${_file.path}.${_requestId()}.tmp');
      try {
        await temporary.writeAsString(
            jsonEncode(
                {'version': 1, 'namespace': namespace, 'devices': devices}),
            flush: true);
        await temporary.rename(_file.path);
      } finally {
        if (await temporary.exists()) await temporary.delete();
      }
    });
  }
}

String _requestId() {
  final random = Random.secure();
  return List.generate(16, (_) => random.nextInt(256))
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();
}

class WakeSender {
  static Future<int> local(WakeProfile profile) async {
    final bytes = profile.packet();
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    try {
      socket.broadcastEnabled = true;
      var sent = 0;
      for (var i = 0; i < 3; i++) {
        if (socket.send(
                bytes, InternetAddress(profile.broadcast), profile.port) !=
            bytes.length) {
          throw const SocketException('Wake packet was not sent');
        }
        sent++;
        if (i != 2) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }
      return sent;
    } finally {
      socket.close();
    }
  }

  static bool proxyReady(NikoTunnelController model, int port) {
    final status = model.statuses[port];
    return model.active &&
        status != null &&
        status.phase == NikoTunnelPhase.listening &&
        status.remotePhase == 'Running' &&
        !status.localResourcesClosed &&
        status.namespace == model.namespace &&
        status.peerId == model.peerId &&
        status.target.host == '127.0.0.1' &&
        status.target.port == 21128;
  }

  static bool _same(NikoTunnelStatus a, NikoTunnelStatus b) =>
      a.namespace == b.namespace &&
      a.peerId == b.peerId &&
      a.generation == b.generation &&
      a.localPort == b.localPort &&
      a.target.same(b.target);

  static Future<int> throughProxy(
      WakeProfile profile, NikoTunnelController model, int port) async {
    if (!proxyReady(model, port)) {
      throw StateError('Authenticated wake proxy is unavailable');
    }
    final original = model.statuses[port]!;
    return throughVerifiedPort(
        profile,
        model.namespace,
        port,
        () async =>
            proxyReady(model, port) && _same(original, model.statuses[port]!));
  }

  /// The caller obtains freshness from the original native tunnel publisher.
  /// Neither a saved proxy choice nor a queued tunnel request opens this route.
  static Future<int> throughVerifiedPort(WakeProfile profile, String namespace,
      int port, Future<bool> Function() current) async {
    profile.packet();
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(namespace) ||
        port < 1 ||
        port > 65535 ||
        !await current()) {
      throw StateError('Authenticated wake proxy is unavailable');
    }
    final id = _requestId();
    final socket = await Socket.connect(InternetAddress.loopbackIPv4, port,
        timeout: const Duration(seconds: 3));
    try {
      if (!await current()) {
        throw StateError('Wake proxy session changed');
      }
      socket.write('${jsonEncode({
            'schema': 1,
            'request_id': id,
            'namespace': namespace,
            ...profile.toJson()
          })}\n');
      await socket.flush();
      final bytes = <int>[];
      final response = await (() async {
        await for (final chunk in socket) {
          bytes.addAll(chunk);
          if (bytes.length > 1024) {
            throw const FormatException('Excessive wake reply');
          }
          final end = bytes.indexOf(10);
          if (end >= 0) return jsonDecode(utf8.decode(bytes.sublist(0, end)));
        }
        throw const SocketException('Wake proxy closed without acknowledgment');
      })()
          .timeout(const Duration(seconds: 5));
      if (!await current() ||
          response is! Map ||
          response.length != 4 ||
          response['schema'] != 1 ||
          response['request_id'] != id ||
          response['sent'] != true ||
          response['packets'] != 3) {
        throw StateError('Wake proxy did not confirm this request');
      }
      return 3;
    } finally {
      socket.destroy();
    }
  }
}
