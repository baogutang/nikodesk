import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/desktop/widgets/tabbar_widget.dart';

/// NikoDesk design language, confirmed with the user as:
///  - light mode "渐变轻盈": purple-blue gradient canvas, glass cards,
///    gradient primary actions;
///  - dark mode "暗夜控制台": deep navy surfaces, glowing blue accent,
///    monospaced device ids picked out in the accent color.
class NikoPalette {
  // shared
  static const success = Color(0xFF22A06B);
  static const warning = Color(0xFFE8930C);
  static const danger = Color(0xFFE5484D);
  static const lightSuccessText = Color(0xFF176B46);
  static const lightWarningText = Color(0xFF8D5900);
  static const lightOfflineText = Color(0xFF586477);

  // light (D)
  static const lightSeed = Color(0xFF6C4CF1);
  static const lightText = Color(0xFF241B3E);
  static const lightMuted = Color(0xFF706493);
  static const lightCard = Color(0xB8FFFFFF); // 72% white
  static const lightCardBorder = Color(0xD9FFFFFF); // 85% white
  static const lightField = Color(0xE6FFFFFF); // 90% white
  static const lightLine = Color(0x296C4CF1); // 16% brand
  static const lightShadow = Color(0x14543CA0); // 8% deep purple
  static const primaryGradient = LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [Color(0xFF8159F2), Color(0xFF366BEF)]);

  // dark (B)
  static const darkSeed = Color(0xFF5B8CFF);
  static const darkText = Color(0xFFE6E9F0);
  static const darkMuted = Color(0xFF8A92A6);
  static const darkScaffold = Color(0xFF101319);
  static const darkSidebar = Color(0xFF141821);
  static const darkCard = Color(0xFF191E27);
  static const darkField = Color(0xFF12151D);
  static const darkLine = Color(0xFF2A3140);
  static const darkOnPrimary = Color(0xFF0D1120);

  /// Home canvas: light paints the soft gradient, dark stays flat navy.
  static const lightCanvas = LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      stops: [0, .55, 1],
      colors: [Color(0xFFF3EFFF), Color(0xFFEAF1FF), Color(0xFFF7F3FF)]);

  /// Deterministic, pleasant avatar gradient for a device id.
  static List<Color> deviceAvatarGradient(String id) {
    var hash = 0;
    for (final rune in id.codeUnits) {
      hash = (hash * 31 + rune) & 0x7fffffff;
    }
    final hue = (hash % 360).toDouble();
    final from =
        HSLColor.fromAHSL(1, hue, .68, .58).toColor();
    final to = HSLColor.fromAHSL(1, (hue + 38) % 360, .66, .46).toColor();
    return [from, to];
  }
}

class NikoShapes {
  static const card = 16.0;
  static const control = 10.0;
  static const chip = 8.0;
  static const avatar = 12.0;
}

bool nikoIsLight(BuildContext context) =>
    Theme.of(context).brightness == Brightness.light;

/// Glass card: translucent + blurred over the gradient canvas in light mode,
/// solid bordered navy in dark mode.
class NikoGlassCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry? margin;
  final List<BoxShadow>? boxShadow;

  const NikoGlassCard(
      {super.key,
      required this.child,
      this.padding = const EdgeInsets.all(16),
      this.margin,
      this.boxShadow});

  @override
  Widget build(BuildContext context) {
    final light = nikoIsLight(context);
    final radius = BorderRadius.circular(NikoShapes.card);
    final card = Container(
      margin: margin,
      padding: padding,
      decoration: BoxDecoration(
        color: light ? NikoPalette.lightCard : NikoPalette.darkCard,
        borderRadius: radius,
        border: Border.all(
            color: light ? NikoPalette.lightCardBorder : NikoPalette.darkLine),
        boxShadow: light
            ? (boxShadow ?? const [BoxShadow(color: NikoPalette.lightShadow, blurRadius: 24, offset: Offset(0, 8))])
            : null,
      ),
      child: child,
    );
    if (!light) return card;
    return ClipRRect(
        borderRadius: radius,
        child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14), child: card));
  }
}

/// Primary action: gradient capsule in light mode, luminous accent in dark.
class NikoPrimaryButton extends StatelessWidget {
  final VoidCallback? onPressed;
  final Widget child;
  final EdgeInsetsGeometry padding;
  final bool compact;

  const NikoPrimaryButton(
      {super.key,
      required this.onPressed,
      required this.child,
      this.padding = const EdgeInsets.symmetric(horizontal: 24, vertical: 13),
      this.compact = false});

  @override
  Widget build(BuildContext context) {
    final light = nikoIsLight(context);
    final radius = BorderRadius.circular(NikoShapes.control);
    final disabled = onPressed == null;
    final fg = light ? Colors.white : NikoPalette.darkOnPrimary;
    return Semantics(
        button: true,
        enabled: !disabled,
        child: Opacity(
            opacity: disabled ? .55 : 1,
            child: Material(
                color: Colors.transparent,
                child: Ink(
                    decoration: BoxDecoration(
                      borderRadius: radius,
                      gradient: light ? NikoPalette.primaryGradient : null,
                      color: light ? null : NikoPalette.darkSeed,
                      boxShadow: disabled
                          ? null
                          : (light
                              ? const [BoxShadow(color: Color(0x4D6C4CF1),
                                  blurRadius: 16, offset: Offset(0, 6))]
                              : const [BoxShadow(color: Color(0x735B8CFF),
                                  blurRadius: 18, offset: Offset(0, 4))]),
                    ),
                    child: InkWell(
                        borderRadius: radius,
                        onTap: onPressed,
                        canRequestFocus: !disabled,
                        focusColor: Colors.black.withOpacity(.12),
                        hoverColor: Colors.black.withOpacity(.06),
                        child: ConstrainedBox(
                            constraints: const BoxConstraints(minHeight: 48, minWidth: 48),
                            child: Padding(
                                padding: compact
                                    ? const EdgeInsets.symmetric(horizontal: 18, vertical: 9)
                                    : padding,
                                child: Center(
                                    widthFactor: 1,
                                    heightFactor: 1,
                                    child: DefaultTextStyle(
                                        style: TextStyle(color: fg, fontWeight: FontWeight.w700,
                                            fontSize: compact ? 13 : 14),
                                        child: IconTheme.merge(
                                            data: IconThemeData(color: fg),
                                            child: child))))))))));
  }
}

ThemeData nikoTheme(Brightness brightness) {
  final light = brightness == Brightness.light;
  final scheme = ColorScheme.fromSeed(
      seedColor: light ? NikoPalette.lightSeed : NikoPalette.darkSeed,
      brightness: brightness);
  final text =
      light ? NikoPalette.lightText : NikoPalette.darkText;
  final muted = light ? NikoPalette.lightMuted : NikoPalette.darkMuted;
  final line = light ? NikoPalette.lightLine : NikoPalette.darkLine;
  final field = light ? NikoPalette.lightField : NikoPalette.darkField;
  final base = ThemeData(
      useMaterial3: true,
      colorScheme: brightness == Brightness.light
          ? scheme.copyWith(
              primary: NikoPalette.lightSeed,
              surface: Colors.white,
              onSurface: text,
              onSurfaceVariant: muted,
              surfaceContainerHighest: const Color(0xFFEEEAFF))
          : scheme.copyWith(
              primary: NikoPalette.darkSeed,
              surface: NikoPalette.darkCard,
              onSurface: text,
              onSurfaceVariant: muted,
              surfaceContainerHighest: const Color(0xFF232936)),
      brightness: brightness);
  OutlineInputBorder border() => OutlineInputBorder(
      borderRadius: BorderRadius.circular(NikoShapes.control),
      borderSide: BorderSide(color: line));
  return base.copyWith(
    // Upstream widgets (the hosted settings page, the connection-manager
    // window) fetch these extensions with non-null assertions; a theme
    // without them renders as a grey window in release builds.
    extensions: <ThemeExtension<dynamic>>[
      (light ? ColorThemeExtension.light : ColorThemeExtension.dark).copyWith(
          border: line, border2: muted, border3: line, divider: line,
          highlight: light ? const Color(0xFFEEEAFF) : const Color(0xFF232936),
          drag_indicator: light ? NikoPalette.lightSeed : NikoPalette.darkSeed,
          shadow: light ? NikoPalette.lightShadow : Colors.black),
      (light ? TabbarTheme.light : TabbarTheme.dark).copyWith(
          selectedTabIconColor: light ? NikoPalette.lightSeed : NikoPalette.darkSeed,
          selectedTextColor: text, unSelectedTextColor: muted,
          selectedIconColor: text, unSelectedIconColor: muted,
          dividerColor: line,
          selectedTabBackgroundColor: field,
          hoverColor: light ? const Color(0xFFEEEAFF) : const Color(0xFF232936)),
    ],
    primaryColor: light ? NikoPalette.lightSeed : NikoPalette.darkSeed,
    scaffoldBackgroundColor:
        light ? const Color(0xFFF3EFFF) : NikoPalette.darkScaffold,
    dividerColor: line,
    textTheme: base.textTheme.apply(bodyColor: text, displayColor: text),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: field,
      border: border(),
      enabledBorder: border(),
      focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(NikoShapes.control),
          borderSide: BorderSide(
              color:
                  light ? NikoPalette.lightSeed : NikoPalette.darkSeed,
              width: 1.6)),
      hintStyle: TextStyle(color: muted.withOpacity(.8)),
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(48, 48),
        tapTargetSize: MaterialTapTargetSize.padded,
        backgroundColor: light ? NikoPalette.lightSeed : NikoPalette.darkSeed,
        foregroundColor: light ? Colors.white : NikoPalette.darkOnPrimary,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(NikoShapes.control)),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        textStyle:
            const TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(48, 48),
        tapTargetSize: MaterialTapTargetSize.padded,
        foregroundColor: light ? NikoPalette.lightSeed : NikoPalette.darkSeed,
        side: BorderSide(color: line),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(NikoShapes.control)),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        minimumSize: const Size(48, 48),
        tapTargetSize: MaterialTapTargetSize.padded,
        foregroundColor: light ? NikoPalette.lightSeed : NikoPalette.darkSeed,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(NikoShapes.control)),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(style: IconButton.styleFrom(
        minimumSize: const Size(48, 48),
        tapTargetSize: MaterialTapTargetSize.padded,
        visualDensity: VisualDensity.standard)),
    chipTheme: base.chipTheme.copyWith(
      backgroundColor: field,
      side: BorderSide(color: line),
      labelStyle: TextStyle(color: muted),
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(NikoShapes.chip)),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
      side: WidgetStatePropertyAll(BorderSide(color: line)),
      shape: WidgetStatePropertyAll(RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(NikoShapes.control))),
      backgroundColor: WidgetStateProperty.resolveWith((states) =>
          states.contains(WidgetState.selected)
              ? (light
                  ? NikoPalette.lightSeed
                  : NikoPalette.darkSeed)
              : field),
      foregroundColor: WidgetStateProperty.resolveWith((states) =>
          states.contains(WidgetState.selected)
              ? (light ? Colors.white : NikoPalette.darkOnPrimary)
              : muted),
    )),
    switchTheme: SwitchThemeData(
      thumbColor: const WidgetStatePropertyAll(Colors.white),
      trackColor: WidgetStateProperty.resolveWith((states) => states
              .contains(WidgetState.selected)
          ? (light ? NikoPalette.lightSeed : NikoPalette.darkSeed)
          : (light ? const Color(0xFFD9D2F0) : const Color(0xFF333B4E))),
    ),
    dialogTheme: DialogTheme(
      backgroundColor: light ? Colors.white : NikoPalette.darkCard,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(NikoShapes.card)),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: light ? const Color(0xFF2A2140) : const Color(0xFFE6E9F0),
        borderRadius: BorderRadius.circular(8),
      ),
      textStyle: TextStyle(
          color: light ? Colors.white : NikoPalette.darkScaffold),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: light ? Colors.white : NikoPalette.darkCard,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(NikoShapes.control)),
    ),
    listTileTheme: ListTileThemeData(
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(NikoShapes.control)),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(NikoShapes.control)),
    ),
  );
}

/// Tabular digits keep long device ids from jittering while editing.
TextStyle nikoIdStyle(BuildContext context,
        {double fontSize = 16, Color? color}) =>
    Theme.of(context).textTheme.titleMedium!.copyWith(
        fontWeight: FontWeight.w700,
        fontSize: fontSize,
        letterSpacing: .4,
        color: color ??
            (nikoIsLight(context)
                ? NikoPalette.lightText
                : NikoPalette.darkSeed),
        fontFeatures: const [FontFeature.tabularFigures()]);
