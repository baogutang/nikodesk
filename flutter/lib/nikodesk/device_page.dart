import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/models/platform_model.dart';

import 'connect_dialog.dart';
import 'credential_connect_dialog.dart';
import 'device_store.dart';
import 'policy.dart';
import 'server_gateway.dart';
import 'server_settings.dart';
import 'session_log.dart';
import 'theme.dart';
import 'ui.dart';
import 'wake_on_lan.dart';
import 'wake_on_lan_view.dart';
import 'wake_proxy.dart';
import 'wake_online.dart';
import 'peer_event_scope.dart';
import 'server_scope.dart';

/// Device workspace of the NikoDesk home. All sessions go through the real
/// connect path; online dots come from the private rendezvous server.
class NikoDevicePage extends StatefulWidget {
  final DeviceStore? store;
  final ServerGateway? gateway;
  final Future<void> Function(BuildContext, String, bool,
      {bool isFileTransfer, String? password})? onConnect;
  final Future<void> Function(BuildContext, String, bool,
      {bool isFileTransfer, String? password})? onTunnelConnect;
  final VoidCallback? onOpenSettings;
  final VoidCallback? onLanguageChanged;
  final SessionLogStore? sessionLog;
  final bool controllerOnly;
  final bool? native;
  final bool active;
  final Future<String> Function(String namespace, String id)? credentialStatusLoader;
  const NikoDevicePage(
      {super.key,
      this.store,
      this.gateway,
      this.onConnect,
      this.onTunnelConnect,
      this.onOpenSettings,
      this.onLanguageChanged,
      this.sessionLog,
      this.controllerOnly = false,
      this.native,
      this.active = true,
      this.credentialStatusLoader});
  @override
  State<NikoDevicePage> createState() => _NikoDevicePageState();
}

class _NikoDevicePageState extends State<NikoDevicePage> {
  late final _store = widget.store ?? DeviceStore.instance;
  late final _gateway = widget.gateway ?? NativeServerGateway();
  final _search = TextEditingController();
  final _temporary = TextEditingController();
  final _password = TextEditingController();
  List<DeviceEntry> _devices = [];
  ServerSnapshot? _server;
  String? _error;
  String? _notice;
  String _filter = 'all';
  bool _loading = true;
  bool _refreshing = false;
  bool _connecting = false;
  bool _fileTransfer = false;
  bool _tunnel = false;
  bool _forceRelay = false;
  bool _rememberPassword = false;
  bool _legacyAvailable = false;
  bool _quickExpanded = false;
  final Map<String, bool> _online = {};
  final Map<String, Duration> _onlineObserved = {};
  final Stopwatch _onlineClock = Stopwatch()..start();
  String? _onlineNamespace;
  Timer? _timer;
  Timer? _onlineTimer;

  bool get _native =>
      widget.native ??
      (widget.gateway == null || widget.gateway is NativeServerGateway);
  bool get _credentialNative => _native || widget.credentialStatusLoader != null;
  Future<String> _credentialStatus(String namespace, String id) =>
      (widget.credentialStatusLoader ?? nikoCredentialStatus)(namespace, id);
  // The store is created on first access, which can happen before the first
  // gateway read activates the private-server scope; its namespace is then
  // frozen empty for the lifetime of this page state. Connection dispatches
  // must resolve the live scope instead of that frozen value — the first
  // real-device launches failed exactly here.
  String? get _dispatchNamespace =>
      NikoServerScope.current ?? _store.serverNamespace;
  static const _onlineEvent = 'callback_query_onlines';
  static const _onlineHandler = 'nikodesk-device-page';

  @override
  void initState() {
    super.initState();
    if (_native) {
      final language = bind.mainGetLocalOption(key: 'lang');
      NikoLanguage.english = language.isNotEmpty && !language.startsWith('zh');
      if (language.isEmpty) {
        WidgetsBinding.instance
            .addPostFrameCallback((_) => _setLanguage(false));
      }
      platformFFI.registerEventHandler(_onlineEvent, _onlineHandler,
          (evt) async {
        if (!mounted) return;
        if (_store.serverNamespace == null ||
            _store.serverNamespace != NikoServerScope.current) return;
        final result = nikoScopedOnlineEvent(evt, _store.serverNamespace);
        if (result == null) return;
        setState(() {
          _expireOnline(result.namespace);
          for (final id in result.onlines) {
            _online[id] = true;
            _onlineObserved[id] = _onlineClock.elapsed;
          }
          for (final id in result.offlines) {
            _online[id] = false;
            _onlineObserved[id] = _onlineClock.elapsed;
          }
        });
      });
      _onlineTimer = Timer.periodic(const Duration(seconds: 6), (_) async {
        if (_devices.isEmpty || !_canConnect) return;
        final namespace = _store.serverNamespace;
        if (namespace == null) return;
        try {
          await bind.queryOnlines(ids: [
            'nikodesk-scope:$namespace',
            ..._devices.map((d) => d.id)
          ]).timeout(const Duration(seconds: 3));
        } catch (_) {
          // The rendezvous query is best-effort; cards fall back to unknown.
        }
      });
    }
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => _refresh());
  }

  void _expireOnline(String? namespace) {
    if (_onlineNamespace != namespace) {
      if (_onlineNamespace != null) {
        _password.clear();
        _temporary.clear();
        _rememberPassword = false;
      }
      _online.clear();
      _onlineObserved.clear();
      _onlineNamespace = namespace;
      return;
    }
    final stale = _onlineObserved.entries
        .where((entry) =>
            _onlineClock.elapsed - entry.value >= const Duration(seconds: 15))
        .map((entry) => entry.key)
        .toList();
    for (final id in stale) {
      _online.remove(id);
      _onlineObserved.remove(id);
    }
  }

  Future<void> _setLanguage(bool english) async {
    if (!mounted) return;
    setState(() => NikoLanguage.english = english);
    widget.onLanguageChanged?.call();
    if (!_native) return;
    final language = english ? 'en' : 'zh-cn';
    await bind.mainSetLocalOption(key: 'lang', value: language);
    await bind.mainChangeLanguage(lang: language);
    if (isDesktop) await reloadAllWindows();
  }

  @override
  void didUpdateWidget(covariant NikoDevicePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.active) _password.clear();
    if (widget.active && !oldWidget.active) _refresh();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _onlineTimer?.cancel();
    _onlineClock.stop();
    if (_native) {
      try {
        platformFFI.unregisterEventHandler(_onlineEvent, _onlineHandler);
      } catch (_) {}
    }
    _search.dispose();
    _temporary.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (_refreshing) return;
    _refreshing = true;
    try {
      Future<void> loadDirectory() async {
        final directory = await _store.load();
        if (!mounted) return;
        setState(() {
          _devices = directory.devices;
          _loading = false;
          if (directory.recovered) {
            _notice = nikoText('设备目录损坏，已保留损坏文件并恢复可用备份（无备份时为空目录）。',
                'The damaged device file was preserved. A valid backup was restored, or an empty directory was created.');
          }
        });
      }

      late ServerSnapshot server;
      final serverRead = _gateway.read().then<void>((value) => server = value);
      // Discover the native scope before resolving the default directory. An
      // explicitly supplied or already scoped directory can render immediately.
      if (widget.store == null && _native && NikoServerScope.current == null) {
        await serverRead;
      }
      await Future.wait<void>([serverRead, loadDirectory()]);
      final legacyAvailable = _native &&
          _store.serverNamespace != null &&
          (await File('${DeviceStore.privateDirectory.path}/devices.json')
                  .exists() ||
              await File('${DeviceStore.privateDirectory.path}/sessions.json')
                  .exists());
      if (mounted) {
        setState(() {
          _expireOnline(server.namespace);
          _server = server;
          _error = null;
          _legacyAvailable = legacyAvailable;
        });
      }
    } on FutureDeviceSchema {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = nikoText('设备目录由更高版本创建，当前版本不会覆盖。请使用创建该目录的新版客户端。',
              'The directory uses a newer schema. It will not be overwritten. Use a newer client.');
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _server = null;
          _online.clear();
          _onlineObserved.clear();
          _error = nikoText('无法读取私服配置或设备目录。请检查本地文件权限后重试。',
              'Cannot read server settings or the device directory. Check local file permissions and retry.');
        });
      }
    } finally {
      _refreshing = false;
    }
  }

  bool get _canConnect =>
      _error == null &&
      (!_native ||
          (_store.serverNamespace != null &&
              _server?.namespace == _store.serverNamespace)) &&
      _server?.config.isValid == true &&
      _server?.enabled == true &&
      !_connecting;

  /// NikoDesk controller policy: no session is dispatched without a
  /// typed password or an authorized secure credential. The remote side
  /// still verifies every session on its own.
  Future<void> _dispatch(String id,
      {required String password,
      required bool fileTransfer,
      required bool forceRelay,
      NikoConnectAuth? auth,
      String? expectedNamespace,
      bool tunnel = false}) async {
    if (_connecting) return;
    final namespace = expectedNamespace ?? _dispatchNamespace;
    final log = widget.sessionLog ??
        SessionLogStore(_store.directory, serverNamespace: namespace);
    final alias = _devices
        .firstWhere((device) => device.id == id,
            orElse: () => DeviceEntry(id: id))
        .alias;
    setState(() => _connecting = true);
    final connToken = namespace == null ? null : auth?.token(namespace);
    final dispatched = await nikoDispatchConnection(context,
        id: id,
        password: password,
        useSavedCredential: auth?.useSaved == true,
        connToken: connToken,
        fileTransfer: fileTransfer,
        forceRelay: forceRelay,
        gateway: _gateway,
        onConnect: tunnel
            ? widget.onTunnelConnect ??
                (ctx, peer, relay, {isFileTransfer = false, password}) =>
                    connect(ctx, peer,
                        forceRelay: relay,
                        password: password,
                        serverNamespace: namespace,
                        isTcpTunneling: true,
                        connToken: connToken)
            : widget.onConnect,
        expectedServerNamespace: namespace,
        credentialStatusLoader: widget.credentialStatusLoader);
    if (mounted) _password.clear();
    // History currently distinguishes control and files only. Do not label
    // a tunnel request as a successful control session.
    if (dispatched && !tunnel)
      await _recordSession(id, fileTransfer, forceRelay, log, alias: alias);
    if (mounted) setState(() => _connecting = false);
  }

  Future<void> _connectHero() async {
    final raw = _temporary.text;
    if (!validDeviceId(raw)) {
      nikoNotice(
          context,
          nikoText('请输入 6–16 位数字设备 ID。',
              'Enter a numeric device ID with 6–16 digits.'));
      return;
    }
    final namespace = _dispatchNamespace;
    NikoConnectAuth? auth;
    if (_credentialNative && namespace != null) {
      if (_password.text.trim().isEmpty) {
        if (_connecting || !_canConnect) return;
        setState(() => _connecting = true);
        auth = await nikoAskCredentialConnect(context, normalizeDeviceId(raw), '',
            namespace: namespace, fileTransfer: _fileTransfer,
            statusLoader: () => _credentialStatus(namespace, normalizeDeviceId(raw)));
        if (!mounted) return;
        setState(() => _connecting = false);
        if (auth == null) return;
      } else {
        auth = NikoConnectAuth(_password.text, remember: _rememberPassword);
      }
    }
    await _dispatch(normalizeDeviceId(raw),
        password: auth?.password ?? _password.text,
        auth: auth,
        expectedNamespace: namespace,
        fileTransfer: _fileTransfer,
        forceRelay: _forceRelay,
        tunnel: _tunnel);
  }

  Future<void> _wake(DeviceEntry device) async {
    final namespace = _store.serverNamespace;
    if (!_canConnect || namespace == null) return;
    final profiles = WakeProfileStore(_store.directory, namespace);
    try {
      final initial = await profiles.load(device.id);
      if (!mounted) return;
      await showWakeOnLan(context,
          title: nikoText('唤醒 ${device.title}', 'Wake ${device.title}'),
          initial: initial,
          save: (profile) => profiles.save(device.id, profile),
          send: WakeSender.local,
          proxies: _native ? NikoWakeTunnelDirectory(namespace) : null,
          proxyLabels: {for (final entry in _devices) entry.id: entry.title},
          connectProxy: _devices.any((entry) => entry.id != device.id)
              ? () => _connectWakeProxy(device, expectedNamespace: namespace)
              : null,
          isCurrent: () async {
            final snapshot = await _gateway.read();
            return mounted &&
                snapshot.enabled &&
                snapshot.namespace == namespace;
          },
          online: _native ? NikoWakeOnlineMonitor(namespace, device.id) : null,
          isOnline: () => _online[device.id] == true);
    } catch (_) {
      if (mounted)
        nikoNotice(
            context,
            nikoText('无法读取唤醒配置，请检查设备目录权限。',
                'Could not read wake settings. Check device-directory permissions.'));
    }
  }

  Future<void> _connectWakeProxy(DeviceEntry target,
      {String? expectedNamespace}) async {
    final namespace = expectedNamespace ?? _store.serverNamespace;
    ServerSnapshot current;
    try {
      current = await _gateway.read();
    } catch (_) {
      if (mounted) {
        nikoNotice(
            context,
            nikoText('无法核验当前私服，请更新设备列表后重试。',
                'Could not verify the private server. Refresh Devices and retry.'));
      }
      return;
    }
    if (!mounted) return;
    if (namespace == null ||
        current.namespace != namespace ||
        !current.enabled) {
      nikoNotice(
          context,
          nikoText('私服已变化，请从当前设备列表重新选择代理。',
              'The private server changed. Choose the proxy again from the current device list.'));
      return;
    }
    if (!mounted || !_canConnect) return;
    final candidates =
        _devices.where((device) => device.id != target.id).toList();
    final proxy = await showDialog<DeviceEntry>(
        context: context,
        builder: (dialog) => AlertDialog(
                title: Text(
                    nikoText('选择同网段常开设备', 'Choose an always-on LAN device')),
                content: SizedBox(
                    width: 440,
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Text(nikoText(
                          '先在这台设备的设置中启用唤醒代理，并添加目标网卡。连接后点击“请求唤醒代理”，由对方批准。',
                          'Enable the wake proxy in that device’s settings and add the target NIC. After connecting, select “Request wake proxy” for remote approval.')),
                      const SizedBox(height: 12),
                      Flexible(
                          child: ListView(shrinkWrap: true, children: [
                        for (final device in candidates)
                          ListTile(
                              title: Text(device.title),
                              subtitle: Text(device.id),
                              onTap: () => Navigator.pop(dialog, device))
                      ])),
                    ])),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(dialog),
                      child: Text(nikoText('取消', 'Cancel')))
                ]));
    if (proxy != null && mounted)
      await _connectWithDialog(proxy,
          tunnel: true, expectedNamespace: namespace);
  }

  Future<void> _forgetCredential(DeviceEntry device) async {
    final namespace = _store.serverNamespace;
    if (!_native || namespace == null) return;
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
                title: Text(nikoText('忘记已保存密码', 'Forget saved password')),
                content: Text(nikoText(
                    '从本机系统安全存储移除 ${device.title} 的密码。当前已建立的会话可以继续使用。',
                    'Remove the password for ${device.title} from this device’s secure storage. Existing sessions can continue.')),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(dialog, false),
                      child: Text(nikoText('取消', 'Cancel'))),
                  TextButton(
                      onPressed: () => Navigator.pop(dialog, true),
                      child: Text(nikoText('忘记密码', 'Forget password'))),
                ]));
    if (confirmed != true || !mounted) return;
    try {
      await bind.mainForgetPassword(
          id: nikoCredentialSelector(namespace, device.id));
      final status = await nikoCredentialStatus(namespace, device.id);
      if (!mounted) return;
      nikoNotice(
          context,
          status == 'missing'
              ? nikoText(
                  '已移除本机保存的密码。', 'The locally saved password was removed.')
              : nikoText('移除未确认，请检查系统安全存储后重试。',
                  'Removal was not confirmed. Check secure storage and retry.'));
    } catch (_) {
      if (mounted)
        nikoNotice(
            context,
            nikoText('无法确认密码是否已移除，请重试。',
                'Could not confirm password removal. Retry.'));
    }
  }

  /// Card actions and history reconnects always go through the password
  /// dialog; nothing connects with an id alone.
  Future<void> _connectWithDialog(DeviceEntry device,
      {bool fileTransfer = false,
      bool tunnel = false,
      String? expectedNamespace}) async {
    if (!_canConnect) {
      nikoNotice(context,
          nikoText('私服未就绪，无法发起连接。', 'The private server is not ready.'));
      return;
    }
    final namespace = expectedNamespace ?? _store.serverNamespace;
    setState(() => _connecting = true);
    final auth = await nikoAskCredentialConnect(
        context, device.id, device.alias,
        namespace: namespace ?? '',
        native: _credentialNative,
        statusLoader: () => _credentialStatus(namespace ?? '', device.id),
        fileTransfer: fileTransfer);
    if (!mounted) return;
    setState(() => _connecting = false);
    if (auth == null) return;
    await _dispatch(device.id,
        password: auth.password,
        auth: auth,
        expectedNamespace: namespace,
        fileTransfer: fileTransfer,
        forceRelay: device.forceRelay,
        tunnel: tunnel);
  }

  Future<void> _recordSession(
      String id, bool fileTransfer, bool forceRelay, SessionLogStore log,
      {String? alias}) async {
    // Locally record what this client initiated. This says nothing about
    // remote-side acceptance, which every session verifies on its own.
    if (!_native && widget.sessionLog == null) return;
    try {
      await log.record(SessionLogEntry(
          id: id,
          alias: alias ??
              _devices
                  .firstWhere((d) => d.id == id,
                      orElse: () => DeviceEntry(id: id))
                  .alias,
          fileTransfer: fileTransfer,
          forceRelay: forceRelay,
          startedAt: DateTime.now().toUtc()));
    } catch (_) {
      // History is a convenience; a failed record never blocks a session.
    }
  }

  Future<void> _edit([DeviceEntry? device]) async {
    final result = await showDialog<DeviceEntry>(
        context: context, builder: (_) => _DeviceDialog(device: device));
    if (result == null || !mounted) return;
    try {
      await _store.save(result);
      await _refresh();
    } catch (_) {
      if (mounted) {
        nikoNotice(
            context,
            nikoText('保存失败，原设备目录未被替换。请检查文件权限。',
                'Save failed. The existing directory was preserved. Check file permissions.'));
      }
    }
  }

  Future<void> _importUnscoped() async {
    final target = _store;
    final log = widget.sessionLog ??
        SessionLogStore(target.directory, serverNamespace: target.serverNamespace);
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
              title:
                  Text(nikoText('关联旧的本地数据', 'Associate previous local data')),
              content: Text(nikoText(
                  '旧设备和发起记录没有私服身份。请确认其中的设备属于当前私服，再导入。已有同 ID 设备优先保留；原文件不会删除。旧画面偏好不会自动导入。',
                  'Previous devices and initiation records have no server identity. Confirm that they belong to the current server before importing. Existing devices take precedence and source files are kept. Previous display preferences are not imported automatically.')),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(dialog, false),
                    child: Text(nikoText('取消', 'Cancel'))),
                NikoPrimaryButton(
                    compact: true,
                    onPressed: () => Navigator.pop(dialog, true),
                    child:
                        Text(nikoText('导入到当前私服', 'Import to current server'))),
              ],
            ));
    if (confirmed != true || !mounted) return;
    try {
      final current = await _gateway.read();
      if (!mounted ||
          current.namespace == null ||
          current.namespace != target.serverNamespace) {
        throw StateError('Server identity changed before import');
      }
      final devices = await target.importUnscoped(DeviceStore.privateDirectory);
      final sessions = await log.importUnscoped(DeviceStore.privateDirectory);
      if (!mounted) return;
      setState(() => _notice = nikoText(
          '已导入 $devices 个设备、$sessions 条发起记录。原文件已保留。',
          'Imported $devices devices and $sessions initiation records. Source files were kept.'));
      await _refresh();
    } catch (_) {
      if (mounted) {
        nikoNotice(
            context,
            nikoText('导入未完成。已导入的数据会保留，请核对私服身份和原文件后重试。',
                'Import did not finish. Imported data is kept. Check the server identity and source files, then retry.'));
      }
    }
  }

  Future<void> _configure() async {
    final saved = await showNikoServerSettings(context, _gateway,
        _server?.config ?? const PrivateServerConfig('', '', ''));
    if (saved == true) await _refresh();
  }

  Future<void> _favorite(DeviceEntry device) async {
    try {
      await _store.toggleFavorite(device.id);
      await _refresh();
    } catch (_) {
      if (mounted) {
        nikoNotice(
            context,
            nikoText('无法保存收藏，请检查目录权限。',
                'Could not save favorite. Check directory permissions.'));
      }
    }
  }

  Future<void> _remove(DeviceEntry device) async {
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
              title: Text(nikoText('移除设备', 'Remove device')),
              content: Text(nikoText('仅从本地目录移除「${device.title}」，不会修改远端设备。',
                  'Remove “${device.title}” from this local directory. The remote device is unchanged.')),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: Text(nikoText('取消', 'Cancel'))),
                TextButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: Text(nikoText('移除', 'Remove')))
              ],
            ));
    if (confirmed != true) return;
    try {
      await _store.remove(device.id);
      await _refresh();
    } catch (_) {
      if (mounted) {
        nikoNotice(
            context, nikoText('移除失败，请重试。', 'Remove failed. Please retry.'));
      }
    }
  }

  String _registration() {
    if (_server == null) return nikoText('状态未知', 'Status unknown');
    if (widget.controllerOnly) {
      return _server?.enabled == true
          ? nikoText('控制端配置已启用', 'Controller configuration enabled')
          : nikoText('控制端配置已暂停', 'Controller configuration paused');
    }
    if (_server?.enabled != true) {
      return nikoText('注册服务已停止', 'Registration stopped');
    }
    switch (_server?.registrationStatus) {
      case 1:
        return nikoText('已注册', 'Registered');
      case 0:
        return nikoText('正在注册', 'Registering');
      case -1:
        return nikoText('注册未就绪', 'Registration not ready');
      default:
        return nikoText('注册状态未知', 'Registration unknown');
    }
  }

  @override
  Widget build(BuildContext context) {
    final query = _search.text.trim().toLowerCase();
    final filtered = _devices
        .where((device) =>
            (_filter != 'favorites' || device.favorite) &&
            (_filter != 'recent' || device.lastConnectedAt != null) &&
            '${device.id} ${device.alias} ${device.group}'
                .toLowerCase()
                .contains(query))
        .toList();
    filtered.sort((a, b) {
      if (_filter == 'recent') {
        return (b.lastConnectedAt ?? DateTime(1970))
            .compareTo(a.lastConnectedAt ?? DateTime(1970));
      }
      if (a.favorite != b.favorite) return a.favorite ? -1 : 1;
      final recent = (b.lastConnectedAt ?? DateTime(1970))
          .compareTo(a.lastConnectedAt ?? DateTime(1970));
      if (recent != 0) return recent;
      return a.title.toLowerCase().compareTo(b.title.toLowerCase());
    });
    return FocusTraversalGroup(
        child: LayoutBuilder(
            builder: (context, constraints) => SingleChildScrollView(
                  padding: EdgeInsets.all(
                      constraints.maxWidth < 520 ? 16 : NikoTokens.pagePadding),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Wrap(
                            alignment: WrapAlignment.spaceBetween,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            spacing: 12,
                            runSpacing: 12,
                            children: [
                              Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(nikoText('我的设备', 'My devices'),
                                        style: (constraints.maxWidth < 520
                                                ? Theme.of(context)
                                                    .textTheme
                                                    .titleLarge
                                                : Theme.of(context)
                                                    .textTheme
                                                    .headlineMedium)
                                            ?.copyWith(
                                                fontWeight: FontWeight.w700)),
                                    if (_devices.isEmpty ||
                                        _server?.config.isValid != true) ...[
                                      const SizedBox(height: 6),
                                      Text(
                                          nikoText('自己的服务器，熟悉的工作空间。',
                                              'Your server. Your workspace.'),
                                          style: TextStyle(
                                              color: _muted(context))),
                                    ],
                                  ]),
                              Wrap(
                                  spacing: 8,
                                  crossAxisAlignment: WrapCrossAlignment.center,
                                  children: [
                                    IconButton(
                                        tooltip: nikoText('设置', 'Settings'),
                                        onPressed: widget.onOpenSettings,
                                        icon: Icon(Icons.tune_rounded,
                                            color: _muted(context))),
                                    NikoPrimaryButton(
                                        compact: true,
                                        onPressed: _error != null
                                            ? null
                                            : () => _edit(),
                                        child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              const Icon(Icons.add, size: 17),
                                              const SizedBox(width: 5),
                                              Flexible(
                                                  child: Text(constraints
                                                              .maxWidth <
                                                          520
                                                      ? nikoText('添加', 'Add')
                                                      : nikoText('添加设备',
                                                          'Add device'))),
                                            ])),
                                  ]),
                            ]),
                        const SizedBox(height: 22),
                        if (_devices.isEmpty || _server?.config.isValid != true)
                          _hero(context, constraints)
                        else
                          NikoGlassCard(
                              padding: EdgeInsets.zero,
                              child: ExpansionTile(
                                  key: const Key('nikodesk-quick-connect'),
                                  title: Text(nikoText('快速连接', 'Quick connect'),
                                      key: const Key(
                                          'nikodesk-quick-connect-toggle')),
                                  subtitle: Text(_registration()),
                                  maintainState: true,
                                  onExpansionChanged: (expanded) {
                                    setState(() => _quickExpanded = expanded);
                                    if (!expanded) _password.clear();
                                  },
                                  children: [
                                    ExcludeFocus(
                                        excluding: !_quickExpanded,
                                        child: _hero(context, constraints))
                                  ])),
                        if (_legacyAvailable)
                          Align(
                              alignment: Alignment.centerLeft,
                              child: TextButton.icon(
                                  onPressed: _importUnscoped,
                                  icon: const Icon(Icons.folder_open_rounded),
                                  label: Text(nikoText('关联旧的本地数据',
                                      'Associate previous local data')))),
                        if (_notice != null)
                          Padding(
                              padding: const EdgeInsets.only(top: 14),
                              child: Text(_notice!,
                                  style: TextStyle(color: _muted(context)))),
                        if (_error != null)
                          Padding(
                              padding: const EdgeInsets.only(top: 14),
                              child: NikoGlassCard(
                                  child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                    Text(_error!,
                                        style: TextStyle(
                                            color: Theme.of(context)
                                                .colorScheme
                                                .error)),
                                    TextButton(
                                        onPressed: _refresh,
                                        child: Text(nikoText('重试', 'Retry'))),
                                  ]))),
                        const SizedBox(height: 20),
                        Row(children: [
                          Expanded(
                              child: TextField(
                                  key: const Key('nikodesk-search'),
                                  controller: _search,
                                  onChanged: (_) => setState(() {}),
                                  decoration: nikoInput(
                                          nikoText('搜索设备', 'Search devices'),
                                          hint: nikoText('别名、设备 ID 或分组',
                                              'Alias, device ID or group'))
                                      .copyWith(
                                          prefixIcon: Icon(Icons.search,
                                              size: 19,
                                              color: _muted(context))))),
                        ]),
                        const SizedBox(height: 10),
                        Wrap(spacing: 8, runSpacing: 8, children: [
                          for (final filter in ['all', 'favorites', 'recent'])
                            ChoiceChip(
                                showCheckmark: false,
                                tooltip: filter == 'recent'
                                    ? nikoText(
                                        '最近成功连接', 'Recent successful sessions')
                                    : filter == 'favorites'
                                        ? nikoText('收藏', 'Favorites')
                                        : nikoText('全部', 'All'),
                                label: constraints.maxWidth < 360 &&
                                        filter != 'all'
                                    ? Icon(
                                        filter == 'favorites'
                                            ? Icons.star_outline_rounded
                                            : Icons.history_rounded,
                                        size: 18,
                                        semanticLabel: filter == 'favorites'
                                            ? nikoText('收藏', 'Favorites')
                                            : nikoText('最近成功连接',
                                                'Recent successful sessions'))
                                    : ConstrainedBox(
                                        constraints: BoxConstraints(
                                            maxWidth:
                                                constraints.maxWidth - 80),
                                        child: Text(filter == 'all'
                                            ? nikoText('全部', 'All')
                                            : filter == 'favorites'
                                                ? nikoText('收藏', 'Favorites')
                                                : nikoText('最近', 'Recent'))),
                                selected: _filter == filter,
                                onSelected: (_) =>
                                    setState(() => _filter = filter)),
                        ]),
                        const SizedBox(height: 18),
                        if (_loading)
                          const Padding(
                              padding: EdgeInsets.all(32),
                              child: Center(child: CircularProgressIndicator()))
                        else if (filtered.isEmpty)
                          _empty(context)
                        else
                          _grid(context, constraints, filtered),
                        const SizedBox(height: 16),
                        Center(
                            child: TextButton(
                                onPressed: () =>
                                    _setLanguage(!NikoLanguage.english),
                                child: Text(
                                    NikoLanguage.english ? '中文' : 'English',
                                    style: TextStyle(color: _muted(context))))),
                      ]),
                )));
  }

  Widget _hero(BuildContext context, BoxConstraints constraints) {
    final configured = _server?.config.isValid == true;
    final idField = TextField(
        key: const Key('nikodesk-hero-id'),
        controller: _temporary,
        enabled: _canConnect,
        style: nikoIdStyle(context, fontSize: 15),
        keyboardType: TextInputType.number,
        decoration: nikoInput(nikoText('远端设备 ID', 'Remote device ID')));
    final passwordField = TextField(
        key: const Key('nikodesk-hero-password'),
        controller: _password,
        enabled: _canConnect,
        obscureText: true,
        autocorrect: false,
        enableSuggestions: false,
        enableIMEPersonalizedLearning: false,
        decoration: nikoInput(nikoText('远端密码', 'Remote password')),
        onSubmitted: _canConnect ? (_) => _connectHero() : null);
    final connectCard = NikoGlassCard(
        padding: const EdgeInsets.all(20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 12,
              runSpacing: 10,
              children: [
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(nikoText('连接远程设备', 'Connect to a device'),
                      style: Theme.of(context)
                          .textTheme
                          .titleMedium
                          ?.copyWith(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 3),
                  Text(
                      nikoText('输入对方 ID 和密码，由你的私服协调连接。',
                          'Enter the remote ID and password. Your private server coordinates the connection.'),
                      style: TextStyle(fontSize: 12.5, color: _muted(context))),
                ]),
                if (constraints.maxWidth /
                        MediaQuery.textScalerOf(context).scale(1) <
                    600)
                  Wrap(spacing: 8, runSpacing: 8, children: [
                    for (final mode in [0, 1, 2])
                      ChoiceChip(
                          key: Key('nikodesk-connect-mode-$mode'),
                          label: Text(mode == 2
                              ? nikoText('TCP 隧道', 'TCP tunnel')
                              : mode == 1
                                  ? nikoText('文件传输', 'Files')
                                  : nikoText('远程控制', 'Control')),
                          selected: (_tunnel
                                  ? 2
                                  : _fileTransfer
                                      ? 1
                                      : 0) ==
                              mode,
                          onSelected: !_canConnect
                              ? null
                              : (_) => setState(() {
                                    _fileTransfer = mode == 1;
                                    _tunnel = mode == 2;
                                  })),
                  ])
                else
                  SegmentedButton<int>(
                      segments: [
                        ButtonSegment(
                            value: 0,
                            icon: const Icon(Icons.desktop_windows_rounded,
                                size: 16),
                            label: Text(nikoText('远程控制', 'Control'))),
                        ButtonSegment(
                            value: 1,
                            icon: const Icon(Icons.folder_rounded, size: 16),
                            label: Text(nikoText('文件传输', 'Files'))),
                        ButtonSegment(
                            value: 2,
                            icon: const Icon(Icons.hub_outlined, size: 16),
                            label: Text(nikoText('TCP 隧道', 'TCP tunnel'))),
                      ],
                      selected: {
                        _tunnel
                            ? 2
                            : _fileTransfer
                                ? 1
                                : 0
                      },
                      onSelectionChanged: !_canConnect
                          ? null
                          : (selection) => setState(() {
                                _fileTransfer = selection.first == 1;
                                _tunnel = selection.first == 2;
                              }),
                      showSelectedIcon: false),
              ]),
          const SizedBox(height: 14),
          ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 680),
              child: constraints.maxWidth < 520
                  ? Column(children: [
                      idField,
                      const SizedBox(height: 12),
                      passwordField,
                    ])
                  : Row(children: [
                      Expanded(flex: 3, child: idField),
                      const SizedBox(width: 10),
                      Expanded(flex: 2, child: passwordField),
                    ])),
          const SizedBox(height: 12),
          Wrap(
              spacing: 14,
              runSpacing: 10,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                MergeSemantics(
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Switch(
                      value: _forceRelay,
                      onChanged: !_canConnect
                          ? null
                          : (value) => setState(() => _forceRelay = value)),
                  const SizedBox(width: 4),
                  Flexible(
                      child: Text(nikoText('强制私服中继', 'Force private relay'),
                          style: TextStyle(
                              fontSize: 12.5, color: _muted(context)))),
                ])),
                if (_credentialNative && _store.serverNamespace != null)
                  MergeSemantics(child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Checkbox(
                        key: const Key('nikodesk-hero-remember'),
                        value: _rememberPassword,
                        onChanged: !_canConnect
                            ? null
                            : (value) => setState(
                                () => _rememberPassword = value == true)),
                    Flexible(child: Text(nikoText('记住密码', 'Remember password'))),
                  ])),
                NikoPrimaryButton(
                    key: const Key('nikodesk-hero-connect'),
                    onPressed: _canConnect ? _connectHero : null,
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(
                          _tunnel
                              ? Icons.hub_outlined
                              : _fileTransfer
                                  ? Icons.folder_rounded
                                  : Icons.bolt_rounded,
                          size: 17),
                      const SizedBox(width: 6),
                      Flexible(
                          child: Text(nikoText(
                              _tunnel ? '打开隧道' : '连接',
                              _tunnel
                                  ? 'Open tunnel'
                                  : _fileTransfer
                                      ? 'Transfer'
                                      : 'Connect'))),
                    ])),
              ]),
        ]));
    final statusCard = NikoGlassCard(
        padding: const EdgeInsets.all(20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: configured
                        ? NikoPalette.success
                        : NikoPalette.warning)),
            const SizedBox(width: 8),
            Expanded(
                child: Text(
                    configured
                        ? nikoText('私服配置完整', 'Private server configured')
                        : _server == null
                            ? nikoText('私服配置状态未知', 'Server settings unknown')
                            : nikoText('先连接自己的服务器', 'Set up your private server'),
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700))),
          ]),
          const SizedBox(height: 10),
          Text(configured || _server == null
              ? _registration()
              : nikoText('需要 ID 服务器、中继地址与公钥。未配置时无法连接。',
                  'Enter your ID server, relay and public key. Connections are disabled until configured.')),
          const SizedBox(height: 6),
          Text(
              _online.isEmpty
                  ? nikoText('设备在线状态：未知 · 建立会话后再验证认证与加密',
                      'Device availability: unknown · Authentication and encryption are checked per session')
                  : nikoText('设备在线状态来自私服 · 认证与加密逐会话验证',
                      'Availability comes from your server · Auth and encryption are checked per session'),
              style: TextStyle(fontSize: 12, color: _muted(context))),
          const SizedBox(height: 12),
          OutlinedButton(
              onPressed: _configure,
              child: Text(nikoText('配置服务器', 'Configure server'))),
        ]));
    return constraints.maxWidth < 860
        ? Column(children: [
            connectCard,
            const SizedBox(height: 14),
            statusCard,
          ])
        : Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(flex: 5, child: connectCard),
            const SizedBox(width: 14),
            Expanded(flex: 3, child: statusCard),
          ]);
  }

  Widget _empty(BuildContext context) => NikoGlassCard(
      padding: const EdgeInsets.all(36),
      child: Column(children: [
        Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
                color: nikoIsLight(context) ? NikoPalette.lightAction : null,
                gradient: nikoIsLight(context) ? null : LinearGradient(
                    colors: NikoPalette.deviceAvatarGradient('nikodesk-empty')),
                borderRadius: BorderRadius.circular(NikoShapes.avatar)),
            child: const Icon(Icons.devices_rounded,
                color: Colors.white, size: 28)),
        const SizedBox(height: 16),
        Text(
            _devices.isEmpty
                ? nikoText('把常用电脑放在这里', 'Keep your computers here')
                : nikoText('没有匹配的设备', 'No matching devices'),
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        Text(
            _devices.isEmpty
                ? nikoText('添加设备 ID 和别名。默认不保存密码；连接时可选择在认证成功后保存到本机系统安全存储。',
                    'Add a device ID and alias. Passwords are not saved by default; when connecting, you can choose to save them to this device’s secure storage after authentication succeeds.')
                : nikoText('试试其他关键词或筛选条件。', 'Try another search or filter.'),
            textAlign: TextAlign.center,
            style: TextStyle(color: _muted(context), fontSize: 12.5)),
      ]));

  Widget _grid(BuildContext context, BoxConstraints constraints,
      List<DeviceEntry> devices) {
    final available = constraints.maxWidth -
        2 * (constraints.maxWidth < 520 ? 16 : NikoTokens.pagePadding);
    final scale = MediaQuery.textScalerOf(context).scale(1);
    final columns =
        (available / (320 * scale.clamp(1, 1.5))).clamp(1, 4).toInt();
    final cardWidth = (available - 14 * (columns - 1)) / columns;
    return Wrap(spacing: 14, runSpacing: 14, children: [
      for (final device in devices)
        SizedBox(
            width: cardWidth,
            child: NikoGlassCard(
                padding: const EdgeInsets.all(16),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        Container(
                            width: 42,
                            height: 42,
                            decoration: BoxDecoration(
                                color: nikoIsLight(context) ? NikoPalette.lightAction : null,
                                gradient: nikoIsLight(context) ? null : LinearGradient(
                                    begin: Alignment.topLeft,
                                    end: Alignment.bottomRight,
                                    colors: NikoPalette.deviceAvatarGradient(
                                        device.id)),
                                borderRadius:
                                    BorderRadius.circular(NikoShapes.avatar)),
                            child: const Icon(Icons.desktop_mac_rounded,
                                color: Colors.white, size: 21)),
                        const SizedBox(width: 12),
                        Expanded(
                            child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                              Text(device.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context)
                                      .textTheme
                                      .titleSmall
                                      ?.copyWith(fontWeight: FontWeight.w700)),
                              const SizedBox(height: 2),
                              Text(device.id,
                                  style: nikoIdStyle(context,
                                      fontSize: 12.5, color: _muted(context))),
                            ])),
                        _StarButton(
                            favorite: device.favorite,
                            color: Theme.of(context).colorScheme.primary,
                            onTap: () => _favorite(device)),
                      ]),
                      const SizedBox(height: 12),
                      Wrap(
                          spacing: 8,
                          runSpacing: 6,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            if (device.group.isNotEmpty)
                              Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 8, vertical: 3),
                                  decoration: BoxDecoration(
                                      color: _muted(context).withOpacity(.1),
                                      borderRadius: BorderRadius.circular(6)),
                                  child: Text(device.group,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                          fontSize: 10.5,
                                          fontWeight: FontWeight.w600,
                                          color: _muted(context)))),
                            _OnlineDot(state: _online[device.id], dense: true),
                            if (device.lastConnectedAt != null)
                              Text(
                                  '${nikoText('上次连接', 'Last session')}: ${_date(device.lastConnectedAt!)}',
                                  style: TextStyle(
                                      fontSize: 10.5, color: _muted(context))),
                          ]),
                      const SizedBox(height: 12),
                      Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            NikoPrimaryButton(
                                key:
                                    Key('nikodesk-device-connect-${device.id}'),
                                compact: true,
                                onPressed: _canConnect
                                    ? () => _connectWithDialog(device)
                                    : null,
                                child: Text(nikoText('连接', 'Connect'))),
                            _IconAction(
                                tooltip: nikoText('文件传输', 'File transfer'),
                                icon: Icons.folder_outlined,
                                onTap: _canConnect
                                    ? () => _connectWithDialog(device,
                                        fileTransfer: true)
                                    : null),
                            _IconAction(
                                tooltip: nikoText('编辑', 'Edit'),
                                icon: Icons.edit_outlined,
                                onTap: () => _edit(device)),
                            PopupMenuButton<String>(
                                tooltip: nikoText('更多', 'More'),
                                color: nikoIsLight(context)
                                    ? NikoPalette.lightField
                                    : NikoPalette.darkCard,
                                onSelected: (value) => value == 'tunnel'
                                    ? _connectWithDialog(device, tunnel: true)
                                    : value == 'wake'
                                        ? _wake(device)
                                        : value == 'forget'
                                            ? _forgetCredential(device)
                                            : value == 'edit'
                                                ? _edit(device)
                                                : _remove(device),
                                itemBuilder: (_) => [
                                      PopupMenuItem(
                                          value: 'wake',
                                          enabled: _canConnect &&
                                              _online[device.id] != true,
                                          child: Text(
                                              nikoText('远程开机', 'Wake-on-LAN'))),
                                      PopupMenuItem(
                                          value: 'tunnel',
                                          enabled: _canConnect,
                                          child: Text(nikoText(
                                              'TCP 隧道', 'TCP tunnel'))),
                                      if (_native)
                                        PopupMenuItem(
                                            value: 'forget',
                                            enabled: _canConnect,
                                            child: Text(nikoText('忘记已保存密码',
                                                'Forget saved password'))),
                                      PopupMenuItem(
                                          value: 'edit',
                                          child: Text(nikoText('编辑', 'Edit'))),
                                      PopupMenuItem(
                                          value: 'remove',
                                          child:
                                              Text(nikoText('移除', 'Remove'))),
                                    ]),
                          ]),
                    ]))),
    ]);
  }

  Color _muted(BuildContext context) =>
      nikoIsLight(context) ? NikoPalette.lightMuted : NikoPalette.darkMuted;

  String _date(DateTime date) {
    final local = date.toLocal();
    return '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')} ${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  }
}

class _StarButton extends StatelessWidget {
  final bool favorite;
  final Color color;
  final VoidCallback onTap;
  const _StarButton(
      {required this.favorite, required this.color, required this.onTap});

  @override
  Widget build(BuildContext context) => Semantics(
      toggled: favorite,
      child: IconButton(
          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
          visualDensity: VisualDensity.standard,
          tooltip: favorite
              ? nikoText('取消收藏', 'Remove favorite')
              : nikoText('收藏', 'Favorite'),
          onPressed: onTap,
          icon: Icon(favorite ? Icons.star_rounded : Icons.star_outline_rounded,
              size: 20, color: favorite ? NikoPalette.warning : null)));
}

class _IconAction extends StatelessWidget {
  final String tooltip;
  final IconData icon;
  final VoidCallback? onTap;
  const _IconAction(
      {required this.tooltip, required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final light = nikoIsLight(context);
    return IconButton(
        constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
        visualDensity: VisualDensity.standard,
        tooltip: tooltip,
        onPressed: onTap,
        icon: Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: light
                  ? NikoPalette.lightField
                  : const Color(0xFF232A38),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Icon(icon,
                size: 16,
                color: light ? NikoPalette.lightSeed : NikoPalette.darkSeed)));
  }
}

/// Online pill: green 在线 / gray 离线 / amber 在线未知. "Unknown" stays a
/// first-class state so presence is never overstated.
class _OnlineDot extends StatelessWidget {
  final bool? state;
  final bool dense;
  const _OnlineDot({required this.state, this.dense = false});

  @override
  Widget build(BuildContext context) {
    final Color color;
    final String label;
    if (state == true) {
      color = NikoPalette.success;
      label = nikoText('在线', 'Online');
    } else if (state == false) {
      color = const Color(0xFF9CA3AF);
      label = nikoText('离线', 'Offline');
    } else {
      color = NikoPalette.warning;
      label = nikoText('在线未知', 'Availability unknown');
    }
    final foreground = !nikoIsLight(context)
        ? color
        : state == true
            ? NikoPalette.lightSuccessText
            : state == false
                ? NikoPalette.lightOfflineText
                : NikoPalette.lightWarningText;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(shape: BoxShape.circle, color: color)),
      const SizedBox(width: 5),
      Flexible(
          child: Text(label,
              style: TextStyle(
                  fontSize: dense ? 10.5 : 11,
                  fontWeight: FontWeight.w600,
                  color: foreground))),
    ]);
  }
}

class _DeviceDialog extends StatefulWidget {
  final DeviceEntry? device;
  const _DeviceDialog({this.device});
  @override
  State<_DeviceDialog> createState() => _DeviceDialogState();
}

class _DeviceDialogState extends State<_DeviceDialog> {
  final _form = GlobalKey<FormState>();
  late final _id = TextEditingController(text: widget.device?.id);
  late final _alias = TextEditingController(text: widget.device?.alias);
  late final _group = TextEditingController(text: widget.device?.group);
  late bool _relay = widget.device?.forceRelay ?? false;
  @override
  void dispose() {
    _id.dispose();
    _alias.dispose();
    _group.dispose();
    super.dispose();
  }

  void _save() {
    if (!_form.currentState!.validate()) return;
    final original = widget.device;
    Navigator.of(context).pop(original == null
        ? DeviceEntry(
            id: normalizeDeviceId(_id.text),
            alias: _alias.text.trim(),
            group: _group.text.trim(),
            forceRelay: _relay)
        : original.copyWith(
            alias: _alias.text.trim(),
            group: _group.text.trim(),
            forceRelay: _relay));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.device == null
            ? nikoText('添加设备', 'Add device')
            : nikoText('编辑设备', 'Edit device')),
        content: SizedBox(
            width: 440,
            child: SingleChildScrollView(
                child: Form(
                    key: _form,
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      TextFormField(
                          controller: _id,
                          enabled: widget.device == null,
                          autofocus: widget.device == null,
                          decoration: nikoInput(nikoText('设备 ID', 'Device ID')),
                          maxLength: 16,
                          validator: (value) => validDeviceId(value!)
                              ? null
                              : nikoText('仅支持 6–16 位数字设备 ID。',
                                  'Use a numeric device ID with 6–16 digits.')),
                      const SizedBox(height: 12),
                      TextFormField(
                          controller: _alias,
                          decoration: nikoInput(nikoText('别名', 'Alias')),
                          maxLength: 100),
                      const SizedBox(height: 12),
                      TextFormField(
                          controller: _group,
                          decoration: nikoInput(nikoText('分组', 'Group')),
                          maxLength: 60,
                          onFieldSubmitted: (_) => _save()),
                      CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          value: _relay,
                          onChanged: (value) => setState(() => _relay = value!),
                          title:
                              Text(nikoText('优先使用私服中继', 'Force private relay')),
                          subtitle: Text(nikoText('否则由核心协商直连或中继',
                              'Otherwise the core negotiates direct or relay'))),
                    ])))),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(nikoText('取消', 'Cancel'))),
          FilledButton(onPressed: _save, child: Text(nikoText('保存', 'Save')))
        ],
      );
}
