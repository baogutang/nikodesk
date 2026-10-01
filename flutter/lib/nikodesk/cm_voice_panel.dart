import 'package:flutter/material.dart';

import 'ui.dart';
import 'voice_session_model.dart';

String nikoVoiceAvailabilityText(NikoVoiceAvailability availability) =>
    switch (availability) {
      NikoVoiceAvailability.enabled => '',
      NikoVoiceAvailability.policyDisabled => nikoText(
          '本机尚未允许语音请求。允许请求后，每次通话仍需单独批准。',
          'Voice requests are disabled on this computer. Each call still requires separate approval after requests are enabled.'),
      NikoVoiceAvailability.peerPolicyDisabled => nikoText(
          '对端尚未允许语音请求。请让对端在本机设置中允许后再试。',
          'The peer has not enabled voice requests. Ask them to enable requests in their local settings and retry.'),
      NikoVoiceAvailability.backendUnsupported => nikoText(
          '此平台的语音通话暂不可用。文字聊天可正常使用。',
          'Voice calls are unavailable on this platform. Text chat is available.'),
      NikoVoiceAvailability.protocolUnsupported => nikoText(
          '对端版本暂不支持此语音通话，请先检查双方版本。',
          'The peer does not support this voice call. Check the versions on both computers.'),
      NikoVoiceAvailability.contextUnsupported => nikoText(
          '请在桌面远控会话中使用语音。摄像头、终端和文件会话暂不支持通话。',
          'Use voice in a desktop control session. Camera, terminal and file sessions do not support calls yet.'),
      NikoVoiceAvailability.permissionUnsupported => nikoText(
          '此版本暂不能请求本机麦克风许可。请检查应用版本后重试。',
          'This version cannot request microphone permission on this computer. Check the application version and retry.'),
      NikoVoiceAvailability.unknown => nikoText('语音能力尚未确认，暂不能准备通话。',
          'Voice support is unconfirmed. Call preparation is unavailable.')
    };

String nikoVoiceReasonText(String code) => switch (code) {
      'pending_local_approval' => nikoText('本次语音请求需本机批准，120 秒后失效。',
          'This voice request requires local approval and expires after 120 seconds.'),
      'queued' => nikoText('请求已发送，等待本机状态确认。',
          'Request sent. Waiting for local status confirmation.'),
      'operation_unconfirmed' || 'channel_unavailable' => nikoText(
          '操作结果尚未确认，请读取当前状态。停止未确认前不能重新呼叫。',
          'The outcome is unconfirmed. Read the current status. A new call remains blocked until shutdown is confirmed.'),
      'voice_requests_disabled_locally' ||
      'policy_disabled' =>
        nikoVoiceAvailabilityText(NikoVoiceAvailability.policyDisabled),
      'peer_policy_disabled' =>
        nikoVoiceAvailabilityText(NikoVoiceAvailability.peerPolicyDisabled),
      'voice_unsupported' ||
      'backend_unsupported' ||
      'unsupported' =>
        nikoVoiceAvailabilityText(NikoVoiceAvailability.backendUnsupported),
      'peer_unsupported' ||
      'voice_peer_unsupported' =>
        nikoVoiceAvailabilityText(NikoVoiceAvailability.protocolUnsupported),
      'os_settings_required' ||
      'permission_denied' ||
      'microphone_denied' =>
        nikoText('系统未允许麦克风访问。请在本机系统隐私设置中允许 NikoDesk，然后重新读取状态。',
            'Microphone access is denied. Allow NikoDesk in this computer’s privacy settings, then read the status again.'),
      'permission_restricted' || 'microphone_restricted' => nikoText(
          '系统限制了麦克风访问，请检查本机管理策略。',
          'Microphone access is restricted. Check this computer’s management policy.'),
      'notification_permission_denied' ||
      'notification_permission_required' ||
      'background_notification_permission_denied' ||
      'background_notification_unavailable' =>
        nikoText('系统通知权限未允许，后台通话未开始。取消后台勾选后可尝试前台通话。',
            'Notification permission was not granted. Background calling did not start. Clear the background option to try a foreground call.'),
      'permission_unavailable' ||
      'permission_unsupported' =>
        nikoVoiceAvailabilityText(NikoVoiceAvailability.permissionUnsupported),
      'roster_changed' ||
      'selection_stale' ||
      'devices_changed' ||
      'invalid_selection' ||
      'device_unavailable' ||
      'voice_selection_stale' ||
      'voice_device_unavailable' =>
        nikoText('所选音频设备或格式已变更，请重新读取并手动选择。',
            'The selected audio device or format changed. Reload devices and select again.'),
      'expired' || 'request_expired' => nikoText('本次请求已过期，请重新建立通话请求。',
          'This request expired. Start a new call request.'),
      'cleanup_unconfirmed' ||
      'stop_unconfirmed' ||
      'cleanup_pending' ||
      'cleanup_failed' ||
      'voice_cleanup_unconfirmed' =>
        nikoText('音频停止结果尚未确认，请重试清理。',
            'Audio shutdown is unconfirmed. Retry cleanup.'),
      'identity_changed' ||
      'namespace_changed' ||
      'stale_command' ||
      'voice_command_stale' =>
        nikoText('会话已改变，请关闭并重新打开远控会话。',
            'The session changed. Close and reopen the control session.'),
      'microphone_not_determined' => nikoText('请在本机明确请求麦克风许可，再选择设备。',
          'Explicitly request microphone permission on this computer, then choose devices.'),
      'authentication_required' => nikoText('会话认证尚未完成，请先完成远控连接。',
          'Session authentication is incomplete. Complete the control connection first.'),
      'ordinary_user_required' => nikoText('请以本机普通登录用户运行 NikoDesk 后使用语音。',
          'Run NikoDesk as this computer’s signed-in user to use voice.'),
      'invalid_command' => nikoText('此操作尚不可用，请读取当前状态并检查应用版本。',
          'This action is unavailable. Read the current status and check the application version.'),
      'busy' => nikoText('上一项操作仍在处理，请读取当前状态后再试。',
          'The previous action is still being processed. Read the current status before retrying.'),
      'start_timeout' || 'worker_failed' => nikoText('音频准备失败或超时。确认停止后，请检查本机设备。',
          'Audio preparation failed or timed out. Confirm shutdown, then check this computer’s devices.'),
      'denied' || 'cancelled' => nikoText('本次通话已拒绝或取消，请查看音频停止状态。',
          'This call was denied or cancelled. Check the audio shutdown state.'),
      _ => nikoText('请按当前通话状态操作。', 'Use the current call state.')
    };

String _permissionText(String value, {bool android = false}) => switch (value) {
      'Authorized' => nikoText('系统已允许麦克风；本次通话仍需批准。',
          'Microphone permission is allowed by the system. This call still requires approval.'),
      'NotDetermined' => android
          ? nikoText('尚未向系统申请麦克风权限。请点击下方按钮申请。',
              'This app has not requested microphone permission. Use the button below to request it.')
          : nikoText('请点击下方按钮请求本机麦克风许可。',
              'Use the button below to request microphone permission on this computer.'),
      'Denied' => nikoVoiceReasonText('permission_denied'),
      'Restricted' => nikoVoiceReasonText('permission_restricted'),
      'Unavailable' => nikoVoiceReasonText('permission_unavailable'),
      _ => nikoText('本机麦克风许可尚未确认。',
          'Microphone permission on this computer is unconfirmed.')
    };

String _phaseText(NikoVoiceStatus status, bool controller) =>
    switch (status.phase) {
      'Pending' => controller
          ? nikoText('等待本机准备音频', 'Waiting for local audio preparation')
          : nikoText('语音请求等待本机批准', 'Voice request waiting for local approval'),
      'Starting' => nikoText('正在准备本机音频', 'Preparing local audio'),
      'Running' => status.callRunning
          ? nikoText('语音通话中', 'Voice call running')
          : nikoText('本机音频已就绪，等待对端接听',
              'Local audio ready. Waiting for the peer to accept'),
      'Revoking' => nikoText('正在结束语音通话', 'Ending voice call'),
      'RecoveryRequired' => nikoText('音频停止尚未确认', 'Audio shutdown unconfirmed'),
      'Stopped' => nikoText('本机音频已确认停止', 'Local audio confirmed stopped'),
      _ => nikoText('通话状态未知', 'Call state unknown')
    };

class NikoCmVoicePanel extends StatefulWidget {
  final NikoVoiceSessionModel model;
  final bool controller;
  const NikoCmVoicePanel(
      {super.key, required this.model, this.controller = false});
  @override
  State<NikoCmVoicePanel> createState() => _VoicePanelState();
}

class _VoicePanelState extends State<NikoCmVoicePanel> {
  String? _capture, _captureFormat, _playback, _playbackFormat;
  NikoVoiceCatalog? _seenCatalog;
  bool _allowBackground = false;
  NikoVoiceSessionModel get _model => widget.model;

  @override
  void initState() {
    super.initState();
    _seenCatalog = _model.catalog;
    _model.addListener(_changed);
  }

  void _clearSelection() {
    _capture = _captureFormat = _playback = _playbackFormat = null;
    _allowBackground = false;
  }

  void _changed() {
    if (!mounted) return;
    setState(() {
      if (!identical(_seenCatalog, _model.catalog)) _clearSelection();
      _seenCatalog = _model.catalog;
    });
  }

  @override
  void didUpdateWidget(covariant NikoCmVoicePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.model, _model)) {
      oldWidget.model.removeListener(_changed);
      _model.addListener(_changed);
      _seenCatalog = _model.catalog;
      _clearSelection();
    }
  }

  @override
  void dispose() {
    _model.removeListener(_changed);
    super.dispose();
  }

  NikoVoiceSelection? get _selection => _model.catalog
      ?.select(_capture, _captureFormat, _playback, _playbackFormat);

  Future<void> _approve() async {
    final model = _model;
    final captured = model.status;
    final selection = _selection;
    final allowBackground =
        model.androidController && model.catalog?.androidClientFormat == true
            ? _allowBackground
            : null;
    if (!model.mayApprove(selection)) return;
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
                scrollable: true,
                title:
                    Text(nikoText('允许本次语音通话？', 'Allow audio for this call?')),
                content: SingleChildScrollView(
                    child: Text(nikoText(
                            '本机将使用你选择的麦克风和扬声器。对端接听后才能开始通话。静音只停止发送声音，不会释放麦克风；结束通话后需确认音频已停止。',
                            'This computer will use the microphone and speaker you selected. The peer must accept before the call begins. Muting stops sending audio but keeps the microphone open. Ending a call requires confirmed audio shutdown.') +
                        (allowBackground == true
                            ? nikoText('\n你已选择离开应用后继续通话，系统通知中会提供停止入口。',
                                '\nYou chose to continue calls outside the app. The system notification will provide a stop action.')
                            : ''))),
                actions: [
                  TextButton(
                      style:
                          TextButton.styleFrom(minimumSize: const Size(48, 48)),
                      onPressed: () => Navigator.pop(context, false),
                      child: Text(nikoText('取消', 'Cancel'))),
                  FilledButton(
                      style: FilledButton.styleFrom(
                          minimumSize: const Size(48, 48)),
                      onPressed: () => Navigator.pop(context, true),
                      child: Text(nikoText('允许此会话', 'Allow this session')))
                ]));
    if (confirmed != true ||
        !mounted ||
        !identical(model, _model) ||
        !model.isCurrent(captured) ||
        !model.mayApprove(selection)) return;
    await model.send('approve',
        selection: selection,
        captured: captured,
        allowBackground: allowBackground);
  }

  Widget _button(String key, String text, String op, {bool enabled = true}) =>
      OutlinedButton(
          key: ValueKey(key),
          style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
          onPressed: enabled && !_model.busy ? () => _model.send(op) : null,
          child: Text(text));

  Widget _deviceSelector(String direction) {
    final catalog = _model.catalog;
    final input = direction == 'capture';
    final devices =
        catalog?.devices.where((d) => d.direction == direction).toList() ?? [];
    final token = input ? _capture : _playback;
    final formatToken = input ? _captureFormat : _playbackFormat;
    final device = catalog?.device(token, direction);
    final enabled = _model.mayPrepare && !_model.busy;
    final label = input
        ? nikoText('本机麦克风', 'Local microphone')
        : nikoText('本机扬声器', 'Local speaker');
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      DropdownButtonFormField<String>(
          key: ValueKey('niko-voice-$direction-device'),
          value: token,
          isExpanded: true,
          itemHeight: null,
          decoration: nikoInput(label),
          hint: Text(nikoText('请选择设备', 'Choose a device')),
          items: devices
              .map((d) => DropdownMenuItem(
                  value: d.token,
                  child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 48),
                      child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                              d.label.isEmpty
                                  ? nikoText('未命名音频设备', 'Unnamed audio device')
                                  : d.label,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis)))))
              .toList(),
          onChanged: enabled
              ? (value) => setState(() {
                    if (input) {
                      _capture = value;
                      _captureFormat = null;
                    } else {
                      _playback = value;
                      _playbackFormat = null;
                    }
                  })
              : null),
      const SizedBox(height: 12),
      DropdownButtonFormField<String>(
          key: ValueKey('niko-voice-$direction-format'),
          value: formatToken,
          isExpanded: true,
          itemHeight: null,
          decoration: nikoInput(input
              ? nikoText('麦克风格式', 'Microphone format')
              : nikoText('扬声器格式', 'Speaker format')),
          hint: Text(nikoText('请选择格式', 'Choose a format')),
          items: (device?.formats ?? <NikoVoiceFormat>[])
              .map((f) => DropdownMenuItem(
                  value: f.token,
                  child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 48),
                      child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                              '48 kHz · f32 · ${f.channels == 1 ? nikoText('单声道', 'mono') : nikoText('双声道', 'stereo')}',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis)))))
              .toList(),
          onChanged: enabled && device != null
              ? (value) => setState(() {
                    if (input) {
                      _captureFormat = value;
                    } else {
                      _playbackFormat = value;
                    }
                  })
              : null)
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final status = _model.status;
    final maySelect = !_model.cleanupOnly && status.phase == 'Pending';
    final availability = nikoVoiceAvailabilityText(_model.availability);
    final cleanup = _model.cleanupUnconfirmed ||
        status.phase == 'RecoveryRequired' ||
        status.phase == 'Revoking';
    return Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Semantics(
                  header: true,
                  child: Text(
                      widget.controller
                          ? nikoText('语音通话', 'Voice call')
                          : nikoText('本机语音授权', 'Local voice approval'),
                      style: Theme.of(context).textTheme.titleMedium)),
              const SizedBox(height: 8),
              Semantics(
                  liveRegion: true,
                  child: Text(_phaseText(status, widget.controller),
                      key: const ValueKey('niko-voice-phase'),
                      style: Theme.of(context).textTheme.titleSmall)),
              if (widget.controller) ...[
                const SizedBox(height: 8),
                Text(nikoText('本机音频：${status.localReady ? '已就绪' : '尚未就绪'}',
                    'Local audio: ${status.localReady ? 'ready' : 'not ready'}')),
                Text(nikoText('对端接听：${status.peerAccepted ? '已确认' : '未确认'}',
                    'Peer acceptance: ${status.peerAccepted ? 'confirmed' : 'unconfirmed'}')),
              ],
              if (availability.isNotEmpty) Text(availability),
              if (status.reason.isNotEmpty)
                Text(nikoVoiceReasonText(status.reason)),
              if (_model.operationMessage != null)
                Semantics(
                    liveRegion: true,
                    child: Text(nikoVoiceReasonText(_model.operationMessage!))),
              if (_model.approvalUnconfirmed)
                Text(nikoText('批准结果未确认，暂不能重复准备音频。请读取当前状态。',
                    'Approval is unconfirmed. Audio preparation cannot be repeated. Read the current status.')),
              if (cleanup)
                Text(nikoText('音频可能仍在使用中。确认停止前，不能重新选择设备或呼叫。',
                    'Audio may still be in use. Device selection and new calls remain blocked until shutdown is confirmed.')),
              if (status.phase == 'Running')
                Text(status.muted
                    ? nikoText('已静音：不发送声音，麦克风仍在使用中。',
                        'Muted: audio is not sent. The microphone remains open.')
                    : nikoText('本机麦克风正在使用中。静音不会释放麦克风。',
                        'The local microphone is open. Muting does not release it.')),
              if (maySelect) ...[
                const SizedBox(height: 12),
                Text(_permissionText(status.microphonePermission,
                    android: _model.androidController)),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  _button(
                      'niko-voice-enumerate',
                      nikoText('读取本机音频设备', 'Read local audio devices'),
                      'enumerate',
                      enabled: _model.mayPrepare),
                  if (status.microphonePermission == 'NotDetermined')
                    _button(
                        'niko-voice-permission',
                        nikoText(
                            '请求本机麦克风许可', 'Request local microphone permission'),
                        'request_permission',
                        enabled: _model.mayRequestPermission),
                ]),
                if (_model.catalog != null) ...[
                  const SizedBox(height: 16),
                  _deviceSelector('capture'),
                  const SizedBox(height: 16),
                  _deviceSelector('playback'),
                  const SizedBox(height: 12),
                  Text(nikoText('设备和格式由你手动选择；更改后需要重新选择。',
                      'Choose devices and formats manually. Select again after a change.')),
                  if (_model.androidController &&
                      _model.catalog!.androidClientFormat) ...[
                    Text(nikoText('所选格式为应用通话格式；是否可用仍需开始时确认。部分蓝牙设备暂不支持。',
                        'These are application call formats. Availability is confirmed when audio starts. Some Bluetooth devices are unsupported.')),
                    CheckboxListTile(
                        key: const ValueKey('niko-voice-background'),
                        contentPadding: EdgeInsets.zero,
                        value: _allowBackground,
                        controlAffinity: ListTileControlAffinity.leading,
                        title: Text(nikoText('离开应用后继续通话（显示通话通知）',
                            'Continue calls outside the app (show a call notification)')),
                        subtitle: Text(nikoText(
                            '首次可能需要系统通知授权；通知中可停止当前通话。未允许时可取消此勾选，继续前台通话。',
                            'The first use may request notification permission. Stop the call from its notification. If permission is denied, clear this option to use a foreground call.')),
                        onChanged: _model.mayPrepare && !_model.busy
                            ? (value) =>
                                setState(() => _allowBackground = value == true)
                            : null),
                  ],
                  if (!_model.catalog!.devices
                          .any((d) => d.direction == 'capture') ||
                      !_model.catalog!.devices
                          .any((d) => d.direction == 'playback'))
                    Text(nikoText('未找到可用的麦克风或扬声器，请检查本机设备后重新读取。',
                        'No usable microphone or speaker was found. Check this computer’s devices and reload.')),
                ],
                const SizedBox(height: 12),
                FilledButton(
                    key: const ValueKey('niko-voice-approve'),
                    style:
                        FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                    onPressed: !_model.busy && _model.mayApprove(_selection)
                        ? _approve
                        : null,
                    child: Text(nikoText(
                        '允许此会话使用本机音频', 'Allow local audio for this session')))
              ],
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 8, children: [
                _button('niko-voice-query',
                    nikoText('读取当前状态', 'Read current status'), 'query'),
                if (!cleanup &&
                    !_model.cleanupOnly &&
                    status.phase == 'Pending')
                  _button('niko-voice-deny',
                      nikoText('拒绝本次通话', 'Deny this call'), 'deny'),
                if (!cleanup &&
                    !_model.cleanupOnly &&
                    {'Starting', 'Running'}.contains(status.phase))
                  _button('niko-voice-end',
                      nikoText('结束语音通话', 'End voice call'), 'revoke'),
                if (cleanup && status.phase != 'Stopped')
                  _button(
                      'niko-voice-cleanup',
                      nikoText('重试音频清理', 'Retry audio cleanup'),
                      'retry_cleanup'),
                if (!cleanup &&
                    !_model.cleanupOnly &&
                    status.phase == 'Running')
                  _button(
                      'niko-voice-mute',
                      status.muted
                          ? nikoText('取消静音', 'Unmute')
                          : nikoText('静音', 'Mute'),
                      status.muted ? 'unmute' : 'mute',
                      enabled: !status.muted ||
                          _model.availability == NikoVoiceAvailability.enabled),
              ]),
            ]));
  }
}
