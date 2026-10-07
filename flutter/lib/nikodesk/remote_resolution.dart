import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_hbb/common.dart' show SessionID;
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/generated_bridge.dart'
    if (dart.library.html) 'package:flutter_hbb/web/bridge.dart' show RustdeskImpl;

import 'connection_progress.dart';
import 'remote_resolution_policy.dart';
import 'policy.dart';

export 'remote_resolution_policy.dart';

/// Per-device opt-in, stored with the peer: fit the remote display mode to
/// this screen once the first frame of a session has arrived.
const nikoAutoFitResolutionOption = 'nikodesk-auto-fit-resolution';

/// Per-device option read by the native session and sent to the controlled
/// side: the widest picture, in pixels, it should capture.
const nikoCaptureWidthOption = 'nikodesk-capture-width';

/// Per-device choice of how much of the remote picture to capture.
const nikoCaptureModeOption = 'nikodesk-capture-mode';

// The exact FPS last written by the responsive preset. An independently
// changed FPS must not become an automatic refresh-rate preference.
const nikoAutomaticFpsOption = 'nikodesk-automatic-fps';
final _sessionViewports = <SessionID, NikoSessionViewport>{};

Future<NikoCaptureMode> nikoReadCaptureMode(SessionID session) async =>
    nikoCaptureModeFromName(await bind.sessionGetOption(
        sessionId: session, arg: nikoCaptureModeOption));

/// Tells the controlled side how wide a picture this controller wants. It is
/// called before login so the first frame already has that size, and again
/// when the user changes the choice.
Future<void> nikoDeclareCaptureWidth(SessionID session,
    {NikoCaptureMode? mode}) async {
  try {
    _sessionViewports[session]?.cancelPending();
    if (mode != null) {
      await bind.sessionPeerOption(
          sessionId: session,
          name: nikoCaptureModeOption,
          value: mode == NikoCaptureMode.fit ? '' : mode.name);
    }
    final chosen = mode ?? await nikoReadCaptureMode(session);
    final style = await bind.sessionGetViewStyle(sessionId: session);
    final width = nikoSessionCaptureWidth(chosen,
        _sessionViewports[session]?.longEdge ?? nikoLocalLongEdge(), style);
    await bind.sessionPeerOption(
        sessionId: session, name: nikoCaptureWidthOption, value: '$width');
  } catch (error) {
    debugPrint('NikoDesk capture width not declared: ${error.runtimeType}');
    if (mode != null) rethrow;
  }
}

/// This engine's current view only; never select another attached screen.
ui.FlutterView? nikoCurrentFlutterView() {
  final dispatcher = ui.PlatformDispatcher.instance;
  return dispatcher.implicitView ??
      (dispatcher.views.length == 1 ? dispatcher.views.single : null);
}

int nikoLocalLongEdge({ui.FlutterView? view, ui.Size? viewport}) {
  try {
    final current = view ?? nikoCurrentFlutterView();
    if (current == null) return 0;
    final dpr = current.devicePixelRatio;
    final size = viewport ?? current.physicalSize / dpr;
    return nikoViewportLongEdge(width: size.width, height: size.height,
        devicePixelRatio: dpr, screenWidth: current.display.size.width,
        screenHeight: current.display.size.height);
  } catch (_) {
    return 0;
  }
}

double? nikoViewRefreshRate([ui.FlutterView? view]) {
  try {
    final rate = (view ?? nikoCurrentFlutterView())?.display.refreshRate;
    return rate != null && rate.isFinite && rate > 0 ? rate : null;
  } catch (_) {
    return null;
  }
}

/// Owned by the desktop remote page, with one cancellable debounce timer.
/// No polling and no native display-mode changes are performed here.
class NikoSessionViewport {
  final FFI ffi;
  final SessionID session;
  final RustdeskImpl? _bindings;
  RustdeskImpl get _api => _bindings ?? bind;
  ui.FlutterView? _view;
  Timer? _timer;
  int _revision = 0;
  int _writeGeneration = 0;
  bool _disposed = false;

  NikoSessionViewport(this.ffi, {RustdeskImpl? bindings})
      : session = ffi.sessionId, _bindings = bindings {
    _sessionViewports[session]?.dispose();
    _sessionViewports[session] = this;
    ffi.canvasModel.addListener(schedule);
    ffi.nikoConnectionProgress.addListener(schedule);
  }

  int get longEdge {
    final size = ffi.canvasModel.size;
    return nikoLocalLongEdge(view: _view,
        viewport: size.width > 0 && size.height > 0 ? size : null);
  }

  void updateView(ui.FlutterView view) {
    _view = view;
    schedule();
  }

  void cancelPending({bool revokeWrites = false}) {
    ++_revision;
    if (revokeWrites) ++_writeGeneration;
    _timer?.cancel();
    _timer = null;
  }

  bool get _connected => !_disposed && !ffi.closed &&
      ffi.sessionId == session && ffi.connType == ConnType.defaultConn &&
      ffi.nikoConnectionProgress.value.phase == NikoConnectionPhase.connected;

  void schedule() {
    cancelPending();
    if (!_connected) {
      ++_writeGeneration;
      return;
    }
    if (_view == null) return;
    final revision = _revision;
    _timer = Timer(const Duration(milliseconds: 650), () => _update(revision));
  }

  Future<void> _update(int revision) async {
    bool current() => _connected && revision == _revision;
    try {
      if (!current() || _view == null || _view!.physicalSize.isEmpty) return;
      final edge = longEdge;
      if (edge <= 0) return;
      final mode = nikoCaptureModeFromName(await _api.sessionGetOption(
          sessionId: session, arg: nikoCaptureModeOption));
      final style = await _api.sessionGetViewStyle(sessionId: session);
      if (!current()) return;
      if (mode == NikoCaptureMode.fit) {
        final width = nikoSessionCaptureWidth(mode, edge, style);
        final previous = int.tryParse(await _api.sessionGetOption(
            sessionId: session, arg: nikoCaptureWidthOption) ?? '');
        if (!current()) return;
        if (nikoCaptureWidthNeedsUpdate(previous, width)) {
          await _api.sessionPeerOption(sessionId: session,
              name: nikoCaptureWidthOption, value: '$width');
        }
      }
      if (!current() || !PictureRequest.supportsCustomFps(ffi.ffiModel.pi.version)) return;
      final saved = await _api.sessionGetPeerOption(
          sessionId: session, name: 'nikodesk-picture-mode');
      final managed = int.tryParse(await _api.sessionGetPeerOption(
          sessionId: session, name: nikoAutomaticFpsOption));
      if (saved != PictureMode.smooth.name || managed == null || !current()) return;
      final fps = int.tryParse(await _api.sessionGetOption(
          sessionId: session, arg: 'custom-fps') ?? '');
      final quality = await _api.sessionGetImageQuality(sessionId: session);
      final percent = await _api.sessionGetCustomImageQuality(sessionId: session);
      final next = nikoAutomaticFpsUpdate(savedMode: saved, managed: managed,
          current: fps, quality: quality,
          percent: percent?.isNotEmpty == true ? percent!.first : null,
          refreshRate: nikoViewRefreshRate(_view));
      if (!current() || next == null) return;
      final generation = _writeGeneration;
      await _api.sessionSetCustomFps(sessionId: session, fps: next);
      // A resize invalidates the next sample, not the acknowledgement of our
      // successful write. Manual choices and disconnected sessions revoke both.
      if (!_connected || generation != _writeGeneration) return;
      await _api.sessionPeerOption(sessionId: session,
          name: nikoAutomaticFpsOption, value: '$next');
      if (_connected && generation == _writeGeneration && revision != _revision) schedule();
    } catch (error) {
      debugPrint('NikoDesk viewport update unconfirmed: ${error.runtimeType}');
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    cancelPending(revokeWrites: true);
    ffi.canvasModel.removeListener(schedule);
    ffi.nikoConnectionProgress.removeListener(schedule);
    if (identical(_sessionViewports[session], this)) _sessionViewports.remove(session);
  }
}

void nikoCancelViewportUpdate(SessionID session) =>
    _sessionViewports[session]?.cancelPending(revokeWrites: true);

Future<void> nikoStopAutomaticFps(SessionID session, {RustdeskImpl? bindings}) async {
  nikoCancelViewportUpdate(session);
  await (bindings ?? bind).sessionPeerOption(
      sessionId: session, name: nikoAutomaticFpsOption, value: '');
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
      localLongEdge: localLongEdge ??
          _sessionViewports[ffi.sessionId]?.longEdge ?? nikoLocalLongEdge());
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
  if (byHand) _choseByHand[ffi] = true;
  await bind.sessionChangeResolution(
      sessionId: session,
      display: ffi.ffiModel.pi.currentDisplay,
      width: mode.width,
      height: mode.height);
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
final _autoFitAttempt = Expando<Object>();

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
    _autoFitAttempt[ffi] = Object();
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
  final attempt = _autoFitAttempt[ffi];
  final displayIndex = ffi.ffiModel.pi.currentDisplay;
  bool current() =>
      identical(_autoFitAttempt[ffi], attempt) &&
      ffi.ffiModel.pi.currentDisplay == displayIndex &&
      _choseByHand[ffi] != true &&
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
    if (!await nikoReadAutoFitResolution(session) || !current()) return;
    // A mode remembered for this device is applied by the session itself at
    // login; let its confirmation arrive so it is seen as already changed.
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    final before = await settled((_) => true);
    if (before == null || !current()) return;
    final fit = before.fit;
    if (fit == null || before.changed) return;
    await nikoChangeRemoteResolution(ffi, session, fit, byHand: false);
    final after = await settled((state) => state.current != before.current);
    if (after == null || !current()) return;
    if (nikoAutoFitShouldRestore(before: before, after: after, requested: fit)) {
      debugPrint('NikoDesk auto fit undone: ${fit.label} was captured as '
          '${after.capturedPixels.label}');
      await nikoChangeRemoteResolution(ffi, session, before.current,
          byHand: false);
    }
  } catch (error) {
    // The session keeps its mode; the control center shows the actual state.
    debugPrint('NikoDesk auto fit skipped: ${error.runtimeType}');
  }
}
