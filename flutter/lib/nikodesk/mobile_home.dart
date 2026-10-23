import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/models/platform_model.dart';

import 'device_page.dart';
import 'link_handler.dart';
import 'device_store.dart';
import 'home_board.dart';
import 'home_chrome.dart';
import 'nightline.dart';
import 'policy.dart';
import 'server_gateway.dart';
import 'server_scope.dart';
import 'server_settings.dart';
import 'session_history.dart';
import 'session_log.dart';
import 'settings_kit.dart';
import 'ui.dart';
import 'product_build_info.dart';
import 'voice_cleanup_panel.dart';
import 'tunnel_cleanup_view.dart';
import 'capability_policy_view.dart';
import 'first_server_setup.dart';

/// Android controller home. Sessions keep the upstream mobile canvas and input.
class NikoMobileHome extends StatefulWidget {
  final DeviceStore? store;
  final ServerGateway? gateway;
  final SessionLogStore? sessionLog;
  final Future<void> Function(BuildContext, String, bool,
      {bool isFileTransfer, String? password})? onConnect;

  const NikoMobileHome(
      {super.key, this.store, this.gateway, this.sessionLog, this.onConnect});

  @override
  State<NikoMobileHome> createState() => _NikoMobileHomeState();
}

enum _MobileDestination { devices, sessions, settings }

class _NikoMobileHomeState extends State<NikoMobileHome> {
  _MobileDestination _destination = _MobileDestination.devices;
  final _board = NikoDeviceBoard();
  late final _gateway = widget.gateway ?? NativeServerGateway();
  StreamSubscription? _links;
  bool get _native =>
      widget.gateway == null || widget.gateway is NativeServerGateway;

  @override
  void initState() {
    super.initState();
    // Phones start with the denser list; the toggle on the page changes it.
    final views = WidgetsBinding.instance.platformDispatcher.views;
    if (views.isNotEmpty &&
        views.first.physicalSize.shortestSide / views.first.devicePixelRatio <
            NlLayout.compactMax) {
      _board.view = NikoDeviceView.list;
    }
    NikoServerScope.changes.addListener(_scopeChanged);
    if (_native) {
      _links = listenUniLinks();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          NikoLinkInbox.attach(
              this,
              (request) =>
                  dispatchNikoLink(context, request, gateway: widget.gateway));
        }
      });
    }
  }

  @override
  void dispose() {
    NikoServerScope.changes.removeListener(_scopeChanged);
    _links?.cancel();
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

  void _go(_MobileDestination destination) =>
      setState(() => _destination = destination);

  /// Shows the device page, then hands it the request once its fields can
  /// take focus again.
  void _onDevices(bool Function() request) {
    _go(_MobileDestination.devices);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) request();
    });
  }

  Future<void> _openPalette() => showNlCommandPalette(context,
      hint: nikoText('搜索设备或命令', 'Search devices or commands'),
      empty: nikoText('没有匹配的结果', 'No matches'),
      commands: [
        ...nikoDeviceCommands(_board, onDevices: _onDevices),
        for (final destination in _MobileDestination.values)
          NlCommand(
              title: _label(destination),
              icon: _icon(destination),
              group: nikoText('前往', 'Go to'),
              run: () => _go(destination)),
      ]);

  IconData _icon(_MobileDestination destination) => switch (destination) {
        _MobileDestination.devices => NlIcons.monitorSmartphone,
        _MobileDestination.sessions => NlIcons.history,
        _MobileDestination.settings => NlIcons.settings,
      };

  String _label(_MobileDestination destination) => switch (destination) {
        _MobileDestination.devices => nikoText('设备', 'Devices'),
        _MobileDestination.sessions => nikoText('会话', 'Sessions'),
        _MobileDestination.settings => nikoText('设置', 'Settings'),
      };

  @override
  Widget build(BuildContext context) {
    final theme = nightlineTheme(Theme.of(context).brightness);
    return Theme(
        data: theme,
        child: Scaffold(
            backgroundColor: theme.scaffoldBackgroundColor,
            body: NikoFirstServerSetup(
                gateway: _gateway,
                onLanguageChanged: _setLanguage,
                onSaved: () => _go(_MobileDestination.devices),
                child: Builder(builder: _home))));
  }

  Widget _home(BuildContext context) {
    final pages = <_MobileDestination, Widget>{
      _MobileDestination.devices: NikoDevicePage(
          key: ValueKey(
              'devices-${widget.store?.directory.path ?? DeviceStore.instance.directory.path}'),
          controllerOnly: true,
          native: _native,
          active: _destination == _MobileDestination.devices,
          store: widget.store,
          gateway: _gateway,
          sessionLog: widget.sessionLog,
          board: _board,
          onConnect: widget.onConnect,
          onOpenSettings: () => _go(_MobileDestination.settings),
          onLanguageChanged: () => setState(() {})),
      _MobileDestination.sessions: NikoSessionHistoryPage(
          key: ValueKey(
              'history-${widget.sessionLog?.directory.path ?? SessionLogStore.instance.directory.path}'),
          store: widget.sessionLog,
          gateway: _gateway,
          active: _destination == _MobileDestination.sessions,
          onConnect: widget.onConnect),
      _MobileDestination.settings: _MobileServerSettings(
          gateway: _gateway,
          active: _destination == _MobileDestination.settings,
          onLanguageChanged: _setLanguage),
    };
    final body = Column(children: [
      if (_native)
        const Padding(
            padding: EdgeInsets.symmetric(horizontal: NlSpace.s4),
            child: NikoVoiceCleanupEntryPoint()),
      if (_native)
        const Padding(
            padding: EdgeInsets.symmetric(horizontal: NlSpace.s4),
            child: NikoTunnelCleanupEntryPoint()),
      Expanded(
          child: IndexedStack(
              index: pages.keys.toList().indexOf(_destination),
              children: pages.entries
                  .map((entry) => ExcludeFocus(
                      excluding: _destination != entry.key,
                      child: entry.value))
                  .toList())),
    ]);
    final apple = Platform.isIOS || Platform.isMacOS;
    SingleActivator key(LogicalKeyboardKey key) =>
        SingleActivator(key, meta: apple, control: !apple);
    return CallbackShortcuts(
        bindings: {
          key(LogicalKeyboardKey.keyK): _openPalette,
          key(LogicalKeyboardKey.keyN): () =>
              _onDevices(_board.requestQuickConnect),
          key(LogicalKeyboardKey.keyF): () =>
              _onDevices(_board.requestFocusSearch),
          key(LogicalKeyboardKey.digit1): () => _go(_MobileDestination.devices),
          key(LogicalKeyboardKey.digit2): () =>
              _go(_MobileDestination.sessions),
          key(LogicalKeyboardKey.digit3): () =>
              _go(_MobileDestination.settings),
        },
        child: Focus(
            autofocus: true,
            child: ListenableBuilder(
                listenable: _board,
                builder: (context, _) => NikoHomeChrome(
                    touch: true,
                    destinations: [
                      for (final destination in _MobileDestination.values)
                        NikoHomeDestination(
                            icon: _icon(destination),
                            label: _label(destination),
                            count: destination == _MobileDestination.devices &&
                                    _board.devices.isNotEmpty
                                ? '${_board.devices.length}'
                                : null),
                    ],
                    selected: _destination == _MobileDestination.devices &&
                            _board.filter.startsWith('group:')
                        ? -1
                        : _MobileDestination.values.indexOf(_destination),
                    onSelect: (index) {
                      final destination = _MobileDestination.values[index];
                      if (destination == _MobileDestination.devices &&
                          _board.filter.startsWith('group:')) {
                        _board.filter = 'all';
                      }
                      _go(destination);
                    },
                    body: body,
                    sections: nikoBoardSections(context, _board,
                        devicesShown:
                            _destination == _MobileDestination.devices,
                        onDevices: _onDevices),
                    onQuickConnect: () =>
                        _onDevices(_board.requestQuickConnect),
                    onSearch: _openPalette))));
  }
}

class _MobileServerSettings extends StatefulWidget {
  final ServerGateway? gateway;
  final bool active;
  final Future<void> Function()? onLanguageChanged;
  const _MobileServerSettings(
      {this.gateway, this.active = true, this.onLanguageChanged});

  @override
  State<_MobileServerSettings> createState() => _MobileServerSettingsState();
}

class _MobileServerSettingsState extends State<_MobileServerSettings> {
  late final _gateway = widget.gateway ?? NativeServerGateway();
  late Future<ServerSnapshot> _snapshot = _gateway.read();

  @override
  void didUpdateWidget(covariant _MobileServerSettings oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) _refresh();
  }

  void _refresh() {
    final snapshot = _gateway.read();
    setState(() {
      _snapshot = snapshot;
    });
  }

  Future<void> _configure(PrivateServerConfig config) async {
    final saved = await showNikoServerSettings(context, _gateway, config);
    if (saved == true && mounted) _refresh();
  }

  String _configurationStatus(ServerSnapshot value) => value.enabled
      ? nikoText('控制端配置已启用', 'Controller configuration enabled')
      : nikoText('控制端配置已暂停', 'Controller configuration paused');

  List<Widget> _server(AsyncSnapshot<ServerSnapshot> snapshot) {
    if (snapshot.hasError) {
      return [
        NikoSettingRow(
            title: nikoText('无法读取私服设置，请重试。',
                'Could not read server settings. Please retry.'),
            trailing: NlButton.ghost(
                small: true,
                onPressed: _refresh,
                label: nikoText('重试', 'Retry'))),
      ];
    }
    if (!snapshot.hasData) {
      return [
        NikoSettingRow(
            title: nikoText('正在读取私服设置…', 'Reading server settings…'),
            busy: true),
      ];
    }
    final value = snapshot.data!;
    final config = value.config;
    return [
      NikoSettingRow(
          leading: NlLed(config.isValid && value.enabled
              ? NlLedState.ok
              : NlLedState.warn),
          title: config.isValid
              ? nikoText('配置完整', 'Configuration complete')
              : nikoText('尚未配置', 'Setup required'),
          description: _configurationStatus(value)),
      if (config.idServer.isNotEmpty)
        NikoSettingRow(
            title: nikoText('ID 服务器', 'ID server'),
            trailing: NikoSettingValue(config.idServer, mono: true)),
      if (config.relayServer.isNotEmpty)
        NikoSettingRow(
            title: nikoText('中继服务器', 'Relay server'),
            trailing: NikoSettingValue(config.relayServer, mono: true)),
      NikoSettingRow(
          title: nikoText('配置服务器', 'Configure server'),
          onTap: () => _configure(value.config)),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final native = widget.gateway == null || widget.gateway is NativeServerGateway;
    return NlScrollWatcher(
        header: (context, scrolled) => NikoPageBar(
            title: nikoText('设置', 'Settings'),
            subtitle: nikoText('私有服务器、语言与使用指南', 'Server, language and guides'),
            divider: scrolled),
        child: ListView(
          key: const Key('nikodesk-mobile-settings-scroll'),
          padding: const EdgeInsets.fromLTRB(
              NlSpace.s4, NlSpace.s2, NlSpace.s4, NlSpace.s10),
          children: [
            FutureBuilder<ServerSnapshot>(
                future: _snapshot,
                builder: (context, snapshot) => NikoSettingsGroup(
                    title: nikoText('私有服务器', 'Private server'),
                    description: nikoText(
                        '本机作为控制端，不注册为被控设备。配置启用不代表远端在线，每次会话仍需密码、认证与加密验证。',
                        'This controller does not register as a receiving device. Enabled configuration does not prove peer availability; each session still verifies its password, authentication and encryption.'),
                    trailing: NlIconButton(
                        icon: NlIcons.refreshCw,
                        tooltip:
                            nikoText('刷新配置状态', 'Refresh configuration'),
                        onPressed: _refresh),
                    children: _server(snapshot))),
            NikoSettingsGroup(title: nikoText('通用', 'General'), children: [
              NikoSettingRow(
                  title: nikoText('界面语言', 'Interface language'),
                  trailing: NlSegmented<bool>(
                      segments: const [
                        NlSegment(value: false, label: '中文'),
                        NlSegment(value: true, label: 'English'),
                      ],
                      selected: NikoLanguage.english,
                      onChanged: (english) {
                        if (english != NikoLanguage.english) {
                          widget.onLanguageChanged?.call();
                        }
                      })),
            ]),
            if (native) const NikoMobileVoicePolicyCard(),
            NikoSettingsGroup(title: nikoText('使用指南', 'Guides'), children: [
              NikoSettingDisclosure(
                  key: const Key('nikodesk-controller-guide'),
                  toggleKey: const Key('nikodesk-controller-guide-toggle'),
                  title: nikoText('手机作为控制端', 'Using your phone as a controller'),
                  children: [
                    Text(nikoText(
                        '先填写自己的 ID 服务器、中继与服务端公钥，再到设备页输入远端 ID 和密码。远端电脑也需要使用相同私服。',
                        'Configure your ID server, relay and server public key, then enter the remote ID and password on Devices. The remote computer needs the same server settings.')),
                    Text(nikoText('控制其他设备无需开启本机屏幕采集或辅助功能。远控画面、触控操作与文件传输沿用原生移动会话。',
                        'Controlling another device does not require local screen capture or accessibility access. Video, touch controls and file transfer use the native mobile session.')),
                    Text(nikoText('服务端公钥不是远控密码；请勿填入或复制服务端私钥。',
                        'The server public key is not a remote-control password. Never enter or copy the server private key.')),
                  ]),
              NikoSettingDisclosure(
                  key: const Key('nikodesk-touch-guide'),
                  toggleKey: const Key('nikodesk-touch-guide-toggle'),
                  title: nikoText('触控操作指南', 'Touch controls'),
                  children: [
                    Text(nikoText('在会话菜单中选择触摸或鼠标模式。触摸模式长按右键，单指拖动；鼠标模式双指轻点右键，用拖动控件保持按下并移动。',
                        'Choose touch or mouse mode in the session menu. In touch mode, long-press for right-click and drag with one finger. In mouse mode, tap with two fingers for right-click and use the drag control to hold and move.')),
                    Text(nikoText('键盘按钮打开软键盘；返回时核对退出提示。操作能力取决于被控端授予的权限。',
                        'The keyboard button opens the soft keyboard. Review the exit prompt when going back. Available actions depend on permissions granted by the remote computer.')),
                  ]),
            ]),
            NikoProductAbout(
                loadInfo: () => ProductBuildInfo.read(
                    nativeVersionLoader: native ? bind.mainGetVersion : null)),
          ],
        ));
  }
}
