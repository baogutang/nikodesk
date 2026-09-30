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
import 'server_scope.dart';
import 'home_settings.dart';
import 'link_handler.dart';
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
  DeviceStore get _store => widget.store ?? DeviceStore.instance;
  late final _gateway = widget.gateway ?? NativeServerGateway();
  int _index = 0;
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  ServerSnapshot? _server;
  String? _temporaryPassword;
  bool _showPassword = false;
  bool _canScreen = true;
  bool _canAccessibility = true;
  Timer? _timer;

  bool get _native =>
      widget.gateway == null || widget.gateway is NativeServerGateway;

  @override
  void initState() {
    super.initState();
    NikoServerScope.changes.addListener(_scopeChanged);
    _refreshStatus();
    if (_native) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) NikoLinkInbox.attach(this, _handleLink);
      });
    }
    _timer =
        Timer.periodic(const Duration(seconds: 3), (_) => _refreshStatus());
  }

  @override
  void dispose() {
    NikoServerScope.changes.removeListener(_scopeChanged);
    _timer?.cancel();
    NikoLinkInbox.detach(this);
    super.dispose();
  }

  void _scopeChanged() {
    if (mounted && widget.store == null) setState(() {});
  }

  Future<void> _refreshStatus() async {
    bool canScreen = !Platform.isMacOS;
    bool canAccessibility = !Platform.isMacOS;
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
      _canScreen = canScreen;
      _canAccessibility = canAccessibility;
      _temporaryPassword = password;
      _server = server;
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

  Future<void> _handleLink(NikoLinkRequest request) async {
    await windowOnTop(null);
    if (mounted) await dispatchNikoLink(context, request, gateway: _gateway);
  }

  Future<void> _setPermanentPassword() async {
    if (!_native) return;
    final controller = TextEditingController();
    var enableAuthentication = false;
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialog) => StatefulBuilder(
            builder: (dialog, update) => AlertDialog(
                  title: Text(nikoText('设置永久密码', 'Set permanent password')),
                  content: Column(mainAxisSize: MainAxisSize.min, children: [
                    Text(nikoText('保存密码与启用永久密码认证是两步；这不会开启无人值守。请使用本产品专用密码。',
                        'Saving and enabling password authentication are separate. This does not enable unattended access. Use a unique password.')),
                    const SizedBox(height: 12),
                    TextField(
                        controller: controller,
                        autofocus: true,
                        obscureText: true,
                        autocorrect: false,
                        enableSuggestions: false,
                        enableIMEPersonalizedLearning: false,
                        key: const Key('nikodesk-permanent-password'),
                        decoration: nikoInput(nikoText('新密码', 'New password'))),
                    CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        value: enableAuthentication,
                        onChanged: (value) =>
                            update(() => enableAuthentication = value == true),
                        title: Text(nikoText('同时允许使用永久密码（接受规则另行设置）',
                            'Also allow this password (acceptance is configured separately)'))),
                  ]),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(dialog, false),
                        child: Text(nikoText('取消', 'Cancel'))),
                    FilledButton(
                        onPressed: () => Navigator.pop(dialog, true),
                        child: Text(nikoText('保存', 'Save'))),
                  ],
                )));
    if (confirmed != true || controller.text.isEmpty) {
      controller.clear();
      return;
    }
    try {
      PasswordSetupResult? result;
      if (_native) {
        result = await NativePasswordGateway()
            .save(controller.text, enableAuthentication: enableAuthentication);
      }
      if (mounted) {
        nikoNotice(
            context,
            result?.enabled == true
                ? nikoText('密码已保存，可用于密码验证；当前接受规则未更改。无人值守需另行配置。',
                    'Password saved and available for authentication. Acceptance rules are unchanged; unattended access needs separate setup.')
                : result?.clickOnly == true && result?.permanentSelected == true
                    ? nikoText(
                        '密码已保存并加入可用密码；本机仍采用点击授权，密码认证尚未生效。请在高级安全设置中核对接受规则。',
                        'Password saved and selected. This computer still uses click approval, so password authentication is inactive. Check acceptance rules in advanced security settings.')
                    : nikoText('密码已保存；永久密码验证未启用。请在高级安全设置中核对验证方式和接受规则。',
                        'Password saved; permanent-password authentication is disabled. Check verification and acceptance rules in advanced security settings.'));
      }
    } catch (_) {
      if (mounted) {
        nikoNotice(
            context,
            nikoText('设置未完成，无法确认密码或认证状态；请在高级安全设置中核对。',
                'Setup did not complete. Check the password and authentication state in advanced security settings.'));
      }
    } finally {
      controller.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final shell = nikoTheme(brightness);
    final light = brightness == Brightness.light;
    return Theme(
        data: shell,
        child: LayoutBuilder(builder: (context, constraints) {
          final compact = constraints.maxWidth < 840 ||
              constraints.maxWidth / MediaQuery.textScalerOf(context).scale(1) < 640;
          return DecoratedBox(
            decoration: BoxDecoration(
                gradient: light ? NikoPalette.lightCanvas : null,
                color: light ? null : NikoPalette.darkScaffold),
            child: Scaffold(
                key: _scaffoldKey,
                backgroundColor: Colors.transparent,
                appBar: compact ? AppBar(
                    backgroundColor: Colors.transparent,
                    title: const Text('NikoDesk'),
                    leading: IconButton(
                        tooltip: nikoText('打开导航', 'Open navigation'),
                        onPressed: () => _scaffoldKey.currentState?.openDrawer(),
                        icon: const Icon(Icons.menu_rounded))) : null,
                drawer: compact ? Drawer(child: _sidebar(shell, light, width: 320)) : null,
                body: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (!compact) _sidebar(shell, light),
                      if (!compact) VerticalDivider(
                          width: 1,
                          thickness: 1,
                          color: light
                              ? Colors.white.withOpacity(.7)
                              : NikoPalette.darkLine),
                      Expanded(
                          child: IndexedStack(index: _index, children: [
                        NikoDevicePage(
                            key: ValueKey('devices-${_store.directory.path}'),
                            store: _store,
                            gateway: _gateway,
                            native: _native,
                            active: _index == 0,
                            sessionLog: widget.sessionLog,
                            onLanguageChanged: () => setState(() {}),
                            onConnect: widget.onConnect,
                            onOpenSettings: () =>
                                setState(() => _index = _settingsIndex)),
                        NikoSessionHistoryPage(
                            key: ValueKey(
                                'history-${widget.sessionLog?.directory.path ?? SessionLogStore.instance.directory.path}'),
                            store: widget.sessionLog,
                            gateway: _gateway,
                            active: _index == 1,
                            onConnect: widget.onConnect),
                        NikoSettingsView(
                            gateway: _gateway,
                            native: _native,
                            active: _index == _settingsIndex,
                            onServerSaved: _refreshStatus,
                            onLanguageChanged: () => setState(() {}),
                            onOpenAdvanced: () =>
                                setState(() => _index = _advancedIndex)),
                        _advancedPage(shell),
                      ].asMap().entries.map((entry) => ExcludeFocus(
                          excluding: _index != entry.key, child: entry.value)).toList())),
                    ])));
        }));
  }

  static const _settingsIndex = 2;
  static const _advancedIndex = 3;

  /// The full upstream settings page, hosted inside the shell instead of a
  /// legacy tab. Widget tests inject a gateway and never build it because
  /// the upstream page reads native options while constructing.
  Widget _advancedPage(ThemeData shell) {
    if (!_native) {
      return Center(
          child: Text(
              nikoText('高级设置仅在应用内提供。', 'Advanced settings are app-only.'),
              style: TextStyle(color: shell.colorScheme.onSurfaceVariant)));
    }
    return Padding(
        padding: const EdgeInsets.all(12),
        child: DesktopSettingPage(initialTabkey: SettingsTabKey.general));
  }

  Widget _sidebar(ThemeData shell, bool light, {double width = 236}) {
    final serverOk =
        _server?.config.isValid == true && _server?.enabled == true;
    final registered = serverOk && _server?.registrationStatus == 1;
    final nav = [
      _NavItem(Icons.devices_rounded, nikoText('设备', 'Devices')),
      _NavItem(Icons.history_rounded, nikoText('会话', 'Sessions')),
      _NavItem(Icons.tune_rounded, nikoText('设置', 'Settings')),
      _NavItem(Icons.settings_suggest_rounded, nikoText('高级设置', 'Advanced')),
    ];
    final panel = Container(
        width: width,
        color: light ? null : NikoPalette.darkSidebar,
        child: SafeArea(
            child: SingleChildScrollView(child: Column(
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
                        onTap: () {
                          setState(() => _index = i);
                          _scaffoldKey.currentState?.closeDrawer();
                        })),
              const Divider(indent: 16, endIndent: 16),
              Padding(
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
                          ])),
              Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                      nikoText('私有服务器 · 端到端加密',
                          'Private server · End-to-end encrypted'),
                      textAlign: TextAlign.center,
                      style: shell.textTheme.bodySmall?.copyWith(
                          color: shell.colorScheme.onSurfaceVariant))),
            ]))));
    if (!light) return panel;
    return ClipRect(
        child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
            child: Container(
                width: width,
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
            Expanded(
                child: Text(nikoText('本机', 'This computer'),
                    style: shell.textTheme.labelMedium
                        ?.copyWith(color: shell.colorScheme.onSurfaceVariant))),
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
              IconButton(
                  tooltip: nikoText('复制本机设备 ID', 'Copy local device ID'),
                  onPressed: id.isEmpty ? null : () => _copy(id, nikoText('设备 ID', 'device ID')),
                  icon: Icon(Icons.copy_rounded, size: 15, color: shell.colorScheme.primary)),
            ]);
          }),
          const SizedBox(height: 10),
          Builder(builder: (_) {
            final raw = _temporaryPassword ?? '';
            final password = raw.isEmpty
                ? null
                : (_showPassword ? raw : '•' * raw.length.clamp(4, 10));
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
                IconButton(
                    tooltip: _showPassword ? nikoText('隐藏临时密码', 'Hide temporary password') : nikoText('显示临时密码', 'Show temporary password'),
                    onPressed: () => setState(() => _showPassword = !_showPassword),
                    icon: Icon(_showPassword ? Icons.visibility_off_rounded : Icons.visibility_rounded,
                        size: 14, color: shell.colorScheme.onSurfaceVariant)),
                IconButton(
                    tooltip: nikoText('复制临时密码', 'Copy temporary password'),
                    onPressed: () => _copy(raw, nikoText('密码', 'password')),
                    icon: Icon(Icons.copy_rounded, size: 14, color: shell.colorScheme.primary)),
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
        child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
            child: Row(children: [
              const Icon(Icons.error_outline_rounded,
                  size: 16, color: NikoPalette.warning),
              const SizedBox(width: 8),
              Expanded(child: Text(label, style: shell.textTheme.bodySmall)),
              Icon(Icons.chevron_right_rounded,
                  size: 16, color: shell.colorScheme.onSurfaceVariant),
            ]))));
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
                ?.copyWith(color: shell.brightness == Brightness.light ? NikoPalette.lightWarningText : NikoPalette.warning)),
        if (!_canScreen)
          row(
              nikoText('屏幕录制（被控画面必需）',
                  'Screen recording (required to be controlled)'),
              _requestScreenRecording),
        if (!_canAccessibility)
          row(
              nikoText(
                  '辅助功能（远端键鼠必需）', 'Accessibility (required for remote input)'),
              _requestAccessibility),
      ]),
    );
  }

  Widget _serverCard(ThemeData shell, bool serverOk, bool registered) {
    final host = _server?.config.idServer ?? '';
    final status = _server == null
        ? nikoText('状态未知', 'Status unknown')
        : !_server!.config.isValid
            ? nikoText('未配置', 'Not configured')
            : !_server!.enabled
                ? nikoText('已暂停', 'Paused')
                : registered
                    ? nikoText('已就绪', 'Ready')
                    : _server!.registrationStatus == 0
                        ? nikoText('注册中', 'Registering')
                        : nikoText('注册未就绪', 'Registration not ready');
    return InkWell(
      customBorder: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(NikoShapes.card)),
      onTap: () => setState(() => _index = _settingsIndex),
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
                    style: shell.textTheme.labelMedium
                        ?.copyWith(color: shell.colorScheme.onSurfaceVariant)),
                const SizedBox(height: 2),
                Text(host.isEmpty ? nikoText('未配置', 'Not configured') : host,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: shell.textTheme.bodySmall),
              ])),
          Flexible(
              child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color:
                        (registered ? NikoPalette.success : NikoPalette.warning)
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
                    Flexible(
                        child: Text(status,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: shell.textTheme.labelSmall?.copyWith(
                                color: registered
                                    ? (shell.brightness == Brightness.light ? NikoPalette.lightSuccessText : NikoPalette.success)
                                    : (shell.brightness == Brightness.light ? NikoPalette.lightWarningText : NikoPalette.warning)))),
                  ]))),
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
    return Semantics(button: true, selected: selected, child: Material(
      color: selected
          ? (light ? Colors.white : NikoPalette.darkSeed.withOpacity(.16))
          : Colors.transparent,
      borderRadius: BorderRadius.circular(NikoShapes.control),
      child: InkWell(
        borderRadius: BorderRadius.circular(NikoShapes.control),
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          child: Row(children: [
            Icon(item.icon,
                size: 19,
                color: selected
                    ? (light ? NikoPalette.lightSeed : NikoPalette.darkSeed)
                    : theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 10),
            Expanded(child: Text(item.label,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: selected
                      ? (light ? NikoPalette.lightSeed : NikoPalette.darkSeed)
                      : theme.colorScheme.onSurfaceVariant,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ))),
          ]),
        )),
      ),
    ));
  }
}
