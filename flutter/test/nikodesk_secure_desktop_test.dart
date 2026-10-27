import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/models/model.dart' show PeerInfo;
import 'package:flutter_hbb/nikodesk/secure_desktop.dart';

PeerInfo _peer(String platform, {bool? installed}) => PeerInfo()
  ..platform = platform
  ..platformAdditions = {
    if (installed != null) kPlatformAdditionsIsInstalled: installed,
  };

void main() {
  test('only a Windows host without the installed service is portable', () {
    expect(nikoPortableWindows(_peer(kPeerPlatformWindows, installed: false)),
        isTrue);
    expect(nikoPortableWindows(_peer(kPeerPlatformWindows)), isTrue);
    expect(nikoPortableWindows(_peer(kPeerPlatformWindows, installed: true)),
        isFalse);
    expect(nikoPortableWindows(_peer(kPeerPlatformMacOS, installed: false)),
        isFalse);
  });

  test('the session toggle is named as the core reads it', () {
    // src/client.rs get_toggle_option knows only this name; the user
    // default's kOptionLockAfterSessionEnd reads as off.
    expect(nikoLockAfterSessionToggle, 'lock-after-session-end');
    expect(nikoLockAfterSessionToggle, isNot(kOptionLockAfterSessionEnd));
  });
}
