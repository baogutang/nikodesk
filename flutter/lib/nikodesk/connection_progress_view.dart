import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart'
    show CustomAlertDialog, OverlayDialogManager;

import 'connection_progress.dart';
import 'ui.dart';

String nikoConnectionPhaseLabel(NikoConnectionPhase phase) => switch (phase) {
      NikoConnectionPhase.preparing => nikoText('验证连接配置', 'Checking connection settings'),
      NikoConnectionPhase.connecting => nikoText('建立连接', 'Establishing connection'),
      NikoConnectionPhase.authenticating => nikoText('验证远端身份', 'Verifying remote identity'),
      NikoConnectionPhase.waitingForCredentials => nikoText('等待输入凭据', 'Waiting for credentials'),
      NikoConnectionPhase.waitingForApproval => nikoText('等待远端接受', 'Waiting for remote approval'),
      NikoConnectionPhase.waitingForFrame => nikoText('等待远端画面', 'Waiting for remote video'),
      NikoConnectionPhase.authenticated => nikoText('身份验证完成', 'Authentication completed'),
      NikoConnectionPhase.connected => nikoText('已收到远端画面', 'Remote video received'),
      NikoConnectionPhase.reconnecting => nikoText('重新连接', 'Reconnecting'),
      NikoConnectionPhase.failed => nikoText('连接失败', 'Connection failed'),
      NikoConnectionPhase.closed => nikoText('会话已关闭', 'Session closed'),
    };

String _detail(NikoConnectionPhase phase) => switch (phase) {
      NikoConnectionPhase.connecting || NikoConnectionPhase.reconnecting =>
        nikoText('正在建立本次会话，尚未完成远端身份验证。',
            'Establishing this session. Remote authentication has not completed.'),
      NikoConnectionPhase.authenticating =>
        nikoText('传输连接已建立，正在等待远端验证本次连接。',
            'The transport is established. Waiting for the remote device to verify this connection.'),
      NikoConnectionPhase.waitingForApproval =>
        nikoText('远端需要接受本次请求；接受后才能继续连接。',
            'The remote device needs to accept this request before the connection can continue.'),
      NikoConnectionPhase.waitingForFrame =>
        nikoText('本次身份验证已完成，尚未收到远端画面。请检查远端屏幕采集权限、显示器和网络。',
            'Authentication completed for this session. No remote video has arrived yet. Check remote screen-capture access, displays and network.'),
      _ => '',
    };

class NikoConnectionProgressView extends StatelessWidget {
  final NikoConnectionProgress progress;
  const NikoConnectionProgressView({super.key, required this.progress});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<NikoConnectionState>(
      valueListenable: progress,
      builder: (context, state, _) => SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              if (state.pending) const CircularProgressIndicator(),
              const SizedBox(height: 20),
              Semantics(liveRegion: true, child: Text(
                nikoConnectionPhaseLabel(state.phase),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleLarge,
              )),
              const SizedBox(height: 12),
              Text(_detail(state.phase), textAlign: TextAlign.center),
            ]),
          ),
      ));
}

CustomAlertDialog nikoConnectionProgressDialog(NikoConnectionProgress progress,
    {required VoidCallback onCancel}) => CustomAlertDialog(
  content: NikoConnectionProgressView(progress: progress),
  actions: [
    OutlinedButton(
        onPressed: onCancel,
        child: Text(nikoText('取消连接', 'Cancel connection'))),
  ],
  onCancel: onCancel,
);

void showNikoConnectionProgress(OverlayDialogManager manager,
    NikoConnectionProgress progress,
    {required String tag, required VoidCallback onCancel}) {
  if (!progress.value.pending) return;
  manager.show((_, close, context) => nikoConnectionProgressDialog(progress,
      onCancel: () {
        manager.dismissAll();
        onCancel();
      }), tag: tag);
}

class NikoConnectionFailureContext extends StatelessWidget {
  final NikoConnectionState state;
  const NikoConnectionFailureContext({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    final phase = state.failedAt;
    if (phase == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Semantics(liveRegion: true, child: Text(
        nikoText('最后确认阶段：${nikoConnectionPhaseLabel(phase)}',
            'Last observed stage: ${nikoConnectionPhaseLabel(phase)}'),
        style: Theme.of(context).textTheme.bodyMedium,
      )),
    );
  }
}
