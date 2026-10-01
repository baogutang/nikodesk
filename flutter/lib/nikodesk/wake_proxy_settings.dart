import 'dart:convert';

import 'package:flutter/material.dart';

import 'ui.dart';
import 'wake_on_lan.dart';
import 'wake_proxy.dart';

class NikoWakeProxySettings extends StatefulWidget {
  final NikoWakeProxyGateway? gateway;
  const NikoWakeProxySettings({super.key, this.gateway});
  @override
  State<NikoWakeProxySettings> createState() => _WakeSettingsState();
}

class _WakeSettingsState extends State<NikoWakeProxySettings> {
  late final _gateway = widget.gateway ?? NativeNikoWakeProxyGateway();
  final _mac = TextEditingController();
  final _broadcast = TextEditingController(text: '255.255.255.255');
  final _port = TextEditingController(text: '9');
  NikoWakeProxySnapshot? _snapshot;
  List<WakeProfile> _targets = [];
  bool _enabled = false, _busy = true;
  String? _error;
  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _mac.dispose();
    _broadcast.dispose();
    _port.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _busy = true);
    try {
      final namespace = await _gateway.namespace();
      final snapshot = await _gateway.read(namespace);
      if (await _gateway.namespace() != namespace) throw StateError('changed');
      if (mounted) {
        setState(() {
          _snapshot = snapshot;
          _targets = snapshot.policy.targets.toList();
          _enabled = snapshot.policy.enabled;
          _error = null;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _snapshot = null;
          _error = nikoText('无法确认唤醒代理设置，请重新读取。',
              'Wake proxy settings are unconfirmed. Reload.');
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _add() {
    final profile = WakeProfile.parse(_mac.text, _broadcast.text,
        port: int.tryParse(_port.text) ?? 0);
    if (profile == null ||
        _targets.length >= 64 ||
        _targets.any((item) =>
            item.mac == profile.mac &&
            item.broadcast == profile.broadcast &&
            item.port == profile.port)) {
      setState(() => _error = nikoText('请填写有效且不重复的网卡 MAC、局域网广播地址和端口，最多 64 项。',
          'Enter a valid, unique NIC MAC, LAN broadcast address and port. Up to 64 targets.'));
      return;
    }
    setState(() {
      _targets.add(profile);
      _mac.clear();
      _error = null;
    });
  }

  Future<void> _save() async {
    final snapshot = _snapshot;
    if (snapshot == null) return;
    final policy =
        NikoWakeProxyPolicy(snapshot.policy.namespace, _enabled, _targets);
    if (NikoWakeProxyPolicy.parse(policy.toJson()) == null) {
      setState(() => _error = nikoText('开启前至少添加一个允许唤醒的设备。',
          'Add at least one permitted wake target before enabling.'));
      return;
    }
    setState(() => _busy = true);
    try {
      if (await _gateway.namespace() != policy.namespace) {
        throw StateError('changed');
      }
      await _gateway.save(policy);
      final readback = await _gateway.read(policy.namespace);
      final expected = NikoWakeProxyPolicy.parse(policy.toJson())!;
      if (await _gateway.namespace() != policy.namespace ||
          jsonEncode(readback.policy.toJson()) !=
              jsonEncode(expected.toJson())) {
        throw StateError('unconfirmed');
      }
      if (mounted) {
        setState(() {
          _snapshot = readback;
          _targets = readback.policy.targets.toList();
          _error = null;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _snapshot = null;
          _error = nikoText(
              '保存未确认，请重新读取。', 'Saving is unconfirmed. Reload settings.');
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  bool get _editable => !_busy && _snapshot != null;
  bool get _dirty {
    final snapshot = _snapshot;
    if (snapshot == null) return false;
    final draft = NikoWakeProxyPolicy.parse(
        NikoWakeProxyPolicy(snapshot.policy.namespace, _enabled, _targets)
            .toJson());
    return draft == null ||
        jsonEncode(draft.toJson()) != jsonEncode(snapshot.policy.toJson());
  }

  String _state() => switch (_snapshot?.state) {
        'listening' => nikoText('代理正在运行', 'Proxy is running'),
        'disabled' => nikoText('唤醒请求已禁用', 'Wake requests are disabled'),
        'paused' => nikoText('远控接收已暂停，代理不接受请求',
            'Remote reception is paused; proxy does not accept requests'),
        'unsupported' =>
          nikoText('当前运行模式不支持唤醒代理', 'Wake proxy is unavailable in this mode'),
        'unavailable' => nikoText('设置已开启，代理尚未确认运行。请确认本机接收端正在运行后刷新。',
            'Enabled in settings; running is not confirmed. Check that this device’s receiver is running, then reload.'),
        _ => nikoText('代理状态未确认', 'Proxy status is unconfirmed'),
      };

  @override
  Widget build(BuildContext context) =>
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SwitchListTile.adaptive(
            key: const Key('wake-proxy-enabled'),
            contentPadding: EdgeInsets.zero,
            title: Text(
                nikoText('让本机作为唤醒代理', 'Use this computer as a wake proxy')),
            subtitle: Text(nikoText(
                '默认关闭。在待开机电脑同网段的常开电脑上启用；只唤醒下列设备。远程使用还需要允许隧道请求，并批准本次代理连接。',
                'Off by default. Enable on an always-on computer in the target LAN; only the targets below can be awakened. Remote use also requires tunnel requests to be allowed and this proxy connection to be approved.')),
            value: _enabled,
            onChanged:
                _editable ? (value) => setState(() => _enabled = value) : null),
        Semantics(liveRegion: true, child: Text(_state())),
        if (_dirty)
          Text(nikoText(
              '修改尚未保存，点击保存后生效。', 'Changes are unsaved. Save to apply.')),
        const SizedBox(height: 12),
        for (final target in _targets)
          Row(children: [
            Expanded(
                child:
                    Text('${target.mac}\n${target.broadcast}:${target.port}')),
            IconButton(
                key: ValueKey(
                    'wake-proxy-remove-${target.mac}-${target.broadcast}-${target.port}'),
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                tooltip: nikoText('移除允许的设备', 'Remove permitted target'),
                onPressed: _editable
                    ? () => setState(() => _targets.remove(target))
                    : null,
                icon: const Icon(Icons.close)),
          ]),
        const SizedBox(height: 8),
        TextField(
            key: const Key('wake-proxy-mac'),
            controller: _mac,
            enabled: _editable,
            autocorrect: false,
            enableSuggestions: false,
            maxLength: 17,
            decoration:
                nikoInput(nikoText('允许唤醒的网卡 MAC', 'Permitted NIC MAC'))),
        const SizedBox(height: 8),
        TextField(
            key: const Key('wake-proxy-broadcast'),
            controller: _broadcast,
            enabled: _editable,
            autocorrect: false,
            enableSuggestions: false,
            maxLength: 15,
            decoration: nikoInput(nikoText(
                '设备所在局域网的广播地址', 'Broadcast address in the target LAN'))),
        const SizedBox(height: 8),
        TextField(
            key: const Key('wake-proxy-port'),
            controller: _port,
            enabled: _editable,
            keyboardType: TextInputType.number,
            maxLength: 5,
            decoration: nikoInput(nikoText('唤醒端口', 'Wake port'))),
        Wrap(spacing: 12, runSpacing: 8, children: [
          OutlinedButton(
              key: const Key('wake-proxy-add'),
              style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: _editable ? _add : null,
              child: Text(nikoText('添加设备', 'Add target'))),
          ElevatedButton(
              key: const Key('wake-proxy-save'),
              style: ElevatedButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: _editable ? _save : null,
              child: Text(nikoText('保存代理设置', 'Save proxy settings'))),
          TextButton(
              key: const Key('wake-proxy-reload'),
              style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: _busy ? null : _load,
              child: Text(nikoText('重新读取', 'Reload'))),
        ]),
        if (_busy) const LinearProgressIndicator(),
        if (_error != null)
          Semantics(
              liveRegion: true,
              child: Text(_error!,
                  style:
                      TextStyle(color: Theme.of(context).colorScheme.error))),
        Text(
            nikoText('NAS 仅部署协调／中继服务器时不能直接作为此代理；可使用同网段运行 NikoDesk 的常开电脑。',
                'A NAS running only rendezvous/relay services cannot serve as this proxy. Use an always-on computer running NikoDesk in the target LAN.'),
            style: Theme.of(context).textTheme.bodySmall),
      ]);
}
