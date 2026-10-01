import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/nikodesk/capability_policy.dart';
import 'package:flutter_hbb/nikodesk/capability_policy_view.dart';
import 'package:flutter_hbb/nikodesk/theme.dart';
import 'package:flutter_hbb/nikodesk/ui.dart';
import 'package:flutter_test/flutter_test.dart';

final _namespace = 'a' * 64;
final _revision = 'c' * 64;

// Transport substitute only: no native policy, microphone or permission call.
class _VoicePolicyTransport implements NikoCapabilityPolicyTransport {
  final calls = <List<Object>>[];
  bool voice = false, conflict = false;
  Future<String> Function()? read;
  Future<String> Function()? write;
  String reply({String status = 'ready', bool ok = true}) => jsonEncode({
        'ok': ok,
        'status': status,
        'namespace': _namespace,
        'revision': _revision,
        'generation': '0',
        'allow_requests': {
          'terminal': false,
          'tunnel': false,
          'camera': false,
          'voice': voice
        }
      });
  @override
  Future<String> get(String namespace) async {
    calls.add(['get', namespace]);
    return read == null ? reply() : await read!();
  }

  @override
  Future<String> set(String namespace, String revision,
      NikoCapability capability, bool allowRequests) async {
    calls.add(['set', namespace, revision, capability.name, allowRequests]);
    if (write != null) return write!();
    if (conflict) return reply(status: 'conflict', ok: false);
    voice = allowRequests;
    return reply(status: 'saved');
  }
}

Future<void> _host(WidgetTester tester, Widget widget,
    {bool english = false, bool dark = false}) async {
  NikoLanguage.english = english;
  tester.view.physicalSize = const Size(320, 700);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(
      theme: nikoTheme(dark ? Brightness.dark : Brightness.light),
      builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(2)),
          child: child!),
      home: Scaffold(body: SingleChildScrollView(child: widget))));
}

Future<void> _open(WidgetTester tester) async {
  final open = find.byKey(const Key('nikodesk-mobile-voice-policy-open'));
  await tester.ensureVisible(open);
  await tester.tap(open);
  await tester.pumpAndSettle();
}

void main() {
  tearDown(() => NikoLanguage.english = false);
  for (final english in [false, true]) {
    for (final dark in [false, true]) {
      testWidgets(
          'Android Voice-only 320/200% en=$english dark=$dark local CAS',
          (tester) async {
        final transport = _VoicePolicyTransport();
        final changes = ValueNotifier<String?>(_namespace);
        addTearDown(changes.dispose);
        final policy = NikoCapabilityPolicy(transport,
            currentNamespace: () => changes.value);
        await _host(tester,
            NikoMobileVoicePolicyCard(policy: policy, scopeChanges: changes),
            english: english, dark: dark);
        expect(transport.calls, isEmpty);
        await _open(tester);
        expect(find.byType(SwitchListTile), findsOneWidget);
        expect(find.byKey(const ValueKey('capability-policy-terminal')),
            findsNothing);
        expect(find.byKey(const ValueKey('capability-policy-camera')),
            findsNothing);
        expect(find.byKey(const ValueKey('capability-policy-tunnel')),
            findsNothing);
        final toggle = find.byKey(const ValueKey('capability-policy-voice'));
        await tester.ensureVisible(toggle);
        expect(tester.widget<SwitchListTile>(toggle).value, false);
        expect(tester.getSize(toggle).height, greaterThanOrEqualTo(48));
        await tester.tap(toggle);
        await tester.pumpAndSettle();
        expect(transport.calls.where((c) => c.first == 'set'), isEmpty);
        await tester.ensureVisible(find.text(english ? 'Cancel' : '取消'));
        await tester.tap(find.text(english ? 'Cancel' : '取消'));
        await tester.pumpAndSettle();
        expect(transport.calls.where((c) => c.first == 'set'), isEmpty);
        await tester.tap(toggle);
        await tester.pumpAndSettle();
        final confirm = find.widgetWithText(
            FilledButton, english ? 'Allow requests' : '允许请求');
        await tester.ensureVisible(confirm);
        await tester.tap(confirm);
        await tester.pumpAndSettle();
        expect(transport.calls.last,
            ['set', _namespace, _revision, 'voice', true]);
        expect(tester.widget<SwitchListTile>(toggle).value, true);
        await tester.ensureVisible(toggle);
        await tester.tap(toggle);
        await tester.pumpAndSettle();
        expect(transport.calls.last,
            ['set', _namespace, _revision, 'voice', false]);
        expect(tester.widget<SwitchListTile>(toggle).value, false);
        expect(tester.takeException(), isNull);
      });
    }
  }
  testWidgets('missing private-server scope disables with actionable text',
      (tester) async {
    final transport = _VoicePolicyTransport();
    final changes = ValueNotifier<String?>(null);
    addTearDown(changes.dispose);
    await _host(
        tester,
        NikoMobileVoicePolicyCard(
            policy: NikoCapabilityPolicy(transport), scopeChanges: changes));
    final open = find.byKey(const Key('nikodesk-mobile-voice-policy-open'));
    expect(tester.widget<OutlinedButton>(open).onPressed, isNull);
    expect(find.textContaining('请先配置有效的私有服务器'), findsOneWidget);
    expect(transport.calls, isEmpty);
  });
  testWidgets('private-server change during approval cannot write old policy',
      (tester) async {
    final transport = _VoicePolicyTransport();
    final changes = ValueNotifier<String?>(_namespace);
    addTearDown(changes.dispose);
    final policy =
        NikoCapabilityPolicy(transport, currentNamespace: () => changes.value);
    await _host(tester,
        NikoMobileVoicePolicyCard(policy: policy, scopeChanges: changes));
    await _open(tester);
    final toggle = find.byKey(const ValueKey('capability-policy-voice'));
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    changes.value = 'b' * 64;
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('允许请求'));
    await tester.tap(find.text('允许请求'));
    await tester.pumpAndSettle();
    expect(transport.calls.where((c) => c.first == 'set'), isEmpty);
    expect(find.textContaining('私服已变更'), findsOneWidget);
    expect(find.byType(SwitchListTile), findsNothing);
  });
  testWidgets('CAS conflict is unconfirmed and cannot auto-enable voice',
      (tester) async {
    final transport = _VoicePolicyTransport()..conflict = true;
    final changes = ValueNotifier<String?>(_namespace);
    addTearDown(changes.dispose);
    await _host(
        tester,
        NikoMobileVoicePolicyCard(
            policy: NikoCapabilityPolicy(transport,
                currentNamespace: () => changes.value),
            scopeChanges: changes));
    await _open(tester);
    final toggle = find.byKey(const ValueKey('capability-policy-voice'));
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('允许请求'));
    await tester.tap(find.text('允许请求'));
    await tester.pumpAndSettle();
    expect(transport.calls.where((c) => c.first == 'set').length, 1);
    expect(find.byType(SwitchListTile), findsNothing);
    expect(find.textContaining('策略已被其他窗口修改'), findsOneWidget);
    expect(transport.voice, false);
    await tester.ensureVisible(find.text('刷新'));
    await tester.tap(find.text('刷新'));
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(toggle).value, false);
    expect(tester.takeException(), isNull);
  });
  testWidgets('hung read and its late result cannot enable a later refresh',
      (tester) async {
    final late = Completer<String>();
    final transport = _VoicePolicyTransport()..read = () => late.future;
    final changes = ValueNotifier<String?>(_namespace);
    addTearDown(changes.dispose);
    final policy = NikoCapabilityPolicy(transport,
        currentNamespace: () => changes.value,
        timeout: const Duration(milliseconds: 100));
    await _host(tester,
        NikoMobileVoicePolicyCard(policy: policy, scopeChanges: changes));
    await _open(tester);
    expect(find.byType(SwitchListTile), findsNothing);
    expect(find.textContaining('策略读取或保存失败'), findsOneWidget);
    transport.read = null;
    await tester.ensureVisible(find.text('刷新'));
    await tester.tap(find.text('刷新'));
    await tester.pumpAndSettle();
    transport.voice = true;
    late.complete(transport.reply());
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<SwitchListTile>(
                find.byKey(const ValueKey('capability-policy-voice')))
            .value,
        false);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
      'keyboard opens Voice-only policy without audio or permission work',
      (tester) async {
    final transport = _VoicePolicyTransport();
    final changes = ValueNotifier<String?>(_namespace);
    addTearDown(changes.dispose);
    await _host(
        tester,
        NikoMobileVoicePolicyCard(
            policy: NikoCapabilityPolicy(transport,
                currentNamespace: () => changes.value),
            scopeChanges: changes));
    final open = find.text('设置语音请求');
    await tester.ensureVisible(open);
    Focus.of(tester.element(open)).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(transport.calls, [
      ['get', _namespace]
    ]);
    expect(find.byType(SwitchListTile), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
