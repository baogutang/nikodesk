import 'package:flutter/gestures.dart';

import '../common.dart';
import '../models/input_model.dart';

/// The iPad reports its trackpad and keyboard as a Mac does, so scrolling
/// and the ⌘ key follow the Mac client's rules there.
bool get nikoMacLikeInput => const bool.fromEnvironment('NIKODESK') && isIOS;

/// Releases the modifier keys the remote still sees pressed. iPadOS keeps
/// ⌘Tab and the app switcher to itself, so their key-up never reaches the
/// session and the remote would keep ⌘ held after switching back.
void nikoReleaseHeldKeys(InputModel input) {
  input.toReleaseKeys.release(input.handleKeyEvent);
  input.resetModifiers();
}

final _pinchScale = Expando<double>('nikodesk-trackpad-pinch');

/// A trackpad gesture begins; the next pinch starts from scale 1.
void nikoTrackpadGestureStart(InputModel input) => _pinchScale[input] = 1;

/// On the iPad a trackpad pinch zooms the local view of the remote screen,
/// as a pinch on the glass does; upstream sends it to the peer as a touch
/// "scale", which only Windows peers act on. Returns whether it handled
/// [e]. A two-finger scroll keeps scale 1 and goes on to the scroll path.
bool nikoTrackpadPinch(InputModel input, PointerPanZoomUpdateEvent e) {
  if (!nikoMacLikeInput || e.scale == 1) return false;
  final canvas = input.parent.target?.canvasModel;
  if (canvas == null) return false;
  final last = _pinchScale[input] ?? 1;
  _pinchScale[input] = e.scale;
  canvas.updateScale(e.scale / last, e.position);
  return true;
}
