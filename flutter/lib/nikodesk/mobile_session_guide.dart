import 'package:flutter/material.dart';

import 'ui.dart';

const nikoMobileGuideSeenKey = 'nikodesk-mobile-session-guide-v1';

/// Offered by the real session page only after its first decoded frame.
class NikoMobileSessionGuide extends StatelessWidget {
  final bool touchMode;
  const NikoMobileSessionGuide({super.key, required this.touchMode});

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(nikoText('开始操作远端', 'Control the remote computer')),
        content: ConstrainedBox(
          constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * .55),
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              _instruction(
                  Icons.touch_app_outlined,
                  nikoText('单击与右键', 'Click and right-click'),
                  nikoText('单指轻点为左键，长按为右键。',
                      'Tap for a left-click; long-press for a right-click.')),
              _instruction(
                  Icons.open_with,
                  nikoText('拖动与缩放', 'Drag and zoom'),
                  touchMode
                      ? nikoText('单指移动拖动远端对象；双指移动画布，捏合缩放。',
                          'Move one finger to drag; use two fingers to pan and pinch to zoom.')
                      : nikoText('双击后移动拖动远端对象；双指移动画布，捏合缩放。',
                          'Double-tap and move to drag; use two fingers to pan and pinch to zoom.')),
              _instruction(
                  Icons.keyboard_outlined,
                  nikoText('键盘与退出', 'Keyboard and exit'),
                  nikoText('工具栏的键盘按钮可输入文字；关闭按钮结束会话。',
                      'Use the keyboard button to type and the close button to end the session.')),
              Text(nikoText('完整手势说明可随时从工具栏的触控／鼠标按钮打开。',
                  'Open the touch/mouse button in the toolbar for the full gesture guide.')),
            ]),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(nikoText('查看手势', 'View gestures'))),
          FilledButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(nikoText('明白了', 'Got it'))),
        ],
      );

  Widget _instruction(IconData icon, String title, String detail) => Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon),
          const SizedBox(width: 12),
          Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text(detail),
            ]),
          ),
        ]),
      );
}
