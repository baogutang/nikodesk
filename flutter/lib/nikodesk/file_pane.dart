import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart' show getPlatformImage;
import 'package:flutter_hbb/common/formatter/id_formatter.dart';
import 'package:flutter_hbb/consts.dart' show StringExtension;
import 'package:flutter_hbb/models/file_model.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:get/get.dart';

import 'nightline.dart';
import 'ui.dart';

/// Nightline pieces for the hosted upstream file pane (FileManagerView). The
/// pane hands over to these in the NikoDesk build only; other builds keep
/// the upstream header, send button, toolbar buttons and rows.

/// Which side the pane shows, the peer id on the remote side, and the
/// platform it runs.
class NikoFilePaneHeader extends StatelessWidget {
  final bool local;
  final String? peerId;
  final Future<String> platform;
  const NikoFilePaneHeader(
      {super.key, required this.local, required this.platform, this.peerId});

  @override
  Widget build(BuildContext context) {
    final nl = NlColors.of(context);
    return Padding(
        padding: const EdgeInsets.only(bottom: NlSpace.s3),
        child: FutureBuilder<String>(
            future: platform,
            builder: (context, snapshot) {
              final name = snapshot.data ?? '';
              return Row(children: [
                Container(
                    width: 36,
                    height: 36,
                    padding: const EdgeInsets.all(NlSpace.s2),
                    decoration: BoxDecoration(
                        color: nl.surface2,
                        borderRadius: BorderRadius.circular(NlRadius.r2),
                        border: Border.all(color: nl.line)),
                    child: name.isEmpty
                        ? null
                        : ExcludeSemantics(
                            child: ColorFiltered(
                                colorFilter:
                                    ColorFilter.mode(nl.fg2, BlendMode.srcIn),
                                child: getPlatformImage(name, size: 20)))),
                const SizedBox(width: NlSpace.s3),
                Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      Row(children: [
                        Flexible(
                            child: Text(
                                local
                                    ? nikoText('本机', 'This device')
                                    : nikoText('远端', 'Remote'),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: NlType.text(NlType.s4,
                                    weight: FontWeight.w600, color: nl.fg))),
                        if (peerId != null && peerId!.isNotEmpty) ...[
                          const SizedBox(width: NlSpace.s2),
                          Text(formatID(peerId!),
                              style: NlType.monoText(NlType.s3,
                                  weight: FontWeight.w500, color: nl.fg2)),
                        ],
                      ]),
                      Text(nikoPlatformName(name),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: NlType.text(NlType.s2, color: nl.fg3)),
                    ])),
              ]);
            }));
  }
}

/// The pane's one primary action: send the selection to the other side.
class NikoFileSendButton extends StatelessWidget {
  final FileController controller;
  const NikoFileSendButton({super.key, required this.controller});

  @override
  Widget build(BuildContext context) => Obx(() {
        final selection = controller.selectedItems;
        final local = controller.isLocal;
        return NlButton(
            key: Key('niko-file-send-${local ? 'local' : 'remote'}'),
            onPressed: SelectedItems.valid(selection.items)
                ? () {
                    controller.sendFiles(
                        selection, controller.getOtherSideDirectoryData());
                    selection.clear();
                  }
                : null,
            icon: local ? NlIcons.arrowRight : NlIcons.arrowLeft,
            label: local ? nikoText('发送', 'Send') : nikoText('接收', 'Receive'));
      });
}

/// Accent for the checkboxes and switches of upstream popup menus, which
/// otherwise take the fixed upstream blue. Null outside Nightline.
Color? nikoMenuAccent(BuildContext context) =>
    const bool.fromEnvironment('NIKODESK')
        ? NlColors.maybeOf(context)?.accent
        : null;

/// Row colours for the hosted directory list. Null outside the NikoDesk
/// build or a Nightline theme, where the upstream colours stay.
class NikoFileListColors {
  final Color selected;
  final Color ring;
  final Color selectedText;
  final Color meta;
  const NikoFileListColors._(
      {required this.selected,
      required this.ring,
      required this.selectedText,
      required this.meta});

  static NikoFileListColors? of(BuildContext context) {
    final nl = NlColors.maybeOf(context);
    if (!const bool.fromEnvironment('NIKODESK') || nl == null) return null;
    return NikoFileListColors._(
        selected: nl.solid(nl.accentSoft),
        ring: nl.accent,
        selectedText: nl.fg,
        meta: nl.fg2);
  }
}

/// The platform under the pane title, in the vendor's spelling; the session
/// reports macOS as "Mac OS".
String nikoPlatformName(String platform) =>
    platform == 'Mac OS' ? 'macOS' : platform;

/// The pane's toolbar button (upstream MenuButton) as a quiet icon button
/// that draws the Lucide match of the upstream glyph. Null outside the
/// NikoDesk build or a Nightline theme, where the upstream button stays.
Widget? nikoMenuButton(BuildContext context,
    {required Widget child,
    required VoidCallback? onPressed,
    required String? tooltip,
    required EdgeInsetsGeometry padding}) {
  if (!const bool.fromEnvironment('NIKODESK')) return null;
  final nl = NlColors.maybeOf(context);
  if (nl == null) return null;
  final icon = _nikoToolIcon(child);
  final label = tooltip ?? '';
  return Padding(
      padding: padding,
      child: icon != null
          ? NlIconButton(icon: icon, tooltip: label, onPressed: onPressed)
          : Tooltip(
              message: label,
              excludeFromSemantics: true,
              child: NlPressable(
                  onTap: onPressed,
                  semanticLabel: label,
                  pressScale: .94,
                  builder: (context, states) {
                    final side = NlIconButton.sizeOf(context);
                    return Container(
                        width: side,
                        height: side,
                        padding: const EdgeInsets.all(NlSpace.s1),
                        decoration: BoxDecoration(
                            color: states.contains(WidgetState.hovered)
                                ? nl.hover
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(NlRadius.r2),
                            boxShadow: states.contains(WidgetState.focused)
                                ? nl.focusRing
                                : null),
                        child: Opacity(
                            opacity: onPressed == null ? .4 : 1,
                            child: FittedBox(child: child)));
                  })));
}

/// The glyph before the pane's path or search field, which upstream draws
/// as a filled asset. Null outside the NikoDesk build or a Nightline theme.
Widget? nikoPathFieldIcon(BuildContext context, {required bool search}) {
  if (!const bool.fromEnvironment('NIKODESK')) return null;
  final nl = NlColors.maybeOf(context);
  if (nl == null) return null;
  return Padding(
      padding: const EdgeInsets.symmetric(horizontal: NlSpace.s2),
      child: Icon(search ? NlIcons.search : NlIcons.folderOpen,
          size: 16, color: nl.fg3));
}

/// The upstream toolbar draws asset glyphs, the arrow turned for back and
/// up; each has a Lucide counterpart.
IconData? _nikoToolIcon(Widget child) {
  var turns = 0;
  var glyph = child;
  if (glyph is RotatedBox && glyph.child != null) {
    turns = glyph.quarterTurns % 4;
    glyph = glyph.child!;
  }
  if (glyph is! SvgPicture) return null;
  final loader = glyph.bytesLoader;
  if (loader is! SvgAssetLoader) return null;
  return switch ((loader.assetName, turns)) {
    ('assets/arrow.svg', 2) => NlIcons.arrowLeft,
    ('assets/arrow.svg', 3) => NlIcons.cornerLeftUp,
    ('assets/search.svg', 0) => NlIcons.search,
    ('assets/close.svg', 0) => NlIcons.close,
    ('assets/refresh.svg', 0) => NlIcons.refreshCw,
    ('assets/home.svg', 0) => NlIcons.house,
    ('assets/folder_new.svg', 0) => NlIcons.folderPlus,
    ('assets/trash.svg', 0) => NlIcons.trash2,
    ('assets/dots.svg', 0) => NlIcons.ellipsis,
    _ => null,
  };
}

/// One directory entry in Nightline, laid out on the upstream columns: a
/// Lucide glyph and the name, the modified time and the size. Rows have no
/// fill until hovered or selected, and an accent ring while their context
/// menu is open. The upstream pane keeps selection, double-click and the
/// menu; this row only reports the gestures.
class NikoFileRow extends StatefulWidget {
  final Entry entry;
  final bool selected;
  final bool menuOpen;
  final double height;
  final double nameWidth;
  final double modifiedWidth;
  final String modified;
  final String size;
  final VoidCallback onTap;
  final VoidCallback onSecondaryTap;
  final GestureTapDownCallback onSecondaryTapDown;
  const NikoFileRow(
      {super.key,
      required this.entry,
      required this.selected,
      required this.menuOpen,
      required this.height,
      required this.nameWidth,
      required this.modifiedWidth,
      required this.modified,
      required this.size,
      required this.onTap,
      required this.onSecondaryTap,
      required this.onSecondaryTapDown});

  /// Matches the header's column dividers: one pixel with a pixel either
  /// side.
  static const gap = 3.0;

  @override
  State<NikoFileRow> createState() => _NikoFileRowState();
}

class _NikoFileRowState extends State<NikoFileRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final nl = NlColors.of(context);
    final colors = NikoFileListColors.of(context);
    final entry = widget.entry;
    final (IconData glyph, Color ink) = entry.isDrive
        ? (NlIcons.hardDrive, nl.fg2)
        : entry.isFile
            ? (NlIcons.file, nl.fg3)
            : (NlIcons.folder, nl.accent);
    final meta = NlType.text(NlType.s2, color: colors?.meta ?? nl.fg2);
    Widget cell(String text) => Padding(
        padding: const EdgeInsets.only(left: NlSpace.s1),
        child: Text(text,
            maxLines: 1, overflow: TextOverflow.ellipsis, style: meta));
    return Semantics(
        selected: widget.selected,
        child: MouseRegion(
            onEnter: (_) => setState(() => _hovered = true),
            onExit: (_) => setState(() => _hovered = false),
            child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: widget.onTap,
                onSecondaryTap: widget.onSecondaryTap,
                onSecondaryTapDown: widget.onSecondaryTapDown,
                child: Container(
                    height: widget.height,
                    margin: const EdgeInsets.symmetric(vertical: 1),
                    decoration: BoxDecoration(
                        color: widget.selected
                            ? colors?.selected ?? nl.selected
                            : _hovered
                                ? nl.hover
                                : Colors.transparent,
                        borderRadius: BorderRadius.circular(NlRadius.r2)),
                    foregroundDecoration: widget.menuOpen
                        ? BoxDecoration(
                            borderRadius: BorderRadius.circular(NlRadius.r2),
                            border: Border.all(color: colors?.ring ?? nl.accent))
                        : null,
                    child: Row(children: [
                      SizedBox(
                          width: widget.nameWidth,
                          child: Tooltip(
                              waitDuration: const Duration(milliseconds: 500),
                              message: entry.name,
                              child: Row(children: [
                                Padding(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: NlSpace.s2),
                                    child: Icon(glyph, size: 16, color: ink)),
                                Expanded(
                                    // Cut the name, not a word, at the end.
                                    child: Text(entry.name.nonBreaking,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: NlType.text(NlType.s3,
                                            color: colors?.selectedText ??
                                                nl.fg))),
                              ]))),
                      const SizedBox(width: NikoFileRow.gap),
                      SizedBox(
                          width: widget.modifiedWidth,
                          child: cell(widget.modified.trimRight())),
                      const SizedBox(width: NikoFileRow.gap),
                      Expanded(child: cell(widget.size)),
                    ])))));
  }
}
