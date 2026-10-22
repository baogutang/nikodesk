import 'package:flutter/material.dart';

import 'nightline.dart';
import 'ui.dart';

/// Nightline pieces for the hosted upstream settings page (高级设置). The
/// shared helpers in desktop_setting_page.dart hand over to these in the
/// NikoDesk build only, so all five tabs share the look of the NikoDesk
/// settings page; other builds keep the upstream layout.

/// A settings group: mono label, then its rows, on a resting panel.
class NikoSettingsCard extends StatelessWidget {
  final String title;
  final List<Widget> children;
  final List<Widget>? titleSuffix;
  const NikoSettingsCard(
      {super.key,
      required this.title,
      required this.children,
      this.titleSuffix});

  @override
  Widget build(BuildContext context) => Padding(
      padding: const EdgeInsets.fromLTRB(
          NlSpace.s6, NlSpace.s4, NlSpace.s6, 0),
      child: Align(
          alignment: Alignment.topLeft,
          child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 680),
              child: NlPanel(
                  padding: const EdgeInsets.fromLTRB(
                      NlSpace.s5, NlSpace.s4, NlSpace.s5, NlSpace.s4),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(children: [
                          Expanded(child: NlMonoLabel(title)),
                          ...?titleSuffix,
                        ]),
                        const SizedBox(height: NlSpace.s2),
                        for (final child in children)
                          Padding(
                              padding: const EdgeInsets.only(top: NlSpace.s1),
                              child: child),
                      ])))));
}

/// Explanatory text above a tab's cards, aligned and measured like them.
class NikoSettingsNote extends StatelessWidget {
  final String text;
  const NikoSettingsNote(this.text, {super.key});

  @override
  Widget build(BuildContext context) => Padding(
      padding: const EdgeInsets.fromLTRB(
          NlSpace.s6, NlSpace.s4, NlSpace.s6, 0),
      child: Align(
          alignment: Alignment.topLeft,
          child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 680),
              child: Text(text,
                  style: NlType.text(NlType.s3,
                      color: NlColors.of(context).fg2)))));
}

/// An on/off option: label on the left, switch on the right; the whole row
/// toggles. [checkedIcon] is shown next to the switch while it is on.
class NikoSettingsToggle extends StatelessWidget {
  final String label;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final Widget? checkedIcon;
  const NikoSettingsToggle(
      {super.key,
      required this.label,
      required this.value,
      required this.onChanged,
      this.checkedIcon});

  @override
  Widget build(BuildContext context) {
    final nl = NlColors.of(context);
    final enabled = onChanged != null;
    return MergeSemantics(
        child: InkWell(
            borderRadius: BorderRadius.circular(NlRadius.r2),
            onTap: enabled ? () => onChanged!(!value) : null,
            child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 40),
                child: Row(children: [
                  Expanded(
                      child: Text(label,
                          style: NlType.text(NlType.s3,
                              color: enabled ? nl.fg : nl.fg3))),
                  if (value && checkedIcon != null) ...[
                    checkedIcon!,
                    const SizedBox(width: NlSpace.s2),
                  ],
                  Switch(value: value, onChanged: onChanged),
                ]))));
  }
}

/// One choice of a radio group, as a compact row.
class NikoSettingsRadio<T> extends StatelessWidget {
  final T value;
  final T groupValue;
  final String label;
  final ValueChanged<T>? onChanged;
  const NikoSettingsRadio(
      {super.key,
      required this.value,
      required this.groupValue,
      required this.label,
      required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final nl = NlColors.of(context);
    final enabled = onChanged != null;
    final selected = value == groupValue;
    return MergeSemantics(
        child: InkWell(
            borderRadius: BorderRadius.circular(NlRadius.r2),
            onTap: enabled ? () => onChanged!(value) : null,
            child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 36),
                child: Row(children: [
                  Radio<T>(
                      value: value,
                      groupValue: groupValue,
                      visualDensity: VisualDensity.compact,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      onChanged: enabled
                          ? (choice) {
                              if (choice != null) onChanged!(choice);
                            }
                          : null),
                  const SizedBox(width: NlSpace.s2),
                  Expanded(
                      child: Text(label,
                          style: NlType.text(NlType.s3,
                              weight: selected ? FontWeight.w500 : FontWeight.w400,
                              color: !enabled
                                  ? nl.fg3
                                  : selected
                                      ? nl.fg
                                      : nl.fg2))),
                ]))));
  }
}

/// A card action. Sub-options are indented under the option they belong to.
class NikoSettingsButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final String? tip;
  final bool indent;
  const NikoSettingsButton(
      {super.key,
      required this.label,
      required this.onPressed,
      this.tip,
      this.indent = false});

  @override
  Widget build(BuildContext context) {
    final button = NlButton.ghost(onPressed: onPressed, label: label);
    return Padding(
        padding: EdgeInsets.only(
            top: NlSpace.s2, left: indent ? NlSpace.s8 : 0),
        child: Row(children: [
          tip == null ? button : Tooltip(message: tip!, child: button),
        ]));
  }
}

/// "Label: control" line for a sub-option.
class NikoSettingsLabeled extends StatelessWidget {
  final String label;
  final Widget child;
  final bool enabled;
  const NikoSettingsLabeled(
      {super.key,
      required this.label,
      required this.child,
      this.enabled = true});

  @override
  Widget build(BuildContext context) {
    final nl = NlColors.of(context);
    return Padding(
        padding: const EdgeInsets.only(left: NlSpace.s8),
        child: Row(children: [
          Text(label,
              style: NlType.text(NlType.s3, color: enabled ? nl.fg2 : nl.fg3)),
          const SizedBox(width: NlSpace.s3),
          child,
        ]));
  }
}

/// Title block above the tab list.
class NikoSettingsHeader extends StatelessWidget {
  const NikoSettingsHeader({super.key});

  @override
  Widget build(BuildContext context) {
    final nl = NlColors.of(context);
    return Padding(
        padding: const EdgeInsets.fromLTRB(
            NlSpace.s5, NlSpace.s5, NlSpace.s5, NlSpace.s4),
        child: Align(
            alignment: Alignment.centerLeft,
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  NlMonoLabel(nikoText('设置', 'Settings')),
                  const SizedBox(height: NlSpace.s1),
                  Text(nikoText('高级设置', 'Advanced settings'),
                      style: NlType.text(NlType.s5,
                          weight: FontWeight.w600, color: nl.fg)),
                ])));
  }
}

/// One entry of the tab list, styled like the draft's settings navigation.
class NikoSettingsNavItem extends StatefulWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;
  const NikoSettingsNavItem(
      {super.key,
      required this.label,
      required this.icon,
      required this.selected,
      required this.onTap});

  @override
  State<NikoSettingsNavItem> createState() => _NikoSettingsNavItemState();
}

class _NikoSettingsNavItemState extends State<NikoSettingsNavItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final nl = NlColors.of(context);
    final selected = widget.selected;
    return Padding(
        padding: const EdgeInsets.symmetric(
            horizontal: NlSpace.s3, vertical: 1),
        child: Semantics(
            button: true,
            selected: selected,
            child: Material(
                type: MaterialType.transparency,
                child: InkWell(
                    onTap: widget.onTap,
                    onHover: (value) => setState(() => _hovered = value),
                    borderRadius: BorderRadius.circular(NlRadius.r2),
                    splashFactory: NoSplash.splashFactory,
                    child: Stack(clipBehavior: Clip.none, children: [
                      AnimatedContainer(
                          duration: NlMotion.of(context, NlMotion.fast),
                          curve: NlMotion.ease,
                          height: 36,
                          padding: const EdgeInsets.symmetric(
                              horizontal: NlSpace.s3),
                          decoration: BoxDecoration(
                              color: selected || _hovered
                                  ? nl.surface
                                  : Colors.transparent,
                              borderRadius:
                                  BorderRadius.circular(NlRadius.r2),
                              border: selected
                                  ? Border.all(color: nl.ring)
                                  : null),
                          child: Row(children: [
                            Icon(widget.icon,
                                size: 17,
                                color: selected ? nl.accentText : nl.fg3),
                            const SizedBox(width: NlSpace.s3),
                            Expanded(
                                child: Text(widget.label,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: NlType.text(NlType.s3,
                                        weight: selected
                                            ? FontWeight.w500
                                            : FontWeight.w400,
                                        color: selected || _hovered
                                            ? nl.fg
                                            : nl.fg2))),
                          ])),
                      if (selected)
                        Positioned(
                            left: -NlSpace.s3,
                            top: 9,
                            bottom: 9,
                            child: Container(
                                width: 3,
                                decoration: BoxDecoration(
                                    color: nl.accent,
                                    borderRadius: const BorderRadius.horizontal(
                                        right: Radius.circular(3)),
                                    boxShadow: nl.glow))),
                    ])))));
  }
}
