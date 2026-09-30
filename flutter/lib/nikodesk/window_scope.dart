import 'server_scope.dart';

const nikoWindowScopeMethod = 'nikodesk-server-scope';

class NikoWindowScope {
  static String? _namespace;
  static String? get current => _namespace;

  static void initialize(Map<String, dynamic> params) {
    final namespace = nikoWindowNamespace(params);
    if (namespace == null || (_namespace != null && _namespace != namespace)) {
      throw StateError(
          'A session window must retain its private server identity');
    }
    _namespace = namespace;
  }
}

String? nikoWindowNamespace(Map<String, dynamic> params) =>
    NikoServerScope.validate(params['serverNamespace']);

Future<String?> nikoReadWindowNamespace(
    int window, Future<Object?> Function(int) readNamespace) async {
  try {
    return NikoServerScope.validate(
        await readNamespace(window).timeout(const Duration(seconds: 2)));
  } catch (_) {
    return null;
  }
}

String nikoConnectionStorageKey(String peerId, String? namespace) {
  if (NikoServerScope.validate(namespace) == null) {
    throw StateError('Private server identity is required');
  }
  return '$namespace:$peerId';
}

Future<List<int>> nikoMatchingWindows(List<int> windows, String? namespace,
    Future<Object?> Function(int) readNamespace) async {
  if (NikoServerScope.validate(namespace) == null) return [];
  final candidates = windows.toList();
  final scopes = await Future.wait(candidates
      .map((window) => nikoReadWindowNamespace(window, readNamespace)));
  return [
    for (var index = 0; index < candidates.length; index++)
      if (scopes[index] == namespace) candidates[index]
  ];
}
