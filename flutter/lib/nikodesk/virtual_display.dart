import 'dart:ui' as ui;

import '../common.dart' show SessionID;
import '../models/platform_model.dart';
import 'remote_resolution.dart' show nikoCurrentFlutterView;

/// A native snapshot; clicking a menu never changes these confirmed slots.
class NikoVirtualDisplays {
  final bool supported, allowed;
  final Set<int> active, cleanup;
  const NikoVirtualDisplays._(
      this.supported, this.allowed, this.active, this.cleanup);
  static NikoVirtualDisplays? parse(dynamic raw) {
    if (raw is! Map ||
        raw.length != 5 ||
        raw['schema'] != 1 ||
        raw['supported'] is! bool ||
        raw['allowed'] is! bool) return null;
    Set<int>? slots(dynamic value) {
      if (value is! List ||
          value.length > 4 ||
          value.any((slot) => slot is! int || slot < 1 || slot > 4)) {
        return null;
      }
      final result = value.cast<int>().toSet();
      return result.length == value.length ? result : null;
    }

    final active = slots(raw['active']), cleanup = slots(raw['cleanup']);
    if (active == null ||
        cleanup == null ||
        active.intersection(cleanup).isNotEmpty) return null;
    return NikoVirtualDisplays._(
        raw['supported'], raw['allowed'], active, cleanup);
  }
}

typedef NikoScreenSpec = ({
  int width,
  int height,
  int scaleMilli,
  int refreshMilliHz
});

const NikoScreenSpec _unknownScreen =
    (width: 0, height: 0, scaleMilli: 0, refreshMilliHz: 0);

/// The screen a virtual display is made to: physical pixels, and scale and
/// refresh rate x 1000. Zeros when unknown; the controlled side then uses its
/// fixed modes. A phone or tablet is assumed to be held in landscape.
NikoScreenSpec nikoScreenSpec(ui.Display? display, {required bool landscape}) {
  try {
    if (display == null) return _unknownScreen;
    return nikoScreenSpecOf(
        display.size, display.devicePixelRatio, display.refreshRate,
        landscape: landscape);
  } catch (_) {
    return _unknownScreen;
  }
}

NikoScreenSpec nikoScreenSpecOf(
    ui.Size size, double devicePixelRatio, double refreshRate,
    {required bool landscape}) {
  if (!size.width.isFinite ||
      !size.height.isFinite ||
      size.width <= 0 ||
      size.height <= 0) return _unknownScreen;
  var width = size.width.round(), height = size.height.round();
  if (landscape && height > width) (width, height) = (height, width);
  return (
    width: width,
    height: height,
    scaleMilli: devicePixelRatio.isFinite && devicePixelRatio > 0
        ? (devicePixelRatio * 1000).round()
        : 0,
    refreshMilliHz: refreshRate.isFinite && refreshRate > 0
        ? (refreshRate * 1000).round()
        : 0
  );
}

/// Turns a virtual display on, made to the screen this window is on, or off.
void nikoToggleVirtualDisplay(SessionID session, int slot, bool on,
    {required bool landscape}) {
  final spec = on
      ? nikoScreenSpec(nikoCurrentFlutterView()?.display, landscape: landscape)
      : _unknownScreen;
  bind.sessionToggleNikodeskVirtualDisplay(
      sessionId: session,
      index: slot,
      on: on,
      width: spec.width,
      height: spec.height,
      scaleMilli: spec.scaleMilli,
      refreshMilliHz: spec.refreshMilliHz);
}
