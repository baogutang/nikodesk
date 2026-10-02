import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart' show connect;
import 'package:flutter_hbb/models/model.dart' show FFI;

import 'connect_dialog.dart';
import 'server_scope.dart';
import 'ui.dart';

Future<void> connectNikoSessionCapability(BuildContext context, String id, FFI ffi,
    {bool fileTransfer = false, bool viewCamera = false,
    bool tcpTunneling = false, bool terminal = false}) async {
  if (!context.mounted) return;
  final namespace = ffi.serverNamespace;
  final owner = ffi.sessionId;
  bool current() => !ffi.closed && ffi.sessionId == owner &&
      ffi.serverNamespace == namespace && NikoServerScope.validate(namespace) != null;
  if (!current()) {
    nikoNotice(context, nikoText('无法确认本会话所属私服，请重新连接。',
        'The session server identity is unavailable. Connect again.'));
    return;
  }
  final password = await nikoAskConnectPassword(context, id, '', fileTransfer: fileTransfer);
  if (password == null || password.trim().isEmpty || !context.mounted) return;
  if (!current()) {
    nikoNotice(context, nikoText('原会话已结束或私服已变化，请重新连接。',
        'The original session ended or its server changed. Connect again.'));
    return;
  }
  try {
    await connect(context, id, serverNamespace: namespace, password: password,
        isFileTransfer: fileTransfer, isViewCamera: viewCamera,
        isTerminal: terminal, isTcpTunneling: tcpTunneling);
  } catch (_) {
    if (context.mounted) {
      nikoNotice(context, nikoText('无法连接。请确认私服未变化且已启用此能力。',
          'Could not connect. Check the server identity and enable this capability.'));
    }
  }
}
