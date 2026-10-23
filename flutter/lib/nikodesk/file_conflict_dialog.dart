import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/common.dart' show CustomAlertDialog;

import 'alert_dialog.dart';
import 'nightline.dart';
import 'ui.dart';

// OverlayDialogManager accepts CustomAlertDialog. Override its build so Enter
// follows the focused decision and never implicitly selects overwrite.
class NikoFileConflictDialog extends CustomAlertDialog {
  final String path;
  final bool identical;
  final bool showRemember;
  final bool remember;
  final ValueChanged<bool> onRemember;
  final ValueChanged<bool?> onDecision;
  const NikoFileConflictDialog(
      {super.key,
      required this.path,
      required this.identical,
      required this.showRemember,
      required this.remember,
      required this.onRemember,
      required this.onDecision})
      : super(content: const SizedBox.shrink());

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.escape): () =>
                onDecision(false)
          },
          child: FocusScope(
              autofocus: true,
              child: NlColors.maybeOf(context) == null
                  ? _material(context)
                  : _nightline(context, NlColors.of(context))));

  String get _title =>
      nikoText('目标已存在同名文件', 'A file with this name already exists');

  String get _explanation => nikoText('覆盖会替换目标文件；跳过保留目标；取消会停止本批传输请求。',
      'Overwrite replaces the destination. Skip keeps it. Cancel stops this batch of transfer requests.');

  String get _identicalNote => nikoText('对端报告内容相同，你仍可以选择跳过。',
      'The peer reports identical content. You can skip this file.');

  String get _rememberLabel => nikoText('对本批后续冲突使用相同选择',
      'Use this choice for the remaining conflicts in this batch');

  /// Nightline: the question and its consequences beside a warning tile,
  /// the destination path in a mono well, and the decisions right to left
  /// from the one that keeps the most: Cancel batch (focused, so Enter never
  /// overwrites), Skip, then Overwrite in the danger fill.
  Widget _nightline(BuildContext context, NlColors nl) {
    // A zero-width space after each separator lets the path wrap at a folder.
    final wrappable =
        path.replaceAllMapped(RegExp(r'[\\/]'), (match) => '${match[0]}\u200b');
    return NikoAlertDialog(
        constraints: const BoxConstraints(maxWidth: 420),
        content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                NlIconTile(icon: NlIcons.files, color: nl.warn, size: 40),
                const SizedBox(width: NlSpace.s4),
                Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Semantics(
                              header: true,
                              child: Text(_title,
                                  style: NlType.text(NlType.s5,
                                      weight: FontWeight.w600, color: nl.fg)))),
                      const SizedBox(height: NlSpace.s2),
                      NikoDialogText(_explanation),
                    ])),
              ]),
              const SizedBox(height: NlSpace.s4),
              Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: NlSpace.s3, vertical: NlSpace.s2),
                  decoration: BoxDecoration(
                      color: nl.surface2,
                      borderRadius: BorderRadius.circular(NlRadius.r2),
                      border: Border.all(color: nl.line)),
                  child: SelectableText(wrappable,
                      style: NlType.monoText(NlType.s2, color: nl.fg2))),
              if (identical) ...[
                const SizedBox(height: NlSpace.s3),
                Row(children: [
                  NlLed(NlLedState.ok),
                  const SizedBox(width: NlSpace.s2),
                  Expanded(
                      child: Text(_identicalNote,
                          style: NlType.text(NlType.s2, color: nl.fg2))),
                ]),
              ],
              if (showRemember) ...[
                const SizedBox(height: NlSpace.s2),
                NlCheckbox(
                    boxKey: const Key('niko-file-conflict-remember'),
                    value: remember,
                    onChanged: onRemember,
                    label: _rememberLabel),
              ],
            ]),
        actions: [
          NikoDialogButton(
              label: nikoText('取消本批', 'Cancel batch'),
              primary: false,
              autofocus: true,
              onPressed: () => onDecision(false)),
          NikoDialogButton(
              label: nikoText('跳过', 'Skip'),
              primary: false,
              onPressed: () => onDecision(null)),
          NikoDialogButton(
              label: nikoText('覆盖', 'Overwrite'),
              primary: true,
              danger: true,
              onPressed: () => onDecision(true)),
        ]);
  }

  Widget _material(BuildContext context) => AlertDialog(
        scrollable: true,
        title:
            Text(nikoText('目标已存在同名文件', 'A file with this name already exists')),
        content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SelectableText(path),
                  const SizedBox(height: 12),
                  Text(nikoText('覆盖会替换目标文件；跳过保留目标；取消会停止本批传输请求。',
                      'Overwrite replaces the destination. Skip keeps it. Cancel stops this batch of transfer requests.')),
                  if (identical) ...[
                    const SizedBox(height: 12),
                    Text(nikoText('对端报告内容相同，你仍可以选择跳过。',
                        'The peer reports identical content. You can skip this file.')),
                  ],
                  if (showRemember)
                    CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        title: Text(nikoText('对本批后续冲突使用相同选择',
                            'Use this choice for the remaining conflicts in this batch')),
                        value: remember,
                        onChanged: (value) {
                          if (value != null) onRemember(value);
                        }),
                ])),
        actions: [
          TextButton(
              autofocus: true,
              onPressed: () => onDecision(false),
              child: Text(nikoText('取消本批', 'Cancel batch'))),
          TextButton(
              onPressed: () => onDecision(null),
              child: Text(nikoText('跳过', 'Skip'))),
          FilledButton(
              style: _overwriteStyle(context),
              onPressed: () => onDecision(true),
              child: Text(nikoText('覆盖', 'Overwrite'))),
        ],
      );

  /// Overwrite destroys the destination, so Nightline gives it the danger
  /// fill, with the same hover as other destructive buttons.
  static ButtonStyle? _overwriteStyle(BuildContext context) {
    final nl = NlColors.maybeOf(context);
    if (nl == null) return null;
    return ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.hovered)
                ? Color.lerp(nl.dangerFill, nl.fg, .08)
                : nl.dangerFill),
        foregroundColor: WidgetStatePropertyAll(nl.onDanger));
  }
}
