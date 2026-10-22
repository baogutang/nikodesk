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

/// Nightline card for the connection manager's terminal, camera, voice and
/// tunnel panels: a mono label naming the request, the phase beside a status
/// light, then the panel's own text and actions. Panels pass the children
/// they lay out without Nightline, so both paths show the same things.
class NikoCmCapabilityFrame extends StatelessWidget {
  final String label;
  final IconData icon;
  final NlTone tone;
  final Widget title;
  final List<Widget> children;
  const NikoCmCapabilityFrame(
      {super.key,
      required this.label,
      required this.icon,
      required this.tone,
      required this.title,
      required this.children});

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
    const tall = WidgetStatePropertyAll(Size(48, 48));
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
                  Semantics(
                      header: true,
                      child: NlMonoLabel(label,
                          leading: Icon(icon, size: 14, color: nl.fg3))),
                  const SizedBox(height: NlSpace.s3),
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    // Centred on the title's first line when it wraps.
                    Padding(
                        padding: EdgeInsets.only(top: (line - NlLed.size) / 2),
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
                  const SizedBox(height: NlSpace.s3),
                  // Dropdowns take titleMedium and list tiles bodyLarge; in a
                  // card this narrow both read at the body size. Actions are
                  // 48 px tall, as the window's Disconnect is.
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

  /// A small gap between neighbouring blocks the panel did not space.
  static List<Widget> _spaced(List<Widget> children) => [
        for (final (i, child) in children.indexed) ...[
          if (i > 0 && child is! SizedBox && children[i - 1] is! SizedBox)
            const SizedBox(height: NlSpace.s2),
          child,
        ]
      ];
}

class _FrameScope extends InheritedWidget {
  const _FrameScope({required super.child});
  @override
  bool updateShouldNotify(_FrameScope oldWidget) => false;
}
