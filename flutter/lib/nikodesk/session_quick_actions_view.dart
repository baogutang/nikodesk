import 'package:flutter/material.dart';

import 'nightline.dart';
import 'privacy_screen_policy.dart';
import 'remote_resolution_policy.dart';
import 'session_shortcuts.dart';
import 'settings_kit.dart';
import 'ui.dart';

/// The parts of the control center, one shown at a time.
enum NikoQuickSection { keys, display, privacy }

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

/// The keys of a shortcut as the remote's keyboard prints them: a Mac's
/// symbols in Apple's modifier order, other systems' names joined by "+".
String _keysLabel(NikoShortcutKeys keys, bool mac) {
  final parts = keys.label.split('+');
  final key = switch (parts.last) {
    'LEFT' => '←',
    'RIGHT' => '→',
    'UP' => '↑',
    'DOWN' => '↓',
    final name => name,
  };
  if (!mac) return [...parts.take(parts.length - 1), key].join('+');
  return '${keys.control ? '⌃' : ''}${keys.alt ? '⌥' : ''}'
      '${keys.shift ? '⇧' : ''}${keys.command ? '⌘' : ''}$key';
}

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
  final NikoRemoteResolution? remoteResolution;
  final bool? autoFitResolution;
  final Future<void> Function(NikoDisplayMode)? onRemoteResolution;
  final Future<void> Function(bool)? onAutoFitResolution;
  final NikoCaptureMode? captureMode;
  final Future<void> Function(NikoCaptureMode)? onCaptureMode;

  /// Null hides the section: this kind of session has no privacy screen.
  final NikoPrivacyScreenStatus? privacyScreen;
  final Future<void> Function(bool)? onPrivacyScreen;
  final Widget? privacyStyle;
  final Widget? privacyAuto;
  final bool privacyPasswordExit;
  final VoidCallback onClose;

  /// The section to open on; by default the shortcuts, or the picture when
  /// the remote takes no desktop shortcuts.
  final NikoQuickSection? initialSection;

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
      this.remoteResolution,
      this.autoFitResolution,
      this.onRemoteResolution,
      this.onAutoFitResolution,
      this.captureMode,
      this.onCaptureMode,
      this.privacyScreen,
      this.onPrivacyScreen,
      this.privacyStyle,
      this.privacyAuto,
      this.privacyPasswordExit = false,
      this.initialSection,
      required this.onClose});

  @override
  State<NikoSessionQuickActionsPanel> createState() =>
      _NikoSessionQuickActionsPanelState();
}

class _NikoSessionQuickActionsPanelState
    extends State<NikoSessionQuickActionsPanel> {
  final _scroll = ScrollController();
  late NikoQuickSection _section = widget.initialSection ??
      (_shortcutsSupported ? NikoQuickSection.keys : NikoQuickSection.display);
  bool _busy = false;
  String? _feedback;
  bool _failed = false;

  bool get _shortcutsSupported =>
      nikoShortcutKeys(NikoSessionShortcut.copy, widget.peerPlatform) != null;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _run(
      Future<void> Function() action, String success, String failure) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _feedback = null;
    });
    try {
      await action();
      if (mounted) {
        setState(() {
          _feedback = success;
          _failed = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _feedback = failure;
          _failed = true;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _show(NikoQuickSection section) {
    if (section == _section) return;
    setState(() => _section = section);
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  /// A control that cannot act now stays in place, dimmed.
  Widget _dim(bool enabled, Widget child) => AnimatedOpacity(
      opacity: enabled ? 1 : .45,
      duration: NlMotion.of(context, NlMotion.fast),
      child: child);

  Widget _grid(Iterable<NikoSessionShortcut> shortcuts) {
    final mac = widget.peerPlatform == 'Mac OS';
    final items = [
      for (final shortcut in shortcuts)
        if (nikoShortcutKeys(shortcut, widget.peerPlatform) case final keys?)
          (shortcut, keys),
    ];
    return LayoutBuilder(builder: (context, box) {
      final width = box.maxWidth / MediaQuery.textScalerOf(context).scale(1);
      final columns = width >= 460 ? 3 : (width >= 250 ? 2 : 1);
      const gap = NlSpace.s2;
      final tile =
          ((box.maxWidth - gap * (columns - 1)) / columns).floorToDouble();
      return Wrap(spacing: gap, runSpacing: gap, children: [
        for (final (shortcut, keys) in items)
          SizedBox(
              width: tile,
              child: NikoShortcutKey(
                  key: ValueKey('nikodesk-shortcut-${shortcut.name}'),
                  name: _shortcutName(shortcut),
                  keys: _keysLabel(keys, mac),
                  onPressed: _busy || !widget.keyboardAllowed
                      ? null
                      : () => _run(
                          () => widget.onShortcut(shortcut),
                          nikoText('已发送快捷键，执行结果请查看远端画面。',
                              'Shortcut sent. Check the remote screen for the result.'),
                          nikoText('快捷键未确认发送，请检查会话和远端输入权限后重试。',
                              'Shortcut was not confirmed. Check the session and remote input permission, then retry.')))),
      ]);
    });
  }

  List<Widget> _keys() {
    final desktop =
        {'Windows', 'Mac OS', 'Linux'}.contains(widget.peerPlatform);
    Widget spaced(Widget child) => Padding(
        padding: const EdgeInsets.only(bottom: NlSpace.s5), child: child);
    return [
      if (!_shortcutsSupported)
        spaced(NikoSettingNote(nikoText('此远端系统不支持这些桌面快捷键。',
            'These desktop shortcuts are unavailable on this remote system.')))
      else ...[
        if (!widget.keyboardAllowed)
          spaced(NikoSettingNote(
              nikoText('远端输入当前不可用：请检查只读模式、输入权限和连接状态。',
                  'Remote input is unavailable. Check view-only mode, input permission and connection status.'),
              tone: NlTone.warn)),
        NikoSettingsGroup(
            title: nikoText('常用', 'Common'),
            description: nikoText('快捷键发送到远端当前应用。粘贴使用远端剪贴板；内容同步由剪贴板设置控制。',
                'Shortcuts go to the active remote app. Paste uses the remote clipboard; clipboard settings control content sync.'),
            bottom: NlSpace.s5,
            children: [
              Padding(
                  padding: const EdgeInsets.only(top: NlSpace.s2),
                  child: _grid(NikoSessionShortcut.values.where(
                      (s) => s.index <= NikoSessionShortcut.reload.index))),
            ]),
        if (desktop)
          NikoSettingsGroup(
              title: nikoText('应用与桌面', 'Apps and desktops'),
              description: switch (widget.peerPlatform) {
                'Mac OS' => nikoText(
                    'Mac 全屏应用位于独立桌面（Spaces），可用前后桌面切换。应用切换遵循远端系统设置；若快捷键被自定义，请在远端键盘快捷键设置中核对。',
                    'Mac full-screen apps occupy separate desktops (Spaces). Use previous/next desktop to browse them. App switching follows remote system settings; check remote keyboard shortcut settings if customized.'),
                'Windows' => nikoText('任务总览与桌面切换使用远端 Windows 系统快捷键。',
                    'Task overview and desktop switching use the remote Windows system shortcuts.'),
                _ => null,
              },
              bottom: NlSpace.s5,
              children: [
                Padding(
                    padding: const EdgeInsets.only(top: NlSpace.s2),
                    child: _grid(NikoSessionShortcut.values.where(
                        (s) => s.index > NikoSessionShortcut.reload.index))),
              ]),
      ],
      if (widget.onMacShortcutMode != null)
        NikoSettingsGroup(
            title: nikoText('本地键盘 → Mac', 'Local keyboard → Mac'),
            bottom: 0,
            children: [
              NikoSettingRow(
                  title: nikoText('快捷键映射', 'Shortcut mapping'),
                  description: widget.macShortcutMode ==
                          NikoMacShortcutMode.original
                      ? nikoText('本地 Ctrl → 远端 Control。关闭常用快捷键的自动映射。',
                          'Local Ctrl → remote Control. Common shortcuts stay unchanged.')
                      : nikoText(
                          'Ctrl+C/V/X/A/Z/S/F/P/R → Cmd（不带 Shift/Alt/Win）。Ctrl+方向键和其他组合原样发送；映射与兼容键盘模式均支持，Translate 不作自动映射。',
                          'Ctrl+C/V/X/A/Z/S/F/P/R → Cmd without Shift/Alt/Win. Ctrl+arrows and other combinations stay unchanged. Supported in Map and Legacy; Translate keeps its existing behavior.'),
                  trailing: _dim(
                      widget.keyboardAllowed && widget.macShortcutMode != null,
                      NlSegmented<NikoMacShortcutMode?>(
                          key: const Key('nikodesk-mac-shortcut-mode'),
                          selected: widget.macShortcutMode,
                          segments: [
                            NlSegment(
                                value: NikoMacShortcutMode.automatic,
                                label: nikoText('自动', 'Automatic')),
                            NlSegment(
                                value: NikoMacShortcutMode.original,
                                label: nikoText('原样', 'Original')),
                          ],
                          onChanged: _busy ||
                                  !widget.keyboardAllowed ||
                                  widget.macShortcutMode == null
                              ? null
                              : (mode) {
                                  if (mode == null ||
                                      mode == widget.macShortcutMode) {
                                    return;
                                  }
                                  _run(
                                      () => widget.onMacShortcutMode!(mode),
                                      nikoText('键盘映射已更新，并按设备保存。',
                                          'Keyboard mapping updated and saved for this device.'),
                                      nikoText('未能确认键盘映射，请检查会话后重试。',
                                          'Keyboard mapping could not be confirmed. Check the session and retry.'));
                                }))),
            ]),
    ];
  }

  List<Widget> _display() {
    final canvas = !_busy && widget.canvasAllowed;
    return [
      NikoSettingsGroup(
          title: nikoText('本地画面', 'Local view'),
          bottom: NlSpace.s5,
          children: [
            NikoSettingRow(
                title: nikoText('缩放', 'Scale'),
                description: widget.canvasAllowed
                    ? nikoText('按设备保存。', 'Saved for this device.')
                    : nikoText('远端画面或显示器尺寸尚未就绪。',
                        'Remote video or display dimensions are not ready.'),
                trailing: _dim(
                    widget.canvasAllowed,
                    NlSegmented<String?>(
                        key: const Key('nikodesk-view-style'),
                        selected: widget.viewStyle,
                        segments: [
                          NlSegment(
                              key: const ValueKey('nikodesk-view-adaptive'),
                              value: 'adaptive',
                              label: nikoText('适应窗口', 'Fit window')),
                          NlSegment(
                              key: const ValueKey('nikodesk-view-original'),
                              value: 'original',
                              label: nikoText('原始 1:1', 'Original 1:1')),
                        ],
                        onChanged: !canvas
                            ? null
                            : (style) {
                                if (style == null || style == widget.viewStyle) {
                                  return;
                                }
                                _run(
                                    () => widget.onViewStyle(style),
                                    nikoText('画面缩放已更新，并按设备保存。',
                                        'View scale updated and saved for this device.'),
                                    nikoText('未能确认画面缩放，请等待画面就绪后重试。',
                                        'View scale could not be confirmed. Wait for video to be ready and retry.'));
                              }))),
            if (widget.onResetCanvas != null)
              NikoSettingRow(
                  title: nikoText('重置画布', 'Reset canvas'),
                  description: nikoText('回到初始的位置和缩放。',
                      'Back to the starting position and scale.'),
                  trailing: NlButton.ghost(
                      key: const Key('nikodesk-reset-canvas'),
                      small: true,
                      icon: NlIcons.rotateCcw,
                      label: nikoText('重置', 'Reset'),
                      onPressed: !canvas
                          ? null
                          : () => _run(
                              () async => widget.onResetCanvas!(),
                              nikoText('已重置本地画布位置和缩放。',
                                  'Local canvas position and scale reset.'),
                              nikoText('画布不可用，请等待画面就绪后重试。',
                                  'Canvas unavailable. Wait for video to be ready and retry.')))),
          ]),
      if (widget.onCaptureMode != null) _capture(),
      if (widget.onRemoteResolution != null) _remoteResolution(),
    ];
  }

  Widget _capture() => NikoSettingsGroup(
          title: nikoText('传输画面大小', 'Picture size sent'),
          description: nikoText(
              '只缩小传输的画面，不改变远端显示器的分辨率和窗口布局，远端是 1.0.5 及以上的 Retina Mac 时生效。"标准大小"是每个点一个像素，Retina 屏为原始像素的四分之一；画面更小，要编码和传输的数据更少。',
              'Only the picture sent is scaled; the remote display mode and its window layout stay as they are. It takes effect on a remote Retina Mac on 1.0.5 or later. Standard size is one pixel per point, a quarter of a Retina display\'s pixels; a smaller picture means less to encode and send.'),
          bottom: NlSpace.s5,
          children: [
            Padding(
                padding: const EdgeInsets.symmetric(vertical: NlSpace.s3),
                child: _dim(
                    widget.captureMode != null,
                    NlSegmented<NikoCaptureMode?>(
                        key: const Key('nikodesk-capture-mode'),
                        expand: true,
                        selected: widget.captureMode,
                        segments: [
                          NlSegment(
                              key: const ValueKey('nikodesk-capture-fit'),
                              value: NikoCaptureMode.fit,
                              label: nikoText('适应本机', 'Fit this screen')),
                          NlSegment(
                              key: const ValueKey('nikodesk-capture-small'),
                              value: NikoCaptureMode.small,
                              label: nikoText('标准大小', 'Standard')),
                          NlSegment(
                              key: const ValueKey('nikodesk-capture-native'),
                              value: NikoCaptureMode.native,
                              label: nikoText('原始大小', 'Native')),
                        ],
                        onChanged: _busy || widget.captureMode == null
                            ? null
                            : (mode) {
                                if (mode == null || mode == widget.captureMode) {
                                  return;
                                }
                                _run(
                                    () => widget.onCaptureMode!(mode),
                                    nikoText('已请求并按设备保存。远端是 1.0.5 及以上的 Mac 时，画面约一秒内切换。',
                                        'Requested and saved for this device. A remote Mac on 1.0.5 or later switches within about a second.'),
                                    nikoText('未能保存该选择，请重试。',
                                        'The choice could not be saved. Retry.'));
                              }))),
          ]);

  Widget _remoteResolution() {
    final state = widget.remoteResolution;
    final fit = state?.fit;
    Future<void> change(NikoDisplayMode mode) => _run(
        () => widget.onRemoteResolution!(mode),
        nikoText('已请求远端切换分辨率，画面几秒内更新。',
            'Remote resolution change requested. Video updates within seconds.'),
        nikoText('未能确认分辨率请求，请检查会话和远端输入权限后重试。',
            'Resolution request was not confirmed. Check the session and remote input permission, then retry.'));
    final canMatch =
        !_busy && state != null && fit != null && fit != state.current;
    final canRestore = !_busy && state != null && state.changed;
    return NikoSettingsGroup(
        title: nikoText('远端分辨率', 'Remote resolution'),
        description: state == null
            ? nikoText('需要键鼠权限，并选中单个非虚拟显示器；远端显示信息就绪后可用。',
                'Needs input permission and one selected, non-virtual display; available once remote display details arrive.')
            : nikoText(
                '当前 ${state.current.label}，传输 ${state.capturedPixels.label} 像素。像素更少，要编码和传输的数据也更少；远端屏幕会同步变化。',
                'Now ${state.current.label}, sending ${state.capturedPixels.label} pixels. Fewer pixels mean less to encode and send; the remote screen changes too.'),
        bottom: 0,
        children: [
          NikoSettingRow(
              title: nikoText('匹配本机像素', 'Match this screen'),
              description: fit != null
                  ? fit.label
                  : state == null || state.changed
                      ? null
                      : state.localLongEdge <= 0
                          ? nikoText('未能读取本机屏幕尺寸，无法计算匹配分辨率；可在显示菜单的"分辨率"里手动选择。',
                              'This screen\'s size could not be read, so no match can be computed; pick a mode in the display menu under Resolution.')
                          : nikoText('没有更小且仍能填满本机屏幕的同比例分辨率。',
                              'No smaller mode in the same aspect ratio still fills this screen.'),
              trailing: NlButton.ghost(
                  key: const Key('nikodesk-resolution-fit'),
                  small: true,
                  label: nikoText('切换', 'Switch'),
                  onPressed: canMatch ? () => change(fit) : null)),
          NikoSettingRow(
              title: nikoText('恢复原始', 'Restore original'),
              description: state?.original.label,
              trailing: NlButton.ghost(
                  key: const Key('nikodesk-resolution-original'),
                  small: true,
                  icon: NlIcons.rotateCcw,
                  label: nikoText('恢复', 'Restore'),
                  onPressed:
                      canRestore ? () => change(state.original) : null)),
          if (widget.onAutoFitResolution != null)
            NikoSettingRow(
                title: nikoText('连接这台设备后自动匹配',
                    'Match automatically for this device'),
                description: nikoText('按设备保存；远端已不在原始分辨率时不再切换。',
                    'Saved for this device; skipped when the remote is already in a non-original mode.'),
                trailing: NlSwitch(
                    key: const Key('nikodesk-resolution-auto'),
                    value: widget.autoFitResolution ?? false,
                    onChanged: _busy || widget.autoFitResolution == null
                        ? null
                        : (enabled) => _run(
                            () => widget.onAutoFitResolution!(enabled),
                            enabled
                                ? nikoText('已开启，下次连接这台设备时生效。',
                                    'On. Applies the next time you connect to this device.')
                                : nikoText('已关闭自动匹配。',
                                    'Automatic matching is off.'),
                            nikoText('未能保存该设置，请重试。',
                                'The setting could not be saved. Retry.')))),
        ]);
  }

  List<Widget> _privacy(NikoPrivacyScreenStatus status) {
    final on = status == NikoPrivacyScreenStatus.on;
    final canToggle = nikoPrivacyScreenCanToggle(status);
    return [
      NikoSettingsGroup(bottom: NlSpace.s5, children: [
        NikoSettingRow(
            title: nikoPrivacyScreenLabel(status),
            description: nikoPrivacyScreenDetail(status, widget.peerPlatform,
                styled: widget.privacyStyle != null,
                passwordExit: widget.privacyPasswordExit),
            below: widget.privacyAuto == null && canToggle
                ? Text(
                    nikoText('断开时如果隐私屏开着，下次连接这台设备会自动再开启；想让它每次都开，保持开启即可。',
                        'If it is on when you disconnect, the next connection to this device turns it on again; leave it on to have it every time.'),
                    style: NlType.text(NlType.s2,
                        color: NlColors.of(context).fg3))
                : null,
            trailing: NlSwitch(
                key: const Key('nikodesk-privacy-screen'),
                value: on,
                semanticLabel: nikoText('隐私屏', 'Privacy screen'),
                onChanged: _busy || widget.onPrivacyScreen == null || !canToggle
                    ? null
                    : (value) => _run(
                        () => widget.onPrivacyScreen!(value),
                        value
                            ? nikoText('已请求开启，以上面的状态为准；被控端拒绝或失败时会弹出原因。',
                                'Requested. The state above is what counts; the remote says why if it refuses or fails.')
                            : nikoText('已请求关闭，以上面的状态为准。',
                                'Requested. The state above is what counts.'),
                        nikoText('请求没有发出。请确认会话仍在连接；多显示器的 Windows 被控端需要先切到显示器 1。',
                            'The request was not sent. Check that the session is still connected; a multi-display Windows remote needs display 1 selected first.')))),
        if (widget.privacyAuto != null) widget.privacyAuto!,
      ]),
      if (widget.privacyStyle != null)
        NikoSettingsGroup(
            title: nikoText('样式', 'Style'),
            bottom: 0,
            children: [widget.privacyStyle!]),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final nl = NlColors.of(context);
    final privacy = widget.privacyScreen;
    final sections = [
      NikoQuickSection.keys,
      NikoQuickSection.display,
      if (privacy != null) NikoQuickSection.privacy,
    ];
    final section = sections.contains(_section) ? _section : sections.first;
    final body = switch (section) {
      NikoQuickSection.keys => _keys(),
      NikoQuickSection.display => _display(),
      NikoQuickSection.privacy => _privacy(privacy!),
    };
    return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            Expanded(
                child: Semantics(
                    header: true,
                    child: Text(nikoText('控制中心', 'Control center'),
                        style: NlType.text(NlType.s5,
                            weight: FontWeight.w600, color: nl.fg)))),
            NlIconButton(
                key: const Key('nikodesk-quick-close'),
                icon: NlIcons.close,
                tooltip: nikoText('关闭', 'Close'),
                onPressed: widget.onClose),
          ]),
          const SizedBox(height: NlSpace.s3),
          NlSegmented<NikoQuickSection>(
              key: const Key('nikodesk-quick-sections'),
              expand: true,
              selected: section,
              segments: [
                for (final item in sections)
                  NlSegment(
                      key: ValueKey('nikodesk-quick-${item.name}'),
                      value: item,
                      icon: switch (item) {
                        NikoQuickSection.keys => NlIcons.keyboard,
                        NikoQuickSection.display => NlIcons.monitor,
                        NikoQuickSection.privacy => NlIcons.shieldCheck,
                      },
                      label: switch (item) {
                        NikoQuickSection.keys => nikoText('快捷键', 'Shortcuts'),
                        NikoQuickSection.display => nikoText('画面', 'Display'),
                        NikoQuickSection.privacy =>
                          nikoText('隐私屏', 'Privacy'),
                      }),
              ],
              onChanged: _show),
          const SizedBox(height: NlSpace.s2),
          Flexible(
              child: SingleChildScrollView(
                  controller: _scroll,
                  padding: const EdgeInsets.only(top: NlSpace.s3),
                  child: AnimatedSize(
                      duration: NlMotion.of(context, NlMotion.base),
                      curve: NlMotion.ease,
                      alignment: Alignment.topCenter,
                      child: AnimatedSwitcher(
                          duration: NlMotion.of(context, NlMotion.fast),
                          layoutBuilder: (current, previous) => Stack(
                              alignment: Alignment.topCenter,
                              children: [...previous, if (current != null) current]),
                          child: Column(
                              key: ValueKey(section),
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: body))))),
          if (_feedback != null)
            Padding(
                padding: const EdgeInsets.only(top: NlSpace.s3),
                child: Semantics(
                    liveRegion: true,
                    child: NikoSettingNote(_feedback!,
                        tone: _failed ? NlTone.danger : NlTone.accent))),
        ]);
  }
}

/// A shortcut the control center sends to the remote: its name and the
/// keys it presses, as a tile in a grid.
class NikoShortcutKey extends StatelessWidget {
  final String name;
  final String keys;
  final VoidCallback? onPressed;

  const NikoShortcutKey(
      {super.key, required this.name, required this.keys, this.onPressed});

  @override
  Widget build(BuildContext context) {
    final nl = NlColors.of(context);
    final touch = NlLayout.touch(context);
    final fill = nl.isDark ? nl.surface2 : nl.surface;
    return NlPressable(
        onTap: onPressed,
        pressScale: .98,
        builder: (context, states) {
          final color = states.contains(WidgetState.pressed)
              ? Color.alphaBlend(nl.selected, fill)
              : states.contains(WidgetState.hovered)
                  ? Color.alphaBlend(nl.hover, fill)
                  : fill;
          return AnimatedOpacity(
              opacity: onPressed == null ? .45 : 1,
              duration: NlMotion.of(context, NlMotion.fast),
              child: AnimatedContainer(
                  duration: NlMotion.of(context, NlMotion.instant),
                  constraints: BoxConstraints(minHeight: touch ? 48 : 40),
                  padding: const EdgeInsets.symmetric(
                      horizontal: NlSpace.s3, vertical: NlSpace.s2),
                  decoration: BoxDecoration(
                      color: color,
                      borderRadius: BorderRadius.circular(NlRadius.r2),
                      border: Border.all(color: nl.line),
                      boxShadow: states.contains(WidgetState.focused)
                          ? nl.focusRing
                          : null),
                  child: Row(children: [
                    Expanded(
                        child: Text(name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: NlType.text(NlType.s3,
                                weight: FontWeight.w500, color: nl.fg))),
                    const SizedBox(width: NlSpace.s2),
                    NlKbd(keys),
                  ])));
        });
  }
}
