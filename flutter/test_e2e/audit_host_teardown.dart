// The controlled side must have recorded the same two sessions from its own
// login and close events.
import 'package:flutter_hbb/nikodesk/session_audit.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/native.dart';

void main() {
  test('the controlled profile recorded the refused and the accepted session',
      () async {
    final native = await NikoNative.instance();
    expect(native.profile, 'host');
    final namespace = await native.configureServer();
    final snapshot = SessionAuditSnapshot.parse(
        await native.bind.mainNikoSessionAudit(namespace: namespace),
        namespace);
    final recent = snapshot.entries
        .where((entry) =>
            entry.role == 'receiver' &&
            entry.startedAt.isAfter(DateTime.now()
                .toUtc()
                .subtract(const Duration(minutes: 2))))
        .toList();
    final phases = recent.map((entry) => entry.phase).toList();
    expect(phases, contains('disconnected'), reason: 'recent: $phases');
    expect(phases, contains('not_authenticated'), reason: 'recent: $phases');
  }, timeout: const Timeout(Duration(minutes: 2)));
}
