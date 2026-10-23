import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/models/platform_model.dart';

import 'connect_dialog.dart';
import 'credential_connect_dialog.dart';
import 'device_store.dart';
import 'home_board.dart';
import 'home_chrome.dart';
import 'nightline.dart';
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

  /// State shared with the home chrome; the page keeps its own otherwise.
  final NikoDeviceBoard? board;

  /// This computer's ID and access panel, shown in the inspector while no
  /// device is selected.
  final Widget? localPanel;
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
      this.credentialStatusLoader,
      this.board,
      this.localPanel});
  @override
  State<NikoDevicePage> createState() => _NikoDevicePageState();
}

class _NikoDevicePageState extends State<NikoDevicePage>
    with SingleTickerProviderStateMixin {
  late final _store = widget.store ?? DeviceStore.instance;
  late final _gateway = widget.gateway ?? NativeServerGateway();
  final _search = TextEditingController();
  final _temporary = TextEditingController();
  final _password = TextEditingController();
  final _idFocus = FocusNode();
  final _searchFocus = FocusNode();
  final _scroll = ScrollController();
  late final NikoDeviceBoard _board = widget.board ?? NikoDeviceBoard();
  late final AnimationController _floating;
  bool _inspectorOpen = true;
  List<DeviceEntry> _devices = [];
  ServerSnapshot? _server;
  String? _error;
  String? _notice;
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
    _floating = AnimationController(vsync: this, duration: NlMotion.slow);
    _board.addListener(_boardChanged);
    _board.attach(this,
        quickConnect: _quickConnectRequested,
        addDevice: () {
          if (_error == null) _edit();
        },
        connect: (id, {fileTransfer = false}) {
          for (final device in _devices) {
            if (device.id == id) {
              _connectWithDialog(device, fileTransfer: fileTransfer);
              return;
            }
          }
        },
        focusSearch: () => _searchFocus.requestFocus());
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
        _publish();
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

  void _boardChanged() {
    if (mounted) setState(() {});
  }

  /// Hands the directory summary to the chrome. Called after state changes,
  /// never during a build, because the chrome rebuilds on notification.
  void _publish() =>
      _board.publish(_devices, _online, canConnect: _canConnect);

  @override
  void dispose() {
    _board.removeListener(_boardChanged);
    _board.detach(this);
    if (widget.board == null) _board.dispose();
    _floating.dispose();
    _idFocus.dispose();
    _searchFocus.dispose();
    _scroll.dispose();
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
        _publish();
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
        _publish();
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
    _publish();
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
    if (mounted) {
      setState(() => _connecting = false);
      _publish();
    }
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

  NlLedState _registrationLed() {
    if (_server == null) return NlLedState.off;
    if (widget.controllerOnly) {
      return _server?.enabled == true ? NlLedState.ok : NlLedState.warn;
    }
    if (_server?.enabled != true) return NlLedState.warn;
    return switch (_server?.registrationStatus) {
      1 => NlLedState.ok,
      null => NlLedState.off,
      _ => NlLedState.warn,
    };
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

  // ---- View ----------------------------------------------------------

  bool get _configured => _server?.config.isValid == true;

  /// With no devices or no server the connect form is the page's hero;
  /// otherwise it folds into the quick-connect row above the devices.
  bool get _showHero => _devices.isEmpty || !_configured;

  DeviceEntry? get _selectedDevice {
    final id = _board.selected;
    if (id == null) return null;
    for (final device in _devices) {
      if (device.id == id) return device;
    }
    return null;
  }

  List<DeviceEntry> _visibleDevices() {
    final query = _search.text.trim().toLowerCase();
    final filter = _board.filter;
    final group = filter.startsWith('group:') ? filter.substring(6) : null;
    final visible = _devices
        .where((device) =>
            (filter != 'favorites' || device.favorite) &&
            (filter != 'recent' || device.lastConnectedAt != null) &&
            (group == null || device.group.trim() == group) &&
            '${device.id} ${device.alias} ${device.group}'
                .toLowerCase()
                .contains(query))
        .toList();
    visible.sort((a, b) {
      if (filter == 'recent') {
        return (b.lastConnectedAt ?? DateTime(1970))
            .compareTo(a.lastConnectedAt ?? DateTime(1970));
      }
      if (a.favorite != b.favorite) return a.favorite ? -1 : 1;
      final recent = (b.lastConnectedAt ?? DateTime(1970))
          .compareTo(a.lastConnectedAt ?? DateTime(1970));
      if (recent != 0) return recent;
      return a.title.toLowerCase().compareTo(b.title.toLowerCase());
    });
    return visible;
  }

  void _setQuick(bool expanded, {bool focus = false}) {
    setState(() => _quickExpanded = expanded);
    if (!expanded) _password.clear();
    if (expanded && focus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _canConnect) _idFocus.requestFocus();
      });
    }
  }

  void _quickConnectRequested() {
    if (_scroll.hasClients) {
      _scroll.animateTo(0,
          duration: NlMotion.of(context, NlMotion.slow), curve: NlMotion.ease);
    }
    if (_showHero) {
      if (_canConnect) _idFocus.requestFocus();
    } else {
      _setQuick(true, focus: true);
    }
  }

  void _select(DeviceEntry device) {
    _board.select(_board.selected == device.id ? null : device.id);
  }

  void _closeInspector() {
    _board.select(null);
    if (_floating.value > 0) _floating.reverse();
  }

  void _showMenu(DeviceEntry device, {Offset? at, Rect? anchor}) {
    final online = _online[device.id];
    showNlMenu(context, position: at, anchor: anchor, entries: [
      if (at != null) ...[
        NlMenuItem(
            label: nikoText('远程控制', 'Remote control'),
            icon: NlIcons.monitor,
            enabled: _canConnect,
            onSelected: () => _connectWithDialog(device)),
        NlMenuItem(
            label: nikoText('文件传输', 'File transfer'),
            icon: NlIcons.folder,
            enabled: _canConnect,
            onSelected: () => _connectWithDialog(device, fileTransfer: true)),
      ],
      NlMenuItem(
          label: nikoText('TCP 隧道', 'TCP tunnel'),
          icon: NlIcons.cable,
          enabled: _canConnect,
          onSelected: () => _connectWithDialog(device, tunnel: true)),
      NlMenuItem(
          label: nikoText('远程开机', 'Wake-on-LAN'),
          icon: NlIcons.power,
          enabled: _canConnect && online != true,
          onSelected: () => _wake(device)),
      const NlMenuDivider(),
      NlMenuItem(
          label: device.favorite
              ? nikoText('取消收藏', 'Remove favorite')
              : nikoText('收藏', 'Favorite'),
          icon: NlIcons.star,
          onSelected: () => _favorite(device)),
      NlMenuItem(
          label: nikoText('编辑', 'Edit'),
          icon: NlIcons.pencil,
          onSelected: () => _edit(device)),
      if (_native)
        NlMenuItem(
            label: nikoText('忘记已保存密码', 'Forget saved password'),
            icon: NlIcons.keyRound,
            enabled: _canConnect,
            onSelected: () => _forgetCredential(device)),
      const NlMenuDivider(),
      NlMenuItem(
          label: nikoText('移除', 'Remove'),
          icon: NlIcons.trash2,
          danger: true,
          onSelected: () => _remove(device)),
    ]);
  }

  String _subtitle() {
    if (_showHero) {
      return nikoText('自己的服务器，熟悉的工作空间。', 'Your server. Your workspace.');
    }
    final filter = _board.filter;
    final count = nikoText('${_devices.length} 台设备', '${_devices.length} devices');
    final online = _board.onlineCount;
    final parts = [
      if (filter.startsWith('group:'))
        '${nikoText('分组', 'Group')} · ${filter.substring(6)}'
      else
        count,
      if (_online.isNotEmpty) nikoText('$online 台在线', '$online online'),
    ];
    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    // Pages shown outside the home shell still draw in the design system.
    if (NlColors.maybeOf(context) == null) {
      return Theme(
          data: nightlineTheme(Theme.of(context).brightness),
          child: Builder(builder: _page));
    }
    return _page(context);
  }

  Widget _page(BuildContext context) {
    final nl = NlColors.of(context);
    final devices = _visibleDevices();
    return FocusTraversalGroup(
        child: LayoutBuilder(builder: (context, constraints) {
      final width = constraints.maxWidth;
      final narrow = width < 520;
      final searchInBody = width < 760;
      final side = width < NlLayout.compactMax ? NlSpace.s4 : NlSpace.s6;
      final selected = _selectedDevice;
      final dock = width >= 820;
      final hasInspector = selected != null || widget.localPanel != null;
      final page = NlScrollWatcher(
          header: (context, scrolled) => NikoPageBar(
              title: nikoText('我的设备', 'My devices'),
              subtitle: _subtitle(),
              divider: scrolled,
              actions: _headerActions(context,
                  width: width, dock: dock && hasInspector)),
          child: SingleChildScrollView(
              controller: _scroll,
              padding: EdgeInsets.fromLTRB(side, NlSpace.s2, side, NlSpace.s10),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (searchInBody) ...[
                      _searchField(),
                      const SizedBox(height: NlSpace.s3),
                    ],
                    ..._banners(context),
                    _quickConnect(context, constraints),
                    const SizedBox(height: NlSpace.s6),
                    _filterBar(context, width - 2 * side, narrow: narrow),
                    const SizedBox(height: NlSpace.s3),
                    if (_loading)
                      const Padding(
                          padding: EdgeInsets.all(NlSpace.s8),
                          child: Center(child: NlSpinner(size: 20)))
                    else if (devices.isEmpty)
                      _empty(context)
                    else
                      LayoutBuilder(
                          builder: (context, box) =>
                              _devicesView(context, box.maxWidth, devices)),
                  ])));
      if (dock && hasInspector) {
        return ColoredBox(
            color: nl.bg,
            child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: page),
                  NlSidePanel(
                      open: _inspectorOpen || selected != null,
                      width: 300,
                      child: DecoratedBox(
                          decoration: BoxDecoration(
                              color: nl.bg2,
                              border:
                                  Border(left: BorderSide(color: nl.line))),
                          child: _inspector(context, selected,
                              docked: true))),
                ]));
      }
      return ColoredBox(
          color: nl.bg,
          child: Stack(fit: StackFit.expand, children: [
            page,
            if (hasInspector) _floatingInspector(context, width, selected),
          ]));
    }));
  }

  List<Widget> _headerActions(BuildContext context,
      {required double width, required bool dock}) {
    final add = _error != null ? null : () => _edit();
    return [
      if (width >= 760) SizedBox(width: 220, child: _searchField()),
      if (width >= 520 && _devices.isNotEmpty) _viewToggle(),
      if (width < 640)
        NlIconButton(
            icon: NlIcons.plus,
            tooltip: nikoText('添加设备', 'Add device'),
            onPressed: add)
      else
        NlButton.ghost(
            icon: NlIcons.plus,
            label: nikoText('添加设备', 'Add device'),
            onPressed: add),
      if (widget.localPanel != null)
        dock
            ? NlIconButton(
                icon: NlIcons.panelRight,
                tooltip: _inspectorOpen
                    ? nikoText('隐藏本机信息', 'Hide this computer')
                    : nikoText('显示本机信息', 'Show this computer'),
                active: _inspectorOpen,
                onPressed: () =>
                    setState(() => _inspectorOpen = !_inspectorOpen))
            : NlIconButton(
                icon: NlIcons.monitorSmartphone,
                tooltip: nikoText('本机信息', 'This computer'),
                onPressed: () {
                  _board.select(null);
                  _floating.forward();
                }),
    ];
  }

  Widget _searchField() => NlSearchField(
      fieldKey: const Key('nikodesk-search'),
      controller: _search,
      focusNode: _searchFocus,
      hint: nikoText('搜索设备', 'Search devices'),
      clearLabel: nikoText('清除搜索', 'Clear search'),
      onChanged: (_) => setState(() {}));

  Widget _viewToggle() => NlSegmented<NikoDeviceView>(
          small: true,
          segments: [
            NlSegment(
                value: NikoDeviceView.grid,
                label: nikoText('网格', 'Grid'),
                icon: NlIcons.layoutGrid,
                iconOnly: true),
            NlSegment(
                value: NikoDeviceView.list,
                label: nikoText('列表', 'List'),
                icon: NlIcons.list,
                iconOnly: true),
          ],
          selected: _board.view,
          onChanged: (view) => _board.view = view);

  List<Widget> _banners(BuildContext context) {
    final nl = NlColors.of(context);
    Widget banner(IconData icon, String text,
            {Color? ink, Color? fill, Widget? action}) =>
        Padding(
            padding: const EdgeInsets.only(bottom: NlSpace.s3),
            child: NlPanel(
                color: fill,
                padding: const EdgeInsets.symmetric(
                    horizontal: NlSpace.s4, vertical: NlSpace.s3),
                child: Row(children: [
                  Icon(icon, size: 16, color: ink ?? nl.fg2),
                  const SizedBox(width: NlSpace.s3),
                  Expanded(
                      child: Text(text,
                          style: NlType.text(NlType.s3, color: ink ?? nl.fg2))),
                  if (action != null) ...[
                    const SizedBox(width: NlSpace.s3),
                    action,
                  ],
                ])));
    return [
      if (_error != null)
        banner(NlIcons.circleAlert, _error!,
            ink: nl.dangerText,
            fill: nl.solid(nl.dangerSoft, nl.surface),
            action: NlButton.ghost(
                small: true,
                label: nikoText('重试', 'Retry'),
                onPressed: _refresh)),
      if (_notice != null) banner(NlIcons.info, _notice!),
      if (_legacyAvailable)
        banner(
            NlIcons.folderOpen,
            nikoText('发现旧版本留下的本地设备与记录。',
                'Devices and records from an earlier version were found.'),
            action: NlButton.ghost(
                small: true,
                label: nikoText('关联旧的本地数据', 'Associate previous local data'),
                onPressed: _importUnscoped)),
    ];
  }

  Widget _quickConnect(BuildContext context, BoxConstraints constraints) {
    if (_showHero) return _hero(context, constraints, inline: true);
    final nl = NlColors.of(context);
    return NlPanel(
        padding: EdgeInsets.zero,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          NlPressable(
              key: const Key('nikodesk-quick-connect'),
              onTap: () => _setQuick(!_quickExpanded, focus: !_quickExpanded),
              pressScale: 1,
              builder: (context, states) => AnimatedContainer(
                  duration: NlMotion.of(context, NlMotion.instant),
                  padding: const EdgeInsets.symmetric(
                      horizontal: NlSpace.s4, vertical: NlSpace.s3),
                  decoration: BoxDecoration(
                      color: states.contains(WidgetState.hovered)
                          ? nl.hover
                          : Colors.transparent,
                      borderRadius: BorderRadius.vertical(
                          top: const Radius.circular(NlRadius.r3),
                          bottom: Radius.circular(
                              _quickExpanded ? 0 : NlRadius.r3)),
                      boxShadow: states.contains(WidgetState.focused)
                          ? nl.focusRing
                          : null),
                  child: Row(children: [
                    Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                            color: nl.accentSoft,
                            borderRadius: BorderRadius.circular(NlRadius.r2)),
                        child:
                            Icon(NlIcons.zap, size: 16, color: nl.accentText)),
                    const SizedBox(width: NlSpace.s3),
                    Expanded(
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                          Text(nikoText('快速连接', 'Quick connect'),
                              key: const Key('nikodesk-quick-connect-toggle'),
                              style: NlType.text(NlType.s4,
                                  weight: FontWeight.w600, color: nl.fg)),
                          const SizedBox(height: 2),
                          Row(children: [
                            NlLed(_registrationLed()),
                            const SizedBox(width: NlSpace.s2),
                            Flexible(
                                child: Text(_registration(),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: NlType.text(NlType.s2,
                                        color: nl.fg2))),
                          ]),
                        ])),
                    AnimatedRotation(
                        turns: _quickExpanded ? .5 : 0,
                        duration: NlMotion.of(context, NlMotion.base),
                        curve: NlMotion.ease,
                        child: Icon(NlIcons.chevronDown,
                            size: 16, color: nl.fg3)),
                  ]))),
          ClipRect(
              child: AnimatedSize(
                  duration: NlMotion.of(context, NlMotion.slow),
                  curve: NlMotion.ease,
                  alignment: Alignment.topCenter,
                  child: _quickExpanded
                      ? Container(
                          decoration: BoxDecoration(
                              border: Border(top: BorderSide(color: nl.line))),
                          padding: const EdgeInsets.all(NlSpace.s4),
                          child: _hero(context, constraints, inline: false))
                      : const SizedBox(width: double.infinity))),
        ]));
  }

  /// The connect form and the server state beside it.
  Widget _hero(BuildContext context, BoxConstraints constraints,
      {required bool inline}) {
    final nl = NlColors.of(context);
    final scale = MediaQuery.textScalerOf(context).scale(1);
    final narrow = constraints.maxWidth / scale < 520;
    final mode = _tunnel
        ? 2
        : _fileTransfer
            ? 1
            : 0;
    final idField = NlTextField(
        fieldKey: const Key('nikodesk-hero-id'),
        controller: _temporary,
        focusNode: _idFocus,
        enabled: _canConnect,
        mono: true,
        large: true,
        label: nikoText('远端设备 ID', 'Remote device ID'),
        hint: '123 456 789',
        keyboardType: TextInputType.number,
        textInputAction: TextInputAction.next);
    final passwordField = NlTextField(
        fieldKey: const Key('nikodesk-hero-password'),
        controller: _password,
        enabled: _canConnect,
        obscure: true,
        large: true,
        label: nikoText('远端密码', 'Remote password'),
        revealLabel: nikoText('显示密码', 'Show password'),
        hideLabel: nikoText('隐藏密码', 'Hide password'),
        onSubmitted: _canConnect ? (_) => _connectHero() : null);
    final modes = NlSegmented<int>(
        expand: narrow,
        segments: [
          NlSegment(
              value: 0,
              key: const Key('nikodesk-connect-mode-0'),
              label: nikoText('远程控制', 'Control'),
              icon: NlIcons.monitor),
          NlSegment(
              value: 1,
              key: const Key('nikodesk-connect-mode-1'),
              label: nikoText('文件传输', 'Files'),
              icon: NlIcons.folder),
          NlSegment(
              value: 2,
              key: const Key('nikodesk-connect-mode-2'),
              label: nikoText('TCP 隧道', 'TCP tunnel'),
              icon: NlIcons.cable),
        ],
        selected: mode,
        onChanged: !_canConnect
            ? null
            : (value) => setState(() {
                  _fileTransfer = value == 1;
                  _tunnel = value == 2;
                }));
    final relay = MergeSemantics(
        child: Row(mainAxisSize: MainAxisSize.min, children: [
      NlSwitch(
          value: _forceRelay,
          onChanged: !_canConnect
              ? null
              : (value) => setState(() => _forceRelay = value)),
      const SizedBox(width: NlSpace.s2),
      Flexible(
          child: Text(nikoText('强制私服中继', 'Force private relay'),
              style: NlType.text(NlType.s3, color: nl.fg2))),
    ]));
    final remember = _credentialNative && _store.serverNamespace != null
        ? MergeSemantics(
            child: Row(mainAxisSize: MainAxisSize.min, children: [
            Checkbox(
                key: const Key('nikodesk-hero-remember'),
                value: _rememberPassword,
                onChanged: !_canConnect
                    ? null
                    : (value) =>
                        setState(() => _rememberPassword = value == true)),
            Flexible(
                child: Text(nikoText('记住密码', 'Remember password'),
                    style: NlType.text(NlType.s3, color: nl.fg2))),
          ]))
        : null;
    final connect = NlButton(
        key: const Key('nikodesk-hero-connect'),
        large: true,
        icon: _tunnel
            ? NlIcons.cable
            : _fileTransfer
                ? NlIcons.folder
                : NlIcons.arrowRight,
        label: nikoText(
            _tunnel
                ? '打开隧道'
                : _fileTransfer
                    ? '传输文件'
                    : '连接',
            _tunnel
                ? 'Open tunnel'
                : _fileTransfer
                    ? 'Transfer'
                    : 'Connect'),
        onPressed: _canConnect ? _connectHero : null);
    final form = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (inline) ...[
        Text(nikoText('连接远程设备', 'Connect to a device'),
            style: NlType.text(NlType.s6, weight: FontWeight.w600, color: nl.fg)),
        const SizedBox(height: NlSpace.s1),
        Text(
            nikoText('输入对方 ID 和密码，由你的私服协调连接。',
                'Enter the remote ID and password. Your private server coordinates the connection.'),
            style: NlType.text(NlType.s3, color: nl.fg2)),
        const SizedBox(height: NlSpace.s5),
      ],
      Align(alignment: Alignment.centerLeft, child: modes),
      const SizedBox(height: NlSpace.s4),
      if (narrow) ...[
        idField,
        const SizedBox(height: NlSpace.s3),
        passwordField,
      ] else
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Expanded(flex: 3, child: idField),
          const SizedBox(width: NlSpace.s3),
          Expanded(flex: 2, child: passwordField),
        ]),
      const SizedBox(height: NlSpace.s4),
      Wrap(
          spacing: NlSpace.s5,
          runSpacing: NlSpace.s3,
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Wrap(
                spacing: NlSpace.s5,
                runSpacing: NlSpace.s2,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [relay, if (remember != null) remember]),
            connect,
          ]),
    ]);
    final status = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        NlLed(_configured
            ? NlLedState.ok
            : _server == null
                ? NlLedState.off
                : NlLedState.warn),
        const SizedBox(width: NlSpace.s2),
        Expanded(
            child: Text(
                _configured
                    ? nikoText('私服配置完整', 'Private server configured')
                    : _server == null
                        ? nikoText('私服配置状态未知', 'Server settings unknown')
                        : nikoText('先连接自己的服务器', 'Set up your private server'),
                style: NlType.text(NlType.s4,
                    weight: FontWeight.w600, color: nl.fg))),
      ]),
      const SizedBox(height: NlSpace.s2),
      Text(
          _configured || _server == null
              ? _registration()
              : nikoText('需要 ID 服务器、中继地址与公钥。未配置时无法连接。',
                  'Enter your ID server, relay and public key. Connections are disabled until configured.'),
          style: NlType.text(NlType.s3, color: nl.fg2)),
      const SizedBox(height: NlSpace.s1),
      Text(
          _online.isEmpty
              ? nikoText('设备在线状态：未知 · 建立会话后再验证认证与加密',
                  'Device availability: unknown · Authentication and encryption are checked per session')
              : nikoText('设备在线状态来自私服 · 认证与加密逐会话验证',
                  'Availability comes from your server · Auth and encryption are checked per session'),
          style: NlType.text(NlType.s2, color: nl.fg3)),
      const SizedBox(height: NlSpace.s4),
      NlButton.ghost(
          small: true,
          icon: NlIcons.server,
          label: nikoText('配置服务器', 'Configure server'),
          onPressed: _configure),
    ]);
    final wide = constraints.maxWidth >= 860;
    final body = wide
        ? IntrinsicHeight(
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Expanded(child: form),
            Padding(
                padding: const EdgeInsets.symmetric(horizontal: NlSpace.s6),
                child: VerticalDivider(width: 1, color: nl.line)),
            SizedBox(width: 280, child: status),
          ]))
        : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            form,
            Padding(
                padding: const EdgeInsets.symmetric(vertical: NlSpace.s5),
                child: Divider(height: 1, color: nl.line)),
            status,
          ]);
    if (!inline) return body;
    return NlPanel(
        padding: EdgeInsets.all(narrow ? NlSpace.s4 : NlSpace.s6),
        radius: NlRadius.r4,
        child: body);
  }

  Widget _filterBar(BuildContext context, double width,
      {required bool narrow}) {
    final nl = NlColors.of(context);
    final filter = _board.filter;
    final group = filter.startsWith('group:') ? filter.substring(6) : null;
    final tiny = width < 340;
    return Row(children: [
      Expanded(
          child: Align(
              alignment: Alignment.centerLeft,
              child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
        NlSegmented<String>(
              segments: [
                NlSegment(
                    value: 'all',
                    label: nikoText('全部', 'All'),
                    count: _devices.isEmpty || tiny ? null : '${_devices.length}'),
                NlSegment(
                    value: 'favorites',
                    label: nikoText('收藏', 'Favorites'),
                    icon: NlIcons.star,
                    iconOnly: tiny),
                NlSegment(
                    value: 'recent',
                    label: nikoText('最近', 'Recent'),
                    icon: NlIcons.history,
                    iconOnly: tiny),
              ],
              selected: group == null ? filter : '',
              onChanged: (value) => _board.filter = value),
        if (group != null) ...[
          const SizedBox(width: NlSpace.s2),
          NlChip(
              label: group,
              icon: NlIcons.tag,
              selected: true,
              onChanged: (_) => _board.filter = 'all'),
        ],
      ])))),
      if (narrow && _devices.isNotEmpty) ...[
        const SizedBox(width: NlSpace.s2),
        _viewToggle(),
      ],
      if (!narrow && _online.isNotEmpty) ...[
        const SizedBox(width: NlSpace.s3),
        Text(nikoText('在线状态来自私服', 'Availability from your server'),
            style: NlType.text(NlType.s2, color: nl.fg3)),
      ],
    ]);
  }

  Widget _empty(BuildContext context) {
    final searching = _search.text.trim().isNotEmpty;
    return NlEmptyState(
        compact: true,
        icon: _devices.isEmpty ? NlIcons.monitorSmartphone : NlIcons.search,
        title: _devices.isEmpty
            ? nikoText('把常用电脑放在这里', 'Keep your computers here')
            : nikoText('没有匹配的设备', 'No matching devices'),
        message: _devices.isEmpty
            ? nikoText('添加设备 ID 和别名。默认不保存密码；连接时可选择在认证成功后保存到本机系统安全存储。',
                'Add a device ID and alias. Passwords are not saved by default; when connecting, you can choose to save them to this device’s secure storage after authentication succeeds.')
            : nikoText('试试其他关键词或筛选条件。', 'Try another search or filter.'),
        action: _devices.isEmpty
            ? NlButton(
                icon: NlIcons.plus,
                label: nikoText('添加设备', 'Add device'),
                onPressed: _error != null ? null : () => _edit())
            : searching
                ? NlButton.ghost(
                    label: nikoText('清除搜索', 'Clear search'),
                    onPressed: () => setState(_search.clear))
                : null);
  }

  Widget _devicesView(
      BuildContext context, double width, List<DeviceEntry> devices) {
    final known = devices.any((device) => _online.containsKey(device.id));
    final sections = known
        ? [
            (
              nikoText('在线', 'Online'),
              devices.where((device) => _online[device.id] == true).toList()
            ),
            (
              nikoText('离线', 'Offline'),
              devices.where((device) => _online[device.id] == false).toList()
            ),
            (
              nikoText('状态未知', 'Unknown'),
              devices.where((device) => !_online.containsKey(device.id)).toList()
            ),
          ]
        : [(null, devices)];
    final grid = _board.view == NikoDeviceView.grid;
    return AnimatedSwitcher(
        duration: NlMotion.of(context, NlMotion.base),
        switchInCurve: NlMotion.ease,
        switchOutCurve: NlMotion.exit,
        child: Column(
            key: ValueKey(_board.view),
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final (title, items) in sections)
                if (items.isNotEmpty) ...[
                  if (title != null)
                    NlSectionLabel('$title · ${items.length}',
                        padding: const EdgeInsets.only(
                            top: NlSpace.s2, bottom: NlSpace.s3)),
                  grid ? _grid(context, width, items) : _list(context, items),
                  const SizedBox(height: NlSpace.s4),
                ],
            ]));
  }

  Widget _grid(BuildContext context, double width, List<DeviceEntry> devices) {
    final scale = MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 1.6);
    final minimum = (NlLayout.touch(context) ? 250 : 228) * scale;
    final columns = (width / minimum).floor().clamp(1, 6);
    const gap = NlSpace.s3;
    final cardWidth = (width - gap * (columns - 1)) / columns;
    return Wrap(spacing: gap, runSpacing: gap, children: [
      for (final device in devices)
        SizedBox(
            width: cardWidth,
            child: _DeviceCard(
                device: device,
                online: _online[device.id],
                selected: _board.selected == device.id,
                canConnect: _canConnect,
                lastSession: device.lastConnectedAt == null
                    ? null
                    : _ago(device.lastConnectedAt!),
                onSelect: () => _select(device),
                onConnect: () => _connectWithDialog(device),
                onFiles: () => _connectWithDialog(device, fileTransfer: true),
                onFavorite: () => _favorite(device),
                onMenu: (at, anchor) =>
                    _showMenu(device, at: at, anchor: anchor))),
    ]);
  }

  Widget _list(BuildContext context, List<DeviceEntry> devices) =>
      NlPanel(
          padding: EdgeInsets.zero,
          child: Column(children: [
            for (var i = 0; i < devices.length; i++)
              _DeviceRow(
                  device: devices[i],
                  divider: i > 0,
                  online: _online[devices[i].id],
                  selected: _board.selected == devices[i].id,
                  canConnect: _canConnect,
                  lastSession: devices[i].lastConnectedAt == null
                      ? null
                      : _ago(devices[i].lastConnectedAt!),
                  onSelect: () => _select(devices[i]),
                  onConnect: () => _connectWithDialog(devices[i]),
                  onFiles: () =>
                      _connectWithDialog(devices[i], fileTransfer: true),
                  onFavorite: () => _favorite(devices[i]),
                  onMenu: (at, anchor) =>
                      _showMenu(devices[i], at: at, anchor: anchor)),
          ]));

  Widget _inspector(BuildContext context, DeviceEntry? device,
      {required bool docked}) {
    final nl = NlColors.of(context);
    final child = device == null
        ? Column(
            key: const ValueKey('nikodesk-inspector-local'),
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
                NikoWindowDrag(
                    child: Padding(
                        padding: const EdgeInsets.fromLTRB(
                            NlSpace.s5, NlSpace.s3, NlSpace.s2, 0),
                        child: Row(children: [
                          Expanded(
                              child: Text(nikoText('本机', 'This computer'),
                                  style: NlType.text(NlType.s2,
                                      weight: FontWeight.w500,
                                      color: nl.fg3))),
                          NlIconButton(
                              icon: NlIcons.close,
                              tooltip: nikoText('关闭', 'Close'),
                              onPressed: docked
                                  ? () =>
                                      setState(() => _inspectorOpen = false)
                                  : _closeInspector),
                        ]))),
                Expanded(
                    child: SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(
                            NlSpace.s5, NlSpace.s2, NlSpace.s5, NlSpace.s5),
                        child: widget.localPanel ?? const SizedBox.shrink())),
              ])
        : _DeviceInspector(
            key: ValueKey('nikodesk-inspector-${device.id}'),
            device: device,
            online: _online[device.id],
            canConnect: _canConnect,
            native: _native,
            lastSession:
                device.lastConnectedAt == null ? null : _date(device.lastConnectedAt!),
            onClose: _closeInspector,
            onConnect: () => _connectWithDialog(device),
            onFiles: () => _connectWithDialog(device, fileTransfer: true),
            onTunnel: () => _connectWithDialog(device, tunnel: true),
            onWake: _canConnect && _online[device.id] != true
                ? () => _wake(device)
                : null,
            onFavorite: () => _favorite(device),
            onEdit: () => _edit(device),
            onForget: () => _forgetCredential(device),
            onRemove: () => _remove(device),
            onCopy: () {
              Clipboard.setData(ClipboardData(text: device.id));
              nikoNotice(
                  context, nikoText('已复制设备 ID', 'Device ID copied'));
            });
    return AnimatedSwitcher(
        duration: NlMotion.of(context, NlMotion.base),
        switchInCurve: NlMotion.ease,
        switchOutCurve: NlMotion.exit,
        layoutBuilder: (current, previous) => Stack(
            fit: StackFit.expand,
            children: [...previous, if (current != null) current]),
        transitionBuilder: (child, animation) => FadeTransition(
            opacity: animation,
            child: SlideTransition(
                position: Tween(begin: const Offset(.03, 0), end: Offset.zero)
                    .animate(animation),
                child: child)),
        child: child);
  }

  /// The inspector over the page on windows too narrow to dock it.
  Widget _floatingInspector(
      BuildContext context, double width, DeviceEntry? device) {
    final nl = NlColors.of(context);
    final panel = (width - NlSpace.s8).clamp(280.0, 360.0);
    return AnimatedBuilder(
        animation: _floating,
        builder: (context, _) {
          final t = NlMotion.ease.transform(_floating.value);
          if (_floating.value == 0) return const SizedBox.shrink();
          return Stack(children: [
            Positioned.fill(
                child: GestureDetector(
                    onTap: _closeInspector,
                    child: ColoredBox(
                        color: nl.scrim.withOpacity(nl.scrim.opacity * t)))),
            Positioned(
                top: NlSpace.s2,
                bottom: NlSpace.s2,
                right: NlSpace.s2 - (panel + NlSpace.s4) * (1 - t),
                width: panel,
                child: Container(
                    clipBehavior: Clip.antiAlias,
                    decoration: BoxDecoration(
                        color: nl.bg2,
                        borderRadius: BorderRadius.circular(NlRadius.r4),
                        border: Border.all(color: nl.line),
                        boxShadow: nl.shadow3),
                    child: _inspector(context, device, docked: false))),
          ]);
        });
  }

  String _date(DateTime date) {
    final local = date.toLocal();
    return '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')} ${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  }

  String _ago(DateTime date) {
    final elapsed = DateTime.now().difference(date.toLocal());
    if (elapsed.inMinutes < 1) return nikoText('刚刚', 'Just now');
    if (elapsed.inHours < 1) {
      return nikoText('${elapsed.inMinutes} 分钟前', '${elapsed.inMinutes} min ago');
    }
    if (elapsed.inDays < 1) {
      return nikoText('${elapsed.inHours} 小时前', '${elapsed.inHours} h ago');
    }
    if (elapsed.inDays < 7) {
      return nikoText('${elapsed.inDays} 天前', '${elapsed.inDays} d ago');
    }
    final local = date.toLocal();
    return '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')}';
  }
}

/// Online state as a dot and a word: green 在线, grey 离线, and a hollow
/// ring for 在线未知. "Unknown" stays a first-class state so presence is
/// never overstated, but it is not a warning either.
class _Presence extends StatelessWidget {
  final bool? online;
  final String? detail;
  const _Presence({required this.online, this.detail});

  @override
  Widget build(BuildContext context) {
    final nl = NlColors.of(context);
    final (Color ink, String label) = switch (online) {
      true => (nl.okText, nikoText('在线', 'Online')),
      false => (nl.fg2, nikoText('离线', 'Offline')),
      null => (nl.fg3, nikoText('在线未知', 'Unknown')),
    };
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: switch (online) {
                true => nl.ok,
                false => nl.fg3,
                null => Colors.transparent,
              },
              border: online == null
                  ? Border.all(color: nl.fg3, width: 1.2)
                  : null)),
      const SizedBox(width: 6),
      Flexible(
          child: Text(label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: NlType.text(NlType.s2,
                  weight: online == true ? FontWeight.w500 : FontWeight.w400,
                  color: ink))),
      if (detail != null)
        Flexible(
            child: Text(' · $detail',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: NlType.text(NlType.s2, color: nl.fg3))),
    ]);
  }
}

class _Star extends StatelessWidget {
  final bool favorite;
  final VoidCallback onTap;
  const _Star({required this.favorite, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final nl = NlColors.of(context);
    return Semantics(
        toggled: favorite,
        child: NlIconButton(
            icon: favorite ? Icons.star_rounded : NlIcons.star,
            iconSize: favorite ? 18 : null,
            color: favorite ? nl.warn : null,
            tooltip: favorite
                ? nikoText('取消收藏', 'Remove favorite')
                : nikoText('收藏', 'Favorite'),
            onPressed: onTap));
  }
}

typedef _MenuOpener = void Function(Offset? at, Rect? anchor);

class _DeviceCard extends StatelessWidget {
  final DeviceEntry device;
  final bool? online;
  final bool selected;
  final bool canConnect;
  final String? lastSession;
  final VoidCallback onSelect;
  final VoidCallback onConnect;
  final VoidCallback onFiles;
  final VoidCallback onFavorite;
  final _MenuOpener onMenu;

  const _DeviceCard(
      {required this.device,
      required this.online,
      required this.selected,
      required this.canConnect,
      required this.lastSession,
      required this.onSelect,
      required this.onConnect,
      required this.onFiles,
      required this.onFavorite,
      required this.onMenu});

  @override
  Widget build(BuildContext context) {
    final nl = NlColors.of(context);
    return NlCard(
        selected: selected,
        onTap: onSelect,
        onContextMenu: (at) => onMenu(at, null),
        padding: const EdgeInsets.fromLTRB(
            NlSpace.s4, NlSpace.s4, NlSpace.s3, NlSpace.s3),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            NlDeviceGlyph(id: device.id, size: 44, online: online),
            const Spacer(),
            _Star(favorite: device.favorite, onTap: onFavorite),
          ]),
          const SizedBox(height: NlSpace.s3),
          Text(device.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: NlType.text(NlType.s4, weight: FontWeight.w600, color: nl.fg)),
          const SizedBox(height: 2),
          Text(nikoGroupedId(device.id),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: NlType.monoText(NlType.s2, color: nl.fg3)),
          const SizedBox(height: NlSpace.s2 + 2),
          _Presence(
              online: online,
              detail: device.group.trim().isEmpty ? null : device.group.trim()),
          const SizedBox(height: NlSpace.s3),
          LayoutBuilder(builder: (context, box) {
            final connect = NlButton(
                key: Key('nikodesk-device-connect-${device.id}'),
                small: true,
                label: nikoText('连接', 'Connect'),
                onPressed: canConnect ? onConnect : null);
            final files = NlIconButton(
                icon: NlIcons.folder,
                tooltip: nikoText('文件传输', 'File transfer'),
                onPressed: canConnect ? onFiles : null);
            final more = Builder(
                builder: (context) => NlIconButton(
                    icon: NlIcons.ellipsis,
                    tooltip: nikoText('更多', 'More'),
                    onPressed: () => onMenu(null, nlAnchorOf(context))));
            final last = lastSession == null
                ? null
                : Text(lastSession!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.end,
                    style: NlType.text(NlType.s1, color: nl.fg3));
            // Large text on a narrow card: the actions wrap instead.
            if (box.maxWidth / MediaQuery.textScalerOf(context).scale(1) <
                200) {
              return Wrap(
                  spacing: NlSpace.s1,
                  runSpacing: NlSpace.s1,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [connect, files, more, if (last != null) last]);
            }
            return Row(children: [
              connect,
              const SizedBox(width: NlSpace.s1),
              files,
              more,
              const SizedBox(width: NlSpace.s2),
              Expanded(child: last ?? const SizedBox.shrink()),
            ]);
          }),
        ]));
  }
}

class _DeviceRow extends StatelessWidget {
  final DeviceEntry device;
  final bool divider;
  final bool? online;
  final bool selected;
  final bool canConnect;
  final String? lastSession;
  final VoidCallback onSelect;
  final VoidCallback onConnect;
  final VoidCallback onFiles;
  final VoidCallback onFavorite;
  final _MenuOpener onMenu;

  const _DeviceRow(
      {required this.device,
      required this.divider,
      required this.online,
      required this.selected,
      required this.canConnect,
      required this.lastSession,
      required this.onSelect,
      required this.onConnect,
      required this.onFiles,
      required this.onFavorite,
      required this.onMenu});

  @override
  Widget build(BuildContext context) {
    final nl = NlColors.of(context);
    return NlPressable(
        onTap: onSelect,
        onContextMenu: (at) => onMenu(at, null),
        selected: selected,
        pressScale: 1,
        builder: (context, states) => AnimatedContainer(
            duration: NlMotion.of(context, NlMotion.instant),
            padding: const EdgeInsets.symmetric(
                horizontal: NlSpace.s3, vertical: NlSpace.s2),
            decoration: BoxDecoration(
                color: selected
                    ? nl.solid(nl.accentSoft, nl.surface)
                    : states.contains(WidgetState.hovered)
                        ? nl.hover
                        : Colors.transparent,
                border: divider ? Border(top: BorderSide(color: nl.line)) : null,
                boxShadow:
                    states.contains(WidgetState.focused) ? nl.focusRing : null),
            child: LayoutBuilder(builder: (context, box) {
              final scale = MediaQuery.textScalerOf(context).scale(1);
              final narrow = box.maxWidth / scale < 560;
              final title = Text(device.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: NlType.text(NlType.s3,
                      weight: FontWeight.w500, color: nl.fg));
              final id = Text(nikoGroupedId(device.id),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: NlType.monoText(NlType.s1, color: nl.fg3));
              final presence = _Presence(
                  online: online,
                  detail:
                      device.group.trim().isEmpty ? null : device.group.trim());
              final more = Builder(
                  builder: (context) => NlIconButton(
                      icon: NlIcons.ellipsis,
                      tooltip: nikoText('更多', 'More'),
                      onPressed: () => onMenu(null, nlAnchorOf(context))));
              final connect = NlButton(
                  key: Key('nikodesk-device-connect-${device.id}'),
                  small: true,
                  label: nikoText('连接', 'Connect'),
                  onPressed: canConnect ? onConnect : null);
              if (narrow) {
                return Row(children: [
                  NlDeviceGlyph(id: device.id, size: 32, online: online),
                  const SizedBox(width: NlSpace.s3),
                  Expanded(
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [title, id, presence])),
                  more,
                  const SizedBox(width: NlSpace.s1),
                  connect,
                ]);
              }
              return Row(children: [
                NlDeviceGlyph(id: device.id, size: 32, online: online),
                const SizedBox(width: NlSpace.s3),
                Expanded(
                    flex: 3,
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [title, id])),
                Expanded(flex: 2, child: presence),
                if (lastSession != null && box.maxWidth > 680)
                  SizedBox(
                      width: 96,
                      child: Text(lastSession!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: NlType.text(NlType.s2, color: nl.fg3))),
                _Star(favorite: device.favorite, onTap: onFavorite),
                NlIconButton(
                    icon: NlIcons.folder,
                    tooltip: nikoText('文件传输', 'File transfer'),
                    onPressed: canConnect ? onFiles : null),
                more,
                const SizedBox(width: NlSpace.s1),
                connect,
              ]);
            })));
  }
}

class _DeviceInspector extends StatelessWidget {
  final DeviceEntry device;
  final bool? online;
  final bool canConnect;
  final bool native;
  final String? lastSession;
  final VoidCallback onClose;
  final VoidCallback onConnect;
  final VoidCallback onFiles;
  final VoidCallback onTunnel;
  final VoidCallback? onWake;
  final VoidCallback onFavorite;
  final VoidCallback onEdit;
  final VoidCallback onForget;
  final VoidCallback onRemove;
  final VoidCallback onCopy;

  const _DeviceInspector(
      {super.key,
      required this.device,
      required this.online,
      required this.canConnect,
      required this.native,
      required this.lastSession,
      required this.onClose,
      required this.onConnect,
      required this.onFiles,
      required this.onTunnel,
      required this.onWake,
      required this.onFavorite,
      required this.onEdit,
      required this.onForget,
      required this.onRemove,
      required this.onCopy});

  @override
  Widget build(BuildContext context) {
    final nl = NlColors.of(context);
    Widget info(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: NlSpace.s2),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(
              width: 88,
              child: Text(label, style: NlType.text(NlType.s2, color: nl.fg3))),
          Expanded(
              child: Text(value,
                  style: NlType.text(NlType.s2, color: nl.fg))),
        ]));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      NikoWindowDrag(
          child: Padding(
              padding: const EdgeInsets.fromLTRB(
                  NlSpace.s5, NlSpace.s3, NlSpace.s2, 0),
              child: Row(children: [
                Expanded(
                    child: Text(nikoText('设备', 'Device'),
                        style: NlType.text(NlType.s2,
                            weight: FontWeight.w500, color: nl.fg3))),
                NlIconButton(
                    icon: NlIcons.close,
                    tooltip: nikoText('关闭', 'Close'),
                    onPressed: onClose),
              ]))),
      Expanded(
          child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(
                  NlSpace.s5, NlSpace.s2, NlSpace.s5, NlSpace.s6),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Align(
                        alignment: Alignment.centerLeft,
                        child: NlDeviceGlyph(
                            id: device.id, size: 56, online: online)),
                    const SizedBox(height: NlSpace.s4),
                    Text(device.title,
                        style: NlType.text(NlType.s6,
                            weight: FontWeight.w600, color: nl.fg)),
                    const SizedBox(height: NlSpace.s1),
                    Row(children: [
                      Flexible(
                          child: Text(nikoGroupedId(device.id),
                              style: NlType.monoText(NlType.s3, color: nl.fg2))),
                      const SizedBox(width: NlSpace.s1),
                      NlIconButton(
                          icon: NlIcons.copy,
                          tooltip: nikoText('复制设备 ID', 'Copy device ID'),
                          iconSize: 14,
                          onPressed: onCopy),
                    ]),
                    const SizedBox(height: NlSpace.s1),
                    _Presence(online: online),
                    const SizedBox(height: NlSpace.s5),
                    NlButton(
                        expand: true,
                        icon: NlIcons.monitor,
                        label: nikoText('远程控制', 'Remote control'),
                        onPressed: canConnect ? onConnect : null),
                    const SizedBox(height: NlSpace.s2),
                    Row(children: [
                      Expanded(
                          child: NlButton.ghost(
                              expand: true,
                              icon: NlIcons.folder,
                              label: nikoText('传文件', 'Files'),
                              onPressed: canConnect ? onFiles : null)),
                      const SizedBox(width: NlSpace.s2),
                      Expanded(
                          child: NlButton.ghost(
                              expand: true,
                              icon: NlIcons.cable,
                              label: nikoText('隧道', 'Tunnel'),
                              onPressed: canConnect ? onTunnel : null)),
                    ]),
                    const SizedBox(height: NlSpace.s2),
                    NlButton.ghost(
                        expand: true,
                        icon: NlIcons.power,
                        label: nikoText('远程开机', 'Wake-on-LAN'),
                        onPressed: onWake),
                    const SizedBox(height: NlSpace.s6),
                    NlSectionLabel(nikoText('详情', 'Details')),
                    info(nikoText('分组', 'Group'),
                        device.group.trim().isEmpty ? '—' : device.group.trim()),
                    info(
                        nikoText('连接方式', 'Route'),
                        device.forceRelay
                            ? nikoText('强制私服中继', 'Private relay only')
                            : nikoText('自动（直连或中继）', 'Automatic (direct or relay)')),
                    info(nikoText('上次连接', 'Last session'),
                        lastSession ?? nikoText('尚未连接', 'Never')),
                    const SizedBox(height: NlSpace.s5),
                    Wrap(spacing: NlSpace.s1, runSpacing: NlSpace.s1, children: [
                      NlButton.quiet(
                          small: true,
                          icon: NlIcons.star,
                          label: device.favorite
                              ? nikoText('取消收藏', 'Unfavorite')
                              : nikoText('收藏', 'Favorite'),
                          onPressed: onFavorite),
                      NlButton.quiet(
                          small: true,
                          icon: NlIcons.pencil,
                          label: nikoText('编辑', 'Edit'),
                          onPressed: onEdit),
                      if (native)
                        NlButton.quiet(
                            small: true,
                            icon: NlIcons.keyRound,
                            label: nikoText('忘记密码', 'Forget password'),
                            onPressed: canConnect ? onForget : null),
                      NlButton.quiet(
                          small: true,
                          icon: NlIcons.trash2,
                          label: nikoText('移除', 'Remove'),
                          onPressed: onRemove),
                    ]),
                  ]))),
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
