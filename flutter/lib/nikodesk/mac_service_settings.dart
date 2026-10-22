import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/models/platform_model.dart';

import 'ui.dart';

class NikoMacServiceState {
  final bool installed, appSigned, inApplications, reachable;

  /// The daemon's view, e.g. `installed=2.0.0+23 service=2.0.0+23`.
  final String versions;
  const NikoMacServiceState(
      {this.installed = false,
      this.appSigned = false,
      this.inApplications = false,
      this.reachable = false,
      this.versions = ''});

  /// Updates can go through the service: it answers and this is the signed
  /// app in /Applications, the only location it updates.
  bool get canInstallUpdates => reachable && appSigned && inApplications;

  /// One version from [versions]: `installed`, `service` or `previous`;
  /// null when that app is missing.
  String? version(String key) {
    for (final part in versions.split(' ')) {
      final pair = part.split('=');
      if (pair.length == 2 && pair[0] == key && pair[1] != 'none') {
        return pair[1];
      }
    }
    return null;
  }

  static NikoMacServiceState parse(String json) {
    try {
      final value = jsonDecode(json);
      if (value is! Map) return const NikoMacServiceState();
      return NikoMacServiceState(
          installed: value['installed'] == true,
          appSigned: value['app_signed'] == true,
          inApplications: value['in_applications'] == true,
          reachable: value['reachable'] == true,
          versions: value['versions'] is String ? value['versions'] : '');
    } catch (_) {
      return const NikoMacServiceState();
    }
  }
}

class NikoMacServiceGateway {
  const NikoMacServiceGateway();
  Future<NikoMacServiceState> state() async =>
      NikoMacServiceState.parse(await bind.mainGetNikodeskMacService());

  /// An error code, or empty on success.
  Future<String> set(bool install) =>
      bind.mainSetNikodeskMacService(install: install);

  /// `install_update` (with the staged bundle's canonical path),
  /// `restore_update` or `sync`.
  Future<NikoMacServiceAnswer> call(String op, {String bundle = ''}) async =>
      NikoMacServiceAnswer.parse(
          await bind.mainNikodeskMacServiceCall(op: op, bundle: bundle));
}

class NikoMacServiceAnswer {
  final bool ok;
  final String code, detail;
  const NikoMacServiceAnswer(this.ok, this.code, [this.detail = '']);

  static NikoMacServiceAnswer parse(String json) {
    try {
      final value = jsonDecode(json);
      if (value is Map && value['code'] is String) {
        return NikoMacServiceAnswer(value['ok'] == true, value['code'],
            value['detail'] is String ? value['detail'] : '');
      }
    } catch (_) {}
    return const NikoMacServiceAnswer(false, 'unreadable_answer');
  }
}

String nikoMacServiceError(String code) => switch (code) {
      'administrator_step_failed_or_cancelled' => nikoText('已取消，或系统没有完成这一步。',
          'Cancelled, or the system did not finish this step.'),
      'app_not_signed_with_nikodesk_certificate' => nikoText(
          '当前应用没有使用 NikoDesk 证书签名，不能安装。正式发布的版本可以。',
          'This copy is not signed with the NikoDesk certificate and cannot install it. Released versions can.'),
      'not_in_app_bundle' || 'app_not_in_applications' => nikoText(
          '请把 NikoDesk 放到“应用程序”文件夹，并从那里打开后再操作。',
          'Move NikoDesk to the Applications folder and open it from there first.'),
      'unreachable' => nikoText('系统后台服务没有响应。', 'The system background service does not answer.'),
      'caller_not_allowed' => nikoText('系统后台服务只接受用 NikoDesk 证书签名的应用。',
          'The system background service only answers apps signed with the NikoDesk certificate.'),
      'not_newer' => nikoText('这个安装包不比当前版本新，已保持不变。',
          'This package is not newer than the installed version; nothing changed.'),
      'signature_not_allowed' || 'bundle_id_mismatch' => nikoText(
          '安装包不是 NikoDesk 证书签名的应用，已拒绝，当前版本未更改。',
          'The package is not an app signed with the NikoDesk certificate; refused, the installed version is unchanged.'),
      'installed_check_failed_restored' => nikoText('新版本放入后复查失败，已恢复原来的版本。',
          'The new version failed its check once in place; the previous version was put back.'),
      'staged_missing' || 'staged_path_invalid' || 'staged_owner_mismatch' => nikoText(
          '找不到可安装的安装包，请重新检查更新。',
          'No installable package was found; check for updates again.'),
      'previous_missing' || 'version_unreadable' => nikoText(
          '没有可恢复的上一个版本。', 'There is no previous version to restore.'),
      _ => nikoText('没有完成：$code', 'Not completed: $code'),
    };

/// The system background service (root daemon and login-window agent).
class NikoMacServiceSettings extends StatefulWidget {
  final NikoMacServiceGateway gateway;

  /// Reopens NikoDesk after its app was replaced.
  final Future<void> Function()? relaunch;
  const NikoMacServiceSettings(
      {super.key, this.gateway = const NikoMacServiceGateway(), this.relaunch});
  @override
  State<NikoMacServiceSettings> createState() => _ServiceState();
}

class _ServiceState extends State<NikoMacServiceSettings> {
  NikoMacServiceState _state = const NikoMacServiceState();
  bool _busy = true;
  String? _notice;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final state = await widget.gateway.state();
    if (mounted) {
      setState(() {
        _state = state;
        _busy = false;
      });
    }
  }

  Future<void> _set(bool install) async {
    setState(() {
      _busy = true;
      _notice = null;
    });
    final error = await widget.gateway.set(install);
    if (!mounted) return;
    setState(() => _notice = error.isEmpty
        ? (install
            ? nikoText(
                '系统后台服务已安装。', 'The system background service is installed.')
            : nikoText(
                '系统后台服务已移除。', 'The system background service is removed.'))
        : nikoMacServiceError(error));
    await _refresh();
  }

  Future<void> _restore(String previous) async {
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
              title: Text(nikoText('恢复上一个版本', 'Restore the previous version')),
              content: Text(nikoText(
                  '用上次更新前的 $previous 替换当前版本，然后重新打开 NikoDesk。进行中的远控会话会断开。',
                  'Replace the installed version with $previous, the version before the last update, then reopen NikoDesk. Remote sessions in progress are disconnected.')),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(dialog, false),
                    child: Text(nikoText('取消', 'Cancel'))),
                FilledButton(
                    key: const Key('niko-mac-service-restore-confirm'),
                    onPressed: () => Navigator.pop(dialog, true),
                    child: Text(nikoText('恢复并重新打开', 'Restore and reopen'))),
              ],
            ));
    if (confirmed != true || !mounted) return;
    setState(() {
      _busy = true;
      _notice = null;
    });
    final answer = await widget.gateway.call('restore_update');
    if (!mounted) return;
    setState(() => _notice = answer.ok
        ? nikoText('已恢复 ${answer.detail}，NikoDesk 正在重新打开。',
            'Restored ${answer.detail}; NikoDesk is reopening.')
        : nikoMacServiceError(answer.code));
    if (answer.ok) {
      await widget.relaunch?.call();
      return;
    }
    await _refresh();
  }

  String get _status {
    if (!_state.installed) return nikoText('未安装', 'Not installed');
    if (!_state.reachable) {
      return nikoText(
          '已安装，但后台服务没有响应', 'Installed, but the service does not answer');
    }
    return nikoText('已安装，运行正常', 'Installed and answering');
  }

  @override
  Widget build(BuildContext context) =>
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(nikoText('系统后台服务', 'System background service'),
            style: Theme.of(context).textTheme.titleSmall),
        Text(_status, key: const Key('niko-mac-service-status')),
        Text(nikoText(
            '由系统在你登录后运行远控核心，取代上面的后台恢复；校验通过的更新也由它直接安装，不必再手动替换应用。安装时系统会要求输入一次管理员密码。登录窗口访问仍在验证中，暂不可用。',
            'Runs the remote-control core after you log in, replacing the background recovery above, and installs verified updates without replacing the app by hand. Installing it asks for an administrator password once. Login-window access is still being verified and not available yet.')),
        if (!_state.installed && !_state.appSigned)
          Text(nikoMacServiceError('app_not_signed_with_nikodesk_certificate')),
        if (!_state.installed)
          FilledButton(
              key: const Key('niko-mac-service-install'),
              onPressed: _busy || !_state.appSigned ? null : () => _set(true),
              child: Text(nikoText(
                  '安装系统后台服务', 'Install the system background service')))
        else
          OutlinedButton(
              key: const Key('niko-mac-service-remove'),
              onPressed: _busy ? null : () => _set(false),
              child: Text(nikoText(
                  '移除系统后台服务', 'Remove the system background service'))),
        if (_state.canInstallUpdates && _state.version('previous') != null)
          TextButton(
              key: const Key('niko-mac-service-restore'),
              onPressed: _busy ? null : () => _restore(_state.version('previous')!),
              child: Text(nikoText('恢复上一个版本（${_state.version('previous')}）',
                  'Restore the previous version (${_state.version('previous')})'))),
        if (_busy) const LinearProgressIndicator(),
        if (_notice != null)
          Text(_notice!, style: Theme.of(context).textTheme.bodySmall)
      ]);
}
