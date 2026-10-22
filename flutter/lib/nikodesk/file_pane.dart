import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart' show getPlatformImage;
import 'package:flutter_hbb/common/formatter/id_formatter.dart';
import 'package:flutter_hbb/models/file_model.dart';
import 'package:get/get.dart';

import 'nightline.dart';
import 'ui.dart';

/// Nightline pieces for the hosted upstream file pane (FileManagerView). The
/// pane hands over to these in the NikoDesk build only; other builds keep
/// the upstream header, send button and row colours.

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
                      NlMonoLabel(name.isEmpty ? ' ' : name),
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
            icon: local
                ? Icons.arrow_forward_rounded
                : Icons.arrow_back_rounded,
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
