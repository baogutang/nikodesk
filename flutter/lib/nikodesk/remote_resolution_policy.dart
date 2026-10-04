import 'dart:math' as math;

class NikoDisplayMode {
  final int width;
  final int height;
  const NikoDisplayMode(this.width, this.height);

  int get area => width * height;
  String get label => '$width×$height';

  @override
  bool operator ==(Object other) =>
      other is NikoDisplayMode && other.width == width && other.height == height;

  @override
  int get hashCode => Object.hash(width, height);
}

/// The smallest remote mode in the original aspect ratio that still sends as
/// many pixels as the local screen can show. A Retina remote reports its
/// modes in points, so [remoteScale] converts them to captured pixels.
/// Returns null when no smaller mode qualifies.
NikoDisplayMode? nikoFitDisplayMode({
  required Iterable<NikoDisplayMode> supported,
  required NikoDisplayMode original,
  required double remoteScale,
  required int localLongEdge,
}) {
  if (localLongEdge <= 0 || original.width <= 0 || original.height <= 0) {
    return null;
  }
  final aspect = original.width / original.height;
  final scale = remoteScale > 1 ? remoteScale : 1.0;
  NikoDisplayMode? best;
  for (final mode in supported) {
    if (mode.width <= 0 || mode.height <= 0 || mode.area >= original.area) {
      continue;
    }
    if ((mode.width / mode.height - aspect).abs() > aspect * 0.01) continue;
    if (math.max(mode.width, mode.height) * scale < localLongEdge) continue;
    if (best == null || mode.area < best.area) best = mode;
  }
  return best;
}

/// What the control center shows and acts on for the current remote display.
class NikoRemoteResolution {
  final NikoDisplayMode current;
  final NikoDisplayMode original;
  final NikoDisplayMode capturedPixels;
  final NikoDisplayMode? fit;

  /// Zero when this controller's screen size could not be read.
  final int localLongEdge;
  const NikoRemoteResolution(
      {required this.current,
      required this.original,
      required this.capturedPixels,
      required this.fit,
      this.localLongEdge = 1});

  bool get changed => current != original;
}

/// Builds the state from what the controlled side reports: [width] and
/// [height] are captured pixels, the original mode and [supported] are in the
/// units its display modes use (points on a Retina Mac), and [scale] relates
/// the two.
NikoRemoteResolution nikoResolutionState({
  required int width,
  required int height,
  required int originalWidth,
  required int originalHeight,
  required double scale,
  required Iterable<NikoDisplayMode> supported,
  required int localLongEdge,
}) {
  final factor = scale > 1 ? scale : 1.0;
  final original = NikoDisplayMode(originalWidth, originalHeight);
  return NikoRemoteResolution(
    current:
        NikoDisplayMode((width / factor).round(), (height / factor).round()),
    original: original,
    capturedPixels: NikoDisplayMode(width, height),
    fit: nikoFitDisplayMode(
        supported: supported,
        original: original,
        remoteScale: factor,
        localLongEdge: localLongEdge),
    localLongEdge: localLongEdge,
  );
}

/// Whether a switch that was meant to reduce the picture did so: fewer
/// captured pixels than [before], still filling the controller. A Mac may
/// apply a listed size as a Retina or a plain mode, so the request alone does
/// not say.
bool nikoFitReducedPixels(
        {required NikoDisplayMode before,
        required NikoDisplayMode after,
        required int localLongEdge}) =>
    after.area < before.area &&
    math.max(after.width, after.height) >= localLongEdge;


/// How much of the remote picture the controlled side captures. This scales
/// the capture and leaves the remote display mode alone.
enum NikoCaptureMode {
  /// As many pixels as this controller's screen can show.
  fit,

  /// The remote display's point size: one pixel per point, a quarter of the
  /// pixels of a Retina display.
  small,

  /// Everything the remote display has.
  native,
}

NikoCaptureMode nikoCaptureModeFromName(String? name) =>
    NikoCaptureMode.values.firstWhere((mode) => mode.name == name,
        orElse: () => NikoCaptureMode.fit);

/// The controlled side never goes below its point size, so the narrowest
/// request it accepts asks for exactly that.
const nikoSmallestCaptureWidth = 640;

/// Any controlled display is narrower than this; it asks for the native size.
const nikoNativeCaptureWidth = 65535;

/// The width to request. An unreadable local screen asks for the native size
/// rather than guessing.
int nikoCaptureWidth(NikoCaptureMode mode, int localLongEdge) {
  switch (mode) {
    case NikoCaptureMode.native:
      return nikoNativeCaptureWidth;
    case NikoCaptureMode.small:
      return nikoSmallestCaptureWidth;
    case NikoCaptureMode.fit:
      return localLongEdge <= 0
          ? nikoNativeCaptureWidth
          : localLongEdge.clamp(
              nikoSmallestCaptureWidth, nikoNativeCaptureWidth);
  }
}
