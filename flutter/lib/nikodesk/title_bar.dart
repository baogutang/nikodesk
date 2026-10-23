import 'dart:io';

import 'package:flutter_hbb/models/platform_model.dart';

/// Whether the main window's home draws the macOS title strip itself, so
/// the tab bar can step aside while the home is the window's only tab.
/// Mirrors the check that puts NikoHomeShell in the desktop home.
bool nikoHomeDrawsTitleBar() =>
    Platform.isMacOS &&
    !bind.isIncomingOnly() &&
    bind.mainGetAppNameSync() == 'NikoDesk';
