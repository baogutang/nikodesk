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

/// Physical pixels along the long edge of this controller's screen, or zero
/// when it cannot be read.
int nikoLocalLongEdge() {
  if (isDesktop) {
    // The same source the upstream "fit local" resolution action uses.
    try {
      final display = jsonDecode(bind.mainGetMainDisplay());
      final w = display['w'], h = display['h'];
      if (w is int && h is int && w > 0 && h > 0) return math.max(w, h);
    } catch (_) {}
  }
  try {
    final views = ui.PlatformDispatcher.instance.views;
    if (views.isEmpty) return 0;
    final view = views.first;
    final display = view.display.size;
    final size = display.isEmpty ? view.physicalSize : display;
    return math.max(size.width, size.height).round();
  } catch (_) {
    return 0;
  }
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
