// Real sessions must leave matching local records on the controller, read
// back through the production parser.
import 'dart:io';

import 'package:flutter_hbb/nikodesk/session_audit.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/native.dart';

void main() {
  test('a refused and an accepted session are both recorded with their outcome',
      () async {
    final native = await NikoNative.instance();
    expect(native.profile, 'ctrl');
    final host =
        File('${env('NIKODESK_E2E_WORK')}/host/id').readAsStringSync().trim();
    final password = env('NIKODESK_E2E_HOST_PASSWORD');
    final namespace = await native.configureServer();
    Future<SessionAuditSnapshot> read() async => SessionAuditSnapshot.parse(
        await native.bind.mainNikoSessionAudit(namespace: namespace),
        namespace);
    final before = {for (final entry in (await read()).entries) entry.session};
    final started = DateTime.now().toUtc();

    final refused =
        await NikoSession.open(native, host, password: 'wrong-$password');
    await refused.event(
        (event) =>
            event['name'] == 'msgbox' && event['type'] == 're-input-password',
        'wrong-password prompt');
    await refused.close();

    final accepted = await NikoSession.open(native, host, password: password);
    await accepted.event(
        (event) => event['name'] == 'peer_info', 'peer info after login');
    await Future<void>.delayed(const Duration(seconds: 2));
    await accepted.close();

    // Records are written by a background task after the session ends.
    late List<SessionAuditEntry> added;
    for (var attempt = 0; attempt < 40; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      final snapshot = await read();
      expect(snapshot.incomplete, isFalse);
      added = snapshot.entries
          .where((entry) => !before.contains(entry.session))
          .toList();
      if (added.length >= 2 && added.every((entry) => entry.endedAt != null)) {
        break;
      }
    }
    expect(added, hasLength(2),
        reason: 'phases seen: ${added.map((entry) => entry.phase).toList()}');
    for (final entry in added) {
      expect(entry.role, 'controller');
      expect(entry.kind, 'desktop');
      expect(entry.peerId, host);
      expect(
          entry.startedAt
              .isAfter(started.subtract(const Duration(seconds: 2))),
          isTrue);
    }
    final phases = added.map((entry) => entry.phase).toSet();
    expect(phases, {'not_authenticated', 'disconnected'});
    final complete =
        added.firstWhere((entry) => entry.phase == 'disconnected');
    expect(complete.authenticatedAt, isNotNull);
    expect(complete.durationMs, greaterThanOrEqualTo(1500));
  }, timeout: const Timeout(Duration(minutes: 3)));
}
