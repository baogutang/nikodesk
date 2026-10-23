import 'package:flutter/material.dart';

import 'nightline.dart';

/// A run of settings rows under an optional title. Rows sit flat on the
/// page with hairlines between them, so a settings page reads like a
/// document rather than a stack of cards.
class NikoSettingsGroup extends StatelessWidget {
  final String? title;
  final String? description;
  final Widget? trailing;
  final List<Widget> children;

  /// Space after the group; a page uses the default, a panel less.
  final double bottom;

  const NikoSettingsGroup(
      {super.key,
      this.title,
      this.description,
      this.trailing,
      this.bottom = NlSpace.s8,
      required this.children});

  @override
  Widget build(BuildContext context) {
    final nl = NlColors.of(context);
    return Padding(
        padding: EdgeInsets.only(bottom: bottom),
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (title != null || trailing != null)
                Row(children: [
                  Expanded(
                      child: Semantics(
                          header: true,
                          child: Text(title ?? '',
                              style: NlType.text(NlType.s3,
                                  weight: FontWeight.w600, color: nl.fg)))),
                  if (trailing != null) trailing!,
                ]),
              if (description != null)
                Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(description!,
                        style: NlType.text(NlType.s2, color: nl.fg2))),
              if (title != null || description != null || trailing != null)
                const SizedBox(height: NlSpace.s1),
              for (var i = 0; i < children.length; i++) ...[
                if (i > 0) Container(height: 1, color: nl.line),
                children[i],
              ],
            ]));
  }
}

/// One setting: what it is and does on the left, its control on the
/// right. [below] holds what belongs to the setting but not on its line:
/// a status note, an error with a way to retry, or extra fields. On a
/// narrow page the control moves under the text.
class NikoSettingRow extends StatelessWidget {
  final String title;
  final String? description;
  final Widget? leading;
  final Widget? trailing;
  final Widget? below;
  final bool busy;

  /// Makes the whole row a button that opens something, with a chevron.
  final VoidCallback? onTap;

  const NikoSettingRow(
      {super.key,
      required this.title,
      this.description,
      this.leading,
      this.trailing,
      this.below,
      this.busy = false,
      this.onTap});

  @override
  Widget build(BuildContext context) {
    final nl = NlColors.of(context);
    final touch = NlLayout.touch(context);
    return LayoutBuilder(builder: (context, box) {
      // A switch is narrow enough to stay beside the text on any width.
      final stack = trailing != null &&
          trailing is! NlSwitch &&
          onTap == null &&
          box.maxWidth < 460;
      final text = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(title,
                style: NlType.text(touch ? NlType.s4 : NlType.s3,
                    weight: FontWeight.w500, color: nl.fg)),
            if (description != null)
              Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(description!,
                      style: NlType.text(NlType.s2, color: nl.fg2))),
          ]);
      final control = Row(mainAxisSize: MainAxisSize.min, children: [
        if (busy) ...[
          const NlSpinner(size: 14),
          if (trailing != null) const SizedBox(width: NlSpace.s3),
        ],
        if (trailing != null) Flexible(child: trailing!),
        if (onTap != null) ...[
          const SizedBox(width: NlSpace.s2),
          Icon(NlIcons.chevronRight, size: 16, color: nl.fg3),
        ],
      ]);
      final content = Padding(
          padding:
              EdgeInsets.symmetric(vertical: touch ? NlSpace.s4 : NlSpace.s3),
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (stack)
                  // The control stays on the title's line when both fit
                  // and wraps under the text when they do not.
                  Wrap(
                      alignment: WrapAlignment.spaceBetween,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: NlSpace.s4,
                      runSpacing: NlSpace.s3,
                      children: [
                        if (leading == null)
                          text
                        else
                          Row(mainAxisSize: MainAxisSize.min, children: [
                            leading!,
                            const SizedBox(width: NlSpace.s3),
                            Flexible(child: text),
                          ]),
                        control,
                      ])
                else
                  Row(children: [
                    if (leading != null) ...[
                      leading!,
                      const SizedBox(width: NlSpace.s3),
                    ],
                    Expanded(child: text),
                    if (busy || trailing != null || onTap != null) ...[
                      const SizedBox(width: NlSpace.s5),
                      // Bounded so a long value wraps instead of pushing
                      // the title out of the row.
                      ConstrainedBox(
                          constraints:
                              BoxConstraints(maxWidth: box.maxWidth * .6),
                          child: control),
                    ],
                  ]),
                if (below != null) ...[
                  const SizedBox(height: NlSpace.s2),
                  below!,
                ],
              ]));
      if (onTap == null) return content;
      return NlPressable(
          onTap: onTap,
          pressScale: 1,
          builder: (context, states) => Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Positioned(
                        left: -NlSpace.s2,
                        right: -NlSpace.s2,
                        top: 2,
                        bottom: 2,
                        child: AnimatedContainer(
                            duration: NlMotion.of(context, NlMotion.instant),
                            decoration: BoxDecoration(
                                color: states.contains(WidgetState.pressed)
                                    ? nl.selected
                                    : states.contains(WidgetState.hovered)
                                        ? nl.hover
                                        : Colors.transparent,
                                borderRadius:
                                    BorderRadius.circular(NlRadius.r2),
                                boxShadow: states.contains(WidgetState.focused)
                                    ? nl.focusRing
                                    : null))),
                    content,
                  ]));
    });
  }
}

/// A row that opens in place to show more about it, such as a short
/// guide. [toggleKey] goes on the title, which is what a test taps.
class NikoSettingDisclosure extends StatefulWidget {
  final String title;
  final String? description;
  final List<Widget> children;
  final Key? toggleKey;

  const NikoSettingDisclosure(
      {super.key,
      required this.title,
      this.description,
      required this.children,
      this.toggleKey});

  @override
  State<NikoSettingDisclosure> createState() => _NikoSettingDisclosureState();
}

class _NikoSettingDisclosureState extends State<NikoSettingDisclosure> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final nl = NlColors.of(context);
    final touch = NlLayout.touch(context);
    final duration = NlMotion.of(context, NlMotion.base);
    final header = NlPressable(
        onTap: () => setState(() => _open = !_open),
        pressScale: 1,
        builder: (context, states) => Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned(
                      left: -NlSpace.s2,
                      right: -NlSpace.s2,
                      top: 2,
                      bottom: 2,
                      child: AnimatedContainer(
                          duration: NlMotion.of(context, NlMotion.instant),
                          decoration: BoxDecoration(
                              color: states.contains(WidgetState.pressed)
                                  ? nl.selected
                                  : states.contains(WidgetState.hovered)
                                      ? nl.hover
                                      : Colors.transparent,
                              borderRadius:
                                  BorderRadius.circular(NlRadius.r2),
                              boxShadow: states.contains(WidgetState.focused)
                                  ? nl.focusRing
                                  : null))),
                  Padding(
                      padding: EdgeInsets.symmetric(
                          vertical: touch ? NlSpace.s4 : NlSpace.s3),
                      child: Row(children: [
                        Expanded(
                            child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                              Text(widget.title,
                                  key: widget.toggleKey,
                                  style: NlType.text(
                                      touch ? NlType.s4 : NlType.s3,
                                      weight: FontWeight.w500,
                                      color: nl.fg)),
                              if (widget.description != null)
                                Padding(
                                    padding: const EdgeInsets.only(top: 2),
                                    child: Text(widget.description!,
                                        style: NlType.text(NlType.s2,
                                            color: nl.fg2))),
                            ])),
                        const SizedBox(width: NlSpace.s3),
                        AnimatedRotation(
                            turns: _open ? .5 : 0,
                            duration: duration,
                            curve: NlMotion.standard,
                            child: Icon(NlIcons.chevronDown,
                                size: 16, color: nl.fg3)),
                      ])),
                ]));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Semantics(expanded: _open, child: header),
      AnimatedSize(
          duration: duration,
          curve: NlMotion.standard,
          alignment: Alignment.topCenter,
          child: _open
              ? Padding(
                  padding: EdgeInsets.only(
                      bottom: touch ? NlSpace.s4 : NlSpace.s3),
                  child: DefaultTextStyle.merge(
                      style: NlType.text(NlType.s3, color: nl.fg2)
                          .copyWith(height: 20 / 13),
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (var i = 0; i < widget.children.length; i++) ...[
                              if (i > 0) const SizedBox(height: NlSpace.s2),
                              widget.children[i],
                            ],
                          ])))
              : const SizedBox(width: double.infinity)),
    ]);
  }
}

/// A short line under a setting: its live state, a caveat, or an error
/// with a way to retry.
class NikoSettingNote extends StatelessWidget {
  final String text;
  final NlTone tone;
  final String? actionLabel;
  final VoidCallback? onAction;
  final Key? textKey;

  const NikoSettingNote(this.text,
      {super.key,
      this.tone = NlTone.neutral,
      this.actionLabel,
      this.onAction,
      this.textKey});

  @override
  Widget build(BuildContext context) {
    final nl = NlColors.of(context);
    final (IconData icon, Color ink) = switch (tone) {
      NlTone.danger => (NlIcons.circleAlert, nl.dangerText),
      NlTone.warn => (NlIcons.triangleAlert, nl.warnText),
      NlTone.ok => (NlIcons.circleCheck, nl.okText),
      NlTone.accent => (NlIcons.info, nl.accentText),
      NlTone.neutral => (NlIcons.info, nl.fg3),
    };
    return Semantics(
        liveRegion: tone == NlTone.danger || tone == NlTone.warn,
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(icon, size: 14, color: ink)),
          const SizedBox(width: NlSpace.s2),
          Expanded(
              child: Text(text,
                  key: textKey,
                  style: NlType.text(NlType.s2,
                      color: tone == NlTone.neutral ? nl.fg2 : ink))),
          if (actionLabel != null) ...[
            const SizedBox(width: NlSpace.s2),
            NlButton.quiet(small: true, onPressed: onAction, label: actionLabel!),
          ],
        ]));
  }
}

/// A read-only value on the right of a setting row, in mono when it is an
/// address or a key.
class NikoSettingValue extends StatelessWidget {
  final String value;
  final bool mono;
  final Widget? leading;

  const NikoSettingValue(this.value,
      {super.key, this.mono = false, this.leading});

  @override
  Widget build(BuildContext context) {
    final nl = NlColors.of(context);
    final style = mono
        ? NlType.monoText(NlType.s2, color: nl.fg2)
        : NlType.text(NlType.s3, color: nl.fg2);
    return ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 320),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (leading != null) ...[leading!, const SizedBox(width: NlSpace.s2)],
          Flexible(
              child: mono
                  ? SelectableText(value,
                      maxLines: 1, textAlign: TextAlign.end, style: style)
                  : Text(value,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.end,
                      style: style)),
        ]));
  }
}
