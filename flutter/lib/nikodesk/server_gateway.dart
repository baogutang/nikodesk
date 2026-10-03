import 'dart:convert';

import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/generated_bridge.dart'
    if (dart.library.html) 'package:flutter_hbb/web/bridge.dart';
import 'policy.dart';
import 'server_scope.dart';

class ServerSnapshot {
  final PrivateServerConfig config;
  final int? registrationStatus;
  final bool enabled;
  final String? namespace;
  const ServerSnapshot(this.config, this.registrationStatus, this.enabled,
      {this.namespace});
}

abstract class ServerGateway {
  Future<ServerSnapshot> read();
  Future<void> save(PrivateServerConfig config);
}

Future<bool> saveImportedPrivateServer(
    String idServer, String relayServer, String key, String apiServer,
    {ServerGateway? gateway}) async {
  if (apiServer.trim().isNotEmpty) return false;
  try {
    await (gateway ?? NativeServerGateway())
        .save(PrivateServerConfig(idServer, relayServer, key));
    return true;
  } catch (_) {
    return false;
  }
}

class PrivateServerSaveException implements Exception {
  final bool stoppedVerified;
  final String state;
  const PrivateServerSaveException(
      {required this.stoppedVerified, this.state = 'unknown'});
  @override
  String toString() => 'Private server save was not confirmed';
}

/// Only for explicit bridge tests. Production saves use a core transaction
/// shared by all windows, rather than a series of independent option writes.
class OptionsServerGateway implements ServerGateway {
  final Rustdesk bridge;
  OptionsServerGateway({required this.bridge});

  @override
  Future<ServerSnapshot> read() => NativeServerGateway(bridge: bridge).read();

  @override
  Future<void> save(PrivateServerConfig config) async {
    if (!config.isValid) {
      throw const FormatException('Invalid private server settings');
    }
    try {
      await bridge.mainSetOption(key: 'stop-service', value: 'Y');
      await bridge.mainSetOption(
          key: 'custom-rendezvous-server', value: config.idServer);
      await bridge.mainSetOption(
          key: 'relay-server', value: config.relayServer);
      await bridge.mainSetOption(key: 'key', value: config.publicKey);
      final saved =
          jsonDecode(await bridge.mainGetOptions()) as Map<String, dynamic>;
      if (!_matches(config, saved)) {
        throw StateError('Settings were not confirmed');
      }
      await bridge.mainSetOption(key: 'stop-service', value: 'N');
      final enabled =
          jsonDecode(await bridge.mainGetOptions()) as Map<String, dynamic>;
      if (!_matches(config, enabled) || enabled['stop-service'] != 'N') {
        throw StateError('Activation was not confirmed');
      }
    } catch (_) {
      var stopped = false;
      try {
        await bridge.mainSetOption(key: 'stop-service', value: 'Y');
        final options =
            jsonDecode(await bridge.mainGetOptions()) as Map<String, dynamic>;
        stopped = options['stop-service'] == 'Y';
      } catch (_) {}
      throw PrivateServerSaveException(
          stoppedVerified: stopped, state: stopped ? 'stopped' : 'unknown');
    }
  }

  bool _matches(PrivateServerConfig expected, Map<String, dynamic> options) {
    final actual = PrivateServerConfig.fromOptions(options);
    return actual.isValid &&
        actual.idServer == expected.idServer &&
        actual.relayServer == expected.relayServer &&
        actual.publicKey == expected.publicKey;
  }
}

class NativeServerGateway implements ServerGateway {
  final Rustdesk? _bridge;
  NativeServerGateway({Rustdesk? bridge}) : _bridge = bridge;

  @override
  Future<ServerSnapshot> read() async {
    final native = _bridge ?? bind;
    int? registrationStatus;
    // Registration is a separate IPC observation. A missing status must not
    // turn readable local settings into an empty or inaccessible configuration.
    try {
      final status = jsonDecode(await native
          .mainGetConnectStatus()
          .timeout(const Duration(seconds: 2)));
      if (status is Map<String, dynamic> && status['status_num'] is int) {
        registrationStatus = status['status_num'] as int;
      }
    } catch (_) {}
    // Read current settings after the optional status observation. A delayed
    // IPC response must not reactivate a namespace captured before a change.
    final options = jsonDecode(await native.mainGetOptions());
    if (options is! Map<String, dynamic> ||
        [
          'custom-rendezvous-server',
          'relay-server',
          'key',
          'stop-service'
        ].any((key) => options.containsKey(key) && options[key] is! String)) {
      throw const FormatException('Private server settings are unavailable');
    }
    final namespace =
        NikoServerScope.validate(options['nikodesk-server-namespace']);
    if (_bridge == null) NikoServerScope.activate(namespace);
    return ServerSnapshot(
        PrivateServerConfig.fromOptions(options),
        registrationStatus,
        options['stop-service'] == 'N' &&
            (_bridge != null || namespace != null),
        namespace: namespace);
  }

  @override
  Future<void> save(PrivateServerConfig config) async {
    if (!config.isValid) {
      throw const FormatException('Invalid private server settings');
    }
    final native = _bridge ?? bind;
    try {
      final response = jsonDecode(await native.mainNikoSavePrivateServer(
          config: jsonEncode({
        'idServer': config.idServer,
        'relayServer': config.relayServer,
        'publicKey': config.publicKey
      })));
      if (response is! Map<String, dynamic> ||
          response['ok'] is! bool ||
          response['stoppedVerified'] is! bool ||
          !{'enabled', 'stopped', 'unknown', 'invalid', 'unsupported'}
              .contains(response['state'])) {
        throw const PrivateServerSaveException(stoppedVerified: false);
      }
      if (response['ok'] == true && response['state'] == 'enabled') return;
      throw PrivateServerSaveException(
          stoppedVerified: response['stoppedVerified'] == true &&
              response['state'] != 'enabled' &&
              response['state'] != 'unknown',
          state: response['state'] as String);
    } on PrivateServerSaveException {
      rethrow;
    } catch (_) {
      throw const PrivateServerSaveException(stoppedVerified: false);
    }
  }
}

class PasswordSetupResult {
  final bool permanentSelected;
  final bool clickOnly;
  const PasswordSetupResult(this.permanentSelected, this.clickOnly);
  bool get enabled => permanentSelected && !clickOnly;
}

class NativePasswordGateway {
  final Rustdesk? _bridge;
  NativePasswordGateway({Rustdesk? bridge}) : _bridge = bridge;

  Future<PasswordSetupResult> save(String password,
      {required bool enableAuthentication}) async {
    if (password.isEmpty) throw const FormatException('Password required');
    final native = _bridge ?? bind;
    if (!await native.mainSetPermanentPasswordWithResult(password: password)) {
      throw StateError('Password update was not confirmed');
    }
    if (enableAuthentication) {
      await native.mainSetOption(
          key: 'verification-method', value: 'use-both-passwords');
    }
    final options =
        jsonDecode(await native.mainGetOptions()) as Map<String, dynamic>;
    final method = options['verification-method'];
    final enabled =
        method == 'use-permanent-password' || method == 'use-both-passwords';
    if (enableAuthentication && !enabled) {
      throw StateError('Password authentication was not confirmed');
    }
    return PasswordSetupResult(enabled, options['approve-mode'] == 'click');
  }
}
