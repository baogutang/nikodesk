// In-memory stand-in for the generated native bridge, so widget tests can
// render pages that read options synchronously, such as the hosted upstream
// settings page. Only the calls those pages make are implemented; any other
// call fails loudly through noSuchMethod.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_hbb/generated_bridge.dart';
import 'package:uuid/uuid.dart';

class NikoFakeBridge implements RustdeskImpl {
  final options = <String, String>{};
  final local = <String, String>{};
  final userDefault = <String, String>{};
  String appName = 'NikoDesk';

  @override
  bool cmCanElevate({dynamic hint}) => false;
  @override
  int getDoubleClickTime({dynamic hint}) => 500;
  @override
  String getLocalFlutterOption({required String k, dynamic hint}) => local[k] ?? '';
  @override
  bool isCustomClient({dynamic hint}) => false;
  @override
  bool isDisableAb({dynamic hint}) => false;
  @override
  bool isDisableAccount({dynamic hint}) => false;
  @override
  bool isDisableGroupPanel({dynamic hint}) => false;
  @override
  bool isDisableSettings({dynamic hint}) => false;
  @override
  bool isIncomingOnly({dynamic hint}) => false;
  @override
  bool isOutgoingOnly({dynamic hint}) => false;
  @override
  Future<bool> isPresetPassword({dynamic hint}) async => false;
  @override
  bool isPresetPasswordMobileOnly({dynamic hint}) => false;
  @override
  bool mainAudioSupportLoopback({dynamic hint}) => false;
  @override
  Future<void> mainChangeLanguage({required String lang, dynamic hint}) async {}
  @override
  Future<void> mainChangeTheme({required String dark, dynamic hint}) async {}
  @override
  Future<void> mainCheckHwcodec({dynamic hint}) async {}
  @override
  Future<void> mainCheckMouseTime({dynamic hint}) async {}
  @override
  Future<bool> mainCheckSuperUserPermission({dynamic hint}) async => false;
  @override
  bool mainCurrentIsWayland({dynamic hint}) => false;
  @override
  String mainDefaultPrivacyModeImpl({dynamic hint}) => '';
  @override
  Future<String> mainGetApiServer({dynamic hint}) async => '';
  @override
  String mainGetAppNameSync({dynamic hint}) => appName;
  @override
  Future<String> mainGetBuildDate({dynamic hint}) async => '2026-10-21';
  @override
  String mainGetBuildinOption({required String key, dynamic hint}) => '';
  @override
  Future<String> mainGetCommon({required String key, dynamic hint}) async => '';
  @override
  String mainGetCommonSync({required String key, dynamic hint}) => '';
  @override
  Future<String> mainGetConnectStatus({dynamic hint}) async => '{"status_num":1}';
  @override
  String mainGetDisplays({dynamic hint}) => '';
  @override
  Future<String> mainGetFingerprint({dynamic hint}) async => '';
  @override
  Future<String> mainGetLangs({dynamic hint}) async => '[["zh-cn","简体中文"],["en","English"]]';
  @override
  Future<String> mainGetLicense({dynamic hint}) async => '';
  @override
  String mainGetLocalOption({required String key, dynamic hint}) => local[key] ?? '';
  @override
  Future<double> mainGetMouseTime({dynamic hint}) async => 0;
  @override
  Future<String> mainGetMyId({dynamic hint}) async => '';
  @override
  String mainGetNikodeskPeerFlutterOptionSync({required String id, required String expectedServerNamespace, required String k, dynamic hint}) => '';
  @override
  Future<String> mainGetOption({required String key, dynamic hint}) async => options[key] ?? '';
  @override
  String mainGetOptionSync({required String key, dynamic hint}) => options[key] ?? '';
  @override
  Future<String> mainGetOptions({dynamic hint}) async => jsonEncode(options);
  @override
  String mainGetPeerFlutterOptionSync({required String id, required String k, dynamic hint}) => '';
  @override
  String mainGetPeerOptionSync({required String id, required String key, dynamic hint}) => '';
  @override
  String mainGetPeerSync({required String id, dynamic hint}) => '';
  @override
  String mainGetPrinterNames({dynamic hint}) => '';
  @override
  Future<List<String>> mainGetSocks({dynamic hint}) async => const [];
  @override
  Future<void> mainGetSoftwareUpdateUrl({dynamic hint}) async {}
  @override
  Future<List<String>> mainGetSoundInputs({dynamic hint}) async => const [];
  @override
  Future<String> mainGetTemporaryPassword({dynamic hint}) async => '';
  @override
  String mainGetUnlockPin({dynamic hint}) => '';
  @override
  bool mainGetUseTextureRender({dynamic hint}) => false;
  @override
  String mainGetUserDefaultOption({required String key, dynamic hint}) => userDefault[key] ?? '';
  @override
  Future<String> mainGetVersion({dynamic hint}) async => '1.0.11';
  @override
  Future<String> mainHandleRelayId({required String id, dynamic hint}) async => '';
  @override
  Future<String> mainHandleWaylandScreencastRestoreToken({required String key, required String value, dynamic hint}) async => '';
  @override
  bool mainHasHwcodec({dynamic hint}) => false;
  @override
  bool mainHasValid2FaSync({dynamic hint}) => false;
  @override
  bool mainHasValidBotSync({dynamic hint}) => false;
  @override
  bool mainHasVram({dynamic hint}) => false;
  @override
  bool mainIsInstalled({dynamic hint}) => false;
  @override
  bool mainIsInstalledDaemon({required bool prompt, dynamic hint}) => false;
  @override
  bool mainIsOptionFixed({required String key, dynamic hint}) => false;
  @override
  bool mainIsShareRdp({dynamic hint}) => false;
  @override
  Future<bool> mainIsUsingPublicServer({dynamic hint}) async => false;
  @override
  int mainMaxEncryptLen({dynamic hint}) => 128;
  @override
  String mainResolveAvatarUrl({required String avatar, dynamic hint}) => '';
  @override
  Future<void> mainSetCommon({required String key, required String value, dynamic hint}) async {}
  @override
  void mainSetEnv({required String key, String? value, dynamic hint}) {}
  @override
  Future<void> mainSetLocalOption({required String key, required String value, dynamic hint}) async { local[key] = value; }
  @override
  bool mainSetNikodeskPeerFlutterOptionSync({required String id, required String expectedServerNamespace, required String k, required String v, dynamic hint}) => false;
  @override
  Future<void> mainSetOption({required String key, required String value, dynamic hint}) async { options[key] = value; }
  @override
  void mainSetPeerFlutterOptionSync({required String id, required String k, required String v, dynamic hint}) {}
  @override
  Future<void> mainSetPeerOption({required String id, required String key, required String value, dynamic hint}) async {}
  @override
  Future<bool> mainSetPermanentPasswordWithResult({required String password, dynamic hint}) async => false;
  @override
  Future<void> mainSetShareRdp({required bool enable, dynamic hint}) async {}
  @override
  Future<void> mainSetSocks({required String proxy, required String username, required String password, dynamic hint}) async {}
  @override
  Future<void> mainSetUserDefaultOption({required String key, required String value, dynamic hint}) async { userDefault[key] = value; }
  @override
  Future<bool> mainSupportRemoveWallpaper({dynamic hint}) async => false;
  @override
  String mainSupportedHwdecodings({dynamic hint}) => '{}';
  @override
  String mainSupportedPrivacyModeImpls({dynamic hint}) => '[]';
  @override
  Future<String> mainTestIfValidServer({required String server, required bool testWithProxy, dynamic hint}) async => '';
  @override
  Future<void> mainTestWallpaper({required int second, dynamic hint}) async {}
  @override
  String mainUriPrefixSync({dynamic hint}) => 'nikodesk://';
  @override
  String mainVideoSaveDirectory({required bool root, dynamic hint}) => '/Users/demo/Movies/NikoDesk';
  @override
  Future<bool> optionSynced({dynamic hint}) async => false;
  @override
  Future<void> sendUrlScheme({required String url, dynamic hint}) async {}
  @override
  String sessionGetPeerOptionSync({required UuidValue sessionId, required String name, dynamic hint}) => '';
  @override
  Future<String> sessionGetPlatform({required UuidValue sessionId, required bool isRemote, dynamic hint}) async => isRemote ? 'Windows' : 'Mac OS';
  @override
  Future<void> sessionPeerOption({required UuidValue sessionId, required String name, required String value, dynamic hint}) async {}
  @override
  Future<void> sessionRefresh({required UuidValue sessionId, required int display, dynamic hint}) async {}
  @override
  Future<void> sessionSetCommon({required UuidValue sessionId, required String key, required String value, dynamic hint}) async {}
  @override
  Future<void> sessionSwitchDisplay({required bool isDesktop, required UuidValue sessionId, required Int32List value, dynamic hint}) async {}
  @override
  Future<void> setLocalFlutterOption({required String k, required String v, dynamic hint}) async { local[k] = v; }
  @override
  String translate({required String name, required String locale, dynamic hint}) => name;
  @override
  int versionToNumber({required String v, dynamic hint}) => 1;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
