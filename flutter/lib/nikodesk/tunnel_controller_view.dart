import 'package:flutter/material.dart';

import 'tunnel_controller.dart';
import 'ui.dart';
import 'wake_on_lan.dart';
import 'wake_device_picker.dart';

class NikoTunnelControllerView extends StatefulWidget {
  final NikoTunnelController controller;
  final Future<String> Function(NikoTunnelCommand) sendCommand;
  final bool mobile;
  const NikoTunnelControllerView(
      {super.key,
      required this.controller,
      required this.sendCommand,
      this.mobile = false});
  @override
  State<NikoTunnelControllerView> createState() =>
      _NikoTunnelControllerViewState();
}

class _NikoTunnelControllerViewState extends State<NikoTunnelControllerView> {
  final _local = TextEditingController();
  final _host = TextEditingController();
  final _remote = TextEditingController();
  String? _validation;
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
  }

  @override
  void didUpdateWidget(NikoTunnelControllerView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.removeListener(_changed);
      widget.controller.addListener(_changed);
      _local.clear();
      _host.clear();
      _remote.clear();
      _validation = null;
    }
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    _local.dispose();
    _host.dispose();
    _remote.dispose();
    super.dispose();
  }

  void _add() {
    final command = NikoTunnelCommand.add(
        widget.controller.namespace,
        widget.controller.peerId,
        int.tryParse(_local.text) ?? 0,
        _host.text,
        int.tryParse(_remote.text) ?? 0);
    setState(() => _validation = command == null
        ? nikoText('请输入有效的目标主机和 1–65535 的端口。',
            'Enter a valid target host and ports from 1 to 65535.')
        : !widget.controller.canAdd(command.localPort)
            ? nikoText('此本机端口仍在使用或结果未确认。请先停止，或关闭此会话后重开。',
                'This local port is in use or unconfirmed. Stop it first, or close and reopen this session.')
            : null);
    if (command != null && _validation == null) {
      widget.controller.send(command, widget.sendCommand);
    }
  }

  void _requestWakeProxy() {
    final model = widget.controller;
    var port = 21129;
    while (port <= 21292 && !model.canAdd(port)) {
      port++;
    }
    if (port > 21292) {
      setState(() => _validation =
          nikoText('请先停止不用的代理端口。', 'Stop unused proxy ports first.'));
      return;
    }
    // The original native bind remains authoritative; an OS port collision is
    // reported by its real publisher and can be corrected in the fields.
    _local.text = '$port';
    _host.text = '127.0.0.1';
    _remote.text = '21128';
    _add();
  }

  Widget _field(TextEditingController controller, String key, String label,
          {bool numeric = false}) =>
      TextField(
          key: Key(key),
          controller: controller,
          keyboardType: numeric ? TextInputType.number : TextInputType.text,
          maxLength: numeric ? 5 : 253,
          autocorrect: false,
          enableSuggestions: false,
          decoration: nikoInput(label).copyWith(counterText: ''),
          textInputAction: TextInputAction.next);

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final ports = {...controller.statuses.keys, ...controller.requests.keys}
        .toList()
      ..sort();
    return SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Center(
            child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 920),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(nikoText('TCP 隧道', 'TCP tunnel'),
                          style: Theme.of(context).textTheme.titleLarge),
                      const SizedBox(height: 8),
                      Text(nikoText(
                          '在本机 127.0.0.1 建立入口。对方需要在自己的设备上明确批准目标地址。请求排队不代表已连接。',
                          'Create an entry at 127.0.0.1 on this device. The remote user must approve the target address on their device. A queued request is not a connection.')),
                      if (widget.mobile) ...[
                        const SizedBox(height: 8),
                        Text(nikoText('这是手机本机的回环地址。请保持此页面，离开或关闭会话后不能保证隧道继续运行。',
                            'This loopback address belongs to this phone. Keep this page open; leaving or closing the session does not guarantee continued operation.')),
                      ],
                      const SizedBox(height: 16),
                      Align(
                          alignment: AlignmentDirectional.centerStart,
                          child: OutlinedButton(
                              key: const Key('niko-tunnel-request-wake-proxy'),
                              style: OutlinedButton.styleFrom(
                                  minimumSize: const Size(48, 48)),
                              onPressed: controller.active && !controller.busy
                                  ? _requestWakeProxy
                                  : null,
                              child: Text(
                                  nikoText('请求唤醒代理', 'Request wake proxy')))),
                      const SizedBox(height: 8),
                      Text(nikoText('对方需在设置中启用唤醒代理并允许目标网卡，再批准本次连接。批准后可选择设备唤醒。',
                          'The remote device must enable its wake proxy, permit the target NIC and approve this connection. Once approved, choose a device to wake.')),
                      const SizedBox(height: 16),
                      if (!controller.active)
                        Semantics(
                            liveRegion: true,
                            child: Text(nikoText('此页已停止提交新请求。请先确认原会话退出，再重新连接。',
                                'This page no longer submits new requests. Confirm exit of the original session before reconnecting.'))),
                      NikoCard(
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                            LayoutBuilder(builder: (context, constraints) {
                              final fields = [
                                _field(_local, 'niko-tunnel-local-port',
                                    nikoText('本机端口', 'Local port'),
                                    numeric: true),
                                _field(_host, 'niko-tunnel-target-host',
                                    nikoText('对端目标主机', 'Remote target host')),
                                _field(_remote, 'niko-tunnel-remote-port',
                                    nikoText('目标端口', 'Target port'),
                                    numeric: true),
                              ];
                              if (constraints.maxWidth /
                                      MediaQuery.textScalerOf(context)
                                          .scale(1) <
                                  600) {
                                return Column(children: [
                                  for (var i = 0; i < fields.length; i++) ...[
                                    if (i != 0) const SizedBox(height: 12),
                                    fields[i],
                                  ]
                                ]);
                              }
                              return Row(children: [
                                for (var i = 0; i < fields.length; i++) ...[
                                  if (i != 0) const SizedBox(width: 12),
                                  Expanded(
                                      flex: i == 1 ? 2 : 1, child: fields[i]),
                                ]
                              ]);
                            }),
                            const SizedBox(height: 12),
                            if (_validation != null)
                              Padding(
                                  padding: const EdgeInsets.only(bottom: 8),
                                  child: Semantics(
                                      liveRegion: true,
                                      child: Text(_validation!))),
                            Align(
                                alignment: AlignmentDirectional.centerStart,
                                child: ElevatedButton(
                                    key: const Key('niko-tunnel-add'),
                                    style: ElevatedButton.styleFrom(
                                        minimumSize: const Size(48, 48)),
                                    onPressed:
                                        controller.active && !controller.busy
                                            ? _add
                                            : null,
                                    child: Text(
                                        nikoText('请求隧道', 'Request tunnel')))),
                          ])),
                      const SizedBox(height: 16),
                      if (ports.isEmpty)
                        Text(nikoText('尚未请求隧道。不会自动恢复以前的目标。',
                            'No tunnel requested. Previous targets are not restored automatically.')),
                      for (final port in ports)
                        Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: _card(context, port)),
                    ]))));
  }

  Widget _card(BuildContext context, int port) {
    final model = widget.controller;
    final status = model.statuses[port];
    final request = model.requests[port];
    final target = status?.target ?? request?.target;
    final requestText = request == null
        ? null
        : switch (request.state) {
            NikoTunnelRequestState.sending =>
              nikoText('正在提交请求…', 'Submitting request…'),
            NikoTunnelRequestState.queued => nikoText('请求已排队，等待实际状态确认。',
                'Request queued; waiting for actual status.'),
            NikoTunnelRequestState.unconfirmed => nikoText(
                '请求结果未确认。请停止此端口或关闭会话，勿重复请求。',
                'Request unconfirmed. Stop this port or close the session before requesting it again.'),
            NikoTunnelRequestState.rejected => _reasonText(request.reason),
          };
    final canStop = model.active &&
        !model.busy &&
        (status?.reusable != true) &&
        (status != null ||
            (request != null &&
                request.state != NikoTunnelRequestState.rejected));
    return NikoCard(
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SelectableText('127.0.0.1:$port',
          style: Theme.of(context).textTheme.titleMedium),
      if (target != null)
        Padding(
            padding: const EdgeInsets.only(top: 4),
            child:
                SelectableText('${nikoText('目标', 'Target')}: ${target.label}')),
      const SizedBox(height: 8),
      Semantics(
          liveRegion: true,
          child: Text(status == null
              ? nikoText('尚未收到实际状态。', 'No actual status received.')
              : '${model.active ? '' : nikoText('上次确认：', 'Last confirmed: ')}${_phaseText(status)}')),
      if (status != null && status.reason != 'queued')
        Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(_reasonText(status.reason))),
      if (requestText != null)
        Padding(
            padding: const EdgeInsets.only(top: 8), child: Text(requestText)),
      if (status?.reusable == true)
        Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(nikoText('本机资源已退出。这不表示远端资源清理已经确认。',
                'Local resources have exited. Remote cleanup is not confirmed by this fact.'))),
      const SizedBox(height: 8),
      Align(
          alignment: AlignmentDirectional.centerStart,
          child: OutlinedButton(
              key: Key('niko-tunnel-stop-$port'),
              style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: canStop
                  ? () => model.send(
                      NikoTunnelCommand.remove(
                          model.namespace, model.peerId, port)!,
                      widget.sendCommand)
                  : null,
              child: Text(nikoText('停止此端口', 'Stop this port')))),
      if (WakeSender.proxyReady(model, port))
        Padding(
            padding: const EdgeInsets.only(top: 8),
            child: OutlinedButton(
                key: Key('niko-tunnel-wake-$port'),
                onPressed: () => showNikoWakeDevicePicker(context, model, port),
                child: Text(nikoText(
                    '通过此代理唤醒设备', 'Wake a device through this proxy')))),
    ]));
  }
}

String _phaseText(NikoTunnelStatus status) => switch (status.phase) {
      NikoTunnelPhase.connecting =>
        nikoText('正在连接对端…', 'Connecting to the remote device…'),
      NikoTunnelPhase.waitingApproval => nikoText(
          '等待对方批准目标地址。', 'Waiting for remote approval of the target address.'),
      NikoTunnelPhase.starting => nikoText('对端正在准备，尚未开始本机监听。',
          'The remote device is preparing. Local listening has not started.'),
      NikoTunnelPhase.listening =>
        nikoText('本机回环端口已开始监听。', 'The local loopback port is listening.'),
      NikoTunnelPhase.stopping => nikoText(
          '正在停止，等待本机资源退出。', 'Stopping; waiting for local resources to exit.'),
      NikoTunnelPhase.closed => status.localResourcesClosed
          ? nikoText('本机隧道已关闭。', 'Local tunnel closed.')
          : nikoText('关闭结果尚未确认。', 'Closure is not confirmed.'),
      NikoTunnelPhase.failed => status.localResourcesClosed
          ? nikoText(
              '隧道失败，本机资源已退出。', 'Tunnel failed; local resources have exited.')
          : nikoText(
              '隧道失败，资源退出尚未确认。', 'Tunnel failed; resource exit is unconfirmed.'),
      NikoTunnelPhase.recoveryRequired => nikoText('资源清理未确认。请关闭此会话，确认退出后再重开。',
          'Resource cleanup is unconfirmed. Close this session and confirm exit before reopening.'),
    };

String _reasonText(String reason) {
  if ({
    'queued',
    'connecting',
    'waiting_approval',
    'starting',
    'listening',
    'stopping',
    'closed',
    'running',
    'tunnel_connecting',
    'tunnel_local_approval_required',
    'tunnel_local_listening',
    'tunnel_waiting_approval',
    'tunnel_starting',
    'tunnel_listening',
    'tunnel_stopping',
    'tunnel_local_stopping',
    'tunnel_remote_stopping',
    'tunnel_local_closed'
  }.contains(reason)) {
    return nikoText('以实际会话状态为准。', 'Follow the actual session status.');
  }
  if (reason.contains('policy') || reason == 'denied') {
    return nikoText('对端未允许此隧道请求。请联系对方检查授权设置。',
        'The remote device has not allowed this tunnel. Ask the remote user to check authorization settings.');
  }
  if (reason.contains('namespace') || reason.contains('scope')) {
    return nikoText('私服身份已变化。请关闭此会话后重开。',
        'The private server identity changed. Close and reopen this session.');
  }
  if (reason.contains('unsupported')) {
    return nikoText('当前会话或对端版本不支持此隧道。',
        'This session or remote version does not support this tunnel.');
  }
  if (reason.contains('bind') || reason.contains('port')) {
    return nikoText('本机端口无法使用。确认此会话停止后，再选择其他端口。',
        'The local port is unavailable. Confirm this session has stopped before choosing another port.');
  }
  if (reason.contains('timeout') ||
      reason.contains('expired') ||
      reason.contains('unconfirmed')) {
    return nikoText('状态未能及时确认。请停止此端口或关闭会话。',
        'Status could not be confirmed in time. Stop this port or close the session.');
  }
  if (reason == 'cancelled' || reason == 'stopped') {
    return nikoText('已请求停止。是否退出以实际状态为准。',
        'Stop requested. The actual status confirms whether resources have exited.');
  }
  return nikoText('此操作未完成。请检查连接和对端授权，或关闭此会话后重试。',
      'The operation did not complete. Check the connection and remote approval, or close and reopen the session.');
}
