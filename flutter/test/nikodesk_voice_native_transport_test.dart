import 'dart:convert';

import 'package:flutter_hbb/generated_bridge.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/nikodesk/tunnel_controller.dart';
import 'package:flutter_hbb/nikodesk/voice_session_model.dart';
import 'package:flutter_hbb/nikodesk/voice_session_native.dart';
import 'package:flutter_hbb/nikodesk/voice_session_owner.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

import 'nikodesk_voice_owner_test.dart' show voiceEnabled, voiceEvent;
import 'nikodesk_voice_session_model_test.dart'
    show parsedVoiceStatus, voiceStatus, voiceQueued;

// Generated bridge interface substitute. No native library or resource access.
class _VoiceBridge implements Rustdesk {
  final sessions = <UuidValue>[];
  final operations = <String>[];
  final payloads = <Map<String, dynamic>>[];
  @override
  Future<String> sessionVoicePrepare(
      {required UuidValue sessionId, dynamic hint}) async {
    sessions.add(sessionId);
    operations.add('prepare');
    return '{"ok":true,"status":"queued"}';
  }

  @override
  Future<String> sessionVoiceAvailability(
      {required UuidValue sessionId, dynamic hint}) async {
    sessions.add(sessionId);
    operations.add('sessionAvailability');
    return voiceEnabled;
  }

  @override
  Future<String> sessionVoiceCommand(
      {required UuidValue sessionId,
      required String json,
      dynamic hint}) async {
    sessions.add(sessionId);
    operations.add('sessionCommand');
    payloads.add(jsonDecode(json));
    return '{"ok":true,"status":"queued","identity":${jsonEncode(payloads.last['identity'])},"revision":"1"}';
  }

  @override
  Future<String> cmVoiceAvailability(
      {required String jsonIdentity, dynamic hint}) async {
    operations.add('cmAvailability');
    payloads.add(jsonDecode(jsonIdentity));
    return voiceEnabled;
  }

  @override
  Future<String> cmVoiceCommand({required String json, dynamic hint}) async {
    operations.add('cmCommand');
    payloads.add(jsonDecode(json));
    return '{"ok":true,"status":"queued","identity":${jsonEncode(payloads.last['identity'])},"revision":"1"}';
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _VoiceFfi implements FFI {
  @override
  final UuidValue sessionId = UuidValue('11111111-1111-4111-8111-111111111111');
  @override
  NikoVoiceSessionOwner? nikoVoiceOwner;
  @override
  NikoTunnelController? get nikoTunnelController => null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test(
      'production native transport captures SessionID and never calls prepare on construction',
      () async {
    final bridge = _VoiceBridge();
    final session = UuidValue('11111111-1111-4111-8111-111111111111');
    final transport = NativeNikoSessionVoiceTransport(session, bridge: bridge);
    expect(bridge.operations, isEmpty);
    expect(await transport.availability(), voiceEnabled);
    expect(await transport.prepare(), '{"ok":true,"status":"queued"}');
    final model = NikoVoiceSessionModel(
        anchor: parsedVoiceStatus(), transport: transport.send);
    addTearDown(model.dispose);
    expect(await model.send('query'), true);
    expect(bridge.operations,
        ['sessionAvailability', 'prepare', 'sessionCommand']);
    expect(bridge.sessions, [session, session, session]);
    expect(bridge.payloads.single, {
      'identity': model.status.identity.toJson(),
      'revision': '1',
      'op': 'query'
    });
    expect(model.status.phase, 'Pending');
  });
  test('CM uses independent actual identity getter and local command bridge',
      () async {
    final bridge = _VoiceBridge();
    final transport = NativeNikoCmVoiceTransport(bridge: bridge);
    final status = parsedVoiceStatus();
    expect(await transport.availability(status), voiceEnabled);
    expect(bridge.payloads.single, status.identity.toJson());
    final model =
        NikoVoiceSessionModel(anchor: status, transport: transport.send);
    addTearDown(model.dispose);
    expect(await model.send('query'), true);
    expect(bridge.operations, ['cmAvailability', 'cmCommand']);
    expect(bridge.sessions, isEmpty);
    expect(model.status.callRunning, false);
  });
  test(
      'actual FfiModel event callback retains original owner rather than current global owner',
      () async {
    NikoVoiceSessionOwner create(String key) => NikoVoiceSessionOwner(
        contextKey: key,
        namespace: 'a' * 64,
        peerId: '123456789',
        isCurrent: () => true,
        readAvailability: () async => voiceEnabled,
        prepareNative: () async => '{}',
        commandNative: (c) async => voiceQueued(c));
    final ffi = _VoiceFfi();
    final old = create('old');
    ffi.nikoVoiceOwner = old;
    final handler = FfiModel(WeakReference(ffi))
        .startEventListener(ffi.sessionId, '123456789');
    old.dispose();
    final next = create('new');
    addTearDown(next.dispose);
    ffi.nikoVoiceOwner = next;
    await handler(voiceEvent(voiceStatus()));
    expect(next.model, isNull);
    final nextHandler = FfiModel(WeakReference(ffi))
        .startEventListener(ffi.sessionId, '123456789');
    await nextHandler(voiceEvent(voiceStatus()));
    expect(next.model != null, const bool.fromEnvironment('NIKODESK'));
  });
  test('legacy voice notifications cannot advance owned Niko call state',
      () async {
    final ffi = _VoiceFfi();
    final owner = NikoVoiceSessionOwner(
        contextKey: 'session',
        namespace: 'a' * 64,
        peerId: '123456789',
        isCurrent: () => true,
        readAvailability: () async => voiceEnabled,
        prepareNative: () async => '{}',
        commandNative: (c) async => voiceQueued(c));
    addTearDown(owner.dispose);
    ffi.nikoVoiceOwner = owner;
    final handler = FfiModel(WeakReference(ffi))
        .startEventListener(ffi.sessionId, '123456789');
    for (final name in [
      'on_voice_call_started',
      'on_voice_call_closed',
      'on_voice_call_incoming',
      'update_voice_call_state'
    ]) {
      await handler({'name': name});
    }
    expect(owner.model, isNull);
  }, skip: !const bool.fromEnvironment('NIKODESK'));
}
