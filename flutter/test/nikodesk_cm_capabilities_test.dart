import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/nikodesk/cm_capabilities.dart';

Map<String, dynamic> identity() => {
      'connection_id': 12,
      'namespace': 'a' * 64,
      'peer_id': '123456789',
      'connection_nonce': 'b' * 32,
      'request_nonce': 'c' * 32,
      'epoch': '18446744073709551615'
    };
Map<String, dynamic> status() => {
      'identity': identity(),
      'kind': 'terminal',
      'scope': 'Local user UID 501',
      'phase': 'Pending',
      'reason': 'Wait for approval',
      'resource_epoch': '18446744073709551615'
    };
void main() {
  test('request identity survives decision/revoke without current global scope',
      () {
    final parsed = NikoCapabilityStatus.parse(jsonEncode(status()))!;
    expect(jsonDecode(parsed.identity.decision(true))['identity'], identity());
    expect(jsonDecode(parsed.identity.revoke()), identity());
    expect(parsed.identity.namespace, 'a' * 64);
  });
  test('u64 epoch remains a precise string and rejects aliases and overflow',
      () {
    for (final epoch in ['0', '01', '-1', '1.0', '18446744073709551616']) {
      final raw = identity()..['epoch'] = epoch;
      expect(NikoCapabilityIdentity.parse(raw), isNull);
    }
    expect(NikoCapabilityIdentity.parse(identity())!.epoch,
        '18446744073709551615');
  });
  test('unknown identity/command fields and unbounded payload are rejected',
      () {
    expect(
        NikoCapabilityIdentity.parse(identity()..['command'] = 'sh'), isNull);
    expect(NikoCapabilityStatus.parse(jsonEncode(status()..['command'] = 'sh')),
        isNull);
    expect(NikoCapabilityStatus.parse('x' * 4097), isNull);
  });
  test('foreign malformed namespace, service IDs and zero nonce are refused',
      () {
    for (final change in [
      {'namespace': 'A' * 64},
      {'peer_id': 'ts_foreign'},
      {'connection_nonce': '0' * 32},
      {'request_nonce': '0' * 32}
    ]) {
      expect(NikoCapabilityIdentity.parse(identity()..addAll(change)), isNull);
    }
  });
  test('queued transport response is never a running resource state', () {
    expect(
        NikoCapabilityStatus.parse(
            jsonEncode({'ok': true, 'status': 'queued'})),
        isNull);
    expect(
        NikoCapabilityStatus.parse(jsonEncode(status()..['phase'] = 'queued')),
        isNull);
  });
  test('stopped and recovery required remain distinct native evidence', () {
    for (final phase in [
      'Stopped',
      'RecoveryRequired',
      'Starting',
      'Running'
    ]) {
      expect(
          NikoCapabilityStatus.parse(jsonEncode(status()..['phase'] = phase))!
              .phase,
          phase);
    }
  });
}
