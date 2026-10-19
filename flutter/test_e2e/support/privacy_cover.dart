import 'dart:io';

/// Windows that cover the whole main display above the screen saver level and
/// belong to NikoDesk: the Mac privacy cover. It is excluded from screen
/// capture, so the controller's picture cannot show it; the window server's
/// own list is the evidence that this Mac's screen is actually covered.
/// (Since 1.0.10 the Mac privacy screen draws this cover instead of changing
/// the display's gamma table.) Null when the list cannot be read.
Future<int?> nikoPrivacyCoverWindows() async {
  final result = await Process.run('swift', [
    '-e',
    'import CoreGraphics; '
        'let main = CGDisplayBounds(CGMainDisplayID()); '
        'let level = Int(CGWindowLevelForKey(.screenSaverWindow)) + 1; '
        'let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []; '
        'var n = 0; '
        'for w in list { '
        'guard let layer = w[kCGWindowLayer as String] as? Int, layer >= level, '
        'let owner = w[kCGWindowOwnerName as String] as? String, owner.contains("NikoDesk"), '
        'let alpha = w[kCGWindowAlpha as String] as? Double, alpha >= 1, '
        'let bounds = w[kCGWindowBounds as String], '
        'let rect = CGRect(dictionaryRepresentation: bounds as! CFDictionary) else { continue }; '
        'if rect.contains(main) { n += 1 } }; '
        'print(n)'
  ]);
  return result.exitCode == 0 ? int.tryParse('${result.stdout}'.trim()) : null;
}
