import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/nikodesk/terminal_session_access.dart';
import 'package:flutter_test/flutter_test.dart';

class _Session implements FFI {
  @override
  final String id;
  @override
  final String? serverNamespace;
  @override
  bool closed;
  _Session(this.id, this.serverNamespace, {this.closed = false});
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void main() {
  test(
      'persistent option lookup uses captured namespace and peer instead of the legacy Get tag',
      () {
    final session = _Session('123456789', 'a' * 64);
    final actual = nikoTerminalOptionOwner(
        peerId: session.id,
        serverNamespace: session.serverNamespace,
        lookup: (peer, {serverNamespace}) {
          expect(peer, '123456789');
          expect(serverNamespace, 'a' * 64);
          return {
            '${session.serverNamespace}:${session.id}': session
          }['$serverNamespace:$peer'];
        });
    expect(actual, same(session));
  });

  test(
      'closed, foreign peer/scope, missing or unattributed owner cannot change a terminal option',
      () {
    for (final session in <FFI?>[
      null,
      _Session('123456789', 'a' * 64, closed: true),
      _Session('987654321', 'a' * 64),
      _Session('123456789', 'b' * 64),
    ]) {
      expect(
          nikoTerminalOptionOwner(
              peerId: '123456789',
              serverNamespace: 'a' * 64,
              lookup: (_, {serverNamespace}) => session),
          isNull);
    }
    expect(
        nikoTerminalOptionOwner(
            peerId: '123456789',
            serverNamespace: null,
            lookup: (_, {serverNamespace}) =>
                throw StateError('must not lookup')),
        isNull);
  });
}
