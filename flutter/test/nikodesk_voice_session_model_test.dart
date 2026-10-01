import 'dart:async';
import 'dart:convert';

import 'package:flutter_hbb/nikodesk/voice_session_model.dart';
import 'package:flutter_test/flutter_test.dart';

// Public synthetic fixtures for the transport substitute, not native evidence.
Map<String, dynamic> voiceIdentity(
        {String namespace = 'a', String request = '2'}) =>
    {
      'connection_id': 7,
      'namespace': namespace * 64,
      'peer_id': '123456789',
      'connection_nonce': '1' * 32,
      'request_nonce': request * 32,
      'epoch': '1'
    };
Map<String, dynamic> voiceSelection({String roster = '1'}) => {
      'roster_revision': roster,
      'capture_token': 'a' * 32,
      'capture_format_token': 'c' * 32,
      'playback_token': 'b' * 32,
      'playback_format_token': 'd' * 32
    };
Map<String, dynamic> voiceStatus(
        {String phase = 'Pending',
        String revision = '1',
        String resourceEpoch = '1',
        String namespace = 'a',
        String permission = 'Authorized',
        bool peerAccepted = false,
        bool muted = false}) =>
    {
      'identity': voiceIdentity(namespace: namespace),
      'kind': 'voice',
      'revision': revision,
      'resource_epoch': resourceEpoch,
      'phase': phase,
      'reason': 'pending_local_approval',
      'microphone_permission': permission,
      'muted': muted,
      'local_ready': phase == 'Running',
      'peer_accepted': peerAccepted,
      'call_running': phase == 'Running' && peerAccepted,
      'wire': {'call_nonce': '3' * 32, 'call_epoch': '1'},
      'selection': phase == 'Running' ? voiceSelection() : null,
      'cleanup_only': false
    };
Map<String, dynamic> voiceFormat(String token, {int channels = 1}) => {
      'format_token': token * 32,
      'sample_rate': 48000,
      'sample_format': 'f32',
      'channels': channels,
      'format_schema': 'coreaudio-client-v1'
    };
Map<String, dynamic> voiceCatalog(
        {String revision = '1',
        String roster = '1',
        String namespace = 'a',
        String permission = 'Authorized',
        String? label}) =>
    {
      'identity': voiceIdentity(namespace: namespace),
      'revision': revision,
      'roster_revision': roster,
      'microphone_permission': permission,
      'reason': '',
      'devices': [
        {
          'device_token': 'a' * 32,
          'uid': 'synthetic-input-uid',
          'label': label ?? 'Test microphone',
          'direction': 'capture',
          'formats': [voiceFormat('c')]
        },
        {
          'device_token': 'b' * 32,
          'uid': 'synthetic-output-uid',
          'label': label ?? 'Test speaker',
          'direction': 'playback',
          'formats': [voiceFormat('d', channels: 2)]
        }
      ]
    };
NikoVoiceStatus parsedVoiceStatus(
        {String phase = 'Pending',
        String revision = '1',
        String namespace = 'a',
        String permission = 'Authorized',
        bool peerAccepted = false,
        bool muted = false}) =>
    NikoVoiceStatus.parse(jsonEncode(voiceStatus(
        phase: phase,
        revision: revision,
        namespace: namespace,
        permission: permission,
        peerAccepted: peerAccepted,
        muted: muted)))!;
NikoVoiceCatalog parsedVoiceCatalog(
        {String revision = '1',
        String roster = '1',
        String namespace = 'a',
        String permission = 'Authorized',
        String? label}) =>
    NikoVoiceCatalog.parse(jsonEncode(voiceCatalog(
        revision: revision,
        roster: roster,
        namespace: namespace,
        permission: permission,
        label: label)))!;
String voiceQueued(NikoVoiceCommand command) => jsonEncode({
      'ok': true,
      'status': 'queued',
      'identity': command.captured.identity.toJson(),
      'revision': command.captured.revision
    });
NikoVoiceSelection selectionFor(NikoVoiceCatalog catalog) =>
    catalog.select('a' * 32, 'c' * 32, 'b' * 32, 'd' * 32)!;

void main() {
  test(
      'native resource readiness, peer acceptance and call running remain separate',
      () {
    final pending = parsedVoiceStatus();
    final ready = parsedVoiceStatus(phase: 'Running');
    final call = parsedVoiceStatus(phase: 'Running', peerAccepted: true);
    expect(pending.localReady, false);
    expect(ready.localReady, true);
    expect(ready.peerAccepted, false);
    expect(ready.callRunning, false);
    expect(call.callRunning, true);
  });
  test(
      'strict status parser rejects legacy, missing, inconsistent and malformed fields',
      () {
    final mutations = <void Function(Map<String, dynamic>)>[
      (s) => s['kind'] = 'terminal',
      (s) => s.remove('wire'),
      (s) => s.remove('selection'),
      (s) => s.remove('cleanup_only'),
      (s) => s['microphone_permission'] = 'granted',
      (s) => s['revision'] = 1,
      (s) => s['resource_epoch'] = '01',
      (s) => s['wire']['call_nonce'] = '0' * 32,
      (s) => s['wire']['call_epoch'] = '18446744073709551616',
      (s) => s['unknown'] = true,
      (s) => s['call_running'] = true,
      (s) => s['reason'] = '/private/raw/backend_error'
    ];
    for (final mutate in mutations) {
      final value = voiceStatus();
      mutate(value);
      expect(NikoVoiceStatus.parse(jsonEncode(value)), isNull);
    }
    final running = voiceStatus(phase: 'Running')..['selection'] = null;
    expect(NikoVoiceStatus.parse(jsonEncode(running)), isNull);
    final stopped = voiceStatus(phase: 'Stopped')..['local_ready'] = true;
    expect(NikoVoiceStatus.parse(jsonEncode(stopped)), isNull);
    expect(NikoVoiceStatus.parse('{'), isNull);
    expect(NikoVoiceStatus.parse('x' * 8193), isNull);
  });
  test('u64 decimal strings retain precision and wire epochs stay independent',
      () {
    final value = voiceStatus(resourceEpoch: '18446744073709551615');
    value['revision'] = '18446744073709551615';
    value['wire']['call_epoch'] = '9007199254740993';
    final parsed = NikoVoiceStatus.parse(jsonEncode(value))!;
    expect(parsed.resourceEpoch, '18446744073709551615');
    expect(parsed.revision, '18446744073709551615');
    expect(parsed.callEpoch, '9007199254740993');
  });
  test('catalog freezes exact device direction and format without a default',
      () {
    final catalog = parsedVoiceCatalog();
    expect(catalog.select(null, null, null, null), isNull);
    expect(catalog.select('b' * 32, 'd' * 32, 'a' * 32, 'c' * 32), isNull);
    expect(catalog.select('a' * 32, 'e' * 32, 'b' * 32, 'd' * 32), isNull);
    expect(selectionFor(catalog).toJson(), voiceSelection());
    expect(() => catalog.devices.add(catalog.devices.first),
        throwsUnsupportedError);
  });
  test(
      'catalog parser enforces bounds, duplicate tokens and supported native formats',
      () {
    final mutations = <void Function(Map<String, dynamic>)>[
      (c) => c['devices'][0]['formats'][0]['sample_rate'] = 44100,
      (c) => c['devices'][0]['formats'][0]['sample_rate'] = 48000.0,
      (c) => c['devices'][0]['device_token'] = '0' * 32,
      (c) => c['devices'][1]['formats'][0]['format_token'] = 'c' * 32,
      (c) => c['devices'][0]['formats'][0]['format_token'] = 'a' * 32,
      (c) => c['devices'][0]['formats'][0]['sample_format'] = 'i16',
      (c) => c['devices'][0]['formats'][0]['format_schema'] = 'guessed',
      (c) => c['devices'][0]['formats'][0]['channels'] = 3,
      (c) => c['devices'][0]['formats'][0]['default'] = true,
      (c) => c['devices'][1]['device_token'] = c['devices'][0]['device_token'],
      (c) => c['devices'][0]['uid'] = 'x' * 8193,
      (c) => c['devices'][0]['label'] = '你' * 400,
      (c) => c['devices'][0]['direction'] = 'default',
      (c) => c['devices'][0]['formats'] =
          List.generate(3, (_) => voiceFormat('c')),
      (c) => c['devices'] = List.generate(257, (_) => c['devices'][0]),
    ];
    for (final mutate in mutations) {
      final value = voiceCatalog();
      mutate(value);
      expect(NikoVoiceCatalog.parse(jsonEncode(value)), isNull);
    }
  });
  test(
      'opening and policy/backend unknown never issue discovery or audio commands',
      () async {
    for (final availability in NikoVoiceAvailability.values
        .where((v) => v != NikoVoiceAvailability.enabled)) {
      var calls = 0;
      final model = NikoVoiceSessionModel(
          anchor: parsedVoiceStatus(),
          availability: availability,
          transport: (command) async {
            calls++;
            return voiceQueued(command);
          });
      expect(calls, 0);
      expect(await model.send('enumerate'), false);
      expect(await model.send('approve'), false);
      expect(await model.send('request_permission'), false);
      expect(calls, 0);
      model.dispose();
    }
  });
  test('approve sends only frozen selection, queued grants no native readiness',
      () async {
    final sent = <NikoVoiceCommand>[];
    final model = NikoVoiceSessionModel(
        anchor: parsedVoiceStatus(),
        availability: NikoVoiceAvailability.enabled,
        transport: (command) async {
          sent.add(command);
          return voiceQueued(command);
        });
    final catalog = parsedVoiceCatalog();
    expect(model.applyCatalog(catalog), true);
    expect(await model.send('approve', selection: selectionFor(catalog)), true);
    expect(jsonDecode(sent.single.toJson()), {
      'identity': voiceIdentity(),
      'revision': '1',
      'op': 'approve',
      ...voiceSelection()
    });
    expect(model.status.phase, 'Pending');
    expect(model.status.callRunning, false);
    expect(model.approvalUnconfirmed, true);
    expect(
        await model.send('approve', selection: selectionFor(catalog)), false);
    model.dispose();
  });
  test(
      'microphone permission facts cannot approve or select devices automatically',
      () async {
    final sent = <NikoVoiceCommand>[];
    final model = NikoVoiceSessionModel(
        anchor: parsedVoiceStatus(permission: 'NotDetermined'),
        availability: NikoVoiceAvailability.enabled,
        transport: (command) async {
          sent.add(command);
          return voiceQueued(command);
        });
    expect(await model.send('request_permission'), true);
    expect(sent.single.op, 'request_permission');
    expect(model.status.microphonePermission, 'NotDetermined');
    expect(model.status.phase, 'Pending');
    expect(model.applyStatus(parsedVoiceStatus(revision: '2')), true);
    expect(await model.send('approve'), false);
    expect(model.catalog, isNull);
    model.dispose();
  });
  test('catalog and permission must match current request and monotonic roster',
      () {
    final model = NikoVoiceSessionModel(
        anchor: parsedVoiceStatus(),
        availability: NikoVoiceAvailability.enabled,
        transport: (c) async => voiceQueued(c));
    expect(model.applyCatalog(parsedVoiceCatalog(namespace: 'b')), false);
    expect(model.applyCatalog(parsedVoiceCatalog(revision: '2')), false);
    expect(
        model.applyCatalog(parsedVoiceCatalog(permission: 'Unknown')), false);
    expect(model.applyCatalog(parsedVoiceCatalog(roster: '2')), true);
    expect(model.applyCatalog(parsedVoiceCatalog(roster: '1')), false);
    expect(model.applyCatalog(parsedVoiceCatalog(roster: '2')), false);
    final selection = selectionFor(parsedVoiceCatalog());
    expect(model.mayApprove(selection), false);
    model.dispose();
  });
  test(
      'old namespace, request, wire nonce, epoch and conflicting revision are rejected',
      () {
    final model = NikoVoiceSessionModel(
        anchor: parsedVoiceStatus(revision: '3'),
        transport: (c) async => voiceQueued(c));
    final mutations = <void Function(Map<String, dynamic>)>[
      (s) => s['identity'] = voiceIdentity(namespace: 'b'),
      (s) => s['identity'] = voiceIdentity(request: '4'),
      (s) => s['wire']['call_nonce'] = '4' * 32,
      (s) => s['wire']['call_epoch'] = '2',
      (s) => s['revision'] = '2',
      (s) => s['reason'] = 'changed_with_same_revision',
      (s) => s['cleanup_only'] = true,
    ];
    for (final mutate in mutations) {
      final value = voiceStatus(revision: '3');
      mutate(value);
      expect(
          model.applyStatus(NikoVoiceStatus.parse(jsonEncode(value))!), false);
    }
    expect(model.status.revision, '3');
    expect(model.status.callRunning, false);
    model.dispose();
  });
  test('queued/error reply requires exact identity and captured revision',
      () async {
    for (final mutation in <void Function(Map<String, dynamic>)>[
      (r) => r['identity'] = voiceIdentity(namespace: 'b'),
      (r) => r['revision'] = '2',
      (r) => r['status'] = 'Running',
      (r) => r['legacy'] = true,
      (r) => r.remove('identity')
    ]) {
      final model = NikoVoiceSessionModel(
          anchor: parsedVoiceStatus(),
          transport: (command) async {
            final value =
                jsonDecode(voiceQueued(command)) as Map<String, dynamic>;
            mutation(value);
            return jsonEncode(value);
          });
      expect(await model.send('query'), false);
      expect(model.operationMessage, 'operation_unconfirmed');
      expect(model.status.phase, 'Pending');
      model.dispose();
    }
  });
  test(
      'selection stays frozen and resource phases cannot be revived by higher revisions',
      () {
    final model = NikoVoiceSessionModel(
        anchor: parsedVoiceStatus(phase: 'Running'),
        transport: (c) async => voiceQueued(c));
    final changed = voiceStatus(phase: 'Running', revision: '2');
    changed['selection']['capture_format_token'] = 'e' * 32;
    expect(
        model.applyStatus(NikoVoiceStatus.parse(jsonEncode(changed))!), false);
    expect(model.applyStatus(parsedVoiceStatus(revision: '2')), false);
    expect(
        model.applyStatus(parsedVoiceStatus(phase: 'Starting', revision: '2')),
        false);
    expect(
        model.applyStatus(
            parsedVoiceStatus(phase: 'RecoveryRequired', revision: '2')),
        true);
    expect(
        model.applyStatus(parsedVoiceStatus(phase: 'Running', revision: '3')),
        false);
    expect(
        model.applyStatus(parsedVoiceStatus(phase: 'Stopped', revision: '3')),
        true);
    model.dispose();
    final higher = voiceStatus(phase: 'Running', resourceEpoch: '3');
    final epochModel = NikoVoiceSessionModel(
        anchor: NikoVoiceStatus.parse(jsonEncode(higher))!,
        transport: (c) async => voiceQueued(c));
    final lower =
        voiceStatus(phase: 'Running', resourceEpoch: '2', revision: '2');
    expect(epochModel.applyStatus(NikoVoiceStatus.parse(jsonEncode(lower))!),
        false);
    epochModel.dispose();
  });
  test('late queued result cannot overwrite newer authoritative state',
      () async {
    final reply = Completer<String>();
    NikoVoiceCommand? command;
    final model = NikoVoiceSessionModel(
        anchor: parsedVoiceStatus(),
        transport: (c) {
          command = c;
          return reply.future;
        });
    final sending = model.send('query');
    expect(model.busy, true);
    expect(
        model.applyStatus(parsedVoiceStatus(phase: 'Starting', revision: '2')),
        true);
    expect(model.busy, false);
    reply.complete(voiceQueued(command!));
    expect(await sending, false);
    expect(model.operationMessage, isNull);
    expect(model.status.phase, 'Starting');
    model.dispose();
  });
  test(
      'cleanup timeout keeps latch; only a newer actual Stopped snapshot clears it',
      () async {
    final late = Completer<String>();
    NikoVoiceCommand? command;
    final model = NikoVoiceSessionModel(
        anchor: parsedVoiceStatus(phase: 'Running'),
        commandTimeout: const Duration(milliseconds: 1),
        transport: (c) {
          command = c;
          return late.future;
        });
    expect(await model.send('revoke'), false);
    expect(model.cleanupUnconfirmed, true);
    expect(model.status.phase, 'Running');
    expect(model.mayPrepare, false);
    late.complete(voiceQueued(command!));
    await Future<void>.delayed(Duration.zero);
    expect(model.cleanupUnconfirmed, true);
    expect(model.applyStatus(parsedVoiceStatus(phase: 'Stopped')), false);
    expect(
        model.applyStatus(parsedVoiceStatus(phase: 'Stopped', revision: '2')),
        true);
    expect(model.cleanupUnconfirmed, false);
    expect(model.applyStatus(parsedVoiceStatus(revision: '3')), false);
    model.dispose();
  });
  test('retired cleanup-only anchor cannot enumerate, approve or be revived',
      () async {
    final ops = <String>[];
    final model = NikoVoiceSessionModel(
        anchor: parsedVoiceStatus(phase: 'RecoveryRequired'),
        cleanupOnly: true,
        availability: NikoVoiceAvailability.enabled,
        transport: (c) async {
          ops.add(c.op);
          return voiceQueued(c);
        });
    expect(await model.send('enumerate'), false);
    expect(await model.send('approve'), false);
    expect(await model.send('mute'), false);
    expect(await model.send('retry_cleanup'), true);
    expect(ops, ['retry_cleanup']);
    expect(
        model.applyStatus(parsedVoiceStatus(phase: 'Running', revision: '2')),
        false);
    expect(model.cleanupUnconfirmed, true);
    model.dispose();
  });
  test('mute acknowledgement never changes resource or call-running facts',
      () async {
    final model = NikoVoiceSessionModel(
        anchor: parsedVoiceStatus(phase: 'Running', peerAccepted: true),
        availability: NikoVoiceAvailability.enabled,
        transport: (c) async => voiceQueued(c));
    expect(await model.send('mute'), true);
    expect(model.status.muted, false);
    expect(model.status.localReady, true);
    expect(model.status.callRunning, true);
    expect(
        model.applyStatus(parsedVoiceStatus(
            phase: 'Running', revision: '2', muted: true, peerAccepted: true)),
        true);
    expect(model.status.muted, true);
    expect(model.status.localReady, true);
    model.dispose();
  });
  test('disposed model rejects old command completion and status updates',
      () async {
    final completer = Completer<String>();
    NikoVoiceCommand? command;
    final model = NikoVoiceSessionModel(
        anchor: parsedVoiceStatus(),
        transport: (c) {
          command = c;
          return completer.future;
        });
    final pending = model.send('query');
    model.dispose();
    completer.complete(voiceQueued(command!));
    expect(await pending, false);
    expect(model.applyStatus(parsedVoiceStatus(revision: '2')), false);
    expect(await model.send('query'), false);
  });
  test(
      'controller preparation is explicit and queued supplies no native identity',
      () async {
    var calls = 0;
    final preparation = NikoVoicePreparation(
        contextKey: 'synthetic-session-a',
        availability: NikoVoiceAvailability.enabled,
        prepare: () async {
          calls++;
          return NikoVoicePrepareResult.queued;
        });
    expect(calls, 0);
    expect(preparation.phase, 'idle');
    await preparation.start();
    expect(calls, 1);
    expect(preparation.phase, 'pending');
    await preparation.start();
    expect(calls, 1);
    preparation.dispose();
  });
  test(
      'unconfirmed controller preparation cannot restart and old context retires',
      () async {
    final late = Completer<NikoVoicePrepareResult>();
    final preparation = NikoVoicePreparation(
        contextKey: 'synthetic-old-session',
        timeout: const Duration(milliseconds: 1),
        availability: NikoVoiceAvailability.enabled,
        prepare: () => late.future);
    await preparation.start();
    expect(preparation.phase, 'unconfirmed');
    expect(preparation.mayPrepare, false);
    preparation.dispose();
    late.complete(NikoVoicePrepareResult.queued);
    await Future<void>.delayed(Duration.zero);
    expect(preparation.phase, 'unconfirmed');
  });
}
