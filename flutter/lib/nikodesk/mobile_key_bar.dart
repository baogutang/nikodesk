import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/models/input_model.dart';
import 'package:flutter_hbb/models/model.dart';

import 'nightline.dart';
import 'theme.dart' show nikoSessionTheme;
import 'ui.dart';

enum NikoModifier { control, alt, shift, command }

/// The keys a soft keyboard lacks, for the remote: modifiers that stay down
/// until tapped again, Esc, Tab and the arrows; on demand the editing keys
/// with copy, paste and save, and F1–F12. A row scrolls when it does not
/// fit; the toggles for the other rows stay at the end of the first.
class NikoKeyBar extends StatelessWidget {
  final String peerPlatform;
  final Set<NikoModifier> down;
  final bool more;
  final bool fn;
  final bool pinned;
  final ValueChanged<NikoModifier> onModifier;

  /// A key by its virtual key name, such as VK_ESCAPE.
  final ValueChanged<String> onKey;

  /// A key pressed with Command on a Mac and Control elsewhere.
  final ValueChanged<String> onShortcut;
  final VoidCallback onMore;
  final VoidCallback onFn;
  final VoidCallback onPin;

  const NikoKeyBar(
      {super.key,
      required this.peerPlatform,
      this.down = const {},
      this.more = true,
      this.fn = false,
      this.pinned = false,
      required this.onModifier,
      required this.onKey,
      required this.onShortcut,
      required this.onMore,
      required this.onFn,
      required this.onPin});

  bool get _mac => peerPlatform == kPeerPlatformMacOS;

  Widget _modifier(NikoModifier modifier) {
    final (String label, String name) = switch (modifier) {
      NikoModifier.control => (_mac ? '⌃' : 'Ctrl', 'Control'),
      NikoModifier.alt => (_mac ? '⌥' : 'Alt', _mac ? 'Option' : 'Alt'),
      NikoModifier.shift => (_mac ? '⇧' : 'Shift', 'Shift'),
      NikoModifier.command => (
          _mac ? '⌘' : 'Win',
          _mac ? 'Command' : 'Windows'
        ),
    };
    return NikoKeyCap(
        key: ValueKey('nikodesk-key-${modifier.name}'),
        label: label,
        semanticLabel: name,
        active: down.contains(modifier),
        onTap: () => onModifier(modifier));
  }

  Widget _key(String label, String key, {IconData? icon, String? name}) =>
      NikoKeyCap(
          key: ValueKey('nikodesk-key-$key'),
          label: label,
          icon: icon,
          semanticLabel: name ?? label,
          onTap: () => onKey(key));

  Widget _shortcut(String letter, String name) => NikoKeyCap(
      key: ValueKey('nikodesk-key-shortcut-$letter'),
      label: _mac ? '⌘$letter' : 'Ctrl+$letter',
      semanticLabel: name,
      onTap: () => onShortcut('VK_$letter'));

  @override
  Widget build(BuildContext context) {
    final pc = peerPlatform == kPeerPlatformWindows ||
        peerPlatform == kPeerPlatformLinux;
    // A phone keeps the modifiers beside the toggles and starts the next
    // row with Esc, Tab and the arrows, so no key hides behind the toggles.
    final narrow = MediaQuery.sizeOf(context).width < NlLayout.compactMax;
    final modifiers = [
      for (final modifier in NikoModifier.values) _modifier(modifier),
    ];
    final moves = [
      _key('Esc', 'VK_ESCAPE'),
      _key('Tab', 'VK_TAB'),
      _key('', 'VK_LEFT', icon: NlIcons.arrowLeft, name: nikoText('左', 'Left')),
      _key('', 'VK_UP', icon: NlIcons.arrowUp, name: nikoText('上', 'Up')),
      _key('', 'VK_DOWN', icon: NlIcons.arrowDown, name: nikoText('下', 'Down')),
      _key('', 'VK_RIGHT',
          icon: NlIcons.arrowRight, name: nikoText('右', 'Right')),
    ];
    final first =
        narrow ? modifiers : [...modifiers, const _KeySeparator(), ...moves];
    final editing = [
      _key('Home', 'VK_HOME'),
      _key('End', 'VK_END'),
      _key('PgUp', 'VK_PRIOR', name: 'Page Up'),
      _key('PgDn', 'VK_NEXT', name: 'Page Down'),
      _key('Ins', 'VK_INSERT', name: 'Insert'),
      _key('Del', 'VK_DELETE', name: 'Delete'),
      // As the stock key bar: these four are offered to Windows and Linux.
      if (pc) ...[
        _key('PrtSc', 'VK_SNAPSHOT', name: 'Print Screen'),
        _key('ScrLk', 'VK_SCROLL', name: 'Scroll Lock'),
        _key('Pause', 'VK_PAUSE'),
        _key('Menu', 'Apps'),
      ],
      _key('', 'VK_ENTER', icon: NlIcons.cornerDownLeft, name: 'Enter'),
      const _KeySeparator(),
      _shortcut('C', nikoText('复制', 'Copy')),
      _shortcut('V', nikoText('粘贴', 'Paste')),
      _shortcut('S', nikoText('保存', 'Save')),
    ];
    final function = [
      for (var i = 1; i <= 12; i++) _key('F$i', 'VK_F$i'),
    ];
    return Semantics(
        container: true,
        explicitChildNodes: true,
        label: nikoText('按键栏', 'Key bar'),
        child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(children: [
                Expanded(child: _KeyRow(keys: first)),
                const SizedBox(width: NlSpace.s2),
                NikoKeyCap(
                    key: const ValueKey('nikodesk-key-toggle-fn'),
                    label: 'Fn',
                    semanticLabel: nikoText('功能键', 'Function keys'),
                    active: fn,
                    onTap: onFn),
                const SizedBox(width: NlSpace.s1),
                NikoKeyCap(
                    key: const ValueKey('nikodesk-key-toggle-more'),
                    icon: NlIcons.ellipsis,
                    semanticLabel: nikoText('更多按键', 'More keys'),
                    active: more,
                    onTap: onMore),
                const SizedBox(width: NlSpace.s1),
                NikoKeyCap(
                    key: const ValueKey('nikodesk-key-toggle-pin'),
                    icon: NlIcons.pin,
                    semanticLabel: nikoText('保持显示', 'Keep shown'),
                    active: pinned,
                    onTap: onPin),
              ]),
              if (narrow || more) ...[
                const SizedBox(height: NlSpace.s1),
                _KeyRow(keys: [
                  if (narrow) ...moves,
                  if (narrow && more) const _KeySeparator(),
                  if (more) ...editing,
                ]),
              ],
              if (fn) ...[
                const SizedBox(height: NlSpace.s1),
                _KeyRow(keys: function),
              ],
            ]));
  }
}

/// One key of [NikoKeyBar]: a label or an icon on a cap that lights up
/// while its modifier is down.
class NikoKeyCap extends StatelessWidget {
  final String label;
  final IconData? icon;
  final String semanticLabel;
  final bool active;
  final VoidCallback onTap;

  const NikoKeyCap(
      {super.key,
      this.label = '',
      this.icon,
      required this.semanticLabel,
      this.active = false,
      required this.onTap});

  @override
  Widget build(BuildContext context) {
    final nl = NlColors.of(context);
    final ink = active ? nl.onAccent : nl.fg;
    return NlPressable(
        selected: active,
        semanticLabel: semanticLabel,
        pressScale: .94,
        onTap: () {
          HapticFeedback.selectionClick();
          onTap();
        },
        builder: (context, states) => AnimatedContainer(
            duration: NlMotion.of(context, NlMotion.instant),
            curve: NlMotion.ease,
            height: 36,
            constraints: const BoxConstraints(minWidth: 40),
            padding: const EdgeInsets.symmetric(horizontal: NlSpace.s3),
            alignment: Alignment.center,
            decoration: BoxDecoration(
                color: active
                    ? nl.accentFill
                    : states.contains(WidgetState.pressed)
                        ? nl.line2
                        : states.contains(WidgetState.hovered)
                            ? Color.alphaBlend(NlDock.hover, nl.surface2)
                            : nl.surface2,
                borderRadius: BorderRadius.circular(NlRadius.r2),
                boxShadow:
                    states.contains(WidgetState.focused) ? nl.focusRing : null),
            child: ExcludeSemantics(
                child: icon != null
                    ? Icon(icon, size: 16, color: ink)
                    : Text(label,
                        maxLines: 1,
                        style: NlType.text(NlType.s2,
                            weight: FontWeight.w500, color: ink)))));
  }
}

class _KeySeparator extends StatelessWidget {
  const _KeySeparator();

  @override
  Widget build(BuildContext context) => Container(
      width: 1,
      height: 20,
      margin: const EdgeInsets.symmetric(horizontal: NlSpace.s2 - 2),
      color: NlDock.separator);
}

/// A row of keys that scrolls sideways when it does not fit, fading out
/// where more keys are hidden.
class _KeyRow extends StatefulWidget {
  final List<Widget> keys;
  const _KeyRow({required this.keys});

  @override
  State<_KeyRow> createState() => _KeyRowState();
}

class _KeyRowState extends State<_KeyRow> {
  var _before = false;
  var _after = false;

  bool _measure(ScrollMetrics metrics) {
    final before = metrics.extentBefore > .5;
    final after = metrics.extentAfter > .5;
    if (before != _before || after != _after) {
      // Metrics arrive during layout; repaint the fade after it.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          setState(() {
            _before = before;
            _after = after;
          });
        }
      });
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    const fade = 16.0;
    return ShaderMask(
        blendMode: BlendMode.dstIn,
        shaderCallback: (bounds) => LinearGradient(
                    colors: [
                  _before ? Colors.transparent : Colors.white,
                  Colors.white,
                  Colors.white,
                  _after ? Colors.transparent : Colors.white,
                ],
                    stops: bounds.width > 3 * fade
                        ? [0, fade / bounds.width, 1 - fade / bounds.width, 1]
                        : const [0, .3, .7, 1])
                .createShader(bounds),
        child: NotificationListener<ScrollMetricsNotification>(
            onNotification: (n) => _measure(n.metrics),
            child: NotificationListener<ScrollNotification>(
                onNotification: (n) => _measure(n.metrics),
                child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(children: [
                      for (var i = 0; i < widget.keys.length; i++) ...[
                        if (i > 0) const SizedBox(width: NlSpace.s1),
                        widget.keys[i],
                      ],
                    ])))));
  }
}

/// [NikoKeyBar] over the session of [ffi], where the stock key bar would
/// be and under the same rules: shown with the soft keyboard or the
/// gesture panel, while a modifier is down, or when pinned; it reports
/// where it is so a touch on it does not reach the remote.
class NikoKeyHelpBar extends StatefulWidget {
  final FFI ffi;
  final bool keyboardIsVisible;
  final bool showGestureHelp;

  const NikoKeyHelpBar(
      {super.key,
      required this.ffi,
      required this.keyboardIsVisible,
      required this.showGestureHelp});

  @override
  State<NikoKeyHelpBar> createState() => _NikoKeyHelpBarState();
}

class _NikoKeyHelpBarState extends State<NikoKeyHelpBar> {
  // The stock key bar's defaults: editing keys shown, F-keys hidden.
  var _more = true;
  var _fn = false;
  var _pin = false;
  final _key = GlobalKey();

  InputModel get _input => widget.ffi.inputModel;

  void _updateRect() {
    final box = _key.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.attached) return;
    widget.ffi.cursorModel.keyHelpToolsVisibilityChanged(
        box.localToGlobal(Offset.zero) & box.size, widget.keyboardIsVisible);
  }

  void _toggle(NikoModifier modifier) => setState(() {
        final input = _input;
        switch (modifier) {
          case NikoModifier.control:
            input.ctrl = !input.ctrl;
          case NikoModifier.alt:
            input.alt = !input.alt;
          case NikoModifier.shift:
            input.shift = !input.shift;
          case NikoModifier.command:
            input.command = !input.command;
        }
      });

  /// As the stock key bar's prompt keys: Command on a Mac, else Control,
  /// held for this key only.
  void _shortcut(String key) {
    final input = _input;
    final mac = widget.ffi.ffiModel.pi.platform == kPeerPlatformMacOS;
    final old = mac ? input.command : input.ctrl;
    if (mac) {
      input.command = true;
    } else {
      input.ctrl = true;
    }
    input.inputKey(key);
    if (mac) {
      input.command = old;
    } else {
      input.ctrl = old;
    }
  }

  @override
  Widget build(BuildContext context) {
    final input = _input;
    final down = {
      if (input.ctrl) NikoModifier.control,
      if (input.alt) NikoModifier.alt,
      if (input.shift) NikoModifier.shift,
      if (input.command) NikoModifier.command,
    };
    if (!_pin &&
        down.isEmpty &&
        !widget.keyboardIsVisible &&
        !widget.showGestureHelp) {
      widget.ffi.cursorModel
          .keyHelpToolsVisibilityChanged(null, widget.keyboardIsVisible);
      return const Offstage();
    }
    // As the stock key bar: read the rect once the layout has settled.
    Future.delayed(const Duration(milliseconds: 500), () {
      if (mounted) _updateRect();
    });
    return NikoKeyBarFrame(
        stripKey: _key,
        keyboardIsVisible: widget.keyboardIsVisible,
        child: NikoKeyBar(
            peerPlatform: widget.ffi.ffiModel.pi.platform,
            down: down,
            more: _more,
            fn: _fn,
            pinned: _pin,
            onModifier: _toggle,
            onKey: (key) => input.inputKey(key),
            onShortcut: _shortcut,
            onMore: () => setState(() {
                  _more = !_more;
                  if (_more) _fn = false;
                }),
            onFn: () => setState(() {
                  _fn = !_fn;
                  if (_fn) _more = false;
                }),
            onPin: () => setState(() => _pin = !_pin)));
  }
}

/// The strip [NikoKeyHelpBar] draws its keys on: centred at the top of the
/// session where the stock key bar sits, as wide as the keys up to 860,
/// dark like the dock in both modes.
class NikoKeyBarFrame extends StatelessWidget {
  final bool keyboardIsVisible;

  /// On the strip itself, whose rect blocks touches to the remote.
  final Key? stripKey;
  final Widget child;

  const NikoKeyBarFrame(
      {super.key,
      required this.keyboardIsVisible,
      this.stripKey,
      required this.child});

  @override
  Widget build(BuildContext context) => Theme(
      data: nikoSessionTheme(context),
      child: Align(
          alignment: Alignment.topCenter,
          child: Padding(
              // The stock key bar's distance from the top.
              padding: EdgeInsets.fromLTRB(
                  NlSpace.s2, keyboardIsVisible ? 24 : 4, NlSpace.s2, 0),
              child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 860),
                  child: IntrinsicWidth(
                      child: DecoratedBox(
                          key: stripKey,
                          decoration: BoxDecoration(
                              color: NlDock.background,
                              borderRadius: BorderRadius.circular(NlRadius.r3),
                              border: Border.all(color: NlDock.line),
                              boxShadow: NlColors.dark.shadow2),
                          child: Padding(
                              padding: const EdgeInsets.all(NlSpace.s1 + 2),
                              child: child)))))));
}
