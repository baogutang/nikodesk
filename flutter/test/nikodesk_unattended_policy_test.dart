import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/generated_bridge.dart';
import 'package:flutter_hbb/nikodesk/mac_background_agent.dart';
import 'package:flutter_hbb/nikodesk/mac_background_settings.dart';
import 'package:flutter_hbb/nikodesk/ui.dart';
import 'package:flutter_hbb/nikodesk/unattended_policy.dart';
import 'package:flutter_test/flutter_test.dart';

// Native bridge and background-agent fixtures; no process, permission, disk
// configuration, real password or login agent is accessed by these tests.
class _PolicyBridge implements Rustdesk {
  final options = <String, String>{
    'custom-rendezvous-server': 'private.test.invalid:21116',
    'relay-server': 'private.test.invalid:21117',
    'key': base64Encode(List.filled(32, 9)),
    'nikodesk-server-namespace': 'a' * 64,
    'stop-service': 'Y',
    'verification-method': 'use-both-passwords',
    'approve-mode': 'click',
    'unrelated-option': 'preserved',
  };
  final operations = <String>[];
  bool passwordSaved = true;
  Completer<bool>? pendingPassword;
  int reads = 0;
  int? malformedRead;
  int? driftRead;
  String driftKey = 'custom-rendezvous-server';
  String? ignoredPatch;

  @override
  Future<String> mainGetOptions({dynamic hint}) async {
    reads++;
    operations.add('read:$reads');
    if (malformedRead == reads) return '';
    if (driftRead == reads) {
      options[driftKey] = driftKey == 'nikodesk-server-namespace'
          ? 'b' * 64
          : driftKey == 'key'
              ? base64Encode(List.filled(32, 5))
              : 'changed.test.invalid:21116';
    }
    return jsonEncode(options);
  }

  @override
  Future<bool> mainSetPermanentPasswordWithResult(
      {required String password, dynamic hint}) async {
    operations.add('password-save');
    if (pendingPassword != null) return pendingPassword!.future;
    return passwordSaved;
  }

  @override
  Future<void> mainSetOption(
      {required String key, required String value, dynamic hint}) async {
    operations.add('patch:$key:$value');
    if (key != ignoredPatch) options[key] = value;
  }

  @override
  Future<void> mainSetOptions({required String json, dynamic hint}) async {
    operations.add('bulk-write');
    throw StateError('forbidden snapshot write');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Agent extends NikoMacBackgroundAgent {
  int enables = 0;
  final List<String> operations;
  _Agent(this.operations);
  @override
  Future<bool> configured() async => false;
  @override
  Future<bool> hasOwnedConfiguration() async => false;
  @override
  Future<bool> enable() async {
    operations.add('agent-enable');
    enables++;
    return true;
  }
}

void main() {
  late _PolicyBridge bridge;
  late NativeUnattendedPolicyGateway gateway;
  setUp(() {
    NikoLanguage.english = true;
    bridge = _PolicyBridge();
    gateway = NativeUnattendedPolicyGateway(bridge: bridge);
  });

  test('unattended approval uses ordered verified patches instead of bulk',
      () async {
    await gateway.save('synthetic-test-secret');
    expect(bridge.operations, [
      'read:1',
      'password-save',
      'read:2',
      'patch:verification-method:use-permanent-password',
      'read:3',
      'patch:approve-mode:password',
      'read:4',
    ]);
    expect(bridge.options['verification-method'], 'use-permanent-password');
    expect(bridge.options['approve-mode'], 'password');
    expect(bridge.options['stop-service'], 'Y');
    expect(bridge.options['unrelated-option'], 'preserved');
  });

  for (final key in [
    'custom-rendezvous-server',
    'relay-server',
    'key',
    'nikodesk-server-namespace'
  ]) {
    for (final read in [2, 3, 4]) {
      test('server $key drift at read $read aborts policy confirmation',
          () async {
        bridge.driftKey = key;
        bridge.driftRead = read;
        await expectLater(
            gateway.save('synthetic-test-secret'), throwsStateError);
        expect(bridge.reads, read);
        expect(bridge.operations, isNot(contains('bulk-write')));
        if (read <= 3) {
          expect(bridge.operations,
              isNot(contains('patch:approve-mode:password')));
        }
        if (read == 2) {
          expect(
              bridge.operations,
              isNot(contains(
                  'patch:verification-method:use-permanent-password')));
        }
      });
    }
  }

  for (final read in [1, 2, 3, 4]) {
    test('unreadable options at read $read stop the next policy step',
        () async {
      bridge.malformedRead = read;
      await expectLater(
          gateway.save('synthetic-test-secret'), throwsFormatException);
      expect(bridge.reads, read);
      expect(bridge.operations, isNot(contains('bulk-write')));
      if (read == 1) expect(bridge.operations, ['read:1']);
      if (read <= 3) {
        expect(
            bridge.operations, isNot(contains('patch:approve-mode:password')));
      }
    });
  }

  test('password save failure leaves both authentication policies unchanged',
      () async {
    bridge.passwordSaved = false;
    await expectLater(gateway.save('synthetic-test-secret'), throwsStateError);
    expect(bridge.operations, ['read:1', 'password-save']);
    expect(bridge.options['verification-method'], 'use-both-passwords');
    expect(bridge.options['approve-mode'], 'click');
  });

  test('unconfirmed permanent policy never enables password approval',
      () async {
    bridge.ignoredPatch = 'verification-method';
    await expectLater(gateway.save('synthetic-test-secret'), throwsStateError);
    expect(bridge.reads, 3);
    expect(bridge.options['approve-mode'], 'click');
    expect(bridge.operations, isNot(contains('patch:approve-mode:password')));
  });

  test('unconfirmed approval never reports full policy success', () async {
    bridge.ignoredPatch = 'approve-mode';
    await expectLater(gateway.save('synthetic-test-secret'), throwsStateError);
    expect(bridge.reads, 4);
    expect(bridge.options['verification-method'], 'use-permanent-password');
    expect(bridge.options['approve-mode'], 'click');
  });

  for (final key in ['key', 'nikodesk-server-namespace']) {
    test('unknown server $key never saves a password', () async {
      bridge.options.remove(key);
      await expectLater(
          gateway.save('synthetic-test-secret'), throwsStateError);
      expect(bridge.operations, ['read:1']);
    });
  }

  for (final password in ['', '   ', 'x' * 129]) {
    test('invalid password length is rejected before native access', () async {
      await expectLater(gateway.save(password), throwsFormatException);
      expect(bridge.operations, isEmpty);
    });
  }

  Future<_Agent> loadSettings(WidgetTester tester,
      {bool permitted = true}) async {
    final agent = _Agent(bridge.operations);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: NikoMacBackgroundSettings(
                agent: agent,
                policyGateway: gateway,
                permissionsGranted: () => permitted))));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'synthetic-test-secret');
    await tester
        .tap(find.text('Confirm unattended access and register recovery'));
    await tester.pumpAndSettle();
    return agent;
  }

  testWidgets('background registration follows final policy confirmation',
      (tester) async {
    final agent = await loadSettings(tester);
    expect(agent.enables, 1);
    expect(bridge.operations.last, 'agent-enable');
    expect(bridge.operations[bridge.operations.length - 2], 'read:4');
    expect(bridge.operations, isNot(contains('bulk-write')));
    expect(find.textContaining('Background configuration is confirmed'),
        findsOneWidget);
  });

  for (final read in [1, 2, 3, 4]) {
    testWidgets(
        'read failure at step $read never registers background recovery',
        (tester) async {
      bridge.malformedRead = read;
      final agent = await loadSettings(tester);
      expect(agent.enables, 0);
      expect(bridge.operations, isNot(contains('bulk-write')));
      expect(find.textContaining('Background setup is incomplete'),
          findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('missing permissions prevent password, policy and agent changes',
      (tester) async {
    final agent = await loadSettings(tester, permitted: false);
    expect(agent.enables, 0);
    expect(bridge.operations, isEmpty);
    expect(
        find.textContaining('Grant NikoDesk Screen Recording'), findsOneWidget);
  });

  testWidgets('an unmounted page never starts background recovery',
      (tester) async {
    final pending = Completer<bool>();
    bridge.pendingPassword = pending;
    final agent = _Agent(bridge.operations);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: NikoMacBackgroundSettings(
                agent: agent,
                policyGateway: gateway,
                permissionsGranted: () => true))));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'synthetic-test-secret');
    await tester
        .tap(find.text('Confirm unattended access and register recovery'));
    await tester.pump();
    expect(bridge.operations, ['read:1', 'password-save']);
    await tester.pumpWidget(const SizedBox());
    pending.complete(true);
    await tester.pumpAndSettle();
    expect(agent.enables, 0);
    expect(bridge.operations, isNot(contains('agent-enable')));
    expect(tester.takeException(), isNull);
  });
}
