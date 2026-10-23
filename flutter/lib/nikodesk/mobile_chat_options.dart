import 'package:flutter/material.dart';

import 'nightline.dart';
import 'session_sheet.dart';
import 'ui.dart';

Future<void> showNikoMobileChatOptions(BuildContext context,
    {required VoidCallback onTextChat, VoidCallback? onVoiceCall}) async {
  final choice = await showNikoSessionSheet<String>(context,
      width: 420, builder: (_) => _ChatOptions(voice: onVoiceCall != null));
  if (!context.mounted) return;
  if (choice == 'text') onTextChat();
  if (choice == 'voice') onVoiceCall?.call();
}

/// The choice between text chat and the voice call, in the frame of the
/// other session panels: a sheet on a phone, a card on an iPad.
class _ChatOptions extends StatelessWidget {
  final bool voice;
  const _ChatOptions({required this.voice});

  Widget _option(BuildContext context,
      {Key? key,
      required IconData icon,
      required String title,
      String? subtitle,
      VoidCallback? onTap}) {
    final nl = NlColors.of(context);
    final enabled = onTap != null;
    return ListTile(
        key: key,
        enabled: enabled,
        minVerticalPadding: 12,
        contentPadding: const EdgeInsets.symmetric(horizontal: NlSpace.s3),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(NlRadius.r3)),
        tileColor: nl.surface2,
        leading: Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
                color: enabled ? nl.accentSoft : nl.surface,
                borderRadius: BorderRadius.circular(NlRadius.r2)),
            child:
                Icon(icon, size: 18, color: enabled ? nl.accentText : nl.fg3)),
        title: Text(title,
            style: NlType.text(NlType.s4,
                weight: FontWeight.w500, color: enabled ? nl.fg : nl.fg3)),
        subtitle: subtitle == null
            ? null
            : Text(subtitle, style: NlType.text(NlType.s2, color: nl.fg2)),
        trailing: enabled
            ? Icon(NlIcons.chevronRight, size: 16, color: nl.fg3)
            : null,
        onTap: onTap);
  }

  @override
  Widget build(BuildContext context) {
    final nl = NlColors.of(context);
    // The tiles paint their colour and ink on this, above the sheet's.
    return Material(
        type: MaterialType.transparency,
        child: SingleChildScrollView(
            child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
              Semantics(
                  header: true,
                  child: Text(nikoText('聊天与语音', 'Chat and voice'),
                      style: NlType.text(NlType.s5,
                          weight: FontWeight.w600, color: nl.fg))),
              const SizedBox(height: NlSpace.s4),
              _option(context,
                  key: const ValueKey('niko-mobile-text-chat'),
                  icon: NlIcons.messageSquare,
                  title: nikoText('文字聊天', 'Text chat'),
                  onTap: () => Navigator.pop(context, 'text')),
              const SizedBox(height: NlSpace.s2),
              if (voice)
                _option(context,
                    key: const ValueKey('niko-mobile-owned-voice'),
                    icon: NlIcons.phone,
                    title: nikoText('语音通话', 'Voice call'),
                    subtitle: nikoText('打开通话面板，查看当前可用状态。',
                        'Open the call panel to check current availability.'),
                    onTap: () => Navigator.pop(context, 'voice'))
              else
                Semantics(
                    key: const ValueKey('niko-mobile-voice-unavailable'),
                    button: true,
                    enabled: false,
                    child: _option(context,
                        icon: NlIcons.phoneOff,
                        title:
                            nikoText('语音通话（暂不可用）', 'Voice call (unavailable)'),
                        subtitle: nikoText('此版本暂不支持语音通话。文字聊天可正常使用。',
                            'Voice calls are not supported in this version. Text chat is available.'))),
              const SizedBox(height: NlSpace.s5),
              NlButton.ghost(
                  expand: true,
                  large: true,
                  label: nikoText('关闭', 'Close'),
                  onPressed: () => Navigator.pop(context)),
            ])));
  }
}
