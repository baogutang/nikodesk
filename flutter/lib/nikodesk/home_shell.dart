import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/desktop/pages/desktop_setting_page.dart';
import 'package:flutter_hbb/models/platform_model.dart';

import 'device_page.dart';
import 'device_store.dart';
import 'server_scope.dart';
import 'home_settings.dart';
import 'nightline.dart';
import 'link_handler.dart';
import 'server_gateway.dart';
import 'session_history.dart';
import 'session_log.dart';
import 'ui.dart';
import 'voice_cleanup_panel.dart';
import 'tunnel_cleanup_view.dart';
import 'install_assistant.dart';
import 'first_server_setup.dart';
import 'diagnostics_bundle.dart';

/// Product shell for the NikoDesk home window: navigation plus the device
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

enum _HomeDestination { devices, sessions, settings, advanced }

class _NikoHomeShellState extends State<NikoHomeShell>
    with SingleTickerProviderStateMixin {
  DeviceStore get _store => widget.store ?? DeviceStore.instance;
  late final _gateway = widget.gateway ?? NativeServerGateway();
  _HomeDestination _destination = _HomeDestination.devices;
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  ServerSnapshot? _server;
  String? _temporaryPassword;
  bool _showPassword = false;
  bool _canScreen = true;
  bool _canAccessibility = true;
  Timer? _timer;
  int _statusReadGeneration = 0;
  late final _enter =
      AnimationController(vsync: this, duration: NlMotion.slow, value: 1);

  bool get _native =>
      widget.gateway == null || widget.gateway is NativeServerGateway;

  @override
  void initState() {
    super.initState();
    NikoServerScope.changes.addListener(_scopeChanged);
    _refreshStatus();
    if (_native) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          NikoLinkInbox.attach(this, _handleLink);
          if (nikoInstallAssistantRequested()) showNikoInstallAssistant(context);
          nikoShowCrashNotice(context);
        }
      });
    }
    _timer =
        Timer.periodic(const Duration(seconds: 3), (_) => _refreshStatus());
  }

  @override
  void dispose() {
    NikoServerScope.changes.removeListener(_scopeChanged);
    _timer?.cancel();
    _enter.dispose();
    NikoLinkInbox.detach(this);
    super.dispose();
  }

  void _scopeChanged() {
    if (mounted && widget.store == null) setState(() {});
  }

  Future<void> _setLanguage() async {
    setState(() => NikoLanguage.english = !NikoLanguage.english);
    if (!_native) return;
    final language = NikoLanguage.english ? 'en' : 'zh-cn';
    await bind.mainSetLocalOption(key: 'lang', value: language);
    await bind.mainChangeLanguage(lang: language);
  }

  Future<void> _refreshStatus() async {
    final generation = ++_statusReadGeneration;
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
    if (!mounted || generation != _statusReadGeneration) return;
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
                    Text(nikoText('知道本机 ID 和有效密码的人可以直接连入，不需要在本机确认。请使用本产品专用密码；要求每次点击确认可在高级设置的安全页里选择。',
                        'Anyone with this ID and a valid password connects without confirmation here. Use a unique password; to require a click every time, choose it under Security in advanced settings.')),
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
                        title: Text(nikoText('同时允许使用永久密码连接',
                            'Also allow connecting with this password'))),
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
                ? nikoText('密码已保存。输入正确密码即可连接，无需在本机确认；应用未运行时的后台访问需另行开启。',
                    'Password saved. A correct password connects without confirmation on this computer; access while the app is not running needs separate setup.')
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
    final shell = nightlineTheme(brightness);
    return Theme(
        data: shell,
        child: NikoFirstServerSetup(
          gateway: _gateway,
          onLanguageChanged: _setLanguage,
          onSaved: () {
            _go(_HomeDestination.devices);
            _refreshStatus();
          },
          child: LayoutBuilder(builder: (context, constraints) {
          final nl = NlColors.of(context);
          final compact = constraints.maxWidth < 840 ||
              constraints.maxWidth / MediaQuery.textScalerOf(context).scale(1) < 640;
          final pages = <_HomeDestination, Widget>{
            _HomeDestination.devices: NikoDevicePage(
                key: ValueKey('devices-${_store.directory.path}'),
                store: _store,
                gateway: _gateway,
                native: _native,
                active: _destination == _HomeDestination.devices,
                sessionLog: widget.sessionLog,
                onLanguageChanged: () => setState(() {}),
                onConnect: widget.onConnect,
                onOpenSettings: () => _go(_HomeDestination.settings)),
            _HomeDestination.sessions: NikoSessionHistoryPage(
                key: ValueKey(
                    'history-${widget.sessionLog?.directory.path ?? SessionLogStore.instance.directory.path}'),
                store: widget.sessionLog,
                gateway: _gateway,
                active: _destination == _HomeDestination.sessions,
                onConnect: widget.onConnect),
            _HomeDestination.settings: NikoSettingsView(
                gateway: _gateway,
                native: _native,
                active: _destination == _HomeDestination.settings,
                onServerSaved: _refreshStatus,
                onLanguageChanged: () => setState(() {}),
                onOpenAdvanced: () => _go(_HomeDestination.advanced)),
            _HomeDestination.advanced: _advancedPage(shell),
          };
          final content = AnimatedBuilder(
              animation: _enter,
              child: IndexedStack(
                  index: pages.keys.toList().indexOf(_destination),
                  children: pages.entries.map((entry) => ExcludeFocus(
                      excluding: _destination != entry.key,
                      child: entry.value)).toList()),
              builder: (context, child) {
                final t = NlMotion.ease.transform(_enter.value);
                return Opacity(
                    key: const ValueKey('nikodesk-shell-page'),
                    opacity: t,
                    child: Transform.translate(
                        offset: Offset(12 * (1 - t), 0), child: child));
              });
          return ColoredBox(
            color: nl.bg,
            child: Scaffold(
                key: _scaffoldKey,
                backgroundColor: Colors.transparent,
                appBar: compact ? AppBar(
                    backgroundColor: nl.bg,
                    shape: Border(bottom: BorderSide(color: nl.line)),
                    title: const Text('NikoDesk'),
                    leading: IconButton(
                        tooltip: nikoText('打开导航', 'Open navigation'),
                        onPressed: () => _scaffoldKey.currentState?.openDrawer(),
                        icon: const Icon(Icons.menu_rounded))) : null,
                drawer: compact ? Drawer(width: 320, child: _drawer(nl)) : null,
                body: compact
                    ? content
                    : Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _rail(nl),
                          Expanded(
                              child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.stretch,
                                  children: [
                                _topBar(nl),
                                Expanded(
                                    child: Row(
                                        crossAxisAlignment: CrossAxisAlignment.stretch,
                                        children: [
                                      Expanded(child: content),
                                      Container(
                                          width: constraints.maxWidth >= 1360 ? 332 : 288,
                                          decoration: BoxDecoration(
                                              color: nl.bg2,
                                              border: Border(
                                                  left: BorderSide(color: nl.line))),
                                          child: _inspector(nl)),
                                    ])),
                              ])),
                        ])));
        })));
  }

  /// Every destination change goes through here so pages enter with the same
  /// short slide; reduced motion switches instantly.
  void _go(_HomeDestination destination) {
    if (destination == _destination) return;
    setState(() => _destination = destination);
    if (NlMotion.reduced(context)) {
      _enter.value = 1;
    } else {
      _enter.forward(from: 0);
    }
  }

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

  List<_NavItem> get _navItems => [
        _NavItem(_HomeDestination.devices, Icons.devices_rounded,
            nikoText('设备', 'Devices'), 'Devices'),
        _NavItem(_HomeDestination.sessions, Icons.history_rounded,
            nikoText('会话', 'Sessions'), 'Sessions'),
        _NavItem(_HomeDestination.settings, Icons.tune_rounded,
            nikoText('设置', 'Settings'), 'Settings'),
        _NavItem(_HomeDestination.advanced, Icons.settings_suggest_rounded,
            nikoText('高级设置', 'Advanced'), 'Advanced'),
      ];

  _ServerState get _serverState {
    final server = _server;
    if (server == null) return _ServerState.unknown;
    if (!server.config.isValid) return _ServerState.unconfigured;
    if (!server.enabled) return _ServerState.paused;
    return switch (server.registrationStatus) {
      1 => _ServerState.ready,
      0 => _ServerState.registering,
      _ => _ServerState.notReady,
    };
  }

  String _serverStatusText(_ServerState state) => switch (state) {
        _ServerState.unknown => nikoText('状态未知', 'Status unknown'),
        _ServerState.unconfigured => nikoText('未配置', 'Not configured'),
        _ServerState.paused => nikoText('已暂停', 'Paused'),
        _ServerState.ready => nikoText('已就绪', 'Ready'),
        _ServerState.registering => nikoText('注册中', 'Registering'),
        _ServerState.notReady => nikoText('注册未就绪', 'Registration not ready'),
      };

  NlLedState _serverLed(_ServerState state) => switch (state) {
        _ServerState.unknown => NlLedState.off,
        _ServerState.ready => NlLedState.ok,
        _ => NlLedState.warn,
      };

  String get _serverHostText {
    final host = _server?.config.idServer ?? '';
    return _server == null
        ? nikoText('配置状态未知', 'Configuration status unknown')
        : host.isEmpty
            ? nikoText('未配置', 'Not configured')
            : host;
  }

  Widget _rail(NlColors nl) {
    final state = _serverState;
    return Container(
        width: 76,
        decoration: BoxDecoration(
            color: nl.bg2, border: Border(right: BorderSide(color: nl.line))),
        child: SafeArea(
            right: false,
            child: Column(children: [
              const SizedBox(height: NlSpace.s4),
              const NlMark(),
              const SizedBox(height: NlSpace.s5),
              for (final item in _navItems)
                Padding(
                    padding: const EdgeInsets.only(bottom: NlSpace.s1),
                    child: _NavButton(
                        item: item,
                        selected: _destination == item.destination,
                        onTap: () => _go(item.destination))),
              const Spacer(),
              Tooltip(
                  message:
                      '${nikoText('私有服务器', 'Private server')} · ${_serverStatusText(state)}',
                  child: Semantics(
                      button: true,
                      child: InkWell(
                          borderRadius: BorderRadius.circular(NlRadius.r2),
                          onTap: () => _go(_HomeDestination.settings),
                          child: Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: NlSpace.s2, vertical: NlSpace.s2),
                              child: Column(children: [
                                NlLed(_serverLed(state)),
                                const SizedBox(height: NlSpace.s1),
                                ExcludeSemantics(
                                    child: Text(
                                        switch (state) {
                                          _ServerState.unknown => '—',
                                          _ServerState.unconfigured => 'SETUP',
                                          _ServerState.paused => 'PAUSED',
                                          _ServerState.ready => 'READY',
                                          _ServerState.registering => 'REG',
                                          _ServerState.notReady => 'WAIT',
                                        },
                                        style: NlType.monoText(NlType.s1,
                                            color: nl.fg2))),
                              ]))))),
              const SizedBox(height: NlSpace.s3),
            ])));
  }

  Widget _topBar(NlColors nl) {
    final item =
        _navItems.firstWhere((item) => item.destination == _destination);
    final state = _serverState;
    return Container(
        height: 56,
        padding: const EdgeInsets.fromLTRB(NlSpace.s6, 0, NlSpace.s4, 0),
        decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: nl.line))),
        child: Row(children: [
          Text('NikoDesk',
              style: NlType.text(NlType.s5, weight: FontWeight.w600, color: nl.fg)),
          Padding(
              padding: const EdgeInsets.symmetric(horizontal: NlSpace.s3),
              child: Text('/', style: NlType.monoText(NlType.s3, color: nl.line2))),
          NlMonoLabel(item.code),
          const Spacer(),
          Semantics(
              button: true,
              label: nikoText('私有服务器', 'Private server'),
              child: Material(
                  type: MaterialType.transparency,
                  child: InkWell(
                      borderRadius: BorderRadius.circular(NlRadius.pill),
                      onTap: () => _go(_HomeDestination.settings),
                      child: Container(
                          height: 30,
                          constraints: const BoxConstraints(maxWidth: 320),
                          padding:
                              const EdgeInsets.symmetric(horizontal: NlSpace.s3),
                          decoration: BoxDecoration(
                              color: nl.surface,
                              borderRadius: BorderRadius.circular(NlRadius.pill),
                              border: Border.all(color: nl.ring)),
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            NlLed(_serverLed(state)),
                            const SizedBox(width: NlSpace.s2),
                            const NlMonoLabel('Private'),
                            const SizedBox(width: NlSpace.s2),
                            Flexible(
                                child: Text(_serverHostText,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: NlType.monoText(NlType.s1,
                                        color: state == _ServerState.ready
                                            ? nl.fg2
                                            : nl.warnText))),
                          ]))))),
        ]));
  }

  Widget _drawer(NlColors nl) => SafeArea(
      child: ListView(
          padding: const EdgeInsets.all(NlSpace.s3),
          children: [
            const Padding(
                padding: EdgeInsets.fromLTRB(
                    NlSpace.s2, NlSpace.s2, NlSpace.s2, NlSpace.s4),
                child: Align(
                    alignment: Alignment.centerLeft,
                    child: NlMark(size: 28))),
            for (final item in _navItems)
              Padding(
                  padding: const EdgeInsets.only(bottom: NlSpace.s1),
                  child: _NavButton(
                      item: item,
                      horizontal: true,
                      selected: _destination == item.destination,
                      onTap: () {
                        _go(item.destination);
                        _scaffoldKey.currentState?.closeDrawer();
                      })),
            Padding(
                padding: const EdgeInsets.symmetric(vertical: NlSpace.s3),
                child: Divider(color: nl.line)),
            _inspectorBody(nl, showHost: true),
          ]));

  Widget _inspector(NlColors nl) => SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(
          NlSpace.s5, NlSpace.s5, NlSpace.s5, NlSpace.s4),
      child: _inspectorBody(nl, showHost: false));

  /// Local identity, health and server state. The drawer shows the server
  /// host here because the compact layout has no top bar.
  Widget _inspectorBody(NlColors nl, {required bool showHost}) {
    final id = _deviceId;
    final raw = _temporaryPassword ?? '';
    final password = raw.isEmpty
        ? null
        : (_showPassword ? raw : '•' * raw.length.clamp(4, 10));
    final state = _serverState;
    final health = <Widget>[
      NlListRow(
          dense: true,
          divider: false,
          leading: NlLed(_serverLed(state)),
          title: nikoText('私有服务器', 'Private server'),
          subtitle: showHost ? _serverHostText : null,
          trailing: Text(_serverStatusText(state),
              style: NlType.text(NlType.s2,
                  color: state == _ServerState.ready ? nl.okText : nl.warnText)),
          onTap: () {
            _go(_HomeDestination.settings);
            _scaffoldKey.currentState?.closeDrawer();
          }),
      if (Platform.isMacOS) ...[
        _permissionRow(nl, nikoText('屏幕录制', 'Screen recording'),
            nikoText('被控画面必需', 'Required to be controlled'), _canScreen,
            _requestScreenRecording),
        _permissionRow(nl, nikoText('辅助功能', 'Accessibility'),
            nikoText('远端键鼠必需', 'Required for remote input'),
            _canAccessibility, _requestAccessibility),
      ],
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      NlMonoLabel(nikoText('本机', 'This computer')),
      const SizedBox(height: NlSpace.s3),
      NlPanel(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const NlMonoLabel('ID'),
        const SizedBox(height: NlSpace.s1),
        Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          Expanded(
              child: Text(id.isEmpty ? '—' : id,
                  style: NlType.monoText(NlType.s7,
                      weight: FontWeight.w500,
                      color: nl.fg).copyWith(
                    shadows: nl.isDark
                        ? const [Shadow(color: Color(0x402FD8EE), blurRadius: 15)]
                        : null))),
          const SizedBox(width: NlSpace.s2),
          NlIconButton(
              icon: Icons.copy_rounded,
              tooltip: nikoText('复制本机设备 ID', 'Copy local device ID'),
              onPressed: id.isEmpty
                  ? null
                  : () => _copy(id, nikoText('设备 ID', 'device ID'))),
        ]),
      ])),
      const SizedBox(height: NlSpace.s4),
      NlMonoLabel(nikoText('临时密码', 'One-time password')),
      const SizedBox(height: NlSpace.s1),
      Row(children: [
        Expanded(
            child: Text(
                password ?? nikoText('未设置临时密码', 'No temporary password'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: password == null
                    ? NlType.text(NlType.s3, color: nl.fg3)
                    : NlType.monoText(NlType.s6,
                            weight: FontWeight.w500, color: nl.fg)
                        .copyWith(letterSpacing: NlType.s6 * .14))),
        if (password != null) ...[
          NlIconButton(
              icon: _showPassword
                  ? Icons.visibility_off_rounded
                  : Icons.visibility_rounded,
              tooltip: _showPassword
                  ? nikoText('隐藏临时密码', 'Hide temporary password')
                  : nikoText('显示临时密码', 'Show temporary password'),
              onPressed: () => setState(() => _showPassword = !_showPassword)),
          NlIconButton(
              icon: Icons.copy_rounded,
              tooltip: nikoText('复制临时密码', 'Copy temporary password'),
              onPressed: () => _copy(raw, nikoText('密码', 'password'))),
        ],
      ]),
      const SizedBox(height: NlSpace.s2),
      Align(
          alignment: Alignment.centerLeft,
          child: NlButton.ghost(
              small: true,
              icon: Icons.key_rounded,
              onPressed: _setPermanentPassword,
              label: nikoText('设置永久密码', 'Set permanent password'))),
      const SizedBox(height: NlSpace.s6),
      NlMonoLabel(nikoText('自检', 'Health')),
      const SizedBox(height: NlSpace.s1),
      ...health,
      if (_native) const NikoVoiceCleanupEntryPoint(),
      if (_native) const NikoTunnelCleanupEntryPoint(),
      const SizedBox(height: NlSpace.s6),
      Text(nikoText('私有服务器 · 端到端加密', 'Private server · End-to-end encrypted'),
          textAlign: TextAlign.center,
          style: NlType.text(NlType.s1, color: nl.fg3)),
    ]);
  }

  Widget _permissionRow(NlColors nl, String title, String reason, bool granted,
          Future<void> Function() request) =>
      NlListRow(
          dense: true,
          leading: NlLed(granted ? NlLedState.ok : NlLedState.warn),
          title: title,
          subtitle: granted ? null : reason,
          trailing: granted
              ? Text('OK', style: NlType.monoText(NlType.s1, color: nl.fg2))
              : NlButton.ghost(
                  small: true,
                  onPressed: request,
                  label: nikoText('授权', 'Grant')));
}

enum _ServerState { unknown, unconfigured, paused, ready, registering, notReady }

class _NavItem {
  final _HomeDestination destination;
  final IconData icon;
  final String label;

  /// English section code for the mono breadcrumb in the top bar.
  final String code;
  const _NavItem(this.destination, this.icon, this.label, this.code);
}

/// Rail button (icon over label) or, in the compact drawer, a row.
class _NavButton extends StatefulWidget {
  final _NavItem item;
  final bool selected;
  final bool horizontal;
  final VoidCallback onTap;
  const _NavButton(
      {required this.item,
      required this.selected,
      required this.onTap,
      this.horizontal = false});

  @override
  State<_NavButton> createState() => _NavButtonState();
}

class _NavButtonState extends State<_NavButton> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final nl = NlColors.of(context);
    final selected = widget.selected;
    final ink = selected || _hovered ? nl.fg : nl.fg3;
    final glow = nl.glow.first;
    final icon = Icon(widget.item.icon,
        size: widget.horizontal ? 18 : 20,
        color: selected ? nl.accentText : ink,
        shadows: selected
            ? [Shadow(color: glow.color, blurRadius: glow.blurRadius)]
            : null);
    final label = Text(widget.item.label,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        textAlign: widget.horizontal ? TextAlign.start : TextAlign.center,
        style: NlType.text(widget.horizontal ? NlType.s3 : NlType.s1,
            weight: FontWeight.w500, color: ink));
    return Semantics(
        button: true,
        selected: selected,
        child: Material(
            type: MaterialType.transparency,
            child: InkWell(
                onTap: widget.onTap,
                borderRadius: BorderRadius.circular(NlRadius.r2),
                splashFactory: NoSplash.splashFactory,
                overlayColor: const WidgetStatePropertyAll(Colors.transparent),
                onHover: (value) => setState(() => _hovered = value),
                onFocusChange: (value) => setState(() => _focused = value),
                child: Stack(clipBehavior: Clip.none, children: [
                  AnimatedContainer(
                      duration: NlMotion.of(context, NlMotion.fast),
                      curve: NlMotion.ease,
                      width: widget.horizontal ? null : 60,
                      constraints: BoxConstraints(
                          minHeight: widget.horizontal ? 40 : 56),
                      padding: widget.horizontal
                          ? const EdgeInsets.symmetric(horizontal: NlSpace.s3)
                          : const EdgeInsets.symmetric(vertical: NlSpace.s2),
                      decoration: BoxDecoration(
                          color: selected
                              ? (widget.horizontal ? nl.surface : nl.surface2)
                              : _hovered
                                  ? nl.surface
                                  : Colors.transparent,
                          borderRadius: BorderRadius.circular(NlRadius.r2),
                          border: selected && widget.horizontal
                              ? Border.all(color: nl.ring)
                              : null,
                          boxShadow: _focused ? nl.focusRing : null),
                      child: widget.horizontal
                          ? Row(children: [
                              icon,
                              const SizedBox(width: NlSpace.s3),
                              Expanded(child: label),
                            ])
                          : Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                  icon,
                                  const SizedBox(height: NlSpace.s1),
                                  label,
                                ])),
                  if (selected)
                    Positioned(
                        left: widget.horizontal ? -12 : -8,
                        top: 12,
                        bottom: 12,
                        child: Container(
                            width: 3,
                            decoration: BoxDecoration(
                                color: nl.accent,
                                borderRadius: const BorderRadius.horizontal(
                                    right: Radius.circular(3)),
                                boxShadow: nl.glow))),
                ]))));
  }
}
