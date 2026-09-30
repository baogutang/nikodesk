import 'package:flutter_hbb/common.dart';

import 'favorite_actions.dart';
import 'peer_preferences.dart';
import 'peer_preferences_native.dart';
import 'ui.dart';

Future<bool> nikoChangeNativeFavorites(Iterable<NikoFavoritePeerRef> peers,
    {required bool favorite}) async {
  try {
    final result = await nikoChangeFavorites(nativeNikoPeerPreferences, peers,
        favorite: favorite);
    if (result.conflict) {
      showToast(nikoText('另一窗口已修改收藏，请刷新后重试。',
          'Favorites changed in another window. Refresh and retry.'));
      return false;
    }
    return true;
  } on NikoPeerPreferencesFailure catch (error) {
    showToast(error.status == 'namespace_changed'
        ? nikoText('设备来源的服务器已变更，请刷新设备列表。',
            'The device server changed. Refresh the device list.')
        : nikoText('无法确认收藏变更，请刷新后重试。',
            'The favorite change is unconfirmed. Refresh and retry.'));
    return false;
  }
}

Future<List<String>?> nikoReadNativeFavorites(NikoFavoritePeerRef peer) async {
  try {
    final namespace = nikoFavoriteSelectionScope([peer]);
    return (await nativeNikoPeerPreferences.readFavorites(namespace))
        .ids
        .toList();
  } on NikoPeerPreferencesFailure {
    showToast(nikoText('收藏读取失败，请刷新设备列表后重试。',
        'Favorites could not be read. Refresh the device list and retry.'));
    return null;
  }
}
