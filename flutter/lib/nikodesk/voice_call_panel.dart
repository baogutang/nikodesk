import 'package:flutter/material.dart';

import 'cm_voice_panel.dart';
import 'ui.dart';
import 'voice_session_model.dart';

class NikoVoiceCallPanel extends StatelessWidget {
  final NikoVoiceSessionModel? model;
  final NikoVoicePreparation? preparation;
  const NikoVoiceCallPanel({super.key, this.model, this.preparation});

  @override
  Widget build(BuildContext context) {
    final session = model;
    if (session != null) {
      return AnimatedBuilder(
          animation: session,
          builder: (context, _) {
            final panel = NikoCmVoicePanel(model: session, controller: true);
            if (session.status.phase != 'Stopped' ||
                session.cleanupUnconfirmed ||
                session.cleanupOnly ||
                preparation == null) {
              return panel;
            }
            // The owner supplies a fresh preparation after native shutdown ACK.
            // This view never resets or reuses the previous preparation context.
            return Column(
                mainAxisSize: MainAxisSize.min,
                children: [panel, _preparePanel(preparation!)]);
          });
    }
    final preparing = preparation;
    if (preparing == null) {
      return Padding(
          padding: const EdgeInsets.all(12),
          child:
              Text(nikoVoiceAvailabilityText(NikoVoiceAvailability.unknown)));
    }
    return _preparePanel(preparing);
  }

  Widget _preparePanel(NikoVoicePreparation preparing) => AnimatedBuilder(
      animation: preparing,
      builder: (context, _) {
        final explanation = nikoVoiceAvailabilityText(preparing.availability);
        final phase = switch (preparing.phase) {
          'preparing' => nikoText('正在准备本机通话，尚未开始使用音频。',
              'Preparing this computer’s call. Audio use has not started.'),
          'pending' => nikoText('准备请求已发送，等待本机会话确认。',
              'Preparation request sent. Waiting for local session confirmation.'),
          'unconfirmed' => nikoText('准备结果未确认，暂不能重新呼叫。请关闭并重新打开远控会话。',
              'Preparation is unconfirmed. A new call is blocked. Close and reopen the control session.'),
          'unsupported' =>
            nikoVoiceAvailabilityText(NikoVoiceAvailability.backendUnsupported),
          'policy_rejected' => nikoText('通话请求未被允许。开启相应设备的语音请求后，请点击“检查语音可用性”。',
              'The call request was not allowed. Enable voice requests on the relevant device, then choose “Check voice availability”.'),
          _ => nikoText('通话尚未准备。请明确选择本机设备并允许麦克风访问。',
              'The call is not prepared. Local devices and microphone permission require your choice.')
        };
        return Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Semantics(
                      header: true,
                      child: Text(nikoText('语音通话', 'Voice call'),
                          style: Theme.of(context).textTheme.titleMedium)),
                  const SizedBox(height: 8),
                  Semantics(liveRegion: true, child: Text(phase)),
                  if (explanation.isNotEmpty) Text(explanation),
                  const SizedBox(height: 12),
                  FilledButton(
                      key: const ValueKey('niko-voice-prepare'),
                      style: FilledButton.styleFrom(
                          minimumSize: const Size(48, 48)),
                      onPressed: preparing.mayPrepare ? preparing.start : null,
                      child: Text(nikoText('准备通话', 'Prepare call')))
                ]));
      });
}
