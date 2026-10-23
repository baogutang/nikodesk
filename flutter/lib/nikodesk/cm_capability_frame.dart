import 'package:flutter/material.dart';

import 'nightline.dart';

/// How the connection manager tones a capability phase: amber while it waits
/// for a decision or changes state, green while it runs, red when its
/// shutdown needs recovery, off once it has stopped. A stop that was just
/// requested is still amber; only RecoveryRequired is an alarm.
NlTone nikoCmPhaseTone(String phase) => switch (phase) {
      'Pending' || 'Starting' || 'Revoking' => NlTone.warn,
      'Running' => NlTone.ok,
      'RecoveryRequired' => NlTone.danger,
      _ => NlTone.neutral,
    };

/// A panel button's minimum size: 48 px in the legacy layout; the frame
/// sizes the design system's own (40 px with a pointer, 48 on touch).
Size? nikoCmButtonSize(BuildContext context) =>
    NlColors.maybeOf(context) == null ? const Size(48, 48) : null;

/// Outline for actions that end live access: stop, revoke, end the call.
/// Null outside Nightline, which keeps the panel's own style.
ButtonStyle? nikoCmStopStyle(BuildContext context) {
  final nl = NlColors.maybeOf(context);
  if (nl == null) return null;
  return ButtonStyle(
      foregroundColor: WidgetStateProperty.resolveWith((states) =>
          states.contains(WidgetState.disabled) ? nl.fg3 : nl.dangerText),
      side: WidgetStateProperty.resolveWith((states) => BorderSide(
          color: states.contains(WidgetState.disabled)
              ? nl.line
              : nl.danger.withOpacity(.6))),
      overlayColor: WidgetStatePropertyAll(nl.dangerSoft));
}

/// Card for the connection manager's terminal, camera, voice and tunnel
/// panels: the request's icon and name, the phase beside a status light, then
/// the panel's own text and actions. Panels pass the children they lay out
/// without the design system, so both paths show the same things.
class NikoCmCapabilityFrame extends StatelessWidget {
  final String label;
  final IconData icon;
  final NlTone tone;
  final Widget title;
  final List<Widget> children;

  /// A small action beside the name, such as reading the current state.
  final Widget? action;
  const NikoCmCapabilityFrame(
      {super.key,
      required this.label,
      required this.icon,
      required this.tone,
      required this.title,
      required this.children,
      this.action});

  /// Whether [context] is inside a frame, so a nested panel lays out its
  /// body without a second card.
  static bool contains(BuildContext context) =>
      context.getInheritedWidgetOfExactType<_FrameScope>() != null;

  /// A nested panel's body, spaced as the frame spaces its own.
  static Widget bare(List<Widget> children) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: _spaced(children));

  @override
  Widget build(BuildContext context) {
    final nl = NlColors.of(context);
    final theme = Theme.of(context);
    final body = NlType.text(NlType.s3, color: nl.fg2);
    // The large button height on pointer platforms; touch keeps 48.
    final tall = WidgetStatePropertyAll(
        Size(48, NlLayout.touch(context) ? 48 : NlButton.largeHeight));
    final line = MediaQuery.textScalerOf(context).scale(NlType.s4) *
        NlType.lineHeight(NlType.s4) /
        NlType.s4;
    return SizedBox(
        width: double.infinity,
        child: NlPanel(
            padding: const EdgeInsets.all(NlSpace.s4),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(children: [
                    NlIconTile(icon: icon, color: nl.accent, size: 32),
                    const SizedBox(width: NlSpace.s3),
                    Expanded(
                        child: Semantics(
                            header: true,
                            child: Text(label,
                                style: NlType.text(NlType.s3,
                                    weight: FontWeight.w500, color: nl.fg2)))),
                    if (action != null) ...[
                      const SizedBox(width: NlSpace.s2),
                      action!,
                    ],
                  ]),
                  const SizedBox(height: NlSpace.s3),
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    // Centred on the title's first line when it wraps.
                    Padding(
                        padding:
                            EdgeInsets.only(top: (line - NlLed.dotSize) / 2),
                        child: NlLed(switch (tone) {
                          NlTone.ok => NlLedState.ok,
                          NlTone.warn || NlTone.accent => NlLedState.warn,
                          NlTone.danger => NlLedState.danger,
                          NlTone.neutral => NlLedState.off,
                        })),
                    const SizedBox(width: NlSpace.s2),
                    Expanded(
                        child: DefaultTextStyle.merge(
                            style: NlType.text(NlType.s4,
                                weight: FontWeight.w600, color: nl.fg),
                            child: title)),
                  ]),
                  const SizedBox(height: NlSpace.s4),
                  // Dropdowns take titleMedium and list tiles bodyLarge; in a
                  // card this narrow both read at the body size.
                  Theme(
                      data: theme.copyWith(
                          textTheme: theme.textTheme.copyWith(
                              titleMedium: body.copyWith(color: nl.fg),
                              bodyLarge: body.copyWith(color: nl.fg)),
                          filledButtonTheme: FilledButtonThemeData(
                              style: theme.filledButtonTheme.style
                                  ?.copyWith(minimumSize: tall)),
                          outlinedButtonTheme: OutlinedButtonThemeData(
                              style: theme.outlinedButtonTheme.style
                                  ?.copyWith(minimumSize: tall)),
                          textButtonTheme: TextButtonThemeData(
                              style: theme.textButtonTheme.style
                                  ?.copyWith(minimumSize: tall))),
                      child: DefaultTextStyle.merge(
                          style: body,
                          child: _FrameScope(
                              child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  mainAxisSize: MainAxisSize.min,
                                  children: _spaced(children))))),
                ])));
  }

  /// A gap between neighbouring blocks the panel did not space.
  static List<Widget> _spaced(List<Widget> children) => [
        for (final (i, child) in children.indexed) ...[
          if (i > 0 && child is! SizedBox && children[i - 1] is! SizedBox)
            const SizedBox(height: NlSpace.s3),
          child,
        ]
      ];
}

/// A capability panel's buttons: in the design system one full-width stack in
/// the order the panel lists them, the main action first; elsewhere the
/// wrapping row the panels used before.
class NikoCmActions extends StatelessWidget {
  final List<Widget> children;

  /// The wrapping row's run spacing; the stack always uses its own.
  final double runSpacing;
  const NikoCmActions(
      {super.key, required this.children, this.runSpacing = 8});

  @override
  Widget build(BuildContext context) {
    if (NlColors.maybeOf(context) == null) {
      return Wrap(spacing: 8, runSpacing: runSpacing, children: children);
    }
    return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (i, child) in children.indexed) ...[
            if (i > 0) const SizedBox(height: NlSpace.s2),
            child,
          ]
        ]);
  }
}

class _FrameScope extends InheritedWidget {
  const _FrameScope({required super.child});
  @override
  bool updateShouldNotify(_FrameScope oldWidget) => false;
}
