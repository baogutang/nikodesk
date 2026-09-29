import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/models/platform_model.dart';

import 'connect_dialog.dart';
import 'device_store.dart';
import 'policy.dart';
import 'server_gateway.dart';
import 'server_settings.dart';
import 'session_log.dart';
import 'theme.dart';
import 'ui.dart';

/// Device workspace of the NikoDesk home. All sessions go through the real
/// connect path; online dots come from the private rendezvous server.
class NikoDevicePage extends StatefulWidget {
  final DeviceStore? store;
  final ServerGateway? gateway;
  final Future<void> Function(BuildContext, String, bool,
      {bool isFileTransfer, String? password})? onConnect;
  final VoidCallback? onOpenSettings;
  const NikoDevicePage(
      {super.key,
      this.store,
      this.gateway,
      this.onConnect,
      this.onOpenSettings});
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
  bool _forceRelay = false;
  final Map<String, bool> _online = {};
  Timer? _timer;
  Timer? _onlineTimer;

  bool get _native => widget.gateway == null;
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
        setState(() {
          for (final id in (evt['onlines'] as String? ?? '').split(',')) {
            if (id.isNotEmpty) _online[id] = true;
          }
          for (final id in (evt['offlines'] as String? ?? '').split(',')) {
            if (id.isNotEmpty) _online[id] = false;
          }
        });
      });
      _onlineTimer = Timer.periodic(const Duration(seconds: 6), (_) {
        if (_devices.isEmpty || !_canConnect) return;
        try {
          bind.queryOnlines(
              ids: _devices.map((d) => d.id).toList(growable: false));
        } catch (_) {
          // The rendezvous query is best-effort; cards fall back to unknown.
        }
      });
    }
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => _refresh());
  }

  Future<void> _setLanguage(bool english) async {
    if (!mounted) return;
    setState(() => NikoLanguage.english = english);
    if (!_native) return;
    final language = english ? 'en' : 'zh-cn';
    await bind.mainSetLocalOption(key: 'lang', value: language);
    await bind.mainChangeLanguage(lang: language);
    await reloadAllWindows();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _onlineTimer?.cancel();
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
      final server = await _gateway.read();
      final directory = await _store.load();
      if (mounted) {
        setState(() {
          _server = server;
          _devices = directory.devices;
          _loading = false;
          _error = null;
          if (directory.recovered) {
            _notice = nikoText('设备目录损坏，已保留损坏文件并恢复可用备份（无备份时为空目录）。',
                'The damaged device file was preserved. A valid backup was restored, or an empty directory was created.');
          }
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
      _server?.config.isValid == true &&
      _server?.enabled == true &&
      !_connecting;

  /// NikoDesk controller policy: no session is dispatched without a
  /// password entered on this client. The remote side still verifies every
  /// session on its own.
  Future<void> _dispatch(String id,
      {required String password,
      required bool fileTransfer,
      required bool forceRelay}) async {
    if (password.isEmpty) {
      nikoNotice(
          context,
          nikoText('安全策略：必须输入远端密码才能发起连接。',
              'Policy: the remote password is required before connecting.'));
      return;
    }
    if (!_canConnect) return;
    setState(() => _connecting = true);
    try {
      // Re-read native settings immediately before dispatching to the real session path.
      final current = await _gateway.read();
      if (!current.config.isValid || !current.enabled) {
        if (mounted) setState(() => _server = current);
        return;
      }
      if (!mounted) return;
      if (widget.onConnect != null) {
        await widget.onConnect!(context, id, forceRelay,
            isFileTransfer: fileTransfer, password: password);
      } else {
        await connect(context, id,
            forceRelay: forceRelay,
            isFileTransfer: fileTransfer,
            password: password);
      }
      await _recordSession(id, fileTransfer, forceRelay);
    } catch (_) {
      if (mounted) {
        nikoNotice(
            context,
            nikoText('无法发起连接。检查私服配置及远端 ID 后重试。',
                'Could not start the session. Check server settings and the device ID, then retry.'));
      }
    } finally {
      if (mounted) setState(() => _connecting = false);
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
    await _dispatch(normalizeDeviceId(raw),
        password: _password.text,
        fileTransfer: _fileTransfer,
        forceRelay: _forceRelay);
  }

  /// Card actions and history reconnects always go through the password
  /// dialog; nothing connects with an id alone.
  Future<void> _connectWithDialog(DeviceEntry device,
      {bool fileTransfer = false}) async {
    if (!_canConnect) {
      nikoNotice(
          context,
          nikoText('私服未就绪，无法发起连接。', 'The private server is not ready.'));
      return;
    }
    await nikoConnectWithPassword(context,
        id: device.id,
        alias: device.alias,
        fileTransfer: fileTransfer,
        forceRelay: device.forceRelay,
        onConnect: _native ? null : widget.onConnect,
        onDispatched: () => _recordSession(device.id, fileTransfer, device.forceRelay));
  }

  Future<void> _recordSession(String id, bool fileTransfer, bool forceRelay) async {
    // Locally record what this client initiated. This says nothing about
    // remote-side acceptance, which every session verifies on its own.
    if (!_native) return;
    try {
      await SessionLogStore.instance.record(SessionLogEntry(
          id: id,
          alias: _devices
              .firstWhere((d) => d.id == id, orElse: () => DeviceEntry(id: id))
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
    if (result == null) return;
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

  Future<void> _configure() async {
    final saved = await showNikoServerSettings(context, _gateway,
        _server?.config ?? const PrivateServerConfig('', '', ''));
    if (saved == true) await _refresh();
  }

  Future<void> _favorite(DeviceEntry device) async {
    try {
      await _store.save(device.copyWith(favorite: !device.favorite));
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
                            style: Theme.of(context)
                                .textTheme
                                .headlineMedium
                                ?.copyWith(fontWeight: FontWeight.w700)),
                        const SizedBox(height: 6),
                        Text(
                            nikoText('自己的服务器，熟悉的工作空间。',
                                'Your server. Your workspace.'),
                            style: TextStyle(color: _muted(context))),
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
                            onPressed: _error != null ? null : () => _edit(),
                            child: Row(mainAxisSize: MainAxisSize.min, children: [
                              const Icon(Icons.add, size: 17),
                              const SizedBox(width: 5),
                              Text(nikoText('添加设备', 'Add device')),
                            ])),
                      ]),
                ]),
            const SizedBox(height: 22),
            _hero(context, constraints),
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
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                        Text(_error!,
                            style: TextStyle(
                                color: Theme.of(context).colorScheme.error)),
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
                    label: Text(filter == 'all'
                        ? nikoText('全部', 'All')
                        : filter == 'favorites'
                            ? nikoText('收藏', 'Favorites')
                            : nikoText('最近成功连接', 'Recent successful sessions')),
                    selected: _filter == filter,
                    onSelected: (_) => setState(() => _filter = filter)),
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
                    onPressed: () => _setLanguage(!NikoLanguage.english),
                    child: Text(NikoLanguage.english ? '中文' : 'English',
                        style: TextStyle(color: _muted(context))))),
          ]),
        )));
  }

  Widget _hero(BuildContext context, BoxConstraints constraints) {
    final configured = _server?.config.isValid == true;
    final connectCard = NikoGlassCard(
        padding: const EdgeInsets.all(20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 12,
              runSpacing: 10,
              children: [
                Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(nikoText('连接远程设备', 'Connect to a device'),
                          style: Theme.of(context)
                              .textTheme
                              .titleMedium
                              ?.copyWith(fontWeight: FontWeight.w700)),
                      const SizedBox(height: 3),
                      Text(
                          nikoText('输入对方设备 ID，经你的私服建立加密会话。',
                              'Enter the remote device ID; sessions go through your private server.'),
                          style: TextStyle(
                              fontSize: 12.5, color: _muted(context))),
                    ]),
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
                    ],
                    selected: {_fileTransfer ? 1 : 0},
                    onSelectionChanged: !_canConnect
                        ? null
                        : (selection) => setState(
                            () => _fileTransfer = selection.first == 1),
                    showSelectedIcon: false),
              ]),
          const SizedBox(height: 14),
          ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 680),
              child: Row(children: [
                Expanded(
                    flex: 3,
                    child: TextField(
                        key: const Key('nikodesk-hero-id'),
                        controller: _temporary,
                        enabled: _canConnect,
                        style: nikoIdStyle(context, fontSize: 15),
                        keyboardType: TextInputType.number,
                        decoration:
                            nikoInput(nikoText('远端设备 ID', 'Remote device ID')))),
                const SizedBox(width: 10),
                Expanded(
                    flex: 2,
                    child: TextField(
                        key: const Key('nikodesk-hero-password'),
                        controller: _password,
                        enabled: _canConnect,
                        obscureText: true,
                        decoration: nikoInput(nikoText('远端密码', 'Remote password')),
                        onSubmitted: _canConnect
                            ? (_) => _connectHero()
                            : null)),
              ])),
          const SizedBox(height: 12),
          Wrap(spacing: 14, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
            Row(mainAxisSize: MainAxisSize.min, children: [
              Switch(
                  value: _forceRelay,
                  onChanged: !_canConnect
                      ? null
                      : (value) => setState(() => _forceRelay = value)),
              const SizedBox(width: 4),
              Text(nikoText('强制私服中继', 'Force private relay'),
                  style: TextStyle(fontSize: 12.5, color: _muted(context))),
            ]),
            NikoPrimaryButton(
                key: const Key('nikodesk-hero-connect'),
                onPressed: _canConnect ? _connectHero : null,
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(_fileTransfer ? Icons.folder_rounded : Icons.bolt_rounded,
                      size: 17),
                  const SizedBox(width: 6),
                  Text(nikoText('连接', _fileTransfer ? 'Transfer' : 'Connect')),
                ])),
          ]),
        ]));
    final statusCard = NikoGlassCard(
        padding: const EdgeInsets.all(20),
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
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
                            : nikoText('先连接自己的服务器',
                                'Set up your private server'),
                        style: Theme.of(context)
                            .textTheme
                            .titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700))),
              ]),
              const SizedBox(height: 10),
              Text(configured ? _registration() : nikoText('需要 ID 服务器、中继地址与公钥。未配置时无法连接。',
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
        // IntrinsicHeight keeps both cards the same height at wide sizes;
        // plain stretch leaves the shorter status card's border ragged.
        : IntrinsicHeight(
            child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(flex: 5, child: connectCard),
              const SizedBox(width: 14),
              Expanded(flex: 3, child: statusCard),
            ]));
  }

  Widget _empty(BuildContext context) => NikoGlassCard(
      padding: const EdgeInsets.all(36),
      child: Column(children: [
        Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
                gradient: LinearGradient(colors:
                    NikoPalette.deviceAvatarGradient('nikodesk-empty')),
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
                ? nikoText('添加设备 ID，设置容易记住的别名。不会保存控制密码。',
                    'Add a device ID and a memorable alias. No control passwords are stored.')
                : nikoText('试试其他关键词或筛选条件。',
                    'Try another search or filter.'),
            textAlign: TextAlign.center,
            style: TextStyle(color: _muted(context), fontSize: 12.5)),
      ]));

  Widget _grid(
      BuildContext context, BoxConstraints constraints, List<DeviceEntry> devices) {
    final columns =
        ((constraints.maxWidth - 40) / 320).clamp(1, 4).toInt();
    final cardWidth = (constraints.maxWidth - 40 - 14 * (columns - 1)) / columns;
    return Wrap(
        spacing: 14,
        runSpacing: 14,
        children: [
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
                                    gradient: LinearGradient(
                                        begin: Alignment.topLeft,
                                        end: Alignment.bottomRight,
                                        colors: NikoPalette
                                            .deviceAvatarGradient(device.id)),
                                    borderRadius: BorderRadius.circular(
                                        NikoShapes.avatar)),
                                child: const Icon(Icons.desktop_mac_rounded,
                                    color: Colors.white, size: 21)),
                            const SizedBox(width: 12),
                            Expanded(
                                child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                  Text(device.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleSmall
                                          ?.copyWith(
                                              fontWeight: FontWeight.w700)),
                                  const SizedBox(height: 2),
                                  Text(device.id,
                                      style: nikoIdStyle(context,
                                          fontSize: 12.5,
                                          color: _muted(context))),
                                ])),
                            _StarButton(
                                favorite: device.favorite,
                                color: Theme.of(context).colorScheme.primary,
                                onTap: () => _favorite(device)),
                          ]),
                          const SizedBox(height: 12),
                          Row(children: [
                            if (device.group.isNotEmpty)
                              Flexible(
                                  fit: FlexFit.loose,
                                  child: Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 8, vertical: 3),
                                      decoration: BoxDecoration(
                                        color:
                                            _muted(context).withOpacity(.1),
                                        borderRadius:
                                            BorderRadius.circular(6),
                                      ),
                                      child: Text(device.group,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                              fontSize: 10.5,
                                              fontWeight: FontWeight.w600,
                                              color: _muted(context))))),
                            const SizedBox(width: 8),
                            _OnlineDot(
                                state: _online[device.id],
                                dense: true),
                            const Spacer(),
                            Flexible(
                                child: Text(
                                    device.lastConnectedAt == null
                                        ? nikoText('尚无成功连接',
                                            'No successful session yet')
                                        : '${nikoText('上次连接', 'Last session')}: ${_date(device.lastConnectedAt!)}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                        fontSize: 10.5,
                                        color: _muted(context)))),
                          ]),
                          const SizedBox(height: 12),
                          Row(children: [
                            NikoPrimaryButton(
                                key: Key('nikodesk-device-connect-${device.id}'),
                                compact: true,
                                onPressed: _canConnect
                                    ? () => _connectWithDialog(device)
                                    : null,
                                child: Text(nikoText('连接', 'Connect'))),
                            const SizedBox(width: 8),
                            _IconAction(
                                tooltip: nikoText('文件传输', 'File transfer'),
                                icon: Icons.folder_outlined,
                                onTap: _canConnect
                                    ? () => _connectWithDialog(
                                        device,
                                        fileTransfer: true)
                                    : null),
                            _IconAction(
                                tooltip: nikoText('编辑', 'Edit'),
                                icon: Icons.edit_outlined,
                                onTap: () => _edit(device)),
                            const Spacer(),
                            PopupMenuButton<String>(
                                tooltip: nikoText('更多', 'More'),
                                color: nikoIsLight(context)
                                    ? Colors.white
                                    : NikoPalette.darkCard,
                                onSelected: (value) =>
                                    value == 'edit' ? _edit(device) : _remove(device),
                                itemBuilder: (_) => [
                                      PopupMenuItem(
                                          value: 'edit',
                                          child:
                                              Text(nikoText('编辑', 'Edit'))),
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
  Widget build(BuildContext context) => IconButton(
      visualDensity: VisualDensity.compact,
      tooltip: favorite ? nikoText('取消收藏', 'Remove favorite') : nikoText('收藏', 'Favorite'),
      onPressed: onTap,
      icon: Icon(favorite ? Icons.star_rounded : Icons.star_outline_rounded,
          size: 20, color: favorite ? NikoPalette.warning : null));
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
        visualDensity: VisualDensity.compact,
        tooltip: tooltip,
        onPressed: onTap,
        icon: Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: light
                  ? Colors.white.withOpacity(.85)
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
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(shape: BoxShape.circle, color: color)),
      const SizedBox(width: 5),
      Text(label,
          style: TextStyle(
              fontSize: dense ? 10.5 : 11,
              fontWeight: FontWeight.w600,
              color: color)),
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
    Navigator.of(context).pop(DeviceEntry(
        id: normalizeDeviceId(_id.text),
        alias: _alias.text.trim(),
        group: _group.text.trim(),
        forceRelay: _relay,
        favorite: widget.device?.favorite ?? false,
        lastConnectedAt: widget.device?.lastConnectedAt));
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
