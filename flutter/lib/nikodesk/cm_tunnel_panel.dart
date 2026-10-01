import 'package:flutter/material.dart';

import 'cm_tunnel.dart';
import 'ui.dart';

String nikoTunnelReasonText(String code) => switch (code) {
      'local_approval_required' => nikoText('先解析目标，再选择实际地址批准。本次请求 120 秒后失效。',
          'Resolve the target, then choose an actual address to approve. This request expires after 120 seconds.'),
      'resolving' => nikoText('正在解析本次目标；尚未批准连接。',
          'Resolving this target. No connection has been approved.'),
      'select_exact_address' => nikoText('目标已解析，请手动选择本次允许的具体地址。',
          'The target was resolved. Choose the exact address allowed for this request.'),
      'awaiting_first_owned_socket' => nikoText('已批准此地址，等待实际连接建立。',
          'This address was approved. Waiting for an actual connection.'),
      'running' => nikoText('本机已确认建立到所选地址的连接。',
          'This computer confirmed a connection to the selected address.'),
      'queued' => nikoText('请求已排队，等待本机状态确认。',
          'Request queued. Waiting for local status confirmation.'),
      'cleanup_confirmed' => nikoText('连接与发送任务已确认停止。',
          'Connection and sending tasks have been confirmed stopped.'),
      'tunnel_request_expired' => nikoText('本次请求已过期，请让对端重新发起。',
          'This request expired. Ask the peer to start a new request.'),
      'tunnel_requests_disabled_locally' => nikoText('本机未允许隧道请求。允许请求后仍需逐次批准。',
          'Tunnel requests are disabled here. Enabling requests still requires approval for each request.'),
      'tunnel_backend_unsupported' => nikoText('此被控端暂不支持此隧道连接。',
          'This receiver does not support this tunnel connection.'),
      'tunnel_resolution_failed' => nikoText('目标解析失败，请检查本机网络和目标地址后重新解析。',
          'Target resolution failed. Check this computer’s network and target, then resolve again.'),
      'tunnel_context_changed' ||
      'tunnel_stale_request' ||
      'tunnel_owner_mismatch' =>
        nikoText('会话或服务器已改变。本次不能继续批准，请读取清理状态。',
            'The session or server changed. Approval is blocked. Read the cleanup state.'),
      'tunnel_authenticated_v1_connection_required' => nikoText('此会话的隧道认证尚未确认。',
          'Tunnel authentication for this session is unconfirmed.'),
      'tunnel_ordinary_user_required' => nikoText('请以本机普通登录用户使用隧道授权。',
          'Use tunnel approval as this computer’s signed-in user.'),
      'parent_disconnected' => nikoText('原会话已断开，仅可读取或重试清理。',
          'The original session disconnected. Only status and cleanup are available.'),
      'tunnel_cleanup_unconfirmed' ||
      'writer_drain_unconfirmed' ||
      'operation_unconfirmed' ||
      'channel_unavailable' =>
        nikoText('操作或停止结果尚未确认。请读取当前状态；停止未确认前不能重新批准。',
            'The action or shutdown is unconfirmed. Read the current state. New approval remains blocked until shutdown is confirmed.'),
      _ => nikoText('详细结果尚未确认，请读取本次状态。',
          'Further details are unconfirmed. Read the state of this request.'),
    };

String _phase(NikoCmTunnelModel model) {
  if (model.cleanupOnly && model.status.phase != 'Stopped') {
    return nikoText(
        '此前会话的隧道清理待确认', 'Previous session tunnel cleanup unconfirmed');
  }
  return switch (model.status.phase) {
    'Pending' =>
      nikoText('隧道请求等待本机批准', 'Tunnel request awaiting local approval'),
    'Starting' => nikoText('等待实际目标连接', 'Waiting for the target connection'),
    'Running' =>
      nikoText('所选目标连接已建立', 'Selected target connection established'),
    'Revoking' => nikoText('正在停止隧道', 'Stopping tunnel'),
    'RecoveryRequired' => nikoText('隧道停止尚未确认', 'Tunnel shutdown unconfirmed'),
    'Stopped' => nikoText('隧道已确认停止', 'Tunnel confirmed stopped'),
    _ => nikoText('隧道状态未知', 'Tunnel state unknown'),
  };
}

class NikoCmTunnelPanel extends StatefulWidget {
  final NikoCmTunnelModel model;
  const NikoCmTunnelPanel({super.key, required this.model});
  @override
  State<NikoCmTunnelPanel> createState() => _TunnelPanelState();
}

class _TunnelPanelState extends State<NikoCmTunnelPanel> {
  String? _selected;
  bool _allowNonLoopback = false;
  NikoTunnelStatus? _seen;
  NikoCmTunnelModel get _model => widget.model;
  @override
  void initState() {
    super.initState();
    _seen = _model.status;
    _model.addListener(_changed);
  }

  void _changed() {
    if (!mounted) return;
    setState(() {
      if (!identical(_seen, _model.status)) {
        _selected = null;
        _allowNonLoopback = false;
      }
      _seen = _model.status;
    });
  }

  @override
  void didUpdateWidget(covariant NikoCmTunnelPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.model, _model)) {
      oldWidget.model.removeListener(_changed);
      _model.addListener(_changed);
      _seen = _model.status;
      _selected = null;
      _allowNonLoopback = false;
    }
  }

  @override
  void dispose() {
    _model.removeListener(_changed);
    super.dispose();
  }

  Future<void> _approve() async {
    final model = _model;
    final captured = model.status;
    final address = _selected;
    final allow = _allowNonLoopback;
    if (!model.mayApprove(address, allowNonLoopback: allow)) return;
    final agreed = await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
                scrollable: true,
                title: Text(
                    nikoText('允许本次隧道连接？', 'Allow this tunnel connection?')),
                content: Text(nikoText(
                    '设备 ${captured.identity.peerId} 将能通过本机连接到 $address。授权仅限此会话和这个地址，不允许访问其他地址。',
                    'Device ${captured.identity.peerId} can connect through this computer to $address. Approval is limited to this session and exact address, without access to other addresses.')),
                actions: [
                  TextButton(
                      style:
                          TextButton.styleFrom(minimumSize: const Size(48, 48)),
                      onPressed: () => Navigator.pop(dialog, false),
                      child: Text(nikoText('取消', 'Cancel'))),
                  FilledButton(
                      key: const ValueKey('niko-tunnel-confirm'),
                      style: FilledButton.styleFrom(
                          minimumSize: const Size(48, 48)),
                      onPressed: () => Navigator.pop(dialog, true),
                      child: Text(nikoText('允许此地址', 'Allow this address'))),
                ]));
    if (!mounted ||
        agreed != true ||
        !identical(model, _model) ||
        !model.isCurrent(captured)) return;
    await model.send('approve',
        captured: captured, address: address, allowNonLoopback: allow);
  }

  Widget _action(String op, String chinese, String english) => OutlinedButton(
      key: ValueKey('niko-tunnel-$op'),
      style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
      onPressed: _model.maySend(op) ? () => _model.send(op) : null,
      child: Text(nikoText(chinese, english)));

  @override
  Widget build(BuildContext context) {
    final status = _model.status;
    final pending = status.phase == 'Pending' && !_model.cleanupOnly;
    final selected = status.addresses.where((a) => a.value == _selected);
    final nonLoopback = selected.isNotEmpty && !selected.first.loopback;
    return NikoCard(
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Semantics(
          header: true,
          child: Text(nikoText('本机隧道授权', 'Local tunnel approval'),
              style: Theme.of(context).textTheme.titleMedium)),
      const SizedBox(height: 12),
      Semantics(liveRegion: true, child: Text(_phase(_model))),
      const SizedBox(height: 8),
      Text(nikoText('请求目标：${status.target.label}',
          'Requested target: ${status.target.label}')),
      if (status.selectedAddress != null)
        Text(nikoText('本次允许地址：${status.selectedAddress}',
            'Approved address: ${status.selectedAddress}')),
      const SizedBox(height: 8),
      Text(nikoTunnelReasonText(status.reason)),
      if (_model.cleanupOnly) ...[
        const SizedBox(height: 8),
        Text(nikoText('这是此前会话的资源，不能重新解析或批准。',
            'These resources belong to a previous session. Resolution and approval are unavailable.')),
      ],
      if (pending) ...[
        const SizedBox(height: 16),
        _action('resolve', '解析本次目标', 'Resolve this target'),
        if (status.reason == 'select_exact_address' &&
            status.addresses.isNotEmpty) ...[
          const SizedBox(height: 16),
          DropdownButtonFormField<String>(
              key: const ValueKey('niko-tunnel-address'),
              value: _selected,
              isExpanded: true,
              itemHeight: null,
              decoration:
                  nikoInput(nikoText('选择实际地址', 'Choose an actual address')),
              hint: Text(nikoText(
                  '请选择，不会自动批准', 'Choose an address; approval is manual')),
              items: status.addresses
                  .map((a) => DropdownMenuItem(
                      value: a.value,
                      child: ConstrainedBox(
                          constraints: const BoxConstraints(minHeight: 48),
                          child: Align(
                              alignment: Alignment.centerLeft,
                              child: Text(a.value)))))
                  .toList(),
              onChanged: _model.mayResolve
                  ? (value) => setState(() {
                        _selected = value;
                        _allowNonLoopback = false;
                      })
                  : null),
          if (nonLoopback) ...[
            const SizedBox(height: 12),
            CheckboxListTile(
                key: const ValueKey('niko-tunnel-non-loopback'),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: _allowNonLoopback,
                onChanged: _model.mayResolve
                    ? (value) =>
                        setState(() => _allowNonLoopback = value == true)
                    : null,
                title: Text(nikoText(
                    '允许连接此非本机回环地址', 'Allow this non-loopback address')),
                subtitle: Text(nikoText('此地址可能是局域网或公网服务；只允许你选择的具体地址。',
                    'This may be a LAN or public service. Only the exact selected address is allowed.'))),
          ],
          const SizedBox(height: 12),
          FilledButton(
              key: const ValueKey('niko-tunnel-approve'),
              style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: _model.mayApprove(_selected,
                      allowNonLoopback: _allowNonLoopback)
                  ? _approve
                  : null,
              child:
                  Text(nikoText('选择并批准此地址', 'Approve the selected address'))),
        ],
      ],
      const SizedBox(height: 16),
      Wrap(spacing: 8, runSpacing: 8, children: [
        _action('query', '读取当前状态', 'Read current state'),
        if (pending) _action('deny', '拒绝本次请求', 'Deny this request'),
        if (!_model.cleanupOnly &&
            {'Starting', 'Running', 'Revoking'}.contains(status.phase))
          _action('revoke', '停止本次隧道', 'Stop this tunnel'),
        if (_model.cleanupUnconfirmed ||
            {'Revoking', 'RecoveryRequired'}.contains(status.phase) ||
            (_model.cleanupOnly && status.phase != 'Stopped'))
          _action('retry_cleanup', '重试隧道清理', 'Retry tunnel cleanup'),
      ]),
      if (_model.resolveUnconfirmed ||
          _model.approvalUnconfirmed ||
          _model.cleanupUnconfirmed) ...[
        const SizedBox(height: 12),
        Text(nikoText('仍在等待本机状态确认，不能重复批准。',
            'Local confirmation is pending. Approval cannot be repeated.')),
      ],
      if (_model.operationMessage != null) ...[
        const SizedBox(height: 12),
        Semantics(
            liveRegion: true,
            child: Text(nikoTunnelReasonText(_model.operationMessage!))),
      ],
    ]));
  }
}
