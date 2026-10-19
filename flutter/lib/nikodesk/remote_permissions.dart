import 'package:flutter/material.dart';

import '../models/model.dart' show FFI, ConnType;
import 'ui.dart';

/// System permissions the controlled Mac reported missing when this session
/// started. Null when it reported none missing or did not report at all
/// (older versions and other platforms).
({bool screen, bool input})? nikoRemoteMissingPermissions(
    Map<String, dynamic> platformAdditions) {
  final reported = platformAdditions['nikodesk_permissions'];
  if (reported is! Map) return null;
  final screen = reported['screen_recording'] == false;
  final input = reported['accessibility'] == false;
  return screen || input ? (screen: screen, input: input) : null;
}

/// Explains, for the whole session, why the picture is empty or input does
/// nothing when the controlled Mac lacks a system permission. Shown until
/// dismissed; the state is read at connection time, so a grant made during
/// the session shows only after reconnecting.
class NikoRemotePermissionNotice extends StatefulWidget {
  final FFI ffi;
  const NikoRemotePermissionNotice({super.key, required this.ffi});
  @override
  State<NikoRemotePermissionNotice> createState() => _NoticeState();
}

class _NoticeState extends State<NikoRemotePermissionNotice> {
  Map<String, dynamic>? _dismissedFor;

  @override
  void initState() {
    super.initState();
    widget.ffi.ffiModel.addListener(_refresh);
  }

  @override
  void dispose() {
    widget.ffi.ffiModel.removeListener(_refresh);
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final additions = widget.ffi.ffiModel.pi.platformAdditions;
    final missing = nikoRemoteMissingPermissions(additions);
    if (widget.ffi.connType != ConnType.defaultConn ||
        missing == null ||
        identical(_dismissedFor, additions)) {
      return const SizedBox.shrink();
    }
    return Positioned(
        left: 12,
        right: 12,
        bottom: 12,
        child: Align(
            alignment: Alignment.bottomCenter,
            child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: NikoRemotePermissionView(
                    screen: missing.screen,
                    input: missing.input,
                    onDismiss: () =>
                        setState(() => _dismissedFor = additions)))));
  }
}

class NikoRemotePermissionView extends StatelessWidget {
  final bool screen, input;
  final VoidCallback onDismiss;
  const NikoRemotePermissionView(
      {super.key,
      required this.screen,
      required this.input,
      required this.onDismiss});

  @override
  Widget build(BuildContext context) {
    final lines = <String>[
      if (screen)
        nikoText(
            '未授予「屏幕录制」：画面会缺失或只显示桌面背景。请在对方电脑的 系统设置 → 隐私与安全性 → 屏幕录制 中勾选 NikoDesk，然后重新连接。',
            'Screen Recording is not allowed: the picture will be missing or show only the desktop background. On that computer, enable NikoDesk in System Settings → Privacy & Security → Screen Recording, then reconnect.'),
      if (input)
        nikoText(
            '未授予「辅助功能」：键盘和鼠标操作不会生效。请在对方电脑的 系统设置 → 隐私与安全性 → 辅助功能 中勾选 NikoDesk。',
            'Accessibility is not allowed: keyboard and mouse input will have no effect. On that computer, enable NikoDesk in System Settings → Privacy & Security → Accessibility.'),
    ];
    return Material(
        key: const Key('remote-permission-notice'),
        color: const Color(0xff2b2219),
        borderRadius: BorderRadius.circular(12),
        elevation: 6,
        child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                      nikoText('对方电脑缺少系统权限',
                          'The remote computer is missing a system permission'),
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w600)),
                  for (final line in lines)
                    Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(line,
                            style: const TextStyle(
                                color: Colors.white70, fontSize: 13))),
                  Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                          key: const Key('remote-permission-dismiss'),
                          onPressed: onDismiss,
                          child: Text(nikoText('知道了', 'Got it')))),
                ])));
  }
}
