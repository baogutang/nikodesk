import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/desktop/pages/desktop_setting_page.dart';
import 'package:flutter_hbb/models/platform_model.dart';

import 'device_page.dart';
import 'device_store.dart';
import 'home_settings.dart';
import 'server_gateway.dart';
import 'session_history.dart';
import 'session_log.dart';
import 'theme.dart';
import 'ui.dart';

/// Product shell for the NikoDesk home window: glass sidebar plus the device
/// workspace. Replaces the stock RustDesk two-pane home while keeping every
/// session path native — nothing here mocks connections.
class NikoHomeShell extends StatefulWidget {
  final DeviceStore? store;
  final ServerGateway? gateway;
  final Future<void> Function(BuildContext, String, bool,
      {bool isFileTransfer, String? password})? onConnect;
  final String Function()? deviceIdProvider;
  final Future<String> Function()? temporaryPasswordProvider;
  final SessionLogStore? sessionLog;

  /// null probes mean "ask the native layer"; tests inject stubs.
  final bool Function()? screenRecordingProbe;
  final bool Function()? accessibilityProbe;
  final void Function(bool prompt)? screenRecordingRequest;
  final void Function(bool prompt)? accessibilityRequest;

  const NikoHomeShell(
      {super.key,
      this.store,
      this.gateway,
      this.onConnect,
      this.deviceIdProvider,
      this.temporaryPasswordProvider,
      this.sessionLog,
      this.screenRecordingProbe,
      this.accessibilityProbe,
      this.screenRecordingRequest,
      this.accessibilityRequest});

  @override
  State<NikoHomeShell> createState() => _NikoHomeShellState();
}

class _NikoHomeShellState extends State<NikoHomeShell> {
  late final _store = widget.store ?? DeviceStore.instance;
  late final _gateway = widget.gateway ?? NativeServerGateway();
  int _index = 0;
  Brightness _brightness = Brightness.light;
  ServerSnapshot? _server;
  String? _temporaryPassword;
  bool _showPassword = false;
  bool _canScreen = true;
  bool _canAccessibility = true;
  Timer? _timer;

  bool get _native => widget.gateway == null;

  @override
  void initState() {
    super.initState();
    _refreshStatus();
    _timer =
        Timer.periodic(const Duration(seconds: 3), (_) => _refreshStatus());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refreshStatus() async {
    // Follow the app-level theme (user setting / system) for the shell skin.
    var brightness =
        WidgetsBinding.instance.platformDispatcher.platformBrightness;
    if (_native && mounted) {
      brightness = Theme.of(context).brightness;
    }
    bool canScreen = true;
    bool canAccessibility = true;
    String? password;
    try {
      if (widget.screenRecordingProbe != null) {
        canScreen = widget.screenRecordingProbe!();
      } else if (_native && Platform.isMacOS) {
        canScreen = bind.mainIsCanScreenRecording(prompt: false);
      }
      if (widget.accessibilityProbe != null) {
        canAccessibility = widget.accessibilityProbe!();
      } else if (_native && Platform.isMacOS) {
        canAccessibility = bind.mainIsProcessTrusted(prompt: false);
      }
      if (widget.temporaryPasswordProvider != null) {
        password = await widget.temporaryPasswordProvider!();
      } else if (_native) {
        password = await bind.mainGetTemporaryPassword();
      }
    } catch (_) {
      // Missing probes never crash the home; cards simply stay neutral.
    }
    ServerSnapshot? server;
    try {
      server = await _gateway.read();
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _brightness = brightness;
      _canScreen = canScreen;
      _canAccessibility = canAccessibility;
      _temporaryPassword = password;
      _server = server ?? _server;
    });
  }

  String get _deviceId {
    if (widget.deviceIdProvider != null) return widget.deviceIdProvider!();
    if (!_native) return '';
    try {
      return gFFI.serverModel.serverId.text;
    } catch (_) {
      return '';
    }
  }

  void _copy(String value, String label) {
    Clipboard.setData(ClipboardData(text: value));
    nikoNotice(context, nikoText('已复制$label', '$label copied'));
  }

  Future<void> _requestScreenRecording() async {
    if (widget.screenRecordingRequest != null) {
      widget.screenRecordingRequest!(true);
    } else if (_native) {
      bind.mainIsCanScreenRecording(prompt: true);
    }
    await _refreshStatus();
  }

  Future<void> _requestAccessibility() async {
    if (widget.accessibilityRequest != null) {
      widget.accessibilityRequest!(true);
    } else if (_native) {
      bind.mainIsProcessTrusted(prompt: true);
    }
    await _refreshStatus();
  }

  Future<void> _setPermanentPassword() async {
    final controller = TextEditingController();
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
              title: Text(nikoText('设置永久密码', 'Set permanent password')),
              content: Column(mainAxisSize: MainAxisSize.min, children: [
                Text(nikoText(
                    '远端使用该密码连接本机。请仅在你自己的设备间使用，不要复用其他账户密码。',
                    'Remote sides use this password to reach this computer. Keep it unique to NikoDesk.')),
                const SizedBox(height: 12),
                TextField(
                    controller: controller,
                    autofocus: true,
                    obscureText: true,
                    decoration: nikoInput(nikoText('新密码', 'New password'))),
              ]),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(dialog, false),
                    child: Text(nikoText('取消', 'Cancel'))),
                FilledButton(
                    onPressed: () => Navigator.pop(dialog, true),
                    child: Text(nikoText('保存', 'Save'))),
              ],
            ));
    if (confirmed != true) return;
    try {
      if (_native) {
        final ok = await bind
            .mainSetPermanentPasswordWithResult(password: controller.text);
        if (!ok) throw StateError('rejected');
      }
      if (mounted) {
        nikoNotice(
            context,
            nikoText('永久密码已更新。远端仍需逐次完成加密握手。',
                'Permanent password updated. Each session still completes its own encrypted handshake.'));
      }
    } catch (_) {
      if (mounted) {
        nikoNotice(context,
            nikoText('设置失败，密码未变更。', 'Update failed. The password is unchanged.'));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final shell = nikoTheme(_brightness);
    final light = _brightness == Brightness.light;
    return Theme(
        data: shell,
        child: DecoratedBox(
            decoration: BoxDecoration(
                gradient: light ? NikoPalette.lightCanvas : null,
                color: light ? null : NikoPalette.darkScaffold),
            child: Scaffold(
                backgroundColor: Colors.transparent,
                body: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _sidebar(shell, light),
                      VerticalDivider(
                          width: 1,
                          thickness: 1,
                          color: light
                              ? Colors.white.withOpacity(.7)
                              : NikoPalette.darkLine),
                      Expanded(
                          child: IndexedStack(index: _index, children: [
                        NikoDevicePage(
                            store: _store,
                            gateway: _gateway,
                            onConnect: widget.onConnect,
                            onOpenSettings: () =>
                                setState(() => _index = _settingsIndex)),
                        NikoSessionHistoryPage(
                            store: widget.sessionLog,
                            onConnect: widget.onConnect),
                        NikoSettingsView(
                            gateway: _gateway,
                            native: _native,
                            onServerSaved: _refreshStatus,
                            onOpenAdvanced: () =>
                                setState(() => _index = _advancedIndex)),
                        _advancedPage(shell),
                      ])),
                    ]))));
  }

  static const _settingsIndex = 2;
  static const _advancedIndex = 3;

  /// The full upstream settings page, hosted inside the shell instead of a
  /// legacy tab. Widget tests inject a gateway and never build it because
  /// the upstream page reads native options while constructing.
  Widget _advancedPage(ThemeData shell) {
    if (!_native) {
      return Center(
          child: Text(nikoText('高级设置仅在应用内提供。', 'Advanced settings are app-only.'),
              style: TextStyle(color: shell.colorScheme.onSurfaceVariant)));
    }
    return Padding(
        padding: const EdgeInsets.all(12),
        child: DesktopSettingPage(initialTabkey: SettingsTabKey.general));
  }

  Widget _sidebar(ThemeData shell, bool light) {
    final serverOk =
        _server?.config.isValid == true && _server?.enabled == true;
    final registered = serverOk && _server?.registrationStatus == 1;
    final nav = [
      _NavItem(Icons.devices_rounded, nikoText('设备', 'Devices')),
      _NavItem(Icons.history_rounded, nikoText('会话', 'Sessions')),
      _NavItem(Icons.tune_rounded, nikoText('设置', 'Settings')),
      _NavItem(Icons.settings_suggest_rounded,
          nikoText('高级设置', 'Advanced')),
    ];
    final panel = Container(
        width: 236,
        color: light ? null : NikoPalette.darkSidebar,
        child: SafeArea(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
              Padding(
                  padding: const EdgeInsets.fromLTRB(16, 18, 16, 14),
                  child: Row(children: [
                    Container(
                        width: 34,
                        height: 34,
                        clipBehavior: Clip.antiAlias,
                        decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(10),
                            boxShadow: light
                                ? const [
                                    BoxShadow(
                                        color: Color(0x406C4CF1),
                                        blurRadius: 12,
                                        offset: Offset(0, 4))
                                  ]
                                : null),
                        child: Image.asset('assets/nikodesk.png',
                            width: 34,
                            height: 34,
                            filterQuality: FilterQuality.medium)),
                    const SizedBox(width: 10),
                    Text('NikoDesk',
                        style: shell.textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700)),
                  ])),
              for (var i = 0; i < nav.length; i++)
                Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                    child: _NavTile(
                        item: nav[i],
                        selected: _index == i,
                        onTap: () => setState(() => _index = i))),
              const Divider(indent: 16, endIndent: 16),
              Expanded(
                  child: SingleChildScrollView(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _localCard(shell, light),
                            if (Platform.isMacOS &&
                                (!_canScreen || !_canAccessibility)) ...[
                              const SizedBox(height: 10),
                              _permissionCard(shell),
                            ],
                            const SizedBox(height: 10),
                            _serverCard(shell, serverOk, registered),
                          ]))),
              Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                      nikoText('私有服务器 · 端到端加密',
                          'Private server · End-to-end encrypted'),
                      textAlign: TextAlign.center,
                      style: shell.textTheme.bodySmall
                          ?.copyWith(color: shell.colorScheme.onSurfaceVariant))),
                ])));
    if (!light) return panel;
    return ClipRect(
        child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
            child: Container(
                width: 236,
                color: Colors.white.withOpacity(.55),
                child: panel.child)));
  }

  Widget _localCard(ThemeData shell, bool light) => NikoGlassCard(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.desktop_mac_rounded,
                size: 16, color: shell.colorScheme.primary),
            const SizedBox(width: 6),
            Text(nikoText('本机', 'This computer'),
                style: shell.textTheme.labelMedium
                    ?.copyWith(color: shell.colorScheme.onSurfaceVariant)),
          ]),
          const SizedBox(height: 8),
          Builder(builder: (_) {
            final id = _deviceId;
            return Row(children: [
              Expanded(
                  child: Text(id.isEmpty ? '—' : id,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: nikoIdStyle(context, fontSize: 19))),
              InkWell(
                  customBorder: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(6)),
                  onTap: id.isEmpty
                      ? null
                      : () => _copy(id, nikoText('设备 ID', 'device ID')),
                  child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: Icon(Icons.copy_rounded,
                          size: 15, color: shell.colorScheme.primary))),
            ]);
          }),
          const SizedBox(height: 10),
          Builder(builder: (_) {
            final raw = _temporaryPassword ?? '';
            final password = raw.isEmpty
                ? null
                : (_showPassword
                    ? raw
                    : '•' * raw.length.clamp(4, 10));
            return Row(children: [
              Icon(Icons.password_rounded,
                  size: 14, color: shell.colorScheme.onSurfaceVariant),
              const SizedBox(width: 6),
              Expanded(
                  child: Text(
                      password ?? nikoText('未设置临时密码', 'No temporary password'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: shell.textTheme.bodySmall),
              ),
              if (password != null) ...[
                InkWell(
                    customBorder: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(6)),
                    onTap: () =>
                        setState(() => _showPassword = !_showPassword),
                    child: Padding(
                        padding: const EdgeInsets.all(3),
                        child: Icon(
                            _showPassword
                                ? Icons.visibility_off_rounded
                                : Icons.visibility_rounded,
                            size: 14,
                            color: shell.colorScheme.onSurfaceVariant))),
                InkWell(
                    customBorder: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(6)),
                    onTap: () =>
                        _copy(raw, nikoText('密码', 'password')),
                    child: Padding(
                        padding: const EdgeInsets.all(3),
                        child: Icon(Icons.copy_rounded,
                            size: 14, color: shell.colorScheme.primary))),
              ],
            ]);
          }),
          const SizedBox(height: 10),
          Center(
              child: TextButton(
                  onPressed: _setPermanentPassword,
                  child: Text(nikoText('设置永久密码', 'Set permanent password'),
                      style: const TextStyle(fontSize: 12)))),
        ]),
      );

  Widget _permissionCard(ThemeData shell) {
    Widget row(String label, VoidCallback onTap) => InkWell(
        customBorder:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        onTap: onTap,
        child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
            child: Row(children: [
              const Icon(Icons.error_outline_rounded,
                  size: 16, color: NikoPalette.warning),
              const SizedBox(width: 8),
              Expanded(child: Text(label, style: shell.textTheme.bodySmall)),
              Icon(Icons.chevron_right_rounded,
                  size: 16, color: shell.colorScheme.onSurfaceVariant),
            ])));
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: NikoPalette.warning.withOpacity(.08),
        borderRadius: BorderRadius.circular(NikoShapes.card),
        border: Border.all(color: NikoPalette.warning.withOpacity(.35)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(nikoText('本机权限', 'Local permissions'),
            style: shell.textTheme.labelMedium
                ?.copyWith(color: NikoPalette.warning)),
        if (!_canScreen)
          row(nikoText('屏幕录制（被控画面必需）',
              'Screen recording (required to be controlled)'), _requestScreenRecording),
        if (!_canAccessibility)
          row(nikoText('辅助功能（远端键鼠必需）',
              'Accessibility (required for remote input)'), _requestAccessibility),
      ]),
    );
  }

  Widget _serverCard(ThemeData shell, bool serverOk, bool registered) {
    final host = _server?.config.idServer ?? '';
    final status = !serverOk
        ? nikoText('未配置', 'Not configured')
        : registered
            ? nikoText('已就绪', 'Ready')
            : nikoText('注册中', 'Registering');
    return InkWell(
      customBorder: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(NikoShapes.card)),
      onTap: () => setState(() => _index = 1),
      child: NikoGlassCard(
        padding: const EdgeInsets.all(12),
        boxShadow: const [],
        child: Row(children: [
          Icon(Icons.dns_rounded, size: 16, color: shell.colorScheme.primary),
          const SizedBox(width: 8),
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text(nikoText('私有服务器', 'Private server'),
                    style: shell.textTheme.labelMedium?.copyWith(
                        color: shell.colorScheme.onSurfaceVariant)),
                const SizedBox(height: 2),
                Text(host.isEmpty ? nikoText('未配置', 'Not configured') : host,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: shell.textTheme.bodySmall),
              ])),
          Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: (registered ? NikoPalette.success : NikoPalette.warning)
                    .withOpacity(.14),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: registered
                            ? NikoPalette.success
                            : NikoPalette.warning)),
                const SizedBox(width: 5),
                Text(status,
                    style: shell.textTheme.labelSmall?.copyWith(
                        color: registered
                            ? NikoPalette.success
                            : NikoPalette.warning)),
              ])),
        ]),
      ),
    );
  }
}

class _NavItem {
  final IconData icon;
  final String label;
  const _NavItem(this.icon, this.label);
}

class _NavTile extends StatelessWidget {
  final _NavItem item;
  final bool selected;
  final VoidCallback onTap;
  const _NavTile(
      {required this.item, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final light = nikoIsLight(context);
    return Material(
      color: selected
          ? (light
              ? Colors.white
              : NikoPalette.darkSeed.withOpacity(.16))
          : Colors.transparent,
      borderRadius: BorderRadius.circular(NikoShapes.control),
      child: InkWell(
        borderRadius: BorderRadius.circular(NikoShapes.control),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          child: Row(children: [
            Icon(item.icon,
                size: 19,
                color: selected
                    ? (light ? NikoPalette.lightSeed : NikoPalette.darkSeed)
                    : theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 10),
            Text(item.label,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: selected
                      ? (light ? NikoPalette.lightSeed : NikoPalette.darkSeed)
                      : theme.colorScheme.onSurfaceVariant,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                )),
          ]),
        ),
      ),
    );
  }
}
