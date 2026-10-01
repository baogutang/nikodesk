import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart' show SessionID, CustomAlertDialog;
import 'package:flutter_hbb/models/model.dart' show FFI;
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/generated_bridge.dart';

import 'cm_voice_panel.dart';
import 'ui.dart';
import 'voice_call_panel.dart';
import 'voice_session_model.dart';
import 'voice_session_owner.dart';

class NativeNikoSessionVoiceTransport {
  final SessionID sessionId;
  final Rustdesk? bridge;
  const NativeNikoSessionVoiceTransport(this.sessionId, {this.bridge});
  Rustdesk get _api => bridge ?? bind;
  Future<String> prepare() => _api.sessionVoicePrepare(sessionId: sessionId);
  Future<String> availability() =>
      _api.sessionVoiceAvailability(sessionId: sessionId);
  Future<String> send(NikoVoiceCommand command) =>
      _api.sessionVoiceCommand(sessionId: sessionId, json: command.toJson());
}

class NativeNikoCmVoiceTransport {
  final Rustdesk? bridge;
  const NativeNikoCmVoiceTransport({this.bridge});
  Rustdesk get _api => bridge ?? bind;
  Future<String> send(NikoVoiceCommand command) =>
      Future<String>.sync(() => _api.cmVoiceCommand(json: command.toJson()));
  Future<String> availability(NikoVoiceStatus status) => _api
      .cmVoiceAvailability(jsonIdentity: jsonEncode(status.identity.toJson()));
}

void showNikoIncomingVoice(FFI ffi, NikoVoiceSessionOwner owner) {
  if (!owner.takeIncomingNotice()) return;
  final nonce = owner.model?.status.identity.requestNonce;
  if (nonce == null) return;
  final call = owner.model!;
  ffi.inputModel.enterOrLeave(false);
  ffi.dialogManager.show<void>((_, close, context) => CustomAlertDialog(
      onCancel: () { if (identical(owner.model, call)) call.send('deny'); close(); },
      title: Text(nikoText('远端语音来电', 'Incoming voice call')),
      contentBoxConstraints: const BoxConstraints(maxWidth: 560),
      content: SingleChildScrollView(child: AnimatedBuilder(animation: owner,
          builder: (context, _) => Column(mainAxisSize: MainAxisSize.min, children: [
            Text(nikoText('远端希望与你通话。设备权限与本次通话都需要你明确同意。',
                'The peer wants to talk. Device access and this call each require your approval.')),
            if (owner.active && identical(owner.model, call))
              NikoVoiceCallPanel(model: call)
            else Text(nikoText('本次来电已结束。', 'This incoming call has ended.')),
            TextButton(onPressed: close, child: Text(nikoText('收起面板', 'Hide panel'))),
          ])))), backDismiss: false, tag: 'nikodesk-incoming-voice-$nonce')
      .then<void>((_) {}, onError: (Object _, StackTrace __) {});
}

Future<void> showNikoVoiceSession(
    BuildContext context, NikoVoiceSessionOwner? owner) async {
  if (owner == null || !owner.active) {
    await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
                scrollable: true,
                title: Text(nikoText('语音通话', 'Voice call')),
                content: Text(owner != null
                    ? nikoText(
                        '会话已关闭，请重新连接。', 'The session is closed. Connect again.')
                    : nikoVoiceAvailabilityText(
                        NikoVoiceAvailability.contextUnsupported)),
                actions: [
                  TextButton(
                      style:
                          TextButton.styleFrom(minimumSize: const Size(48, 48)),
                      onPressed: () => Navigator.pop(context),
                      child: Text(nikoText('关闭', 'Close')))
                ]));
    return;
  }
  // This reads metadata only. Discovery, permission and preparation require a
  // separate explicit action in the panel.
  owner.refreshAvailability();
  await showDialog<void>(
      context: context,
      builder: (context) => Dialog(
          child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: SingleChildScrollView(
                  child: AnimatedBuilder(
                      animation: owner,
                      builder: (context, _) => Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                if (!owner.active)
                                  Text(nikoText('会话已关闭，请重新连接。',
                                      'The session is closed. Connect again.')),
                                if (owner.active)
                                  NikoVoiceCallPanel(
                                      model: owner.model,
                                      preparation: owner.preparation),
                                if (owner.reason?.isNotEmpty == true)
                                  Text(nikoVoiceReasonText(owner.reason!)),
                                OutlinedButton(
                                    style: OutlinedButton.styleFrom(
                                        minimumSize: const Size(48, 48)),
                                    onPressed: owner.active && !owner.reading
                                        ? owner.refreshAvailability
                                        : null,
                                    child: Text(nikoText('检查语音可用性',
                                        'Check voice availability'))),
                                TextButton(
                                    style: TextButton.styleFrom(
                                        minimumSize: const Size(48, 48)),
                                    onPressed: () => Navigator.pop(context),
                                    child:
                                        Text(nikoText('关闭面板', 'Close panel')))
                              ])))))));
}
