import 'dart:convert';

import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/generated_bridge.dart'
    if (dart.library.html) 'package:flutter_hbb/web/bridge.dart';
import 'policy.dart';

class ServerSnapshot {
  final PrivateServerConfig config;
  final int? registrationStatus;
  final bool enabled;
  const ServerSnapshot(this.config, this.registrationStatus, this.enabled);
}

abstract class ServerGateway {
  Future<ServerSnapshot> read();
  Future<void> save(PrivateServerConfig config);
}

class NativeServerGateway implements ServerGateway {
  final Rustdesk? _bridge;
  NativeServerGateway({Rustdesk? bridge}) : _bridge = bridge;

  @override
  Future<ServerSnapshot> read() async {
    final native = _bridge ?? bind;
    final options =
        jsonDecode(await native.mainGetOptions()) as Map<String, dynamic>;
    final status =
        jsonDecode(await native.mainGetConnectStatus()) as Map<String, dynamic>;
    return ServerSnapshot(
        PrivateServerConfig.fromOptions(options),
        status['status_num'] is int ? status['status_num'] : null,
        options['stop-service'] == 'N');
  }

  @override
  Future<void> save(PrivateServerConfig config) async {
    if (!config.isValid) {
      throw const FormatException('Invalid private server settings');
    }
    final native = _bridge ?? bind;
    // Keep the client stopped while the three required fields are updated.
    await native.mainSetOption(key: 'stop-service', value: 'Y');
    await native.mainSetOption(
        key: 'custom-rendezvous-server', value: config.idServer);
    await native.mainSetOption(key: 'relay-server', value: config.relayServer);
    await native.mainSetOption(key: 'key', value: config.publicKey);
    final saved =
        jsonDecode(await native.mainGetOptions()) as Map<String, dynamic>;
    final verified = PrivateServerConfig.fromOptions(saved);
    if (!verified.isValid ||
        verified.idServer != config.idServer ||
        verified.relayServer != config.relayServer ||
        verified.publicKey != config.publicKey) {
      throw StateError('Private server settings could not be verified');
    }
    await native.mainSetOption(key: 'stop-service', value: 'N');
    final enabled =
        jsonDecode(await native.mainGetOptions()) as Map<String, dynamic>;
    final finalConfig = PrivateServerConfig.fromOptions(enabled);
    if (!finalConfig.isValid ||
        finalConfig.idServer != config.idServer ||
        finalConfig.relayServer != config.relayServer ||
        finalConfig.publicKey != config.publicKey ||
        enabled['stop-service'] != 'N') {
      throw StateError('Private server activation could not be verified');
    }
  }
}
