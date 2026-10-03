import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/models/platform_model.dart';

import 'package:url_launcher/url_launcher.dart';

import 'autostart.dart';
import 'auto_lock_settings.dart';
import 'privacy_settings.dart';
import 'virtual_display_settings.dart';
import 'wake_proxy_settings.dart';
import 'mac_background_settings.dart';
import 'policy.dart';
import 'updater.dart';
import 'server_gateway.dart';
import 'server_settings.dart';
import 'theme.dart';
import 'ui.dart';
import 'peer_preferences_native.dart';
import 'peer_preferences_view.dart';
import 'server_scope.dart';
import 'capability_policy_native.dart';
import 'capability_policy_view.dart';
import 'product_build_info.dart';
import 'update_transfer.dart' show NikoUpdateTask;

/// Settings page of the NikoDesk home: private server, appearance, language,
/// autostart, and a hosted entry into the full upstream settings.
class NikoSettingsView extends StatefulWidget {
  final ServerGateway? gateway;
  final bool native;
  final bool active;
  final VoidCallback? onServerSaved;
  final VoidCallback? onLanguageChanged;
  final VoidCallback? onOpenAdvanced;
  final NikoAutostart? autostart;
  final Future<ProductBuildInfo> Function()? buildInfoLoader;
  // Explicit UI-test injection; production uses the real NikoUpdater.
  final Future<NikoReleaseInfo?> Function(NikoUpdateCancellation)? updateChecker;
  const NikoSettingsView(
      {super.key,
      this.gateway,
      this.native = true,
      this.active = true,
      this.onServerSaved,
      this.onLanguageChanged,
      this.onOpenAdvanced,
      this.autostart,
      this.buildInfoLoader,
      this.updateChecker});

  @override
  State<NikoSettingsView> createState() => _NikoSettingsViewState();
}

class _NikoSettingsViewState extends State<NikoSettingsView> {
  final _updater = const NikoUpdater();
  ProductBuildInfo _buildInfo = ProductBuildInfo.unknown;
  bool _buildInfoLoading = true;
  int _buildInfoRequest = 0;
  int _settingsRequest = 0;
  bool _checkingUpdate = false;
  NikoUpdateChannel _updateChannel = NikoUpdateChannel.stable;
  bool _downloadingUpdate = false;
  double? _updateProgress;
  NikoUpdateCancellation? _updateCancellation;
  late final _gateway =
      widget.gateway ?? (widget.native ? NativeServerGateway() : null);
  late final _autostart = widget.autostart ??
      (widget.native && Platform.isMacOS ? const NikoAutostart() : null);
  PrivateServerConfig? _config;
  int? _registration;
  bool _enabled = false;
  ThemeMode _mode = ThemeMode.system;
  bool _autostartOn = false;
  String? _buildDate;
  String? _loadError;

  bool get _native => widget.native;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void didUpdateWidget(covariant NikoSettingsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) _refresh();
  }

  @override
  void dispose() {
    _updateCancellation?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    final request = ++_settingsRequest;
    unawaited(_refreshBuildInfo());
    PrivateServerConfig? config;
    int? registration;
    var enabled = false;
    var mode = _mode;
    var autostartOn = false;
    String? error;
    try {
      final gateway = _gateway;
      if (gateway != null) {
        final snapshot = await gateway.read();
        config = snapshot.config;
        registration = snapshot.registrationStatus;
        enabled = snapshot.enabled;
      }
      if (_native) {
        mode = MyTheme.getThemeModePreference();
      }
      final autostart = _autostart;
      if (autostart != null) {
        autostartOn = autostart.enabled;
      }
    } catch (_) {
      error = nikoText('读取设置失败，可重试。', 'Could not read settings. Retry.');
    }
    if (!mounted || request != _settingsRequest) return;
    setState(() {
      _config = config;
      _registration = registration;
      _enabled = enabled;
      _mode = mode;
      _autostartOn = autostartOn;
      _loadError = error;
    });
  }

  Future<void> _refreshBuildInfo() async {
    final request = ++_buildInfoRequest;
    setState(() => _buildInfoLoading = true);
    final infoFuture = _readBuildInfo();
    final dateFuture = _readBuildDate();
    final info = await infoFuture;
    final date = await dateFuture;
    if (!mounted || request != _buildInfoRequest) return;
    setState(() {
      _buildInfo = info;
      _buildDate = date;
      _buildInfoLoading = false;
    });
  }

  Future<String?> _readBuildDate() async {
    if (!_native) return null;
    try {
      return await bind.mainGetBuildDate()
          .timeout(ProductBuildInfo.sourceReadTimeout);
    } catch (_) {
      return null;
    }
  }

  Future<ProductBuildInfo> _readBuildInfo() async {
    try {
      final loader = widget.buildInfoLoader;
      final future = loader != null
          ? Future<ProductBuildInfo>.sync(loader)
          : _native
              ? ProductBuildInfo.read(nativeVersionLoader: bind.mainGetVersion)
              : Future.value(ProductBuildInfo.unknown);
      return await future.timeout(ProductBuildInfo.loadTimeout);
    } catch (_) {
      return ProductBuildInfo.unknown;
    }
  }

  Future<void> _changeAutostart(bool on) async {
    final autostart = _autostart;
    if (autostart == null) return;
    final ok = on ? await autostart.enable() : await autostart.disable();
    if (!mounted) return;
    setState(() => _autostartOn = autostart.enabled);
    if (!ok) {
      nikoNotice(
          context,
          nikoText('自启动设置未变更，请检查 ~/Library/LaunchAgents 权限。',
              'Autostart was not changed. Check ~/Library/LaunchAgents permissions.'));
    }
  }

  Future<void> _changeMode(ThemeMode mode) async {
    setState(() => _mode = mode);
    if (_native) await MyTheme.changeDarkMode(mode);
  }

  Future<void> _changeLanguage(bool english) async {
    setState(() => NikoLanguage.english = english);
    widget.onLanguageChanged?.call();
    if (!_native) return;
    final language = english ? 'en' : 'zh-cn';
    await bind.mainSetLocalOption(key: 'lang', value: language);
    await bind.mainChangeLanguage(lang: language);
    await reloadAllWindows();
  }

  Future<void> _checkForUpdate() async {
    if (_checkingUpdate || (!_native && widget.updateChecker == null)) return;
    final cancellation = NikoUpdateCancellation();
    _updateCancellation = cancellation;
    setState(() => _checkingUpdate = true);
    final task = NikoUpdateTask(_updater.limits, cancellation);
    int? metadataRequest;
    try {
      final checker = widget.updateChecker;
      final release = await task.wait(checker == null
          ? _updater.checkLatest(
              channel: _updateChannel, cancellation: cancellation)
          : Future<NikoReleaseInfo?>.sync(() => checker(cancellation)));
      if (!_ownsUpdate(cancellation)) return;
      if (release == null) {
        nikoNotice(context, nikoText('暂无已发布版本。', 'No published release yet.'));
        return;
      }
      metadataRequest = ++_buildInfoRequest;
      setState(() => _buildInfoLoading = true);
      final info = await task.wait(_readBuildInfo(),
          timeout: ProductBuildInfo.loadTimeout +
              const Duration(milliseconds: 100));
      if (!_ownsUpdate(cancellation) || metadataRequest != _buildInfoRequest) {
        return;
      }
      setState(() {
        _buildInfo = info;
        _buildInfoLoading = false;
      });
      if (!release.isNightly &&
          info.relationTo(release.tag) !=
              PublishedVersionRelation.newerRelease) {
        nikoNotice(context, info.updateStatus(release.tag));
        return;
      }
      final macAsset = Platform.isMacOS && !release.isNightly
          ? release.assetFor('macos-arm64')
          : null;
      final confirmed = await showDialog<bool>(
          context: context,
          builder: (dialog) => AlertDialog(
                title: Text(release.isNightly
                    ? nikoText('预览版本', 'Nightly preview')
                    : nikoText('发现新版本', 'Update available')),
                content: SizedBox(
                    width: 420,
                    child: SingleChildScrollView(
                        child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                          Text(release.displayName,
                              style:
                                  const TextStyle(fontWeight: FontWeight.w700)),
                          const SizedBox(height: 6),
                          Text(nikoText(
                              '当前本机 ${info.fullVersion} → 公开版本 ${release.tag}',
                              'Installed ${info.fullVersion} → published ${release.tag}')),
                          if (release.publishedAt != null) ...[
                            const SizedBox(height: 6),
                            Text(nikoText(
                                '发布时间：${release.publishedAt!.toLocal()}',
                                'Published: ${release.publishedAt!.toLocal()}')),
                          ],
                          if (release.isNightly) ...[
                            const SizedBox(height: 10),
                            Text(nikoText(
                                '预览版随 main 更新，可能尚未完成真机验收。相同版本号不能判断是否比本机构建更新；请核对发布名称和时间后手动下载。',
                                'Nightly follows main and may still be awaiting device acceptance. Matching version numbers cannot establish whether it is newer than your installed build; review the release name and time before downloading manually.')),
                          ],
                          const SizedBox(height: 10),
                          if (release.notes.isNotEmpty)
                            Text(release.notes,
                                maxLines: 12,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontSize: 12,
                                    color: Theme.of(dialog)
                                        .colorScheme
                                        .onSurfaceVariant)),
                          const SizedBox(height: 10),
                          Text(
                              macAsset == null
                                  ? nikoText('本平台请从 GitHub Releases 下载更新包。',
                                      'Download the update from GitHub Releases for this platform.')
                                  : nikoText(
                                      '下载并校验更新包后，在 Finder 中显示供你手动安装；当前应用会继续运行。',
                                      'Download and verify the update, then show it in Finder for manual installation. The current app keeps running.'),
                              style: TextStyle(
                                  fontSize: 11.5,
                                  color: Theme.of(dialog)
                                      .colorScheme
                                      .onSurfaceVariant)),
                        ]))),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(dialog, false),
                      child: Text(nikoText('稍后', 'Later'))),
                  NikoPrimaryButton(
                      compact: true,
                      onPressed: () => Navigator.pop(dialog, true),
                      child: Text(macAsset == null
                          ? nikoText('去下载', 'Download')
                          : nikoText('下载并校验', 'Download and verify'))),
                ],
              ));
      if (confirmed != true || !_ownsUpdate(cancellation)) return;
      if (macAsset == null) {
        await launchUrl(_updater.releasePage(release));
        return;
      }
      await _prepareMacUpdate(release, macAsset, cancellation);
    } on NikoUpdateCancelled {
      if (mounted && identical(_updateCancellation, cancellation)) {
        nikoNotice(context, nikoText('已取消更新。', 'Update cancelled.'));
      }
    } catch (_) {
      if (mounted && identical(_updateCancellation, cancellation)) {
        nikoNotice(context,
            nikoText('检查更新失败，请稍后重试。', 'Update check failed. Retry later.'));
      }
    } finally {
      if (identical(_updateCancellation, cancellation)) {
        _updateCancellation = null;
        if (mounted) {
          setState(() {
            _checkingUpdate = false;
            if (metadataRequest != null &&
                metadataRequest == _buildInfoRequest) {
              ++_buildInfoRequest;
              _buildInfoLoading = false;
            }
          });
        }
      }
    }
  }

  bool _ownsUpdate(NikoUpdateCancellation cancellation) => mounted &&
      identical(_updateCancellation, cancellation) && !cancellation.isCancelled;

  Future<void> _prepareMacUpdate(NikoReleaseInfo release,
      NikoReleaseAsset asset, NikoUpdateCancellation cancellation) async {
    setState(() {
      _downloadingUpdate = true;
      _updateProgress = null;
    });
    Directory? staging;
    var revealed = false;
    try {
      staging = await Directory.systemTemp.createTemp('nikodesk-update-');
      final ok = await _updater.verifyAndStageMacUpdate(release, asset, staging,
          cancellation: cancellation, onProgress: (received, total) {
        if (total > 0 && mounted) {
          setState(() => _updateProgress = received / total);
        }
      });
      if (!ok) {
        if (mounted) {
          nikoNotice(
              context,
              nikoText('更新包校验失败，未做任何更改。',
                  'Update verification failed. Nothing was changed.'));
        }
        return;
      }
      cancellation.check();
      await _updater.revealStagedMacUpdate(staging, cancellation: cancellation);
      revealed = true;
      if (mounted) {
        nikoNotice(
            context,
            nikoText('更新包已校验并在 Finder 中显示。请退出应用后手动安装。',
                'The verified update is shown in Finder. Quit the app before installing it manually.'));
      }
    } on NikoUpdateCancelled {
      rethrow;
    } catch (_) {
      if (mounted) {
        nikoNotice(
            context,
            nikoText('更新失败，当前版本未受影响。',
                'Update failed. Current version is untouched.'));
      }
    } finally {
      if (!revealed && staging != null && await staging.exists()) {
        try {
          await staging.delete(recursive: true);
        } catch (_) {
          // A failed cleanup must not hide the download or validation result.
          debugPrint('nikodesk update: temporary cleanup failed');
        }
      }
      if (mounted) {
        setState(() {
          _downloadingUpdate = false;
          _updateProgress = null;
        });
      }
    }
  }

  Future<void> _configure() async {
    final gateway = _gateway;
    if (gateway == null) return;
    final saved = await showNikoServerSettings(
        context, gateway, _config ?? const PrivateServerConfig('', '', ''));
    if (saved == true) {
      await _refresh();
      widget.onServerSaved?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    final muted =
        nikoIsLight(context) ? NikoPalette.lightMuted : NikoPalette.darkMuted;
    return FocusTraversalGroup(
        child: ListView(
            padding: const EdgeInsets.all(NikoTokens.pagePadding),
            children: [
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(nikoText('设置', 'Settings'),
                style: Theme.of(context)
                    .textTheme
                    .headlineMedium
                    ?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text(
                nikoText(
                    '外观、服务器与高级选项。', 'Appearance, server and advanced options.'),
                style: TextStyle(color: muted)),
          ]),
          const SizedBox(height: 22),
          _section(context, nikoText('私有服务器', 'Private server'), [
            _row(context, nikoText('ID 服务器', 'ID server'),
                _config?.idServer ?? '—'),
            _row(context, nikoText('中继服务器', 'Relay server'),
                _config?.relayServer ?? '—'),
            _row(context, nikoText('公钥', 'Public key'), _maskedKey()),
            _row(context, nikoText('注册状态', 'Registration'),
                _registrationLabel()),
            const SizedBox(height: 12),
            Row(children: [
              OutlinedButton(
                  onPressed: _gateway == null ? null : _configure,
                  child: Text(nikoText('配置服务器', 'Configure server'))),
              const SizedBox(width: 10),
              Expanded(
                  child: Text(
                      nikoText('未配置或配置错误时不回退公共协调服务。',
                          'Never falls back to public rendezvous services.'),
                      style: TextStyle(fontSize: 11.5, color: muted))),
            ]),
          ]),
          const SizedBox(height: 16),
          if (_native && (Platform.isMacOS || Platform.isWindows)) ...[
            if (Platform.isMacOS) ...[
              _section(context, nikoText('无人值守', 'Unattended access'), [const NikoMacBackgroundSettings()]),
              const SizedBox(height: 16),
            ],
            _section(context, nikoText('会话安全', 'Session security'), [
              const NikoAutoLockSettings(),
              const SizedBox(height: 12),
              const NikoPrivacySettings(),
              const SizedBox(height: 16),
              const NikoVirtualDisplaySettings(),
            ]),
            const SizedBox(height: 16),
            _section(context, nikoText('远程开机', 'Remote wake'), [const NikoWakeProxySettings()]),
            const SizedBox(height: 16),
          ],
          _section(context, nikoText('外观', 'Appearance'), [
            Text(nikoText('主题', 'Theme'),
                style: Theme.of(context)
                    .textTheme
                    .titleSmall
                    ?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            SegmentedButton<ThemeMode>(
                segments: [
                  ButtonSegment(
                      value: ThemeMode.system,
                      label: Text(nikoText('跟随系统', 'System'))),
                  ButtonSegment(
                      value: ThemeMode.light,
                      label: Text(nikoText('明亮', 'Light'))),
                  ButtonSegment(
                      value: ThemeMode.dark,
                      label: Text(nikoText('暗黑', 'Dark'))),
                ],
                selected: {
                  _mode
                },
                onSelectionChanged: (selection) => _changeMode(selection.first),
                showSelectedIcon: false),
            const SizedBox(height: 14),
            Text(nikoText('语言', 'Language'),
                style: Theme.of(context)
                    .textTheme
                    .titleSmall
                    ?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            SegmentedButton<int>(
                segments: [
                  ButtonSegment(value: 0, label: const Text('中文')),
                  ButtonSegment(value: 1, label: const Text('English')),
                ],
                selected: {
                  NikoLanguage.english ? 1 : 0
                },
                onSelectionChanged: (selection) =>
                    _changeLanguage(selection.first == 1),
                showSelectedIcon: false),
          ]),
          const SizedBox(height: 16),
          if (_autostart != null)
            _section(context, nikoText('通用', 'General'), [
              SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _autostartOn,
                  onChanged: _changeAutostart,
                  title: Text(
                      nikoText('登录自动启动配置', 'Launch-at-login configuration')),
                  subtitle: Text(nikoText(
                      '开关表示本应用的登录启动配置已验证；实际重新登录运行需另行确认。不会安装特权服务，也不提供登录前被控。',
                      'The switch verifies this app’s login configuration. Startup after a real login needs separate verification. It installs no privileged service and provides no pre-login control.'))),
            ]),
          const SizedBox(height: 16),
          _section(context, nikoText('软件更新', 'Software update'), [
            DropdownButtonFormField<NikoUpdateChannel>(
                key: const Key('nikodesk-update-channel'),
                value: _updateChannel,
                decoration: InputDecoration(
                    labelText: nikoText('更新渠道', 'Update channel')),
                items: [
                  DropdownMenuItem(
                      value: NikoUpdateChannel.stable,
                      child: Text(nikoText('正式版', 'Stable'))),
                  DropdownMenuItem(
                      value: NikoUpdateChannel.nightly,
                      child: Text(nikoText('预览版（nightly）', 'Nightly preview'))),
                ],
                onChanged: _checkingUpdate
                    ? null
                    : (channel) {
                        if (channel != null) {
                          setState(() => _updateChannel = channel);
                        }
                      }),
            const SizedBox(height: 10),
            Row(children: [
              Icon(Icons.system_update_rounded, color: muted),
              const SizedBox(width: 10),
              Expanded(
                  child: Text(
                      _buildInfoLoading
                          ? nikoText('正在读取本机版本…',
                              'Reading installed version…')
                          : 'NikoDesk ${_buildInfo.fullVersion}',
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w600))),
              _downloadingUpdate
                  ? SizedBox(
                      width: 120,
                      child: LinearProgressIndicator(
                          value: _updateProgress,
                          minHeight: 6,
                          borderRadius: BorderRadius.circular(3)))
                  : OutlinedButton(
                      onPressed: _checkingUpdate ? null : _checkForUpdate,
                      child: _checkingUpdate
                          ? SizedBox(
                              width: 14,
                              height: 14,
                              child: const CircularProgressIndicator(
                                  strokeWidth: 2))
                          : Text(nikoText('检查更新', 'Check for updates'))),
              if (_checkingUpdate) ...[
                const SizedBox(width: 8),
                TextButton(
                    onPressed: () => _updateCancellation?.cancel(),
                    child: Text(nikoText('取消', 'Cancel'))),
              ],
            ]),
            const SizedBox(height: 6),
            Text(
                nikoText(
                    '从 GitHub Releases 下载，校验 SHA256 与应用包完整性后手动安装。SHA256 不等同于发行签名。',
                    'Download from GitHub Releases, verify SHA256 and bundle integrity, then install manually. SHA256 is not a publisher signature.'),
                style: TextStyle(fontSize: 11.5, color: muted)),
          ]),
          const SizedBox(height: 16),
          _section(context, nikoText('高级', 'Advanced'), [
            if (_native && (Platform.isMacOS || Platform.isWindows))
              ListTile(
                leading: Icon(Icons.verified_user_outlined, color: muted),
                title: Text(nikoText('高级功能请求', 'Advanced capability requests')),
                subtitle: Text(nikoText('默认关闭；允许请求后仍需每次单独批准。',
                    'Off by default. Every request still needs separate approval.')),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () {
                  final namespace = NikoServerScope.current;
                  if (namespace == null) {
                    nikoNotice(context, nikoText('请先配置有效的私有服务器。',
                        'Configure a valid private server first.'));
                    return;
                  }
                  showNikoCapabilityPolicy(context, nativeNikoCapabilityPolicy, namespace);
                },
              ),
            if (_native)
              ListTile(
                leading: Icon(Icons.import_export_rounded, color: muted),
                title: Text(nikoText('查看旧连接偏好', 'Review legacy connection preferences')),
                subtitle: Text(nikoText('选择设备归属当前私服；保留原文件，不导入密码。',
                    'Attribute selected devices to this server. Preserve originals without importing passwords.')),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () {
                  final namespace = NikoServerScope.current;
                  if (namespace == null) {
                    nikoNotice(context, nikoText('请先配置有效的私有服务器。',
                        'Configure a valid private server first.'));
                    return;
                  }
                  showNikoPeerPreferences(context, nativeNikoPeerPreferences, namespace);
                },
              ),
            ListTile(
              leading: Icon(Icons.tune_rounded, color: muted),
              title: Text(nikoText('打开高级设置', 'Open advanced settings')),
              subtitle: Text(nikoText('安全、网络、显示、编解码等完整上游选项。',
                  'Full upstream options for security, network, display and codecs.')),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: widget.onOpenAdvanced,
            ),
          ]),
          const SizedBox(height: 16),
          _section(context, nikoText('关于', 'About'), [
            if (_buildInfoLoading)
              Semantics(liveRegion: true,
                  child: Text(nikoText('正在读取版本信息…',
                      'Reading version information…')))
            else ...[
              NikoProductInfoRows(info: _buildInfo, buildDate: _buildDate),
              if (_buildInfo.hasUnknown)
                TextButton(key: const Key('nikodesk-version-retry'),
                    onPressed: _refreshBuildInfo,
                    child: Text(nikoText('重试读取版本', 'Retry version read'))),
            ],
            _row(
                context,
                nikoText('边界', 'Boundaries'),
                nikoText('仅私服 · 无自动更新 · 本地签名',
                    'Private-server only · no auto update · locally signed')),
          ]),
          if (_loadError != null)
            Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(_loadError!,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error))),
          const SizedBox(height: 16),
        ]));
  }

  String _maskedKey() {
    final key = _config?.publicKey ?? '';
    if (key.length <= 10) return key.isEmpty ? '—' : key;
    return '${key.substring(0, 6)}…${key.substring(key.length - 4)}';
  }

  String _registrationLabel() {
    if (_loadError != null) return nikoText('状态未知', 'Status unknown');
    if (!_enabled) return nikoText('已停止', 'Stopped');
    switch (_registration) {
      case 1:
        return nikoText('已注册', 'Registered');
      case 0:
        return nikoText('正在注册', 'Registering');
      case -1:
        return nikoText('注册未就绪', 'Not ready');
      default:
        return nikoText('未知', 'Unknown');
    }
  }

  Widget _section(BuildContext context, String title, List<Widget> children) =>
      NikoGlassCard(
          padding: const EdgeInsets.all(20),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title,
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 12),
            ...children,
          ]));

  Widget _row(BuildContext context, String label, String value) {
    final muted =
        nikoIsLight(context) ? NikoPalette.lightMuted : NikoPalette.darkMuted;
    return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(
              width: 92,
              child:
                  Text(label, style: TextStyle(fontSize: 12.5, color: muted))),
          Expanded(
              child: Text(value,
                  style: const TextStyle(
                      fontSize: 12.5, fontWeight: FontWeight.w600))),
        ]));
  }
}
