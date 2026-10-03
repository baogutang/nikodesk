enum NikoSessionShortcut { copy, paste, selectAll, undo, save, switchApp }

class NikoShortcutKeys {
  final String key;
  final bool control;
  final bool command;
  final bool alt;
  const NikoShortcutKeys(this.key,
      {this.control = false, this.command = false, this.alt = false});

  String get label =>
      '${command ? 'Cmd+' : control ? 'Ctrl+' : alt ? 'Alt+' : ''}'
      '${key == 'VK_TAB' ? 'Tab' : key.substring(3)}';
}

NikoShortcutKeys? nikoShortcutKeys(
    NikoSessionShortcut shortcut, String peerPlatform) {
  if (!{'Windows', 'Mac OS', 'Linux'}.contains(peerPlatform)) return null;
  final mac = peerPlatform == 'Mac OS';
  if (shortcut == NikoSessionShortcut.switchApp) {
    return NikoShortcutKeys('VK_TAB', command: mac, alt: !mac);
  }
  final key = switch (shortcut) {
    NikoSessionShortcut.copy => 'VK_C',
    NikoSessionShortcut.paste => 'VK_V',
    NikoSessionShortcut.selectAll => 'VK_A',
    NikoSessionShortcut.undo => 'VK_Z',
    NikoSessionShortcut.save => 'VK_S',
    NikoSessionShortcut.switchApp => 'VK_TAB',
  };
  return NikoShortcutKeys(key, control: !mac, command: mac);
}

abstract class NikoShortcutInput {
  void releaseCapture();
  void setModifiers(NikoShortcutKeys? keys);
  Future<void> inputKey(String key, {required bool press});
}

/// Uses the existing atomic key-press dispatch, then clears its key/modifiers.
/// Releasing capture first also releases physical keys held before the menu.
Future<void> sendNikoShortcut(NikoShortcutKeys keys, NikoShortcutInput input,
    {required bool Function() allowed}) async {
  if (!allowed()) throw StateError('Remote input unavailable');
  input.releaseCapture();
  if (!allowed()) throw StateError('Remote input unavailable');
  try {
    input.setModifiers(keys);
    await input.inputKey(keys.key, press: true);
    if (!allowed()) throw StateError('Remote input unavailable');
  } finally {
    input.setModifiers(null);
    await input.inputKey(keys.key, press: false);
  }
}
