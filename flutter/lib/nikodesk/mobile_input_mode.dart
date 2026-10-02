import 'package:flutter/material.dart';

import 'ui.dart';

class NikoMobileInputMode extends StatelessWidget {
  final bool touchMode;
  final ValueChanged<bool> onChanged;

  const NikoMobileInputMode({super.key, required this.touchMode,
      required this.onChanged});

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      for (final mode in [false, true]) RadioListTile<bool>(
        key: ValueKey('nikodesk-mobile-input-mode-$mode'),
        contentPadding: EdgeInsets.zero,
        value: mode,
        groupValue: touchMode,
        selected: mode == touchMode,
        title: Text(mode ? nikoText('触摸模式', 'Touch mode')
            : nikoText('鼠标模式', 'Mouse mode')),
        secondary: Icon(mode ? Icons.touch_app : Icons.mouse),
        onChanged: (value) {
          if (value != null && value != touchMode) onChanged(value);
        },
      ),
    ],
  );
}
