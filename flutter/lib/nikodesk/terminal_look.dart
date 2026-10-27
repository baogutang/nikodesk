import 'package:flutter/widgets.dart';
import 'package:xterm/xterm.dart';

import 'nightline.dart';

/// The remote terminal in the design system: the window's own background,
/// ANSI colours drawn from the palette and bundled JetBrains Mono. Null
/// outside the NikoDesk build or a Nightline theme, where the stock look
/// stays.
({TerminalTheme theme, TerminalStyle style})? nikoTerminalLook(
    BuildContext context) {
  if (!const bool.fromEnvironment('NIKODESK')) return null;
  final nl = NlColors.maybeOf(context);
  if (nl == null) return null;
  return (theme: nikoTerminalTheme(nl), style: nikoTerminalStyle);
}

// Same size and line height as the stock style, so a remote shell keeps
// the rows and columns it had.
const nikoTerminalStyle = TerminalStyle(
    fontFamily: NlType.mono, fontFamilyFallback: NlType.monoFallback);

/// Light terminals use the palette's text tones, which keep contrast on
/// white; dark ones use the brighter tones. Yellow, magenta and cyan have
/// no palette role, so they are fixed to match it.
TerminalTheme nikoTerminalTheme(NlColors nl) {
  final dark = nl.isDark;
  return TerminalTheme(
    // Translucent, so the character under a block cursor stays legible.
    cursor: nl.accent.withOpacity(.67),
    selection: nl.accent.withOpacity(dark ? .32 : .22),
    foreground: nl.fg,
    background: nl.bg,
    black: dark ? const Color(0xFF48484C) : nl.fg,
    red: dark ? nl.danger : nl.dangerText,
    green: dark ? nl.ok : nl.okText,
    yellow: dark ? const Color(0xFFFFD60A) : const Color(0xFF8A5300),
    blue: dark ? nl.accent : nl.accentText,
    magenta: dark ? const Color(0xFFBF5AF2) : const Color(0xFF8944AB),
    cyan: dark ? const Color(0xFF40C8E0) : const Color(0xFF0A7E8C),
    white: dark ? nl.fg2 : nl.fg3,
    brightBlack: dark ? const Color(0xFF7C7C82) : nl.fg2,
    brightRed: dark ? nl.dangerText : nl.danger,
    brightGreen: dark ? nl.okText : nl.ok,
    brightYellow: dark ? const Color(0xFFFFE45C) : const Color(0xFFA66B00),
    brightBlue: dark ? nl.accentText : nl.accent,
    brightMagenta: dark ? const Color(0xFFDA8FFF) : const Color(0xFFA550A7),
    brightCyan: dark ? const Color(0xFF70D7FF) : const Color(0xFF1A8FA0),
    brightWhite: dark ? nl.fg : const Color(0xFF767B83),
    searchHitBackground: nl.warn.withOpacity(.35),
    searchHitBackgroundCurrent: nl.warn.withOpacity(.6),
    searchHitForeground: nl.fg,
  );
}
