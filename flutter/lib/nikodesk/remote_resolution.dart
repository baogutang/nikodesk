import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_hbb/common.dart' show SessionID, isDesktop;
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/platform_model.dart';

import 'connection_progress.dart';
import 'remote_resolution_policy.dart';

export 'remote_resolution_policy.dart';

/// Per-device opt-in, stored with the peer: fit the remote display mode to
/// this screen once the first frame of a session has arrived.
const nikoAutoFitResolutionOption = 'nikodesk-auto-fit-resolution';

/// Per-device option read by the native session and sent to the controlled
/// side: the widest picture, in pixels, it should capture.
const nikoCaptureWidthOption = 'nikodesk-capture-width';

/// Per-device choice of how much of the remote picture to capture.
const nikoCaptureModeOption = 'nikodesk-capture-mode';

Future<NikoCaptureMode> nikoReadCaptureMode(SessionID session) async =>
    nikoCaptureModeFromName(await bind.sessionGetOption(
        sessionId: session, arg: nikoCaptureModeOption));

/// Tells the controlled side how wide a picture this controller wants. It is
/// called before login so the first frame already has that size, and again
/// when the user changes the choice.
Future<void> nikoDeclareCaptureWidth(SessionID session,
    {NikoCaptureMode? mode}) async {
  try {
    if (mode != null) {
      await bind.sessionPeerOption(
          sessionId: session,
          name: nikoCaptureModeOption,
          value: mode == NikoCaptureMode.fit ? '' : mode.name);
    }
    final width = nikoCaptureWidth(
        mode ?? await nikoReadCaptureMode(session), nikoLocalLongEdge());
    await bind.sessionPeerOption(
        sessionId: session, name: nikoCaptureWidthOption, value: '$width');
  } catch (error) {
    debugPrint('NikoDesk capture width not declared: ${error.runtimeType}');
    if (mode != null) rethrow;
  }
}

/// Physical pixels along the longest edge of any screen of this controller,
/// or zero when none can be read. The window may be on any of them, and each
/// source can be missing or too small on some platform (a Mac that is itself
/// being controlled reports a reduced size through the native list), so the
/// largest value wins: asking for too much only costs pixels.
int nikoLocalLongEdge() {
  var edge = 0.0;
  void take(num? w, num? h) {
    if (w != null && h != null && w > 0 && h > 0) {
      edge = math.max(edge, math.max(w, h).toDouble());
    }
  }

  try {
    final dispatcher = ui.PlatformDispatcher.instance;
    for (final display in dispatcher.displays) {
      take(display.size.width, display.size.height);
    }
    for (final view in dispatcher.views) {
      take(view.display.size.width, view.display.size.height);
      take(view.physicalSize.width, view.physicalSize.height);
    }
  } catch (_) {}
  if (isDesktop) {
    // The source the upstream "fit local" resolution action uses.
    try {
      final main = jsonDecode(bind.mainGetMainDisplay());
      if (main is Map) take(main['w'] as num?, main['h'] as num?);
    } catch (_) {}
    try {
      final all = jsonDecode(bind.mainGetDisplays());
      if (all is List) {
        for (final display in all) {
          if (display is Map) take(display['w'] as num?, display['h'] as num?);
        }
      }
    } catch (_) {}
  }
  return edge.round();
}

bool _resolutionControlAllowed(FFI ffi) =>
    !ffi.closed &&
    ffi.connType == ConnType.defaultConn &&
    !ffi.ffiModel.viewOnly &&
    ffi.ffiModel.keyboard &&
    ffi.ffiModel.permissions['keyboard'] != false &&
    ffi.ffiModel.pi.currentDisplay != kAllDisplayValue &&
    !ffi.ffiModel.isVirtualDisplayResolution;

/// Null while the remote display, its original mode or its mode list is not
/// known, or when this session may not change the remote display.
NikoRemoteResolution? nikoRemoteResolution(FFI ffi, {int? localLongEdge}) {
  if (!_resolutionControlAllowed(ffi)) return null;
  final pi = ffi.ffiModel.pi;
  final display = pi.tryGetDisplayIfNotAllDisplay();
  if (display == null ||
      !display.isOriginalResolutionSet ||
      pi.resolutions.length < 2) {
    return null;
  }
  return nikoResolutionState(
      width: display.width,
      height: display.height,
      originalWidth: display.originalWidth,
      originalHeight: display.originalHeight,
      scale: display.scale,
      supported: pi.resolutions.map((r) => NikoDisplayMode(r.width, r.height)),
      localLongEdge: localLongEdge ?? nikoLocalLongEdge());
}

// Set once the user changes or restores the mode by hand; the automatic match
// then stays out of the way until the session is closed.
final _choseByHand = Expando<bool>();

Future<void> nikoChangeRemoteResolution(
    FFI ffi, SessionID session, NikoDisplayMode mode,
    {bool byHand = true}) async {
  if (ffi.sessionId != session || !_resolutionControlAllowed(ffi)) {
    throw StateError('Remote display unavailable');
  }
  await bind.sessionChangeResolution(
      sessionId: session,
      display: ffi.ffiModel.pi.currentDisplay,
      width: mode.width,
      height: mode.height);
  if (byHand) _choseByHand[ffi] = true;
}

Future<bool> nikoReadAutoFitResolution(SessionID session) async =>
    await bind.sessionGetOption(
        sessionId: session, arg: nikoAutoFitResolutionOption) ==
    'Y';

Future<void> nikoSetAutoFitResolution(SessionID session, bool enabled) async {
  await bind.sessionPeerOption(
      sessionId: session,
      name: nikoAutoFitResolutionOption,
      value: enabled ? 'Y' : '');
  if (await nikoReadAutoFitResolution(session) != enabled) {
    throw StateError('Auto fit unconfirmed');
  }
}

final _autoFitWatched = Expando<bool>();

/// Fits the remote mode each time a connection of [ffi] delivers its first
/// frame, for devices that opted in. The controlled side restores its mode
/// when the last controller leaves, so a reconnect fits again unless the user
/// has chosen a mode by hand in this session.
void nikoWatchAutoFitResolution(FFI ffi) {
  if (_autoFitWatched[ffi] == true) return;
  _autoFitWatched[ffi] = true;
  var last = ffi.nikoConnectionProgress.value.phase;
  ffi.nikoConnectionProgress.addListener(() {
    final phase = ffi.nikoConnectionProgress.value.phase;
    final entered = phase == NikoConnectionPhase.connected && last != phase;
    last = phase;
    if (phase == NikoConnectionPhase.closed) _choseByHand[ffi] = null;
    if (entered && ffi.connType == ConnType.defaultConn) {
      // The declaration made before login may have lost the race with it;
      // repeating the same width changes nothing on the controlled side.
      unawaited(nikoDeclareCaptureWidth(ffi.sessionId));
    }
    if (entered) unawaited(_autoFit(ffi));
  });
}

Future<void> _autoFit(FFI ffi) async {
  final session = ffi.sessionId;
  bool current() =>
      !ffi.closed &&
      ffi.sessionId == session &&
      ffi.nikoConnectionProgress.value.phase == NikoConnectionPhase.connected;
  Future<NikoRemoteResolution?> settled(
      bool Function(NikoRemoteResolution) done) async {
    for (var attempt = 0; attempt < 20 && current(); attempt++) {
      final state = nikoRemoteResolution(ffi);
      if (state != null && done(state)) return state;
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    return null;
  }

  try {
    if (ffi.connType != ConnType.defaultConn) return;
    if (!await nikoReadAutoFitResolution(session)) return;
    // A mode remembered for this device is applied by the session itself at
    // login; let its confirmation arrive so it is seen as already changed.
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    final before = await settled((_) => true);
    if (before == null || _choseByHand[ffi] == true) return;
    final fit = before.fit;
    if (fit == null || before.changed) return;
    await nikoChangeRemoteResolution(ffi, session, fit, byHand: false);
    final after = await settled(
        (state) => state.capturedPixels != before.capturedPixels);
    if (after == null || _choseByHand[ffi] == true) return;
    if (!nikoFitReducedPixels(
        before: before.capturedPixels,
        after: after.capturedPixels,
        localLongEdge: before.localLongEdge)) {
      debugPrint('NikoDesk auto fit undone: ${fit.label} was captured as '
          '${after.capturedPixels.label}');
      await nikoChangeRemoteResolution(ffi, session, before.original,
          byHand: false);
    }
  } catch (error) {
    // The session keeps its mode; the control center shows the actual state.
    debugPrint('NikoDesk auto fit skipped: ${error.runtimeType}');
  }
}
