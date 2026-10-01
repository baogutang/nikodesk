import 'package:flutter/material.dart';

import 'capability_policy.dart';
import 'capability_policy_native.dart';
import 'server_scope.dart';
import 'ui.dart';

String nikoCapabilityName(NikoCapability kind) => switch (kind) {
      NikoCapability.terminal => nikoText('远程终端', 'Remote terminal'),
      NikoCapability.tunnel => nikoText('端口隧道', 'Port tunnel'),
      NikoCapability.camera => nikoText('远端摄像头', 'Remote camera'),
      NikoCapability.voice => nikoText('语音通话', 'Voice call'),
    };

Future<void> showNikoCapabilityPolicy(
        BuildContext context, NikoCapabilityPolicy policy, String namespace) =>
    showDialog<void>(
        context: context,
        builder: (_) =>
            NikoCapabilityPolicyView(policy: policy, namespace: namespace));

/// Android is a controller. Expose only its actual local voice-request policy.
class NikoMobileVoicePolicyCard extends StatelessWidget {
  final NikoCapabilityPolicy? policy;
  final ValueNotifier<String?>? scopeChanges;
  const NikoMobileVoicePolicyCard({super.key, this.policy, this.scopeChanges});
  @override
  Widget build(BuildContext context) => ValueListenableBuilder<String?>(
      valueListenable: scopeChanges ?? NikoServerScope.changes,
      builder: (context, namespace, _) => NikoCard(
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(nikoText('本机语音通话', 'Voice calls'),
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                Text(nikoText('语音请求默认关闭。打开后，每次通话仍需允许麦克风并手动选择本机音频设备；不会自动采集声音。',
                    'Voice requests are off by default. Each call still requires microphone permission and a manual choice of local audio devices. Enabling requests does not start audio capture.')),
                if (NikoServerScope.validate(namespace) == null) ...[
                  const SizedBox(height: 8),
                  Text(nikoText('请先配置有效的私有服务器，再设置本机语音请求。',
                      'Configure a valid private server before setting voice requests.'))
                ],
                const SizedBox(height: 12),
                OutlinedButton(
                    key: const Key('nikodesk-mobile-voice-policy-open'),
                    style: OutlinedButton.styleFrom(
                        minimumSize: const Size(48, 48)),
                    onPressed: NikoServerScope.validate(namespace) == null
                        ? null
                        : () => showDialog<void>(
                            context: context,
                            builder: (_) => NikoCapabilityPolicyView(
                                policy: policy ?? nativeNikoCapabilityPolicy,
                                namespace: namespace!,
                                scopeChanges: scopeChanges,
                                voiceOnly: true)),
                    child: Text(nikoText('设置语音请求', 'Set voice requests')))
              ])));
}

class NikoCapabilityPolicyView extends StatefulWidget {
  final NikoCapabilityPolicy policy;
  final String namespace;
  final ValueNotifier<String?>? scopeChanges;
  final bool voiceOnly;
  const NikoCapabilityPolicyView(
      {super.key,
      required this.policy,
      required this.namespace,
      this.scopeChanges,
      this.voiceOnly = false});
  @override
  State<NikoCapabilityPolicyView> createState() =>
      _NikoCapabilityPolicyViewState();
}

class _NikoCapabilityPolicyViewState extends State<NikoCapabilityPolicyView> {
  NikoCapabilityPolicySnapshot? _snapshot;
  bool _busy = false;
  bool _confirming = false;
  bool _obsolete = false;
  String? _message;
  int _operation = 0;
  ValueNotifier<String?> get _scope =>
      widget.scopeChanges ?? NikoServerScope.changes;

  @override
  void initState() {
    super.initState();
    _scope.addListener(_changed);
    _load();
  }

  @override
  void dispose() {
    _operation++;
    _scope.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (!mounted || _scope.value == widget.namespace) return;
    _operation++;
    setState(() {
      _obsolete = true;
      _busy = false;
      _confirming = false;
      _snapshot = null;
      _message = nikoText('私服已变更，请关闭此窗口后重新打开。',
          'The private server changed. Close and reopen this dialog.');
    });
  }

  bool _current(int operation) =>
      mounted && !_obsolete && operation == _operation;
  String _error(Object error) {
    final status =
        error is NikoCapabilityPolicyFailure ? error.status : 'unavailable';
    return switch (status) {
      'write_unconfirmed' => nikoText('保存结果未确认，请刷新后查看当前策略。',
          'The save is unconfirmed. Refresh to read the current policy.'),
      'namespace_changed' => nikoText('私服已变更，请关闭此窗口后重新打开。',
          'The private server changed. Close and reopen this dialog.'),
      'unsupported' => widget.voiceOnly
          ? nikoText('此版本暂不支持本机语音请求，请检查应用版本。',
              'This version does not support local voice requests. Check the application version.')
          : nikoText('此平台目前不支持被控端高级请求策略。',
              'This platform does not support incoming advanced request policies.'),
      'exhausted' => nikoText('策略版本已达到上限，仍可关闭已有权限；请联系维护者。',
          'The policy revision limit was reached. Existing permissions can still be disabled.'),
      _ => nikoText('策略读取或保存失败，请刷新重试。',
          'Could not read or save the policy. Refresh and try again.'),
    };
  }

  Future<void> _load() async {
    if (_obsolete || _busy) return;
    final operation = ++_operation;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final snapshot = await widget.policy.get(widget.namespace);
      if (_current(operation)) setState(() => _snapshot = snapshot);
    } catch (error) {
      if (_current(operation)) {
        setState(() {
          _snapshot = null;
          _message = _error(error);
        });
      }
    } finally {
      if (_current(operation)) setState(() => _busy = false);
    }
  }

  Future<void> _set(NikoCapability kind, bool enabled) async {
    if (widget.voiceOnly && kind != NikoCapability.voice) return;
    final snapshot = _snapshot;
    if (snapshot == null || _busy || _obsolete) return;
    final operation = ++_operation;
    setState(() => _busy = true);
    if (enabled) {
      setState(() => _confirming = true);
      final accepted = await showDialog<bool>(
          context: context,
          builder: (dialog) => AlertDialog(
                scrollable: widget.voiceOnly,
                title: Text(nikoText('允许提出请求', 'Allow requests')),
                content: SingleChildScrollView(
                    child: Text(widget.voiceOnly
                        ? nikoText('允许本机在当前私服下提出语音通话请求。每次通话仍需允许麦克风访问并选择具体音频设备。打开此开关不会开始采集声音。',
                            'Allow this device to request voice calls on the current private server. Each call still requires microphone access and a choice of specific audio devices. Enabling this switch does not start audio capture.')
                        : nikoText(
                        '允许当前私服下已认证的会话请求“${nikoCapabilityName(kind)}”。每次仍需在本机单独批准，并确认用户、设备或目标地址。重连不会继承授权。',
                        'Authenticated sessions on this private server may request ${nikoCapabilityName(kind)}. Each request still needs local approval of its user, device or destination. Reconnecting does not restore a grant.'))),
                actions: [
                  TextButton(
                      style: widget.voiceOnly ? TextButton.styleFrom(
                          minimumSize: const Size(48, 48)) : null,
                      onPressed: () => Navigator.pop(dialog, false),
                      child: Text(nikoText('取消', 'Cancel'))),
                  FilledButton(
                      style: widget.voiceOnly ? FilledButton.styleFrom(
                          minimumSize: const Size(48, 48)) : null,
                      onPressed: () => Navigator.pop(dialog, true),
                      child: Text(nikoText('允许请求', 'Allow requests')))
                ],
              ));
      if (!_current(operation)) return;
      setState(() => _confirming = false);
      if (accepted != true) {
        setState(() => _busy = false);
        return;
      }
    }
    try {
      final result = await widget.policy
          .set(widget.namespace, snapshot.revision, kind, enabled);
      if (!_current(operation)) return;
      setState(() {
        if (result.conflict) {
          _snapshot = null;
          _message = nikoText('策略已被其他窗口修改，请刷新后重新选择。',
              'Another window changed the policy. Refresh before making another choice.');
        } else {
          _snapshot = result;
          _message = null;
        }
      });
    } catch (error) {
      if (_current(operation)) {
        setState(() {
          _snapshot = null;
          _message = _error(error);
        });
      }
    } finally {
      if (_current(operation)) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Dialog(
      child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Flexible(
                    child: SingleChildScrollView(
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                      Text(widget.voiceOnly
                          ? nikoText('本机语音通话', 'Voice calls')
                          : nikoText('高级功能请求', 'Advanced capability requests'),
                          style: Theme.of(context).textTheme.titleLarge),
                      const SizedBox(height: 12),
                      Text(widget.voiceOnly
                          ? nikoText('语音请求默认关闭。此开关只允许本机提出语音请求，每次通话仍需允许麦克风并选择本机设备；不会自动采集声音。',
                              'Voice requests are off by default. This switch allows requests from this device. Each call still requires microphone permission and a choice of local devices. It does not start audio capture.')
                          : nikoText('四项默认关闭。这些开关只允许提出请求，不会启动资源或批准远程访问。',
                          'All four are off by default. These switches permit requests and do not start resources or grant remote access.')),
                      const SizedBox(height: 8),
                      Text(widget.voiceOnly
                          ? nikoText('仅作用于当前私服。关闭请求不等于音频已释放，请在语音面板中结束通话并查看清理状态。',
                              'Applies to the current private server only. Disabling requests does not prove audio resources are released. End the call in the voice panel and check its cleanup state.')
                          : nikoText(
                          '仅作用于当前私服。已有资源是否停止，请在本机授权窗口查看。平台或系统权限不满足时不能启动。',
                          'Applies to this private server only. Check the local approval window for resource stop status. Platform and system permissions must also allow the operation.')),
                      if (_snapshot != null) ...[
                        const SizedBox(height: 12),
                        for (final kind in widget.voiceOnly
                            ? [NikoCapability.voice] : NikoCapability.values)
                          SwitchListTile(
                              key: ValueKey('capability-policy-${kind.name}'),
                              contentPadding: EdgeInsets.zero,
                              title: Text(nikoCapabilityName(kind)),
                              subtitle: Text(widget.voiceOnly
                                  ? nikoText('允许本机提出语音请求',
                                      'Allow voice requests from this device')
                                  : nikoText('允许已认证会话提出请求',
                                  'Allow authenticated sessions to request access')),
                              value: _snapshot!.allowRequests[kind]!,
                              onChanged: _busy || _obsolete
                                  ? null
                                  : (enabled) => _set(kind, enabled)),
                      ],
                      if (_message != null)
                        Padding(
                            padding: const EdgeInsets.only(top: 12),
                            child: Semantics(
                                liveRegion: true, child: Text(_message!))),
                      if (_busy && !_confirming)
                        const Padding(
                            padding: EdgeInsets.all(12),
                            child: Center(child: CircularProgressIndicator())),
                    ]))),
                const SizedBox(height: 12),
                Wrap(spacing: 12, children: [
                  OutlinedButton(
                      style: widget.voiceOnly ? OutlinedButton.styleFrom(
                          minimumSize: const Size(48, 48)) : null,
                      onPressed: _busy || _obsolete ? null : _load,
                      child: Text(nikoText('刷新', 'Refresh'))),
                  TextButton(
                      style: widget.voiceOnly ? TextButton.styleFrom(
                          minimumSize: const Size(48, 48)) : null,
                      onPressed: () => Navigator.pop(context),
                      child: Text(nikoText('关闭', 'Close')))
                ]),
              ]))));
}
