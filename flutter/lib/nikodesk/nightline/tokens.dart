import 'package:flutter/material.dart';

/// Nightline (夜航) colour tokens, frozen from the chosen UI 2.0 draft
/// (artifacts/design/ui-2026/c/nightline.css, picked 2026-10-20).
///
/// Only semantic names: surfaces, overlay, lines, text, accent and status.
/// Pages read them through [NlColors.of]; nothing outside this file writes a
/// colour literal for Nightline surfaces.
@immutable
class NlColors extends ThemeExtension<NlColors> {
  final Brightness brightness;
  final Color page;
  final Color bg;
  final Color bg2;
  final Color surface;
  final Color surface2;
  final Color overlay;
  final Color line;
  final Color line2;

  /// Hairline drawn inside a resting panel (elevation 1).
  final Color ring;
  final Color fg;
  final Color fg2;
  final Color fg3;
  final Color accent;
  final Color onAccent;
  final Color accentText;
  final Color accentSoft;
  final Color accent2;
  final Color ok;
  final Color okText;
  final Color okSoft;
  final Color warn;
  final Color warnText;
  final Color warnSoft;
  final Color danger;
  final Color dangerText;
  final Color dangerSoft;
  final Color onDanger;
  final Color scrim;

  /// Elevation 2 (menus, popovers) and 3 (dialogs, floating tool panels).
  final List<BoxShadow> shadow2;
  final List<BoxShadow> shadow3;
  final List<BoxShadow> glow;

  const NlColors({
    required this.brightness,
    required this.page,
    required this.bg,
    required this.bg2,
    required this.surface,
    required this.surface2,
    required this.overlay,
    required this.line,
    required this.line2,
    required this.ring,
    required this.fg,
    required this.fg2,
    required this.fg3,
    required this.accent,
    required this.onAccent,
    required this.accentText,
    required this.accentSoft,
    required this.accent2,
    required this.ok,
    required this.okText,
    required this.okSoft,
    required this.warn,
    required this.warnText,
    required this.warnSoft,
    required this.danger,
    required this.dangerText,
    required this.dangerSoft,
    required this.onDanger,
    required this.scrim,
    required this.shadow2,
    required this.shadow3,
    required this.glow,
  });

  // CSS blur radii are converted to Flutter's blurRadius (sigma = r/2 in CSS,
  // r * 0.57735 + 0.5 in Flutter), so the shadows match the draft visually.
  static const dark = NlColors(
    brightness: Brightness.dark,
    page: Color(0xFF07080A),
    bg: Color(0xFF0B0D10),
    bg2: Color(0xFF0E1114),
    surface: Color(0xFF13171B),
    surface2: Color(0xFF1A1F24),
    overlay: Color(0xFF161A1F),
    line: Color(0xFF222930),
    line2: Color(0xFF2F3841),
    ring: Color(0x0FFFFFFF),
    fg: Color(0xFFE6EDF2),
    fg2: Color(0xFF93A1AD),
    fg3: Color(0xFF687682),
    accent: Color(0xFF2FD8EE),
    onAccent: Color(0xFF031317),
    accentText: Color(0xFF5CE6F7),
    accentSoft: Color(0x1F2FD8EE),
    accent2: Color(0xFF7FA2FF),
    ok: Color(0xFF3DDC97),
    okText: Color(0xFF5BE3A7),
    okSoft: Color(0x1F3DDC97),
    warn: Color(0xFFFFB547),
    warnText: Color(0xFFFFC46E),
    warnSoft: Color(0x1FFFB547),
    danger: Color(0xFFFF5D6C),
    dangerText: Color(0xFFFF8592),
    dangerSoft: Color(0x24FF5D6C),
    onDanger: Color(0xFFFFFFFF),
    scrim: Color(0x9E030507),
    shadow2: [
      BoxShadow(color: Color(0x14FFFFFF), spreadRadius: 1),
      BoxShadow(
          color: Color(0xBF000000),
          offset: Offset(0, 16),
          blurRadius: 34,
          spreadRadius: -8),
    ],
    shadow3: [
      BoxShadow(color: Color(0x297FC8FF), spreadRadius: 1),
      BoxShadow(
          color: Color(0xCC000000),
          offset: Offset(0, 24),
          blurRadius: 51,
          spreadRadius: -10),
      BoxShadow(color: Color(0x612FD8EE), blurRadius: 34, spreadRadius: -12),
    ],
    glow: [BoxShadow(color: Color(0x8C2FD8EE), blurRadius: 8)],
  );

  static const light = NlColors(
    brightness: Brightness.light,
    page: Color(0xFFE4E8EB),
    bg: Color(0xFFF3F5F7),
    bg2: Color(0xFFEBEEF1),
    surface: Color(0xFFFFFFFF),
    surface2: Color(0xFFEEF1F4),
    overlay: Color(0xFFFFFFFF),
    line: Color(0xFFDCE1E6),
    line2: Color(0xFFC5CDD4),
    ring: Color(0xFFDCE1E6),
    fg: Color(0xFF0E1418),
    fg2: Color(0xFF4A5660),
    fg3: Color(0xFF74808A),
    accent: Color(0xFF0A7F95),
    onAccent: Color(0xFFFFFFFF),
    accentText: Color(0xFF07707F),
    accentSoft: Color(0xFFDCF3F6),
    accent2: Color(0xFF3D63E6),
    ok: Color(0xFF12865A),
    okText: Color(0xFF0E6B48),
    okSoft: Color(0xFFDDF3E9),
    warn: Color(0xFFD98A00),
    warnText: Color(0xFF8F5A00),
    warnSoft: Color(0xFFFFF0D6),
    danger: Color(0xFFD2283B),
    dangerText: Color(0xFFB71F31),
    dangerSoft: Color(0xFFFCE3E6),
    onDanger: Color(0xFFFFFFFF),
    scrim: Color(0x660E1418),
    shadow2: [
      BoxShadow(color: Color(0x0F0E1418), spreadRadius: 1),
      BoxShadow(
          color: Color(0x330E1418),
          offset: Offset(0, 12),
          blurRadius: 27,
          spreadRadius: -8),
    ],
    shadow3: [
      BoxShadow(color: Color(0x400A7F95), spreadRadius: 1),
      BoxShadow(
          color: Color(0x520E1418),
          offset: Offset(0, 24),
          blurRadius: 48,
          spreadRadius: -12),
    ],
    glow: [BoxShadow(color: Color(0x590A7F95), blurRadius: 6)],
  );

  static NlColors forBrightness(Brightness brightness) =>
      brightness == Brightness.dark ? dark : light;

  /// Null outside a Nightline theme; existing NikoDesk widgets use this to
  /// keep their previous look when they are not hosted by a Nightline page.
  static NlColors? maybeOf(BuildContext context) =>
      Theme.of(context).extension<NlColors>();

  static NlColors of(BuildContext context) =>
      maybeOf(context) ?? forBrightness(Theme.of(context).brightness);

  bool get isDark => brightness == Brightness.dark;

  /// Elevation 1 is the [ring] hairline; 2 and 3 add drop shadows.
  List<BoxShadow> shadow(int level) => switch (level) {
        <= 1 => const [],
        2 => shadow2,
        _ => shadow3,
      };

  /// Keyboard focus: a background-coloured gap, then an accent ring.
  List<BoxShadow> get focusRing => [
        BoxShadow(color: accent, spreadRadius: 3.5),
        BoxShadow(color: bg, spreadRadius: 2),
      ];

  /// Soft tints are translucent in dark mode; widgets that need an opaque
  /// fill composite them over the surface they sit on.
  Color solid(Color tint, [Color? over]) =>
      Color.alphaBlend(tint, over ?? surface);

  @override
  NlColors copyWith({
    Color? page,
    Color? bg,
    Color? bg2,
    Color? surface,
    Color? surface2,
    Color? overlay,
    Color? line,
    Color? line2,
    Color? ring,
    Color? fg,
    Color? fg2,
    Color? fg3,
    Color? accent,
    Color? onAccent,
    Color? accentText,
    Color? accentSoft,
    Color? accent2,
    Color? ok,
    Color? okText,
    Color? okSoft,
    Color? warn,
    Color? warnText,
    Color? warnSoft,
    Color? danger,
    Color? dangerText,
    Color? dangerSoft,
    Color? onDanger,
    Color? scrim,
    List<BoxShadow>? shadow2,
    List<BoxShadow>? shadow3,
    List<BoxShadow>? glow,
  }) =>
      NlColors(
        brightness: brightness,
        page: page ?? this.page,
        bg: bg ?? this.bg,
        bg2: bg2 ?? this.bg2,
        surface: surface ?? this.surface,
        surface2: surface2 ?? this.surface2,
        overlay: overlay ?? this.overlay,
        line: line ?? this.line,
        line2: line2 ?? this.line2,
        ring: ring ?? this.ring,
        fg: fg ?? this.fg,
        fg2: fg2 ?? this.fg2,
        fg3: fg3 ?? this.fg3,
        accent: accent ?? this.accent,
        onAccent: onAccent ?? this.onAccent,
        accentText: accentText ?? this.accentText,
        accentSoft: accentSoft ?? this.accentSoft,
        accent2: accent2 ?? this.accent2,
        ok: ok ?? this.ok,
        okText: okText ?? this.okText,
        okSoft: okSoft ?? this.okSoft,
        warn: warn ?? this.warn,
        warnText: warnText ?? this.warnText,
        warnSoft: warnSoft ?? this.warnSoft,
        danger: danger ?? this.danger,
        dangerText: dangerText ?? this.dangerText,
        dangerSoft: dangerSoft ?? this.dangerSoft,
        onDanger: onDanger ?? this.onDanger,
        scrim: scrim ?? this.scrim,
        shadow2: shadow2 ?? this.shadow2,
        shadow3: shadow3 ?? this.shadow3,
        glow: glow ?? this.glow,
      );

  @override
  NlColors lerp(NlColors? other, double t) {
    if (other == null) return this;
    Color c(Color a, Color b) => Color.lerp(a, b, t)!;
    List<BoxShadow> s(List<BoxShadow> a, List<BoxShadow> b) =>
        BoxShadow.lerpList(a, b, t)!;
    return NlColors(
      brightness: t < .5 ? brightness : other.brightness,
      page: c(page, other.page),
      bg: c(bg, other.bg),
      bg2: c(bg2, other.bg2),
      surface: c(surface, other.surface),
      surface2: c(surface2, other.surface2),
      overlay: c(overlay, other.overlay),
      line: c(line, other.line),
      line2: c(line2, other.line2),
      ring: c(ring, other.ring),
      fg: c(fg, other.fg),
      fg2: c(fg2, other.fg2),
      fg3: c(fg3, other.fg3),
      accent: c(accent, other.accent),
      onAccent: c(onAccent, other.onAccent),
      accentText: c(accentText, other.accentText),
      accentSoft: c(accentSoft, other.accentSoft),
      accent2: c(accent2, other.accent2),
      ok: c(ok, other.ok),
      okText: c(okText, other.okText),
      okSoft: c(okSoft, other.okSoft),
      warn: c(warn, other.warn),
      warnText: c(warnText, other.warnText),
      warnSoft: c(warnSoft, other.warnSoft),
      danger: c(danger, other.danger),
      dangerText: c(dangerText, other.dangerText),
      dangerSoft: c(dangerSoft, other.dangerSoft),
      onDanger: c(onDanger, other.onDanger),
      scrim: c(scrim, other.scrim),
      shadow2: s(shadow2, other.shadow2),
      shadow3: s(shadow3, other.shadow3),
      glow: s(glow, other.glow),
    );
  }
}

/// Floating session chrome (dock, telemetry HUD, privacy chip). The draft
/// keeps it dark in both modes, so these are not brightness dependent. The
/// draft blurs a translucent fill; without backdrop blur over live video the
/// fill is a little more opaque to stay legible.
class NlDock {
  static const background = Color(0xEB0C0E12);
  static const line = Color(0x14FFFFFF);
  static const hover = Color(0x14FFFFFF);
  static const separator = Color(0x1AFFFFFF);
}

/// Seven type sizes; UI text in Inter, numbers, IDs and labels in
/// JetBrains Mono. CJK falls back to the platform UI font.
class NlType {
  static const ui = 'Inter';
  static const mono = 'JetBrains Mono';
  static const uiFallback = [
    'PingFang SC',
    'Microsoft YaHei UI',
    'Noto Sans SC',
    'Noto Sans CJK SC',
  ];
  /// JetBrains Mono is bundled, so mono text only falls back for CJK.
  static const monoFallback = uiFallback;

  static const s1 = 11.0;
  static const s2 = 12.0;
  static const s3 = 13.0;
  static const s4 = 14.0;
  static const s5 = 16.0;
  static const s6 = 20.0;
  static const s7 = 28.0;
  static const scale = [s1, s2, s3, s4, s5, s6, s7];

  /// Line height in logical pixels for each step of [scale].
  static double lineHeight(double size) => switch (size) {
        s1 || s2 => 16,
        s3 => 18,
        s4 => 20,
        s5 => 22,
        s6 => 28,
        _ => 36,
      };

  /// Section and metric labels: uppercase mono with wide tracking.
  static const labelTracking = .12;

  static TextStyle text(double size,
          {FontWeight weight = FontWeight.w400, Color? color}) =>
      TextStyle(
          fontFamily: ui,
          fontFamilyFallback: uiFallback,
          fontSize: size,
          height: lineHeight(size) / size,
          fontWeight: weight,
          letterSpacing: 0,
          color: color);

  static TextStyle monoText(double size,
          {FontWeight weight = FontWeight.w400, Color? color}) =>
      TextStyle(
          fontFamily: mono,
          fontFamilyFallback: monoFallback,
          fontSize: size,
          height: lineHeight(size) / size,
          fontWeight: weight,
          letterSpacing: 0,
          color: color,
          fontFeatures: const [FontFeature.tabularFigures()]);
}

/// Four radii: controls, fields and cards, panels, pills.
class NlRadius {
  static const r1 = 4.0;
  static const r2 = 8.0;
  static const r3 = 12.0;
  static const pill = 999.0;
  static const all = [r1, r2, r3, pill];
}

/// Spacing on a 4-pixel grid; sN is N × 4.
class NlSpace {
  static const s1 = 4.0;
  static const s2 = 8.0;
  static const s3 = 12.0;
  static const s4 = 16.0;
  static const s5 = 20.0;
  static const s6 = 24.0;
  static const s8 = 32.0;
  static const s12 = 48.0;
}

/// Three durations and one easing curve. Every animated Nightline widget
/// asks [of] so the platform "reduce motion" setting turns motion off.
class NlMotion {
  static const fast = Duration(milliseconds: 100);
  static const base = Duration(milliseconds: 180);
  static const slow = Duration(milliseconds: 280);
  static const durations = [fast, base, slow];

  /// cubic-bezier(.16, 1, .3, 1)
  static const ease = Cubic(.16, 1, .3, 1);

  static bool reduced(BuildContext context) =>
      MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  static Duration of(BuildContext context, Duration duration) =>
      reduced(context) ? Duration.zero : duration;
}
