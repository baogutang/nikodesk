import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'nightline.dart';
import 'ui.dart';

const nikoScreenRecordingPane =
    'x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture';
const nikoAccessibilityPane =
    'x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility';

/// Local option set when the user asks not to be reminded again.
const nikoPermissionGuideOption = 'nikodesk-permission-guide';

Future<void> nikoOpenPrivacyPane(String pane) async {
  await launchUrl(Uri.parse(pane));
}

/// The two macOS permissions a controlled Mac needs, shown at launch while
/// one is missing: on a first launch, and after an update whose new
/// signature no longer matches the old grants. The checks are read again
/// every second, so the rows follow what the user does in System Settings.
class NikoPermissionGuide extends StatefulWidget {
  final bool Function() screenRecording;
  final bool Function() accessibility;
  final VoidCallback requestScreenRecording;
  final VoidCallback requestAccessibility;

  /// Leaves the guide for this launch.
  final VoidCallback onContinue;

  /// Leaves the guide and stops showing it at launch.
  final VoidCallback onSilence;

  const NikoPermissionGuide(
      {super.key,
      required this.screenRecording,
      required this.accessibility,
      required this.requestScreenRecording,
      required this.requestAccessibility,
      required this.onContinue,
      required this.onSilence});

  @override
  State<NikoPermissionGuide> createState() => _NikoPermissionGuideState();
}

class _NikoPermissionGuideState extends State<NikoPermissionGuide> {
  late bool _screen = widget.screenRecording();
  late bool _input = widget.accessibility();
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _read());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _read() {
    final screen = widget.screenRecording();
    final input = widget.accessibility();
    if (mounted && (screen != _screen || input != _input)) {
      setState(() {
        _screen = screen;
        _input = input;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final nl = NlColors.of(context);
    final ready = _screen && _input;
    return ColoredBox(
        color: nl.page,
        child: SafeArea(
            child: Center(
                child: SingleChildScrollView(
                    padding: const EdgeInsets.all(NlSpace.s6),
                    child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 560),
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Row(children: [
                                const NlMark(size: 28),
                                const SizedBox(width: NlSpace.s3),
                                NlMonoLabel(nikoText('系统权限', 'Permissions')),
                              ]),
                              const SizedBox(height: NlSpace.s5),
                              Text(
                                  ready
                                      ? nikoText('这台 Mac 已可以被远程控制',
                                          'This Mac can now be controlled')
                                      : nikoText('让这台 Mac 可以被远程控制',
                                          'Let this Mac be controlled remotely'),
                                  style: NlType.text(NlType.s6,
                                      weight: FontWeight.w600, color: nl.fg)),
                              const SizedBox(height: NlSpace.s2),
                              Text(
                                  ready
                                      ? nikoText('两项权限都已授权，远端可以看到画面并操作键盘和鼠标。',
                                          'Both are allowed: the other side can see this screen and use the keyboard and mouse.')
                                      : nikoText(
                                          '被远程控制时需要下面两项 macOS 权限。只用这台 Mac 去控制别的设备，可以跳过。',
                                          'macOS needs these two permissions before this Mac can be controlled. Skip them if you only use it to control other devices.'),
                                  style: NlType.text(NlType.s3, color: nl.fg2)),
                              const SizedBox(height: NlSpace.s5),
                              NlPanel(
                                  child: Column(children: [
                                _row(
                                    nl,
                                    nikoText('屏幕录制', 'Screen recording'),
                                    nikoText('让远端看到这台 Mac 的画面',
                                        'Lets the other side see this screen'),
                                    _screen,
                                    widget.requestScreenRecording,
                                    divider: false),
                                _row(
                                    nl,
                                    nikoText('辅助功能', 'Accessibility'),
                                    nikoText('让远端操作键盘和鼠标',
                                        'Lets the other side use the keyboard and mouse'),
                                    _input,
                                    widget.requestAccessibility),
                              ])),
                              if (!ready) ...[
                                const SizedBox(height: NlSpace.s4),
                                _hint(
                                    nl,
                                    nikoText(
                                        '在系统设置中打开 NikoDesk 的开关。屏幕录制授权后，系统会提示退出并重新打开 NikoDesk，照做即可。',
                                        'Turn NikoDesk on in System Settings. After allowing screen recording, quit and reopen NikoDesk when macOS asks.')),
                                const SizedBox(height: NlSpace.s2),
                                _hint(
                                    nl,
                                    nikoText(
                                        '列表里已有 NikoDesk 且开关是开的，这里却仍未授权：那是更新前的旧记录。先关掉再打开；仍不行就选中它点「−」删除，再点「+」添加「应用程序」中的 NikoDesk。',
                                        'NikoDesk is listed and on, but still not allowed here? That entry belongs to the version before the update. Turn it off and on again; if that does not help, remove it with "−" and add NikoDesk from Applications with "+".')),
                              ],
                              const SizedBox(height: NlSpace.s6),
                              Wrap(
                                  alignment: WrapAlignment.spaceBetween,
                                  spacing: NlSpace.s2,
                                  runSpacing: NlSpace.s2,
                                  children: [
                                if (!ready)
                                  NlButton.ghost(
                                      onPressed: widget.onSilence,
                                      label: nikoText('不再提醒', 'Don\'t remind me'))
                                else
                                  const SizedBox.shrink(),
                                if (ready)
                                  NlButton(
                                      onPressed: widget.onContinue,
                                      label: nikoText(
                                          '进入 NikoDesk', 'Open NikoDesk'))
                                else
                                  NlButton.ghost(
                                      onPressed: widget.onContinue,
                                      label: nikoText('跳过，进入 NikoDesk',
                                          'Skip for now')),
                              ]),
                            ]))))));
  }

  /// A narrow window puts the action under the text instead of beside it.
  Widget _row(NlColors nl, String title, String reason, bool granted,
          VoidCallback request,
          {bool divider = true}) =>
      LayoutBuilder(builder: (context, constraints) {
        final action = granted
            ? Text(nikoText('已授权', 'Allowed'),
                style: NlType.text(NlType.s2, color: nl.okText))
            : NlButton.ghost(
                small: true,
                onPressed: request,
                label: nikoText('打开系统设置', 'Open System Settings'));
        final narrow = constraints.maxWidth <
            420 * MediaQuery.textScalerOf(context).scale(1);
        final row = NlListRow(
            divider: divider,
            leading: NlLed(granted ? NlLedState.ok : NlLedState.warn),
            title: title,
            subtitle: reason,
            trailing: narrow ? null : action);
        if (!narrow) return row;
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          row,
          Padding(
              padding: const EdgeInsets.only(
                  left: NlLed.size + NlSpace.s3, bottom: NlSpace.s2),
              child: Align(alignment: Alignment.centerLeft, child: action)),
        ]);
      });

  Widget _hint(NlColors nl, String text) =>
      Text(text, style: NlType.text(NlType.s2, color: nl.fg3));
}
