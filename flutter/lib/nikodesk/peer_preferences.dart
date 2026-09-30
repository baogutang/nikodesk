import 'dart:convert';

import 'server_scope.dart';

/// Structured native I/O. Every operation carries the originating server;
/// callers never replace a full favorite list from a cached LocalConfig.
abstract class NikoPeerPreferencesTransport {
  Future<String> favorites(String namespace);
  Future<String> patchFavorites(
      String namespace, String revision, List<String> add, List<String> remove);
  Future<String> previewLegacy(String namespace);
  Future<String> importLegacy(
      String namespace, String revision, List<String> peerIds);
}

class NikoPeerPreferencesFailure implements Exception {
  final String status;
  const NikoPeerPreferencesFailure(this.status);
  // Do not expose the native exception, paths or raw response in UI/logs.
  @override
  String toString() => 'NikoPeerPreferencesFailure($status)';
}

class NikoFavoritesSnapshot {
  final String namespace;
  final String revision;
  final Set<String> ids;
  final bool conflict;
  NikoFavoritesSnapshot(this.namespace, this.revision, Iterable<String> ids,
      {this.conflict = false})
      : ids = Set.unmodifiable(ids);
}

class NikoLegacyPeer {
  final String id;
  final String alias;
  final int fieldCount;
  final bool targetExists;
  const NikoLegacyPeer(this.id, this.alias, this.fieldCount, this.targetExists);
}

class NikoLegacyPreview {
  final String namespace;
  final String revision;
  final bool requiresLocalRestart;
  final List<NikoLegacyPeer> items;
  NikoLegacyPreview(this.namespace, this.revision, this.requiresLocalRestart,
      Iterable<NikoLegacyPeer> items)
      : items = List.unmodifiable(items);
}

class NikoLegacyImportResult {
  final bool confirmed;
  final Set<String> imported;
  final Map<String, String> skipped;
  NikoLegacyImportResult(
      this.confirmed, Iterable<String> imported, Map<String, String> skipped)
      : imported = Set.unmodifiable(imported),
        skipped = Map.unmodifiable(skipped);
}

class NikoPeerPreferences {
  final NikoPeerPreferencesTransport transport;
  final String? Function() currentNamespace;
  final Duration timeout;
  NikoPeerPreferences(this.transport,
      {String? Function()? currentNamespace,
      this.timeout = const Duration(seconds: 5)})
      : currentNamespace = currentNamespace ?? (() => NikoServerScope.current);

  static bool _id(Object? value) =>
      value is String && RegExp(r'^\d{6,16}$').hasMatch(value);

  void _checkNamespace(String namespace) {
    if (NikoServerScope.validate(namespace) == null) {
      throw const NikoPeerPreferencesFailure('invalid_namespace');
    }
    if (currentNamespace() != namespace) {
      throw const NikoPeerPreferencesFailure('namespace_changed');
    }
  }

  static Never _invalid() =>
      throw const NikoPeerPreferencesFailure('invalid_data');

  static String _revision(Object? value) =>
      NikoServerScope.validate(value) ?? _invalid();

  static Set<String> _ids(Object? value) {
    if (value is! List || value.length > 4096 || !value.every(_id)) _invalid();
    final ids = value.cast<String>().toSet();
    if (ids.length != value.length) _invalid();
    return ids;
  }

  Future<Map<String, dynamic>> _call(
      String namespace, Future<String> Function() request,
      {bool mutation = false}) async {
    _checkNamespace(namespace);
    String raw;
    try {
      raw = await request().timeout(timeout, onTimeout: () {
        throw NikoPeerPreferencesFailure(
            mutation ? 'timeout_unconfirmed' : 'unavailable');
      });
    } on NikoPeerPreferencesFailure {
      rethrow;
    } catch (_) {
      throw NikoPeerPreferencesFailure(
          mutation ? 'write_unconfirmed' : 'unavailable');
    }
    _checkNamespace(namespace);
    if (raw.length > 4 * 1024 * 1024) _invalid();
    try {
      final result = jsonDecode(raw);
      if (result is! Map<String, dynamic> ||
          result['ok'] is! bool ||
          result['status'] is! String ||
          (result.containsKey('namespace') &&
              result['namespace'] != namespace)) {
        _invalid();
      }
      if (result['ok'] != true &&
          result['status'] != 'conflict' &&
          result['status'] != 'partial_or_unconfirmed') {
        const known = {
          'invalid_namespace',
          'namespace_changed',
          'invalid_revision',
          'disk_error',
          'peer_writers_not_coordinated',
          'unsafe_path',
          'invalid_data',
          'limit_exceeded',
          'unavailable',
          'revision_changed',
          'revision_required',
          'unsupported_atomic_publish',
          'serialization_failed'
        };
        throw NikoPeerPreferencesFailure(known.contains(result['status'])
            ? result['status'] as String
            : 'unavailable');
      }
      return result;
    } on NikoPeerPreferencesFailure {
      rethrow;
    } catch (_) {
      _invalid();
    }
  }

  NikoFavoritesSnapshot _favorites(
      String namespace, Map<String, dynamic> result) {
    final conflict = result['status'] == 'conflict' && result['ok'] == false;
    if (result['namespace'] != namespace ||
        (!conflict &&
            (result['ok'] != true ||
                !{'ready', 'saved'}.contains(result['status'])))) _invalid();
    return NikoFavoritesSnapshot(
        namespace, _revision(result['revision']), _ids(result['ids']),
        conflict: conflict);
  }

  Future<NikoFavoritesSnapshot> readFavorites(String namespace) async =>
      _favorites(namespace,
          await _call(namespace, () => transport.favorites(namespace)));

  Future<NikoFavoritesSnapshot> patchFavorites(NikoFavoritesSnapshot expected,
      {Iterable<String> add = const [],
      Iterable<String> remove = const []}) async {
    _revision(expected.revision);
    final additions = _ids(add.toList());
    final removals = _ids(remove.toList());
    if (additions.intersection(removals).isNotEmpty) _invalid();
    return _favorites(
        expected.namespace,
        await _call(
            expected.namespace,
            () => transport.patchFavorites(expected.namespace,
                expected.revision, additions.toList(), removals.toList()),
            mutation: true));
  }

  Future<NikoLegacyPreview> previewLegacy(String namespace) async {
    final result =
        await _call(namespace, () => transport.previewLegacy(namespace));
    if (result['ok'] != true ||
        result['status'] != 'preview' ||
        result['namespace'] != namespace ||
        result['requires_local_restart'] is! bool ||
        result['items'] is! List ||
        (result['items'] as List).length > 4096) _invalid();
    final items = <NikoLegacyPeer>[];
    final seen = <String>{};
    for (final item in result['items'] as List) {
      if (item is! Map ||
          !_id(item['id']) ||
          !seen.add(item['id']) ||
          item['alias'] is! String ||
          (item['alias'] as String).length > 4096 ||
          item['fields'] is! List ||
          (item['fields'] as List).length > 64 ||
          !(item['fields'] as List).every((field) => field is String) ||
          item['target_exists'] is! bool ||
          item['status'] !=
              (item['target_exists'] ? 'target_exists' : 'available')) {
        _invalid();
      }
      final alias = (item['alias'] as String)
          .replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ')
          .trim();
      items.add(NikoLegacyPeer(item['id'], alias,
          (item['fields'] as List).length, item['target_exists']));
    }
    return NikoLegacyPreview(namespace, _revision(result['revision']),
        result['requires_local_restart'], items);
  }

  Future<NikoLegacyImportResult> importLegacy(
      NikoLegacyPreview preview, Iterable<String> peerIds) async {
    _revision(preview.revision);
    final requested = _ids(peerIds.toList());
    final available = preview.items
        .where((item) => !item.targetExists)
        .map((item) => item.id)
        .toSet();
    if (requested.isEmpty || !available.containsAll(requested)) _invalid();
    final result = await _call(
        preview.namespace,
        () => transport.importLegacy(
            preview.namespace, preview.revision, requested.toList()),
        mutation: true);
    final confirmed = result['ok'] == true && result['status'] == 'imported';
    if ((!confirmed &&
            !(result['ok'] == false &&
                result['status'] == 'partial_or_unconfirmed')) ||
        result['namespace'] != preview.namespace ||
        _revision(result['revision']) != preview.revision ||
        result['skipped'] is! Map) _invalid();
    final imported = _ids(result['imported']);
    final skipped = <String, String>{};
    for (final entry in (result['skipped'] as Map).entries) {
      if (!_id(entry.key) ||
          !{'active_peer', 'target_exists'}.contains(entry.value)) _invalid();
      skipped[entry.key] = entry.value;
    }
    if (!requested.containsAll(imported) ||
        !requested.containsAll(skipped.keys) ||
        imported.intersection(skipped.keys.toSet()).isNotEmpty ||
        (confirmed && imported.length + skipped.length != requested.length)) {
      _invalid();
    }
    return NikoLegacyImportResult(confirmed, imported, skipped);
  }
}
