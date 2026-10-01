import 'package:flutter/material.dart';

import 'ui.dart';

Future<void> showNikoMobileChatOptions(BuildContext context,
    {required VoidCallback onTextChat, VoidCallback? onVoiceCall}) async {
  final choice = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
          child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Text(nikoText('聊天与语音', 'Chat and voice'),
                    style: Theme.of(sheetContext).textTheme.titleLarge),
                const SizedBox(height: 12),
                ListTile(
                    key: const ValueKey('niko-mobile-text-chat'),
                    minVerticalPadding: 12,
                    leading: const Icon(Icons.message_outlined),
                    title: Text(nikoText('文字聊天', 'Text chat')),
                    onTap: () => Navigator.pop(sheetContext, 'text')),
                const Divider(),
                if (onVoiceCall != null)
                  ListTile(
                      key: const ValueKey('niko-mobile-owned-voice'),
                      minVerticalPadding: 12,
                      leading: const Icon(Icons.call_outlined),
                      title: Text(nikoText('语音通话', 'Voice call')),
                      subtitle: Text(nikoText('打开通话面板，查看当前可用状态。',
                          'Open the call panel to check current availability.')),
                      onTap: () => Navigator.pop(sheetContext, 'voice')),
                if (onVoiceCall == null)
                  Semantics(
                      key: const ValueKey('niko-mobile-voice-unavailable'),
                      button: true,
                      enabled: false,
                      child: ListTile(
                          enabled: false,
                          minVerticalPadding: 12,
                          leading: const Icon(Icons.phone_disabled_outlined),
                          title: Text(nikoText(
                              '语音通话（暂不可用）', 'Voice call (unavailable)')),
                          subtitle: Text(nikoText('此版本暂不支持语音通话。文字聊天可正常使用。',
                              'Voice calls are not supported in this version. Text chat is available.')))),
                const SizedBox(height: 12),
                TextButton(
                    style:
                        TextButton.styleFrom(minimumSize: const Size(48, 48)),
                    onPressed: () => Navigator.pop(sheetContext),
                    child: Text(nikoText('关闭', 'Close'))),
              ]))));
  if (!context.mounted) return;
  if (choice == 'text') onTextChat();
  if (choice == 'voice') onVoiceCall?.call();
}
