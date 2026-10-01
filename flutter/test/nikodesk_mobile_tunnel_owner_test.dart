import 'dart:async';
import 'dart:convert';

import 'package:flutter_hbb/mobile/pages/port_forward_page.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/nikodesk/tunnel_cleanup.dart';
import 'package:flutter_hbb/nikodesk/tunnel_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

class _Global implements FFI {
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _Session implements FFI {
  @override
  final sessionId = const Uuid().v4obj();
  @override
  NikoTunnelController? get nikoTunnelController => null;
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

String proof(NikoTunnelOwnerIdentity identity,
        {bool closed = true, String reason = 'closed', bool ok = true}) =>
    jsonEncode({
      'session_id': identity.sessionId,
      'namespace': identity.namespace,
      'peer_id': identity.peerId,
      'ok': ok,
      'reason': reason,
      'local_resources_closed': closed,
    });
void main() {
  final global = _Global();
  const scope =
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  NikoMobileTunnelOwner open(
          {Future<String> Function(NikoTunnelOwnerIdentity)? close,
          Future<String> Function(NikoTunnelOwnerIdentity)? query,
          Future<void> Function(FFI)? dartClose,
          Duration? timeout}) =>
      NikoMobileTunnelOwner.open(
          globalOwner: global,
          namespace: scope,
          peerId: '123456789',
          createFfi: (_) => _Session(),
          closeNative: close ?? (identity) async => proof(identity),
          queryNative: query ?? (identity) async => proof(identity),
          closeDart: dartClose ?? (_) async {},
          timeout: timeout ?? const Duration(seconds: 5));
  test('fresh page UUID; old repeated close cannot release its successor',
      () async {
    final first = open();
    expect(await first.close(), true);
    final second = open();
    expect(first.identity.sessionId, isNot(second.identity.sessionId));
    await first.close();
    expect(NikoMobileTunnelOwner.hasActiveSession, true);
    expect(await second.close(), true);
  });
  test(
      'queued/pending or Dart teardown completion cannot unlock owner before real query',
      () async {
    var dartClosed = 0;
    final first = open(
        close: (identity) async => proof(identity,
            closed: false, reason: 'cleanup_pending', ok: false),
        dartClose: (_) async {
          dartClosed++;
        });
    expect(await first.close(), false);
    expect(dartClosed, 1);
    expect(NikoMobileTunnelOwner.hasActiveSession, true);
    expect(() => open(), throwsStateError);
    expect(await first.close(query: true), true);
    expect(NikoMobileTunnelOwner.hasActiveSession, false);
  });
  test(
      'timeout and wrong-scope proof remain occupied; exact global proof releases CAS',
      () async {
    final late = Completer<String>();
    final first = open(
        close: (_) => late.future, timeout: const Duration(milliseconds: 1));
    expect(await first.close(), false);
    expect(NikoMobileTunnelOwner.hasActiveSession, true);
    final wrong = NikoTunnelOwnerIdentity(
        first.identity.sessionId, 'b' * 64, first.identity.peerId);
    NikoTunnelCleanupProofs.record(
        NikoTunnelCleanupReply.parse(proof(wrong), wrong)!);
    expect(NikoMobileTunnelOwner.hasActiveSession, true);
    late.complete(proof(first.identity));
    await Future<void>.delayed(Duration.zero);
    expect(NikoMobileTunnelOwner.hasActiveSession, true);
    NikoTunnelCleanupProofs.record(
        NikoTunnelCleanupReply.parse(proof(first.identity), first.identity)!);
    expect(NikoMobileTunnelOwner.hasActiveSession, false);
  });
  test('confirmed native proof permits exit even if Dart cleanup hangs',
      () async {
    final first = open(
        dartClose: (_) => Completer<void>().future,
        timeout: const Duration(milliseconds: 1));
    expect(await first.close(), true);
    expect(NikoMobileTunnelOwner.hasActiveSession, false);
  });
}
