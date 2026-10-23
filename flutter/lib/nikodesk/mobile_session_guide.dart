import 'package:flutter/material.dart';

import 'nightline.dart';
import 'session_sheet.dart';
import 'ui.dart';

const nikoMobileGuideSeenKey = 'nikodesk-mobile-session-guide-v1';

/// Offers the guide over the session; true asks for the full gesture guide.
Future<bool?> showNikoMobileSessionGuide(BuildContext context,
        {required bool touchMode}) =>
    showDialog<bool>(
        context: context,
        // The sheet keeps clear of the home indicator itself.
        useSafeArea: false,
        barrierColor: Colors.black45,
        builder: (_) => NikoMobileSessionGuide(touchMode: touchMode));

/// Offered by the real session page only after its first decoded frame.
class NikoMobileSessionGuide extends StatelessWidget {
  final bool touchMode;
  const NikoMobileSessionGuide({super.key, required this.touchMode});

  @override
  Widget build(BuildContext context) => NikoSessionSheet(
      width: 460,
      onCancel: () => Navigator.pop(context, false),
      child: Builder(builder: (context) {
        final nl = NlColors.of(context);
        return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Semantics(
                  header: true,
                  child: Text(nikoText('开始操作远端', 'Control the remote computer'),
                      style: NlType.text(NlType.s5,
                          weight: FontWeight.w600, color: nl.fg))),
              const SizedBox(height: NlSpace.s4),
              Flexible(
                  child: SingleChildScrollView(
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                    _instruction(
                        context,
                        NlIcons.pointer,
                        nikoText('单击与右键', 'Click and right-click'),
                        nikoText('单指轻点为左键，长按为右键。',
                            'Tap for a left-click; long-press for a right-click.')),
                    _instruction(
                        context,
                        NlIcons.move,
                        nikoText('拖动与缩放', 'Drag and zoom'),
                        touchMode
                            ? nikoText('单指移动拖动远端对象；双指移动画布，捏合缩放。',
                                'Move one finger to drag; use two fingers to pan and pinch to zoom.')
                            : nikoText('双击后移动拖动远端对象；双指移动画布，捏合缩放。',
                                'Double-tap and move to drag; use two fingers to pan and pinch to zoom.')),
                    _instruction(
                        context,
                        NlIcons.keyboard,
                        nikoText('键盘与退出', 'Keyboard and exit'),
                        nikoText('工具栏的键盘按钮可输入文字；关闭按钮结束会话。',
                            'Use the keyboard button to type and the close button to end the session.')),
                    Text(
                        nikoText('完整手势说明可随时从工具栏的触控／鼠标按钮打开。',
                            'Open the touch/mouse button in the toolbar for the full gesture guide.'),
                        style: NlType.text(NlType.s2, color: nl.fg3)),
                  ]))),
              const SizedBox(height: NlSpace.s5),
              Wrap(
                  alignment: WrapAlignment.end,
                  spacing: NlSpace.s2,
                  runSpacing: NlSpace.s2,
                  children: [
                    NlButton.ghost(
                        key: const Key('nikodesk-guide-gestures'),
                        label: nikoText('查看手势', 'View gestures'),
                        onPressed: () => Navigator.pop(context, true)),
                    NlButton(
                        key: const Key('nikodesk-guide-done'),
                        label: nikoText('明白了', 'Got it'),
                        onPressed: () => Navigator.pop(context, false)),
                  ]),
            ]);
      }));

  Widget _instruction(
      BuildContext context, IconData icon, String title, String detail) {
    final nl = NlColors.of(context);
    return Padding(
        padding: const EdgeInsets.only(bottom: NlSpace.s4),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                  color: nl.accentSoft,
                  borderRadius: BorderRadius.circular(NlRadius.r2)),
              child: Icon(icon, size: 18, color: nl.accentText)),
          const SizedBox(width: NlSpace.s3),
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text(title,
                    style: NlType.text(NlType.s4,
                        weight: FontWeight.w600, color: nl.fg)),
                const SizedBox(height: 2),
                Text(detail, style: NlType.text(NlType.s3, color: nl.fg2)),
              ])),
        ]));
  }
}
