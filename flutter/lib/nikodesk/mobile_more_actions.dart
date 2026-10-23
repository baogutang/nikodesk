import 'package:flutter/widgets.dart';
import 'package:flutter_hbb/common.dart' show translate;
import 'package:flutter_hbb/common/widgets/toolbar.dart'
    show TTextMenu, handleOsPasswordEditIcon;
import 'package:flutter_hbb/models/model.dart';

import 'nightline.dart';
import 'theme.dart' show nikoSessionTheme;
import 'ui.dart';

/// Icons of the stock session actions, by their translation key.
const _icons = {
  'Back': NlIcons.arrowLeft,
  'Home': NlIcons.house,
  'Apps': NlIcons.layoutGrid,
  'Volume up': NlIcons.volume2,
  'Volume down': NlIcons.volume1,
  'Power': NlIcons.power,
  'Request Elevation': NlIcons.shieldAlert,
  'OS Password': NlIcons.keyRound,
  'Send clipboard keystrokes': NlIcons.clipboard,
  'Reset canvas': NlIcons.rotateCcw,
  'Note': NlIcons.squarePen,
  'Insert Ctrl + Alt + Del': NlIcons.keyboard,
  'Restart remote device': NlIcons.rotateCw,
  'Insert Lock': NlIcons.lock,
  'Switch Sides': NlIcons.arrowLeftRight,
  'Refresh': NlIcons.refreshCw,
  'Start session recording': NlIcons.circleDot,
  'Stop session recording': NlIcons.square,
  'Copy Fingerprint': NlIcons.fingerprint,
};

/// The label of a stock menu entry: its text, or the first text of a row
/// that also holds an icon; null for anything else.
String? nikoMenuLabel(Widget child) => switch (child) {
      Text(:final data, :final textSpan) => data ?? textSpan?.toPlainText(),
      Flex(:final children) => children.map(nikoMenuLabel).nonNulls.firstOrNull,
      SingleChildRenderObjectWidget(:final child?) => nikoMenuLabel(child),
      _ => null,
    };

/// The session's more-actions menu: the remote phone's keys under their
/// own header, then the stock session controls, each running its stock
/// handler. [onEditOsPassword] adds the edit the stock menu puts on the OS
/// password row. Null when an entry has no label to show, so the caller
/// can keep the stock menu.
List<NlMenuEntry>? nikoMoreActionEntries(
    {required List<TTextMenu> phone,
    required List<TTextMenu> controls,
    required String Function(String) translate,
    VoidCallback? onEditOsPassword}) {
  final icons = {
    for (final MapEntry(:key, :value) in _icons.entries) translate(key): value
  };
  final restart = translate('Restart remote device');
  final osPassword = translate('OS Password');
  List<NlMenuEntry>? items(List<TTextMenu> menus) {
    final out = <NlMenuEntry>[];
    for (final menu in menus) {
      if (menu.divider) {
        if (out.isNotEmpty && out.last is! NlMenuDivider) {
          out.add(const NlMenuDivider());
        }
        continue;
      }
      final label = nikoMenuLabel(menu.child);
      if (label == null || label.isEmpty) return null;
      out.add(NlMenuItem(
          label: label,
          icon: icons[label],
          danger: label == restart,
          enabled: menu.onPressed != null,
          onSelected: menu.onPressed));
      if (label == osPassword && onEditOsPassword != null) {
        out.add(NlMenuItem(
            label: nikoText('修改系统密码', 'Edit OS password'),
            icon: NlIcons.pencil,
            onSelected: onEditOsPassword));
      }
    }
    while (out.isNotEmpty && out.last is NlMenuDivider) {
      out.removeLast();
    }
    return out;
  }

  final keys = items(phone);
  final session = items(controls);
  if (keys == null || session == null) return null;
  return [
    if (keys.isNotEmpty) ...[
      NlMenuHeader(nikoText('远端手机', 'Remote phone')),
      ...keys,
      if (session.isNotEmpty) const NlMenuDivider(),
    ],
    ...session,
  ];
}

/// Opens the more-actions menu by the dock button behind [button]. Returns
/// false, showing nothing, when the stock menu should open instead.
bool showNikoMoreActions(BuildContext button, FFI ffi,
    {required List<TTextMenu> phone, required List<TTextMenu> controls}) {
  final entries = nikoMoreActionEntries(
      phone: phone,
      controls: controls,
      translate: translate,
      onEditOsPassword: () =>
          handleOsPasswordEditIcon(ffi.sessionId, ffi.dialogManager));
  if (entries == null || entries.isEmpty) return false;
  ffi.inputModel.enterOrLeave(false);
  showNikoDockMenu(button, entries);
  return true;
}

/// Opens [entries] as a menu over the dock button behind [button].
Future<void> showNikoDockMenu(BuildContext button, List<NlMenuEntry> entries) =>
    showNlMenu(button,
        anchor: _dockAnchor(button),
        entries: entries,
        width: NlLayout.touch(button) ? 264 : 240,
        theme: nikoSessionTheme(button));

/// The button's rectangle stretched to the height of the dock around it,
/// so the menu clears the dock instead of covering its edge.
Rect _dockAnchor(BuildContext button) {
  final rect = nlAnchorOf(button);
  RenderBox? dock;
  button.visitAncestorElements((element) {
    if (element.widget.key != const Key('nikodesk-mobile-control-dock')) {
      return true;
    }
    dock = element.renderObject as RenderBox?;
    return false;
  });
  final box = dock;
  if (box == null || !box.hasSize) return rect;
  final top = box.localToGlobal(Offset.zero).dy;
  return Rect.fromLTRB(rect.left, top, rect.right, top + box.size.height);
}
