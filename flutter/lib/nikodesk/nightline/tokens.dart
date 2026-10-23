import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Colour presets of the NikoDesk design system (UI 2.1, 2026-10-23).
/// Orbit is the default: white and light-grey surfaces with system blue.
/// Clay is the warm alternative: ivory and terracotta. Each has a light and
/// a dark palette; every text pair meets WCAG AA
/// (test/nikodesk_nightline_test.dart keeps the table).
enum NlPreset { orbit, clay }

/// Semantic colour tokens. Pages read them through [NlColors.of]; nothing
/// outside this file writes a colour literal for design-system surfaces.
///
/// [accent] marks state (focus rings, switches, selection, progress) and
/// keeps 3:1 against the surfaces it is drawn on. Buttons fill with
/// [accentFill], which keeps 4.5:1 under a white label; in dark mode it is
/// therefore deeper than [accent].
@immutable
class NlColors extends ThemeExtension<NlColors> {
  final Brightness brightness;
  final NlPreset preset;
  final Color page;
  final Color bg;

  /// Sidebar and secondary panes.
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
  final Color accentFill;
  final Color accentHover;
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

  /// Fill of destructive buttons, with the white label at 4.5:1 or more.
  final Color dangerFill;
  final Color dangerHover;
  final Color onDanger;
  final Color scrim;

  /// Translucent washes for hovered and selected rows on any surface.
  final Color hover;
  final Color selected;

  /// Device tile colours; [tile] picks one per device id.
  final List<Color> tiles;

  /// Elevation 1 (resting cards, light only), 2 (menus, popovers) and
  /// 3 (dialogs, sheets, floating tool panels).
  final List<BoxShadow> shadow1;
  final List<BoxShadow> shadow2;
  final List<BoxShadow> shadow3;
  final List<BoxShadow> glow;

  const NlColors({
    required this.brightness,
    required this.preset,
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
    required this.accentFill,
    required this.accentHover,
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
    required this.dangerFill,
    required this.dangerHover,
    required this.onDanger,
    required this.scrim,
    required this.hover,
    required this.selected,
    required this.tiles,
    required this.shadow1,
    required this.shadow2,
    required this.shadow3,
    required this.glow,
  });

  static const _orbitTiles = [
    Color(0xFF0A84FF),
    Color(0xFF5E5CE6),
    Color(0xFFAF52DE),
    Color(0xFFFF375F),
    Color(0xFFFF9500),
    Color(0xFF30B0C7),
    Color(0xFF34C759),
    Color(0xFF8E8E93),
  ];
  static const _clayTiles = [
    Color(0xFFC96442),
    Color(0xFF6F8F62),
    Color(0xFF5B7A99),
    Color(0xFFC08A2E),
    Color(0xFF8E5E7E),
    Color(0xFF4E8C88),
    Color(0xFFA8553A),
    Color(0xFF8A8577),
  ];

  static const _lightShadow1 = [
    BoxShadow(color: Color(0x0F000000), offset: Offset(0, 1), blurRadius: 3, spreadRadius: -1),
  ];
  static const _lightShadow2 = [
    BoxShadow(color: Color(0x0F000000), spreadRadius: 1),
    BoxShadow(color: Color(0x1A000000), offset: Offset(0, 10), blurRadius: 30, spreadRadius: -6),
    BoxShadow(color: Color(0x0D000000), offset: Offset(0, 2), blurRadius: 6, spreadRadius: -1),
  ];
  static const _lightShadow3 = [
    BoxShadow(color: Color(0x0F000000), spreadRadius: 1),
    BoxShadow(color: Color(0x2E000000), offset: Offset(0, 24), blurRadius: 60, spreadRadius: -12),
    BoxShadow(color: Color(0x14000000), offset: Offset(0, 8), blurRadius: 20, spreadRadius: -6),
  ];
  static const _darkShadow2 = [
    BoxShadow(color: Color(0x14FFFFFF), spreadRadius: 1),
    BoxShadow(color: Color(0x99000000), offset: Offset(0, 12), blurRadius: 32, spreadRadius: -4),
  ];
  static const _darkShadow3 = [
    BoxShadow(color: Color(0x1FFFFFFF), spreadRadius: 1),
    BoxShadow(color: Color(0xB3000000), offset: Offset(0, 24), blurRadius: 64, spreadRadius: -8),
  ];

  static const orbitLight = NlColors(
    brightness: Brightness.light,
    preset: NlPreset.orbit,
    page: Color(0xFFECECEF),
    bg: Color(0xFFFFFFFF),
    bg2: Color(0xFFF2F2F5),
    surface: Color(0xFFF5F5F7),
    surface2: Color(0xFFEBEBEF),
    overlay: Color(0xFFFFFFFF),
    line: Color(0xFFE5E5EA),
    line2: Color(0xFFD1D1D6),
    ring: Color(0xFFE5E5EA),
    fg: Color(0xFF1D1D1F),
    fg2: Color(0xFF55555A),
    fg3: Color(0xFF68686E),
    accent: Color(0xFF0071E3),
    accentFill: Color(0xFF0071E3),
    accentHover: Color(0xFF0066CC),
    onAccent: Color(0xFFFFFFFF),
    accentText: Color(0xFF0066CC),
    accentSoft: Color(0x1A0A84FF),
    accent2: Color(0xFF5E5CE6),
    ok: Color(0xFF28A745),
    okText: Color(0xFF1A7F37),
    okSoft: Color(0x1F34C759),
    warn: Color(0xFFF29900),
    warnText: Color(0xFF8A5300),
    warnSoft: Color(0x1FFF9F0A),
    danger: Color(0xFFE0352B),
    dangerText: Color(0xFFC8001A),
    dangerSoft: Color(0x1AFF3B30),
    dangerFill: Color(0xFFD70015),
    dangerHover: Color(0xFFC20013),
    onDanger: Color(0xFFFFFFFF),
    scrim: Color(0x3D0B0B0F),
    hover: Color(0x0A000000),
    selected: Color(0x12000000),
    tiles: _orbitTiles,
    shadow1: _lightShadow1,
    shadow2: _lightShadow2,
    shadow3: _lightShadow3,
    glow: [BoxShadow(color: Color(0x590071E3), blurRadius: 6)],
  );

  static const orbitDark = NlColors(
    brightness: Brightness.dark,
    preset: NlPreset.orbit,
    page: Color(0xFF111113),
    bg: Color(0xFF1C1C1E),
    bg2: Color(0xFF222225),
    surface: Color(0xFF2A2A2D),
    surface2: Color(0xFF323236),
    overlay: Color(0xFF2C2C2F),
    line: Color(0xFF37373A),
    line2: Color(0xFF4A4A4E),
    ring: Color(0x14FFFFFF),
    fg: Color(0xFFF5F5F7),
    fg2: Color(0xFFBDBDC3),
    fg3: Color(0xFFA0A0A7),
    accent: Color(0xFF0A84FF),
    accentFill: Color(0xFF0A6CDC),
    accentHover: Color(0xFF0961C6),
    onAccent: Color(0xFFFFFFFF),
    accentText: Color(0xFF4DA3FF),
    accentSoft: Color(0x2E0A84FF),
    accent2: Color(0xFF7D7AFF),
    ok: Color(0xFF30D158),
    okText: Color(0xFF3DD467),
    okSoft: Color(0x2430D158),
    warn: Color(0xFFFF9F0A),
    warnText: Color(0xFFFFB340),
    warnSoft: Color(0x24FF9F0A),
    danger: Color(0xFFFF453A),
    dangerText: Color(0xFFFF7A70),
    dangerSoft: Color(0x29FF453A),
    dangerFill: Color(0xFFD93A30),
    dangerHover: Color(0xFFC3342B),
    onDanger: Color(0xFFFFFFFF),
    scrim: Color(0x99000000),
    hover: Color(0x0FFFFFFF),
    selected: Color(0x1AFFFFFF),
    tiles: _orbitTiles,
    shadow1: [],
    shadow2: _darkShadow2,
    shadow3: _darkShadow3,
    glow: [BoxShadow(color: Color(0x730A84FF), blurRadius: 8)],
  );

  static const clayLight = NlColors(
    brightness: Brightness.light,
    preset: NlPreset.clay,
    page: Color(0xFFEDEBE4),
    bg: Color(0xFFFAF9F5),
    bg2: Color(0xFFF3F1EA),
    surface: Color(0xFFFFFFFF),
    surface2: Color(0xFFF0EEE6),
    overlay: Color(0xFFFFFFFF),
    line: Color(0xFFE8E6DC),
    line2: Color(0xFFD9D6CA),
    ring: Color(0xFFE8E6DC),
    fg: Color(0xFF1F1E1D),
    fg2: Color(0xFF5A5954),
    fg3: Color(0xFF6B6A64),
    accent: Color(0xFFC96442),
    accentFill: Color(0xFFB65234),
    accentHover: Color(0xFFA44A2F),
    onAccent: Color(0xFFFFFFFF),
    accentText: Color(0xFFA64A2C),
    accentSoft: Color(0x1FC96442),
    accent2: Color(0xFF5B7A99),
    ok: Color(0xFF3F8A5C),
    okText: Color(0xFF2B6B45),
    okSoft: Color(0x1F3F8A5C),
    warn: Color(0xFFD08C1F),
    warnText: Color(0xFF8A5A00),
    warnSoft: Color(0x1FD08C1F),
    danger: Color(0xFFC4412D),
    dangerText: Color(0xFFB3361F),
    dangerSoft: Color(0x1AC4412D),
    dangerFill: Color(0xFFB83A2A),
    dangerHover: Color(0xFFA63426),
    onDanger: Color(0xFFFFFFFF),
    scrim: Color(0x3D1F1E1D),
    hover: Color(0x0A1F1E1D),
    selected: Color(0x141F1E1D),
    tiles: _clayTiles,
    shadow1: _lightShadow1,
    shadow2: _lightShadow2,
    shadow3: _lightShadow3,
    glow: [BoxShadow(color: Color(0x59C96442), blurRadius: 6)],
  );

  static const clayDark = NlColors(
    brightness: Brightness.dark,
    preset: NlPreset.clay,
    page: Color(0xFF141413),
    bg: Color(0xFF262624),
    bg2: Color(0xFF1F1E1D),
    surface: Color(0xFF30302E),
    surface2: Color(0xFF3A3936),
    overlay: Color(0xFF30302E),
    line: Color(0xFF3E3D39),
    line2: Color(0xFF52504B),
    ring: Color(0x14FFFFFF),
    fg: Color(0xFFF5F4EF),
    fg2: Color(0xFFC6C3BA),
    fg3: Color(0xFFABA89F),
    accent: Color(0xFFD97757),
    accentFill: Color(0xFFB5532F),
    accentHover: Color(0xFFA34B2A),
    onAccent: Color(0xFFFFFFFF),
    accentText: Color(0xFFE8A086),
    accentSoft: Color(0x2ED97757),
    accent2: Color(0xFF8FA8C4),
    ok: Color(0xFF5DBB86),
    okText: Color(0xFF7AD3A5),
    okSoft: Color(0x245DBB86),
    warn: Color(0xFFE5A54B),
    warnText: Color(0xFFF0BB66),
    warnSoft: Color(0x24E5A54B),
    danger: Color(0xFFE5664F),
    dangerText: Color(0xFFF2907F),
    dangerSoft: Color(0x29E5664F),
    dangerFill: Color(0xFFC2412F),
    dangerHover: Color(0xFFAF3A2A),
    onDanger: Color(0xFFFFFFFF),
    scrim: Color(0x99000000),
    hover: Color(0x0FFFFFFF),
    selected: Color(0x17FFFFFF),
    tiles: _clayTiles,
    shadow1: [],
    shadow2: _darkShadow2,
    shadow3: _darkShadow3,
    glow: [BoxShadow(color: Color(0x73D97757), blurRadius: 8)],
  );

  /// The preset of the running window; NikoAppearance loads it from the
  /// local options before the first frame.
  static NlPreset active = NlPreset.orbit;

  static NlColors get dark => palette(active, Brightness.dark);
  static NlColors get light => palette(active, Brightness.light);

  static NlColors palette(NlPreset preset, Brightness brightness) =>
      switch ((preset, brightness)) {
        (NlPreset.orbit, Brightness.light) => orbitLight,
        (NlPreset.orbit, Brightness.dark) => orbitDark,
        (NlPreset.clay, Brightness.light) => clayLight,
        (NlPreset.clay, Brightness.dark) => clayDark,
      };

  static NlColors forBrightness(Brightness brightness) =>
      palette(active, brightness);

  /// Null outside a design-system theme; existing NikoDesk widgets use this
  /// to keep their previous look when a design-system page does not host
  /// them.
  static NlColors? maybeOf(BuildContext context) =>
      Theme.of(context).extension<NlColors>();

  static NlColors of(BuildContext context) =>
      maybeOf(context) ?? forBrightness(Theme.of(context).brightness);

  bool get isDark => brightness == Brightness.dark;

  /// Elevation 1 is the [ring] hairline plus [shadow1]; 2 and 3 float.
  List<BoxShadow> shadow(int level) => switch (level) {
        <= 1 => shadow1,
        2 => shadow2,
        _ => shadow3,
      };

  /// Keyboard focus: a background-coloured gap, then an accent ring.
  List<BoxShadow> get focusRing => [
        BoxShadow(color: accent, spreadRadius: 3.5),
        BoxShadow(color: bg, spreadRadius: 2),
      ];

  /// Soft tints are translucent; widgets that need an opaque fill composite
  /// them over the surface they sit on.
  Color solid(Color tint, [Color? over]) =>
      Color.alphaBlend(tint, over ?? surface);

  /// A stable tile colour for a device id.
  Color tile(String id) {
    var hash = 0;
    for (final unit in id.codeUnits) {
      hash = (hash * 31 + unit) & 0x7fffffff;
    }
    return tiles[hash % tiles.length];
  }

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
    Color? accentFill,
    Color? accentHover,
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
    Color? dangerFill,
    Color? dangerHover,
    Color? onDanger,
    Color? scrim,
    Color? hover,
    Color? selected,
    List<Color>? tiles,
    List<BoxShadow>? shadow1,
    List<BoxShadow>? shadow2,
    List<BoxShadow>? shadow3,
    List<BoxShadow>? glow,
  }) =>
      NlColors(
        brightness: brightness,
        preset: preset,
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
        accentFill: accentFill ?? this.accentFill,
        accentHover: accentHover ?? this.accentHover,
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
        dangerFill: dangerFill ?? this.dangerFill,
        dangerHover: dangerHover ?? this.dangerHover,
        onDanger: onDanger ?? this.onDanger,
        scrim: scrim ?? this.scrim,
        hover: hover ?? this.hover,
        selected: selected ?? this.selected,
        tiles: tiles ?? this.tiles,
        shadow1: shadow1 ?? this.shadow1,
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
    final next = t < .5 ? this : other;
    return NlColors(
      brightness: next.brightness,
      preset: next.preset,
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
      accentFill: c(accentFill, other.accentFill),
      accentHover: c(accentHover, other.accentHover),
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
      dangerFill: c(dangerFill, other.dangerFill),
      dangerHover: c(dangerHover, other.dangerHover),
      onDanger: c(onDanger, other.onDanger),
      scrim: c(scrim, other.scrim),
      hover: c(hover, other.hover),
      selected: c(selected, other.selected),
      tiles: next.tiles,
      shadow1: s(shadow1, other.shadow1),
      shadow2: s(shadow2, other.shadow2),
      shadow3: s(shadow3, other.shadow3),
      glow: s(glow, other.glow),
    );
  }
}

/// Floating session chrome (dock, telemetry HUD, privacy chip) over remote
/// video. It stays dark glass in every preset and mode.
class NlDock {
  static const background = Color(0xE61C1C1E);
  static const line = Color(0x1FFFFFFF);
  static const hover = Color(0x1AFFFFFF);
  static const separator = Color(0x1FFFFFFF);
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

  /// Inter's dynamic metrics: a touch of tracking at caption sizes,
  /// tightening as text grows (rsms.me/inter/dynmetrics).
  static double tracking(double size) =>
      size * (-.0223 + .185 * math.exp(-.1745 * size));

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
          letterSpacing: tracking(size),
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

/// Five radii: small marks, controls and rows, cards and panels, sheets and
/// dialogs, pills.
class NlRadius {
  static const r1 = 4.0;
  static const r2 = 8.0;
  static const r3 = 12.0;
  static const r4 = 16.0;
  static const pill = 999.0;
  static const all = [r1, r2, r3, r4, pill];
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
  static const s10 = 40.0;
  static const s12 = 48.0;
  static const s16 = 64.0;
}

/// Durations, curves and the sheet spring. Every animated widget asks [of]
/// so the platform "reduce motion" setting turns motion off.
class NlMotion {
  /// Colour and hover washes.
  static const instant = Duration(milliseconds: 80);

  /// Presses, small state changes.
  static const fast = Duration(milliseconds: 120);

  /// Menus, popovers, toggles, list reflow.
  static const base = Duration(milliseconds: 200);

  /// Sheets, the sidebar, the inspector.
  static const slow = Duration(milliseconds: 300);

  /// Page and window-sized transitions.
  static const page = Duration(milliseconds: 420);
  static const durations = [instant, fast, base, slow, page];

  /// Entrances: cubic-bezier(.16, 1, .3, 1), a long soft landing.
  static const ease = Cubic(.16, 1, .3, 1);

  /// Moves between two resting places.
  static const standard = Cubic(.2, 0, 0, 1);

  /// Exits accelerate away.
  static const exit = Cubic(.3, 0, .8, .15);

  /// Sheets and drawers that follow a finger settle on this spring.
  static const spring =
      SpringDescription(mass: 1, stiffness: 420, damping: 40);

  static bool reduced(BuildContext context) =>
      MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  static Duration of(BuildContext context, Duration duration) =>
      reduced(context) ? Duration.zero : duration;
}

enum NlSize { compact, medium, expanded }

/// Window-size classes and input density. Compact is a phone (or a narrow
/// window), medium an iPad in portrait or a small desktop window, expanded
/// everything wider.
class NlLayout {
  static const compactMax = 600.0;
  static const mediumMax = 1000.0;

  static NlSize sizeOf(double width) => width < compactMax
      ? NlSize.compact
      : width < mediumMax
          ? NlSize.medium
          : NlSize.expanded;

  /// Touch platforms get 44-point targets even with a trackpad attached,
  /// as iPadOS does; pointer platforms get 32.
  static bool touch(BuildContext context) =>
      switch (Theme.of(context).platform) {
        TargetPlatform.iOS ||
        TargetPlatform.android ||
        TargetPlatform.fuchsia =>
          true,
        _ => false,
      };

  static double target(BuildContext context) => touch(context) ? 44 : 32;

  /// Row height for lists and the sidebar.
  static double row(BuildContext context) => touch(context) ? 44 : 32;
}
