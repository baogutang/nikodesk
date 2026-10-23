import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'components.dart';
import 'icons.dart';
import 'surfaces.dart';
import 'tokens.dart';

TextStyle _labelStyle(NlColors nl) =>
    NlType.text(NlType.s2, weight: FontWeight.w500, color: nl.fg2);

// A label mixing Latin and Chinese takes the taller line of both fonts, so
// fields side by side would sit a pixel apart; a fixed line keeps them level.
final _labelStrut = StrutStyle.fromTextStyle(
    NlType.text(NlType.s2, weight: FontWeight.w500),
    forceStrutHeight: true);

/// Text field with its label above, a soft focus ring and inline error.
class NlTextField extends StatefulWidget {
  final TextEditingController? controller;
  final FocusNode? focusNode;
  final String? label;
  final String? hint;
  final String? helper;
  final String? error;
  final IconData? prefixIcon;
  final Widget? suffix;

  /// Hides the text and offers a reveal button.
  final bool obscure;

  /// JetBrains Mono with tabular figures, for IDs, addresses and keys; the
  /// keyboard leaves such text as typed and does not learn it.
  final bool mono;
  final bool large;
  final bool autofocus;
  final bool enabled;
  final TextAlign textAlign;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final List<TextInputFormatter>? inputFormatters;
  final Iterable<String>? autofillHints;

  /// Key of the inner [TextField], for callers and tests that address it.
  final Key? fieldKey;
  final String? revealLabel;
  final String? hideLabel;

  const NlTextField(
      {super.key,
      this.controller,
      this.focusNode,
      this.label,
      this.hint,
      this.helper,
      this.error,
      this.prefixIcon,
      this.suffix,
      this.obscure = false,
      this.mono = false,
      this.large = false,
      this.autofocus = false,
      this.enabled = true,
      this.textAlign = TextAlign.start,
      this.keyboardType,
      this.textInputAction,
      this.onChanged,
      this.onSubmitted,
      this.inputFormatters,
      this.autofillHints,
      this.fieldKey,
      this.revealLabel,
      this.hideLabel});

  @override
  State<NlTextField> createState() => _NlTextFieldState();
}

class _NlTextFieldState extends State<NlTextField> {
  FocusNode? _ownFocus;
  FocusNode get _focus => widget.focusNode ?? (_ownFocus ??= FocusNode());
  bool _focused = false;
  bool _hovered = false;
  bool _revealed = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_focusChanged);
  }

  @override
  void didUpdateWidget(covariant NlTextField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusNode != widget.focusNode) {
      (oldWidget.focusNode ?? _ownFocus)?.removeListener(_focusChanged);
      _focus.addListener(_focusChanged);
    }
  }

  @override
  void dispose() {
    _focus.removeListener(_focusChanged);
    _ownFocus?.dispose();
    super.dispose();
  }

  void _focusChanged() {
    if (mounted && _focused != _focus.hasFocus) {
      setState(() => _focused = _focus.hasFocus);
    }
  }

  @override
  Widget build(BuildContext context) {
    final nl = NlColors.of(context);
    final touch = NlLayout.touch(context);
    final error = widget.error;
    final size = widget.large
        ? NlType.s5
        : (touch ? NlType.s4 : NlType.s3);
    final height = widget.large ? (touch ? 52.0 : 44.0) : (touch ? 44.0 : 34.0);
    final style = widget.mono
        ? NlType.monoText(size, weight: FontWeight.w500, color: nl.fg)
        : NlType.text(size, color: nl.fg);
    final ring = error != null ? nl.danger : nl.accent;
    final border = error != null
        ? nl.danger
        : _focused
            ? nl.accent
            : _hovered
                ? nl.fg3.withOpacity(.6)
                : nl.line2;
    final field = TextField(
        key: widget.fieldKey,
        controller: widget.controller,
        focusNode: _focus,
        autofocus: widget.autofocus,
        enabled: widget.enabled,
        obscureText: widget.obscure && !_revealed,
        autocorrect: !widget.obscure && !widget.mono,
        enableSuggestions: !widget.obscure && !widget.mono,
        enableIMEPersonalizedLearning: !widget.obscure && !widget.mono,
        smartDashesType: widget.mono ? SmartDashesType.disabled : null,
        smartQuotesType: widget.mono ? SmartQuotesType.disabled : null,
        keyboardType: widget.keyboardType,
        textInputAction: widget.textInputAction,
        inputFormatters: widget.inputFormatters,
        autofillHints: widget.autofillHints,
        textAlign: widget.textAlign,
        onChanged: widget.onChanged,
        onSubmitted: widget.onSubmitted,
        style: style,
        cursorColor: nl.accent,
        cursorWidth: 1.5,
        cursorRadius: const Radius.circular(1),
        decoration: InputDecoration(
            isCollapsed: true,
            filled: false,
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            disabledBorder: InputBorder.none,
            errorBorder: InputBorder.none,
            focusedErrorBorder: InputBorder.none,
            hintText: widget.hint,
            hintStyle: style.copyWith(
                color: nl.fg3, fontWeight: FontWeight.w400),
            contentPadding: EdgeInsets.zero));
    final box = MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        cursor: SystemMouseCursors.text,
        child: GestureDetector(
            onTap: () => _focus.requestFocus(),
            child: AnimatedContainer(
                duration: NlMotion.of(context, NlMotion.fast),
                curve: NlMotion.standard,
                // A minimum, so large text grows the field instead of
                // clipping it.
                constraints: BoxConstraints(minHeight: height),
                alignment: Alignment.centerLeft,
                padding: EdgeInsets.symmetric(
                    horizontal: widget.large ? NlSpace.s4 : NlSpace.s3,
                    vertical: NlSpace.s1),
                decoration: BoxDecoration(
                    color: nl.isDark ? nl.surface : nl.overlay,
                    borderRadius: BorderRadius.circular(
                        widget.large ? NlRadius.r3 : NlRadius.r2),
                    border: Border.all(color: border),
                    boxShadow: [
                      if (_focused)
                        BoxShadow(
                            color: ring.withOpacity(nl.isDark ? .32 : .2),
                            spreadRadius: 3)
                      else
                        ...nl.shadow1,
                    ]),
                child: Row(children: [
                  if (widget.prefixIcon != null) ...[
                    Icon(widget.prefixIcon,
                        size: widget.large ? 18 : 16,
                        color: _focused ? nl.fg2 : nl.fg3),
                    const SizedBox(width: NlSpace.s2),
                  ],
                  Expanded(child: field),
                  if (widget.obscure)
                    NlIconButton(
                        icon: _revealed ? NlIcons.eyeOff : NlIcons.eye,
                        tooltip: _revealed
                            ? widget.hideLabel ?? 'Hide'
                            : widget.revealLabel ?? 'Show',
                        iconSize: 15,
                        onPressed: widget.enabled
                            ? () => setState(() => _revealed = !_revealed)
                            : null),
                  if (widget.suffix != null) ...[
                    const SizedBox(width: NlSpace.s1),
                    widget.suffix!,
                  ],
                ]))));
    return AnimatedOpacity(
        opacity: widget.enabled ? 1 : .55,
        duration: NlMotion.of(context, NlMotion.fast),
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.label != null)
                Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text(widget.label!,
                        style: _labelStyle(nl),
                        strutStyle: _labelStrut)),
              box,
              AnimatedSize(
                  duration: NlMotion.of(context, NlMotion.fast),
                  curve: NlMotion.standard,
                  alignment: Alignment.topLeft,
                  child: error != null || widget.helper != null
                      ? Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(error ?? widget.helper!,
                              style: NlType.text(NlType.s2,
                                  color: error != null
                                      ? nl.dangerText
                                      : nl.fg3)))
                      : const SizedBox(width: double.infinity)),
            ]));
  }
}

/// Search field: a quiet filled capsule with a clear button and an
/// optional shortcut hint while it is empty.
class NlSearchField extends StatefulWidget {
  final TextEditingController controller;
  final FocusNode? focusNode;
  final String hint;
  final String? shortcut;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final String clearLabel;
  final Key? fieldKey;
  final bool autofocus;

  const NlSearchField(
      {super.key,
      required this.controller,
      required this.hint,
      this.focusNode,
      this.shortcut,
      this.onChanged,
      this.onSubmitted,
      this.clearLabel = 'Clear',
      this.fieldKey,
      this.autofocus = false});

  @override
  State<NlSearchField> createState() => _NlSearchFieldState();
}

class _NlSearchFieldState extends State<NlSearchField> {
  FocusNode? _ownFocus;
  FocusNode get _focus => widget.focusNode ?? (_ownFocus ??= FocusNode());
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_changed);
    widget.controller.addListener(_changed);
  }

  @override
  void didUpdateWidget(covariant NlSearchField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_changed);
      widget.controller.addListener(_changed);
    }
  }

  @override
  void dispose() {
    _focus.removeListener(_changed);
    widget.controller.removeListener(_changed);
    _ownFocus?.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() => _focused = _focus.hasFocus);
  }

  @override
  Widget build(BuildContext context) {
    final nl = NlColors.of(context);
    final touch = NlLayout.touch(context);
    final empty = widget.controller.text.isEmpty;
    final size = touch ? NlType.s4 : NlType.s3;
    return AnimatedContainer(
        duration: NlMotion.of(context, NlMotion.fast),
        curve: NlMotion.standard,
        height: touch ? 38 : 30,
        padding: const EdgeInsets.only(left: NlSpace.s2 + 2, right: NlSpace.s1),
        decoration: BoxDecoration(
            color: _focused
                ? (nl.isDark ? nl.surface : nl.overlay)
                : nl.solid(nl.isDark ? nl.hover : const Color(0x0F000000),
                    nl.isDark ? nl.surface : nl.bg),
            borderRadius: BorderRadius.circular(NlRadius.r2),
            border: Border.all(
                color: _focused ? nl.accent : Colors.transparent),
            boxShadow: _focused
                ? [
                    BoxShadow(
                        color: nl.accent.withOpacity(nl.isDark ? .32 : .2),
                        spreadRadius: 3)
                  ]
                : null),
        child: Row(children: [
          Icon(NlIcons.search, size: touch ? 17 : 15, color: nl.fg3),
          const SizedBox(width: NlSpace.s2),
          Expanded(
              child: TextField(
                  key: widget.fieldKey,
                  controller: widget.controller,
                  focusNode: _focus,
                  autofocus: widget.autofocus,
                  onChanged: widget.onChanged,
                  onSubmitted: widget.onSubmitted,
                  textInputAction: TextInputAction.search,
                  style: NlType.text(size, color: nl.fg),
                  cursorColor: nl.accent,
                  cursorWidth: 1.5,
                  decoration: InputDecoration(
                      isCollapsed: true,
                      filled: false,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      hintText: widget.hint,
                      hintStyle: NlType.text(size, color: nl.fg3),
                      contentPadding: EdgeInsets.zero))),
          if (!empty)
            NlIconButton(
                icon: NlIcons.circleX,
                tooltip: widget.clearLabel,
                iconSize: 14,
                onPressed: () {
                  widget.controller.clear();
                  widget.onChanged?.call('');
                  _focus.requestFocus();
                })
          else if (widget.shortcut != null && !_focused && !touch)
            Padding(
                padding: const EdgeInsets.only(right: NlSpace.s1),
                child: ExcludeSemantics(child: NlKbd(widget.shortcut!))),
        ]));
  }
}

/// On/off switch. The thumb slides on the motion curve and stretches while
/// pressed.
class NlSwitch extends StatelessWidget {
  final bool value;
  final ValueChanged<bool>? onChanged;
  final String? semanticLabel;
  final Key? switchKey;

  const NlSwitch(
      {super.key,
      required this.value,
      required this.onChanged,
      this.semanticLabel,
      this.switchKey});

  @override
  Widget build(BuildContext context) {
    final nl = NlColors.of(context);
    final touch = NlLayout.touch(context);
    final width = touch ? 46.0 : 32.0;
    final height = touch ? 28.0 : 18.0;
    const inset = 2.0;
    final thumb = height - 2 * inset;
    return Semantics(
        toggled: value,
        child: NlPressable(
            key: switchKey,
            onTap: onChanged == null ? null : () => onChanged!(!value),
            semanticLabel: semanticLabel,
            pressScale: 1,
            builder: (context, states) {
              final pressed = states.contains(WidgetState.pressed);
              final duration = NlMotion.of(context, NlMotion.base);
              return AnimatedOpacity(
                  opacity: onChanged == null ? .45 : 1,
                  duration: duration,
                  child: AnimatedContainer(
                      duration: duration,
                      curve: NlMotion.standard,
                      width: width,
                      height: height,
                      padding: const EdgeInsets.all(inset),
                      decoration: BoxDecoration(
                          color: value ? nl.accent : nl.line2,
                          borderRadius: BorderRadius.circular(height / 2),
                          boxShadow: states.contains(WidgetState.focused)
                              ? nl.focusRing
                              : null),
                      child: AnimatedAlign(
                          duration: duration,
                          curve: NlMotion.ease,
                          alignment:
                              value ? Alignment.centerRight : Alignment.centerLeft,
                          child: AnimatedContainer(
                              duration: duration,
                              curve: NlMotion.ease,
                              width: thumb + (pressed ? thumb * .22 : 0),
                              height: thumb,
                              decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius:
                                      BorderRadius.circular(thumb / 2),
                                  boxShadow: const [
                                    BoxShadow(
                                        color: Color(0x33000000),
                                        offset: Offset(0, 1),
                                        blurRadius: 2.5),
                                    BoxShadow(
                                        color: Color(0x0F000000),
                                        spreadRadius: .5),
                                  ])))));
            }));
  }
}

/// Checkbox with its label. The box sits flush with the text around it,
/// unlike a list tile's inset one; the whole row toggles it and the check
/// grows in on the motion curve.
class NlCheckbox extends StatelessWidget {
  final bool value;
  final ValueChanged<bool>? onChanged;

  /// Null draws the box alone, for a row that names it itself; the box then
  /// keeps a square target and announces [semanticLabel].
  final String? label;
  final String? semanticLabel;
  final Key? boxKey;

  const NlCheckbox(
      {super.key,
      required this.value,
      required this.onChanged,
      this.label,
      this.semanticLabel,
      this.boxKey});

  @override
  Widget build(BuildContext context) {
    final nl = NlColors.of(context);
    final touch = NlLayout.touch(context);
    final size = touch ? 22.0 : 16.0;
    return Semantics(
        checked: value,
        child: NlPressable(
            key: boxKey,
            onTap: onChanged == null ? null : () => onChanged!(!value),
            semanticLabel: label == null ? semanticLabel : null,
            button: false,
            pressScale: 1,
            builder: (context, states) {
              final duration = NlMotion.of(context, NlMotion.fast);
              final hovered = states.contains(WidgetState.hovered);
              final target = touch ? 44.0 : 24.0;
              return AnimatedOpacity(
                  opacity: onChanged == null ? .45 : 1,
                  duration: duration,
                  child: ConstrainedBox(
                      constraints: BoxConstraints(
                          minHeight: target,
                          minWidth: label == null ? target : 0),
                      child: Row(
                          mainAxisSize: label == null
                              ? MainAxisSize.min
                              : MainAxisSize.max,
                          mainAxisAlignment: label == null
                              ? MainAxisAlignment.center
                              : MainAxisAlignment.start,
                          children: [
                        AnimatedContainer(
                            duration: duration,
                            curve: NlMotion.standard,
                            width: size,
                            height: size,
                            decoration: BoxDecoration(
                                color: value
                                    ? nl.accent
                                    : hovered
                                        ? nl.hover
                                        : Colors.transparent,
                                borderRadius:
                                    BorderRadius.circular(NlRadius.r1),
                                border: Border.all(
                                    color: value
                                        ? nl.accent
                                        : hovered
                                            ? nl.fg3
                                            : nl.line2,
                                    width: 1.5),
                                boxShadow: states.contains(WidgetState.focused)
                                    ? nl.focusRing
                                    : null),
                            child: AnimatedScale(
                                scale: value ? 1 : .5,
                                duration: duration,
                                curve: NlMotion.ease,
                                child: AnimatedOpacity(
                                    opacity: value ? 1 : 0,
                                    duration: duration,
                                    child: Icon(NlIcons.check,
                                        size: size - 4, color: nl.onAccent)))),
                        if (label != null) ...[
                          const SizedBox(width: NlSpace.s3),
                          Flexible(
                              child: Text(label!,
                                  style:
                                      NlType.text(NlType.s3, color: nl.fg))),
                        ],
                      ])));
            }));
  }
}

/// One choice of an [NlSelect].
class NlSelectOption<T> {
  final T value;
  final String label;
  final bool enabled;
  const NlSelectOption(this.value, this.label, {this.enabled = true});
}

/// A pop-up choice styled as [NlTextField], label above: the field shows the
/// chosen option or [placeholder], and a press lists the options in a menu
/// under the field with the chosen one checked.
class NlSelect<T> extends StatelessWidget {
  final String? label;
  final String placeholder;
  final T? value;
  final List<NlSelectOption<T>> options;

  /// Null disables the field, as an empty [options] list does.
  final ValueChanged<T>? onChanged;
  final String? helper;
  const NlSelect(
      {super.key,
      this.label,
      required this.placeholder,
      required this.value,
      required this.options,
      required this.onChanged,
      this.helper});

  bool get enabled => onChanged != null && options.isNotEmpty;

  /// The chosen option, or null when [value] is not among [options].
  NlSelectOption<T>? get chosen {
    for (final option in options) {
      if (option.value == value) return option;
    }
    return null;
  }

  void _open(BuildContext field) {
    final anchor = nlAnchorOf(field);
    showNlMenu(field, anchor: anchor, width: anchor.width, entries: [
      for (final option in options)
        NlMenuItem(
            label: option.label,
            enabled: option.enabled,
            checked: option.value == value,
            onSelected: () => onChanged?.call(option.value)),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final nl = NlColors.of(context);
    final touch = NlLayout.touch(context);
    final chosen = this.chosen;
    final field = Builder(
        builder: (field) => NlPressable(
            onTap: enabled ? () => _open(field) : null,
            pressScale: 1,
            semanticLabel: label,
            builder: (context, states) {
              final focused = states.contains(WidgetState.focused);
              final hovered = states.contains(WidgetState.hovered);
              return AnimatedContainer(
                  duration: NlMotion.of(context, NlMotion.fast),
                  curve: NlMotion.standard,
                  constraints: BoxConstraints(minHeight: touch ? 44 : 34),
                  padding: const EdgeInsets.symmetric(
                      horizontal: NlSpace.s3, vertical: NlSpace.s1),
                  decoration: BoxDecoration(
                      color: nl.isDark ? nl.surface : nl.overlay,
                      borderRadius: BorderRadius.circular(NlRadius.r2),
                      border: Border.all(
                          color: focused
                              ? nl.accent
                              : hovered
                                  ? nl.fg3.withOpacity(.6)
                                  : nl.line2),
                      boxShadow: focused ? nl.focusRing : nl.shadow1),
                  child: Row(children: [
                    Expanded(
                        child: Text(chosen?.label ?? placeholder,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: NlType.text(
                                touch ? NlType.s4 : NlType.s3,
                                color: chosen == null ? nl.fg3 : nl.fg))),
                    const SizedBox(width: NlSpace.s2),
                    Icon(NlIcons.chevronsUpDown, size: 14, color: nl.fg3),
                  ]));
            }));
    return AnimatedOpacity(
        opacity: enabled ? 1 : .55,
        duration: NlMotion.of(context, NlMotion.fast),
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (label != null)
                Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    // The field announces it, with the choice.
                    child: ExcludeSemantics(
                        child: Text(label!,
                            style: _labelStyle(nl), strutStyle: _labelStrut))),
              field,
              if (helper != null)
                Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(helper!,
                        style: NlType.text(NlType.s2, color: nl.fg3))),
            ]));
  }
}
