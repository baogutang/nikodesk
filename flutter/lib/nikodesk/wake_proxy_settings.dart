import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'nightline.dart';
import 'settings_kit.dart';
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
  Widget build(BuildContext context) {
    final nl = NlColors.of(context);
    final title = nikoText('让本机作为唤醒代理', 'Use this computer as a wake proxy');
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      NikoSettingsGroup(children: [
        NikoSettingRow(
            title: title,
            description: nikoText(
                '默认关闭。在待开机电脑同网段的常开电脑上启用；只唤醒下列设备。远程使用还需要允许隧道请求，并批准本次代理连接。',
                'Off by default. Enable on an always-on computer in the target LAN; only the targets below can be awakened. Remote use also requires tunnel requests to be allowed and this proxy connection to be approved.'),
            busy: _busy,
            trailing: NlSwitch(
                switchKey: const Key('wake-proxy-enabled'),
                semanticLabel: title,
                value: _enabled,
                onChanged: _editable
                    ? (value) => setState(() => _enabled = value)
                    : null),
            below: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Semantics(liveRegion: true, child: NikoSettingNote(_state())),
                  if (_dirty) ...[
                    const SizedBox(height: NlSpace.s1),
                    NikoSettingNote(
                        nikoText('修改尚未保存，点击保存后生效。',
                            'Changes are unsaved. Save to apply.'),
                        tone: NlTone.warn),
                  ],
                  if (_error != null) ...[
                    const SizedBox(height: NlSpace.s1),
                    NikoSettingNote(_error!, tone: NlTone.danger),
                  ],
                ])),
      ]),
      NikoSettingsGroup(
          title: nikoText('允许唤醒的设备', 'Permitted targets'),
          children: [
            for (final target in _targets)
              NikoSettingRow(
                  leading: Icon(NlIcons.power, size: 16, color: nl.fg3),
                  title: target.mac,
                  description: '${target.broadcast}:${target.port}',
                  trailing: NlIconButton(
                      key: ValueKey(
                          'wake-proxy-remove-${target.mac}-${target.broadcast}-${target.port}'),
                      icon: NlIcons.close,
                      tooltip: nikoText('移除允许的设备', 'Remove permitted target'),
                      onPressed: _editable
                          ? () => setState(() => _targets.remove(target))
                          : null)),
            Padding(
                padding: const EdgeInsets.symmetric(vertical: NlSpace.s3),
                child: Wrap(
                    spacing: NlSpace.s2,
                    runSpacing: NlSpace.s2,
                    crossAxisAlignment: WrapCrossAlignment.end,
                    children: [
                      SizedBox(
                          width: 190,
                          child: NlTextField(
                              fieldKey: const Key('wake-proxy-mac'),
                              controller: _mac,
                              enabled: _editable,
                              mono: true,
                              label: nikoText('网卡 MAC', 'NIC MAC'),
                              hint: 'AA:BB:CC:DD:EE:FF',
                              inputFormatters: [
                                LengthLimitingTextInputFormatter(17)
                              ])),
                      SizedBox(
                          width: 170,
                          child: NlTextField(
                              fieldKey: const Key('wake-proxy-broadcast'),
                              controller: _broadcast,
                              enabled: _editable,
                              mono: true,
                              label: nikoText('广播地址', 'Broadcast address'),
                              inputFormatters: [
                                LengthLimitingTextInputFormatter(15)
                              ])),
                      SizedBox(
                          width: 88,
                          child: NlTextField(
                              fieldKey: const Key('wake-proxy-port'),
                              controller: _port,
                              enabled: _editable,
                              mono: true,
                              keyboardType: TextInputType.number,
                              label: nikoText('端口', 'Port'),
                              inputFormatters: [
                                LengthLimitingTextInputFormatter(5)
                              ])),
                      NlButton.ghost(
                          key: const Key('wake-proxy-add'),
                          icon: NlIcons.plus,
                          onPressed: _editable ? _add : null,
                          label: nikoText('添加设备', 'Add target')),
                    ])),
          ]),
      Wrap(spacing: NlSpace.s2, runSpacing: NlSpace.s2, children: [
        NlButton(
            key: const Key('wake-proxy-save'),
            onPressed: _editable ? _save : null,
            label: nikoText('保存代理设置', 'Save proxy settings')),
        NlButton.quiet(
            key: const Key('wake-proxy-reload'),
            icon: NlIcons.refreshCw,
            onPressed: _busy ? null : _load,
            label: nikoText('重新读取', 'Reload')),
      ]),
      const SizedBox(height: NlSpace.s5),
      NikoSettingNote(nikoText(
          'NAS 仅部署协调／中继服务器时不能直接作为此代理；可使用同网段运行 NikoDesk 的常开电脑。',
          'A NAS running only rendezvous/relay services cannot serve as this proxy. Use an always-on computer running NikoDesk in the target LAN.')),
    ]);
  }
}
