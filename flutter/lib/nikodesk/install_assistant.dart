import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;

import 'home_board.dart';
import 'nightline.dart';
import 'policy.dart';
import 'product_build_info.dart';
import 'server_gateway.dart';
import 'server_settings.dart';
import 'ui.dart';
import 'unattended_install.dart';
import 'unattended_install_native.dart';
import 'unattended_install_view.dart';
import 'windows_install.dart';

// This only selects a visible UI. Native release pins and consent remain mandatory.
bool nikoInstallAssistantRequested() =>
    const bool.fromEnvironment('NIKODESK') &&
    Platform.isWindows &&
    Platform.environment['NIKODESK_SETUP_ASSISTANT'] == '1';

/// Settings > Apps > Uninstall starts the GUI with [nikoUninstallArgument].
bool nikoUninstallRequested(List<String> arguments) =>
    const bool.fromEnvironment('NIKODESK') &&
    Platform.isWindows &&
    arguments.contains(nikoUninstallArgument);

Future<void> showNikoInstallAssistant(BuildContext context) => showNlDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const NikoInstallAssistant());

Future<void> showNikoUninstallAssistant(BuildContext context) =>
    showNlDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => const NikoUninstallAssistant());

String _setupBeside(String executable) =>
    path.windows.join(path.windows.dirname(executable), 'nikodesk-setup.exe');

/// A dialog frame for the assistants, wider than [NlDialog] and with its
/// actions pinned below the scrolling steps.
class _Frame extends StatelessWidget {
  final String title;
  final String message;
  final List<Widget> children;
  final List<Widget> actions;
  const _Frame(
      {required this.title,
      required this.message,
      required this.children,
      required this.actions});

  @override
  Widget build(BuildContext context) {
    final nl = NlColors.of(context);
    return NlDialog(
        width: 640,
        icon: const NlMark(size: 36),
        title: title,
        message: message,
        content: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: NlSpace.s2),
              Divider(height: 1, color: nl.line),
              ...children,
            ]),
        actions: actions);
  }
}

/// One numbered step: the number, its title and what it needs.
class _Step extends StatelessWidget {
  final int number;
  final String title;
  final bool done;
  final Widget child;
  const _Step(
      {required this.number,
      required this.title,
      required this.done,
      required this.child});

  @override
  Widget build(BuildContext context) {
    final nl = NlColors.of(context);
    return Padding(
        padding: const EdgeInsets.only(top: NlSpace.s5),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
              width: 24,
              height: 24,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: done ? nl.okSoft : nl.surface2),
              child: done
                  ? Icon(NlIcons.check, size: 14, color: nl.okText)
                  : Text('$number',
                      style: NlType.text(NlType.s2,
                          weight: FontWeight.w600, color: nl.fg2))),
          const SizedBox(width: NlSpace.s3),
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(title,
                        style: NlType.text(NlType.s4,
                            weight: FontWeight.w600, color: nl.fg))),
                const SizedBox(height: NlSpace.s2),
                child,
              ])),
        ]));
  }
}

class NikoInstallAssistant extends StatefulWidget {
  final ServerGateway? gateway;
  final NikoUnattendedInstall? model;
  final String? setup;
  final NikoWindowsInstall? windows;

  /// The product version for the Apps entry; tests replace the native read.
  final Future<String?> Function()? readVersion;
  const NikoInstallAssistant(
      {super.key,
      this.gateway,
      this.model,
      this.setup,
      this.windows,
      this.readVersion});
  @override
  State<NikoInstallAssistant> createState() => _AssistantState();
}

class _AssistantState extends State<NikoInstallAssistant> {
  late final _gateway = widget.gateway ?? NativeServerGateway();
  late final _model = widget.model ?? nativeNikoUnattendedInstall();
  late final _windows = widget.windows ?? NikoWindowsInstall();
  late final _setup = widget.setup ?? _setupBeside(Platform.resolvedExecutable);
  ServerSnapshot? _server;
  bool _loading = true, _editing = false;
  String? _error;

  /// null until the service is confirmed; then whether this copy now has
  /// its Start menu shortcut and Apps entry.
  bool? _registered;

  bool get _installed =>
      _model.operationConfirmed &&
      const {'install', 'upgrade', 'repair'}.contains(_model.reply?.action);

  @override
  void initState() {
    super.initState();
    _model.addListener(_changed);
    _readServer();
  }

  void _changed() {
    if (!mounted) return;
    setState(() {});
    if (_installed && _registered == null) _register();
  }

  Future<void> _register() async {
    _registered = false;
    var ok = false;
    try {
      final version = await (widget.readVersion ??
          () async => (await ProductBuildInfo.read()).version)();
      ok = await _windows.register(version: version ?? '');
    } catch (_) {
      ok = false;
    }
    if (mounted) setState(() => _registered = ok);
    // Earlier releases' folders; whatever is in use stays for next time.
    if (ok) unawaited(_windows.removeOtherCopies().catchError((_) {}));
  }

  Future<void> _readServer() async {
    try {
      final snapshot = await _gateway.read();
      if (!mounted) return;
      setState(() {
        _server = snapshot;
        _error = null;
        _loading = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _server = null;
          _loading = false;
          _error = nikoText('读不到服务器设置，请重试。',
              'Server settings could not be read. Retry.');
        });
      }
    }
  }

  Future<void> _configure() async {
    if (_editing || _model.busy || _model.hasJob || _model.uncertain) return;
    setState(() => _editing = true);
    await showNikoServerSettings(context, _gateway,
        _server?.config ?? const PrivateServerConfig('', '', ''));
    if (!mounted) return;
    setState(() => _editing = false);
    await _readServer();
    if (mounted) await _model.refresh();
  }

  @override
  void dispose() {
    _model.removeListener(_changed);
    super.dispose();
  }

  Widget _done(BuildContext context) {
    final nl = NlColors.of(context);
    final id = _model.reply?.machineId ?? '';
    return Padding(
        padding: const EdgeInsets.only(top: NlSpace.s5),
        child: NlPanel(
            padding: const EdgeInsets.all(NlSpace.s5),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Icon(NlIcons.circleCheck, size: 18, color: nl.okText),
                    const SizedBox(width: NlSpace.s2),
                    Text(nikoText('安装完成', 'Installed'),
                        style: NlType.text(NlType.s4,
                            weight: FontWeight.w600, color: nl.fg)),
                  ]),
                  const SizedBox(height: NlSpace.s4),
                  Text(nikoText('这台电脑的设备代码', 'This computer’s device code'),
                      style: NlType.text(NlType.s2, color: nl.fg2)),
                  const SizedBox(height: NlSpace.s1),
                  Row(children: [
                    Flexible(
                        child: SelectableText(nikoGroupedId(id),
                            key: const Key('install-assistant-machine-id'),
                            style: NlType.text(26,
                                    weight: FontWeight.w600, color: nl.fg)
                                .copyWith(
                                    letterSpacing: 0,
                                    fontFeatures: const [
                                  FontFeature.tabularFigures()
                                ]))),
                    const SizedBox(width: NlSpace.s2),
                    NlIconButton(
                        icon: NlIcons.copy,
                        tooltip: nikoText('复制设备代码', 'Copy device code'),
                        onPressed: id.isEmpty
                            ? null
                            : () => Clipboard.setData(ClipboardData(text: id))),
                  ]),
                  const SizedBox(height: NlSpace.s3),
                  Text(
                      nikoText(
                          '这是新的代码，和之前便携版的不同。在 Mac、iPad 上用它连接，密码是刚才设的服务密码。',
                          'This is a new code, not the portable one. Connect to it from your Mac or iPad with the service password you just set.'),
                      style: NlType.text(NlType.s3, color: nl.fg2)),
                  const SizedBox(height: NlSpace.s2),
                  Text(
                      switch (_registered) {
                        true => nikoText(
                            '开始菜单里已经有 NikoDesk；要卸载，在 Windows 的「设置 → 应用」里找 NikoDesk。',
                            'NikoDesk is in the Start menu. To remove it, find NikoDesk in Windows Settings > Apps.'),
                        false => nikoText(
                            '服务已装好，但开始菜单和「设置 → 应用」的入口没能添加。可以重新运行安装程序再试。',
                            'The service is installed, but the Start menu and Apps entries could not be added. Run the installer again to retry.'),
                        null => nikoText('正在添加开始菜单入口…', 'Adding the Start menu entry…'),
                      },
                      style: NlType.text(NlType.s3,
                          color: _registered == false ? nl.warnText : nl.fg2)),
                ])));
  }

  @override
  Widget build(BuildContext context) {
    final nl = NlColors.of(context);
    final ready = _server?.config.isValid == true && _server?.enabled == true;
    return _Frame(
        title: nikoText('安装 NikoDesk', 'Install NikoDesk'),
        message: nikoText(
            '装好后，NikoDesk 作为后台服务运行。这台电脑锁屏、在登录界面或弹出管理员确认时，也能从别的设备远程操作。',
            'Once installed, NikoDesk runs as a background service, so this computer can be operated remotely even when it is locked, at the sign-in screen or asking for administrator approval.'),
        actions: [
          _installed
              ? NlButton(
                  key: const Key('install-assistant-close'),
                  label: nikoText('完成', 'Done'),
                  onPressed: () => Navigator.of(context).pop())
              : NlButton.ghost(
                  key: const Key('install-assistant-close'),
                  label: nikoText('以后再装', 'Not now'),
                  onPressed: () => Navigator.of(context).pop()),
        ],
        children: [
          if (_installed)
            _done(context)
          else ...[
            _Step(
                number: 1,
                title: nikoText('连上自己的服务器', 'Connect to your server'),
                done: ready,
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (_loading)
                        const NlSkeleton(height: 16, width: 220)
                      else
                        Text(
                            _error ??
                                (ready
                                    ? nikoText('当前服务器：${_server!.config.idServer}',
                                        'Current server: ${_server!.config.idServer}')
                                    : nikoText('还没有设置服务器。服务会用它注册这台电脑。',
                                        'No server yet. The service registers this computer with it.')),
                            style: NlType.text(NlType.s3,
                                color: _error != null ? nl.dangerText : nl.fg2)),
                      const SizedBox(height: NlSpace.s3),
                      NlButton.ghost(
                          key: const Key('install-assistant-server'),
                          small: true,
                          icon: _error != null ? NlIcons.rotateCw : NlIcons.server,
                          label: _error != null
                              ? nikoText('重试', 'Retry')
                              : ready
                                  ? nikoText('修改服务器', 'Change server')
                                  : nikoText('设置服务器', 'Set up server'),
                          onPressed: _loading ||
                                  _editing ||
                                  _model.busy ||
                                  _model.hasJob ||
                                  _model.uncertain
                              ? null
                              : _error != null
                                  ? _readServer
                                  : _configure),
                    ])),
            _Step(
                number: 2,
                title: nikoText('设置服务密码并安装', 'Set a service password and install'),
                done: false,
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                          nikoText(
                              '别的设备连这台电脑时用这个密码。点安装后，先在本机确认，再在 Windows 的管理员确认窗口点「是」。',
                              'Other devices use this password to connect. After you choose install, confirm here and then choose Yes in Windows’ administrator prompt.'),
                          style: NlType.text(NlType.s3, color: nl.fg2)),
                      const SizedBox(height: NlSpace.s3),
                      NikoUnattendedInstallView(
                          model: _model, initialSetup: _setup, assistant: true),
                    ])),
          ],
        ]);
  }
}

/// Settings > Apps > Uninstall: removes the service through the broker,
/// then this user's shortcut, Apps entry and program folder.
class NikoUninstallAssistant extends StatefulWidget {
  final NikoUnattendedInstall? model;
  final String? setup;
  final NikoWindowsInstall? windows;

  /// Ends this process once the removal is done; tests replace it.
  final Future<void> Function()? quit;
  const NikoUninstallAssistant(
      {super.key, this.model, this.setup, this.windows, this.quit});
  @override
  State<NikoUninstallAssistant> createState() => _UninstallState();
}

class _UninstallState extends State<NikoUninstallAssistant> {
  late final _model = widget.model ?? nativeNikoUnattendedInstall();
  late final _windows = widget.windows ?? NikoWindowsInstall();
  late final _setup = widget.setup ?? _setupBeside(Platform.resolvedExecutable);
  Timer? _timer;
  bool _finishing = false;

  bool get _removed =>
      _model.operationConfirmed && _model.reply?.action == 'remove';

  @override
  void initState() {
    super.initState();
    _model.addListener(_changed);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_model.supported) return;
      _model.refresh();
      _timer = Timer.periodic(const Duration(seconds: 2), (_) {
        if ((_model.hasJob || _model.uncertain) && !_model.operationConfirmed) {
          _model.refresh();
        }
      });
    });
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _timer?.cancel();
    _model.removeListener(_changed);
    super.dispose();
  }

  Future<void> _remove() =>
      _model.begin(selectedSetup: _setup, password: '', action: 'remove');

  /// After the service is gone, or to drop only this user's copy.
  Future<void> _finish() async {
    if (_finishing) return;
    setState(() => _finishing = true);
    try {
      await _windows.unregister();
      await _windows.removeAllAfterExit();
    } catch (_) {
      // The folder stays; nothing else depends on it.
    }
    await (widget.quit ?? () async => exit(0))();
  }

  @override
  Widget build(BuildContext context) {
    final nl = NlColors.of(context);
    final working = _model.busy ||
        ((_model.hasJob || _model.uncertain) && !_model.operationConfirmed);
    final feedback = nikoUnattendedFeedbackText(_model.feedback);
    return _Frame(
        title: _removed
            ? nikoText('后台服务已卸载', 'Background service removed')
            : nikoText('卸载 NikoDesk', 'Uninstall NikoDesk'),
        message: _removed
            ? nikoText('最后删除程序文件，然后关闭 NikoDesk。你的设备列表和设置会保留。',
                'Last, the program files are deleted and NikoDesk closes. Your device list and settings are kept.')
            : nikoText(
                '会停止并删除后台服务、程序文件，以及这台电脑作为被控端的设备代码和服务密码。你的设备列表和设置会保留。',
                'This stops and deletes the background service, the program files, and this computer’s device code and service password. Your device list and settings are kept.'),
        actions: _removed
            ? [
                NlButton(
                    key: const Key('uninstall-finish'),
                    label: nikoText('删除并关闭', 'Delete and close'),
                    loading: _finishing,
                    onPressed: _finish),
              ]
            : [
                NlButton.ghost(
                    key: const Key('uninstall-cancel'),
                    label: nikoText('取消', 'Cancel'),
                    onPressed: working ? null : () => Navigator.of(context).pop()),
                NlButton(
                    key: const Key('uninstall-confirm'),
                    label: nikoText('卸载', 'Uninstall'),
                    loading: working,
                    onPressed: _model.canManage && !working ? _remove : null),
              ],
        children: [
          if (!_removed) ...[
            const SizedBox(height: NlSpace.s4),
            Text(
                working
                    ? nikoUnattendedPhaseText(_model)
                    : nikoText('点卸载后，先在本机确认，再在 Windows 的管理员确认窗口点「是」。',
                        'After you choose Uninstall, confirm here and then choose Yes in Windows’ administrator prompt.'),
                style: NlType.text(NlType.s3, color: nl.fg2)),
            if (feedback.isNotEmpty) ...[
              const SizedBox(height: NlSpace.s2),
              Text(feedback, style: NlType.text(NlType.s3, color: nl.warnText)),
            ],
            if (!working && _model.feedback != 'idle' && !_model.canManage) ...[
              const SizedBox(height: NlSpace.s4),
              Text(
                  nikoText(
                      '后台服务暂时卸载不了。也可以只删除程序：已安装的服务会留在系统里，以后重新安装再卸载。',
                      'The service cannot be removed right now. You can delete only the program; an installed service then stays until you install and uninstall again.'),
                  style: NlType.text(NlType.s3, color: nl.fg2)),
              const SizedBox(height: NlSpace.s2),
              Align(
                  alignment: Alignment.centerLeft,
                  child: NlButton.ghost(
                      key: const Key('uninstall-program-only'),
                      small: true,
                      label: nikoText('只删除程序', 'Delete the program only'),
                      onPressed: _finish)),
            ],
          ],
        ]);
  }
}
