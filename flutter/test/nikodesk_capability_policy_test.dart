import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/nikodesk/capability_policy.dart';
import 'package:flutter_hbb/nikodesk/capability_policy_view.dart';
import 'package:flutter_hbb/nikodesk/theme.dart';
import 'package:flutter_hbb/nikodesk/ui.dart';

final _a = 'a' * 64;
final _b = 'b' * 64;
final _revision = 'c' * 64;
String _reply(
        {bool terminal = false,
        String status = 'ready',
        bool ok = true,
        String? revision,
        String generation = '0'}) =>
    jsonEncode({
      'ok': ok,
      'status': status,
      'namespace': _a,
      'revision': revision ?? _revision,
      'generation': generation,
      'allow_requests': {
        'terminal': terminal,
        'tunnel': false,
        'camera': false,
        'voice': false
      },
    });

class _Transport implements NikoCapabilityPolicyTransport {
  String reply = _reply();
  Future<String> Function()? read;
  Future<String> Function()? write;
  final calls = <List<Object>>[];
  @override
  Future<String> get(String namespace) async {
    calls.add(['get', namespace]);
    return read == null ? reply : await read!();
  }

  @override
  Future<String> set(String namespace, String revision,
      NikoCapability capability, bool enabled) async {
    calls.add(['set', namespace, revision, capability.name, enabled]);
    return write == null
        ? _reply(status: 'saved', terminal: enabled)
        : await write!();
  }
}

Matcher _failure(String status) => isA<NikoCapabilityPolicyFailure>()
    .having((e) => e.status, 'status', status);

void main() {
  test('stale scope blocks I/O before sending or consuming a delayed result',
      () async {
    final transport = _Transport();
    var scope = _b;
    final policy =
        NikoCapabilityPolicy(transport, currentNamespace: () => scope);
    await expectLater(policy.get(_a), throwsA(_failure('namespace_changed')));
    expect(transport.calls, isEmpty);
    scope = _a;
    final pending = Completer<String>();
    transport.read = () => pending.future;
    final result = policy.get(_a);
    scope = _b;
    pending.complete(_reply());
    await expectLater(result, throwsA(_failure('namespace_changed')));
  });
  test('CAS conflict preserves the fresh native policy and never auto-retries',
      () async {
    final transport = _Transport()
      ..write =
          () async => _reply(status: 'conflict', ok: false, terminal: true);
    final policy = NikoCapabilityPolicy(transport, currentNamespace: () => _a);
    final conflict =
        await policy.set(_a, _revision, NikoCapability.camera, true);
    expect(conflict.conflict, isTrue);
    expect(conflict.allowRequests[NikoCapability.terminal], isTrue);
    expect(transport.calls, [
      ['set', _a, _revision, 'camera', true]
    ]);
  });
  test(
      'write timeout remains unconfirmed and cannot become a disabled snapshot',
      () async {
    final transport = _Transport()..write = () => Completer<String>().future;
    final policy = NikoCapabilityPolicy(transport,
        currentNamespace: () => _a, timeout: const Duration(milliseconds: 1));
    await expectLater(policy.set(_a, _revision, NikoCapability.voice, true),
        throwsA(_failure('write_unconfirmed')));
  });
  test(
      'malformed policy, foreign response and imprecise generation are rejected',
      () async {
    final transport = _Transport();
    final policy = NikoCapabilityPolicy(transport, currentNamespace: () => _a);
    final ready = jsonDecode(_reply()) as Map<String, dynamic>;
    for (final changes in [
      {'namespace': _b},
      {'generation': 3},
      {'generation': '18446744073709551616'},
      {'generation': '-1'},
      {'revision': 'bad'},
      {'status': 'running'},
      {'status': 'conflict', 'ok': false},
      {
        'allow_requests': {'terminal': false, 'tunnel': false, 'camera': false}
      },
    ]) {
      transport.reply = jsonEncode({...ready, ...changes});
      await expectLater(policy.get(_a), throwsA(_failure('invalid_data')));
    }
    transport.reply = _reply(generation: '18446744073709551615');
    expect((await policy.get(_a)).generation, '18446744073709551615');
    transport.reply = '{broken';
    await expectLater(policy.get(_a), throwsA(_failure('invalid_data')));
  });
  testWidgets(
      'permission checkbox requires local confirmation and only sends one-kind CAS',
      (tester) async {
    final transport = _Transport();
    final policy = NikoCapabilityPolicy(transport, currentNamespace: () => _a);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: NikoCapabilityPolicyView(
                policy: policy,
                namespace: _a,
                scopeChanges: ValueNotifier(_a)))));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('capability-policy-terminal')));
    await tester.pumpAndSettle();
    expect(transport.calls.where((call) => call.first == 'set'), isEmpty);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(transport.calls.where((call) => call.first == 'set'), isEmpty);
    await tester.tap(find.byKey(const ValueKey('capability-policy-terminal')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('允许请求'));
    await tester.pumpAndSettle();
    expect(transport.calls.last, ['set', _a, _revision, 'terminal', true]);
    expect(tester.takeException(), isNull);
  });
  testWidgets('scope change during confirmation invalidates the save',
      (tester) async {
    final transport = _Transport();
    var current = _a;
    final changes = ValueNotifier<String?>(_a);
    final policy =
        NikoCapabilityPolicy(transport, currentNamespace: () => current);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: NikoCapabilityPolicyView(
                policy: policy, namespace: _a, scopeChanges: changes))));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('capability-policy-terminal')));
    await tester.pumpAndSettle();
    current = _b;
    changes.value = _b;
    await tester.pumpAndSettle();
    await tester.tap(find.text('允许请求'));
    await tester.pumpAndSettle();
    expect(transport.calls.where((call) => call.first == 'set'), isEmpty);
    expect(find.textContaining('私服已变更'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  for (final english in [false, true]) {
    for (final brightness in [Brightness.light, Brightness.dark]) {
      testWidgets('policy at 320/200% $english $brightness', (tester) async {
        NikoLanguage.english = english;
        addTearDown(() => NikoLanguage.english = false);
        await tester.binding.setSurfaceSize(const Size(320, 500));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final transport = _Transport();
        await tester.pumpWidget(MaterialApp(
            theme: nikoTheme(brightness),
            builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(2)),
                child: child!),
            home: Scaffold(
                body: Center(
                    child: NikoCapabilityPolicyView(
                        policy: NikoCapabilityPolicy(transport,
                            currentNamespace: () => _a),
                        namespace: _a,
                        scopeChanges: ValueNotifier(_a))))));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(
            find.byKey(const ValueKey('capability-policy-voice')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text(english ? 'Close' : '关闭'), findsOneWidget);
      });
    }
  }
}
