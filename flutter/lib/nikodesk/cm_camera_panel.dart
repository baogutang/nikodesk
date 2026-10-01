import 'dart:async';

import 'package:flutter/material.dart';

import 'cm_camera.dart';
import 'ui.dart';

String nikoCameraReason(String code) => switch (code) {
      'pending_local_approval' ||
      'camera_pending' ||
      'local_approval_required' =>
        nikoText('等待本机选择摄像头并批准；请求 120 秒后失效。',
            'Choose a camera and approve locally. The request expires after 120 seconds.'),
      'os_settings_required' ||
      'os_camera_settings_required' ||
      'permission_denied' =>
        nikoText('系统尚未允许摄像头访问。请在本机系统隐私设置中允许 NikoDesk，然后重新读取设备。',
            'Camera access is not allowed by the system. Allow NikoDesk in this computer’s privacy settings, then reload devices.'),
      'permission_restricted' => nikoText('系统限制了摄像头访问，请检查本机管理策略。',
          'The system restricts camera access. Check this computer’s management policy.'),
      'permission_pending' ||
      'os_permission_requested_locally' ||
      'camera_permission_request_pending' =>
        nikoText('等待本机系统权限选择；这不会批准远端访问。',
            'Waiting for a local system permission decision. This does not approve remote access.'),
      'roster_changed' ||
      'selection_stale' ||
      'camera_roster_changed_reselect' ||
      'camera_exact_format_not_in_snapshot' ||
      'camera_device_not_in_roster' =>
        nikoText('设备或格式已变更，请重新读取并选择。',
            'Devices or formats changed. Reload and select again.'),
      'device_unavailable' || 'device_removed' => nikoText(
          '所选摄像头不可用，请检查连接后重新读取设备。',
          'The selected camera is unavailable. Check its connection and reload devices.'),
      'unsupported' || 'camera_unsupported' => nikoText('此被控端平台暂不支持摄像头授权。',
          'Camera approval is not supported on this receiving platform.'),
      'cleanup_unconfirmed' ||
      'stop_unconfirmed' ||
      'camera_cleanup_unconfirmed_owner_retained' ||
      'camera_revoke_unconfirmed' =>
        nikoText('摄像头停止结果尚未确认，暂不能重新选择或启动。请重试清理。',
            'Camera shutdown is unconfirmed. Selection and startup remain blocked. Retry cleanup.'),
      'expired' || 'request_expired' || 'camera_request_expired' => nikoText(
          '请求已过期，请让对端重新发起会话。',
          'The request expired. Ask the peer to start a new session.'),
      'denied_locally' =>
        nikoText('本机已拒绝本次摄像头请求。', 'This camera request was denied locally.'),
      'camera_running' || 'first_encoded_packet_sent' => nikoText(
          '状态来自此会话拥有的原生摄像头资源；不代表对端已显示画面。',
          'Status comes from the native camera resource owned by this session; it does not confirm display at the peer.'),
      'camera_catalog_ready' ||
      'camera_catalog_updated' ||
      'camera_formats_ready' ||
      'os_permission_completed' =>
        nikoText('本机设备信息已读取，请明确选择设备与格式。',
            'Local device information was read. Explicitly choose a device and format.'),
      'camera_format_probe_unconfirmed' ||
      'camera_catalog_unavailable' ||
      'camera_operation_unconfirmed' ||
      'os_permission_unconfirmed' =>
        nikoText('读取或系统许可结果未确认。请检查设备与系统隐私设置后重新读取。',
            'Discovery or system permission is unconfirmed. Check devices and system privacy settings, then reload.'),
      'camera_selected_format_exceeds_stream_limit' => nikoText(
          '当前传输上限为 1920 × 1080，请选择范围内的原生格式。',
          'The current stream limit is 1920 × 1080. Choose a native format within this limit.'),
      'camera_policy_or_identity_changed' ||
      'camera_request_scope_changed' ||
      'camera_command_stale' =>
        nikoText('策略或会话身份已改变，请关闭并重新建立摄像头会话。',
            'The policy or session identity changed. Close and reopen the camera session.'),
      'camera_capture_or_encode_failed' => nikoText(
          '采集或编码失败。确认摄像头已停止后，检查设备并重新建立会话。',
          'Capture or encoding failed. Confirm camera shutdown, check the device, and reopen the session.'),
      'camera_requests_disabled_locally' => nikoText(
          '本机未允许摄像头请求。允许请求后，每个会话仍需本机批准。',
          'This computer has not enabled camera requests. Enabling requests still requires local approval for each session.'),
      'camera_preparing' => nikoText('本机已批准，正在准备所选原生设备；尚未确认开始传输。',
          'Approved locally. The selected native device is being prepared; transmission is not confirmed yet.'),
      'revoked_locally' => nikoText('本机已拒绝或撤销本次访问，并确认资源停止。',
          'This access was denied or revoked locally, and resource shutdown was confirmed.'),
      'camera_stopped' => nikoText('原生摄像头资源已确认停止。',
          'The native camera resource has been confirmed stopped.'),
      _ => nikoText('请按当前资源状态操作；详细结果尚未确认。',
          'Use the current resource state. Further details are unconfirmed.'),
    };

class NikoCameraCapabilityPanel extends StatefulWidget {
  final NikoCameraStatus status;
  final NikoCameraCatalog? catalog;
  final Future<String> Function(String) sendCommand;
  final bool cleanupUnconfirmed;
  final bool cleanupOnly;
  final VoidCallback? onCleanupRequested;
  final bool canRequestSystemPermission;
  final Future<bool> Function()? refreshStatus;
  const NikoCameraCapabilityPanel(
      {super.key,
      required this.status,
      this.catalog,
      this.cleanupUnconfirmed = false,
      this.cleanupOnly = false,
      this.onCleanupRequested,
      this.canRequestSystemPermission = false,
      this.refreshStatus,
      required this.sendCommand});
  @override
  State<NikoCameraCapabilityPanel> createState() => _CameraPanelState();
}

class _CameraPanelState extends State<NikoCameraCapabilityPanel> {
  final _fps = TextEditingController();
  String? _uid, _token, _message;
  bool _busy = false, _cleanupUnconfirmed = false;
  int _action = 0;

  NikoCameraCatalog? get _catalog {
    final catalog = widget.catalog;
    return catalog != null &&
            catalog.identity.sameRequest(widget.status.identity) &&
            catalog.revision == widget.status.revision
        ? catalog
        : null;
  }

  NikoCameraDevice? get _device {
    for (final device in _catalog?.devices ?? <NikoCameraDevice>[]) {
      if (device.uid == _uid) return device;
    }
    return null;
  }

  NikoCameraFormat? get _format {
    for (final format in _device?.formats ?? <NikoCameraFormat>[]) {
      if (format.token == _token) return format;
    }
    return null;
  }

  int? get _requestedFps => int.tryParse(_fps.text.trim());
  bool get _canSelect =>
      !widget.cleanupOnly &&
      widget.status.phase == 'Pending' &&
      !_cleanupUnconfirmed &&
      !widget.cleanupUnconfirmed;
  bool get _canStart =>
      _canSelect &&
      !_busy &&
      _catalog?.authorization == 'authorized' &&
      _device != null &&
      _format != null &&
      _format!.width <= 1920 &&
      _format!.height <= 1080 &&
      _format!.acceptsFps(
          _format!.schema == 'windows-native-v1' ? null : _requestedFps);
  bool _current(int action, NikoCameraStatus captured) =>
      mounted &&
      action == _action &&
      widget.status.identity.sameRequest(captured.identity) &&
      widget.status.revision == captured.revision &&
      widget.status.resourceEpoch == captured.resourceEpoch &&
      widget.status.phase == captured.phase;

  @override
  void dispose() {
    ++_action;
    _fps.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant NikoCameraCapabilityPanel old) {
    super.didUpdateWidget(old);
    final identityChanged =
        !old.status.identity.sameRequest(widget.status.identity);
    if (identityChanged ||
        old.status.revision != widget.status.revision ||
        old.status.phase != widget.status.phase ||
        old.status.resourceEpoch != widget.status.resourceEpoch) {
      ++_action;
      _busy = false;
      _message = null;
    }
    if (identityChanged || widget.status.phase == 'Stopped') {
      _cleanupUnconfirmed = false;
    }
    if (identityChanged ||
        old.catalog?.rosterRevision != widget.catalog?.rosterRevision ||
        old.catalog?.revision != widget.catalog?.revision) {
      _token = null;
      _fps.clear();
      if (identityChanged || _device == null) _uid = null;
    }
  }

  Future<void> _send(String op) async {
    if (_busy ||
        (widget.cleanupOnly && op != 'retry_cleanup') ||
        (op == 'approve' && !_canStart)) return;
    if ({'enumerate', 'probe', 'request_permission', 'approve', 'deny'}
            .contains(op) &&
        !_canSelect) return;
    final captured = widget.status;
    final catalog = _catalog;
    final device = _device;
    final format = _format;
    final fps = format?.schema == 'mac-fps-range-v1' ? _requestedFps : null;
    final action = ++_action;
    setState(() {
      _busy = true;
      _message = null;
      if (op == 'revoke' || op == 'retry_cleanup') _cleanupUnconfirmed = true;
    });
    if (op == 'revoke' || op == 'retry_cleanup') {
      widget.onCleanupRequested?.call();
    }
    try {
      if (op == 'approve') {
        final accepted = await showDialog<bool>(
            context: context,
            builder: (dialog) => AlertDialog(
                    title: Text(nikoText('允许此会话查看本机摄像头？',
                        'Allow this session to view this computer’s camera?')),
                    content: SingleChildScrollView(
                        child: Text(nikoText(
                            '设备 ${captured.identity.peerId} 将能查看“${_deviceName(device!)}”，${_formatLabel(format!)}${fps == null ? '' : '，$fps FPS'}。授权只用于此会话，以本机普通用户运行。断开或撤销后须重新授权。',
                            'Device ${captured.identity.peerId} can view “${_deviceName(device)}”, ${_formatLabel(format)}${fps == null ? '' : ', $fps FPS'}. Approval is for this session, running as this computer’s regular user. Disconnecting or revoking requires new approval.'))),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(dialog, false),
                          child: Text(nikoText('取消', 'Cancel'))),
                      FilledButton(
                          onPressed: () => Navigator.pop(dialog, true),
                          child: Text(nikoText('允许此会话', 'Allow this session')))
                    ]));
        if (accepted != true ||
            !_current(action, captured) ||
            _catalog?.rosterRevision != catalog?.rosterRevision ||
            _device?.uid != device?.uid ||
            _format?.token != format?.token) return;
      }
      final request = nikoCameraCommand(captured, op,
          uid: {'probe', 'approve'}.contains(op) ? device?.uid : null,
          rosterRevision: op == 'approve' ? catalog?.rosterRevision : null,
          formatToken: op == 'approve' ? format?.token : null,
          fps: op == 'approve' ? fps : null);
      final raw = await Future<String>.sync(() => widget.sendCommand(request))
          .timeout(const Duration(seconds: 5));
      if (_current(action, captured)) {
        setState(() {
          _message = nikoCameraQueued(raw, captured)
              ? nikoText('请求已发送，等待原生资源状态确认。',
                  'Request sent. Waiting for native resource confirmation.')
              : nikoText('请求未获确认。请查看当前会话状态；不会自动选择其他设备或格式。',
                  'Request unconfirmed. Check this session’s status. No other device or format will be selected automatically.');
        });
      }
    } on TimeoutException {
      if (_current(action, captured)) {
        setState(() => _message = nikoText('结果尚未确认，请刷新会话状态。停止未确认前不能重新启动。',
            'The outcome is unconfirmed. Refresh session status. Restart remains blocked until shutdown is confirmed.'));
      }
    } catch (_) {
      if (_current(action, captured)) {
        setState(() => _message = nikoText('本机摄像头授权通道不可用，请查看会话状态后重试。',
            'The local camera approval channel is unavailable. Check session status before retrying.'));
      }
    } finally {
      if (mounted && action == _action) setState(() => _busy = false);
    }
  }

  Future<void> _refresh() async {
    if (_busy || widget.refreshStatus == null) return;
    final captured = widget.status;
    final action = ++_action;
    setState(() {
      _busy = true;
      _message = null;
    });
    var read = false;
    try {
      read = await Future<bool>.sync(widget.refreshStatus!)
          .timeout(const Duration(seconds: 5));
    } catch (_) {}
    if (_current(action, captured)) {
      setState(() => _message = read
          ? nikoText('已读取本机会话状态，请按上方状态操作。',
              'Local session status was read. Use the status shown above.')
          : nikoText('会话状态读取未确认，选择与启动保持原有限制。',
              'The session status read is unconfirmed. Existing selection and startup restrictions remain.'));
    }
    if (mounted && action == _action) setState(() => _busy = false);
  }

  String _formatLabel(NikoCameraFormat format) =>
      '${format.width} × ${format.height}${format.schema == 'windows-native-v1' ? ' · ${format.fpsNum}/${format.fpsDen} FPS' : ' · ${format.minFpsMilli! / 1000}–${format.maxFpsMilli! / 1000} FPS'}';
  String _deviceName(NikoCameraDevice device) =>
      device.name.isEmpty ? nikoText('未命名摄像头', 'Unnamed camera') : device.name;

  Widget _button(String label, String op,
          {bool enabled = true, bool primary = false}) =>
      ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: primary
              ? FilledButton(
                  onPressed: !_busy && enabled ? () => _send(op) : null,
                  child: Text(label))
              : OutlinedButton(
                  onPressed: !_busy && enabled ? () => _send(op) : null,
                  child: Text(label)));

  @override
  Widget build(BuildContext context) {
    final phase = widget.status.phase;
    final catalog = _catalog;
    final label = switch (phase) {
      'Pending' => nikoText('摄像头等待本机授权', 'Camera waiting for local approval'),
      'Starting' => nikoText('正在准备本机摄像头', 'Preparing this computer’s camera'),
      'Running' => nikoText('本机摄像头正在运行', 'This computer’s camera is running'),
      'Revoking' => nikoText('正在停止本机摄像头', 'Stopping this computer’s camera'),
      'RecoveryRequired' =>
        nikoText('摄像头停止尚未确认', 'Camera shutdown unconfirmed'),
      _ => nikoText('本机摄像头已停止', 'This computer’s camera stopped'),
    };
    return Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Semantics(
                  liveRegion: true,
                  child: Text(label,
                      style: Theme.of(context).textTheme.titleSmall)),
              Text(nikoText('仅本机普通用户；系统许可与此会话授权分别确认。',
                  'Regular local user only. System permission and this session’s approval are separate.')),
              Text(nikoText('本次仅传输摄像头画面，麦克风与录制未启用。',
                  'This request transmits camera video only. Microphone and recording are not enabled.')),
              Text(nikoCameraReason(widget.status.reason)),
              if (widget.status.selection case final selection?)
                Text(
                    '${selection.width} × ${selection.height} · ${selection.fpsNum}/${selection.fpsDen} FPS'),
              if ((_cleanupUnconfirmed || widget.cleanupUnconfirmed) &&
                  phase == 'Pending')
                Text(nikoText('上次停止结果未确认，选择与启动已暂停。',
                    'Previous shutdown is unconfirmed. Selection and startup are blocked.')),
              if (_message != null)
                Semantics(liveRegion: true, child: Text(_message!)),
              if (widget.refreshStatus != null)
                ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 48),
                    child: OutlinedButton(
                        onPressed: _busy ? null : _refresh,
                        child: Text(nikoText(
                            '刷新本机会话状态', 'Refresh local session status')))),
              if (_canSelect) ...[
                const SizedBox(height: 8),
                Text(nikoText('点击后才读取本机设备；不会自动请求系统权限或开启摄像头。',
                    'Devices are read only after you click. System permission and capture are never started automatically.')),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  _button(
                      nikoText('读取本机摄像头', 'Read local cameras'), 'enumerate'),
                  if (catalog != null && catalog.authorization != 'authorized')
                    _button(
                        widget.canRequestSystemPermission
                            ? nikoText(
                                '请求本机系统许可', 'Request local system permission')
                            : nikoText('查看系统许可要求',
                                'Check system permission requirements'),
                        'request_permission'),
                  _button(nikoText('拒绝本次请求', 'Deny this request'), 'deny'),
                ]),
                if (catalog != null) ...[
                  const SizedBox(height: 8),
                  Text(nikoCameraReason(catalog.reason)),
                  if (catalog.devices.isEmpty)
                    Text(nikoText('未读取到可选择的摄像头，请检查设备与系统许可后重试。',
                        'No selectable cameras were read. Check devices and system permission, then retry.')),
                  if (catalog.devices.isNotEmpty)
                    DropdownButtonFormField<String>(
                        key: const ValueKey('niko-camera-device'),
                        isExpanded: true,
                        value: _device?.uid,
                        decoration: nikoInput(
                            nikoText('选择本机摄像头', 'Choose a local camera')),
                        items: catalog.devices
                            .map((d) => DropdownMenuItem(
                                value: d.uid,
                                child: Text(_deviceName(d),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis)))
                            .toList(),
                        onChanged: _busy
                            ? null
                            : (uid) => setState(() {
                                  _uid = uid;
                                  _token = null;
                                  _fps.clear();
                                })),
                  if (_device != null && _device!.formats.isEmpty)
                    _button(
                        nikoText('读取所选设备格式', 'Read selected camera formats'),
                        'probe'),
                  if (_device != null && _device!.formats.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    DropdownButtonFormField<String>(
                        key: const ValueKey('niko-camera-format'),
                        isExpanded: true,
                        value: _format?.token,
                        decoration: nikoInput(
                            nikoText('选择原生格式', 'Choose a native format')),
                        items: _device!.formats
                            .map((f) => DropdownMenuItem(
                                value: f.token,
                                enabled: f.width <= 1920 && f.height <= 1080,
                                child: Text(_formatLabel(f),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis)))
                            .toList(),
                        onChanged: _busy
                            ? null
                            : (token) => setState(() {
                                  _token = token;
                                  _fps.clear();
                                })),
                    Text(nikoText('当前传输上限为 1920 × 1080；不自动替换所选原生格式。',
                        'The current stream limit is 1920 × 1080. Selected native formats are never substituted automatically.')),
                    if (_format?.schema == 'mac-fps-range-v1')
                      TextField(
                          key: const ValueKey('niko-camera-fps'),
                          controller: _fps,
                          enabled: !_busy,
                          keyboardType: TextInputType.number,
                          decoration: nikoInput(nikoText('帧率（范围内 1–60 的整数）',
                              'FPS (integer 1–60 within this range)')),
                          onChanged: (_) => setState(() {})),
                    const SizedBox(height: 8),
                    _button(
                        nikoText('选择并授权此会话', 'Select and approve this session'),
                        'approve',
                        enabled: _canStart,
                        primary: true),
                  ],
                ],
              ],
              if ({'Starting', 'Running', 'Revoking', 'RecoveryRequired'}
                      .contains(phase) ||
                  _cleanupUnconfirmed ||
                  widget.cleanupUnconfirmed)
                _button(
                    phase == 'RecoveryRequired' ||
                            _cleanupUnconfirmed ||
                            widget.cleanupUnconfirmed
                        ? nikoText('重试摄像头清理', 'Retry camera cleanup')
                        : nikoText(
                            '停止并撤销摄像头访问', 'Stop and revoke camera access'),
                    phase == 'RecoveryRequired' ||
                            _cleanupUnconfirmed ||
                            widget.cleanupUnconfirmed
                        ? 'retry_cleanup'
                        : widget.cleanupOnly
                            ? 'retry_cleanup'
                            : 'revoke'),
            ]));
  }
}
