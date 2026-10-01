import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/nikodesk/theme.dart';
import 'package:flutter_hbb/nikodesk/ui.dart';
import 'package:flutter_hbb/nikodesk/voice_session_model.dart';
import 'package:flutter_hbb/nikodesk/voice_session_native.dart';
import 'package:flutter_hbb/nikodesk/voice_session_owner.dart';
import 'package:flutter_test/flutter_test.dart';

import 'nikodesk_voice_owner_test.dart' show voiceEnabled, voiceEvent;
import 'nikodesk_voice_session_model_test.dart' show voiceStatus, voiceQueued;

String _rejected(String reason) =>
    jsonEncode({'ok': false, 'status': 'error', 'reason': reason});
const _queued = '{"ok":true,"status":"queued"}';
String _peerDisabled() {
  final raw = jsonDecode(voiceEnabled);
  raw['peer_requests_allowed'] = false;
  raw['reason'] = 'peer_policy_disabled';
  return jsonEncode(raw);
}

NikoVoiceSessionOwner _owner(
        {required Future<String> Function() prepare,
        Future<String> Function()? read,
        bool Function()? current,
        Duration timeout = const Duration(seconds: 5)}) =>
    NikoVoiceSessionOwner(
        contextKey: 'synthetic-original-session',
        namespace: 'a' * 64,
        peerId: '123456789',
        isCurrent: current ?? () => true,
        readAvailability: read ?? () async => voiceEnabled,
        prepareNative: prepare,
        timeout: timeout,
        commandNative: (c) async => voiceQueued(c));

void main() {
  tearDown(() => NikoLanguage.english = false);
  test('only the two exact native no-Call policy failures are retryable', () {
    for (final reason in ['policy_disabled', 'peer_policy_disabled']) {
      expect(nikoVoicePrepareReply(_rejected(reason)),
          NikoVoicePrepareResult.policyRejected);
    }
    for (final reason in [
      'busy',
      'worker_failed',
      'timeout',
      'unknown',
      'voice_requests_disabled_locally',
      'permission_denied'
    ]) {
      expect(nikoVoicePrepareReply(_rejected(reason)),
          NikoVoicePrepareResult.unconfirmed);
    }
    for (final raw in [
      '{"ok":true,"status":"queued","reason":"policy_disabled"}',
      '{"ok":false,"status":"queued","reason":"policy_disabled"}',
      '{"ok":false,"status":"error","reason":"policy_disabled","identity":{}}'
    ]) {
      expect(nikoVoicePrepareReply(raw),
          isNot(NikoVoicePrepareResult.policyRejected));
    }
  });
  for (final reason in ['policy_disabled', 'peer_policy_disabled']) {
    test(
        'explicit $reason refusal requires fresh enabled metadata and one click',
        () async {
      var prepares = 0;
      var availability = voiceEnabled;
      final owner = _owner(
          read: () async => availability,
          prepare: () async => ++prepares == 1 ? _rejected(reason) : _queued);
      addTearDown(owner.dispose);
      await owner.refreshAvailability();
      await owner.preparation.start();
      expect(owner.preparation.phase, 'policy_rejected');
      expect(owner.preparation.mayPrepare, false);
      expect(owner.model, isNull);
      availability = _peerDisabled();
      await owner.refreshAvailability();
      expect(owner.preparation.phase, 'policy_rejected');
      availability = voiceEnabled;
      await owner.refreshAvailability();
      expect(owner.preparation.phase, 'idle');
      expect(owner.preparation.mayPrepare, true);
      expect(prepares, 1); // Refresh does not create a call.
      await owner.preparation.start();
      await owner.preparation.start();
      expect(prepares, 2);
      expect(owner.preparation.phase, 'pending');
      expect(owner.model, isNull);
    });
  }
  test('a metadata request from before the refusal cannot unlock retry',
      () async {
    final oldRead = Completer<String>();
    var reads = 0;
    final owner = _owner(
        read: () => ++reads == 2 ? oldRead.future : Future.value(voiceEnabled),
        prepare: () async => _rejected('policy_disabled'));
    addTearDown(owner.dispose);
    await owner.refreshAvailability();
    final old = owner.refreshAvailability();
    await owner.preparation.start();
    oldRead.complete(voiceEnabled);
    await old;
    expect(owner.preparation.phase, 'policy_rejected');
    expect(owner.preparation.mayPrepare, false);
    await owner.refreshAvailability();
    expect(owner.preparation.mayPrepare, true);
  });
  test(
      'native anchor arriving first fences a late rejection of old preparation',
      () async {
    final reply = Completer<String>();
    final owner = _owner(prepare: () => reply.future);
    addTearDown(owner.dispose);
    await owner.refreshAvailability();
    final old = owner.preparation.start();
    expect(owner.handleEvent(voiceEvent(voiceStatus())), true);
    final current = owner.model;
    reply.complete(_rejected('peer_policy_disabled'));
    await old;
    await owner.refreshAvailability();
    expect(owner.model, same(current));
    expect(owner.model!.status.phase, 'Pending');
    expect(owner.reason, isNot('peer_policy_disabled'));
  });
  test('an existing stopped anchor cannot gain this no-anchor recovery path',
      () async {
    var prepares = 0;
    final owner = _owner(prepare: () async {
      prepares++;
      return _rejected('policy_disabled');
    });
    addTearDown(owner.dispose);
    await owner.refreshAvailability();
    owner.handleEvent(voiceEvent(voiceStatus(phase: 'Stopped')));
    await owner.preparation.start();
    await owner.refreshAvailability();
    expect(owner.model, isNotNull);
    expect(owner.preparation.phase, 'policy_rejected');
    expect(owner.preparation.mayPrepare, false);
    expect(prepares, 1);
  });
  test(
      'a queued request never resets merely because metadata still allows voice',
      () async {
    var prepares = 0;
    final owner = _owner(prepare: () async {
      prepares++;
      return _queued;
    });
    addTearDown(owner.dispose);
    await owner.refreshAvailability();
    await owner.preparation.start();
    for (var i = 0; i < 3; i++) {
      await owner.refreshAvailability();
      await owner.preparation.start();
    }
    expect(prepares, 1);
    expect(owner.preparation.phase, 'pending');
    expect(owner.model, isNull);
  });
  for (final lateReply in [_rejected('peer_policy_disabled'), _queued]) {
    test('timed-out Prepare cannot revive from late reply $lateReply',
        () async {
      final pending = Completer<String>();
      var prepares = 0;
      final owner = _owner(
          timeout: const Duration(milliseconds: 10),
          prepare: () {
            prepares++;
            return pending.future;
          });
      addTearDown(owner.dispose);
      await owner.refreshAvailability();
      await owner.preparation.start();
      expect(owner.preparation.phase, 'unconfirmed');
      pending.complete(lateReply);
      await Future<void>.delayed(Duration.zero);
      await owner.refreshAvailability();
      await owner.preparation.start();
      expect(owner.preparation.phase, 'unconfirmed');
      expect(owner.preparation.mayPrepare, false);
      expect(prepares, 1);
    });
  }
  test('unknown or malformed rejection stays uncertain after fresh metadata',
      () async {
    for (final raw in [
      '{}',
      _rejected('worker_failed'),
      _rejected('timeout')
    ]) {
      final owner = _owner(prepare: () async => raw);
      await owner.refreshAvailability();
      await owner.preparation.start();
      await owner.refreshAvailability();
      expect(owner.preparation.phase, 'unconfirmed');
      expect(owner.preparation.mayPrepare, false);
      owner.dispose();
    }
  });
  test('failed fresh read cannot unlock a confirmed rejection', () async {
    var availability = voiceEnabled;
    final owner = _owner(
        read: () async => availability,
        prepare: () async => _rejected('policy_disabled'));
    addTearDown(owner.dispose);
    await owner.refreshAvailability();
    await owner.preparation.start();
    availability = '{}';
    await owner.refreshAvailability();
    expect(owner.preparation.phase, 'policy_rejected');
    expect(owner.preparation.mayPrepare, false);
    availability = voiceEnabled;
    await owner.refreshAvailability();
    expect(owner.preparation.mayPrepare, true);
  });
  test('scope/session invalidation during fresh read does not unlock old owner',
      () async {
    var current = true, reads = 0;
    final pending = Completer<String>();
    final owner = _owner(
        current: () => current,
        read: () => ++reads == 2 ? pending.future : Future.value(voiceEnabled),
        prepare: () async => _rejected('policy_disabled'));
    await owner.refreshAvailability();
    await owner.preparation.start();
    final read = owner.refreshAvailability();
    current = false;
    owner.dispose();
    pending.complete(voiceEnabled);
    await read;
    expect(owner.active, false);
    expect(owner.preparation.mayPrepare, false);
  });
  test('inactive original context cannot reuse an earlier enabled snapshot',
      () async {
    var current = true, reads = 0;
    final pending = Completer<String>();
    final owner = _owner(
        current: () => current,
        read: () => ++reads == 2 ? pending.future : Future.value(voiceEnabled),
        prepare: () async => _rejected('policy_disabled'));
    addTearDown(owner.dispose);
    await owner.refreshAvailability();
    await owner.preparation.start();
    final read = owner.refreshAvailability();
    current = false;
    pending.complete(voiceEnabled);
    await read;
    expect(owner.active, false);
    expect(owner.preparation.phase, 'policy_rejected');
    expect(owner.preparation.mayPrepare, false);
  });

  for (final english in [false, true]) {
    for (final dark in [false, true]) {
      testWidgets('policy rejection refresh 320/200% en=$english dark=$dark',
          (tester) async {
        NikoLanguage.english = english;
        tester.view.physicalSize = const Size(320, 700);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        var prepares = 0, availability = voiceEnabled;
        final owner = _owner(
            read: () async => availability,
            prepare: () async =>
                ++prepares == 1 ? _rejected('peer_policy_disabled') : _queued);
        addTearDown(owner.dispose);
        await owner.refreshAvailability();
        await owner.preparation.start();
        availability = _peerDisabled();
        await tester.pumpWidget(MaterialApp(
            theme: nikoTheme(dark ? Brightness.dark : Brightness.light),
            builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: const TextScaler.linear(2)),
                child: child!),
            home: Scaffold(
                body: Builder(
                    builder: (context) => TextButton(
                        onPressed: () => showNikoVoiceSession(context, owner),
                        child: const Text('open'))))));
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        expect(
            find.textContaining(
                english ? 'The call request was not allowed.' : '通话请求未被允许'),
            findsOneWidget);
        final prepare = find.byKey(const ValueKey('niko-voice-prepare'));
        expect(tester.widget<FilledButton>(prepare).onPressed, isNull);
        final refresh =
            find.text(english ? 'Check voice availability' : '检查语音可用性');
        await tester.ensureVisible(refresh);
        availability = voiceEnabled;
        await tester.tap(refresh);
        await tester.pumpAndSettle();
        expect(tester.widget<FilledButton>(prepare).onPressed, isNotNull);
        expect(prepares, 1);
        await tester.ensureVisible(prepare);
        expect(tester.getSize(prepare).height, greaterThanOrEqualTo(48));
        await tester.tap(prepare);
        await tester.pumpAndSettle();
        expect(prepares, 2);
        expect(owner.preparation.phase, 'pending');
        expect(owner.model, isNull);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
