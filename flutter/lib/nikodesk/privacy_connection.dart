import 'dart:async';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import '../models/model.dart' show FFI, ConnType;
import '../models/platform_model.dart';
import 'connection_progress.dart';
import 'privacy_screen.dart';
import 'privacy_style.dart';
import 'ui.dart';

const nikoPrivacyAutoOption = 'nikodesk-privacy-auto-on';

class NikoPrivacyConnectionPrompt extends StatefulWidget {
  final FFI ffi;
  final VoidCallback onExplain;
  const NikoPrivacyConnectionPrompt(
      {super.key, required this.ffi, required this.onExplain});
  @override
  State<NikoPrivacyConnectionPrompt> createState() => _ArrivalState();
}

class _ArrivalState extends State<NikoPrivacyConnectionPrompt> {
  bool _connected = false, _visible = false, _auto = false, _busy = false;
  int _arrival = 0;
  String? _error;
  bool get _current =>
      mounted &&
      !widget.ffi.closed &&
      _connected &&
      widget.ffi.connType == ConnType.defaultConn &&
      widget.ffi.nikoConnectionProgress.value.phase ==
          NikoConnectionPhase.connected;
  NikoPrivacyScreenStatus get _status => nikoPrivacyScreenStatusOf(
      widget.ffi, nikoPrivacyScreenActive(widget.ffi.id)?.value ?? '');

  @override
  void initState() {
    super.initState();
    widget.ffi.nikoConnectionProgress.addListener(_observe);
    widget.ffi.ffiModel.addListener(_refresh);
    WidgetsBinding.instance.addPostFrameCallback((_) => _observe());
  }

  @override
  void dispose() {
    _arrival++;
    widget.ffi.nikoConnectionProgress.removeListener(_observe);
    widget.ffi.ffiModel.removeListener(_refresh);
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  void _observe() {
    if (!mounted) return;
    final connected = !widget.ffi.closed &&
        widget.ffi.nikoConnectionProgress.value.phase ==
            NikoConnectionPhase.connected;
    if (connected == _connected) return;
    _connected = connected;
    final arrival = ++_arrival;
    setState(() {
      _visible = false;
      _busy = false;
      _error = null;
    });
    if (_current &&
        _status != NikoPrivacyScreenStatus.unsupported &&
        _status != NikoPrivacyScreenStatus.on) unawaited(_arrive(arrival));
  }

  Future<void> _arrive(int arrival) async {
    bool auto = false;
    try {
      auto = await bind.sessionGetPeerOption(
              sessionId: widget.ffi.sessionId, name: nikoPrivacyAutoOption) ==
          'Y';
    } catch (_) {/* A missing preference keeps the optional reminder. */}
    if (!_current ||
        arrival != _arrival ||
        _status == NikoPrivacyScreenStatus.on) return;
    setState(() {
      _auto = auto;
      _visible = true;
    });
    if (auto && _status == NikoPrivacyScreenStatus.off) await _enable();
  }

  Future<void> _setAuto(bool value) async {
    if (!_current || _busy) return;
    final arrival = _arrival;
    setState(() => _busy = true);
    try {
      await bind.sessionPeerOption(
          sessionId: widget.ffi.sessionId,
          name: nikoPrivacyAutoOption,
          value: value ? 'Y' : 'N');
      if (_current && arrival == _arrival) setState(() => _auto = value);
    } catch (_) {
      if (_current && arrival == _arrival)
        setState(() => _error = nikoText(
            '未能保存自动开启设置，请重试。', 'Could not save this preference. Retry.'));
    } finally {
      if (_current && arrival == _arrival) setState(() => _busy = false);
    }
  }

  Future<void> _enable() async {
    if (!_current || _busy) return;
    if (_status != NikoPrivacyScreenStatus.off) {
      widget.onExplain();
      return;
    }
    final arrival = _arrival;
    widget.ffi.inputModel.enterOrLeave(false);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await nikoRequestPrivacyScreen(widget.ffi, on: true);
      if (_current && arrival == _arrival) setState(() => _visible = false);
    } catch (error) {
      if (_current && arrival == _arrival)
        setState(() => _error = nikoPrivacyStyleError(error));
    } finally {
      if (_current && arrival == _arrival) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_current || !_visible) return const SizedBox.shrink();
    final active = nikoPrivacyScreenActive(widget.ffi.id);
    return Positioned(
        left: 12,
        right: 12,
        top: 12,
        child: active == null
            ? const SizedBox.shrink()
            : Obx(() => active.value.isNotEmpty
                ? const SizedBox.shrink()
                : Align(
                    alignment: Alignment.topCenter,
                    child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 480),
                        child: NikoPrivacyArrivalView(
                            allowed: _status == NikoPrivacyScreenStatus.off,
                            auto: _auto,
                            busy: _busy,
                            error: _error,
                            onAuto: _setAuto,
                            onEnable: _enable,
                            onSkip: () => setState(() => _visible = false))))));
  }
}

class NikoPrivacyArrivalView extends StatelessWidget {
  final bool allowed, auto, busy;
  final String? error;
  final ValueChanged<bool> onAuto;
  final VoidCallback onEnable, onSkip;
  const NikoPrivacyArrivalView(
      {super.key,
      required this.allowed,
      required this.auto,
      required this.busy,
      this.error,
      required this.onAuto,
      required this.onEnable,
      required this.onSkip});
  @override
  Widget build(BuildContext context) => Material(
      color: const Color(0xff24282e),
      borderRadius: BorderRadius.circular(12),
      elevation: 6,
      child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                    nikoText(
                        '开启被控电脑的隐私屏？', 'Turn on the remote privacy screen?'),
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 5),
                Text(
                    allowed
                        ? nikoText('电脑屏幕仍在显示你的远程操作。',
                            'Your remote activity is still visible on that computer.')
                        : nikoText('被控端尚未允许隐私屏，请在控制中心查看设置。',
                            'Privacy screen is unavailable. Check permissions in Control center.'),
                    style:
                        const TextStyle(color: Colors.white70, fontSize: 13)),
                CheckboxListTile(
                    key: const Key('privacy-arrival-auto'),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    value: auto,
                    onChanged: busy ? null : (value) => onAuto(value ?? false),
                    title: Text(
                        nikoText('以后连接这台电脑自动开启',
                            'Turn on automatically for this computer'),
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 13))),
                if (error != null)
                  Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(error!,
                          style: const TextStyle(
                              color: Color(0xffffc8a4), fontSize: 13))),
                Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                  TextButton(
                      key: const Key('privacy-arrival-skip'),
                      onPressed: busy ? null : onSkip,
                      child: Text(nikoText('暂不开启', 'Not now'))),
                  const SizedBox(width: 8),
                  FilledButton(
                      key: const Key('privacy-arrival-enable'),
                      onPressed: busy ? null : onEnable,
                      child: Text(busy
                          ? nikoText('开启中…', 'Turning on…')
                          : allowed
                              ? nikoText('开启', 'Turn on')
                              : nikoText('查看设置', 'Check settings'))),
                ]),
              ])));
}

class NikoPrivacyAutoPreference extends StatefulWidget {
  final FFI ffi;
  const NikoPrivacyAutoPreference({super.key, required this.ffi});
  @override
  State<NikoPrivacyAutoPreference> createState() => _PreferenceState();
}

class _PreferenceState extends State<NikoPrivacyAutoPreference> {
  bool? _value;
  bool _busy = false;
  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final value = await bind.sessionGetPeerOption(
          sessionId: widget.ffi.sessionId, name: nikoPrivacyAutoOption);
      if (mounted && !widget.ffi.closed) setState(() => _value = value == 'Y');
    } catch (_) {
      if (mounted) setState(() => _value = null);
    }
  }

  Future<void> _save(bool value) async {
    if (widget.ffi.closed || _busy) return;
    setState(() => _busy = true);
    try {
      await bind.sessionPeerOption(
          sessionId: widget.ffi.sessionId,
          name: nikoPrivacyAutoOption,
          value: value ? 'Y' : 'N');
      if (mounted && !widget.ffi.closed) setState(() => _value = value);
    } catch (_) {
      if (mounted) setState(() => _value = null);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => SwitchListTile.adaptive(
      key: const Key('privacy-auto-preference'),
      contentPadding: EdgeInsets.zero,
      title: Text(
          nikoText('连接后自动开启隐私屏', 'Turn on privacy screen after connecting')),
      subtitle: Text(_value == null
          ? nikoText('设置暂不可用', 'Preference unavailable')
          : nikoText('仅对这台电脑生效；关闭后改为可跳过的提醒。',
              'Applies to this computer. Turn off to use an optional reminder.')),
      value: _value ?? false,
      onChanged: _value == null || _busy ? null : _save);
}
