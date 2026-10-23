import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart' show SessionID;
import 'package:flutter_hbb/models/model.dart' show FFI;
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/generated_bridge.dart';

import 'cm_voice_panel.dart';
import 'session_sheet.dart';
import 'ui.dart';
import 'voice_session_model.dart';
import 'voice_session_owner.dart';
import 'voice_session_view.dart';

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
  ffi.dialogManager.show<void>((_, close, context) => NikoSessionSheet(
      width: 560,
      onCancel: () { if (identical(owner.model, call)) call.send('deny'); close(); },
      child: NikoIncomingVoicePanel(owner: owner, call: call, onHide: close)),
      backDismiss: false, tag: 'nikodesk-incoming-voice-$nonce')
      .then<void>((_) {}, onError: (Object _, StackTrace __) {});
}

Future<void> showNikoVoiceSession(
    BuildContext context, NikoVoiceSessionOwner? owner) async {
  if (owner == null || !owner.active) {
    await showNikoSessionSheet<void>(context,
        width: 480,
        builder: (sheet) => NikoVoiceUnavailablePanel(
            message: owner != null
                ? nikoText(
                    '会话已关闭，请重新连接。', 'The session is closed. Connect again.')
                : nikoVoiceAvailabilityText(
                    NikoVoiceAvailability.contextUnsupported),
            onClose: () => Navigator.pop(sheet)));
    return;
  }
  // This reads metadata only. Discovery, permission and preparation require a
  // separate explicit action in the panel.
  owner.refreshAvailability();
  await showNikoSessionSheet<void>(context,
      width: 560,
      builder: (sheet) => NikoVoiceSessionPanel(
          owner: owner, onClose: () => Navigator.pop(sheet)));
}
