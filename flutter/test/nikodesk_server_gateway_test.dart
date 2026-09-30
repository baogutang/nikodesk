import 'dart:convert';

import 'package:flutter_hbb/generated_bridge.dart';
import 'package:flutter_hbb/nikodesk/policy.dart';
import 'package:flutter_hbb/nikodesk/server_gateway.dart';
import 'package:flutter_test/flutter_test.dart';

// Native API test double; production uses the initialized Rust FFI bridge.
class _BridgeDouble implements Rustdesk {
  final options = <String, String>{};
  final operations = <String>[];
  String Function(Map<String, String>)? finalRead;
  int reads = 0;
  bool failStopRead = false;
  String transactionResult =
      '{"ok":true,"state":"enabled","stoppedVerified":false}';
  String? transactionConfig;

  @override
  Future<void> mainSetOption(
      {required String key, required String value, dynamic hint}) async {
    operations.add('set:$key');
    options[key] = value;
  }

  @override
  Future<String> mainGetOptions({dynamic hint}) async {
    reads++;
    operations.add('read:$reads');
    if (failStopRead && reads >= 3) return '';
    return reads == 2 && finalRead != null
        ? finalRead!(Map.of(options))
        : jsonEncode(options);
  }

  @override
  Future<String> mainNikoSavePrivateServer(
      {required String config, dynamic hint}) async {
    operations.add('transaction-save');
    transactionConfig = config;
    return transactionResult;
  }

  bool passwordSaved = true;
  @override
  Future<bool> mainSetPermanentPasswordWithResult(
      {required String password, dynamic hint}) async {
    operations.add('password-save');
    return passwordSaved;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late _BridgeDouble bridge;
  late OptionsServerGateway gateway;
  final config = PrivateServerConfig('nas.example.net:21116',
      'nas.example.net:21117', base64Encode(List.filled(32, 1)));

  setUp(() {
    bridge = _BridgeDouble();
    gateway = OptionsServerGateway(bridge: bridge);
  });

  test('success requires a final read after explicit enable', () async {
    await gateway.save(config);
    expect(bridge.reads, 2);
    expect(bridge.operations, [
      'set:stop-service',
      'set:custom-rendezvous-server',
      'set:relay-server',
      'set:key',
      'read:1',
      'set:stop-service',
      'read:2',
    ]);
    expect(bridge.options['stop-service'], 'N');
  });

  test('empty final persistence read never reports save success', () async {
    bridge.finalRead = (_) => '';
    await expectLater(
        gateway.save(config),
        throwsA(isA<PrivateServerSaveException>()
            .having((e) => e.stoppedVerified, 'stopped verified', true)));
    expect(bridge.reads, 3);
    expect(bridge.options['stop-service'], 'Y');
  });

  for (final status in ['Y', '']) {
    test('final stopped or implicit-enabled status "$status" is rejected',
        () async {
      bridge.finalRead = (options) {
        options['stop-service'] = status;
        return jsonEncode(options);
      };
      await expectLater(
          gateway.save(config),
          throwsA(isA<PrivateServerSaveException>()
              .having((e) => e.stoppedVerified, 'stopped verified', true)));
      expect(bridge.options['stop-service'], 'Y');
    });
  }

  for (final key in ['custom-rendezvous-server', 'relay-server', 'key']) {
    test('final configuration drift in $key is rejected', () async {
      bridge.finalRead = (options) {
        options[key] = key == 'key'
            ? base64Encode(List.filled(32, 2))
            : 'other.example.net:21116';
        return jsonEncode(options);
      };
      await expectLater(
          gateway.save(config),
          throwsA(isA<PrivateServerSaveException>()
              .having((e) => e.stoppedVerified, 'stopped verified', true)));
      expect(bridge.options['stop-service'], 'Y');
    });
  }
  test('saving a permanent password does not silently enable authentication',
      () async {
    bridge.options['verification-method'] = 'use-temporary-password';
    final result = await NativePasswordGateway(bridge: bridge)
        .save('synthetic-secret', enableAuthentication: false);
    expect(result.enabled, isFalse);
    expect(bridge.options['verification-method'], 'use-temporary-password');
    expect(bridge.operations, ['password-save', 'read:1']);
  });

  test('explicit permanent authentication enable requires readback', () async {
    final result = await NativePasswordGateway(bridge: bridge)
        .save('synthetic-secret', enableAuthentication: true);
    expect(result.enabled, isTrue);
    expect(bridge.options['verification-method'], 'use-both-passwords');
    expect(bridge.operations,
        ['password-save', 'set:verification-method', 'read:1']);
  });

  test('password rejection does not change authentication', () async {
    bridge.passwordSaved = false;
    await expectLater(
        NativePasswordGateway(bridge: bridge)
            .save('synthetic-secret', enableAuthentication: true),
        throwsStateError);
    expect(bridge.operations, ['password-save']);
  });

  test('empty permanent password never reaches native write', () async {
    await expectLater(
        NativePasswordGateway(bridge: bridge)
            .save('', enableAuthentication: true),
        throwsFormatException);
    expect(bridge.operations, isEmpty);
  });
  test('a failed recovery read reports unknown instead of claiming stopped',
      () async {
    bridge.finalRead = (_) => '';
    bridge.failStopRead = true;
    await expectLater(
        gateway.save(config),
        throwsA(isA<PrivateServerSaveException>()
            .having((e) => e.stoppedVerified, 'stopped verified', false)));
  });

  test('production save only uses the native transaction', () async {
    await NativeServerGateway(bridge: bridge).save(config);
    expect(bridge.operations, ['transaction-save']);
    expect(jsonDecode(bridge.transactionConfig!), {
      'idServer': config.idServer,
      'relayServer': config.relayServer,
      'publicKey': config.publicKey,
    });
  });

  test('importing a private server uses the complete native transaction',
      () async {
    expect(
        await saveImportedPrivateServer(
            config.idServer, config.relayServer, config.publicKey, '',
            gateway: NativeServerGateway(bridge: bridge)),
        isTrue);
    expect(bridge.operations, ['transaction-save']);
  });

  test('importing a server never reports a failed transaction as successful',
      () async {
    bridge.transactionResult =
        '{"ok":false,"state":"unknown","stoppedVerified":false}';
    expect(
        await saveImportedPrivateServer(
            config.idServer, config.relayServer, config.publicKey, '',
            gateway: NativeServerGateway(bridge: bridge)),
        isFalse);
    expect(bridge.operations, ['transaction-save']);
  });

  test('importing team API settings fails before any native writes', () async {
    expect(
        await saveImportedPrivateServer(config.idServer, config.relayServer,
            config.publicKey, 'https://accounts.example',
            gateway: NativeServerGateway(bridge: bridge)),
        isFalse);
    expect(bridge.operations, isEmpty);
  });

  for (final state in ['stopped', 'unknown', 'invalid', 'unsupported']) {
    test('native failed state $state is never reported as successful',
        () async {
      bridge.transactionResult = jsonEncode(
          {'ok': false, 'state': state, 'stoppedVerified': state == 'stopped'});
      await expectLater(
          NativeServerGateway(bridge: bridge).save(config),
          throwsA(isA<PrivateServerSaveException>()
              .having((e) => e.state, 'state', state)
              .having((e) => e.stoppedVerified, 'stopped verified',
                  state == 'stopped')));
      expect(bridge.operations, ['transaction-save']);
    });
  }
  for (final result in [
    '',
    '{}',
    '[]',
    '{"ok":true,"state":"enabled"}',
    '{"ok":true,"state":"invented","stoppedVerified":false}'
  ]) {
    test('malformed transaction results fail closed ($result)', () async {
      bridge.transactionResult = result;
      await expectLater(
          NativeServerGateway(bridge: bridge).save(config),
          throwsA(isA<PrivateServerSaveException>()
              .having((e) => e.stoppedVerified, 'stopped verified', false)));
    });
  }
  test('selecting permanent password never silently bypasses click approval',
      () async {
    bridge.options['approve-mode'] = 'click';
    final result = await NativePasswordGateway(bridge: bridge)
        .save('synthetic-secret', enableAuthentication: true);
    expect(result.permanentSelected, isTrue);
    expect(result.clickOnly, isTrue);
    expect(result.enabled, isFalse);
    expect(bridge.options['approve-mode'], 'click');
  });
}
