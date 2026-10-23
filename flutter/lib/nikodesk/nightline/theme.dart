import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/desktop/widgets/tabbar_widget.dart';

import 'tokens.dart';

/// The single entry point for the NikoDesk design system. Material widgets
/// hosted on a design-system page pick the tokens up through this theme;
/// design-system components read [NlColors] from it. [preset] defaults to
/// the one the window loaded ([NlColors.active]).
ThemeData nightlineTheme(Brightness brightness, {NlPreset? preset}) {
  final nl = NlColors.palette(preset ?? NlColors.active, brightness);
  final light = brightness == Brightness.light;
  final softFill = nl.solid(nl.accentSoft, nl.bg);
  final scheme = ColorScheme(
    brightness: brightness,
    primary: nl.accentFill,
    onPrimary: nl.onAccent,
    primaryContainer: softFill,
    onPrimaryContainer: nl.accentText,
    secondary: nl.accent2,
    onSecondary: Colors.white,
    secondaryContainer: softFill,
    onSecondaryContainer: nl.accentText,
    tertiary: nl.ok,
    onTertiary: light ? Colors.white : Colors.black,
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
    labelLarge: t(NlType.s3, FontWeight.w500),
    labelMedium: t(NlType.s2, FontWeight.w500),
    labelSmall: t(NlType.s1, FontWeight.w500),
  );
  final r1 = BorderRadius.circular(NlRadius.r1);
  final r2 = BorderRadius.circular(NlRadius.r2);
  final r3 = BorderRadius.circular(NlRadius.r3);
  final r4 = BorderRadius.circular(NlRadius.r4);
  OutlineInputBorder field(Color color, [double width = 1]) =>
      OutlineInputBorder(
          borderRadius: r2, borderSide: BorderSide(color: color, width: width));
  WidgetStateProperty<Color?> overlay(Color hover) =>
      WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.pressed)) return nl.selected;
        if (states.contains(WidgetState.focused)) return nl.accentSoft;
        if (states.contains(WidgetState.hovered)) return hover;
        return null;
      });
  const control = Size(32, 32);
  final buttonText = t(NlType.s3, FontWeight.w500);
  // Menus and dialogs: a hairline in dark mode, where the drop shadow is
  // lost against the background; light mode relies on the shadow alone.
  final floatingSide =
      light ? BorderSide.none : BorderSide(color: nl.line, width: 1);
  final tooltipFill = light ? const Color(0xF21D1D1F) : const Color(0xF23A3A3D);
  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    fontFamily: NlType.ui,
    fontFamilyFallback: NlType.uiFallback,
    textTheme: text,
    primaryColor: nl.accentFill,
    scaffoldBackgroundColor: nl.bg,
    canvasColor: nl.bg,
    cardColor: nl.surface,
    dividerColor: nl.line,
    disabledColor: nl.fg3,
    hintColor: nl.fg3,
    hoverColor: nl.hover,
    focusColor: nl.accentSoft,
    highlightColor: nl.selected,
    splashColor: Colors.transparent,
    splashFactory: NoSplash.splashFactory,
    materialTapTargetSize: MaterialTapTargetSize.padded,
    visualDensity: VisualDensity.standard,
    pageTransitionsTheme: const PageTransitionsTheme(builders: {
      // Native edge-swipe back on iPad and iPhone.
      TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
      TargetPlatform.android: NlPageTransitionsBuilder(),
      TargetPlatform.macOS: NlPageTransitionsBuilder(),
      TargetPlatform.windows: NlPageTransitionsBuilder(),
      TargetPlatform.linux: NlPageTransitionsBuilder(),
    }),
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
          toastBg: tooltipFill,
          toastText: Colors.white),
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
    tabBarTheme: TabBarTheme(
        labelColor: nl.fg2,
        unselectedLabelColor: nl.fg3,
        indicatorColor: nl.accent,
        dividerColor: nl.line,
        labelStyle: t(NlType.s3, FontWeight.w500),
        unselectedLabelStyle: t(NlType.s3, FontWeight.w400),
        overlayColor: overlay(nl.hover),
        splashFactory: NoSplash.splashFactory),
    dataTableTheme: DataTableThemeData(
        headingTextStyle: t(NlType.s2, FontWeight.w500, nl.fg2)),
    iconTheme: IconThemeData(color: nl.fg2, size: 18),
    appBarTheme: AppBarTheme(
        backgroundColor: nl.bg,
        foregroundColor: nl.fg,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        centerTitle: false,
        titleTextStyle: t(NlType.s5, FontWeight.w600),
        iconTheme: IconThemeData(color: nl.fg2, size: 20)),
    drawerTheme: DrawerThemeData(
        backgroundColor: nl.bg2,
        surfaceTintColor: Colors.transparent,
        scrimColor: nl.scrim,
        shape: const RoundedRectangleBorder()),
    bottomSheetTheme: BottomSheetThemeData(
        // A persistent sheet (the file page's selection bar) draws its own
        // floating surface; modal sheets keep the overlay.
        backgroundColor: Colors.transparent,
        elevation: 0,
        modalBackgroundColor: nl.overlay,
        modalElevation: 1,
        surfaceTintColor: Colors.transparent,
        showDragHandle: true,
        dragHandleColor: nl.line2,
        dragHandleSize: const Size(36, 5),
        modalBarrierColor: nl.scrim,
        shape: const RoundedRectangleBorder(
            borderRadius:
                BorderRadius.vertical(top: Radius.circular(NlRadius.r4)))),
    navigationBarTheme: NavigationBarThemeData(
        backgroundColor: nl.bg2,
        surfaceTintColor: Colors.transparent,
        indicatorColor: nl.accentSoft,
        elevation: 0,
        height: 64,
        labelTextStyle: WidgetStateProperty.resolveWith((states) => t(
            NlType.s1,
            FontWeight.w500,
            states.contains(WidgetState.selected) ? nl.accentText : nl.fg2)),
        iconTheme: WidgetStateProperty.resolveWith((states) => IconThemeData(
            size: 22,
            color: states.contains(WidgetState.selected)
                ? nl.accentText
                : nl.fg2))),
    cardTheme: CardTheme(
        color: nl.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
            borderRadius: r3, side: BorderSide(color: nl.ring))),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: light ? nl.overlay : nl.surface,
      hoverColor: Colors.transparent,
      border: field(nl.line2),
      enabledBorder: field(nl.line2),
      disabledBorder: field(nl.line),
      focusedBorder: field(nl.accent, 1.5),
      errorBorder: field(nl.danger),
      focusedErrorBorder: field(nl.danger, 1.5),
      hintStyle: t(NlType.s3, FontWeight.w400, nl.fg3),
      labelStyle: t(NlType.s3, FontWeight.w400, nl.fg2),
      floatingLabelStyle: t(NlType.s2, FontWeight.w500, nl.accentText),
      helperStyle: t(NlType.s2, FontWeight.w400, nl.fg3),
      errorStyle: t(NlType.s2, FontWeight.w400, nl.dangerText),
      prefixIconColor: nl.fg3,
      suffixIconColor: nl.fg3,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(
          horizontal: NlSpace.s3, vertical: NlSpace.s3),
    ),
    textSelectionTheme: TextSelectionThemeData(
        cursorColor: nl.accent,
        selectionColor: nl.accent.withOpacity(.26),
        selectionHandleColor: nl.accent),
    cupertinoOverrideTheme: NoDefaultCupertinoThemeData(
        brightness: brightness,
        primaryColor: nl.accent,
        scaffoldBackgroundColor: nl.bg,
        barBackgroundColor: nl.bg2),
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
              ? nl.accentFill.withOpacity(.4)
              : states.contains(WidgetState.hovered) ||
                      states.contains(WidgetState.pressed)
                  ? nl.accentHover
                  : nl.accentFill),
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
      shape: WidgetStatePropertyAll(RoundedRectangleBorder(
          borderRadius: r2, side: BorderSide(color: nl.line2))),
      textStyle: WidgetStatePropertyAll(buttonText),
      elevation: const WidgetStatePropertyAll(0),
      backgroundColor: WidgetStatePropertyAll(light ? nl.overlay : nl.surface2),
      foregroundColor: WidgetStatePropertyAll(nl.fg),
      overlayColor: overlay(nl.hover),
      splashFactory: NoSplash.splashFactory,
    )),
    outlinedButtonTheme: OutlinedButtonThemeData(
        style: ButtonStyle(
      minimumSize: const WidgetStatePropertyAll(control),
      padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: NlSpace.s4)),
      shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: r2)),
      side: WidgetStateProperty.resolveWith((states) => BorderSide(
          color: states.contains(WidgetState.disabled) ? nl.line : nl.line2)),
      backgroundColor: WidgetStatePropertyAll(light ? nl.overlay : null),
      textStyle: WidgetStatePropertyAll(buttonText),
      foregroundColor: WidgetStateProperty.resolveWith((states) =>
          states.contains(WidgetState.disabled) ? nl.fg3 : nl.fg),
      overlayColor: overlay(nl.hover),
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
      overlayColor: overlay(nl.hover),
      tapTargetSize: MaterialTapTargetSize.padded,
      splashFactory: NoSplash.splashFactory,
    )),
    chipTheme: ChipThemeData(
      color: WidgetStateProperty.resolveWith((states) =>
          states.contains(WidgetState.selected) ? softFill : nl.surface),
      side: WidgetStateBorderSide.resolveWith((states) => BorderSide(
          color: states.contains(WidgetState.selected)
              ? nl.accent.withOpacity(.45)
              : nl.line2)),
      labelStyle: t(NlType.s2, FontWeight.w500, nl.fg2),
      secondaryLabelStyle: t(NlType.s2, FontWeight.w500, nl.accentText),
      shape: RoundedRectangleBorder(borderRadius: r2),
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
          states.contains(WidgetState.selected)
              ? (light ? nl.overlay : nl.surface2)
              : nl.surface),
      foregroundColor: WidgetStateProperty.resolveWith((states) =>
          states.contains(WidgetState.disabled)
              ? nl.fg3
              : states.contains(WidgetState.selected)
                  ? nl.fg
                  : nl.fg2),
      iconColor: WidgetStateProperty.resolveWith((states) =>
          states.contains(WidgetState.selected) ? nl.fg : nl.fg3),
      overlayColor: overlay(nl.hover),
      splashFactory: NoSplash.splashFactory,
    )),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((states) =>
          states.contains(WidgetState.disabled) ? nl.surface2 : Colors.white),
      trackColor: WidgetStateProperty.resolveWith((states) =>
          states.contains(WidgetState.selected)
              ? (states.contains(WidgetState.disabled)
                  ? nl.accent.withOpacity(.4)
                  : nl.accent)
              : nl.line2),
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
      overlayColor: overlay(nl.hover),
      thumbIcon: const WidgetStatePropertyAll(Icon(null)),
    ),
    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith((states) =>
          states.contains(WidgetState.selected)
              ? nl.accent
              : Colors.transparent),
      checkColor: WidgetStatePropertyAll(nl.onAccent),
      side: BorderSide(color: nl.line2, width: 1.5),
      shape: RoundedRectangleBorder(borderRadius: r1),
      overlayColor: overlay(nl.hover),
    ),
    radioTheme: RadioThemeData(
        fillColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.selected) ? nl.accent : nl.line2),
        overlayColor: overlay(nl.hover)),
    sliderTheme: SliderThemeData(
        activeTrackColor: nl.accent,
        inactiveTrackColor: nl.line2,
        thumbColor: Colors.white,
        overlayColor: nl.accentSoft,
        trackHeight: 4,
        trackShape: const _NlSliderTrack(),
        valueIndicatorColor: tooltipFill,
        valueIndicatorTextStyle:
            NlType.monoText(NlType.s2, color: Colors.white)),
    progressIndicatorTheme: ProgressIndicatorThemeData(
        color: nl.accent,
        linearTrackColor: nl.line,
        linearMinHeight: 3,
        circularTrackColor: Colors.transparent),
    scrollbarTheme: ScrollbarThemeData(
        thickness: const WidgetStatePropertyAll(6),
        thumbColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.hovered) ||
                    states.contains(WidgetState.dragged)
                ? nl.fg3.withOpacity(.55)
                : nl.fg3.withOpacity(.32)),
        radius: const Radius.circular(NlRadius.pill),
        crossAxisMargin: 2,
        mainAxisMargin: 2),
    listTileTheme: ListTileThemeData(
        iconColor: nl.fg2,
        textColor: nl.fg,
        selectedColor: nl.fg,
        selectedTileColor: nl.selected,
        titleTextStyle: t(NlType.s3, FontWeight.w400),
        subtitleTextStyle: t(NlType.s2, FontWeight.w400, nl.fg2),
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
        elevation: 24,
        shadowColor: Colors.black.withOpacity(light ? .35 : .8),
        insetPadding:
            const EdgeInsets.symmetric(horizontal: NlSpace.s6, vertical: NlSpace.s6),
        shape: RoundedRectangleBorder(borderRadius: r4, side: floatingSide),
        titleTextStyle: t(NlType.s5, FontWeight.w600),
        contentTextStyle: t(NlType.s3, FontWeight.w400, nl.fg2)),
    menuTheme: MenuThemeData(
        style: MenuStyle(
            backgroundColor: WidgetStatePropertyAll(nl.overlay),
            surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
            elevation: const WidgetStatePropertyAll(10),
            shadowColor:
                WidgetStatePropertyAll(Colors.black.withOpacity(light ? .3 : .7)),
            padding: const WidgetStatePropertyAll(EdgeInsets.all(NlSpace.s1)),
            shape: WidgetStatePropertyAll(
                RoundedRectangleBorder(borderRadius: r3, side: floatingSide)))),
    menuButtonTheme: MenuButtonThemeData(
        style: ButtonStyle(
      textStyle: WidgetStatePropertyAll(t(NlType.s3)),
      minimumSize: const WidgetStatePropertyAll(Size(160, 30)),
      foregroundColor: WidgetStateProperty.resolveWith((states) =>
          states.contains(WidgetState.disabled) ? nl.fg3 : nl.fg),
      iconColor: WidgetStatePropertyAll(nl.fg2),
      iconSize: const WidgetStatePropertyAll(16),
      overlayColor: overlay(nl.hover),
      shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: r2)),
      splashFactory: NoSplash.splashFactory,
    )),
    popupMenuTheme: PopupMenuThemeData(
        color: nl.overlay,
        surfaceTintColor: Colors.transparent,
        elevation: 10,
        shadowColor: Colors.black.withOpacity(light ? .3 : .7),
        menuPadding: const EdgeInsets.all(NlSpace.s1),
        shape: RoundedRectangleBorder(borderRadius: r3, side: floatingSide),
        textStyle: t(NlType.s3),
        labelTextStyle: WidgetStateProperty.resolveWith((states) => t(
            NlType.s3,
            FontWeight.w400,
            states.contains(WidgetState.disabled) ? nl.fg3 : nl.fg))),
    tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(color: tooltipFill, borderRadius: r2),
        padding: const EdgeInsets.symmetric(
            horizontal: NlSpace.s2, vertical: NlSpace.s1 + 1),
        textStyle: t(NlType.s2, FontWeight.w500, Colors.white),
        waitDuration: const Duration(milliseconds: 500),
        exitDuration: const Duration(milliseconds: 80)),
    // Toasts: a dark pill at the bottom in every preset and mode.
    snackBarTheme: SnackBarThemeData(
        backgroundColor: tooltipFill,
        contentTextStyle: t(NlType.s3, FontWeight.w500, Colors.white),
        actionTextColor: light ? const Color(0xFF6CB4FF) : nl.accentText,
        behavior: SnackBarBehavior.floating,
        elevation: 0,
        insetPadding: const EdgeInsets.fromLTRB(
            NlSpace.s4, NlSpace.s4, NlSpace.s4, NlSpace.s6),
        shape: RoundedRectangleBorder(borderRadius: r3)),
  );
}

/// Desktop and Android page transition: the incoming page fades in while
/// rising 12 px, the outgoing one dims slightly.
class NlPageTransitionsBuilder extends PageTransitionsBuilder {
  const NlPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
      PageRoute<T> route,
      BuildContext context,
      Animation<double> animation,
      Animation<double> secondaryAnimation,
      Widget child) {
    if (NlMotion.reduced(context)) return child;
    final enter = CurvedAnimation(
        parent: animation, curve: NlMotion.ease, reverseCurve: NlMotion.exit);
    final leave = CurvedAnimation(parent: secondaryAnimation, curve: NlMotion.standard);
    return FadeTransition(
        opacity: Tween<double>(begin: 1, end: .92).animate(leave),
        child: FadeTransition(
            opacity: enter,
            child: SlideTransition(
                position: Tween<Offset>(
                        begin: const Offset(0, .015), end: Offset.zero)
                    .animate(enter),
                child: child)));
  }
}

/// The track runs edge to edge: the thumb, not the hover halo, sets the
/// inset, so a slider lines up with the fields and switches around it.
class _NlSliderTrack extends RoundedRectSliderTrackShape {
  const _NlSliderTrack();

  @override
  Rect getPreferredRect(
      {required RenderBox parentBox,
      Offset offset = Offset.zero,
      required SliderThemeData sliderTheme,
      bool isEnabled = false,
      bool isDiscrete = false}) {
    final thumb =
        sliderTheme.thumbShape!.getPreferredSize(isEnabled, isDiscrete).width;
    final height = sliderTheme.trackHeight!;
    final width = parentBox.size.width - thumb;
    return Rect.fromLTWH(offset.dx + thumb / 2,
        offset.dy + (parentBox.size.height - height) / 2,
        width < 0 ? 0 : width, height);
  }
}
