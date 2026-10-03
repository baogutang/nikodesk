import 'dart:convert';

import 'package:flutter_hbb/generated_bridge.dart'
    if (dart.library.html) 'package:flutter_hbb/web/bridge.dart';
import 'package:flutter_hbb/models/platform_model.dart';

import 'policy.dart';
import 'server_scope.dart';

class NativeUnattendedPolicyGateway {
  final Rustdesk? _bridge;
  NativeUnattendedPolicyGateway({Rustdesk? bridge}) : _bridge = bridge;

  Future<Map<String, dynamic>> _read(Rustdesk native) async {
    final options = jsonDecode(await native.mainGetOptions());
    if (options is! Map<String, dynamic> ||
        [
          'custom-rendezvous-server',
          'relay-server',
          'key',
          'verification-method',
          'approve-mode'
        ].any((key) => options.containsKey(key) && options[key] is! String)) {
      throw StateError('private_server_unavailable');
    }
    return options;
  }

  void _confirmServer(Map<String, dynamic> options,
      PrivateServerConfig expected, String namespace) {
    final actual = PrivateServerConfig.fromOptions(options);
    if (!actual.isValid ||
        actual.idServer != expected.idServer ||
        actual.relayServer != expected.relayServer ||
        actual.publicKey != expected.publicKey ||
        NikoServerScope.validate(options['nikodesk-server-namespace']) !=
            namespace) {
      throw StateError('private_server_changed');
    }
  }

  Future<void> save(String password) async {
    if (password.trim().isEmpty || password.runes.length > 128) {
      throw const FormatException('Password required');
    }
    final native = _bridge ?? bind;
    final initial = await _read(native);
    final server = PrivateServerConfig.fromOptions(initial);
    final namespace =
        NikoServerScope.validate(initial['nikodesk-server-namespace']);
    if (!server.isValid || namespace == null) {
      throw StateError('private_server_unavailable');
    }
    if (!await native.mainSetPermanentPasswordWithResult(password: password)) {
      throw StateError('password_not_saved');
    }
    _confirmServer(await _read(native), server, namespace);

    // Select the permanent credential before changing click approval, so a
    // partial update cannot enable unattended temporary-password access.
    await native.mainSetOption(
        key: 'verification-method', value: 'use-permanent-password');
    final method = await _read(native);
    _confirmServer(method, server, namespace);
    if (method['verification-method'] != 'use-permanent-password') {
      throw StateError('policy_not_confirmed');
    }

    await native.mainSetOption(key: 'approve-mode', value: 'password');
    final confirmed = await _read(native);
    _confirmServer(confirmed, server, namespace);
    if (confirmed['verification-method'] != 'use-permanent-password' ||
        confirmed['approve-mode'] != 'password') {
      throw StateError('policy_not_confirmed');
    }
  }
}
