import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'cm_capabilities.dart';
import 'ui.dart';

String _reasonLabel(String reason) {
  const reasons = {
    'Waiting for local terminal approval': '等待本机批准终端请求。',
    'Waiting for local terminal approval (expires in 120 seconds)':
        '等待本机批准终端请求，120 秒后失效。',
    'Local decision rejected: stale, expired or unavailable':
        '请求已变更、过期或暂不可用，本次操作未获确认。',
    'Terminal resource status': '状态来自本机会话中的实际终端资源。',
    'Denied locally': '本机已拒绝终端请求。',
    'Terminal decision was not confirmed': '本次终端授权未获确认。',
    'Local terminal grant applied': '本机已批准此会话访问终端。',
    'Terminal execution or cleanup could not be confirmed': '终端执行或清理结果尚未确认。',
    'Terminal policy, identity or grant changed': '授权策略或会话身份已变更，正在撤回终端权限。',
    'All owned terminals have closed': '此会话的终端均已关闭。',
  };
  final chinese = reasons[reason];
  return chinese == null
      ? nikoText('状态说明暂不可用。', 'Status details unavailable.')
      : nikoText(chinese, reason);
}

class NikoTerminalCapabilityPanel extends StatefulWidget {
  final NikoCapabilityStatus status;
  final Future<String> Function(String)? sendDecision;
  final Future<String> Function(String)? sendRevoke;
  const NikoTerminalCapabilityPanel({
    super.key,
    required this.status,
    this.sendDecision,
    this.sendRevoke,
  });
  @override
  State<NikoTerminalCapabilityPanel> createState() => _PanelState();
}

class _PanelState extends State<NikoTerminalCapabilityPanel> {
  bool _busy = false;
  String? _message;
  int _actionSerial = 0;

  Future<void> _send({bool? approve}) async {
    if (_busy) return;
    final identity = widget.status.identity;
    final serial = ++_actionSerial;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      if (approve == true) {
        final confirmed = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
                    title: Text(nikoText('允许终端访问？', 'Allow terminal access?')),
                    content: Text(nikoText(
                        '设备 ${identity.peerId} 将能以 ${widget.status.scope} 执行命令，授权最长 1 小时。断开或撤销后需要重新授权。',
                        'Device ${identity.peerId} can run commands as ${widget.status.scope} for up to 1 hour. Disconnecting or revoking requires new approval.')),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: Text(nikoText('取消', 'Cancel'))),
                      FilledButton(
                          onPressed: () => Navigator.pop(context, true),
                          child: Text(nikoText('允许此会话', 'Allow this session')))
                    ]));
        if (confirmed != true || !mounted) return;
        // The dialog must never switch its request identity to a newer connection.
        if (serial != _actionSerial ||
            !widget.status.identity.sameRequest(identity) ||
            widget.status.phase != 'Pending') return;
      }
      final request = approve == null
          ? (widget.sendRevoke?.call(identity.revoke()) ??
              bind.cmNikodeskCapabilityRevoke(json: identity.revoke()))
          : (widget.sendDecision?.call(identity.decision(approve)) ??
              bind.cmNikodeskCapabilityDecision(
                  json: identity.decision(approve)));
      final raw = await request.timeout(const Duration(seconds: 5));
      final reply = jsonDecode(raw);
      if (mounted &&
          serial == _actionSerial &&
          widget.status.identity.sameRequest(identity)) {
        setState(() {
          _message = reply is Map &&
                  reply['ok'] == true &&
                  reply['status'] == 'queued'
              ? nikoText('请求已发送，等待实际资源状态确认。',
                  'Request sent. Waiting for resource confirmation.')
              : nikoText('请求未确认，请刷新会话状态后重试。',
                  'Request unconfirmed. Refresh the session status before retrying.');
        });
      }
    } on TimeoutException {
      if (mounted &&
          serial == _actionSerial &&
          widget.status.identity.sameRequest(identity)) {
        setState(() {
          _message = nikoText('请求结果尚未确认，请查看实际终端状态。',
              'Request outcome unconfirmed. Check the actual terminal status.');
        });
      }
    } catch (_) {
      if (mounted &&
          serial == _actionSerial &&
          widget.status.identity.sameRequest(identity)) {
        setState(() {
          _message = nikoText('本机授权通道不可用，请重试。',
              'Local approval channel unavailable. Please retry.');
        });
      }
    } finally {
      if (mounted && serial == _actionSerial) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  @override
  void didUpdateWidget(covariant NikoTerminalCapabilityPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.status.identity.sameRequest(widget.status.identity) ||
        oldWidget.status.phase != widget.status.phase ||
        oldWidget.status.resourceEpoch != widget.status.resourceEpoch) {
      ++_actionSerial;
      _busy = false;
      _message = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final phase = widget.status.phase;
    final label = {
      'Pending': nikoText('终端等待本机授权', 'Terminal waiting for local approval'),
      'Starting':
          nikoText('已授权，等待打开终端', 'Approved. Waiting for terminal to open'),
      'Running': nikoText('终端正在运行', 'Terminal running'),
      'Revoking': nikoText('正在撤销终端权限', 'Revoking terminal access'),
      'RecoveryRequired': nikoText('终端清理尚未确认', 'Terminal cleanup unconfirmed'),
      'Stopped': nikoText('终端已停止', 'Terminal stopped')
    }[phase]!;
    return Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label, style: Theme.of(context).textTheme.titleSmall),
            Text(widget.status.scope),
            Text(_reasonLabel(widget.status.reason)),
            if (_message != null) Text(_message!),
            Wrap(spacing: 8, children: [
              if (phase == 'Pending') ...[
                FilledButton(
                    onPressed: _busy ? null : () => _send(approve: true),
                    child: Text(nikoText('允许此会话', 'Allow this session'))),
                TextButton(
                    onPressed: _busy ? null : () => _send(approve: false),
                    child: Text(nikoText('拒绝', 'Deny'))),
              ],
              if ({'Starting', 'Running', 'Revoking', 'RecoveryRequired'}
                  .contains(phase))
                OutlinedButton(
                    onPressed: _busy ? null : () => _send(),
                    child: Text(phase == 'RecoveryRequired'
                        ? nikoText('重试清理', 'Retry cleanup')
                        : nikoText('撤销终端访问', 'Revoke terminal access'))),
            ]),
          ],
        ));
  }
}
