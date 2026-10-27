import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/generated_bridge.dart'
    if (dart.library.html) 'package:flutter_hbb/web/bridge.dart' show RustdeskImpl;

import 'policy.dart';
import 'remote_resolution.dart' show nikoAutomaticFpsOption;

/// An iPad or iPhone controller starts a device it never chose a picture mode
/// for in the responsive mode, as the session panel would save it; any other
/// choice, here or in the default settings, is left alone.
Future<void> nikoApplyDefaultPicture(FFI ffi, double? refreshRate,
    {RustdeskImpl? bindings}) async {
  final api = bindings ?? bind;
  final session = ffi.sessionId;
  bool current() => !ffi.closed && ffi.sessionId == session;
  if (!PictureRequest.supportsCustomFps(ffi.ffiModel.pi.version)) return;
  final saved = await api.sessionGetPeerOption(
      sessionId: session, name: 'nikodesk-picture-mode');
  final quality = await api.sessionGetImageQuality(sessionId: session);
  if (!current() || !nikoPictureUnchosen(savedMode: saved, quality: quality)) {
    return;
  }
  final request = PictureRequest.forMode(PictureMode.smooth,
      smoothFps: nikoSmoothFps(refreshRate));
  await api.sessionSetImageQuality(
      sessionId: session, value: request.imageQuality);
  await api.sessionSetCustomImageQuality(
      sessionId: session, value: request.bitratePercent!);
  await api.sessionSetCustomFps(sessionId: session, fps: request.fps!);
  if (!current()) return;
  await api.sessionPeerOption(
      sessionId: session, name: nikoAutomaticFpsOption, value: '${request.fps}');
  await api.sessionPeerOption(sessionId: session,
      name: 'nikodesk-picture-mode', value: PictureMode.smooth.name);
}
