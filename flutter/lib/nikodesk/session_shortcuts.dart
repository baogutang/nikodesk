enum NikoSessionShortcut {
  copy,
  paste,
  cut,
  selectAll,
  undo,
  save,
  find,
  print,
  reload,
  switchApp,
  previousApp,
  previousDesktop,
  nextDesktop,
  taskOverview,
  appWindows,
}

const nikoMacShortcutOption = 'nikodesk-mac-shortcuts';

enum NikoMacShortcutMode { automatic, original }

class NikoShortcutKeys {
  final String key;
  final bool control;
  final bool command;
  final bool alt;
  final bool shift;
  final String commandLabel;
  const NikoShortcutKeys(this.key,
      {this.control = false,
      this.command = false,
      this.alt = false,
      this.shift = false,
      this.commandLabel = 'Cmd'});

  String get label =>
      '${control ? 'Ctrl+' : ''}${command ? '$commandLabel+' : ''}'
      '${alt ? 'Alt+' : ''}${shift ? 'Shift+' : ''}'
      '${key == 'VK_TAB' ? 'Tab' : key.substring(3)}';
}

NikoShortcutKeys? nikoShortcutKeys(
    NikoSessionShortcut shortcut, String peerPlatform) {
  if (!{'Windows', 'Mac OS', 'Linux'}.contains(peerPlatform)) return null;
  final mac = peerPlatform == 'Mac OS';
  if (shortcut == NikoSessionShortcut.switchApp ||
      shortcut == NikoSessionShortcut.previousApp) {
    return NikoShortcutKeys('VK_TAB',
        command: mac,
        alt: !mac,
        shift: shortcut == NikoSessionShortcut.previousApp);
  }
  if ({
    NikoSessionShortcut.previousDesktop,
    NikoSessionShortcut.nextDesktop,
    NikoSessionShortcut.taskOverview,
    NikoSessionShortcut.appWindows
  }.contains(shortcut)) {
    if (!mac && peerPlatform != 'Windows') return null;
    if (!mac && shortcut == NikoSessionShortcut.appWindows) return null;
    final key = switch (shortcut) {
      NikoSessionShortcut.previousDesktop => 'VK_LEFT',
      NikoSessionShortcut.nextDesktop => 'VK_RIGHT',
      NikoSessionShortcut.taskOverview => mac ? 'VK_UP' : 'VK_TAB',
      _ => 'VK_DOWN',
    };
    return NikoShortcutKeys(key,
        control: mac || shortcut != NikoSessionShortcut.taskOverview,
        command: !mac,
        commandLabel: mac ? 'Cmd' : 'Win');
  }
  final key = switch (shortcut) {
    NikoSessionShortcut.copy => 'VK_C',
    NikoSessionShortcut.paste => 'VK_V',
    NikoSessionShortcut.cut => 'VK_X',
    NikoSessionShortcut.selectAll => 'VK_A',
    NikoSessionShortcut.undo => 'VK_Z',
    NikoSessionShortcut.save => 'VK_S',
    NikoSessionShortcut.find => 'VK_F',
    NikoSessionShortcut.print => 'VK_P',
    NikoSessionShortcut.reload => 'VK_R',
    _ => throw StateError('Shortcut unavailable'),
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
