import 'dart:async';
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
  String? optionsResult;
  Object? optionsError;
  String statusResult = '{"status_num":1}';
  Object? statusError;
  Completer<String>? pendingStatus;
  int statusReads = 0;
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
    if (optionsError != null) throw optionsError!;
    if (optionsResult != null) return optionsResult!;
    if (failStopRead && reads >= 3) return '';
    return reads == 2 && finalRead != null
        ? finalRead!(Map.of(options))
        : jsonEncode(options);
  }

  @override
  Future<String> mainGetConnectStatus({dynamic hint}) async {
    statusReads++;
    if (statusError != null) throw statusError!;
    if (pendingStatus != null) return pendingStatus!.future;
    return statusResult;
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

  for (final status in ['', '[]', 'null', '{broken']) {
    test('registration read failure preserves valid settings ($status)',
        () async {
      bridge.options.addAll({
        'custom-rendezvous-server': config.idServer,
        'relay-server': config.relayServer,
        'key': config.publicKey,
        'stop-service': 'N',
      });
      bridge.statusResult = status;
      final snapshot = await NativeServerGateway(bridge: bridge).read();
      expect(snapshot.config.idServer, config.idServer);
      expect(snapshot.config.relayServer, config.relayServer);
      expect(snapshot.config.publicKey, config.publicKey);
      expect(snapshot.registrationStatus, isNull);
      expect(bridge.operations, ['read:1']);
    });
  }

  test('IPC status failure does not erase readable paused settings', () async {
    bridge.options.addAll({
      'custom-rendezvous-server': config.idServer,
      'relay-server': config.relayServer,
      'key': config.publicKey,
      'stop-service': 'Y',
    });
    bridge.statusError = StateError('synthetic IPC unavailable');
    final snapshot = await NativeServerGateway(bridge: bridge).read();
    expect(snapshot.config.isValid, isTrue);
    expect(snapshot.enabled, isFalse);
    expect(snapshot.registrationStatus, isNull);
    expect(bridge.operations, ['read:1']);
  });

  testWidgets('pending IPC observation times out without losing settings',
      (tester) async {
    bridge.options.addAll({
      'custom-rendezvous-server': config.idServer,
      'relay-server': config.relayServer,
      'key': config.publicKey,
      'stop-service': 'N',
    });
    bridge.pendingStatus = Completer<String>();
    ServerSnapshot? snapshot;
    final read = NativeServerGateway(bridge: bridge).read();
    read.then((value) => snapshot = value);
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    expect(snapshot?.config.isValid, isTrue);
    expect(snapshot?.registrationStatus, isNull);
    bridge.pendingStatus!.complete('{"status_num":1}');
    await tester.pump();
    expect(snapshot?.registrationStatus, isNull);
    expect(bridge.operations, ['read:1']);
  });

  testWidgets('a late status read uses the current server namespace',
      (tester) async {
    bridge.options.addAll({
      'custom-rendezvous-server': config.idServer,
      'relay-server': config.relayServer,
      'key': config.publicKey,
      'stop-service': 'N',
      'nikodesk-server-namespace': 'a' * 64,
    });
    final firstStatus = Completer<String>();
    bridge.pendingStatus = firstStatus;
    final native = NativeServerGateway(bridge: bridge);
    final firstRead = native.read();
    await tester.pump();
    bridge.options['custom-rendezvous-server'] = 'current.test.invalid:21116';
    bridge.options['nikodesk-server-namespace'] = 'b' * 64;
    bridge.pendingStatus = null;
    final current = await native.read();
    expect(current.namespace, 'b' * 64);
    firstStatus.complete('{"status_num":1}');
    await tester.pump();
    final late = await firstRead;
    expect(late.namespace, 'b' * 64);
    expect(late.config.idServer, 'current.test.invalid:21116');
    expect(bridge.operations, ['read:1', 'read:2']);
  });

  for (final status in [
    '{}',
    '{"status_num":"1"}',
    '{"status_num":true}',
    '{"status_num":1.0}'
  ]) {
    test('missing or noninteger registration remains unknown ($status)',
        () async {
      bridge.statusResult = status;
      final snapshot = await NativeServerGateway(bridge: bridge).read();
      expect(snapshot.registrationStatus, isNull);
      expect(snapshot.config.isValid, isFalse);
      expect(snapshot.enabled, isFalse);
      expect(bridge.operations, ['read:1']);
    });
  }

  for (final status in [-1, 0, 1]) {
    test('registration status $status is preserved from the real contract',
        () async {
      bridge.statusResult = jsonEncode({'status_num': status});
      final snapshot = await NativeServerGateway(bridge: bridge).read();
      expect(snapshot.registrationStatus, status);
      expect(snapshot.enabled, isFalse);
      expect(snapshot.config.isValid, isFalse);
    });
  }

  for (final result in ['', '[]', 'null', '{broken', '"unknown"']) {
    test('unreadable settings never become an empty editable config ($result)',
        () async {
      bridge.optionsResult = result;
      await expectLater(
          NativeServerGateway(bridge: bridge).read(), throwsFormatException);
      expect(bridge.statusReads, 1);
      expect(bridge.operations, ['read:1']);
    });
  }

  for (final key in [
    'custom-rendezvous-server',
    'relay-server',
    'key',
    'stop-service'
  ]) {
    test('malformed settings value for $key fails before any write', () async {
      bridge.optionsResult = jsonEncode({key: 1});
      await expectLater(
          NativeServerGateway(bridge: bridge).read(), throwsFormatException);
      expect(bridge.statusReads, 1);
      expect(bridge.operations, ['read:1']);
    });
  }

  test('a failed settings read is recoverable on the next explicit read',
      () async {
    bridge.optionsError = StateError('synthetic options unavailable');
    final native = NativeServerGateway(bridge: bridge);
    await expectLater(native.read(), throwsStateError);
    bridge.optionsError = null;
    bridge.options.addAll({
      'custom-rendezvous-server': config.idServer,
      'relay-server': config.relayServer,
      'key': config.publicKey,
      'stop-service': 'Y',
    });
    final snapshot = await native.read();
    expect(snapshot.config.idServer, config.idServer);
    expect(snapshot.config.publicKey, config.publicKey);
    expect(snapshot.enabled, isFalse);
    expect(bridge.operations, ['read:1', 'read:2']);
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
