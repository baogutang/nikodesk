import 'dart:async';
import 'dart:convert';

import 'package:flutter_hbb/nikodesk/cm_voice_ledger.dart';
import 'package:flutter_hbb/nikodesk/voice_session_model.dart';
import 'package:flutter_hbb/nikodesk/voice_session_owner.dart';
import 'package:flutter_test/flutter_test.dart';

import 'nikodesk_voice_session_model_test.dart'
    show
        voiceStatus,
        voiceCatalog,
        voiceQueued,
        parsedVoiceStatus,
        parsedVoiceCatalog;

const voiceEnabled =
    '{"supported":true,"requests_allowed":true,"peer_supported":true,"peer_requests_allowed":true,"reason":""}';
Map<String, dynamic> voiceEvent(Map<String, dynamic> payload,
        {String name = 'nikodesk_voice_status'}) =>
    {
      'name': name,
      'payload': jsonEncode(payload),
      'namespace': payload['identity']['namespace'],
      'peer_id': payload['identity']['peer_id'],
      'connection_nonce': payload['identity']['connection_nonce'],
    };
Map<String, dynamic> freshCall({String phase = 'Pending', String epoch = '2'}) {
  final result = voiceStatus(phase: phase);
  result['wire'] = {'call_nonce': '4' * 32, 'call_epoch': epoch};
  result['identity']['request_nonce'] = '5' * 32;
  return result;
}

void main() {
  test(
      'incoming reverse call renews only after confirmed stop and never prepares or opens audio automatically',
      () async {
    var prepares = 0, commands = 0;
    final receiver = jsonEncode({
      ...jsonDecode(voiceEnabled) as Map<String, dynamic>,
      'peer_requests_allowed': false
    });
    final owner = NikoVoiceSessionOwner(
        contextKey: 'session-A',
        namespace: 'a' * 64,
        peerId: '123456789',
        isCurrent: () => true,
        readAvailability: () async => receiver,
        prepareNative: () async {
          prepares++;
          return '{}';
        },
        commandNative: (command) async {
          commands++;
          return voiceQueued(command);
        });
    addTearDown(owner.dispose);
    expect(owner.handleEvent(voiceEvent(voiceStatus())..['initiator'] = 'peer'),
        true);
    await owner.refreshAvailability();
    expect(owner.model!.availability, NikoVoiceAvailability.enabled);
    expect(owner.handleEvent(voiceEvent(freshCall())..['initiator'] = 'peer'),
        false);
    expect(
        owner.handleEvent(
            voiceEvent(voiceStatus(phase: 'Stopped', revision: '2'))),
        true);
    expect(owner.handleEvent(voiceEvent(freshCall())..['initiator'] = 'peer'),
        true);
    expect(owner.model!.status.callEpoch, '2');
    expect(owner.handleEvent(voiceEvent(voiceStatus())..['initiator'] = 'peer'),
        false);
    expect(prepares + commands, 0);
  });
  test('availability requires all independent native facts and strict types',
      () {
    expect(NikoVoiceAvailabilitySnapshot.parse(voiceEnabled)!.availability,
        NikoVoiceAvailability.enabled);
    for (final field in [
      'supported',
      'requests_allowed',
      'peer_supported',
      'peer_requests_allowed'
    ]) {
      final raw = jsonDecode(voiceEnabled) as Map<String, dynamic>;
      raw[field] = false;
      expect(NikoVoiceAvailabilitySnapshot.parse(jsonEncode(raw))!.availability,
          isNot(NikoVoiceAvailability.enabled));
      raw[field] = 'true';
      expect(NikoVoiceAvailabilitySnapshot.parse(jsonEncode(raw)), isNull);
    }
    expect(
        NikoVoiceAvailabilitySnapshot.parse(voiceEnabled.replaceFirst(
            '"reason":""', '"unknown":true,"reason":""')),
        isNull);
    expect(nikoVoicePrepareReply('{"ok":true,"status":"queued","identity":{}}'),
        NikoVoicePrepareResult.unconfirmed);
  });

  test('constructor, native status and catalog never prepare or enumerate',
      () async {
    var prepares = 0, commands = 0;
    final owner = NikoVoiceSessionOwner(
        contextKey: 'session-A',
        namespace: 'a' * 64,
        peerId: '123456789',
        isCurrent: () => true,
        readAvailability: () async => voiceEnabled,
        prepareNative: () async {
          prepares++;
          return '{"ok":true,"status":"queued"}';
        },
        commandNative: (c) async {
          commands++;
          return voiceQueued(c);
        });
    addTearDown(owner.dispose);
    expect(owner.handleEvent(voiceEvent(voiceStatus())), true);
    expect(
        owner.handleEvent(
            voiceEvent(voiceCatalog(), name: 'nikodesk_voice_catalog')),
        true);
    expect(owner.model!.availability, NikoVoiceAvailability.unknown);
    expect(owner.model!.catalog, isNull);
    await owner.refreshAvailability();
    expect(owner.model!.catalog, isNotNull);
    expect(prepares + commands, 0);
    expect(await owner.model!.send('query'), true);
    expect(commands, 1);
    expect(owner.model!.status.phase, 'Pending');
  });

  test(
      'controller events require captured namespace peer nonce and strict payload',
      () {
    final owner = NikoVoiceSessionOwner(
        contextKey: 'session-A',
        namespace: 'a' * 64,
        peerId: '123456789',
        isCurrent: () => true,
        readAvailability: () async => voiceEnabled,
        prepareNative: () async => '{}',
        commandNative: (c) async => voiceQueued(c));
    addTearDown(owner.dispose);
    for (final changes in [
      {'namespace': 'b' * 64},
      {'peer_id': '987654321'},
      {'connection_nonce': '9' * 32},
      {'payload': '{}'},
      {'name': 'legacy_voice_started'},
    ]) {
      expect(
          owner.handleEvent(voiceEvent(voiceStatus())..addAll(changes)), false);
    }
    expect(owner.model, isNull);
    expect(owner.handleEvent(voiceEvent(voiceStatus())), true);
    final changed = voiceStatus(revision: '2');
    changed['wire']['call_nonce'] = '9' * 32;
    expect(owner.handleEvent(voiceEvent(changed)), false);
    expect(owner.model!.status.revision, '1');
  });

  test(
      'queued prepare creates no Dart anchor; fresh native call only after real stop and explicit prepare',
      () async {
    var prepares = 0;
    final owner = NikoVoiceSessionOwner(
        contextKey: 'session-A',
        namespace: 'a' * 64,
        peerId: '123456789',
        isCurrent: () => true,
        readAvailability: () async => voiceEnabled,
        prepareNative: () async {
          prepares++;
          return '{"ok":true,"status":"queued"}';
        },
        commandNative: (c) async => voiceQueued(c));
    addTearDown(owner.dispose);
    await owner.refreshAvailability();
    await owner.preparation.start();
    expect(owner.model, isNull);
    expect(owner.preparation.phase, 'pending');
    expect(owner.handleEvent(voiceEvent(voiceStatus())), true);
    expect(owner.handleEvent(voiceEvent(freshCall())), false);
    expect(
        owner.handleEvent(
            voiceEvent(voiceStatus(phase: 'Stopped', revision: '2'))),
        true);
    expect(owner.handleEvent(voiceEvent(freshCall())), false);
    await owner.preparation.start();
    expect(owner.handleEvent(voiceEvent(freshCall())), true);
    expect(prepares, 2);
    expect(owner.model!.status.callEpoch, '2');
    expect(
        owner.handleEvent(
            voiceEvent(voiceStatus(phase: 'Running', revision: '8'))),
        false);
    expect(owner.model!.status.phase, 'Pending');
  });

  test(
      'shutdown uncertainty survives owner cache reuse; queued revoke is not stop ACK',
      () async {
    final owner = NikoVoiceSessionOwner(
        contextKey: 'session-A',
        namespace: 'a' * 64,
        peerId: '123456789',
        isCurrent: () => true,
        readAvailability: () async => voiceEnabled,
        prepareNative: () async => '{}',
        commandNative: (c) async => voiceQueued(c));
    addTearDown(owner.dispose);
    owner.handleEvent(voiceEvent(voiceStatus(phase: 'Running')));
    final cached = owner.model!;
    expect(await cached.send('revoke'), true);
    expect(owner.model, same(cached));
    expect(cached.cleanupUnconfirmed, true);
    expect(cached.status.phase, 'Running');
    expect(owner.handleEvent(voiceEvent(freshCall())), false);
    expect(
        owner.handleEvent(
            voiceEvent(voiceStatus(phase: 'Stopped', revision: '2'))),
        true);
    expect(cached.cleanupUnconfirmed, false);
  });

  test(
      'bounded metadata timeout remains unknown and late result cannot enable disposed owner',
      () async {
    final pending = Completer<String>();
    var current = true;
    final owner = NikoVoiceSessionOwner(
        contextKey: 'session-A',
        namespace: 'a' * 64,
        peerId: '123456789',
        isCurrent: () => current,
        timeout: const Duration(milliseconds: 5),
        readAvailability: () => pending.future,
        prepareNative: () async => '{}',
        commandNative: (c) async => voiceQueued(c));
    await owner.refreshAvailability();
    expect(owner.reading, false);
    expect(owner.availability, NikoVoiceAvailability.unknown);
    owner.dispose();
    current = false;
    pending.complete(voiceEnabled);
    await Future<void>.delayed(Duration.zero);
    expect(owner.handleEvent(voiceEvent(voiceStatus())), false);
    expect(owner.model, isNull);
  });

  test('old command completion cannot mutate the new call or disposed session',
      () async {
    final pending = Completer<String>();
    final owner = NikoVoiceSessionOwner(
        contextKey: 'session-A',
        namespace: 'a' * 64,
        peerId: '123456789',
        isCurrent: () => true,
        readAvailability: () async => voiceEnabled,
        prepareNative: () async => '{"ok":true,"status":"queued"}',
        commandNative: (_) => pending.future);
    await owner.refreshAvailability();
    owner.handleEvent(voiceEvent(voiceStatus()));
    final old = owner.model!;
    final result = old.send('query');
    owner.handleEvent(voiceEvent(voiceStatus(phase: 'Stopped', revision: '2')));
    await owner.preparation.start();
    owner.handleEvent(voiceEvent(freshCall()));
    final next = owner.model!;
    pending.complete('{}');
    expect(await result, false);
    expect(next.operationMessage, isNull);
    owner.dispose();
    expect(next.mayPrepare, false);
  });

  test('CM status without trusted anchor cannot create a voice grant', () {
    final ledger = NikoCmVoiceLedger(
        command: (c) async => voiceQueued(c),
        readAvailability: (_) async => voiceEnabled);
    addTearDown(ledger.dispose);
    expect(ledger.status(parsedVoiceStatus()), false);
    expect(ledger.model(7), isNull);
  });

  test('scope change deactivates callback cache and cannot install late status',
      () async {
    var current = true;
    final pending = Completer<String>();
    final owner = NikoVoiceSessionOwner(
        contextKey: 'session-A',
        namespace: 'a' * 64,
        peerId: '123456789',
        isCurrent: () => current,
        readAvailability: () => pending.future,
        prepareNative: () async => '{}',
        commandNative: (c) async => voiceQueued(c));
    addTearDown(owner.dispose);
    final reading = owner.refreshAvailability();
    current = false;
    pending.complete(voiceEnabled);
    await reading;
    expect(owner.availability, NikoVoiceAvailability.unknown);
    expect(owner.handleEvent(voiceEvent(voiceStatus())), false);
    expect(owner.model, isNull);
  });

  test(
      'CM approves actual incoming request without fabricating peer incoming policy',
      () async {
    final raw = jsonDecode(voiceEnabled) as Map<String, dynamic>;
    raw['peer_requests_allowed'] = false;
    final snapshot = NikoVoiceAvailabilitySnapshot.parse(jsonEncode(raw))!;
    expect(snapshot.peerRequestsAllowed, false);
    expect(snapshot.availability, NikoVoiceAvailability.peerPolicyDisabled);
    expect(snapshot.receiverAvailability, NikoVoiceAvailability.enabled);
    final ledger = NikoCmVoiceLedger(
        command: (c) async => voiceQueued(c),
        readAvailability: (_) async => jsonEncode(raw));
    addTearDown(ledger.dispose);
    ledger.anchor(parsedVoiceStatus(),
        cleanupOnly: false, catalog: parsedVoiceCatalog());
    await Future<void>.delayed(Duration.zero);
    expect(ledger.model(7)!.mayPrepare, true);
    expect(ledger.model(7)!.catalog, isNotNull);
  });

  test(
      'CM catalog waits for actual availability without inferring support from Pending',
      () async {
    final available = Completer<String>();
    var commands = 0;
    final ledger = NikoCmVoiceLedger(
        command: (c) async {
          commands++;
          return voiceQueued(c);
        },
        readAvailability: (_) => available.future);
    addTearDown(ledger.dispose);
    expect(
        ledger.anchor(parsedVoiceStatus(),
            cleanupOnly: false, catalog: parsedVoiceCatalog()),
        true);
    final model = ledger.model(7)!;
    expect(model.mayPrepare, false);
    expect(model.catalog, isNull);
    available.complete(voiceEnabled);
    await Future<void>.delayed(Duration.zero);
    expect(model.mayPrepare, true);
    expect(model.catalog, isNotNull);
    expect(commands, 0);
  });

  test(
      'CM cannot self-retire from event and cannot revive retired cleanup-only row',
      () async {
    final ledger = NikoCmVoiceLedger(
        command: (c) async => voiceQueued(c),
        readAvailability: (_) async => voiceEnabled);
    addTearDown(ledger.dispose);
    ledger.anchor(parsedVoiceStatus(phase: 'Running'), cleanupOnly: false);
    final retiredRaw = voiceStatus(phase: 'RecoveryRequired', revision: '2');
    retiredRaw['cleanup_only'] = true;
    final retired = NikoVoiceStatus.parse(jsonEncode(retiredRaw))!;
    expect(ledger.status(retired), false);
    expect(ledger.anchor(retired, cleanupOnly: true), true);
    final model = ledger.model(7)!;
    expect(model.cleanupOnly, true);
    expect(await model.send('enumerate'), false);
    expect(await model.send('request_permission'), false);
    expect(await model.send('retry_cleanup'), true);
    expect(model.cleanupUnconfirmed, true);
    expect(
        ledger.anchor(parsedVoiceStatus(phase: 'Running', revision: '3'),
            cleanupOnly: false),
        false);
    final stoppedRaw = voiceStatus(phase: 'Stopped', revision: '3');
    stoppedRaw['cleanup_only'] = true;
    expect(ledger.status(NikoVoiceStatus.parse(jsonEncode(stoppedRaw))!), true);
    expect(model.cleanupUnconfirmed, false);
  });

  test(
      'CM old availability future and command cannot cross a replacement identity',
      () async {
    final pending = Completer<String>();
    final ledger = NikoCmVoiceLedger(
        command: (c) async => voiceQueued(c),
        readAvailability: (_) => pending.future);
    ledger.anchor(parsedVoiceStatus(), cleanupOnly: false);
    final old = ledger.model(7)!;
    ledger.remove(7);
    final nextStatus = NikoVoiceStatus.parse(jsonEncode(freshCall()))!;
    ledger.anchor(nextStatus, cleanupOnly: false);
    final next = ledger.model(7)!;
    ledger.dispose();
    pending.complete(voiceEnabled);
    await Future<void>.delayed(Duration.zero);
    expect(old.mayPrepare || next.mayPrepare, false);
    expect(await old.send('query'), false);
  });

  test('CM availability timeout cannot become supported from a catalog',
      () async {
    final pending = Completer<String>();
    final ledger = NikoCmVoiceLedger(
        command: (c) async => voiceQueued(c),
        availabilityTimeout: const Duration(milliseconds: 5),
        readAvailability: (_) => pending.future);
    addTearDown(ledger.dispose);
    ledger.anchor(parsedVoiceStatus(),
        cleanupOnly: false, catalog: parsedVoiceCatalog());
    await Future<void>.delayed(const Duration(milliseconds: 15));
    expect(ledger.model(7)!.availability, NikoVoiceAvailability.unknown);
    expect(ledger.model(7)!.mayPrepare, false);
    pending.complete(voiceEnabled);
    await Future<void>.delayed(Duration.zero);
    expect(ledger.model(7)!.mayPrepare, false);
  });
}
