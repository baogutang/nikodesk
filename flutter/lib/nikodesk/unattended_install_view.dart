import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'unattended_install.dart';
import 'unattended_install_native.dart';
import 'unattended_password_dialog.dart';
import 'ui.dart';

String _phaseText(NikoUnattendedInstall model) {
  if (model.operationConfirmed) {
    return switch (model.reply!.action) {
      'stop' => nikoText('服务已停用', 'Service stopped and disabled'),
      'resume' => nikoText('服务已恢复运行', 'Service resumed'),
      'remove' =>
        nikoText('服务和机器身份已卸载', 'Service and machine identity removed'),
      'upgrade' => nikoText(
          '服务程序已升级，机器身份保留', 'Service upgraded; machine identity preserved'),
      'repair' => nikoText(
          '服务程序已修复，机器身份保留', 'Service repaired; machine identity preserved'),
      'configure' => nikoText('机器权限已保存，机器身份保留',
          'Machine permissions saved; machine identity preserved'),
      'change_password' => nikoText('服务密码已修改，机器身份保留',
          'Service password changed; machine identity preserved'),
      _ => nikoText('本次安装已确认', 'This installation is confirmed')
    };
  }
  if (model.uncertain) {
    return model.reply?.action == 'install' || model.reply == null
        ? nikoText('安装结果尚未确认', 'Installation result is unconfirmed')
        : nikoText('操作结果尚未确认', 'Operation result is unconfirmed');
  }
  if (model.reply == null) {
    return nikoText('本机安装任务尚未读取', 'Local installation task has not been read');
  }
  return switch (model.reply?.phase) {
    'preparing' => nikoText('本机请求已排队', 'Local request queued'),
    'awaiting_native_confirmation' =>
      nikoText('等待本机操作确认', 'Waiting for local confirmation'),
    'preflight' ||
    'roots' ||
    'journal' ||
    'payload' =>
      nikoText('正在准备安装', 'Preparing installation'),
    'disabled_service' || 'profile' => model.reply?.action == 'configure'
        ? nikoText('正在保存机器权限', 'Saving machine permissions')
        : model.reply?.action == 'change_password'
            ? nikoText('正在修改服务密码', 'Changing service password')
            : nikoText(
                '正在安装服务和机器身份', 'Installing the service and machine identity'),
    'verify' => nikoText('正在核验安装', 'Verifying installation'),
    'consent' =>
      nikoText('等待安装程序或系统确认', 'Waiting for installer or system confirmation'),
    'auto_start' ||
    'started' =>
      nikoText('正在核验服务启动', 'Verifying service startup'),
    'recovery' ||
    'recovery_disabled' =>
      nikoText('安装需要恢复处理', 'Installation recovery is required'),
    'recovery_unconfirmed' =>
      nikoText('恢复结果尚未确认', 'Recovery result is unconfirmed'),
    'install_recovered' => nikoText('未完成安装已清理，可以重新安装',
        'Incomplete installation cleared; ready to install again'),
    'launch_not_started' => nikoText('安装程序未启动', 'Installer did not start'),
    _ => nikoText('本进程暂无安装任务', 'No installation task in this process')
  };
}

String _feedbackText(String reason) => switch (reason) {
      'unsupported' => nikoText('本机暂不支持此安装流程。请在 Windows 上以普通登录用户运行 NikoDesk。',
          'This installation flow is unavailable here. Run NikoDesk on Windows as the ordinary signed-in user.'),
      'busy' => nikoText('已有安装任务，请更新状态以恢复原任务。',
          'An installation task already exists. Refresh to restore the original task.'),
      'private_server_changed' => nikoText('私服已变化。请更新状态，确认当前服务器后重新提交。',
          'The private server changed. Refresh and confirm the current server before submitting again.'),
      'private_server_unavailable' => nikoText('请先完成有效的私服配置，再更新安装状态。',
          'Configure a valid private server, then refresh installation status.'),
      'invalid_request' => nikoText('请重新选择安装程序并输入密码，然后更新状态后重试。',
          'Choose the installer and enter the password again, then refresh before retrying.'),
      'cancel_requested' => nikoText('取消请求已发送。仍在等待安装程序退出和清理确认。',
          'Cancellation was requested. Waiting for the installer to exit and cleanup to be confirmed.'),
      'unknown_job' || 'unconfirmed' => nikoText('暂时无法确认原任务状态。请更新状态；不要重复安装。',
          'The original task status could not be confirmed. Refresh; do not start another installation.'),
      'launch_not_started' => nikoText('请检查本机确认提示和所选安装程序，再更新状态。',
          'Check the local confirmation prompt and selected installer, then refresh.'),
      'recovery_required' => nikoText('请保留本页面，查看本机安装程序的恢复提示并更新状态。',
          'Keep this page open, follow the local installer recovery instructions and refresh.'),
      _ => ''
    };

class NikoUnattendedInstallView extends StatefulWidget {
  final NikoUnattendedInstall? model;
  final Future<String?> Function()? pickSetup;
  final String? initialSetup;
  final Duration pollInterval;
  const NikoUnattendedInstallView(
      {super.key,
      this.model,
      this.pickSetup,
      this.initialSetup,
      this.pollInterval = const Duration(seconds: 2)});
  @override
  State<NikoUnattendedInstallView> createState() => _InstallViewState();
}

class _InstallViewState extends State<NikoUnattendedInstallView>
    with WidgetsBindingObserver {
  late final _model = widget.model ?? nativeNikoUnattendedInstall();
  final _password = TextEditingController();
  String? _setup;
  bool _start = false,
      _picking = false,
      _virtualDisplay = false,
      _lock = false,
      _privacy = false,
      _restart = false;
  Timer? _timer;
  @override
  void initState() {
    super.initState();
    if (widget.initialSetup != null &&
        nikoSelectedWindowsSetup(widget.initialSetup!)) {
      _setup = widget.initialSetup;
    }
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _resume();
    });
  }

  void _resume() {
    _timer?.cancel();
    if (!_model.supported) return;
    _model.refresh();
    _timer = Timer.periodic(widget.pollInterval, (_) {
      if ((_model.hasJob || _model.uncertain) && !_model.operationConfirmed) {
        _model.refresh();
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _timer?.cancel();
    if (state == AppLifecycleState.resumed && mounted) _resume();
  }

  Future<void> _pick() async {
    if (_picking ||
        _model.busy ||
        (_model.hasJob && !_model.canManage && !_model.canRetryWithoutLaunch)) {
      return;
    }
    setState(() => _picking = true);
    String? selected;
    try {
      if (widget.pickSetup != null) {
        selected = await widget.pickSetup!();
      } else {
        final files = await FilePicker.platform.pickFiles(
            dialogTitle:
                nikoText('选择 NikoDesk 安装程序', 'Choose the NikoDesk installer'),
            type: FileType.custom,
            allowedExtensions: ['exe'],
            allowMultiple: false,
            withData: false);
        selected = files?.files.single.path;
      }
    } catch (_) {
      if (mounted) {
        nikoNotice(
            context,
            nikoText(
                '无法打开文件选择，请重试。', 'Could not open the file picker. Try again.'));
      }
    }
    if (!mounted) return;
    setState(() {
      _picking = false;
      if (selected != null) {
        _setup = nikoSelectedWindowsSetup(selected) ? selected : null;
      }
    });
    if (selected != null && _setup == null) {
      nikoNotice(
          context,
          nikoText('请选择 Windows 安装程序的完整路径。',
              'Choose a Windows installer using its full path.'));
    }
  }

  Future<void> _begin() async {
    final setup = _setup, password = _password.text;
    if (!_model.canBegin || setup == null || password.isEmpty) return;
    // Remove the visible credential immediately, including on failed/unknown
    // submission. Native carries it only to this explicit local job.
    final start = _start;
    final virtualDisplay = _virtualDisplay, lock = _lock;
    final privacy = _privacy;
    final restart = _restart;
    _password.clear();
    setState(() => _start = false);
    await _model.begin(
        selectedSetup: setup,
        password: password,
        startAfterCommit: start,
        allowVirtualDisplay: virtualDisplay,
        lockOnDisconnect: lock,
        allowPrivacy: privacy,
        allowRemoteRestart: restart);
  }

  Future<void> _manage(String action) async {
    final setup = _setup;
    if (!_model.canManage || setup == null) return;
    if (action == 'change_password') {
      final choice = await askNikoUnattendedPassword(context);
      if (!mounted || choice == null || !_model.canManage) return;
      _password.clear();
      await _model.begin(
          selectedSetup: setup,
          password: choice.password,
          action: action,
          startAfterCommit: choice.resume);
      return;
    }
    final (title, explanation) = switch (action) {
      'stop' => (
          nikoText('停用无人值守服务', 'Disable unattended service'),
          nikoText('停止服务并关闭开机运行。设备 ID、密码和私服配置保留，恢复后可继续连接。',
              'Stop the service and disable startup. Keep the device ID, password and private server settings for resuming later.')
        ),
      'resume' => (
          nikoText('恢复无人值守服务', 'Resume unattended service'),
          nikoText('核验已安装的 NikoDesk 服务后启动，并恢复开机运行。沿用原设备 ID 和密码。',
              'Verify and start the installed NikoDesk service, then enable startup. Keep its original device ID and password.')
        ),
      'remove' => (
          nikoText('卸载无人值守服务', 'Remove unattended service'),
          nikoText(
              '停止并删除独立的 NikoDesk 服务、安装文件和机器身份。原设备 ID 和密码将失效，重新安装会生成新身份。日志和无法识别的文件保留。',
              'Stop and remove the separate NikoDesk service, its installed files and machine identity. Its ID and password become invalid; a later installation creates a new identity. Logs and unrecognized files are kept.')
        ),
      'upgrade' => (
          nikoText('升级无人值守服务', 'Upgrade unattended service'),
          nikoText(
              '用本次所选发行版升级已安装的服务程序，保留 ID、密码、私服及权限设置。服务会暂时离线；失败时恢复原文件并停用服务，可随后明确恢复运行。',
              'Upgrade the installed service to this selected release. Keep its ID, password, private server and permissions. Access is interrupted briefly; failure restores original files and disables the service until you explicitly resume.')
        ),
      'repair' => (
          nikoText('修复无人值守服务', 'Repair unattended service'),
          nikoText(
              '恢复中断的升级，并用所选发行版修复缺失或损坏的程序文件。保留原 ID、密码和权限设置；不会覆盖或重新生成损坏的机器身份。停用的服务需另行恢复运行。',
              'Recover an interrupted upgrade and repair missing or damaged program files from the selected release. Keep its original ID, password and permissions; damaged machine identity is never overwritten or regenerated. Resume a disabled service separately.')
        ),
      'recover_install' => (
          nikoText('清理未完成安装', 'Clear incomplete installation'),
          nikoText(
              '用于首次安装意外退出后的恢复。只清理原安装记录确认归属的服务和文件；已提交的机器身份和无法确认归属的文件保留。清理完成后可重新安装。',
              'Recover a first installation that exited unexpectedly. Clear only the service and files confirmed by its original installation records. Keep committed machine identities and unrecognized files. Install again after cleanup completes.')
        ),
      'configure' => (
          nikoText('修改机器权限', 'Change machine permissions'),
          nikoText(
              '本次完整替换以下四项权限，未勾选的权限会关闭。保留 ID、密码、私服和程序文件。服务会先停用；只有明确勾选恢复运行才会重新启动。',
              'Replace all four permissions below; unchecked permissions are disabled. Keep the ID, password, private server and program files. The service stops first and restarts only if explicitly selected.')
        ),
      _ => ('', '')
    };
    if (title.isEmpty) return;
    bool screens = false,
        lock = false,
        privacy = false,
        restart = false,
        resume = false;
    final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => StatefulBuilder(
            builder: (context, change) => AlertDialog(
                    title: Text(title),
                    content: SingleChildScrollView(
                        child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                          Text(explanation),
                          if (action == 'configure') ...[
                            CheckboxListTile(
                                key: const Key('unattended-policy-virtual'),
                                contentPadding: EdgeInsets.zero,
                                value: screens,
                                onChanged: (value) =>
                                    change(() => screens = value == true),
                                title: Text(nikoText(
                                    '允许虚拟屏', 'Allow virtual displays'))),
                            CheckboxListTile(
                                key: const Key('unattended-policy-lock'),
                                contentPadding: EdgeInsets.zero,
                                value: lock,
                                onChanged: (value) =>
                                    change(() => lock = value == true),
                                title: Text(nikoText('最后一个控制连接断开后锁屏',
                                    'Lock after the last control connection'))),
                            CheckboxListTile(
                                key: const Key('unattended-policy-privacy'),
                                contentPadding: EdgeInsets.zero,
                                value: privacy,
                                onChanged: (value) =>
                                    change(() => privacy = value == true),
                                title: Text(
                                    nikoText('允许隐私屏', 'Allow privacy screen'))),
                            CheckboxListTile(
                                key: const Key('unattended-policy-restart'),
                                contentPadding: EdgeInsets.zero,
                                value: restart,
                                onChanged: (value) =>
                                    change(() => restart = value == true),
                                title: Text(nikoText('允许远程重启机器',
                                    'Allow remote machine restart'))),
                            CheckboxListTile(
                                key: const Key('unattended-policy-resume'),
                                contentPadding: EdgeInsets.zero,
                                value: resume,
                                onChanged: (value) =>
                                    change(() => resume = value == true),
                                title: Text(nikoText('保存后恢复开机运行并立即启动',
                                    'Enable startup and resume after saving'))),
                          ],
                          const SizedBox(height: 12),
                          Text(nikoText('随后还需本机安装程序和 Windows 系统确认。',
                              'The local installer and Windows will also request confirmation.')),
                        ])),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: Text(nikoText('取消', 'Cancel'))),
                      FilledButton(
                          key: const Key('unattended-confirm-maintenance'),
                          onPressed: () => Navigator.pop(context, true),
                          child: Text(title))
                    ])));
    if (!mounted || accepted != true || !_model.canManage) return;
    _password.clear();
    await _model.begin(
        selectedSetup: setup,
        password: '',
        action: action,
        allowVirtualDisplay: screens,
        lockOnDisconnect: lock,
        allowPrivacy: privacy,
        allowRemoteRestart: restart,
        startAfterCommit: resume);
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
      animation: _model,
      builder: (context, _) =>
          Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(nikoText('Windows 无人值守', 'Windows unattended access'),
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(nikoText(
                '安装独立的 NikoDesk Windows 服务并生成新的机器身份，可用于登录前的无人值守连接；它与便携版窗口的设备身份不同。安装可能需要 Windows 系统确认（UAC）。',
                'Install a separate NikoDesk Windows service with a new machine identity for unattended access, including before sign-in. Its identity differs from the portable app. Windows may request administrator confirmation (UAC).')),
            const SizedBox(height: 8),
            if (!_model.supported || _model.feedback == 'unsupported')
              Text(nikoText('此安装流程仅支持 Windows 本机的 NikoDesk。请使用普通登录用户打开应用。',
                  'This installation flow is available only in NikoDesk on Windows. Open the app as the ordinary signed-in user.'))
            else ...[
              Text(nikoText(
                  '请选择专用安装程序并设置服务密码。已有安装需填写原密码，并保持原来的功能选项。安装期间更换私服需先取消任务。未经确认不会安装；安装后默认不立即启动，Windows 下次启动时自动运行。',
                  'Choose the dedicated installer and set a service password. To verify an existing installation, enter its current password and keep its original feature choices. Cancel before changing servers during installation. Installation requires confirmation; immediate startup is off by default, while startup with Windows is enabled.')),
              const SizedBox(height: 12),
              if (!_model.hasJob ||
                  _model.canRetryWithoutLaunch ||
                  _model.canManage) ...[
                OutlinedButton(
                    key: const Key('unattended-choose-setup'),
                    style: OutlinedButton.styleFrom(
                        minimumSize: const Size(48, 48)),
                    onPressed: _model.busy || _picking ? null : _pick,
                    child: Text(nikoText('选择安装程序…', 'Choose installer…'))),
                if (_setup != null) Text(_setup!.split(RegExp(r'[\\/]')).last),
              ],
              if (!_model.hasJob ||
                  _model.canRetryWithoutLaunch ||
                  _model.canReinstall) ...[
                const SizedBox(height: 12),
                TextField(
                    key: const Key('unattended-password'),
                    controller: _password,
                    enabled: !_model.busy,
                    obscureText: true,
                    maxLength: 128,
                    enableSuggestions: false,
                    autocorrect: false,
                    autofillHints: const [],
                    onChanged: (_) => setState(() {}),
                    decoration: nikoInput(
                        nikoText('本次服务密码', 'Service password for this task')),
                    onSubmitted: (_) => _begin()),
                const SizedBox(height: 8),
                CheckboxListTile(
                    key: const Key('unattended-start'),
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    value: _start,
                    onChanged: _model.busy
                        ? null
                        : (value) => setState(() => _start = value == true),
                    title: Text(nikoText('安装核验完成后启动服务',
                        'Start the service after installation is verified'))),
                if (_model.namespace == null)
                  Text(nikoText('请先配置有效的私服，再更新状态。',
                      'Configure a valid private server, then refresh.')),
                CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    value: _virtualDisplay,
                    onChanged: _model.busy
                        ? null
                        : (value) =>
                            setState(() => _virtualDisplay = value == true),
                    title: Text(nikoText('允许无人值守连接创建虚拟屏',
                        'Allow unattended connections to create virtual displays')),
                    subtitle: Text(nikoText('需另行在本机安装兼容的签名驱动。此安装不会安装驱动。',
                        'A compatible signed driver must be installed locally. This installer does not install a driver.'))),
                CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    value: _lock,
                    onChanged: _model.busy
                        ? null
                        : (value) => setState(() => _lock = value == true),
                    title: Text(nikoText('最后一个控制会话断开后自动锁屏',
                        'Lock after the last control session disconnects'))),
                CheckboxListTile(
                    key: const Key('unattended-privacy'),
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    value: _privacy,
                    onChanged: _model.busy
                        ? null
                        : (value) => setState(() => _privacy = value == true),
                    title: Text(nikoText('允许无人值守连接请求隐私屏',
                        'Allow unattended connections to request privacy screen')),
                    subtitle: Text(nikoText(
                        '只遮挡登录后的普通桌面；切到登录或 UAC 桌面时恢复。物理 Esc 可恢复。',
                        'Covers the signed-in desktop only. Switching to sign-in or UAC restores the screen. Physical Esc restores it.'))),
                CheckboxListTile(
                    key: const Key('unattended-remote-restart'),
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    value: _restart,
                    onChanged: _model.busy
                        ? null
                        : (value) => setState(() => _restart = value == true),
                    title: Text(nikoText('允许无人值守连接重启机器',
                        'Allow unattended connections to restart this machine')),
                    subtitle: Text(nikoText('默认关闭。需要已认证的远控和键鼠权限，并由主控端明确请求重启。',
                        'Off by default. Requires authenticated remote control, keyboard permission and an explicit restart request.'))),
                const SizedBox(height: 8),
                FilledButton(
                    key: const Key('unattended-begin'),
                    style:
                        FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                    onPressed: _model.canBegin &&
                            _setup != null &&
                            _password.text.isNotEmpty
                        ? _begin
                        : null,
                    child:
                        Text(nikoText('申请本机安装', 'Request local installation'))),
              ],
              const SizedBox(height: 12),
              Semantics(
                  liveRegion: true,
                  child: Text(_phaseText(_model),
                      key: const Key('unattended-state'),
                      style: Theme.of(context).textTheme.titleSmall)),
              if (!_model.hasJob && !_model.uncertain)
                Text(nikoText('这不是对系统服务是否已安装的判断。',
                    'This does not determine whether a system service is already installed.')),
              if (_model.differentServer)
                Text(nikoText('这是此前私服下的安装任务，仍可查询或取消原任务。',
                    'This task belongs to a previous private server. You can still query or cancel the original task.')),
              if (_feedbackText(_model.feedback).isNotEmpty)
                Text(_feedbackText(_model.feedback)),
              if (_model.operationConfirmed &&
                  _model.reply!.action != 'remove') ...[
                SelectableText(
                    '${nikoText('无人值守机器 ID', 'Unattended machine ID')}: ${_model.reply!.machineId}'),
                Text(_model.reply!.action == 'stop'
                    ? nikoText('服务已停用，恢复运行后可继续使用此 ID 和原服务密码。',
                        'The service is disabled. Resume it to use this ID and its existing service password.')
                    : nikoText('服务运行时可连接此 ID，使用服务密码。它与便携版 ID 不同。',
                        'Connect to this ID using its service password while the service is running. It differs from the portable ID.')),
                TextButton(
                    onPressed: () => Clipboard.setData(
                        ClipboardData(text: _model.reply!.machineId)),
                    child: Text(nikoText('复制机器 ID', 'Copy machine ID'))),
              ],
              if (_model.operationConfirmed && _model.reply!.action == 'remove')
                Text(nikoText('原机器 ID 和密码已失效。',
                    'The former machine ID and password are no longer valid.')),
              if (_model.reply?.installRecovered == true)
                Text(nikoText('请设置新服务密码后重新安装。',
                    'Set a new service password, then install again.')),
              if (_model.canManage) ...[
                const SizedBox(height: 12),
                Text(
                    nikoText(
                        '管理本机已安装的服务', 'Manage the installed local service'),
                    style: Theme.of(context).textTheme.titleSmall),
                Text(nikoText('请选择对应的 NikoDesk 安装程序。每项操作都需明确确认，并核验当前私服下的独立服务。',
                    'Choose the corresponding NikoDesk installer. Each action requires explicit confirmation and verifies the separate service on your current private server.')),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final item in [
                    ('stop', nikoText('停用', 'Disable')),
                    ('resume', nikoText('恢复运行', 'Resume')),
                    ('remove', nikoText('卸载', 'Remove')),
                    ('upgrade', nikoText('升级', 'Upgrade')),
                    ('repair', nikoText('修复', 'Repair')),
                    ('configure', nikoText('修改机器权限', 'Change permissions')),
                    (
                      'change_password',
                      nikoText('修改服务密码', 'Change service password')
                    ),
                    (
                      'recover_install',
                      nikoText('清理未完成安装', 'Clear incomplete installation')
                    )
                  ])
                    OutlinedButton(
                        key: Key('unattended-${item.$1}'),
                        style: OutlinedButton.styleFrom(
                            minimumSize: const Size(48, 48)),
                        onPressed:
                            _setup == null ? null : () => _manage(item.$1),
                        child: Text(item.$2))
                ])
              ],
              if (_model.busy)
                Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(nikoText(
                        '正在等待本机任务回应…', 'Waiting for the local task…'))),
              const SizedBox(height: 12),
              Wrap(spacing: 8, runSpacing: 8, children: [
                OutlinedButton(
                    key: const Key('unattended-refresh'),
                    style: OutlinedButton.styleFrom(
                        minimumSize: const Size(48, 48)),
                    onPressed: _model.busy ? null : _model.refresh,
                    child: Text(nikoText('更新状态', 'Refresh status'))),
                if (_model.cancellable)
                  OutlinedButton(
                      key: const Key('unattended-cancel'),
                      style: OutlinedButton.styleFrom(
                          minimumSize: const Size(48, 48)),
                      onPressed: _model.busy ? null : _model.cancel,
                      child: Text(nikoText('请求取消安装', 'Request cancellation')))
              ])
            ]
          ]));
}
