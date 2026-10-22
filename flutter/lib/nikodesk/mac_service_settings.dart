import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/models/platform_model.dart';

import 'ui.dart';

class NikoMacServiceState {
  final bool installed, appSigned, reachable;
  const NikoMacServiceState(
      {this.installed = false, this.appSigned = false, this.reachable = false});

  static NikoMacServiceState parse(String json) {
    try {
      final value = jsonDecode(json);
      if (value is! Map) return const NikoMacServiceState();
      return NikoMacServiceState(
          installed: value['installed'] == true,
          appSigned: value['app_signed'] == true,
          reachable: value['reachable'] == true);
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
}

String nikoMacServiceError(String code) => switch (code) {
      'administrator_step_failed_or_cancelled' => nikoText('已取消，或系统没有完成这一步。',
          'Cancelled, or the system did not finish this step.'),
      'app_not_signed_with_nikodesk_certificate' => nikoText(
          '当前应用没有使用 NikoDesk 证书签名，不能安装。正式发布的版本可以。',
          'This copy is not signed with the NikoDesk certificate and cannot install it. Released versions can.'),
      'not_in_app_bundle' => nikoText('请从“应用程序”文件夹中的 NikoDesk 安装。',
          'Install it from NikoDesk in the Applications folder.'),
      _ => nikoText('没有完成：$code', 'Not completed: $code'),
    };

/// The system background service (root daemon and login-window agent).
class NikoMacServiceSettings extends StatefulWidget {
  final NikoMacServiceGateway gateway;
  const NikoMacServiceSettings(
      {super.key, this.gateway = const NikoMacServiceGateway()});
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
            '由系统在你登录后运行远控核心，取代上面的后台恢复；也为以后的登录窗口访问和自动更新做准备。安装和移除时，系统会要求输入管理员密码。登录窗口访问仍在验证中，暂不可用。',
            'Runs the remote-control core after you log in, replacing the background recovery above, and prepares login-window access and automatic updates. Installing and removing ask for an administrator password. Login-window access is still being verified and not available yet.')),
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
        if (_busy) const LinearProgressIndicator(),
        if (_notice != null)
          Text(_notice!, style: Theme.of(context).textTheme.bodySmall)
      ]);
}
