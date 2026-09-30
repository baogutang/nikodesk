import 'package:flutter_hbb/nikodesk/window_scope.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final a = 'a' * 64;
  final b = 'b' * 64;

  test('same peer ID on different servers has different local connection keys',
      () {
    expect(nikoConnectionStorageKey('123456', a),
        isNot(nikoConnectionStorageKey('123456', b)));
    expect(() => nikoConnectionStorageKey('123456', null), throwsStateError);
  });

  test('candidate reuse skips other namespaces and closed windows', () async {
    final scopes = {1: a, 2: b, 3: a};
    expect(
        await nikoMatchingWindows([1, 2, 3, 4], a, (window) async {
          if (window == 4) throw StateError('Closed');
          return scopes[window];
        }),
        [1, 3]);
    expect(await nikoMatchingWindows([1, 2], null, (_) async => a), isEmpty);
  });

  test('invalid or unavailable window identity never resolves to current scope',
      () async {
    expect(await nikoReadWindowNamespace(1, (_) async => 'broken'), isNull);
    expect(await nikoReadWindowNamespace(2, (_) async => null), isNull);
    expect(await nikoReadWindowNamespace(3, (_) async => a), a);
    expect(await nikoReadWindowNamespace(4, (_) async => throw StateError('Gone')),
        isNull);
  });

  test('a session engine retains its original namespace for its lifetime', () {
    NikoWindowScope.initialize({'serverNamespace': a});
    NikoWindowScope.initialize({'serverNamespace': a});
    expect(NikoWindowScope.current, a);
    expect(() => NikoWindowScope.initialize({'serverNamespace': b}),
        throwsStateError);
    expect(() => NikoWindowScope.initialize({}), throwsStateError);
    expect(NikoWindowScope.current, a);
  });
}
