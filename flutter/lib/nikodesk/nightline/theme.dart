import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/desktop/widgets/tabbar_widget.dart';

import 'tokens.dart';

/// The single entry point for the Nightline design system. Material widgets
/// hosted on a Nightline page pick the tokens up through this theme; Nightline
/// components read [NlColors] from it.
ThemeData nightlineTheme(Brightness brightness) {
  final nl = NlColors.forBrightness(brightness);
  final light = brightness == Brightness.light;
  final accentFill = nl.solid(nl.accentSoft);
  final scheme = ColorScheme(
    brightness: brightness,
    primary: nl.accent,
    onPrimary: nl.onAccent,
    primaryContainer: accentFill,
    onPrimaryContainer: nl.accentText,
    secondary: nl.accent2,
    onSecondary: light ? Colors.white : nl.onAccent,
    secondaryContainer: accentFill,
    onSecondaryContainer: nl.accentText,
    tertiary: nl.ok,
    onTertiary: light ? Colors.white : nl.onAccent,
    error: nl.danger,
    onError: nl.onDanger,
    errorContainer: nl.solid(nl.dangerSoft),
    onErrorContainer: nl.dangerText,
    // Upstream pages still paint window backgrounds from the deprecated
    // `background`; without it they fall back to the lighter surface.
    // ignore: deprecated_member_use
    background: nl.bg,
    // ignore: deprecated_member_use
    onBackground: nl.fg,
    surface: nl.surface,
    onSurface: nl.fg,
    onSurfaceVariant: nl.fg2,
    surfaceContainerLowest: nl.bg,
    surfaceContainerLow: nl.bg2,
    surfaceContainer: nl.surface,
    surfaceContainerHigh: nl.surface2,
    surfaceContainerHighest: nl.surface2,
    outline: nl.line2,
    outlineVariant: nl.line,
    shadow: Colors.black,
    scrim: nl.scrim,
    inverseSurface: nl.fg,
    onInverseSurface: nl.bg,
    inversePrimary: nl.accentText,
    surfaceTint: Colors.transparent,
  );
  TextStyle t(double size, [FontWeight weight = FontWeight.w400, Color? color]) =>
      NlType.text(size, weight: weight, color: color ?? nl.fg);
  final text = TextTheme(
    displayLarge: t(NlType.s7, FontWeight.w600),
    displayMedium: t(NlType.s7, FontWeight.w600),
    displaySmall: t(NlType.s7, FontWeight.w600),
    headlineLarge: t(NlType.s7, FontWeight.w600),
    headlineMedium: t(NlType.s6, FontWeight.w600),
    headlineSmall: t(NlType.s6, FontWeight.w600),
    titleLarge: t(NlType.s6, FontWeight.w600),
    titleMedium: t(NlType.s5, FontWeight.w600),
    titleSmall: t(NlType.s4, FontWeight.w600),
    bodyLarge: t(NlType.s4),
    bodyMedium: t(NlType.s3),
    bodySmall: t(NlType.s2, FontWeight.w400, nl.fg2),
    labelLarge: t(NlType.s3, FontWeight.w600),
    labelMedium: t(NlType.s2, FontWeight.w500),
    labelSmall: t(NlType.s1, FontWeight.w500),
  );
  final r1 = BorderRadius.circular(NlRadius.r1);
  final r2 = BorderRadius.circular(NlRadius.r2);
  final r3 = BorderRadius.circular(NlRadius.r3);
  OutlineInputBorder field(Color color, [double width = 1]) =>
      OutlineInputBorder(
          borderRadius: r2, borderSide: BorderSide(color: color, width: width));
  WidgetStateProperty<Color?> overlay(Color hover) =>
      WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.focused)) return nl.accentSoft;
        if (states.contains(WidgetState.hovered) ||
            states.contains(WidgetState.pressed)) {
          return hover;
        }
        return null;
      });
  const control = Size(32, 32);
  final buttonText = t(NlType.s3, FontWeight.w600);
  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    fontFamily: NlType.ui,
    fontFamilyFallback: NlType.uiFallback,
    textTheme: text,
    primaryColor: nl.accent,
    scaffoldBackgroundColor: nl.bg,
    canvasColor: nl.bg,
    cardColor: nl.surface,
    dividerColor: nl.line,
    disabledColor: nl.fg3,
    hintColor: nl.fg3,
    hoverColor: nl.surface2.withOpacity(.7),
    focusColor: nl.accentSoft,
    highlightColor: nl.line.withOpacity(.5),
    splashColor: Colors.transparent,
    splashFactory: NoSplash.splashFactory,
    materialTapTargetSize: MaterialTapTargetSize.padded,
    visualDensity: VisualDensity.standard,
    // Upstream pages hosted in the shell (advanced settings, connection
    // manager) read these with non-null assertions.
    extensions: <ThemeExtension<dynamic>>[
      nl,
      (light ? ColorThemeExtension.light : ColorThemeExtension.dark).copyWith(
          border: nl.line,
          border2: nl.line2,
          border3: nl.line,
          divider: nl.line,
          highlight: nl.surface2,
          drag_indicator: nl.accent,
          shadow: Colors.black,
          toastBg: NlColors.dark.bg,
          toastText: NlColors.dark.fg),
      (light ? TabbarTheme.light : TabbarTheme.dark).copyWith(
          selectedTabIconColor: nl.accentText,
          unSelectedTabIconColor: nl.fg3,
          selectedTextColor: nl.fg,
          unSelectedTextColor: nl.fg2,
          selectedIconColor: nl.fg,
          unSelectedIconColor: nl.fg2,
          dividerColor: nl.line,
          hoverColor: nl.surface2,
          selectedTabBackgroundColor: nl.surface2),
    ],
    dividerTheme: DividerThemeData(color: nl.line, thickness: 1, space: 1),
    // Upstream panes (file transfer, connection manager) tint their SVG
    // icons with the tab label colour; without it the icons draw black.
    tabBarTheme: TabBarTheme(labelColor: nl.fg2, unselectedLabelColor: nl.fg3),
    // Column headers read like the draft's table heads.
    dataTableTheme: DataTableThemeData(
        headingTextStyle: NlType.monoText(NlType.s1,
                weight: FontWeight.w500, color: nl.fg3)
            .copyWith(letterSpacing: NlType.s1 * NlType.labelTracking)),
    iconTheme: IconThemeData(color: nl.fg2, size: 18),
    appBarTheme: AppBarTheme(
        backgroundColor: nl.bg,
        foregroundColor: nl.fg,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        titleTextStyle: t(NlType.s5, FontWeight.w600),
        iconTheme: IconThemeData(color: nl.fg2)),
    drawerTheme: DrawerThemeData(
        backgroundColor: nl.bg2,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder()),
    cardTheme: CardTheme(
        color: nl.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
            borderRadius: r3, side: BorderSide(color: nl.ring))),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: nl.surface,
      border: field(nl.line),
      enabledBorder: field(nl.line),
      disabledBorder: field(nl.line.withOpacity(.5)),
      focusedBorder: field(nl.accent),
      errorBorder: field(nl.danger),
      focusedErrorBorder: field(nl.danger, 1.5),
      hintStyle: t(NlType.s3, FontWeight.w400, nl.fg3),
      labelStyle: t(NlType.s3, FontWeight.w400, nl.fg2),
      floatingLabelStyle: t(NlType.s2, FontWeight.w500, nl.accentText),
      helperStyle: t(NlType.s2, FontWeight.w400, nl.fg3),
      errorStyle: t(NlType.s2, FontWeight.w400, nl.dangerText),
      prefixIconColor: nl.fg3,
      suffixIconColor: nl.fg3,
      contentPadding: const EdgeInsets.symmetric(
          horizontal: NlSpace.s3, vertical: NlSpace.s3),
    ),
    textSelectionTheme: TextSelectionThemeData(
        cursorColor: nl.accent,
        selectionColor: nl.accent.withOpacity(.28),
        selectionHandleColor: nl.accent),
    filledButtonTheme: FilledButtonThemeData(
        style: ButtonStyle(
      minimumSize: const WidgetStatePropertyAll(control),
      padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: NlSpace.s4)),
      shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: r2)),
      textStyle: WidgetStatePropertyAll(buttonText),
      elevation: const WidgetStatePropertyAll(0),
      backgroundColor: WidgetStateProperty.resolveWith((states) =>
          states.contains(WidgetState.disabled)
              ? nl.accent.withOpacity(.4)
              : states.contains(WidgetState.hovered)
                  ? Color.lerp(nl.accent, nl.fg, .08)
                  : nl.accent),
      foregroundColor: WidgetStateProperty.resolveWith((states) =>
          states.contains(WidgetState.disabled)
              ? nl.onAccent.withOpacity(.6)
              : nl.onAccent),
      overlayColor: const WidgetStatePropertyAll(Colors.transparent),
      tapTargetSize: MaterialTapTargetSize.padded,
      splashFactory: NoSplash.splashFactory,
    )),
    elevatedButtonTheme: ElevatedButtonThemeData(
        style: ButtonStyle(
      minimumSize: const WidgetStatePropertyAll(control),
      shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: r2)),
      textStyle: WidgetStatePropertyAll(buttonText),
      elevation: const WidgetStatePropertyAll(0),
      backgroundColor: WidgetStatePropertyAll(nl.surface2),
      foregroundColor: WidgetStatePropertyAll(nl.fg),
      overlayColor: overlay(nl.line),
      splashFactory: NoSplash.splashFactory,
    )),
    outlinedButtonTheme: OutlinedButtonThemeData(
        style: ButtonStyle(
      minimumSize: const WidgetStatePropertyAll(control),
      padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: NlSpace.s4)),
      shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: r2)),
      side: WidgetStateProperty.resolveWith((states) => BorderSide(
          color: states.contains(WidgetState.disabled)
              ? nl.line
              : nl.line2)),
      textStyle: WidgetStatePropertyAll(buttonText),
      foregroundColor: WidgetStateProperty.resolveWith((states) =>
          states.contains(WidgetState.disabled) ? nl.fg3 : nl.fg),
      overlayColor: overlay(nl.surface2),
      tapTargetSize: MaterialTapTargetSize.padded,
      splashFactory: NoSplash.splashFactory,
    )),
    textButtonTheme: TextButtonThemeData(
        style: ButtonStyle(
      minimumSize: const WidgetStatePropertyAll(control),
      shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: r2)),
      textStyle: WidgetStatePropertyAll(buttonText),
      foregroundColor: WidgetStateProperty.resolveWith((states) =>
          states.contains(WidgetState.disabled) ? nl.fg3 : nl.accentText),
      overlayColor: overlay(nl.accentSoft),
      tapTargetSize: MaterialTapTargetSize.padded,
      splashFactory: NoSplash.splashFactory,
    )),
    iconButtonTheme: IconButtonThemeData(
        style: ButtonStyle(
      shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: r2)),
      foregroundColor: WidgetStateProperty.resolveWith((states) =>
          states.contains(WidgetState.disabled)
              ? nl.fg3.withOpacity(.5)
              : states.contains(WidgetState.hovered)
                  ? nl.fg
                  : nl.fg2),
      overlayColor: overlay(nl.surface2),
      tapTargetSize: MaterialTapTargetSize.padded,
      splashFactory: NoSplash.splashFactory,
    )),
    chipTheme: ChipThemeData(
      color: WidgetStateProperty.resolveWith((states) =>
          states.contains(WidgetState.selected) ? accentFill : nl.surface),
      side: WidgetStateBorderSide.resolveWith((states) => BorderSide(
          color: states.contains(WidgetState.selected)
              ? nl.accent.withOpacity(.45)
              : nl.line2)),
      labelStyle: t(NlType.s2, FontWeight.w500, nl.fg2),
      secondaryLabelStyle: t(NlType.s2, FontWeight.w500, nl.accentText),
      shape: RoundedRectangleBorder(borderRadius: r1),
      showCheckmark: false,
      checkmarkColor: nl.accentText,
      iconTheme: IconThemeData(color: nl.fg2, size: 14),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
      minimumSize: const WidgetStatePropertyAll(control),
      shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: r2)),
      side: WidgetStatePropertyAll(BorderSide(color: nl.line)),
      textStyle: WidgetStatePropertyAll(t(NlType.s2, FontWeight.w500)),
      backgroundColor: WidgetStateProperty.resolveWith((states) =>
          states.contains(WidgetState.selected) ? accentFill : nl.surface),
      foregroundColor: WidgetStateProperty.resolveWith((states) =>
          states.contains(WidgetState.disabled)
              ? nl.fg3
              : states.contains(WidgetState.selected)
                  ? nl.accentText
                  : nl.fg2),
      iconColor: WidgetStateProperty.resolveWith((states) =>
          states.contains(WidgetState.selected) ? nl.accentText : nl.fg3),
      overlayColor: overlay(nl.surface2),
      splashFactory: NoSplash.splashFactory,
    )),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((states) =>
          states.contains(WidgetState.selected) ? nl.onAccent : nl.fg2),
      trackColor: WidgetStateProperty.resolveWith((states) =>
          states.contains(WidgetState.selected) ? nl.accent : nl.line2),
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
    ),
    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith((states) =>
          states.contains(WidgetState.selected)
              ? nl.accent
              : Colors.transparent),
      checkColor: WidgetStatePropertyAll(nl.onAccent),
      side: BorderSide(color: nl.fg3, width: 1.5),
      shape: RoundedRectangleBorder(borderRadius: r1),
    ),
    radioTheme: RadioThemeData(
        fillColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.selected) ? nl.accent : nl.fg3)),
    sliderTheme: SliderThemeData(
        activeTrackColor: nl.accent,
        inactiveTrackColor: nl.line2,
        thumbColor: nl.accent,
        overlayColor: nl.accentSoft,
        trackHeight: 3,
        valueIndicatorColor: nl.overlay,
        valueIndicatorTextStyle: NlType.monoText(NlType.s2, color: nl.fg)),
    progressIndicatorTheme: ProgressIndicatorThemeData(
        color: nl.accent,
        linearTrackColor: nl.line,
        circularTrackColor: Colors.transparent),
    scrollbarTheme: ScrollbarThemeData(
        thumbColor: WidgetStatePropertyAll(nl.line2),
        radius: const Radius.circular(NlRadius.pill)),
    listTileTheme: ListTileThemeData(
        iconColor: nl.fg2,
        textColor: nl.fg,
        shape: RoundedRectangleBorder(borderRadius: r2)),
    expansionTileTheme: ExpansionTileThemeData(
        iconColor: nl.fg2,
        collapsedIconColor: nl.fg3,
        textColor: nl.fg,
        collapsedTextColor: nl.fg,
        shape: const Border(),
        collapsedShape: const Border()),
    dialogTheme: DialogTheme(
        backgroundColor: nl.overlay,
        surfaceTintColor: Colors.transparent,
        elevation: 12,
        shadowColor: Colors.black,
        shape: RoundedRectangleBorder(
            borderRadius: r3, side: BorderSide(color: nl.line)),
        titleTextStyle: t(NlType.s5, FontWeight.w600),
        contentTextStyle: t(NlType.s3, FontWeight.w400, nl.fg2)),
    menuTheme: MenuThemeData(
        style: MenuStyle(
            backgroundColor: WidgetStatePropertyAll(nl.overlay),
            surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
            elevation: const WidgetStatePropertyAll(8),
            shadowColor: const WidgetStatePropertyAll(Colors.black),
            shape: WidgetStatePropertyAll(RoundedRectangleBorder(
                borderRadius: r3, side: BorderSide(color: nl.line))))),
    menuButtonTheme: MenuButtonThemeData(
        style: ButtonStyle(
      textStyle: WidgetStatePropertyAll(t(NlType.s3)),
      foregroundColor: WidgetStateProperty.resolveWith((states) =>
          states.contains(WidgetState.disabled) ? nl.fg3 : nl.fg),
      iconColor: WidgetStatePropertyAll(nl.fg2),
      overlayColor: overlay(nl.surface2),
      shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: r1)),
      splashFactory: NoSplash.splashFactory,
    )),
    popupMenuTheme: PopupMenuThemeData(
        color: nl.overlay,
        surfaceTintColor: Colors.transparent,
        elevation: 8,
        shadowColor: Colors.black,
        shape: RoundedRectangleBorder(
            borderRadius: r3, side: BorderSide(color: nl.line)),
        textStyle: t(NlType.s3),
        labelTextStyle: WidgetStateProperty.resolveWith((states) => t(
            NlType.s3,
            FontWeight.w400,
            states.contains(WidgetState.disabled) ? nl.fg3 : nl.fg))),
    tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
            color: light ? nl.fg : Colors.black,
            borderRadius: r1,
            border: light ? null : Border.all(color: const Color(0x1AFFFFFF))),
        textStyle:
            t(NlType.s2, FontWeight.w400, light ? nl.bg : NlColors.dark.fg),
        waitDuration: const Duration(milliseconds: 400)),
    // Toasts stay dark in both modes, as in the draft.
    snackBarTheme: SnackBarThemeData(
        backgroundColor: NlColors.dark.bg,
        contentTextStyle: t(NlType.s3, FontWeight.w400, NlColors.dark.fg),
        actionTextColor: NlColors.dark.accentText,
        behavior: SnackBarBehavior.floating,
        elevation: 8,
        shape: RoundedRectangleBorder(
            borderRadius: r2,
            side: const BorderSide(color: Color(0x2E7FC8FF)))),
  );
}
