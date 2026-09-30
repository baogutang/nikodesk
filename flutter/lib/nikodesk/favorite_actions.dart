import 'peer_preferences.dart';
import 'server_scope.dart';

class NikoFavoritePeerRef {
  final String id;
  final String? namespace;
  const NikoFavoritePeerRef(this.id, this.namespace);
}

/// Validate the provenance of the displayed selection before any native read.
/// Never bind unscoped or mixed-server rows to the current server implicitly.
String nikoFavoriteSelectionScope(Iterable<NikoFavoritePeerRef> peers) {
  final selected = peers.toList();
  if (selected.isEmpty || selected.length > 4096) {
    throw const NikoPeerPreferencesFailure('invalid_data');
  }
  final namespace = NikoServerScope.validate(selected.first.namespace);
  if (namespace == null ||
      selected.any((peer) =>
          peer.namespace != namespace ||
          !RegExp(r'^\d{6,16}$').hasMatch(peer.id))) {
    throw const NikoPeerPreferencesFailure('namespace_changed');
  }
  return namespace;
}

Future<NikoFavoritesSnapshot> nikoChangeFavorites(
    NikoPeerPreferences preferences, Iterable<NikoFavoritePeerRef> peers,
    {required bool favorite}) async {
  final selected = peers.toList();
  final namespace = nikoFavoriteSelectionScope(selected);
  final ids = selected.map((peer) => peer.id).toSet();
  final snapshot = await preferences.readFavorites(namespace);
  return preferences.patchFavorites(snapshot,
      add: favorite ? ids : const [], remove: favorite ? const [] : ids);
}
