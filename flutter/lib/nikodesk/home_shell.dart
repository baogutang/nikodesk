import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/desktop/pages/desktop_setting_page.dart';
import 'package:flutter_hbb/models/platform_model.dart';

import 'device_page.dart';
import 'device_store.dart';
import 'home_board.dart';
import 'home_chrome.dart';
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
import 'permission_guide.dart';
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

  /// Draws the page headers as the macOS title bar. Defaults to the native
  /// macOS app; screenshots set it explicitly.
  final bool? macTitleBar;

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
      this.accessibilityRequest,
      this.macTitleBar});

  @override
  State<NikoHomeShell> createState() => _NikoHomeShellState();
}

enum _HomeDestination { devices, sessions, settings, advanced }

class _NikoHomeShellState extends State<NikoHomeShell>
    with SingleTickerProviderStateMixin {
  DeviceStore get _store => widget.store ?? DeviceStore.instance;
  late final _gateway = widget.gateway ?? NativeServerGateway();
  _HomeDestination _destination = _HomeDestination.devices;
  final _board = NikoDeviceBoard();
  ServerSnapshot? _server;
  String? _temporaryPassword;
  bool _showPassword = false;
  bool _canScreen = true;
  bool _canAccessibility = true;

  /// Decided at the first status read; the health rows open it again.
  bool? _guide;
  Timer? _timer;
  int _statusReadGeneration = 0;
  late final _enter =
      AnimationController(vsync: this, duration: NlMotion.slow, value: 1);

  bool get _native =>
      widget.gateway == null || widget.gateway is NativeServerGateway;

  // The tab bar above steps aside on macOS (nikoHomeDrawsTitleBar), so every
  // page here keeps the traffic lights clear and the window draggable.
  bool get _macTitleBar => widget.macTitleBar ?? (Platform.isMacOS && _native);

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
    _board.dispose();
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
      _guide ??= Platform.isMacOS &&
          (_native || widget.screenRecordingProbe != null) &&
          !(canScreen && canAccessibility) &&
          !_guideSilenced;
    });
  }

  bool get _guideSilenced {
    if (!_native) return false;
    try {
      return bind.mainGetLocalOption(key: nikoPermissionGuideOption) == 'off';
    } catch (_) {
      return false;
    }
  }

  void _leaveGuide({bool silence = false}) {
    if (silence && _native) {
      bind.mainSetLocalOption(key: nikoPermissionGuideOption, value: 'off');
    }
    setState(() => _guide = false);
    _refreshStatus();
  }

  Widget _permissionGuide() => NikoPermissionGuide(
      screenRecording: () =>
          widget.screenRecordingProbe?.call() ??
          (_native && bind.mainIsCanScreenRecording(prompt: false)),
      accessibility: () =>
          widget.accessibilityProbe?.call() ??
          (_native && bind.mainIsProcessTrusted(prompt: false)),
      requestScreenRecording: _requestScreenRecording,
      requestAccessibility: _requestAccessibility,
      onContinue: _leaveGuide,
      onSilence: () => _leaveGuide(silence: true));

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

  // Asking first puts NikoDesk in the list; the system shows its own prompt
  // only once, so the pane is opened as well.
  Future<void> _requestScreenRecording() async {
    if (widget.screenRecordingRequest != null) {
      widget.screenRecordingRequest!(true);
    } else if (_native) {
      bind.mainIsCanScreenRecording(prompt: true);
      await nikoOpenPrivacyPane(nikoScreenRecordingPane);
    }
    await _refreshStatus();
  }

  Future<void> _requestAccessibility() async {
    if (widget.accessibilityRequest != null) {
      widget.accessibilityRequest!(true);
    } else if (_native) {
      bind.mainIsProcessTrusted(prompt: true);
      await nikoOpenPrivacyPane(nikoAccessibilityPane);
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
        child: Material(
            type: MaterialType.transparency,
            child: NikoFirstServerSetup(
                gateway: _gateway,
                macTitleBar: _macTitleBar,
                onLanguageChanged: _setLanguage,
                onSaved: () {
                  _go(_HomeDestination.devices);
                  _refreshStatus();
                },
                child: _guide == true
                    ? NikoTitleStrip(
                        enabled: _macTitleBar, child: _permissionGuide())
                    : Builder(builder: (context) => _home(context, shell)))));
  }

  Widget _home(BuildContext context, ThemeData shell) {
    final nl = NlColors.of(context);
    final local = _localPanel(nl, heading: false);
    final pages = <_HomeDestination, Widget>{
      _HomeDestination.devices: NikoDevicePage(
          key: ValueKey('devices-${_store.directory.path}'),
          store: _store,
          gateway: _gateway,
          native: _native,
          active: _destination == _HomeDestination.devices,
          sessionLog: widget.sessionLog,
          board: _board,
          localPanel: local,
          onLanguageChanged: () => setState(() {}),
          onConnect: widget.onConnect,
          onOpenSettings: () => _openSettings(NikoSettingsSection.server)),
      _HomeDestination.sessions: NikoSessionHistoryPage(
          key: ValueKey(
              'history-${widget.sessionLog?.directory.path ?? SessionLogStore.instance.directory.path}'),
          store: widget.sessionLog,
          gateway: _gateway,
          active: _destination == _HomeDestination.sessions,
          onConnect: widget.onConnect),
      _HomeDestination.settings: NikoSettingsView(
          gateway: _gateway,
          initialSection: _settingsSection,
          sectionRequest: _settingsRequest,
          native: _native,
          active: _destination == _HomeDestination.settings,
          onServerSaved: _refreshStatus,
          onLanguageChanged: () => setState(() {}),
          onAppearanceChanged: () => setState(() {}),
          onOpenAdvanced: () => _go(_HomeDestination.advanced)),
      _HomeDestination.advanced: _advancedPage(shell),
    };
    final content = AnimatedBuilder(
        animation: _enter,
        child: IndexedStack(
            index: pages.keys.toList().indexOf(_destination),
            children: pages.entries
                .map((entry) => ExcludeFocus(
                    excluding: _destination != entry.key, child: entry.value))
                .toList()),
        builder: (context, child) {
          final t = NlMotion.ease.transform(_enter.value);
          return Opacity(
              key: const ValueKey('nikodesk-shell-page'),
              opacity: t,
              child: Transform.translate(
                  offset: Offset(12 * (1 - t), 0), child: child));
        });
    return CallbackShortcuts(
        bindings: _shortcuts,
        child: Focus(
            autofocus: true,
            child: ListenableBuilder(
                listenable: _board,
                builder: (context, _) {
                  final grouped = _destination == _HomeDestination.devices &&
                      _board.filter.startsWith('group:');
                  return NikoHomeChrome(
                      destinations: [
                        for (final destination in _HomeDestination.values)
                          NikoHomeDestination(
                              icon: _icon(destination),
                              label: _label(destination),
                              count: destination == _HomeDestination.devices &&
                                      _board.devices.isNotEmpty
                                  ? '${_board.devices.length}'
                                  : null),
                      ],
                      selected: grouped
                          ? -1
                          : _HomeDestination.values.indexOf(_destination),
                      onSelect: (index) {
                        final destination = _HomeDestination.values[index];
                        if (destination == _HomeDestination.devices &&
                            _board.filter.startsWith('group:')) {
                          _board.filter = 'all';
                        }
                        _go(destination);
                      },
                      body: content,
                      sections: nikoBoardSections(context, _board,
                          devicesShown:
                              _destination == _HomeDestination.devices,
                          onDevices: _onDevices),
                      footer: _footer(nl),
                      drawerExtra: _localPanel(nl),
                      onQuickConnect: _quickConnect,
                      onSearch: _openPalette,
                      quickConnectShortcut: nikoShortcut('N'),
                      searchShortcut: nikoShortcut('K'),
                      macTitleBar: _macTitleBar);
                })));
  }

  /// Every destination change goes through here so pages enter with the same
  /// short slide; reduced motion switches instantly.
  NikoSettingsSection? _settingsSection;
  int _settingsRequest = 0;

  /// Opens settings on [section], wherever the settings page was left.
  void _openSettings(NikoSettingsSection section) {
    setState(() {
      _settingsSection = section;
      _settingsRequest++;
    });
    _go(_HomeDestination.settings);
  }

  void _go(_HomeDestination destination) {
    if (destination == _destination) return;
    setState(() => _destination = destination);
    if (NlMotion.reduced(context)) {
      _enter.value = 1;
    } else {
      _enter.forward(from: 0);
    }
  }

  /// Shows the device page, then hands it the request once its fields can
  /// take focus again.
  void _onDevices(bool Function() request) {
    _go(_HomeDestination.devices);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) request();
    });
  }

  void _quickConnect() => _onDevices(_board.requestQuickConnect);

  Map<ShortcutActivator, VoidCallback> get _shortcuts {
    final apple = Platform.isMacOS || Platform.isIOS;
    SingleActivator key(LogicalKeyboardKey key) =>
        SingleActivator(key, meta: apple, control: !apple);
    return {
      key(LogicalKeyboardKey.keyK): _openPalette,
      key(LogicalKeyboardKey.keyN): _quickConnect,
      key(LogicalKeyboardKey.keyF): () =>
          _onDevices(_board.requestFocusSearch),
      key(LogicalKeyboardKey.comma): () => _go(_HomeDestination.settings),
      key(LogicalKeyboardKey.digit1): () => _go(_HomeDestination.devices),
      key(LogicalKeyboardKey.digit2): () => _go(_HomeDestination.sessions),
      key(LogicalKeyboardKey.digit3): () => _go(_HomeDestination.settings),
    };
  }

  Future<void> _openPalette() async {
    final id = _deviceId;
    final commands = nikoDeviceCommands(_board, onDevices: _onDevices);
    final actions = nikoText('操作', 'Actions');
    await showNlCommandPalette(context,
        hint: nikoText('搜索设备、页面或命令', 'Search devices, pages or commands'),
        empty: nikoText('没有匹配的结果', 'No matches'),
        commands: [
          ...commands.take(2),
          if (id.isNotEmpty)
            NlCommand(
                title: nikoText('复制本机设备 ID', 'Copy local device ID'),
                subtitle: id,
                icon: NlIcons.copy,
                group: actions,
                run: () => _copy(id, nikoText('设备 ID', 'device ID'))),
          NlCommand(
              title: nikoText('设置永久密码', 'Set permanent password'),
              icon: NlIcons.keyRound,
              group: actions,
              run: _setPermanentPassword),
          for (final destination in _HomeDestination.values)
            NlCommand(
                title: _label(destination),
                icon: _icon(destination),
                group: nikoText('前往', 'Go to'),
                shortcut: switch (destination) {
                  _HomeDestination.devices => nikoShortcut('1'),
                  _HomeDestination.sessions => nikoShortcut('2'),
                  _HomeDestination.settings => nikoShortcut(','),
                  _HomeDestination.advanced => null,
                },
                run: () => _go(destination)),
          ...commands.skip(2),
        ]);
  }

  IconData _icon(_HomeDestination destination) => switch (destination) {
        _HomeDestination.devices => NlIcons.monitorSmartphone,
        _HomeDestination.sessions => NlIcons.history,
        _HomeDestination.settings => NlIcons.settings,
        _HomeDestination.advanced => NlIcons.slidersHorizontal,
      };

  String _label(_HomeDestination destination) => switch (destination) {
        _HomeDestination.devices => nikoText('设备', 'Devices'),
        _HomeDestination.sessions => nikoText('会话', 'Sessions'),
        _HomeDestination.settings => nikoText('设置', 'Settings'),
        _HomeDestination.advanced => nikoText('高级设置', 'Advanced'),
      };

  /// The private server at the foot of the sidebar; it opens settings.
  Widget _footer(NlColors nl) {
    final state = _serverState;
    final code = switch (state) {
      _ServerState.unknown => '—',
      _ServerState.unconfigured => 'SETUP',
      _ServerState.paused => 'PAUSED',
      _ServerState.ready => 'READY',
      _ServerState.registering => 'REG',
      _ServerState.notReady => 'WAIT',
    };
    return Padding(
        padding: const EdgeInsets.fromLTRB(
            NlSpace.s2, NlSpace.s1, NlSpace.s2, NlSpace.s3),
        child: Semantics(
            button: true,
            label:
                '${nikoText('私有服务器', 'Private server')} · ${_serverStatusText(state)}',
            excludeSemantics: true,
            child: NlPressable(
                onTap: () => _openSettings(NikoSettingsSection.server),
                pressScale: .99,
                builder: (context, states) => AnimatedContainer(
                    duration: NlMotion.of(context, NlMotion.instant),
                    padding: const EdgeInsets.symmetric(
                        horizontal: NlSpace.s3, vertical: NlSpace.s2),
                    decoration: BoxDecoration(
                        color: states.contains(WidgetState.hovered)
                            ? nl.hover
                            : nl.surface.withOpacity(nl.isDark ? .5 : .7),
                        borderRadius: BorderRadius.circular(NlRadius.r2),
                        border: Border.all(color: nl.line),
                        boxShadow: states.contains(WidgetState.focused)
                            ? nl.focusRing
                            : null),
                    child: Row(children: [
                      NlLed(_serverLed(state)),
                      const SizedBox(width: NlSpace.s2),
                      Expanded(
                          child: Text(_serverHostText,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: NlType.monoText(NlType.s1,
                                  color: state == _ServerState.ready
                                      ? nl.fg2
                                      : nl.warnText))),
                      const SizedBox(width: NlSpace.s2),
                      NlMonoLabel(code,
                          tone: switch (state) {
                            _ServerState.ready => NlTone.ok,
                            _ServerState.unknown => NlTone.neutral,
                            _ => NlTone.warn,
                          }),
                    ])))));
  }

  /// The full upstream settings page, hosted inside the shell instead of a
  /// legacy tab. Widget tests inject a gateway and never build it because
  /// the upstream page reads native options while constructing.
  Widget _advancedPage(ThemeData shell) {
    final bar = NikoPageBar(
        title: nikoText('高级设置', 'Advanced settings'),
        subtitle: nikoText('RustDesk 的全部原生选项', 'Every native RustDesk option'));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      bar,
      Expanded(
          child: !_native
              ? Center(
                  child: Text(
                      nikoText('高级设置仅在应用内提供。', 'Advanced settings are app-only.'),
                      style:
                          TextStyle(color: shell.colorScheme.onSurfaceVariant)))
              : Padding(
                  padding: const EdgeInsets.fromLTRB(
                      NlSpace.s3, 0, NlSpace.s3, NlSpace.s3),
                  child:
                      DesktopSettingPage(initialTabkey: SettingsTabKey.general))),
    ]);
  }

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

  /// This computer: the ID and one-time password a controller needs, and
  /// the checks that decide whether it can be controlled at all. Shown in
  /// the device page's inspector, or in the drawer on narrow windows.
  Widget _localPanel(NlColors nl, {bool heading = true}) =>
      Builder(builder: (context) {
        void closeDrawer() => Scaffold.maybeOf(context)?.closeDrawer();
        final id = _deviceId;
        final raw = _temporaryPassword ?? '';
        final password = raw.isEmpty
            ? null
            : (_showPassword ? raw : '•' * raw.length.clamp(4, 10));
        final state = _serverState;
        return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (heading) NlSectionLabel(nikoText('本机', 'This computer')),
              NlPanel(
                  padding: const EdgeInsets.fromLTRB(
                      NlSpace.s4, NlSpace.s3, NlSpace.s2, NlSpace.s3),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(nikoText('设备 ID', 'Device ID'),
                            style: NlType.text(NlType.s2, color: nl.fg3)),
                        const SizedBox(height: 2),
                        Row(children: [
                          Expanded(
                              // Ten-digit and custom IDs step down a size
                              // before they wrap.
                              child: LayoutBuilder(
                                  builder: (context, box) => Text(
                                      id.isEmpty ? '—' : id,
                                      style: NlType.monoText(
                                          _idSize(context, id, box.maxWidth),
                                          weight: FontWeight.w500,
                                          color: nl.fg)))),
                          const SizedBox(width: NlSpace.s1),
                          NlIconButton(
                              icon: NlIcons.copy,
                              tooltip:
                                  nikoText('复制本机设备 ID', 'Copy local device ID'),
                              onPressed: id.isEmpty
                                  ? null
                                  : () =>
                                      _copy(id, nikoText('设备 ID', 'device ID'))),
                        ]),
                        Padding(
                            padding: const EdgeInsets.only(
                                top: NlSpace.s2,
                                bottom: NlSpace.s2,
                                right: NlSpace.s2),
                            child: Divider(height: 1, color: nl.line)),
                        Text(nikoText('临时密码', 'One-time password'),
                            style: NlType.text(NlType.s2, color: nl.fg3)),
                        const SizedBox(height: 2),
                        Row(children: [
                          Expanded(
                              child: Text(
                                  password ??
                                      nikoText(
                                          '未设置临时密码', 'No temporary password'),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: password == null
                                      ? NlType.text(NlType.s3, color: nl.fg3)
                                      : NlType.monoText(NlType.s5,
                                              weight: FontWeight.w500,
                                              color: nl.fg)
                                          .copyWith(
                                              letterSpacing: NlType.s5 * .12))),
                          if (password != null) ...[
                            NlIconButton(
                                icon: _showPassword ? NlIcons.eyeOff : NlIcons.eye,
                                tooltip: _showPassword
                                    ? nikoText('隐藏临时密码', 'Hide temporary password')
                                    : nikoText('显示临时密码', 'Show temporary password'),
                                onPressed: () => setState(
                                    () => _showPassword = !_showPassword)),
                            NlIconButton(
                                icon: NlIcons.copy,
                                tooltip:
                                    nikoText('复制临时密码', 'Copy temporary password'),
                                onPressed: () =>
                                    _copy(raw, nikoText('密码', 'password'))),
                          ],
                        ]),
                      ])),
              const SizedBox(height: NlSpace.s2),
              Align(
                  alignment: Alignment.centerLeft,
                  child: NlButton.quiet(
                      small: true,
                      icon: NlIcons.keyRound,
                      onPressed: _setPermanentPassword,
                      label: nikoText('设置永久密码', 'Set permanent password'))),
              const SizedBox(height: NlSpace.s5),
              NlSectionLabel(nikoText('自检', 'Health')),
              NlListRow(
                  dense: true,
                  divider: false,
                  leading: NlLed(_serverLed(state)),
                  title: nikoText('私有服务器', 'Private server'),
                  trailing: Text(_serverStatusText(state),
                      style: NlType.text(NlType.s2,
                          color: state == _ServerState.ready
                              ? nl.okText
                              : nl.warnText)),
                  onTap: () {
                    _openSettings(NikoSettingsSection.server);
                    closeDrawer();
                  }),
              if (Platform.isMacOS) ...[
                _permissionRow(nl, nikoText('屏幕录制', 'Screen recording'),
                    nikoText('被控画面必需', 'Required to be controlled'),
                    _canScreen, _openGuide),
                _permissionRow(nl, nikoText('辅助功能', 'Accessibility'),
                    nikoText('远端键鼠必需', 'Required for remote input'),
                    _canAccessibility, _openGuide),
              ],
              if (_native) const NikoVoiceCleanupEntryPoint(),
              if (_native) const NikoTunnelCleanupEntryPoint(),
              const SizedBox(height: NlSpace.s5),
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(NlIcons.shieldCheck, size: 12, color: nl.fg3),
                const SizedBox(width: NlSpace.s1),
                Flexible(
                    child: Text(
                        nikoText('私有服务器 · 端到端加密',
                            'Private server · End-to-end encrypted'),
                        textAlign: TextAlign.center,
                        style: NlType.text(NlType.s1, color: nl.fg3))),
              ]),
            ]);
      });

  Future<void> _openGuide() async {
    setState(() => _guide = true);
  }

  Widget _permissionRow(NlColors nl, String title, String reason, bool granted,
          Future<void> Function() request) =>
      NlListRow(
          dense: true,
          leading: NlLed(granted ? NlLedState.ok : NlLedState.warn),
          title: title,
          subtitle: granted ? null : reason,
          trailing: granted
              ? Text(nikoText('已授权', 'Allowed'),
                  style: NlType.text(NlType.s2, color: nl.okText))
              : NlButton.ghost(
                  small: true,
                  onPressed: request,
                  label: nikoText('授权', 'Grant')));
}

/// The largest local ID size at which [id] fits [width] on one line; the
/// smallest one otherwise.
double _idSize(BuildContext context, String id, double width) {
  const sizes = [NlType.s7, NlType.s6, NlType.s5];
  for (final size in sizes) {
    final painter = TextPainter(
        text: TextSpan(
            text: id, style: NlType.monoText(size, weight: FontWeight.w500)),
        textDirection: TextDirection.ltr,
        textScaler: MediaQuery.textScalerOf(context),
        maxLines: 1)
      ..layout();
    final fits = painter.width <= width;
    painter.dispose();
    if (fits) return size;
  }
  return sizes.last;
}

enum _ServerState { unknown, unconfigured, paused, ready, registering, notReady }
