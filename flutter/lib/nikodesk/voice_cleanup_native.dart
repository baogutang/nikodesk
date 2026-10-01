import 'package:flutter_hbb/generated_bridge.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:uuid/uuid.dart';

import 'voice_cleanup_model.dart';

class NativeNikoVoiceCleanupTransport {
  final Rustdesk? bridge;
  const NativeNikoVoiceCleanupTransport({this.bridge});
  Rustdesk get _api => bridge ?? bind;
  Future<String> read() => _api.voicePendingCleanup();
  Future<String> send(String sessionId, String json) =>
      _api.sessionVoiceCommand(sessionId: UuidValue(sessionId), json: json);
  NikoVoiceCleanupModel createModel() =>
      NikoVoiceCleanupModel(readPending: read, command: send);
}
