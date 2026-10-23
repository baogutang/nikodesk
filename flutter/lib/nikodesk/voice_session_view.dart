import 'package:flutter/material.dart';

import 'cm_voice_panel.dart' show nikoVoiceReasonText;
import 'nightline.dart';
import 'session_tools_view.dart' show NikoToolFrame;
import 'settings_kit.dart' show NikoSettingNote;
import 'ui.dart';
import 'voice_call_panel.dart';
import 'voice_session_model.dart' show NikoVoiceSessionModel;
import 'voice_session_owner.dart';

String get _status => nikoText('通话状态', 'Call status');

String get _approval => nikoText(
    '设备权限与每次通话都需要你明确同意。', 'Device access and each call require your approval.');

/// The voice call of a session, in the frame of its other panels. Opening
/// it reads availability only; preparing and calling stay explicit actions
/// in the call panel.
class NikoVoiceSessionPanel extends StatelessWidget {
  final NikoVoiceSessionOwner owner;
  final VoidCallback onClose;
  const NikoVoiceSessionPanel(
      {super.key, required this.owner, required this.onClose});

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
      animation: owner,
      builder: (context, _) {
        final active = owner.active, reason = owner.reason;
        return NikoToolFrame(
            title: nikoText('语音通话', 'Voice call'),
            detail: _approval,
            body: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (active)
                    NikoVoiceCallPanel(
                        model: owner.model,
                        preparation: owner.preparation,
                        label: _status)
                  else
                    NikoSettingNote(
                        nikoText('会话已关闭，请重新连接。',
                            'The session is closed. Connect again.'),
                        tone: NlTone.warn),
                  if (reason?.isNotEmpty == true) ...[
                    const SizedBox(height: NlSpace.s3),
                    Semantics(
                        liveRegion: true,
                        child: NikoSettingNote(nikoVoiceReasonText(reason!),
                            tone: NlTone.warn)),
                  ],
                ]),
            footer: [
              const SizedBox(height: NlSpace.s5),
              Wrap(
                  alignment: WrapAlignment.end,
                  spacing: NlSpace.s2,
                  runSpacing: NlSpace.s2,
                  children: [
                    NlButton.ghost(
                        key: const Key('niko-voice-refresh'),
                        icon: NlIcons.refreshCw,
                        label: nikoText('检查语音可用性', 'Check voice availability'),
                        loading: owner.reading,
                        onPressed: active && !owner.reading
                            ? owner.refreshAvailability
                            : null),
                    NlButton.ghost(
                        key: const Key('niko-voice-close'),
                        label: nikoText('关闭面板', 'Close panel'),
                        onPressed: onClose),
                  ]),
            ]);
      });
}

/// A call the peer started, until this side answers it in the call panel
/// or hides the panel.
class NikoIncomingVoicePanel extends StatelessWidget {
  final NikoVoiceSessionOwner owner;
  final NikoVoiceSessionModel call;
  final VoidCallback onHide;
  const NikoIncomingVoicePanel(
      {super.key,
      required this.owner,
      required this.call,
      required this.onHide});

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
      animation: owner,
      builder: (context, _) => NikoToolFrame(
              title: nikoText('远端语音来电', 'Incoming voice call'),
              detail: nikoText('远端希望与你通话。设备权限与本次通话都需要你明确同意。',
                  'The peer wants to talk. Device access and this call each require your approval.'),
              body: owner.active && identical(owner.model, call)
                  ? NikoVoiceCallPanel(model: call, label: _status)
                  : NikoSettingNote(
                      nikoText('本次来电已结束。', 'This incoming call has ended.')),
              footer: [
                const SizedBox(height: NlSpace.s5),
                Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: NlButton.ghost(
                        key: const Key('niko-voice-hide'),
                        label: nikoText('收起面板', 'Hide panel'),
                        onPressed: onHide)),
              ]));
}

/// Why the voice call cannot open: the session is gone, or this kind of
/// session has no call.
class NikoVoiceUnavailablePanel extends StatelessWidget {
  final String message;
  final VoidCallback onClose;
  const NikoVoiceUnavailablePanel(
      {super.key, required this.message, required this.onClose});

  @override
  Widget build(BuildContext context) => NikoToolFrame(
          title: nikoText('语音通话', 'Voice call'),
          detail: message,
          footer: [
            const SizedBox(height: NlSpace.s5),
            Align(
                alignment: AlignmentDirectional.centerEnd,
                child: NlButton.ghost(
                    key: const Key('niko-voice-close'),
                    label: nikoText('关闭', 'Close'),
                    onPressed: onClose)),
          ]);
}
