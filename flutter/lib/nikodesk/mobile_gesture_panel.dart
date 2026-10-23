import 'package:flutter/material.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/mobile/widgets/gesture_help.dart' show GestureIcons;
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:get/get.dart';

import 'nightline.dart';
import 'settings_kit.dart';
import 'theme.dart' show nikoSessionTheme;
import 'ui.dart';

/// What each gesture does in touch or mouse mode, and the on-screen mouse:
/// the panel the dock's touch and mouse button opens under the remote
/// picture, styled as the dock opened up.
class NikoGesturePanel extends StatelessWidget {
  final bool touchMode;
  final ValueChanged<bool> onTouchMode;

  /// Null when the remote cannot use the on-screen mouse.
  final bool? virtualMouse;
  final ValueChanged<bool>? onVirtualMouse;
  final double mouseScale;
  final ValueChanged<double>? onMouseScale;
  final bool joystick;
  final ValueChanged<bool>? onJoystick;

  /// Null when this device cannot move the pointer relatively.
  final bool? relative;
  final ValueChanged<bool>? onRelative;

  const NikoGesturePanel(
      {super.key,
      required this.touchMode,
      required this.onTouchMode,
      this.virtualMouse,
      this.onVirtualMouse,
      this.mouseScale = 1,
      this.onMouseScale,
      this.joystick = false,
      this.onJoystick,
      this.relative,
      this.onRelative});

  List<(IconData, String, String)> get _gestures => [
        (
          GestureIcons.iconMobileTouch,
          nikoText('单指轻点', 'Tap'),
          nikoText('左键', 'Left click')
        ),
        (
          GestureIcons.iconGesturePressHold,
          nikoText('单指长按', 'Long press'),
          nikoText('右键', 'Right click')
        ),
        (
          GestureIcons.iconGestureFSwipeRight,
          touchMode
              ? nikoText('单指移动', 'One-finger move')
              : nikoText('双击后移动', 'Double-tap and move'),
          nikoText('拖动', 'Drag')
        ),
        (
          GestureIcons.iconGestureFThreeFingers,
          nikoText('三指上下滑', 'Three fingers up or down'),
          nikoText('滚轮', 'Scroll')
        ),
        (
          GestureIcons.iconGestureFDrag,
          nikoText('双指移动', 'Two-finger move'),
          nikoText('移动画面', 'Move the view')
        ),
        (
          GestureIcons.iconGesturePinch,
          nikoText('双指捏合', 'Pinch'),
          nikoText('缩放画面', 'Zoom the view')
        ),
      ];

  @override
  Widget build(BuildContext context) {
    final nl = NlColors.of(context);
    final mouse = virtualMouse;
    return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: NlSpace.s4,
              runSpacing: NlSpace.s3,
              children: [
                Semantics(
                    header: true,
                    child: Text(nikoText('触控与鼠标', 'Touch and mouse'),
                        style: NlType.text(NlType.s5,
                            weight: FontWeight.w600, color: nl.fg))),
                NlSegmented<bool>(
                    key: const Key('nikodesk-input-mode'),
                    selected: touchMode,
                    segments: [
                      NlSegment(
                          key: const ValueKey(
                              'nikodesk-mobile-input-mode-false'),
                          value: false,
                          icon: NlIcons.mouse,
                          label: nikoText('鼠标模式', 'Mouse mode')),
                      NlSegment(
                          key:
                              const ValueKey('nikodesk-mobile-input-mode-true'),
                          value: true,
                          icon: NlIcons.hand,
                          label: nikoText('触摸模式', 'Touch mode')),
                    ],
                    onChanged: (value) {
                      if (value != touchMode) onTouchMode(value);
                    }),
              ]),
          const SizedBox(height: NlSpace.s2),
          Text(
              touchMode
                  ? nikoText('手指点在哪里，就在远端的哪里操作。',
                      'Your finger acts where it touches the remote screen.')
                  : nikoText('手指像触控板一样移动指针，轻点在指针处点击。',
                      'Your finger moves the pointer like a trackpad; a tap clicks where it points.'),
              style: NlType.text(NlType.s2, color: nl.fg2)),
          const SizedBox(height: NlSpace.s4),
          LayoutBuilder(builder: (context, box) {
            final columns = box.maxWidth >= 560 ? 6 : 3;
            // Phones get smaller tiles so the panel stays within half the
            // screen; each row takes the height of its tallest tile.
            final compact = columns == 3;
            final tiles = [
              for (final (icon, gesture, result) in _gestures)
                Container(
                    padding: EdgeInsets.symmetric(
                        horizontal: NlSpace.s2,
                        vertical: compact ? NlSpace.s2 : NlSpace.s3),
                    decoration: BoxDecoration(
                        color: nl.surface2,
                        borderRadius: BorderRadius.circular(NlRadius.r3)),
                    child: Column(children: [
                      Icon(icon, size: compact ? 24 : 30, color: nl.accentText),
                      SizedBox(height: compact ? NlSpace.s1 : NlSpace.s2),
                      Text(result,
                          textAlign: TextAlign.center,
                          style: NlType.text(NlType.s3,
                              weight: FontWeight.w500, color: nl.fg)),
                      const SizedBox(height: 2),
                      Text(gesture,
                          textAlign: TextAlign.center,
                          style: NlType.text(NlType.s1, color: nl.fg3)),
                    ])),
            ];
            return Column(children: [
              for (var i = 0; i < tiles.length; i += columns) ...[
                if (i > 0) const SizedBox(height: NlSpace.s2),
                IntrinsicHeight(
                    child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                      for (var j = i; j < i + columns; j++) ...[
                        if (j > i) const SizedBox(width: NlSpace.s2),
                        Expanded(
                            child: j < tiles.length
                                ? tiles[j]
                                : const SizedBox.shrink()),
                      ],
                    ])),
              ],
            ]);
          }),
          if (mouse != null) ...[
            const SizedBox(height: NlSpace.s3),
            NikoSettingsGroup(bottom: 0, children: [
              NikoSettingRow(
                  title: nikoText('显示虚拟鼠标', 'Show virtual mouse'),
                  trailing: NlSwitch(
                      key: const Key('nikodesk-virtual-mouse'),
                      value: mouse,
                      onChanged: onVirtualMouse)),
              if (touchMode && mouse)
                NikoSettingRow(
                    title: nikoText('虚拟鼠标大小', 'Virtual mouse size'),
                    below: Row(children: [
                      Text(nikoText('小', 'Small'),
                          style: NlType.text(NlType.s2, color: nl.fg3)),
                      Expanded(
                          child: Slider(
                              key: const Key('nikodesk-virtual-mouse-size'),
                              value: mouseScale.clamp(.8, 1.8),
                              min: .8,
                              max: 1.8,
                              divisions: 10,
                              onChanged: onMouseScale)),
                      Text(nikoText('大', 'Large'),
                          style: NlType.text(NlType.s2, color: nl.fg3)),
                    ])),
              if (!touchMode && mouse)
                NikoSettingRow(
                    title: nikoText('显示虚拟摇杆', 'Show virtual joystick'),
                    trailing: NlSwitch(
                        key: const Key('nikodesk-virtual-joystick'),
                        value: joystick,
                        onChanged: onJoystick)),
              if (!touchMode && mouse && joystick && relative != null)
                NikoSettingRow(
                    title: nikoText('相对鼠标模式', 'Relative mouse mode'),
                    trailing: NlSwitch(
                        key: const Key('nikodesk-relative-mouse'),
                        value: relative!,
                        onChanged: onRelative)),
            ]),
          ],
        ]);
  }
}

/// [NikoGesturePanel] for the session of [ffi], dark like the dock: it
/// switches the touch mode and the on-screen mouse as the stock gesture
/// help does, and leaves relative mouse mode when touch mode or the
/// controls it needs go away.
class NikoGestureHelp extends StatefulWidget {
  final FFI ffi;
  const NikoGestureHelp({super.key, required this.ffi});

  @override
  State<NikoGestureHelp> createState() => _NikoGestureHelpState();
}

class _NikoGestureHelpState extends State<NikoGestureHelp> {
  late bool _touch = widget.ffi.ffiModel.touchMode;

  void _setTouch(bool touch) {
    final model = widget.ffi.ffiModel;
    setState(() => _touch = touch);
    if (model.touchMode != touch) model.toggleTouchMode();
    bind.mainSetLocalOption(
        key: kOptionTouchMode, value: model.touchMode ? 'Y' : 'N');
    if (touch) widget.ffi.inputModel.setRelativeMouseMode(false);
  }

  @override
  Widget build(BuildContext context) {
    final model = widget.ffi.ffiModel;
    final mouse = model.virtualMouseMode;
    final input = widget.ffi.inputModel;
    return ListenableBuilder(
        listenable: mouse,
        builder: (context, _) => Obx(() {
              final relative = input.relativeMouseMode.value;
              return NikoGestureCard(
                  child: NikoGesturePanel(
                      touchMode: _touch,
                      onTouchMode: _setTouch,
                      virtualMouse:
                          model.isPeerAndroid ? null : mouse.showVirtualMouse,
                      onVirtualMouse: (_) async {
                        await mouse.toggleVirtualMouse();
                        if (!mouse.showVirtualMouse) {
                          input.setRelativeMouseMode(false);
                        }
                      },
                      mouseScale: mouse.virtualMouseScale,
                      onMouseScale: mouse.setVirtualMouseScale,
                      joystick: mouse.showVirtualJoystick,
                      onJoystick: (_) async {
                        await mouse.toggleVirtualJoystick();
                        if (!mouse.showVirtualJoystick) {
                          input.setRelativeMouseMode(false);
                        }
                      },
                      relative: relative,
                      onRelative: input.setRelativeMouseMode));
            }));
  }
}

/// The card under the remote picture that holds [NikoGesturePanel]: the
/// dock opened up, dark in both modes, scrolling past half the screen.
class NikoGestureCard extends StatelessWidget {
  final Widget child;
  const NikoGestureCard({super.key, required this.child});

  @override
  Widget build(BuildContext context) => Theme(
      data: nikoSessionTheme(context),
      child: Center(
          child: ConstrainedBox(
              constraints: BoxConstraints(
                  maxWidth: 720,
                  maxHeight: MediaQuery.sizeOf(context).height * .55),
              child: Padding(
                  padding: const EdgeInsets.fromLTRB(
                      NlSpace.s2, NlSpace.s2, NlSpace.s2, NlSpace.s3),
                  child: DecoratedBox(
                      key: const Key('nikodesk-gesture-panel'),
                      decoration: BoxDecoration(
                          color: NlDock.background,
                          borderRadius: BorderRadius.circular(NlRadius.r4),
                          border: Border.all(color: NlDock.line),
                          boxShadow: NlColors.dark.shadow3),
                      child: SingleChildScrollView(
                          padding: const EdgeInsets.all(NlSpace.s4),
                          child: child))))));
}
