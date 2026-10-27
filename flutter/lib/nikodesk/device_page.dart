import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/models/platform_model.dart';

import 'connect_dialog.dart';
import 'credential_connect_dialog.dart';
import 'device_identity.dart';
import 'device_screens.dart';
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

  /// This computer's ID and access card, beside the connect panel on the
  /// home layout.
  final Widget? localPanel;

  final NikoDeviceLayout layout;

  /// Opens the devices screen from the home layout's device wall.
  final VoidCallback? onManage;

  /// The last picture of a device's screen, when one was kept.
  final ImageProvider? Function(String id)? screenOf;

  /// A warning about this device itself, such as an expiring signature.
  final String? warning;

  /// Test hooks; native builds ask the service and the peer store.
  final Future<String> Function()? ownDeviceId;
  final NikoPeerIdentity Function(String id)? peerIdentity;
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
      this.localPanel,
      this.layout = NikoDeviceLayout.home,
      this.onManage,
      this.screenOf,
      this.warning,
      this.ownDeviceId,
      this.peerIdentity});
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
  List<DeviceEntry> _devices = [];
  String _ownId = '';
  final Map<String, (DateTime?, NikoPeerIdentity)> _identities = {};
  final Map<String, (DateTime, ImageProvider)> _screens = {};
  ServerSnapshot? _server;
  String? _error;
  String? _notice;
  bool _loading = true;
  bool _refreshing = false;
  bool _connecting = false;

  /// Only a session started from the panel's own fields spins its button.
  bool _heroDispatching = false;
  bool _fileTransfer = false;
  bool _tunnel = false;
  bool _forceRelay = false;
  bool _rememberPassword = false;
  bool _legacyAvailable = false;
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
  Future<String> _ownDeviceId() =>
      widget.ownDeviceId?.call() ??
      (_native ? nikoOwnDeviceId() : Future.value(''));
  NikoPeerIdentity _identity(DeviceEntry device) =>
      _identities[device.id]?.$2 ?? const NikoPeerIdentity();

  /// Peer files change only when a session succeeds, so a device is reread
  /// only when its last-session time moves.
  void _readIdentities(List<DeviceEntry> devices) {
    final read = widget.peerIdentity ?? (_native ? nikoPeerIdentity : null);
    if (read == null) return;
    for (final device in devices) {
      final cached = _identities[device.id];
      if (cached != null && cached.$1 == device.lastConnectedAt) continue;
      _identities[device.id] = (device.lastConnectedAt, read(device.id));
    }
  }
  ImageProvider? _screen(String id) =>
      widget.screenOf?.call(id) ?? _screens[id]?.$2;

  /// The core rewrites a device's screen at most every 30 seconds while
  /// connected, so a file is read again only when it changes.
  Future<void> _readScreens(List<DeviceEntry> devices) async {
    if (!_native || widget.screenOf != null) return;
    final directory = nikoDeviceScreensDirectory(_store.serverNamespace);
    if (directory == null) return;
    var changed = false;
    for (final device in devices) {
      final file = File('${directory.path}/${device.id}.png');
      try {
        final stat = await file.stat();
        if (stat.type == FileSystemEntityType.notFound) {
          changed |= _screens.remove(device.id) != null;
          continue;
        }
        if (_screens[device.id]?.$1 == stat.modified) continue;
        _screens[device.id] =
            (stat.modified, MemoryImage(await file.readAsBytes()));
        changed = true;
      } catch (_) {
        // A screen being replaced is read on the next refresh.
      }
    }
    if (changed && mounted) setState(() {});
  }

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
        final ownId = _ownDeviceId().catchError((Object _) => '');
        final directory = await _store.load();
        final own = await ownId;
        if (!mounted) return;
        // A self-session once saved this computer's own ID as a device; it is
        // hidden, not deleted, so the directory file stays as written.
        final devices = directory.devices
            .where((device) => !nikoIsOwnDevice(device.id, own))
            .toList();
        _readIdentities(devices);
        unawaited(_readScreens(devices));
        setState(() {
          _ownId = own;
          _devices = devices;
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
        credentialStatusLoader: widget.credentialStatusLoader,
        ownIdLoader: _ownDeviceId);
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
    if (nikoIsOwnDevice(raw, _ownId)) {
      nikoRefuseOwnDevice(context);
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
    setState(() => _heroDispatching = true);
    try {
      await _dispatch(normalizeDeviceId(raw),
          password: auth?.password ?? _password.text,
          auth: auth,
          expectedNamespace: namespace,
          fileTransfer: _fileTransfer,
          forceRelay: _forceRelay,
          tunnel: _tunnel);
    } finally {
      if (mounted) setState(() => _heroDispatching = false);
    }
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
    if (nikoIsOwnDevice(result.id, _ownId)) {
      nikoRefuseOwnDevice(context);
      return;
    }
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
      unawaited(nikoForgetDeviceScreen(_store.serverNamespace, device.id));
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

  // ---- View ----------------------------------------------------------

  bool get _configured => _server?.config.isValid == true;

  bool get _serverPending => _server == null && _error == null;

  DeviceEntry? get _selectedDevice {
    final id = _board.selected;
    if (id == null) return null;
    for (final device in _devices) {
      if (device.id == id) return device;
    }
    return null;
  }

  /// The device of the latest session, for the home panel's resume row.
  DeviceEntry? get _lastDevice {
    DeviceEntry? last;
    for (final device in _devices) {
      final at = device.lastConnectedAt;
      if (at == null) continue;
      if (last == null || at.isAfter(last.lastConnectedAt!)) last = device;
    }
    return last;
  }

  List<DeviceEntry> _visibleDevices() {
    final query = _search.text.trim().toLowerCase();
    final filter = _board.filter;
    final group = filter.startsWith('group:') ? filter.substring(6) : null;
    final visible = _devices
        .where((device) =>
            (filter != 'favorites' || device.favorite) &&
            (filter != 'online' || _online[device.id] == true) &&
            (filter != 'recent' || device.lastConnectedAt != null) &&
            (group == null || device.group.trim() == group) &&
            '${device.id} ${device.alias} ${device.group} ${_identity(device).name} ${_identity(device).platformLabel}'
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

  void _quickConnectRequested() {
    if (_scroll.hasClients) {
      _scroll.animateTo(0,
          duration: NlMotion.of(context, NlMotion.slow), curve: NlMotion.ease);
    }
    if (_canConnect) _idFocus.requestFocus();
  }

  void _select(DeviceEntry device) {
    _board.select(device.id);
    if (_floating.value == 0) _floating.forward();
  }

  void _closeInspector() {
    _board.select(null);
    if (_floating.value > 0) _floating.reverse();
  }

  void _showMenu(DeviceEntry device, {Offset? at, Rect? anchor}) {
    final online = _online[device.id];
    showNlMenu(context, position: at, anchor: anchor, entries: [
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
          label: nikoText('重命名和分组', 'Rename and group'),
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
          label: nikoText('从列表中移除', 'Remove from list'),
          icon: NlIcons.trash2,
          danger: true,
          onSelected: () => _remove(device)),
    ]);
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

  Widget _page(BuildContext context) => FocusTraversalGroup(
      child: widget.layout == NikoDeviceLayout.manage
          ? _managePage(context)
          : _homePage(context));

  // -- Home: the connect panel leads, devices show their screens below.

  Widget _homePage(BuildContext context) {
    final nl = NlColors.of(context);
    final devices = _visibleDevices();
    return ColoredBox(
        color: nl.bg,
        child: LayoutBuilder(builder: (context, constraints) {
          final width = constraints.maxWidth;
          final side = width < NlLayout.compactMax ? NlSpace.s4 : NlSpace.s6;
          final local = widget.controllerOnly ? null : widget.localPanel;
          final launch = _launchPanel(context, compact: width < 600);
          final top = local != null && width >= 920
              ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(flex: 7, child: launch),
                  const SizedBox(width: NlSpace.s4),
                  Expanded(flex: 5, child: local),
                ])
              : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  launch,
                  if (local != null) ...[
                    const SizedBox(height: NlSpace.s4),
                    local,
                  ],
                ]);
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const _HomeBar(),
            Expanded(
                child: SingleChildScrollView(
                    controller: _scroll,
                    padding:
                        EdgeInsets.fromLTRB(side, 0, side, NlSpace.s10),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          ..._banners(context),
                          top,
                          const SizedBox(height: NlSpace.s8),
                          _wallHeader(context, compact: width < 600),
                          const SizedBox(height: NlSpace.s3),
                          if (_loading)
                            _wallSkeleton(context, width - 2 * side)
                          else if (devices.isEmpty)
                            _empty(context)
                          else
                            _wall(context, width - 2 * side, devices),
                        ]))),
          ]);
        }));
  }

  /// The one committed surface: connecting is the main task, so it is the
  /// first thing on the home screen, in the logo blue.
  Widget _launchPanel(BuildContext context, {required bool compact}) {
    final nl = NlColors.of(context);
    final pad = compact ? NlSpace.s5 : NlSpace.s8;
    final last = _lastDevice;
    // Setup is offered only once a read says no server is set; while the
    // read is pending or has failed, the fields stay in place, disabled, so
    // the panel does not flash a setup prompt on every launch.
    final fields = _server == null || _configured;
    final help = !fields
        ? null
        : _serverPending
            ? nikoText('正在读取私服设置…', 'Reading server settings…')
            : _error != null
                ? nikoText('暂时不能连接，原因见上方提示。',
                    'Connecting is unavailable for now. See the notice above.')
                : !_canConnect && !_connecting
                    ? _registration()
                    : nikoText('对方 NikoDesk 首页上的设备代码。密码可以现在填，也可以连接时再输。',
                        'The device code shown on the other NikoDesk. Type the password now or when asked.');
    final title = Text(nikoText('控制另一台设备', 'Control another device'),
        style: NlType.text(compact ? NlType.s6 : 24,
                weight: FontWeight.w600, color: nl.brandInk)
            .copyWith(height: 1.3));
    return Container(
        constraints: const BoxConstraints(minHeight: 300),
        padding: EdgeInsets.fromLTRB(pad, pad, pad, compact ? pad : NlSpace.s6),
        decoration: BoxDecoration(
            color: nl.brand, borderRadius: BorderRadius.circular(NlRadius.r3)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          // Phones give the modes a full row of equal parts.
          if (compact) ...[
            title,
            if (fields) ...[
              const SizedBox(height: NlSpace.s3),
              _modes(context, expand: true),
            ],
          ] else
            Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: NlSpace.s4,
                runSpacing: NlSpace.s3,
                children: [title, if (fields) _modes(context)]),
          SizedBox(height: compact ? NlSpace.s5 : NlSpace.s6),
          if (fields) ...[
            _connectFields(context, compact: compact),
            const SizedBox(height: NlSpace.s2),
            Text(help!,
                style: NlType.text(NlType.s3, color: nl.brandInk2)),
          ] else
            _setupPrompt(context),
          if (_configured && last != null) ...[
            const SizedBox(height: NlSpace.s6),
            _resume(context, last),
          ],
        ]));
  }

  Widget _modes(BuildContext context, {bool expand = false}) {
    final mode = _tunnel
        ? 2
        : _fileTransfer
            ? 1
            : 0;
    return _BrandModes(
        selected: mode,
        enabled: _canConnect,
        expand: expand,
        modes: [
          (NlIcons.monitor, nikoText('远程控制', 'Control')),
          (NlIcons.folder, nikoText('文件传输', 'Files')),
          (NlIcons.cable, nikoText('TCP 隧道', 'TCP tunnel')),
        ],
        onChanged: (value) => setState(() {
              _fileTransfer = value == 1;
              _tunnel = value == 2;
            }));
  }

  Widget _connectFields(BuildContext context, {required bool compact}) {
    final nl = NlColors.of(context);
    Widget labelled(String label, Widget field) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(label,
                  style: NlType.text(NlType.s2,
                      weight: FontWeight.w500, color: nl.brandInk2)),
              const SizedBox(height: 6),
              field,
            ]);
    final id = labelled(
        nikoText('对方设备代码', 'Device code'),
        NlTextField(
            fieldKey: const Key('nikodesk-hero-id'),
            controller: _temporary,
            focusNode: _idFocus,
            enabled: _canConnect,
            mono: true,
            large: true,
            hint: '123 456 789',
            keyboardType: TextInputType.number,
            textInputAction: TextInputAction.next));
    final password = labelled(
        nikoText('密码', 'Password'),
        NlTextField(
            fieldKey: const Key('nikodesk-hero-password'),
            controller: _password,
            enabled: _canConnect,
            obscure: true,
            large: true,
            hint: nikoText('可留空', 'Optional'),
            revealLabel: nikoText('显示密码', 'Show password'),
            hideLabel: nikoText('隐藏密码', 'Hide password'),
            onSubmitted: _canConnect ? (_) => _connectHero() : null));
    final button = _BrandConnect(
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
        busy: _heroDispatching,
        expand: compact,
        onPressed: _canConnect ? _connectHero : null,
        onOptions: (anchor) => showNlMenu(context, anchor: anchor, entries: [
              NlMenuHeader(nikoText('这次连接', 'This connection')),
              NlMenuItem(
                  label: nikoText('强制经私服中继', 'Force private relay'),
                  icon: NlIcons.route,
                  checked: _forceRelay,
                  enabled: _canConnect,
                  onSelected: () => setState(() => _forceRelay = !_forceRelay)),
            ]));
    // The box sits on the fields' left edge and the whole row toggles it.
    final remember = _credentialNative && _store.serverNamespace != null
        ? MergeSemantics(
            child: NlPressable(
                onTap: !_canConnect
                    ? null
                    : () => setState(() => _rememberPassword = !_rememberPassword),
                button: false,
                pressScale: 1,
                builder: (context, states) => ConstrainedBox(
                    constraints: BoxConstraints(
                        minHeight: NlLayout.touch(context) ? 44 : 32),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Theme(
                          data: Theme.of(context).copyWith(
                              checkboxTheme: CheckboxThemeData(
                                  side: BorderSide(
                                      color: nl.brandInk2, width: 1.5),
                                  fillColor: WidgetStateProperty.resolveWith(
                                      (states) =>
                                          states.contains(WidgetState.selected)
                                              ? nl.brandInk
                                              : Colors.transparent),
                                  checkColor: WidgetStatePropertyAll(nl.brand))),
                          child: SizedBox.square(
                              dimension: 18,
                              child: Checkbox(
                                  key: const Key('nikodesk-hero-remember'),
                                  materialTapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                  visualDensity: const VisualDensity(
                                      horizontal: -4, vertical: -4),
                                  value: _rememberPassword,
                                  onChanged: !_canConnect
                                      ? null
                                      : (value) => setState(() =>
                                          _rememberPassword = value == true)))),
                      const SizedBox(width: NlSpace.s2),
                      Flexible(
                          child: Text(
                              nikoText('记住这个密码', 'Remember this password'),
                              style:
                                  NlType.text(NlType.s3, color: nl.brandInk2))),
                    ]))))
        : null;
    final fields = compact
        ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            id,
            const SizedBox(height: NlSpace.s3),
            password,
            const SizedBox(height: NlSpace.s3),
            button,
          ])
        : Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Expanded(flex: 5, child: id),
            const SizedBox(width: NlSpace.s3),
            Expanded(flex: 3, child: password),
            const SizedBox(width: NlSpace.s3),
            button,
          ]);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      fields,
      if (remember != null) ...[
        const SizedBox(height: NlSpace.s1),
        Align(alignment: Alignment.centerLeft, child: remember),
      ],
    ]);
  }

  Widget _setupPrompt(BuildContext context) {
    final nl = NlColors.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(nikoText('先连上自己的服务器', 'Set up your private server first'),
          style: NlType.text(NlType.s5,
              weight: FontWeight.w600, color: nl.brandInk)),
      const SizedBox(height: NlSpace.s2),
      Text(
          nikoText('填好 ID 服务器、中继服务器和公钥后，就能用设备代码连接其他电脑。',
              'Enter the ID server, relay server and public key, then connect to other computers by their device codes.'),
          style: NlType.text(NlType.s3, color: nl.brandInk2)),
      const SizedBox(height: NlSpace.s5),
      _BrandButton(
          icon: NlIcons.server,
          label: nikoText('配置服务器', 'Configure server'),
          onPressed: _configure),
    ]);
  }

  Widget _resume(BuildContext context, DeviceEntry device) {
    final nl = NlColors.of(context);
    final title = _deviceTitle(device, _identity(device));
    return Container(
        padding: const EdgeInsets.only(top: NlSpace.s4),
        decoration: BoxDecoration(
            border: Border(top: BorderSide(color: nl.brandTrack))),
        child: Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: NlSpace.s3,
            runSpacing: NlSpace.s2,
            children: [
              Text.rich(
                  TextSpan(children: [
                    TextSpan(text: nikoText('上次连接 ', 'Last session ')),
                    TextSpan(
                        text: title,
                        style: TextStyle(
                            color: nl.brandInk, fontWeight: FontWeight.w600)),
                    TextSpan(
                        text: nikoText('，${_ago(device.lastConnectedAt!)}',
                            ', ${_ago(device.lastConnectedAt!)}')),
                  ]),
                  style: NlType.text(NlType.s3, color: nl.brandInk2)),
              _BrandButton(
                  ghost: true,
                  icon: NlIcons.rotateCw,
                  label: nikoText('重新连接', 'Reconnect'),
                  onPressed:
                      _canConnect ? () => _connectWithDialog(device) : null),
            ]));
  }

  Widget _wallHeader(BuildContext context, {required bool compact}) {
    final nl = NlColors.of(context);
    final filter = _board.filter;
    final heading = Row(mainAxisSize: MainAxisSize.min, children: [
      Flexible(
          child: Semantics(
              header: true,
              child: Text(nikoText('我的设备', 'My devices'),
                  style: NlType.text(NlType.s5,
                      weight: FontWeight.w600, color: nl.fg)))),
      if (_devices.isNotEmpty) ...[
        const SizedBox(width: NlSpace.s2),
        Text('${_devices.length}', style: NlType.text(NlType.s4, color: nl.fg3)),
      ],
    ]);
    final filters = _devices.isEmpty
        ? null
        : NlSegmented<String>(
            small: true,
            expand: compact,
            segments: [
              NlSegment(value: 'all', label: nikoText('全部', 'All')),
              NlSegment(value: 'online', label: nikoText('在线', 'Online')),
              NlSegment(value: 'favorites', label: nikoText('收藏', 'Favorites')),
            ],
            selected: const {'all', 'online', 'favorites'}.contains(filter)
                ? filter
                : '',
            onChanged: (value) => _board.filter = value);
    if (compact) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Align(alignment: Alignment.centerLeft, child: heading),
        if (filters != null) ...[
          const SizedBox(height: NlSpace.s3),
          filters,
        ],
      ]);
    }
    return Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: NlSpace.s4,
        runSpacing: NlSpace.s3,
        children: [
          heading,
          Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: NlSpace.s3,
              runSpacing: NlSpace.s2,
              children: [
                if (filters != null) filters,
                if (widget.onManage != null)
                  NlButton.quiet(
                      label: nikoText('管理设备', 'Manage devices'),
                      onPressed: widget.onManage),
              ]),
        ]);
  }

  int _columns(BuildContext context, double width) {
    final scale = MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 1.6);
    // Phones keep two tiles a row; wider windows give each tile room.
    final minimum = (width < NlLayout.compactMax
            ? 150
            : NlLayout.touch(context)
                ? 240
                : 220) *
        scale;
    return (width / minimum).floor().clamp(1, 5);
  }

  Widget _wall(BuildContext context, double width, List<DeviceEntry> devices) {
    final columns = _columns(context, width);
    const gap = NlSpace.s4;
    final tile = (width - gap * (columns - 1)) / columns;
    return Wrap(spacing: gap, runSpacing: gap, children: [
      for (final device in devices)
        SizedBox(
            width: tile,
            child: _DeviceTile(
                device: device,
                identity: _identity(device),
                online: _online[device.id],
                canConnect: _canConnect,
                picture: _screen(device.id),
                lastSession: device.lastConnectedAt == null
                    ? null
                    : _ago(device.lastConnectedAt!),
                onConnect: () => _connectWithDialog(device),
                onMenu: (at, anchor) =>
                    _showMenu(device, at: at, anchor: anchor))),
      if (_board.filter == 'all' && _search.text.trim().isEmpty)
        SizedBox(
            width: tile,
            child: _AddTile(onTap: _error != null ? null : () => _edit())),
    ]);
  }

  Widget _wallSkeleton(BuildContext context, double width) {
    final nl = NlColors.of(context);
    final columns = _columns(context, width);
    const gap = NlSpace.s4;
    final tile = (width - gap * (columns - 1)) / columns;
    return Semantics(
        label: nikoText('正在读取设备', 'Loading devices'),
        child: Wrap(spacing: gap, runSpacing: gap, children: [
          for (var i = 0; i < columns; i++)
            Container(
                width: tile,
                padding: const EdgeInsets.all(NlSpace.s2),
                decoration: BoxDecoration(
                    color: nl.surface,
                    borderRadius: BorderRadius.circular(NlRadius.r3),
                    border: Border.all(color: nl.ring)),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      AspectRatio(
                          aspectRatio: 16 / 9,
                          child: LayoutBuilder(
                              builder: (context, box) => NlSkeleton(
                                  width: box.maxWidth,
                                  height: box.maxHeight,
                                  radius: NlRadius.r2))),
                      const SizedBox(height: NlSpace.s3),
                      NlSkeleton(width: tile * .55, height: 14),
                      const SizedBox(height: NlSpace.s2),
                      NlSkeleton(width: tile * .35),
                    ])),
        ]));
  }

  List<Widget> _banners(BuildContext context) {
    final nl = NlColors.of(context);
    Widget banner(IconData icon, String text,
            {Color? ink, Color? fill, Widget? action}) =>
        Padding(
            padding: const EdgeInsets.only(bottom: NlSpace.s4),
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
      if (widget.warning != null)
        banner(NlIcons.triangleAlert, widget.warning!,
            ink: nl.warnText, fill: nl.warnSoft),
      if (_error != null)
        banner(NlIcons.circleAlert, _error!,
            ink: nl.dangerText,
            fill: nl.dangerSoft,
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

  /// [framed] is false inside the device list, which is already a panel.
  Widget _empty(BuildContext context, {bool framed = true}) {
    final searching = _search.text.trim().isNotEmpty;
    final filtered = _board.filter != 'all';
    const padding =
        EdgeInsets.symmetric(horizontal: NlSpace.s6, vertical: NlSpace.s8);
    Widget frame(Widget child) => framed
        ? NlPanel(padding: padding, child: child)
        : Padding(padding: padding, child: child);
    return frame(NlEmptyState(
            compact: true,
            icon: _devices.isEmpty ? NlIcons.monitorSmartphone : NlIcons.search,
            title: _devices.isEmpty
                ? nikoText('还没有设备', 'No devices yet')
                : nikoText('没有符合的设备', 'No matching devices'),
            message: _devices.isEmpty
                ? nikoText('用设备代码连接一次，它就会出现在这里；也可以先添加，起个好记的名字。密码默认不保存。',
                    'Connect once by device code and it appears here, or add it first with a name you will remember. Passwords are not saved by default.')
                : nikoText('换个关键词，或者看全部设备。', 'Try another search, or show all devices.'),
            action: _devices.isEmpty
                ? NlButton(
                    icon: NlIcons.plus,
                    label: nikoText('添加设备', 'Add device'),
                    onPressed: _error != null ? null : () => _edit())
                : searching || filtered
                    ? NlButton.ghost(
                        label: nikoText('显示全部设备', 'Show all devices'),
                        onPressed: () => setState(() {
                              _search.clear();
                              _board.filter = 'all';
                            }))
                    : null));
  }

  // -- Devices: a list beside the selected device's detail.

  Widget _managePage(BuildContext context) {
    final nl = NlColors.of(context);
    final devices = _visibleDevices();
    return LayoutBuilder(builder: (context, constraints) {
      final width = constraints.maxWidth;
      final side = width < NlLayout.compactMax ? NlSpace.s4 : NlSpace.s6;
      final wide = width >= 880;
      final selected = _selectedDevice ??
          (wide && devices.isNotEmpty ? devices.first : null);
      final count = nikoText('${_devices.length} 台', '${_devices.length}');
      final online = _board.onlineCount;
      final page = NlScrollWatcher(
          header: (context, scrolled) => NikoPageBar(
              title: nikoText('设备', 'Devices'),
              subtitle: _online.isEmpty
                  ? count
                  : nikoText('$count，$online 台在线', '$count, $online online'),
              divider: scrolled,
              actions: [
                NlButton.ghost(
                    icon: NlIcons.plus,
                    label: nikoText('添加设备', 'Add device'),
                    onPressed: _error != null ? null : () => _edit()),
              ]),
          child: SingleChildScrollView(
              controller: _scroll,
              padding: EdgeInsets.fromLTRB(side, NlSpace.s2, side, NlSpace.s10),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ..._banners(context),
                    if (wide)
                      Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(
                                width: 340,
                                child: _listCard(context, devices,
                                    selected: selected)),
                            const SizedBox(width: NlSpace.s4),
                            Expanded(
                                child: selected == null
                                    ? const SizedBox.shrink()
                                    : _detail(context, selected)),
                          ])
                    else
                      _listCard(context, devices, selected: _selectedDevice),
                  ])));
      return ColoredBox(
          color: nl.bg,
          child: Stack(fit: StackFit.expand, children: [
            page,
            if (!wide) _floatingDetail(context, width, _selectedDevice),
          ]));
    });
  }

  Widget _listCard(BuildContext context, List<DeviceEntry> devices,
      {required DeviceEntry? selected}) {
    final filter = _board.filter;
    final group = filter.startsWith('group:') ? filter.substring(6) : null;
    final groups = _board.groups;
    return NlPanel(
        padding: const EdgeInsets.all(NlSpace.s3),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _searchField(),
          const SizedBox(height: NlSpace.s3),
          SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(children: [
                NlSegmented<String>(
                    small: true,
                    segments: [
                      NlSegment(
                          value: 'all',
                          label: nikoText('全部', 'All'),
                          count: _devices.isEmpty ? null : '${_devices.length}'),
                      NlSegment(
                          value: 'favorites', label: nikoText('收藏', 'Favorites')),
                      NlSegment(value: 'recent', label: nikoText('最近', 'Recent')),
                    ],
                    selected: group == null ? filter : '',
                    onChanged: (value) => _board.filter = value),
                for (final name in groups.keys) ...[
                  const SizedBox(width: NlSpace.s2),
                  NlChip(
                      label: name,
                      icon: NlIcons.tag,
                      selected: group == name,
                      onChanged: (_) => _board.filter =
                          group == name ? 'all' : 'group:$name'),
                ],
              ])),
          const SizedBox(height: NlSpace.s2),
          if (_loading)
            Padding(
                padding: const EdgeInsets.all(NlSpace.s2),
                child: Column(children: [
                  for (var i = 0; i < 4; i++)
                    const Padding(
                        padding: EdgeInsets.symmetric(vertical: NlSpace.s2),
                        child: NlSkeleton(height: 36, radius: NlRadius.r2)),
                ]))
          else if (devices.isEmpty)
            _empty(context, framed: false)
          else
            for (final device in devices)
              _DeviceListItem(
                  device: device,
                  identity: _identity(device),
                  online: _online[device.id],
                  selected: selected?.id == device.id,
                  picture: _screen(device.id),
                  lastSession: device.lastConnectedAt == null
                      ? null
                      : _ago(device.lastConnectedAt!),
                  onSelect: () => _select(device),
                  onMenu: (at, anchor) =>
                      _showMenu(device, at: at, anchor: anchor)),
        ]));
  }

  Widget _detail(BuildContext context, DeviceEntry device) => _DeviceDetail(
      key: ValueKey('nikodesk-detail-${device.id}'),
      device: device,
      identity: _identity(device),
      online: _online[device.id],
      canConnect: _canConnect,
      native: _native,
      picture: _screen(device.id),
      lastSession:
          device.lastConnectedAt == null ? null : _date(device.lastConnectedAt!),
      lastAgo:
          device.lastConnectedAt == null ? null : _ago(device.lastConnectedAt!),
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
        nikoNotice(context, nikoText('已复制设备代码', 'Device code copied'));
      });

  Widget _searchField() => NlSearchField(
      fieldKey: const Key('nikodesk-search'),
      controller: _search,
      focusNode: _searchFocus,
      hint: nikoText('名称或设备代码', 'Name or device code'),
      clearLabel: nikoText('清除搜索', 'Clear search'),
      onChanged: (_) => setState(() {}));

  /// The detail over the list on windows too narrow to show both.
  Widget _floatingDetail(
      BuildContext context, double width, DeviceEntry? device) {
    final nl = NlColors.of(context);
    final panel = (width - NlSpace.s8).clamp(280.0, 420.0);
    return AnimatedBuilder(
        animation: _floating,
        builder: (context, _) {
          final t = NlMotion.ease.transform(_floating.value);
          if (_floating.value == 0 || device == null) {
            return const SizedBox.shrink();
          }
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
                        color: nl.bg,
                        borderRadius: BorderRadius.circular(NlRadius.r4),
                        boxShadow: nl.shadow3),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Align(
                              alignment: Alignment.centerRight,
                              child: Padding(
                                  padding: const EdgeInsets.all(NlSpace.s2),
                                  child: NlIconButton(
                                      icon: NlIcons.close,
                                      tooltip: nikoText('关闭', 'Close'),
                                      onPressed: _closeInspector))),
                          Expanded(
                              child: SingleChildScrollView(
                                  padding: const EdgeInsets.fromLTRB(
                                      NlSpace.s3, 0, NlSpace.s3, NlSpace.s4),
                                  child: _detail(context, device))),
                        ]))),
          ]);
        });
  }

  String _date(DateTime date) {
    final local = date.toLocal();
    return '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')} ${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  }

  String _ago(DateTime date) {
    final elapsed = DateTime.now().difference(date.toLocal());
    if (elapsed.inMinutes < 1) return nikoText('刚刚', 'just now');
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
    return nikoText('${local.month} 月 ${local.day} 日', '${local.month}/${local.day}');
  }
}

/// The page top on the home layout: no title, only the window's drag strip
/// and, with the sidebar hidden, the control that opens it.
class _HomeBar extends StatelessWidget {
  const _HomeBar();

  @override
  Widget build(BuildContext context) {
    final frame = NikoHomeFrame.maybeOf(context);
    final leading = frame?.leading;
    return NikoWindowDrag(
        child: SizedBox(
            height: leading == null ? NlSpace.s6 : 52,
            width: double.infinity,
            child: leading == null
                ? null
                : Padding(
                    padding: EdgeInsets.only(
                        left: (frame?.insetLeft ?? 0) + NlSpace.s3),
                    child: Align(alignment: Alignment.centerLeft, child: leading))));
  }
}

/// Connection modes on the brand panel: a darker track, the selected mode
/// a white chip labelled in the panel blue.
class _BrandModes extends StatelessWidget {
  final int selected;
  final bool enabled;
  final List<(IconData, String)> modes;
  final ValueChanged<int> onChanged;

  /// Fill the width in equal parts; labels wrap rather than overflow.
  final bool expand;
  const _BrandModes(
      {required this.selected,
      required this.enabled,
      required this.modes,
      required this.onChanged,
      this.expand = false});

  @override
  Widget build(BuildContext context) {
    final nl = NlColors.of(context);
    final touch = NlLayout.touch(context);
    return Container(
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
            color: nl.brandTrack,
            borderRadius: BorderRadius.circular(NlRadius.r2)),
        // A wrapped label keeps every segment the same height.
        child: IntrinsicHeight(
            child: Row(
            mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
          for (var i = 0; i < modes.length; i++)
            _grow(expand, Semantics(
                inMutuallyExclusiveGroup: true,
                selected: i == selected,
                child: NlPressable(
                    key: Key('nikodesk-connect-mode-$i'),
                    onTap: enabled ? () => onChanged(i) : null,
                    selected: i == selected,
                    pressScale: 1,
                    builder: (context, states) {
                      final on = i == selected;
                      final ink = on
                          ? nl.brand
                          : states.contains(WidgetState.hovered)
                              ? nl.brandInk
                              : nl.brandInk2;
                      return AnimatedContainer(
                          duration: NlMotion.of(context, NlMotion.instant),
                          constraints:
                              BoxConstraints(minHeight: touch ? 36 : 28),
                          padding: EdgeInsets.symmetric(
                              horizontal: expand ? NlSpace.s2 : NlSpace.s3,
                              vertical: 2),
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                              color: on ? nl.brandInk : Colors.transparent,
                              borderRadius:
                                  BorderRadius.circular(NlRadius.r2 - 2),
                              boxShadow: states.contains(WidgetState.focused)
                                  ? [BoxShadow(color: nl.brandInk, spreadRadius: 2)]
                                  : null),
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            Icon(modes[i].$1, size: 14, color: ink),
                            const SizedBox(width: 6),
                            Flexible(
                                child: Text(modes[i].$2,
                                    maxLines: 2,
                                    textAlign: TextAlign.center,
                                    overflow: TextOverflow.ellipsis,
                                    style: NlType.text(NlType.s3,
                                        weight: on
                                            ? FontWeight.w600
                                            : FontWeight.w500,
                                        color: ink))),
                          ]));
                    }))),
        ])));
  }
}

/// The connect button on the brand panel: white, labelled in the panel
/// blue, with the connection options behind its arrow.
class _BrandConnect extends StatelessWidget {
  final String label;
  final bool busy;
  final bool expand;
  final VoidCallback? onPressed;
  final void Function(Rect anchor) onOptions;
  const _BrandConnect(
      {required this.label,
      required this.busy,
      required this.onPressed,
      required this.onOptions,
      this.expand = false});

  @override
  Widget build(BuildContext context) {
    final nl = NlColors.of(context);
    final height = NlLayout.touch(context) ? 52.0 : 44.0;
    final enabled = onPressed != null && !busy;
    Widget part(
            {Key? key,
            required VoidCallback? onTap,
            required BorderRadius radius,
            required Widget child,
            EdgeInsets padding =
                const EdgeInsets.symmetric(horizontal: NlSpace.s6)}) =>
        NlPressable(
            key: key,
            onTap: onTap,
            pressScale: .98,
            builder: (context, states) => AnimatedContainer(
                duration: NlMotion.of(context, NlMotion.instant),
                height: height,
                padding: padding,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                    color: states.contains(WidgetState.hovered) ||
                            states.contains(WidgetState.pressed)
                        ? nl.brandInk2
                        : nl.brandInk,
                    borderRadius: radius,
                    boxShadow: states.contains(WidgetState.focused)
                        ? [BoxShadow(color: nl.brandInk, spreadRadius: 2)]
                        : null),
                child: child));
    return AnimatedOpacity(
        opacity: onPressed == null ? .6 : 1,
        duration: NlMotion.of(context, NlMotion.fast),
        child: Row(
            mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
            children: [
          _grow(expand, part(
              key: const Key('nikodesk-hero-connect'),
              onTap: enabled ? onPressed : null,
              radius: const BorderRadius.horizontal(
                  left: Radius.circular(NlRadius.r2)),
              padding: EdgeInsets.symmetric(
                  horizontal: expand ? NlSpace.s4 : NlSpace.s6),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                if (busy) ...[
                  NlSpinner(size: 14, color: nl.brand),
                  const SizedBox(width: NlSpace.s2),
                ],
                Flexible(
                    child: Text(label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: NlType.text(NlType.s5,
                            weight: FontWeight.w600, color: nl.brand))),
              ]))),
          Container(width: 1, height: height, color: nl.brandInk2),
          Builder(
              builder: (context) => part(
                  key: const Key('nikodesk-hero-options'),
                  onTap: onPressed == null ? null : () => onOptions(nlAnchorOf(context)),
                  radius: const BorderRadius.horizontal(
                      right: Radius.circular(NlRadius.r2)),
                  padding: const EdgeInsets.symmetric(horizontal: NlSpace.s3),
                  child: Semantics(
                      label: nikoText('连接选项', 'Connection options'),
                      child: Icon(NlIcons.chevronDown, size: 16, color: nl.brand)))),
        ]));
  }
}

Widget _grow(bool expand, Widget child) =>
    expand ? Expanded(child: child) : child;

/// A button on the brand panel: white, or outlined in white when [ghost].
class _BrandButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool ghost;
  const _BrandButton(
      {required this.icon,
      required this.label,
      required this.onPressed,
      this.ghost = false});

  @override
  Widget build(BuildContext context) {
    final nl = NlColors.of(context);
    final ink = ghost ? nl.brandInk : nl.brand;
    return AnimatedOpacity(
        opacity: onPressed == null ? .6 : 1,
        duration: NlMotion.of(context, NlMotion.fast),
        child: NlPressable(
            onTap: onPressed,
            pressScale: .98,
            builder: (context, states) {
              final hovered = states.contains(WidgetState.hovered) ||
                  states.contains(WidgetState.pressed);
              return AnimatedContainer(
                  duration: NlMotion.of(context, NlMotion.instant),
                  height: NlLayout.touch(context) ? 40 : 32,
                  padding: const EdgeInsets.symmetric(horizontal: NlSpace.s4),
                  decoration: BoxDecoration(
                      color: ghost
                          ? (hovered ? nl.brandTrack : Colors.transparent)
                          : (hovered ? nl.brandInk2 : nl.brandInk),
                      borderRadius: BorderRadius.circular(NlRadius.r2),
                      border: ghost ? Border.all(color: nl.brandInk2) : null,
                      boxShadow: states.contains(WidgetState.focused)
                          ? [BoxShadow(color: nl.brandInk, spreadRadius: 2)]
                          : null),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(icon, size: 15, color: ink),
                    const SizedBox(width: 6),
                    Flexible(
                        child: Text(label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: NlType.text(NlType.s3,
                                weight: FontWeight.w600, color: ink))),
                  ]));
            }));
  }
}

/// Online state as a dot and a word: green 在线, grey 离线, and a hollow
/// ring for 状态未知. Unknown stays a first-class state so presence is
/// never overstated, but it is not a warning either.
class _Presence extends StatelessWidget {
  final bool? online;
  const _Presence({required this.online});

  @override
  Widget build(BuildContext context) {
    final nl = NlColors.of(context);
    final (Color ink, String label) = switch (online) {
      true => (nl.okText, nikoText('在线', 'Online')),
      false => (nl.fg2, nikoText('离线', 'Offline')),
      null => (nl.fg3, nikoText('状态未知', 'Unknown')),
    };
    return Row(mainAxisSize: MainAxisSize.min, children: [
      _Dot(online: online),
      const SizedBox(width: 6),
      Flexible(
          child: Text(label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: NlType.text(NlType.s2,
                  weight: online == true ? FontWeight.w500 : FontWeight.w400,
                  color: ink))),
    ]);
  }
}

class _Dot extends StatelessWidget {
  final bool? online;
  const _Dot({required this.online});

  @override
  Widget build(BuildContext context) {
    final nl = NlColors.of(context);
    return Container(
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
                : null));
  }
}

typedef _MenuOpener = void Function(Offset? at, Rect? anchor);

/// An unnamed device shows the host name it reported in its last session.
String _deviceTitle(DeviceEntry device, NikoPeerIdentity identity) =>
    device.alias.isEmpty && identity.name.isNotEmpty
        ? identity.name
        : device.title;

/// Controllers that cannot be controlled themselves.
bool _controllerPlatform(NikoPeerIdentity identity) =>
    const {'android', 'ios'}.contains(identity.platform.toLowerCase());

IconData _deviceIcon(NikoPeerIdentity identity) =>
    switch (identity.platform.toLowerCase()) {
      'android' || 'ios' => NlIcons.tablet,
      'linux' => NlIcons.server,
      'mac os' || 'macos' => NlIcons.laptop,
      _ => NlIcons.monitor,
    };

/// A device's last screen, or a plain field that says why there is none.
/// [chip] lays the online state over the picture.
class _Screen extends StatelessWidget {
  final ImageProvider? picture;
  final bool? online;
  final IconData icon;
  final String? reason;
  final bool chip;
  final double aspect;
  final double radius;
  final Widget? overlay;
  const _Screen(
      {required this.picture,
      required this.online,
      required this.icon,
      this.reason,
      this.chip = true,
      this.aspect = 16 / 9,
      this.radius = NlRadius.r2,
      this.overlay});

  @override
  Widget build(BuildContext context) {
    final nl = NlColors.of(context);
    final small = reason == null;
    Widget none() => ColoredBox(
        color: nl.surface2,
        child: Center(
            child: Padding(
                padding: const EdgeInsets.all(NlSpace.s2),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(icon, size: small ? 16 : 26, color: nl.fg3),
                  if (!small) ...[
                    const SizedBox(height: NlSpace.s2),
                    Text(reason!,
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: NlType.text(NlType.s2, color: nl.fg2)),
                  ],
                ]))));
    final image = picture == null
        ? none()
        : online == false
            ? Opacity(
                opacity: .55,
                child: ColorFiltered(
                    colorFilter: const ColorFilter.matrix([
                      .2126, .7152, .0722, 0, 0, //
                      .2126, .7152, .0722, 0, 0, //
                      .2126, .7152, .0722, 0, 0, //
                      0, 0, 0, 1, 0,
                    ]),
                    child: Image(
                        image: picture!,
                        fit: BoxFit.cover,
                        gaplessPlayback: true,
                        errorBuilder: (_, __, ___) => none())))
            : Image(
                image: picture!,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                errorBuilder: (_, __, ___) => none());
    return AspectRatio(
        aspectRatio: aspect,
        child: ClipRRect(
            borderRadius: BorderRadius.circular(radius),
            child: Stack(fit: StackFit.expand, children: [
              image,
              if (chip && online != null)
                Positioned(
                    left: NlSpace.s2,
                    top: NlSpace.s2,
                    child: _StateChip(online: online!)),
              if (overlay != null) overlay!,
            ])));
  }
}

/// The online state laid over a picture: a dark chip that reads on any
/// screen behind it.
class _StateChip extends StatelessWidget {
  final bool online;
  const _StateChip({required this.online});

  @override
  Widget build(BuildContext context) {
    return Container(
        height: 22,
        padding: const EdgeInsets.symmetric(horizontal: 7),
        decoration: BoxDecoration(
            color: NlDock.chip, borderRadius: BorderRadius.circular(NlRadius.r1)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: online ? NlColors.orbitDark.ok : NlDock.ink2)),
          const SizedBox(width: 5),
          Text(online ? nikoText('在线', 'Online') : nikoText('离线', 'Offline'),
              style: NlType.text(NlType.s1,
                  weight: FontWeight.w500, color: NlDock.ink)),
        ]));
  }
}

String? _screenReason(DeviceEntry device, NikoPeerIdentity identity) {
  if (_controllerPlatform(identity)) {
    return nikoText('只能控制别人，不能被控制', 'Controls others; cannot be controlled');
  }
  if (device.lastConnectedAt == null) {
    return nikoText('还没连接过，暂无画面', 'Not connected yet, no picture');
  }
  return nikoText('下次连接后显示画面', 'The picture appears after the next session');
}

/// A device on the home wall: its last screen, its name and how it was
/// last seen. The whole tile connects; the menu holds everything else.
class _DeviceTile extends StatelessWidget {
  final DeviceEntry device;
  final NikoPeerIdentity identity;
  final bool? online;
  final bool canConnect;
  final ImageProvider? picture;
  final String? lastSession;
  final VoidCallback onConnect;
  final _MenuOpener onMenu;

  const _DeviceTile(
      {required this.device,
      required this.identity,
      required this.online,
      required this.canConnect,
      required this.picture,
      required this.lastSession,
      required this.onConnect,
      required this.onMenu});

  @override
  Widget build(BuildContext context) {
    final nl = NlColors.of(context);
    final controller = _controllerPlatform(identity);
    final title = _deviceTitle(device, identity);
    final caption = [
      if (identity.platformLabel.isNotEmpty)
        identity.platformLabel
      else
        nikoGroupedId(device.id),
      lastSession ?? nikoText('从未连接', 'never connected'),
    ].join(nikoText('，', ', '));
    return Semantics(
        button: true,
        label: nikoText('连接$title', 'Connect to $title'),
        child: NlPressable(
            key: Key('nikodesk-device-connect-${device.id}'),
            onTap: canConnect && !controller ? onConnect : null,
            onContextMenu: (at) => onMenu(at, null),
            pressScale: .99,
            builder: (context, states) {
              final hovered = states.contains(WidgetState.hovered);
              final focused = states.contains(WidgetState.focused);
              final live = hovered || focused;
              return AnimatedContainer(
                  duration: NlMotion.of(context, NlMotion.base),
                  curve: NlMotion.ease,
                  transform: Matrix4.translationValues(0, hovered ? -1 : 0, 0),
                  padding: const EdgeInsets.fromLTRB(
                      NlSpace.s2, NlSpace.s2, NlSpace.s1, NlSpace.s2),
                  decoration: BoxDecoration(
                      color: nl.surface,
                      borderRadius: BorderRadius.circular(NlRadius.r3),
                      border: Border.all(color: hovered ? nl.line2 : nl.ring),
                      boxShadow: [
                        if (focused) ...nl.focusRing else ...nl.shadow1,
                      ]),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _Screen(
                            picture: picture,
                            online: online,
                            icon: _deviceIcon(identity),
                            reason: _screenReason(device, identity),
                            overlay: live && canConnect && !controller
                                ? Positioned(
                                    right: NlSpace.s2,
                                    bottom: NlSpace.s2,
                                    child: Container(
                                        height: 28,
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: NlSpace.s3),
                                        alignment: Alignment.center,
                                        decoration: BoxDecoration(
                                            color: nl.accentFill,
                                            borderRadius: BorderRadius.circular(
                                                NlRadius.r2)),
                                        child: Text(nikoText('连接', 'Connect'),
                                            style: NlType.text(NlType.s2,
                                                weight: FontWeight.w600,
                                                color: nl.onAccent))))
                                : null),
                        const SizedBox(height: NlSpace.s2 + 2),
                        Row(children: [
                          const SizedBox(width: NlSpace.s1),
                          Expanded(
                              child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                Row(children: [
                                  Flexible(
                                      child: Text(title,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: NlType.text(NlType.s4,
                                              weight: FontWeight.w600,
                                              color: nl.fg))),
                                  if (device.favorite) ...[
                                    const SizedBox(width: NlSpace.s1),
                                    Icon(Icons.star_rounded,
                                        size: 14, color: nl.fg3),
                                  ],
                                ]),
                                const SizedBox(height: 2),
                                Text(caption,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: NlType.text(NlType.s2, color: nl.fg3)),
                              ])),
                          Builder(
                              builder: (context) => NlIconButton(
                                  icon: NlIcons.ellipsis,
                                  tooltip: nikoText('$title 的更多操作',
                                      'More for $title'),
                                  onPressed: () =>
                                      onMenu(null, nlAnchorOf(context)))),
                        ]),
                      ]));
            }));
  }
}

/// The last tile on the wall: add a device by its code.
class _AddTile extends StatelessWidget {
  final VoidCallback? onTap;
  const _AddTile({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final nl = NlColors.of(context);
    return NlPressable(
        onTap: onTap,
        pressScale: .99,
        semanticLabel: nikoText('添加设备', 'Add device'),
        // Laid out like a device tile, so a row of tiles ends level.
        builder: (context, states) => AnimatedContainer(
            duration: NlMotion.of(context, NlMotion.instant),
            padding: const EdgeInsets.fromLTRB(
                NlSpace.s2, NlSpace.s2, NlSpace.s1, NlSpace.s2),
            decoration: BoxDecoration(
                color: states.contains(WidgetState.hovered)
                    ? nl.surface
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(NlRadius.r3),
                border: Border.all(color: nl.line2),
                boxShadow:
                    states.contains(WidgetState.focused) ? nl.focusRing : null),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              AspectRatio(
                  aspectRatio: 16 / 9,
                  child: Center(child: Icon(NlIcons.plus, size: 24, color: nl.fg2))),
              const SizedBox(height: NlSpace.s2 + 2),
              Row(children: [
                const SizedBox(width: NlSpace.s1),
                Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      Text(nikoText('添加设备', 'Add device'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: NlType.text(NlType.s4,
                              weight: FontWeight.w600, color: nl.fg)),
                      const SizedBox(height: 2),
                      Text(nikoText('用设备代码添加，起个好记的名字', 'By device code, with a name'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: NlType.text(NlType.s2, color: nl.fg3)),
                    ])),
                // Holds the height of the device tiles' menu button.
                ExcludeSemantics(
                    child: Visibility(
                        visible: false,
                        maintainSize: true,
                        maintainAnimation: true,
                        maintainState: true,
                        child: NlIconButton(
                            icon: NlIcons.ellipsis, tooltip: '', onPressed: null))),
              ]),
            ])));
  }
}

/// One device in the devices list: a small screen, the name and its state.
class _DeviceListItem extends StatelessWidget {
  final DeviceEntry device;
  final NikoPeerIdentity identity;
  final bool? online;
  final bool selected;
  final ImageProvider? picture;
  final String? lastSession;
  final VoidCallback onSelect;
  final _MenuOpener onMenu;

  const _DeviceListItem(
      {required this.device,
      required this.identity,
      required this.online,
      required this.selected,
      required this.picture,
      required this.lastSession,
      required this.onSelect,
      required this.onMenu});

  @override
  Widget build(BuildContext context) {
    final nl = NlColors.of(context);
    final (String state, Color ink) = switch (online) {
      true => (nikoText('在线', 'Online'), nl.okText),
      false => (nikoText('离线', 'Offline'), nl.fg2),
      null => (
          _controllerPlatform(identity)
              ? nikoText('只能控制别人', 'Controller only')
              : nikoText('状态未知', 'Unknown'),
          nl.fg3
        ),
    };
    return NlPressable(
        onTap: onSelect,
        onContextMenu: (at) => onMenu(at, null),
        selected: selected,
        pressScale: 1,
        builder: (context, states) => AnimatedContainer(
            duration: NlMotion.of(context, NlMotion.instant),
            margin: const EdgeInsets.only(bottom: 2),
            padding: const EdgeInsets.all(NlSpace.s2),
            decoration: BoxDecoration(
                color: selected
                    ? nl.accentSoft
                    : states.contains(WidgetState.hovered)
                        ? nl.hover
                        : Colors.transparent,
                borderRadius: BorderRadius.circular(NlRadius.r2),
                boxShadow:
                    states.contains(WidgetState.focused) ? nl.focusRing : null),
            child: Row(children: [
              SizedBox(
                  width: 72,
                  child: _Screen(
                      picture: picture,
                      online: online,
                      icon: _deviceIcon(identity),
                      chip: false,
                      aspect: 16 / 10,
                      radius: NlRadius.r1)),
              const SizedBox(width: NlSpace.s3),
              Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Text(_deviceTitle(device, identity),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: NlType.text(NlType.s4,
                            weight: FontWeight.w600, color: nl.fg)),
                    const SizedBox(height: 2),
                    Row(children: [
                      _Dot(online: online),
                      const SizedBox(width: 6),
                      Text(state, style: NlType.text(NlType.s2, color: ink)),
                      if (lastSession != null) ...[
                        const SizedBox(width: NlSpace.s2),
                        Flexible(
                            child: Text(lastSession!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: NlType.text(NlType.s2, color: nl.fg3))),
                      ],
                    ]),
                  ])),
            ])));
  }
}

/// The selected device: its screen beside who it is, what to do with it
/// and the facts the last session left.
class _DeviceDetail extends StatelessWidget {
  final DeviceEntry device;
  final NikoPeerIdentity identity;
  final bool? online;
  final bool canConnect;
  final bool native;
  final ImageProvider? picture;
  final String? lastSession;
  final String? lastAgo;
  final VoidCallback onConnect;
  final VoidCallback onFiles;
  final VoidCallback onTunnel;
  final VoidCallback? onWake;
  final VoidCallback onFavorite;
  final VoidCallback onEdit;
  final VoidCallback onForget;
  final VoidCallback onRemove;
  final VoidCallback onCopy;

  const _DeviceDetail(
      {super.key,
      required this.device,
      required this.identity,
      required this.online,
      required this.canConnect,
      required this.native,
      required this.picture,
      required this.lastSession,
      required this.lastAgo,
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
    final controller = _controllerPlatform(identity);
    final connectable = canConnect && !controller;
    Widget fact(String label, String value) => SizedBox(
        width: 168,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: NlType.text(NlType.s2, color: nl.fg3)),
          const SizedBox(height: 2),
          Text(value,
              style: NlType.text(NlType.s3, weight: FontWeight.w600, color: nl.fg)),
        ]));
    final screen = _Screen(
        picture: picture,
        online: online,
        icon: _deviceIcon(identity),
        reason: _screenReason(device, identity),
        chip: false,
        aspect: 16 / 10,
        overlay: picture != null && lastAgo != null
            ? Positioned(
                left: NlSpace.s2,
                top: NlSpace.s2,
                child: Container(
                    height: 22,
                    padding: const EdgeInsets.symmetric(horizontal: 7),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                        color: NlDock.chip,
                        borderRadius: BorderRadius.circular(NlRadius.r1)),
                    child: Text(nikoText('上次画面，$lastAgo', 'Last picture, $lastAgo'),
                        style: NlType.text(NlType.s1, color: NlDock.ink))))
            : null);
    final who = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
            child: Text(_deviceTitle(device, identity),
                style: NlType.text(NlType.s6,
                    weight: FontWeight.w600, color: nl.fg))),
        Semantics(
            toggled: device.favorite,
            child: NlIconButton(
                icon: device.favorite ? Icons.star_rounded : NlIcons.star,
                iconSize: device.favorite ? 18 : null,
                color: device.favorite ? nl.fg : null,
                tooltip: device.favorite
                    ? nikoText('取消收藏', 'Remove favorite')
                    : nikoText('收藏', 'Favorite'),
                onPressed: onFavorite)),
      ]),
      const SizedBox(height: NlSpace.s1),
      Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: NlSpace.s3,
          runSpacing: NlSpace.s1,
          children: [
            _Presence(online: online),
            Row(mainAxisSize: MainAxisSize.min, children: [
              Text(nikoText('设备代码 ', 'Code '),
                  style: NlType.text(NlType.s2, color: nl.fg3)),
              Text(nikoGroupedId(device.id),
                  style: NlType.monoText(NlType.s2, color: nl.fg2)),
              NlIconButton(
                  icon: NlIcons.copy,
                  tooltip: nikoText('复制设备代码', 'Copy device code'),
                  iconSize: 13,
                  onPressed: onCopy),
            ]),
          ]),
      const SizedBox(height: NlSpace.s4),
      Wrap(spacing: NlSpace.s2, runSpacing: NlSpace.s2, children: [
        NlButton(
            icon: NlIcons.monitor,
            label: nikoText('连接', 'Connect'),
            onPressed: connectable ? onConnect : null),
        NlButton.ghost(
            icon: NlIcons.folder,
            label: nikoText('传输文件', 'Files'),
            onPressed: connectable ? onFiles : null),
        NlButton.ghost(
            icon: NlIcons.cable,
            label: nikoText('TCP 隧道', 'TCP tunnel'),
            onPressed: connectable ? onTunnel : null),
        if (onWake != null)
          NlButton.ghost(
              icon: NlIcons.power,
              label: nikoText('远程开机', 'Wake-on-LAN'),
              onPressed: onWake),
      ]),
    ]);
    return NlPanel(
        padding: const EdgeInsets.all(NlSpace.s5),
        child: LayoutBuilder(builder: (context, box) {
          final side = box.maxWidth >= 620;
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (side)
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SizedBox(width: box.maxWidth * .44, child: screen),
                const SizedBox(width: NlSpace.s5),
                Expanded(child: who),
              ])
            else ...[
              screen,
              const SizedBox(height: NlSpace.s4),
              who,
            ],
            const SizedBox(height: NlSpace.s5),
            Divider(height: 1, color: nl.line),
            const SizedBox(height: NlSpace.s4),
            Wrap(spacing: NlSpace.s5, runSpacing: NlSpace.s4, children: [
              if (identity.platformLabel.isNotEmpty)
                fact(nikoText('系统', 'System'), identity.platformLabel),
              if (identity.name.isNotEmpty)
                fact(nikoText('主机名', 'Host name'), identity.name),
              fact(nikoText('分组', 'Group'),
                  device.group.trim().isEmpty ? nikoText('未分组', 'None') : device.group.trim()),
              fact(
                  nikoText('连接方式', 'Route'),
                  device.forceRelay
                      ? nikoText('只走私服中继', 'Private relay only')
                      : nikoText('自动选择直连或中继', 'Direct or relay')),
              fact(nikoText('上次连接', 'Last session'),
                  lastSession ?? nikoText('从未连接', 'Never')),
            ]),
            const SizedBox(height: NlSpace.s5),
            Wrap(spacing: NlSpace.s1, runSpacing: NlSpace.s1, children: [
              NlButton.quiet(
                  small: true,
                  icon: NlIcons.pencil,
                  label: nikoText('重命名和分组', 'Rename and group'),
                  onPressed: onEdit),
              if (native)
                NlButton.quiet(
                    small: true,
                    icon: NlIcons.keyRound,
                    label: nikoText('忘记已保存密码', 'Forget saved password'),
                    onPressed: canConnect ? onForget : null),
              NlButton.quiet(
                  small: true,
                  icon: NlIcons.trash2,
                  label: nikoText('从列表中移除', 'Remove from list'),
                  onPressed: onRemove),
            ]),
          ]);
        }));
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
