import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/common.dart' show CustomAlertDialog;

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
              child: AlertDialog(
                scrollable: true,
                title: Text(nikoText(
                    '目标已存在同名文件', 'A file with this name already exists')),
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
                                controlAffinity:
                                    ListTileControlAffinity.leading,
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
                      onPressed: () => onDecision(true),
                      child: Text(nikoText('覆盖', 'Overwrite'))),
                ],
              )));
}
