import 'dart:ui';

/// Where a session puts the remote pointer when it starts or changes display.
/// Upstream uses the display's top-left corner, which macOS can bind to a hot
/// corner: with Lock Screen there, every session from a Flutter controller
/// began by locking the Mac it controlled (2026-10-26). The middle of the
/// display triggers nothing. Null keeps upstream's corner.
Offset? nikoPointerStart(Rect? display) =>
    const bool.fromEnvironment('NIKODESK') ? display?.center : null;
