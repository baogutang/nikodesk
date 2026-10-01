import 'dart:async';
import 'package:flutter/material.dart';
import 'ui.dart';
import 'wake_on_lan.dart';
import 'wake_proxy.dart';
import 'tunnel_controller.dart';
import 'wake_online.dart';

Future<void> showWakeOnLan(
  BuildContext context, {
  required String title,
  required Future<int> Function(WakeProfile) send,
  WakeProfile? initial,
  Future<void> Function(WakeProfile)? save,
  bool Function()? isOnline,
  NikoWakeOnlineMonitor? online,
  NikoWakeTunnelDirectory? proxies,
  Map<String, String> proxyLabels = const {},
  Future<void> Function()? connectProxy,
  Future<bool> Function()? isCurrent,
  String? fixedProxyId,
}) =>
    showDialog<void>(
        context: context,
        builder: (_) => _WakeDialog(
            title: title,
            send: send,
            initial: initial,
            save: save,
            isOnline: isOnline,
            online: online,
            proxies: proxies,
            proxyLabels: proxyLabels,
            connectProxy: connectProxy,
            isCurrent: isCurrent,
            fixedProxyId: fixedProxyId));

class _WakeDialog extends StatefulWidget {
  final String title;
  final Future<int> Function(WakeProfile) send;
  final WakeProfile? initial;
  final Future<void> Function(WakeProfile)? save;
  final bool Function()? isOnline;
  final NikoWakeOnlineMonitor? online;
  final NikoWakeTunnelDirectory? proxies;
  final Map<String, String> proxyLabels;
  final Future<void> Function()? connectProxy;
  final Future<bool> Function()? isCurrent;
  final String? fixedProxyId;
  const _WakeDialog(
      {required this.title,
      required this.send,
      this.initial,
      this.save,
      this.isOnline,
      this.online,
      this.proxies,
      this.proxyLabels = const {},
      this.connectProxy,
      this.isCurrent,
      this.fixedProxyId});
  @override
  State<_WakeDialog> createState() => _WakeState();
}

class _WakeState extends State<_WakeDialog> {
  late final _mac = TextEditingController(text: widget.initial?.mac ?? '');
  late final _broadcast = TextEditingController(
      text: widget.initial?.broadcast ?? '255.255.255.255');
  late final _port =
      TextEditingController(text: '${widget.initial?.port ?? 9}');
  bool _busy = false;
  String? _feedback;
  Timer? _timer;
  Timer? _proxyTimer;
  int _waitSequence = 0;
  bool _checkingOnline = false;
  final Stopwatch _waiting = Stopwatch();
  List<NikoTunnelStatus> _proxies = [];
  late String? _proxyId = widget.fixedProxyId ?? widget.initial?.proxyId;
  bool _readingProxies = false, _proxyUnconfirmed = false;
  @override
  void initState() {
    super.initState();
    if (widget.proxies != null) {
      _readProxies();
      _proxyTimer =
          Timer.periodic(const Duration(seconds: 2), (_) => _readProxies());
    }
  }

  Future<void> _readProxies() async {
    if (_readingProxies || _busy) return;
    _readingProxies = true;
    try {
      final proxies = await widget.proxies!.read();
      if (mounted) {
        setState(() {
          _proxies = proxies;
          _proxyUnconfirmed = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _proxies = [];
          _proxyUnconfirmed = true;
        });
      }
    } finally {
      _readingProxies = false;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _proxyTimer?.cancel();
    _waitSequence++;
    _waiting.stop();
    widget.online?.close();
    _mac.dispose();
    _broadcast.dispose();
    _port.dispose();
    super.dispose();
  }

  Future<void> _wake() async {
    final profile = WakeProfile.parse(_mac.text, _broadcast.text,
        port: int.tryParse(_port.text) ?? 0, proxyId: _proxyId);
    if (profile == null) {
      setState(() => _feedback = nikoText('请填写有效的网卡 MAC 和局域网广播地址。',
          'Enter a valid NIC MAC and LAN broadcast address.'));
      return;
    }
    setState(() {
      _busy = true;
      _feedback = null;
    });
    _timer?.cancel();
    final sequence = ++_waitSequence;
    try {
      if (widget.isCurrent != null && !await widget.isCurrent!()) {
        throw StateError('scope changed');
      }
      final candidates =
          _proxies.where((proxy) => proxy.peerId == _proxyId).toList();
      if (widget.proxies != null && _proxyId != null && candidates.isEmpty) {
        throw StateError('saved proxy unavailable');
      }
      if (_proxyId != null &&
          widget.proxies == null &&
          widget.fixedProxyId != _proxyId) {
        throw StateError('saved proxy route unconfirmed');
      }
      await widget.save?.call(profile);
      if (widget.isCurrent != null && !await widget.isCurrent!()) {
        throw StateError('scope changed');
      }
      final packets = widget.proxies != null && _proxyId != null
          ? await widget.proxies!.send(profile, candidates.first)
          : await widget.send(profile);
      if (widget.isCurrent != null && !await widget.isCurrent!()) {
        throw StateError('scope changed');
      }
      if (!mounted) return;
      setState(() => _feedback = nikoText('已发送 $packets 个唤醒包，等待设备上线…',
          '$packets wake packets sent; waiting for the device…'));
      if (widget.isOnline == null && widget.online == null) {
        setState(() {
          _busy = false;
          _feedback = nikoText('已确认发送唤醒包，请在设备列表查看上线状态。',
              'Wake packet transmission confirmed. Check online status on Devices.');
        });
        return;
      }
      try {
        await widget.online?.prepare();
      } catch (_) {}
      if (!mounted || sequence != _waitSequence) return;
      _waiting
        ..reset()
        ..start();
      _timer = Timer.periodic(
          const Duration(seconds: 1), (_) => _checkOnline(sequence));
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _feedback = nikoText('唤醒请求未确认，请检查网络、代理目标白名单或隧道状态后重试。',
              'Wake request unconfirmed. Check network, proxy allowlist or tunnel status and retry.');
        });
      }
    }
  }

  Future<void> _checkOnline(int sequence) async {
    if (!mounted || sequence != _waitSequence || _checkingOnline) return;
    _checkingOnline = true;
    try {
      if (widget.isCurrent != null &&
          !await widget.isCurrent!().timeout(const Duration(seconds: 3))) {
        if (!mounted || sequence != _waitSequence) return;
        _finishWaiting(nikoText('唤醒包已发送，私服或代理会话已变化，上线查询已停止。',
            'Wake packets were sent. The private server or proxy session changed; online checks stopped.'));
        return;
      }
      if (widget.online != null) {
        try {
          await widget.online!.prepareIfNeeded();
        } catch (_) {}
      }
      final online = widget.online == null
          ? widget.isOnline?.call()
          : await widget.online!.poll();
      if (!mounted || sequence != _waitSequence) return;
      if (widget.isCurrent != null &&
          !await widget.isCurrent!().timeout(const Duration(seconds: 3))) {
        if (!mounted || sequence != _waitSequence) return;
        _finishWaiting(nikoText('唤醒包已发送，私服或代理会话已变化，上线查询已停止。',
            'Wake packets were sent. The private server or proxy session changed; online checks stopped.'));
        return;
      }
      if (!mounted || sequence != _waitSequence) return;
      if (online == true) {
        _finishWaiting(nikoText('私服已查询到设备在线，可以连接。',
            'The private server reports this device online. You can connect.'));
      }
    } catch (_) {
      // A failed status read remains unknown; it never completes the wake.
    } finally {
      _checkingOnline = false;
      if (mounted &&
          sequence == _waitSequence &&
          _busy &&
          _waiting.elapsed >= const Duration(seconds: 45)) {
        _finishWaiting(nikoText('45 秒内未查询到上线。请核对 BIOS/网卡唤醒设置和网络；跨网段需使用同网段在线代理。',
            'No online status within 45 seconds. Check BIOS/NIC wake settings and the network. Use an online LAN proxy across networks.'));
      }
    }
  }

  void _finishWaiting(String text) {
    _timer?.cancel();
    _waiting.stop();
    setState(() {
      _busy = false;
      _feedback = text;
    });
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
          title: Text(widget.title),
          content: SizedBox(
              width: 440,
              child: SingleChildScrollView(
                  child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                    Text(nikoText(
                        '设备需要支持并启用 Wake-on-LAN。当前网络与设备同网段时可直接发送；跨网段请连接同网段在线代理的加密隧道。',
                        'Wake-on-LAN must be supported and enabled. Send directly on the same LAN; across networks use an encrypted tunnel to an online LAN proxy.')),
                    const SizedBox(height: 16),
                    if (widget.proxies != null) ...[
                      DropdownButtonFormField<String>(
                          key: const Key('wol-route'),
                          isExpanded: true,
                          value: _proxyId ?? 'local',
                          decoration: nikoInput(nikoText('唤醒方式', 'Wake route')),
                          items: [
                            DropdownMenuItem(
                                value: 'local',
                                child: Text(
                                    nikoText('本机所在局域网', 'This device’s LAN'))),
                            for (final id in _proxies
                                .map((proxy) => proxy.peerId)
                                .toSet())
                              DropdownMenuItem(
                                  value: id,
                                  child: Text(widget.proxyLabels[id] ?? id,
                                      overflow: TextOverflow.ellipsis)),
                            if (_proxyId != null &&
                                !_proxies
                                    .any((proxy) => proxy.peerId == _proxyId))
                              DropdownMenuItem(
                                  value: _proxyId,
                                  enabled: false,
                                  child: Text(
                                      nikoText('已保存的代理 $_proxyId 暂不可用',
                                          'Saved proxy $_proxyId is unavailable'),
                                      overflow: TextOverflow.ellipsis)),
                          ],
                          onChanged: _busy
                              ? null
                              : (value) => setState(() =>
                                  _proxyId = value == 'local' ? null : value)),
                      if (_proxyUnconfirmed)
                        Text(nikoText('代理列表未确认，不能通过已保存的代理发送。',
                            'Proxy list is unconfirmed; saved proxy routes cannot send.')),
                      if (widget.connectProxy != null)
                        TextButton(
                            key: const Key('wol-connect-proxy'),
                            style: TextButton.styleFrom(
                                minimumSize: const Size(48, 48)),
                            onPressed: _busy
                                ? null
                                : () async {
                                    final connect = widget.connectProxy!;
                                    Navigator.of(context).pop();
                                    await connect();
                                  },
                            child: Text(nikoText(
                                '连接常开设备作为代理', 'Connect an always-on proxy'))),
                      const SizedBox(height: 12),
                    ],
                    TextField(
                        key: const Key('wol-mac'),
                        controller: _mac,
                        enabled: !_busy,
                        maxLength: 17,
                        decoration: nikoInput(nikoText('网卡 MAC', 'NIC MAC'),
                            hint: '02:11:22:33:44:55')),
                    const SizedBox(height: 8),
                    TextField(
                        key: const Key('wol-broadcast'),
                        controller: _broadcast,
                        enabled: !_busy,
                        maxLength: 15,
                        decoration: nikoInput(
                            nikoText('局域网广播地址', 'LAN broadcast address'))),
                    TextField(
                        key: const Key('wol-port'),
                        controller: _port,
                        enabled: !_busy,
                        keyboardType: TextInputType.number,
                        maxLength: 5,
                        decoration: nikoInput(nikoText('UDP 端口', 'UDP port'))),
                    if (_feedback != null)
                      Semantics(
                          liveRegion: true,
                          child:
                              Text(_feedback!, key: const Key('wol-feedback')))
                  ]))),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(nikoText('关闭', 'Close'))),
            FilledButton(
                key: const Key('wol-send'),
                onPressed: _busy ? null : _wake,
                child: Text(nikoText(_busy ? '等待上线…' : '发送唤醒',
                    _busy ? 'Waiting…' : 'Send wake request')))
          ]);
}
