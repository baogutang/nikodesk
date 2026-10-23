import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'nightline.dart';

/// Below this width a dialog's actions stack, primary first, as
/// [NlDialog]'s do.
const _stackBelow = 440.0;

/// The stock dialog's surface in the NikoDesk build, laid out as [NlDialog]
/// lays out its own: Nightline type and spacing, actions right to left with
/// the primary one last, stacked primary first on a narrow screen. It stays
/// an [AlertDialog], so every caller's content keeps the sizing and
/// scrolling it was written for.
class NikoAlertDialog extends StatelessWidget {
  final Widget? title;
  final EdgeInsetsGeometry? titlePadding;
  final Widget content;
  final BoxConstraints constraints;
  final List<Widget>? actions;
  const NikoAlertDialog(
      {super.key,
      this.title,
      this.titlePadding,
      required this.content,
      required this.constraints,
      this.actions});

  @override
  Widget build(BuildContext context) {
    final actions = this.actions ?? const <Widget>[];
    return AlertDialog(
        scrollable: true,
        title: title,
        titlePadding: titlePadding ??
            const EdgeInsets.fromLTRB(NlSpace.s6, NlSpace.s6, NlSpace.s6, 0),
        content: ConstrainedBox(constraints: constraints, child: content),
        contentPadding: EdgeInsets.fromLTRB(
            NlSpace.s6,
            title == null ? NlSpace.s6 : NlSpace.s3,
            NlSpace.s6,
            actions.isEmpty ? NlSpace.s6 : 0),
        actions: actions.isEmpty ? null : [NikoDialogActions(actions)],
        actionsPadding: const EdgeInsets.fromLTRB(
            NlSpace.s6, NlSpace.s6, NlSpace.s6, NlSpace.s5),
        buttonPadding: EdgeInsets.zero,
        actionsAlignment: MainAxisAlignment.end);
  }
}

/// A dialog's actions: a row ending in the primary one, or on a narrow
/// screen a stack starting with it.
class NikoDialogActions extends StatelessWidget {
  final List<Widget> actions;
  const NikoDialogActions(this.actions, {super.key});

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.sizeOf(context).width < _stackBelow) {
      return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final (i, action) in actions.reversed.indexed) ...[
              if (i > 0) const SizedBox(height: NlSpace.s2),
              action,
            ]
          ]);
    }
    return Wrap(
        alignment: WrapAlignment.end,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: NlSpace.s2,
        runSpacing: NlSpace.s2,
        children: actions);
  }
}

/// Whether a stock dialog button, named by its untranslated [key], is the
/// dialog's main action. Touch builds never showed `isOutline`, so some
/// callers leave Cancel filled; it never leads.
bool nikoDialogPrimary(String key, {required bool isOutline}) =>
    !isOutline && key != 'Cancel';

/// A stock dialog button in the NikoDesk build: text only, in the accent
/// when it is the dialog's main action, full width once the actions stack.
class NikoDialogButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final bool primary;

  /// The danger fill, for a choice that replaces or deletes something.
  final bool danger;
  final bool autofocus;
  const NikoDialogButton(
      {super.key,
      required this.label,
      required this.onPressed,
      required this.primary,
      this.danger = false,
      this.autofocus = false});

  @override
  Widget build(BuildContext context) {
    final stacked = MediaQuery.sizeOf(context).width < _stackBelow;
    if (danger) {
      return NlButton.danger(
          label: label,
          onPressed: onPressed,
          expand: stacked,
          autofocus: autofocus);
    }
    return primary
        ? NlButton(
            label: label,
            onPressed: onPressed,
            expand: stacked,
            autofocus: autofocus)
        : NlButton.ghost(
            label: label,
            onPressed: onPressed,
            expand: stacked,
            autofocus: autofocus);
  }
}

/// The look of a message box's type: the stock box shows an icon for the
/// same types, in the matching tone.
(IconData, NlTone)? _look(String type) {
  if (type.contains('error') || type == 're-input-password') {
    return (NlIcons.circleX, NlTone.danger);
  }
  if (type.contains('success')) return (NlIcons.circleCheck, NlTone.ok);
  if (type == 'wait-uac' || type == 'wait-remote-accept-nook') {
    return (NlIcons.clock, NlTone.warn);
  }
  if (type == 'on-uac' || type == 'on-foreground-elevated') {
    return (NlIcons.shield, NlTone.accent);
  }
  if (type.contains('info')) return (NlIcons.info, NlTone.accent);
  return null;
}

/// The body of a message box: its icon tile, its title and its text, with
/// any web address in the text as a link.
class NikoMsgboxContent extends StatelessWidget {
  final String type;
  final String title;
  final String text;
  const NikoMsgboxContent(
      {super.key, required this.type, required this.title, required this.text});

  @override
  Widget build(BuildContext context) {
    final nl = NlColors.of(context);
    final look = _look(type);
    final tone = switch (look?.$2) {
      NlTone.danger => nl.danger,
      NlTone.ok => nl.ok,
      NlTone.warn => nl.warn,
      _ => nl.accent,
    };
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (look != null) ...[
        NlIconTile(icon: look.$1, color: tone, size: 40),
        const SizedBox(width: NlSpace.s4),
      ],
      Expanded(
          child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
            Padding(
                // Level with the middle of the tile when the title is short.
                padding: EdgeInsets.only(top: look == null ? 0 : 2),
                child: Text(title,
                    style: NlType.text(NlType.s5,
                        weight: FontWeight.w600, color: nl.fg))),
            const SizedBox(height: NlSpace.s2),
            NikoDialogText(text),
          ])),
    ]);
  }
}

final _link = RegExp(r'(https?://[^\s]+)');

/// Selectable dialog text in the Nightline body style; web addresses in it
/// open in the browser.
class NikoDialogText extends StatelessWidget {
  final String text;
  const NikoDialogText(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    final nl = NlColors.of(context);
    final style =
        NlType.text(NlType.s3, color: nl.fg2).copyWith(height: 20 / 13);
    if (!_link.hasMatch(text)) return SelectableText(text, style: style);
    final spans = <TextSpan>[];
    var start = 0;
    for (final match in _link.allMatches(text)) {
      if (match.start > start) {
        spans.add(TextSpan(text: text.substring(start, match.start)));
      }
      final address = match.group(0)!;
      spans.add(TextSpan(
          text: address,
          style: TextStyle(
              color: nl.accentText, decoration: TextDecoration.underline),
          recognizer: TapGestureRecognizer()
            ..onTap = () => launchUrl(
                Uri.parse(address.replaceAll(RegExp(r'[.,;!?]+$'), '')))));
      start = match.end;
    }
    if (start < text.length) spans.add(TextSpan(text: text.substring(start)));
    return SelectableText.rich(TextSpan(style: style, children: spans));
  }
}
