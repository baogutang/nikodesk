import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/models/platform_model.dart';

import 'device_page.dart';
import 'link_handler.dart';
import 'device_store.dart';
import 'policy.dart';
import 'server_gateway.dart';
import 'server_scope.dart';
import 'server_settings.dart';
import 'session_history.dart';
import 'session_log.dart';
import 'theme.dart';
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
  late final _gateway = widget.gateway ?? NativeServerGateway();
  StreamSubscription? _links;
  bool get _native =>
      widget.gateway == null || widget.gateway is NativeServerGateway;

  @override
  void initState() {
    super.initState();
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

  @override
  Widget build(BuildContext context) => Theme(
      data: nikoTheme(Theme.of(context).brightness),
      child: NikoFirstServerSetup(
        gateway: _gateway,
        onLanguageChanged: _setLanguage,
        onSaved: () =>
            setState(() => _destination = _MobileDestination.devices),
        child: Builder(builder: (context) {
        final light = nikoIsLight(context);
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
              onConnect: widget.onConnect,
              onOpenSettings: () =>
                  setState(() => _destination = _MobileDestination.settings),
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
              active: _destination == _MobileDestination.settings),
        };
        return Scaffold(
          appBar: AppBar(
            title: const Text('NikoDesk'),
            actions: [
              TextButton(
                  onPressed: _setLanguage,
                  child: Text(NikoLanguage.english ? '中文' : 'English')),
            ],
          ),
          body: SafeArea(
            bottom: false,
            child: Column(children: [
              if (_native) const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16),
                  child: NikoVoiceCleanupEntryPoint()),
              if (_native) const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16),
                  child: NikoTunnelCleanupEntryPoint()),
              Expanded(child: DecoratedBox(
              decoration: BoxDecoration(
                  color: light ? NikoPalette.lightScaffold : NikoPalette.darkScaffold),
              child: IndexedStack(
                  index: pages.keys.toList().indexOf(_destination),
                  children: pages.entries.map((entry) => ExcludeFocus(
                      excluding: _destination != entry.key,
                      child: entry.value)).toList()),
              )),
            ]),
          ),
          bottomNavigationBar: NavigationBar(
            selectedIndex: pages.keys.toList().indexOf(_destination),
            onDestinationSelected: (value) =>
                setState(() => _destination = pages.keys.elementAt(value)),
            destinations: [
              for (final destination in pages.keys)
              if (destination == _MobileDestination.devices) NavigationDestination(
                  icon: const Icon(Icons.devices_outlined),
                  selectedIcon: const Icon(Icons.devices_rounded),
                  label: nikoText('设备', 'Devices'))
              else if (destination == _MobileDestination.sessions) NavigationDestination(
                  icon: const Icon(Icons.history_rounded),
                  label: nikoText('会话', 'Sessions'))
              else NavigationDestination(
                  icon: const Icon(Icons.settings_outlined),
                  selectedIcon: const Icon(Icons.settings_rounded),
                  label: nikoText('设置', 'Settings')),
            ],
          ),
        );
      })));
}

class _MobileServerSettings extends StatefulWidget {
  final ServerGateway? gateway;
  final bool active;
  const _MobileServerSettings({this.gateway, this.active = true});

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

  @override
  Widget build(BuildContext context) => ListView(
        key: const Key('nikodesk-mobile-settings-scroll'),
        padding: const EdgeInsets.all(16),
        children: [
          Text(nikoText('私有服务器', 'Private server'),
              style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 16),
          FutureBuilder<ServerSnapshot>(
              future: _snapshot,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return NikoGlassCard(
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                        Text(nikoText('无法读取私服设置，请重试。',
                            'Could not read server settings. Please retry.')),
                        TextButton(
                            onPressed: _refresh,
                            child: Text(nikoText('重试', 'Retry'))),
                      ]));
                }
                if (!snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final value = snapshot.data!;
                return NikoGlassCard(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      Text(value.config.isValid
                          ? nikoText('配置完整', 'Configuration complete')
                          : nikoText('尚未配置', 'Setup required')),
                      const SizedBox(height: 8),
                      Text(_configurationStatus(value)),
                      const SizedBox(height: 8),
                      Text(nikoText(
                          '本机作为控制端，不注册为被控设备。配置启用不代表远端在线，每次会话仍需密码、认证与加密验证。',
                          'This controller does not register as a receiving device. Enabled configuration does not prove peer availability; each session still verifies its password, authentication and encryption.')),
                      const SizedBox(height: 16),
                      OutlinedButton(
                          onPressed: () => _configure(value.config),
                          child: Text(nikoText('配置服务器', 'Configure server'))),
                      TextButton(
                          onPressed: _refresh,
                          child:
                              Text(nikoText('刷新配置状态', 'Refresh configuration'))),
                    ]));
              }),
          const SizedBox(height: 16),
          if (widget.gateway == null || widget.gateway is NativeServerGateway) ...[
            const NikoMobileVoicePolicyCard(),
            const SizedBox(height: 16),
          ],
          NikoGlassCard(
              padding: EdgeInsets.zero,
              child: ExpansionTile(
                  key: const Key('nikodesk-controller-guide'),
                  title: Text(nikoText('手机作为控制端', 'Using your phone as a controller'), key: const Key('nikodesk-controller-guide-toggle')),
                  childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  children: [
                const SizedBox(height: 8),
                Text(nikoText(
                    '先填写自己的 ID 服务器、中继与服务端公钥，再到设备页输入远端 ID 和密码。远端电脑也需要使用相同私服。',
                    'Configure your ID server, relay and server public key, then enter the remote ID and password on Devices. The remote computer needs the same server settings.')),
                const SizedBox(height: 8),
                Text(nikoText('控制其他设备无需开启本机屏幕采集或辅助功能。远控画面、触控操作与文件传输沿用原生移动会话。',
                    'Controlling another device does not require local screen capture or accessibility access. Video, touch controls and file transfer use the native mobile session.')),
                const SizedBox(height: 8),
                Text(nikoText('服务端公钥不是远控密码；请勿填入或复制服务端私钥。',
                    'The server public key is not a remote-control password. Never enter or copy the server private key.')),
              ])),
          const SizedBox(height: 16),
          NikoGlassCard(
              padding: EdgeInsets.zero,
              child: ExpansionTile(
                  key: const Key('nikodesk-touch-guide'),
                  title: Text(nikoText('触控操作指南', 'Touch controls'), key: const Key('nikodesk-touch-guide-toggle')),
                  childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  children: [
                    Text(nikoText('在会话菜单中选择触摸或鼠标模式。触摸模式长按右键，单指拖动；鼠标模式双指轻点右键，用拖动控件保持按下并移动。',
                        'Choose touch or mouse mode in the session menu. In touch mode, long-press for right-click and drag with one finger. In mouse mode, tap with two fingers for right-click and use the drag control to hold and move.')),
                    const SizedBox(height: 8),
                    Text(nikoText('键盘按钮打开软键盘；返回时核对退出提示。操作能力取决于被控端授予的权限。',
                        'The keyboard button opens the soft keyboard. Review the exit prompt when going back. Available actions depend on permissions granted by the remote computer.')),
                  ])),
          const SizedBox(height: 16),
          NikoProductAbout(
              loadInfo: () => ProductBuildInfo.read(
                  nativeVersionLoader: widget.gateway == null ||
                          widget.gateway is NativeServerGateway
                      ? bind.mainGetVersion
                      : null)),
        ],
      );
}
