import 'package:flutter_hbb/models/platform_model.dart';

import 'peer_preferences.dart';

class NativeNikoPeerPreferencesTransport
    implements NikoPeerPreferencesTransport {
  const NativeNikoPeerPreferencesTransport();
  @override
  Future<String> favorites(String namespace) =>
      bind.mainGetNikodeskFavorites(expectedServerNamespace: namespace);
  @override
  Future<String> patchFavorites(String namespace, String revision,
          List<String> add, List<String> remove) =>
      bind.mainPatchNikodeskFavorites(
          expectedServerNamespace: namespace,
          expectedRevision: revision,
          add: add,
          remove: remove);
  @override
  Future<String> previewLegacy(String namespace) =>
      bind.mainPreviewNikodeskLegacyPeerPreferences(
          expectedServerNamespace: namespace);
  @override
  Future<String> importLegacy(
          String namespace, String revision, List<String> peerIds) =>
      bind.mainImportNikodeskLegacyPeerPreferences(
          expectedServerNamespace: namespace,
          previewRevision: revision,
          peerIds: peerIds);
}

final nativeNikoPeerPreferences =
    NikoPeerPreferences(const NativeNikoPeerPreferencesTransport());
