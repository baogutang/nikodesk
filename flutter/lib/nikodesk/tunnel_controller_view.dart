import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'nightline.dart';
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
    final nl = NlColors.maybeOf(context);
    if (nl != null) return _nightline(context, nl);
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

  /// Nightline: what a tunnel does, the new tunnel's fields over a preview
  /// of its route, the wake proxy, and one row per requested port with its
  /// confirmed state. Same checks, keys and commands as the layout below.
  Widget _nightline(BuildContext context, NlColors nl) {
    final controller = widget.controller;
    final ports = {...controller.statuses.keys, ...controller.requests.keys}
        .toList()
      ..sort();
    final ready = controller.active && !controller.busy;
    Widget field(Key key, TextEditingController text, String label,
            {required String hint, bool numeric = false}) =>
        NlTextField(
            fieldKey: key,
            controller: text,
            label: label,
            hint: hint,
            mono: true,
            keyboardType: numeric ? TextInputType.number : TextInputType.url,
            textInputAction: TextInputAction.next,
            inputFormatters: [
              if (numeric) FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(numeric ? 5 : 253),
            ],
            // The route preview follows the fields.
            onChanged: (_) => setState(() {}));
    final fields = [
      field(const Key('niko-tunnel-local-port'), _local,
          nikoText('本机端口', 'Local port'),
          hint: '8000', numeric: true),
      field(const Key('niko-tunnel-target-host'), _host,
          nikoText('对端目标主机', 'Remote target host'),
          hint: '127.0.0.1'),
      field(const Key('niko-tunnel-remote-port'), _remote,
          nikoText('目标端口', 'Target port'),
          hint: '22', numeric: true),
    ];
    String typed(TextEditingController text, String empty) =>
        text.text.trim().isEmpty ? empty : text.text.trim();
    final description = nikoText(
        '在本机 127.0.0.1 建立入口。对方需要在自己的设备上明确批准目标地址。请求排队不代表已连接。',
        'Create an entry at 127.0.0.1 on this device. The remote user must approve the target address on their device. A queued request is not a connection.');
    final address = NlType.monoText(NlType.s2, color: nl.fg2);
    final via = NlType.text(NlType.s2, color: nl.fg3);
    // Where the entry leads, as typed so far.
    final preview = Semantics(
        excludeSemantics: true,
        child: Row(children: [
          Icon(NlIcons.route, size: 14, color: nl.fg3),
          const SizedBox(width: NlSpace.s2),
          Flexible(
              child: Text.rich(
                  TextSpan(children: [
                    TextSpan(
                        text: '127.0.0.1:${typed(_local, '—')}',
                        style: address),
                    TextSpan(
                        text: '  →  ${nikoText('经对端', 'via the remote')}  →  ',
                        style: via),
                    TextSpan(
                        text:
                            '${typed(_host, nikoText('目标主机', 'host'))}:${typed(_remote, '—')}',
                        style: address),
                  ]),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis)),
        ]));
    final validation = _validation == null
        ? null
        : Semantics(
            liveRegion: true,
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Icon(NlIcons.circleAlert,
                      size: 15, color: nl.dangerText)),
              const SizedBox(width: NlSpace.s2),
              Expanded(
                  child: Text(_validation!,
                      style: NlType.text(NlType.s3, color: nl.dangerText))),
            ]));
    Widget add(bool narrow) => NlButton(
        key: const Key('niko-tunnel-add'),
        icon: NlIcons.plus,
        label: nikoText('请求隧道', 'Request tunnel'),
        expand: narrow,
        onPressed: ready ? _add : null);
    return LayoutBuilder(builder: (context, constraints) {
      final narrow =
          constraints.maxWidth / MediaQuery.textScalerOf(context).scale(1) <
              600;
      return SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
              narrow ? NlSpace.s4 : NlSpace.s8,
              narrow ? NlSpace.s4 : NlSpace.s8,
              narrow ? NlSpace.s4 : NlSpace.s8,
              NlSpace.s10),
          child: Center(
              child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 720),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // The phone's app bar already names the page.
                        if (widget.mobile)
                          Text(description,
                              style: NlType.text(NlType.s3, color: nl.fg2))
                        else
                          Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                NlIconTile(
                                    icon: NlIcons.route,
                                    color: nl.accent,
                                    size: 36),
                                const SizedBox(width: NlSpace.s3),
                                Expanded(
                                    child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                      Text(nikoText('TCP 隧道', 'TCP tunnel'),
                                          style: NlType.text(NlType.s6,
                                              weight: FontWeight.w600,
                                              color: nl.fg)),
                                      const SizedBox(height: 2),
                                      Text(description,
                                          style: NlType.text(NlType.s3,
                                              color: nl.fg2)),
                                    ])),
                              ]),
                        if (widget.mobile) ...[
                          const SizedBox(height: NlSpace.s4),
                          NikoTunnelNote(nikoText(
                              '这是本机的回环地址。请保持此页面，离开或关闭会话后不能保证隧道继续运行。',
                              'This loopback address belongs to this device. Keep this page open; leaving or closing the session does not guarantee continued operation.')),
                        ],
                        if (!controller.active) ...[
                          const SizedBox(height: NlSpace.s4),
                          NikoTunnelNote(
                              nikoText('此页已停止提交新请求。请先确认原会话退出，再重新连接。',
                                  'This page no longer submits new requests. Confirm exit of the original session before reconnecting.'),
                              warn: true),
                        ],
                        const SizedBox(height: NlSpace.s6),
                        NlSectionLabel(nikoText('新建隧道', 'New tunnel')),
                        NlPanel(
                            padding: const EdgeInsets.all(NlSpace.s4),
                            child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  if (narrow)
                                    for (final (i, field)
                                        in fields.indexed) ...[
                                      if (i > 0)
                                        const SizedBox(height: NlSpace.s3),
                                      field,
                                    ]
                                  else
                                    Row(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          for (final (i, field)
                                              in fields.indexed) ...[
                                            if (i > 0)
                                              const SizedBox(width: NlSpace.s3),
                                            Expanded(
                                                flex: i == 1 ? 2 : 1,
                                                child: field),
                                          ]
                                        ]),
                                  if (validation != null) ...[
                                    const SizedBox(height: NlSpace.s3),
                                    validation,
                                  ],
                                  const SizedBox(height: NlSpace.s4),
                                  if (narrow) ...[
                                    preview,
                                    const SizedBox(height: NlSpace.s4),
                                    add(true),
                                  ] else
                                    Row(children: [
                                      Expanded(child: preview),
                                      const SizedBox(width: NlSpace.s4),
                                      add(false),
                                    ]),
                                ])),
                        const SizedBox(height: NlSpace.s6),
                        NlSectionLabel(nikoText('远程开机', 'Wake on LAN')),
                        NlPanel(
                            padding: const EdgeInsets.all(NlSpace.s4),
                            child: Flex(
                                direction:
                                    narrow ? Axis.vertical : Axis.horizontal,
                                crossAxisAlignment: narrow
                                    ? CrossAxisAlignment.stretch
                                    : CrossAxisAlignment.center,
                                children: [
                                  // Keeps the button at the end of a wide row.
                                  Flexible(
                                      flex: narrow ? 0 : 1,
                                      fit: FlexFit.tight,
                                      child: Text(
                                          nikoText(
                                              '对方需在设置中启用唤醒代理并允许目标网卡，再批准本次连接。批准后可选择设备唤醒。',
                                              'The remote device must enable its wake proxy, permit the target NIC and approve this connection. Once approved, choose a device to wake.'),
                                          style: NlType.text(NlType.s3,
                                              color: nl.fg2))),
                                  SizedBox(
                                      width: NlSpace.s4, height: NlSpace.s3),
                                  NlButton.ghost(
                                      key: const Key(
                                          'niko-tunnel-request-wake-proxy'),
                                      icon: NlIcons.power,
                                      label: nikoText(
                                          '请求唤醒代理', 'Request wake proxy'),
                                      expand: narrow,
                                      onPressed:
                                          ready ? _requestWakeProxy : null),
                                ])),
                        const SizedBox(height: NlSpace.s6),
                        NlSectionLabel(nikoText('隧道', 'Tunnels'),
                            trailing: ports.isEmpty
                                ? null
                                : Text('${ports.length}',
                                    style: NlType.monoText(NlType.s2,
                                        color: nl.fg3))),
                        NlPanel(
                            padding: EdgeInsets.zero,
                            child: ports.isEmpty
                                ? NlEmptyState(
                                    compact: true,
                                    icon: NlIcons.route,
                                    title: nikoText('尚未请求隧道', 'No tunnel yet'),
                                    message: nikoText('不会自动恢复以前的目标。',
                                        'Previous targets are not restored automatically.'))
                                : Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                        for (final (i, port) in ports.indexed)
                                          _nightlineRow(context, nl, port,
                                              divider: i > 0),
                                      ])),
                      ]))));
    });
  }

  /// One requested port: its light and state, the target, what the native
  /// side last confirmed, and stop and wake.
  Widget _nightlineRow(BuildContext context, NlColors nl, int port,
      {required bool divider}) {
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
    final (label, tone, light) = _tunnelState(status, request);
    final indent = NlLed.dotSize + NlSpace.s3;
    Widget line(String text, {Color? color}) => Padding(
        padding: EdgeInsetsDirectional.only(start: indent, top: NlSpace.s1),
        child:
            Text(text, style: NlType.text(NlType.s2, color: color ?? nl.fg3)));
    return Container(
        decoration: divider
            ? BoxDecoration(border: Border(top: BorderSide(color: nl.line)))
            : null,
        padding: const EdgeInsets.fromLTRB(
            NlSpace.s4, NlSpace.s3, NlSpace.s4, NlSpace.s3),
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            NlLed(light),
            const SizedBox(width: NlSpace.s3),
            // The badge moves under the address when both do not fit.
            Expanded(
                child: Wrap(
                    spacing: NlSpace.s2,
                    runSpacing: NlSpace.s1,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                  SelectableText('127.0.0.1:$port',
                      style: NlType.monoText(NlType.s4,
                          weight: FontWeight.w600, color: nl.fg)),
                  NlBadge(label, tone: tone),
                ])),
          ]),
          if (target != null)
            Padding(
                padding:
                    EdgeInsetsDirectional.only(start: indent, top: NlSpace.s1),
                child: SelectableText('→ ${target.label}',
                    style: NlType.monoText(NlType.s3, color: nl.fg2))),
          Padding(
              padding:
                  EdgeInsetsDirectional.only(start: indent, top: NlSpace.s2),
              child: Semantics(
                  liveRegion: true,
                  child: Text(
                      status == null
                          ? nikoText('尚未收到实际状态。', 'No actual status received.')
                          : '${model.active ? '' : nikoText('上次确认：', 'Last confirmed: ')}${_phaseText(status)}',
                      style: NlType.text(NlType.s3, color: nl.fg2)))),
          // The generic "follow the actual status" line adds nothing under
          // the phase sentence.
          if (status != null &&
              _reasonText(status.reason) != _reasonText('running'))
            line(_reasonText(status.reason)),
          if (requestText != null)
            line(requestText,
                color: request!.state == NikoTunnelRequestState.unconfirmed ||
                        request.state == NikoTunnelRequestState.rejected
                    ? nl.warnText
                    : null),
          if (status?.reusable == true)
            line(nikoText('本机资源已退出。这不表示远端资源清理已经确认。',
                'Local resources have exited. Remote cleanup is not confirmed by this fact.')),
          Padding(
              padding:
                  EdgeInsetsDirectional.only(start: indent, top: NlSpace.s3),
              child:
                  Wrap(spacing: NlSpace.s2, runSpacing: NlSpace.s2, children: [
                NlButton.ghost(
                    key: Key('niko-tunnel-stop-$port'),
                    small: true,
                    icon: NlIcons.square,
                    label: nikoText('停止此端口', 'Stop this port'),
                    onPressed: canStop
                        ? () => model.send(
                            NikoTunnelCommand.remove(
                                model.namespace, model.peerId, port)!,
                            widget.sendCommand)
                        : null),
                if (WakeSender.proxyReady(model, port))
                  NlButton.quiet(
                      key: Key('niko-tunnel-wake-$port'),
                      small: true,
                      icon: NlIcons.power,
                      label: nikoText(
                          '通过此代理唤醒设备', 'Wake a device through this proxy'),
                      onPressed: () =>
                          showNikoWakeDevicePicker(context, model, port)),
              ])),
        ]));
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

/// A port's state as a badge and a light: what the native side last
/// confirmed, or else where the request stands.
(String, NlTone, NlLedState) _tunnelState(
        NikoTunnelStatus? status, NikoTunnelRequest? request) =>
    switch ((status?.phase, request?.state)) {
      (NikoTunnelPhase.connecting, _) => (
          nikoText('连接中', 'Connecting'),
          NlTone.neutral,
          NlLedState.live
        ),
      (NikoTunnelPhase.waitingApproval, _) => (
          nikoText('等待批准', 'Awaiting approval'),
          NlTone.warn,
          NlLedState.warn
        ),
      (NikoTunnelPhase.starting, _) => (
          nikoText('准备中', 'Starting'),
          NlTone.neutral,
          NlLedState.live
        ),
      (NikoTunnelPhase.listening, _) => (
          nikoText('监听中', 'Listening'),
          NlTone.ok,
          NlLedState.ok
        ),
      (NikoTunnelPhase.stopping, _) => (
          nikoText('停止中', 'Stopping'),
          NlTone.warn,
          NlLedState.warn
        ),
      (NikoTunnelPhase.closed, _) => status!.localResourcesClosed
          ? (nikoText('已关闭', 'Closed'), NlTone.neutral, NlLedState.off)
          : (nikoText('未确认', 'Unconfirmed'), NlTone.warn, NlLedState.warn),
      (NikoTunnelPhase.failed, _) => (
          nikoText('失败', 'Failed'),
          NlTone.danger,
          NlLedState.danger
        ),
      (NikoTunnelPhase.recoveryRequired, _) => (
          nikoText('需清理', 'Cleanup needed'),
          NlTone.danger,
          NlLedState.danger
        ),
      (null, NikoTunnelRequestState.sending) => (
          nikoText('提交中', 'Submitting'),
          NlTone.neutral,
          NlLedState.live
        ),
      (null, NikoTunnelRequestState.queued) => (
          nikoText('已排队', 'Queued'),
          NlTone.neutral,
          NlLedState.live
        ),
      (null, NikoTunnelRequestState.rejected) => (
          nikoText('未完成', 'Not done'),
          NlTone.danger,
          NlLedState.danger
        ),
      (null, NikoTunnelRequestState.unconfirmed || null) => (
          nikoText('未确认', 'Unconfirmed'),
          NlTone.warn,
          NlLedState.warn
        ),
    };

/// A note in the tunnel window and page: information, or with [warn] a
/// state the user has to act on. Announced when it changes.
class NikoTunnelNote extends StatelessWidget {
  final String text;
  final bool warn;
  final List<Widget> actions;
  const NikoTunnelNote(this.text,
      {super.key, this.warn = false, this.actions = const []});

  @override
  Widget build(BuildContext context) {
    final nl = NlColors.of(context);
    return Container(
        padding: const EdgeInsets.fromLTRB(
            NlSpace.s3, NlSpace.s3, NlSpace.s4, NlSpace.s3),
        decoration: BoxDecoration(
            color:
                warn ? nl.warn.withOpacity(nl.isDark ? .14 : .1) : nl.surface2,
            borderRadius: BorderRadius.circular(NlRadius.r2),
            border:
                Border.all(color: warn ? nl.warn.withOpacity(.35) : nl.line)),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Icon(warn ? NlIcons.triangleAlert : NlIcons.info,
                  size: 16, color: warn ? nl.warnText : nl.fg2)),
          const SizedBox(width: NlSpace.s2),
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Semantics(
                    liveRegion: true,
                    child: Text(text,
                        style: NlType.text(NlType.s3,
                            color: warn ? nl.warnText : nl.fg))),
                if (actions.isNotEmpty) ...[
                  const SizedBox(height: NlSpace.s3),
                  Wrap(
                      spacing: NlSpace.s2,
                      runSpacing: NlSpace.s2,
                      children: actions),
                ],
              ])),
        ]));
  }
}
