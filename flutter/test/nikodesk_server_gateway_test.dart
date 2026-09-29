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
    return reads == 2 && finalRead != null
        ? finalRead!(Map.of(options))
        : jsonEncode(options);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late _BridgeDouble bridge;
  late NativeServerGateway gateway;
  final config = PrivateServerConfig('nas.example.net:21116',
      'nas.example.net:21117', base64Encode(List.filled(32, 1)));

  setUp(() {
    bridge = _BridgeDouble();
    gateway = NativeServerGateway(bridge: bridge);
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
    await expectLater(gateway.save(config), throwsFormatException);
    expect(bridge.reads, 2);
  });

  for (final status in ['Y', '']) {
    test('final stopped or implicit-enabled status "$status" is rejected',
        () async {
      bridge.finalRead = (options) {
        options['stop-service'] = status;
        return jsonEncode(options);
      };
      await expectLater(gateway.save(config), throwsStateError);
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
      await expectLater(gateway.save(config), throwsStateError);
    });
  }
}
