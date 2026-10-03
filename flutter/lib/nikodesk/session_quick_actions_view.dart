import 'package:flutter/material.dart';

import 'session_shortcuts.dart';
import 'ui.dart';

String _shortcutName(NikoSessionShortcut shortcut) => switch (shortcut) {
      NikoSessionShortcut.copy => nikoText('复制', 'Copy'),
      NikoSessionShortcut.paste => nikoText('粘贴', 'Paste'),
      NikoSessionShortcut.cut => nikoText('剪切', 'Cut'),
      NikoSessionShortcut.selectAll => nikoText('全选', 'Select all'),
      NikoSessionShortcut.undo => nikoText('撤销', 'Undo'),
      NikoSessionShortcut.save => nikoText('保存', 'Save'),
      NikoSessionShortcut.find => nikoText('查找', 'Find'),
      NikoSessionShortcut.print => nikoText('打印', 'Print'),
      NikoSessionShortcut.reload => nikoText('刷新', 'Reload'),
      NikoSessionShortcut.switchApp => nikoText('切换应用', 'Switch app'),
      NikoSessionShortcut.previousApp => nikoText('反向切换应用', 'Previous app'),
      NikoSessionShortcut.previousDesktop =>
        nikoText('上一个桌面', 'Previous desktop'),
      NikoSessionShortcut.nextDesktop => nikoText('下一个桌面', 'Next desktop'),
      NikoSessionShortcut.taskOverview => nikoText('任务总览', 'Task overview'),
      NikoSessionShortcut.appWindows => nikoText('应用窗口', 'App windows'),
    };

class NikoSessionQuickActionsPanel extends StatefulWidget {
  final String peerPlatform;
  final bool keyboardAllowed;
  final bool canvasAllowed;
  final String? viewStyle;
  final NikoMacShortcutMode? macShortcutMode;
  final Future<void> Function(NikoMacShortcutMode)? onMacShortcutMode;
  final Future<void> Function(NikoSessionShortcut) onShortcut;
  final Future<void> Function(String) onViewStyle;
  final VoidCallback? onResetCanvas;
  final VoidCallback onClose;

  const NikoSessionQuickActionsPanel(
      {super.key,
      required this.peerPlatform,
      required this.keyboardAllowed,
      required this.canvasAllowed,
      required this.viewStyle,
      this.macShortcutMode,
      this.onMacShortcutMode,
      required this.onShortcut,
      required this.onViewStyle,
      this.onResetCanvas,
      required this.onClose});

  @override
  State<NikoSessionQuickActionsPanel> createState() =>
      _NikoSessionQuickActionsPanelState();
}

class _NikoSessionQuickActionsPanelState
    extends State<NikoSessionQuickActionsPanel> {
  bool _busy = false;
  String? _feedback;

  Future<void> _run(
      Future<void> Function() action, String success, String failure) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _feedback = null;
    });
    try {
      await action();
      if (mounted) setState(() => _feedback = success);
    } catch (_) {
      if (mounted) setState(() => _feedback = failure);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _shortcuts(Iterable<NikoSessionShortcut> shortcuts) =>
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final shortcut in shortcuts)
          if (nikoShortcutKeys(shortcut, widget.peerPlatform) case final keys?)
            OutlinedButton(
              key: ValueKey('nikodesk-shortcut-${shortcut.name}'),
              onPressed: _busy || !widget.keyboardAllowed
                  ? null
                  : () => _run(
                      () => widget.onShortcut(shortcut),
                      nikoText('已发送快捷键，执行结果请查看远端画面。',
                          'Shortcut sent. Check the remote screen for the result.'),
                      nikoText('快捷键未确认发送，请检查会话和远端输入权限后重试。',
                          'Shortcut was not confirmed. Check the session and remote input permission, then retry.')),
              child: Text('${_shortcutName(shortcut)} · ${keys.label}'),
            ),
      ]);

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(nikoText('控制中心', 'Control center'),
                style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 8),
            Text(nikoText('快捷键发送到远端当前应用。粘贴使用远端剪贴板；内容同步由剪贴板设置控制。',
                'Shortcuts go to the active remote app. Paste uses the remote clipboard; clipboard settings control content sync.')),
            const SizedBox(height: 16),
            if (widget.onMacShortcutMode != null) ...[
              Text(nikoText('本地键盘 → Mac', 'Local keyboard → Mac'),
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              DropdownButtonFormField<NikoMacShortcutMode>(
                key: const Key('nikodesk-mac-shortcut-mode'),
                value: widget.macShortcutMode,
                isExpanded: true,
                decoration: InputDecoration(
                    labelText: nikoText('快捷键映射', 'Shortcut mapping')),
                items: [
                  DropdownMenuItem(
                      value: NikoMacShortcutMode.automatic,
                      child: Text(nikoText('自动', 'Automatic'))),
                  DropdownMenuItem(
                      value: NikoMacShortcutMode.original,
                      child: Text(nikoText('原样', 'Original'))),
                ],
                onChanged: _busy ||
                        !widget.keyboardAllowed ||
                        widget.macShortcutMode == null
                    ? null
                    : (mode) {
                        if (mode == null) return;
                        _run(
                            () => widget.onMacShortcutMode!(mode),
                            nikoText('键盘映射已更新，并按设备保存。',
                                'Keyboard mapping updated and saved for this device.'),
                            nikoText('未能确认键盘映射，请检查会话后重试。',
                                'Keyboard mapping could not be confirmed. Check the session and retry.'));
                      },
              ),
              const SizedBox(height: 8),
              Text(widget.macShortcutMode == NikoMacShortcutMode.original
                  ? nikoText('本地 Ctrl → 远端 Control。关闭常用快捷键的自动映射。',
                      'Local Ctrl → remote Control. Common shortcuts stay unchanged.')
                  : nikoText(
                      'Ctrl+C/V/X/A/Z/S/F/P/R → Cmd（不带 Shift/Alt/Win）。Ctrl+方向键和其他组合原样发送；映射与兼容键盘模式均支持，Translate 不作自动映射。',
                      'Ctrl+C/V/X/A/Z/S/F/P/R → Cmd without Shift/Alt/Win. Ctrl+arrows and other combinations stay unchanged. Supported in Map and Legacy; Translate keeps its existing behavior.')),
              const SizedBox(height: 16),
            ],
            Text(nikoText('常用快捷键', 'Common shortcuts'),
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            _shortcuts(NikoSessionShortcut.values
                .where((s) => s.index <= NikoSessionShortcut.reload.index)),
            if ({'Windows', 'Mac OS', 'Linux'}
                .contains(widget.peerPlatform)) ...[
              const SizedBox(height: 16),
              Text(nikoText('应用与桌面', 'Apps and desktops'),
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              _shortcuts(NikoSessionShortcut.values
                  .where((s) => s.index > NikoSessionShortcut.reload.index)),
              const SizedBox(height: 8),
              if (widget.peerPlatform == 'Mac OS')
                Text(nikoText(
                    'Mac 全屏应用位于独立桌面（Spaces），可用前后桌面切换。应用切换遵循远端系统设置；若快捷键被自定义，请在远端键盘快捷键设置中核对。',
                    'Mac full-screen apps occupy separate desktops (Spaces). Use previous/next desktop to browse them. App switching follows remote system settings; check remote keyboard shortcut settings if customized.')),
              if (widget.peerPlatform == 'Windows')
                Text(nikoText('任务总览与桌面切换使用远端 Windows 系统快捷键。',
                    'Task overview and desktop switching use the remote Windows system shortcuts.')),
            ],
            if (nikoShortcutKeys(
                    NikoSessionShortcut.copy, widget.peerPlatform) ==
                null)
              Text(nikoText('此远端系统不支持这些桌面快捷键。',
                  'These desktop shortcuts are unavailable on this remote system.'))
            else if (!widget.keyboardAllowed)
              Text(nikoText('远端输入当前不可用：请检查只读模式、输入权限和连接状态。',
                  'Remote input is unavailable. Check view-only mode, input permission and connection status.')),
            const SizedBox(height: 16),
            const Divider(),
            Text(nikoText('本地画面', 'Local view'),
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final style in ['adaptive', 'original'])
                OutlinedButton.icon(
                  key: ValueKey('nikodesk-view-$style'),
                  icon: Icon(style == widget.viewStyle
                      ? Icons.check
                      : style == 'adaptive'
                          ? Icons.fit_screen
                          : Icons.crop_free),
                  label: Text(style == 'adaptive'
                      ? nikoText('适应窗口', 'Fit window')
                      : nikoText('原始 1:1', 'Original 1:1')),
                  onPressed: _busy || !widget.canvasAllowed
                      ? null
                      : () => _run(
                          () => widget.onViewStyle(style),
                          nikoText('画面缩放已更新，并按设备保存。',
                              'View scale updated and saved for this device.'),
                          nikoText('未能确认画面缩放，请等待画面就绪后重试。',
                              'View scale could not be confirmed. Wait for video to be ready and retry.')),
                ),
              if (widget.onResetCanvas != null)
                OutlinedButton.icon(
                  key: const Key('nikodesk-reset-canvas'),
                  icon: const Icon(Icons.center_focus_strong),
                  label: Text(nikoText('重置画布', 'Reset canvas')),
                  onPressed: _busy || !widget.canvasAllowed
                      ? null
                      : () => _run(
                          () async => widget.onResetCanvas!(),
                          nikoText('已重置本地画布位置和缩放。',
                              'Local canvas position and scale reset.'),
                          nikoText('画布不可用，请等待画面就绪后重试。',
                              'Canvas unavailable. Wait for video to be ready and retry.')),
                ),
            ]),
            if (!widget.canvasAllowed)
              Text(nikoText('远端画面或显示器尺寸尚未就绪。',
                  'Remote video or display dimensions are not ready.')),
            if (_feedback != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Semantics(liveRegion: true, child: Text(_feedback!)),
              ),
            const SizedBox(height: 16),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: TextButton(
                  onPressed: widget.onClose,
                  child: Text(nikoText('关闭', 'Close'))),
            ),
          ],
        ),
      );
}
