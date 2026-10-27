import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/main.dart' show kBootArgs;
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
import 'product_build_info.dart';

/// Product shell for the NikoDesk home window: navigation plus the device
/// workspace. Replaces the stock RustDesk two-pane home while keeping every
/// session path native — nothing here mocks connections.
class NikoHomeShell extends StatefulWidget {
  final DeviceStore? store;
  final ServerGateway? gateway;
  final Future<void> Function(BuildContext, String, bool,
      {bool isFileTransfer, String? password})? onConnect;
  final String Function()? deviceIdProvider;

  /// This computer's name on the card; tests and screenshots set a sample.
  final String Function()? hostNameProvider;
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

  /// Devices' last screens; null reads the ones the core keeps.
  final ImageProvider? Function(String id)? screenOf;

  const NikoHomeShell(
      {super.key,
      this.store,
      this.gateway,
      this.onConnect,
      this.deviceIdProvider,
      this.hostNameProvider,
      this.temporaryPasswordProvider,
      this.sessionLog,
      this.screenRecordingProbe,
      this.accessibilityProbe,
      this.screenRecordingRequest,
      this.accessibilityRequest,
      this.macTitleBar,
      this.screenOf});

  @override
  State<NikoHomeShell> createState() => _NikoHomeShellState();
}

/// Advanced settings stay a destination (settings and the palette open it)
/// but have no row of their own in the navigation.
enum _HomeDestination { home, devices, sessions, settings, advanced }

const _navigation = [
  _HomeDestination.home,
  _HomeDestination.devices,
  _HomeDestination.sessions,
  _HomeDestination.settings,
];

class _NikoHomeShellState extends State<NikoHomeShell>
    with SingleTickerProviderStateMixin {
  DeviceStore get _store => widget.store ?? DeviceStore.instance;
  late final _gateway = widget.gateway ?? NativeServerGateway();
  _HomeDestination _destination = _HomeDestination.home;
  final _board = NikoDeviceBoard();
  ServerSnapshot? _server;
  String? _temporaryPassword;
  bool _showPassword = false;
  bool _canScreen = true;
  bool _canAccessibility = true;
  String? _version;

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
      ProductBuildInfo.read().then((info) {
        if (mounted && info.version != null) {
          setState(() => _version = info.version);
        }
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          NikoLinkInbox.attach(this, _handleLink);
          if (nikoInstallAssistantRequested()) {
            showNikoInstallAssistant(context);
          } else if (Platform.isWindows && nikoUninstallRequested(kBootArgs)) {
            showNikoUninstallAssistant(context);
          }
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
                  title: Text(nikoText('设置固定密码', 'Set a fixed password')),
                  content: Column(mainAxisSize: MainAxisSize.min, children: [
                    Text(nikoText('知道本机设备代码和固定密码的人可以直接连进来，不需要在本机点允许。请用一个只给 NikoDesk 的密码；如果想每次都在本机点允许，到高级设置的安全页里改。',
                        'Anyone with this device code and the fixed password connects without a click here. Use a password only for NikoDesk; to require a click every time, change it under Security in advanced settings.')),
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
                        title: Text(nikoText('同时允许用固定密码连接',
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
                    : nikoText('密码已保存，但固定密码验证没有开启。请在高级设置的安全页里核对验证方式和接受规则。',
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
                  _go(_HomeDestination.home);
                  _refreshStatus();
                },
                child: _guide == true
                    ? NikoTitleStrip(
                        enabled: _macTitleBar, child: _permissionGuide())
                    : Builder(builder: (context) => _home(context, shell)))));
  }

  Widget _home(BuildContext context, ThemeData shell) {
    final nl = NlColors.of(context);
    final onDevices = _destination == _HomeDestination.home ||
        _destination == _HomeDestination.devices;
    // Home and Devices are one page in two layouts, so a connection started
    // from either has one owner.
    final slots = <Widget>[
      NikoDevicePage(
          key: ValueKey('devices-${_store.directory.path}'),
          store: _store,
          gateway: _gateway,
          native: _native,
          active: onDevices,
          sessionLog: widget.sessionLog,
          board: _board,
          layout: _destination == _HomeDestination.devices
              ? NikoDeviceLayout.manage
              : NikoDeviceLayout.home,
          localPanel: _credentials(nl),
          screenOf: widget.screenOf,
          onManage: () => _go(_HomeDestination.devices),
          onLanguageChanged: () => setState(() {}),
          onConnect: widget.onConnect,
          onOpenSettings: () => _openSettings(NikoSettingsSection.server)),
      NikoSessionHistoryPage(
          key: ValueKey(
              'history-${widget.sessionLog?.directory.path ?? SessionLogStore.instance.directory.path}'),
          store: widget.sessionLog,
          gateway: _gateway,
          active: _destination == _HomeDestination.sessions,
          onConnect: widget.onConnect),
      NikoSettingsView(
          gateway: _gateway,
          initialSection: _settingsSection,
          sectionRequest: _settingsRequest,
          native: _native,
          active: _destination == _HomeDestination.settings,
          onServerSaved: _refreshStatus,
          onLanguageChanged: () => setState(() {}),
          onAppearanceChanged: () => setState(() {}),
          onOpenAdvanced: () => _go(_HomeDestination.advanced)),
      _advancedPage(shell),
    ];
    final slot = switch (_destination) {
      _HomeDestination.home || _HomeDestination.devices => 0,
      _HomeDestination.sessions => 1,
      _HomeDestination.settings => 2,
      _HomeDestination.advanced => 3,
    };
    final content = AnimatedBuilder(
        animation: _enter,
        child: IndexedStack(
            index: slot,
            children: [
              for (var i = 0; i < slots.length; i++)
                ExcludeFocus(excluding: i != slot, child: slots[i]),
            ]),
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
                builder: (context, _) => NikoHomeChrome(
                    destinations: [
                      for (final destination in _navigation)
                        NikoHomeDestination(
                            icon: _icon(destination),
                            label: _label(destination),
                            count: destination == _HomeDestination.devices &&
                                    _board.devices.isNotEmpty
                                ? '${_board.devices.length}'
                                : null),
                    ],
                    selected: _navigation.indexOf(
                        _destination == _HomeDestination.advanced
                            ? _HomeDestination.settings
                            : _destination),
                    onSelect: (index) => _go(_navigation[index]),
                    body: content,
                    footer: _footer(nl),
                    onSearch: _openPalette,
                    searchShortcut: nikoShortcut('K'),
                    macTitleBar: _macTitleBar))));
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

  /// Shows the home panel and puts the cursor in its device-code field.
  void _quickConnect() {
    _go(_HomeDestination.home);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _board.requestQuickConnect();
    });
  }

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
      key(LogicalKeyboardKey.digit1): () => _go(_HomeDestination.home),
      key(LogicalKeyboardKey.digit2): () => _go(_HomeDestination.devices),
      key(LogicalKeyboardKey.digit3): () => _go(_HomeDestination.sessions),
      key(LogicalKeyboardKey.digit4): () => _go(_HomeDestination.settings),
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
              title: nikoText('设置固定密码', 'Set a fixed password'),
              icon: NlIcons.keyRound,
              group: actions,
              run: _setPermanentPassword),
          for (final destination in _HomeDestination.values)
            NlCommand(
                title: _label(destination),
                icon: _icon(destination),
                group: nikoText('前往', 'Go to'),
                shortcut: switch (destination) {
                  _HomeDestination.home => nikoShortcut('1'),
                  _HomeDestination.devices => nikoShortcut('2'),
                  _HomeDestination.sessions => nikoShortcut('3'),
                  _HomeDestination.settings => nikoShortcut(','),
                  _HomeDestination.advanced => null,
                },
                run: () => _go(destination)),
          ...commands.skip(2),
        ]);
  }

  IconData _icon(_HomeDestination destination) => switch (destination) {
        _HomeDestination.home => NlIcons.screenShare,
        _HomeDestination.devices => NlIcons.monitorSmartphone,
        _HomeDestination.sessions => NlIcons.history,
        _HomeDestination.settings => NlIcons.settings,
        _HomeDestination.advanced => NlIcons.slidersHorizontal,
      };

  String _label(_HomeDestination destination) => switch (destination) {
        _HomeDestination.home => nikoText('远程控制', 'Remote control'),
        _HomeDestination.devices => nikoText('设备', 'Devices'),
        _HomeDestination.sessions => nikoText('会话记录', 'Sessions'),
        _HomeDestination.settings => nikoText('设置', 'Settings'),
        _HomeDestination.advanced => nikoText('高级设置', 'Advanced'),
      };

  /// The private server at the foot of the sidebar, in words, and the
  /// version; the server line opens its settings.
  Widget _footer(NlColors nl) {
    final state = _serverState;
    final ready = state == _ServerState.ready;
    final host = _server?.config.idServer ?? '';
    final line = switch (state) {
      _ServerState.unknown => nikoText('配置状态未知', 'Configuration status unknown'),
      _ServerState.unconfigured =>
        nikoText('未配置私有服务器', 'No private server yet'),
      _ServerState.ready => host,
      _ => '${_serverStatusText(state)}，$host',
    };
    return Padding(
        padding: const EdgeInsets.fromLTRB(
            NlSpace.s2, NlSpace.s1, NlSpace.s2, NlSpace.s3),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Semantics(
              button: true,
              label:
                  '${nikoText('私有服务器', 'Private server')}，${_serverStatusText(state)}',
              excludeSemantics: true,
              child: NlPressable(
                  onTap: () => _openSettings(NikoSettingsSection.server),
                  pressScale: .99,
                  builder: (context, states) => AnimatedContainer(
                      duration: NlMotion.of(context, NlMotion.instant),
                      padding: const EdgeInsets.symmetric(
                          horizontal: NlSpace.s2, vertical: NlSpace.s2),
                      decoration: BoxDecoration(
                          color: states.contains(WidgetState.hovered)
                              ? nl.hover
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(NlRadius.r2),
                          boxShadow: states.contains(WidgetState.focused)
                              ? nl.focusRing
                              : null),
                      child: Row(children: [
                        NlLed(_serverLed(state)),
                        const SizedBox(width: NlSpace.s2),
                        Expanded(
                            child: Text(line,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: NlType.text(NlType.s2,
                                    color: ready ? nl.fg2 : nl.warnText))),
                      ])))),
          if (_version != null)
            Padding(
                padding: const EdgeInsets.fromLTRB(
                    NlSpace.s2, NlSpace.s1, NlSpace.s2, 0),
                child: Text('NikoDesk $_version',
                    style: NlType.text(NlType.s1, color: nl.fg3))),
        ]));
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

  /// This computer, as the card beside the connect panel: the code and
  /// one-time password a controller needs, whether it can be controlled at
  /// all, and only when it cannot, what is missing.
  Widget _credentials(NlColors nl) => Builder(builder: (context) {
        final id = _deviceId;
        final raw = _temporaryPassword ?? '';
        final password = raw.isEmpty
            ? null
            : (_showPassword ? raw : '•' * raw.length.clamp(4, 10));
        final state = _serverState;
        final missing = <(String, String, VoidCallback)>[
          if (state != _ServerState.ready && state != _ServerState.unknown)
            (
              nikoText('私有服务器${_serverStatusText(state)}',
                  'Private server: ${_serverStatusText(state)}'),
              nikoText('去设置', 'Settings'),
              () => _openSettings(NikoSettingsSection.server)
            ),
          if (Platform.isMacOS && !_canScreen)
            (
              nikoText('没有授权“屏幕录制”，别人连进来只能看到黑屏',
                  'Screen Recording is off, so others would see black'),
              nikoText('去授权', 'Grant'),
              _openGuide
            ),
          if (Platform.isMacOS && !_canAccessibility)
            (
              nikoText('没有授权“辅助功能”，别人连进来不能操作',
                  'Accessibility is off, so others could not operate'),
              nikoText('去授权', 'Grant'),
              _openGuide
            ),
        ];
        final ready = missing.isEmpty && state == _ServerState.ready;
        final host = (widget.hostNameProvider?.call() ?? Platform.localHostname)
            .replaceAll(RegExp(r'\.local$'), '');
        final system = Platform.isMacOS
            ? 'macOS'
            : Platform.isWindows
                ? 'Windows'
                : Platform.isLinux
                    ? 'Linux'
                    : '';
        final pill = Container(
            height: 24,
            padding: const EdgeInsets.symmetric(horizontal: NlSpace.s3),
            decoration: BoxDecoration(
                color: ready ? nl.okSoft : nl.warnSoft,
                borderRadius: BorderRadius.circular(NlRadius.pill)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              if (ready) ...[
                Container(
                    width: 6,
                    height: 6,
                    decoration:
                        BoxDecoration(shape: BoxShape.circle, color: nl.ok)),
                const SizedBox(width: 6),
              ],
              Text(
                  ready
                      ? nikoText('可以被控制', 'Ready to be controlled')
                      : nikoText('还不能被控制', 'Not ready yet'),
                  style: NlType.text(NlType.s2,
                      weight: FontWeight.w500,
                      color: ready ? nl.okText : nl.warnText)),
            ]));
        return NlPanel(
            padding: const EdgeInsets.all(NlSpace.s6),
            child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 252),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(children: [
                        Expanded(
                            child: Text(nikoText('本机', 'This computer'),
                                style: NlType.text(NlType.s5,
                                    weight: FontWeight.w600, color: nl.fg))),
                        if (state != _ServerState.unknown) pill,
                      ]),
                      const SizedBox(height: NlSpace.s4),
                      Text(nikoText('设备代码', 'Device code'),
                          style: NlType.text(NlType.s2, color: nl.fg3)),
                      Row(children: [
                        Flexible(
                            child: FittedBox(
                                fit: BoxFit.scaleDown,
                                alignment: Alignment.centerLeft,
                                child: Text(
                                    id.isEmpty ? '—' : nikoGroupedId(id),
                                    key: const Key('nikodesk-local-id'),
                                    style: NlType.text(34,
                                            weight: FontWeight.w600,
                                            color: nl.fg)
                                        .copyWith(
                                            height: 1.25,
                                            // Figures keep their own spacing;
                                            // tracking would push the first
                                            // digit outside its box.
                                            letterSpacing: 0,
                                            fontFeatures: const [
                                          FontFeature.tabularFigures()
                                        ])))),
                        const SizedBox(width: NlSpace.s1),
                        NlIconButton(
                            icon: NlIcons.copy,
                            tooltip:
                                nikoText('复制本机设备代码', 'Copy this device code'),
                            onPressed: id.isEmpty
                                ? null
                                : () => _copy(id, nikoText('设备代码', 'device code'))),
                      ]),
                      if (host.isNotEmpty)
                        Text(system.isEmpty ? host : '$host，$system',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: NlType.text(NlType.s2, color: nl.fg3)),
                      const SizedBox(height: NlSpace.s4),
                      Text(nikoText('临时密码', 'One-time password'),
                          style: NlType.text(NlType.s2, color: nl.fg3)),
                      Row(children: [
                        Expanded(
                            child: Text(
                                password ??
                                    nikoText('没有临时密码', 'No one-time password'),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: password == null
                                    ? NlType.text(NlType.s3, color: nl.fg3)
                                    : NlType.text(NlType.s6,
                                            weight: FontWeight.w600,
                                            color: nl.fg)
                                        .copyWith(
                                            letterSpacing: _showPassword ? .5 : 2,
                                            fontFeatures: const [
                                            FontFeature.tabularFigures()
                                          ]))),
                        if (password != null) ...[
                          NlIconButton(
                              icon: _showPassword ? NlIcons.eyeOff : NlIcons.eye,
                              tooltip: _showPassword
                                  ? nikoText('隐藏临时密码', 'Hide one-time password')
                                  : nikoText('显示临时密码', 'Show one-time password'),
                              onPressed: () =>
                                  setState(() => _showPassword = !_showPassword)),
                          NlIconButton(
                              icon: NlIcons.copy,
                              tooltip: nikoText('复制临时密码', 'Copy one-time password'),
                              onPressed: () =>
                                  _copy(raw, nikoText('密码', 'password'))),
                        ],
                      ]),
                      for (final (text, action, onTap) in missing) ...[
                        const SizedBox(height: NlSpace.s3),
                        Container(
                            padding: const EdgeInsets.fromLTRB(
                                NlSpace.s3, NlSpace.s2, NlSpace.s2, NlSpace.s2),
                            decoration: BoxDecoration(
                                color: nl.warnSoft,
                                borderRadius: BorderRadius.circular(NlRadius.r2)),
                            child: Row(children: [
                              Icon(NlIcons.triangleAlert,
                                  size: 15, color: nl.warnText),
                              const SizedBox(width: NlSpace.s2),
                              Expanded(
                                  child: Text(text,
                                      style: NlType.text(NlType.s2, color: nl.fg))),
                              NlButton.quiet(
                                  small: true, label: action, onPressed: onTap),
                            ])),
                      ],
                      const SizedBox(height: NlSpace.s4),
                      Divider(height: 1, color: nl.line),
                      const SizedBox(height: NlSpace.s2),
                      Wrap(
                          spacing: NlSpace.s1,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            NlButton.quiet(
                                small: true,
                                icon: NlIcons.keyRound,
                                onPressed: _setPermanentPassword,
                                label: nikoText('设置固定密码', 'Set a fixed password')),
                          ]),
                      if (_native) const NikoVoiceCleanupEntryPoint(),
                      if (_native) const NikoTunnelCleanupEntryPoint(),
                    ])));
      });

  Future<void> _openGuide() async {
    setState(() => _guide = true);
  }
}

enum _ServerState { unknown, unconfigured, paused, ready, registering, notReady }
