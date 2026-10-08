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
  final NikoUpdater? updater;
  final Future<bool> Function(Uri)? openUpdateUrl;
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
      this.updateChecker,
      this.updater,
      this.openUpdateUrl});

  @override
  State<NikoSettingsView> createState() => _NikoSettingsViewState();
}

class _NikoSettingsViewState extends State<NikoSettingsView> {
  late final _updater = widget.updater ?? const NikoUpdater();
  ProductBuildInfo _buildInfo = ProductBuildInfo.unknown;
  bool _buildInfoLoading = true;
  int _buildInfoRequest = 0;
  int _settingsRequest = 0;
  bool _checkingUpdate = false;
  NikoUpdateChannel _updateChannel = NikoUpdateChannel.stable;
  bool _downloadingUpdate = false;
  double? _updateProgress;
  NikoUpdateCancellation? _updateCancellation;
  String? _updateStatus;
  Uri? _updatePage;
  Directory? _stagedMacUpdate;
  String? _stagedMacVersion;
  bool _stagedMacReady = false;
  bool _openingUpdate = false;
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
    if (_checkingUpdate || _openingUpdate || (!_native && widget.updateChecker == null)) return;
    final cancellation = NikoUpdateCancellation();
    _updateCancellation = cancellation;
    setState(() {
      _checkingUpdate = true;
      _updateStatus = nikoText('正在检查更新…', 'Checking for updates…');
    });
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
        _showUpdateStatus(nikoText('暂无已发布版本。', 'No published release yet.'));
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
      final legacyTransition = !release.isNightly &&
          info.canMigrateLegacyPreviewTo(release.tag);
      if (!release.isNightly && !legacyTransition &&
          info.relationTo(release.tag) !=
              PublishedVersionRelation.newerRelease) {
        _showUpdateStatus(info.updateStatus(release.tag));
        return;
      }
      final macAsset = Platform.isMacOS && !release.isNightly && !legacyTransition && _updater.publisher.configured
          ? release.assetFor('macos-arm64')
          : null;
      setState(() {
        _updatePage = _updater.releasePage(release);
        _updateStatus = nikoText('可下载 ${release.displayName}，尚未安装。',
            '${release.displayName} is available to download, not installed.');
      });
      final confirmed = await showDialog<bool>(
          context: context,
          builder: (dialog) => AlertDialog(
                title: Text(release.isNightly
                    ? nikoText('预览版本', 'Nightly preview')
                    : legacyTransition
                        ? nikoText('切换到正式版', 'Switch to stable')
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
                          if (legacyTransition) ...[
                            const SizedBox(height: 10),
                            Text(nikoText(
                                '本机 1.1.0+9 使用旧预览版编号；1.0.7 是新的正式版编号。本次仅打开发布页供你核对并手动切换，请保留备用远控入口。',
                                'Installed 1.1.0+9 uses the old preview numbering. Stable 1.0.7 uses the new scheme. Open the release page to review and switch manually, keeping a backup remote-access path.')),
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
                                  ? nikoText('请前往 GitHub Releases 手动下载。此构建未提供本平台的发行者签名验证下载流程。',
                                      'Download manually from GitHub Releases. This build does not provide publisher-verified downloads for this platform.')
                                  : nikoText(
                                      '验证发行者签名和更新包完整性后，在 Finder 中显示供你手动安装；当前应用会继续运行。',
                                      'Verify the publisher signature and update integrity, then show it in Finder for manual installation. The current app keeps running.'),
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
        await _openUpdatePage();
        return;
      }
      await _prepareMacUpdate(release, macAsset, cancellation);
    } on NikoUpdateCancelled {
      if (mounted && identical(_updateCancellation, cancellation)) {
        _showUpdateStatus(nikoText('已取消更新。', 'Update cancelled.'));
      }
    } catch (_) {
      if (mounted && identical(_updateCancellation, cancellation)) {
        _showUpdateStatus(
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

  void _showUpdateStatus(String message) {
    if (mounted) setState(() => _updateStatus = message);
  }

  Future<void> _openUpdatePage() async {
    final page = _updatePage;
    if (page == null || _openingUpdate) return;
    setState(() => _openingUpdate = true);
    try {
      final opened = await (widget.openUpdateUrl?.call(page) ?? launchUrl(page));
      _showUpdateStatus(opened
          ? _stagedMacUpdate != null
              ? nikoText('已打开发布页。之前准备的文件仍列在下方，请按其校验状态操作；此次打开网页没有安装或重启应用。',
                  'Release page opened. Previously prepared files remain listed below; follow their verification status. Opening this page did not install or restart the app.')
              : nikoText('已打开发布页，尚未下载或安装。下载后按发布说明手动安装，再从原安装位置重新打开 NikoDesk 核对版本。',
                  'Release page opened; nothing has been downloaded or installed by this app. Install manually using the release instructions, then reopen NikoDesk from its installation location and check the version.')
          : nikoText('无法打开发布页。请重试，或复制下方地址到浏览器；当前版本未更改。',
              'Could not open the release page. Retry or copy the address below into a browser. The current version is unchanged.'));
    } catch (_) {
      _showUpdateStatus(nikoText('无法打开发布页。请重试，或复制下方地址到浏览器；当前版本未更改。',
          'Could not open the release page. Retry or copy the address below into a browser. The current version is unchanged.'));
    } finally {
      if (mounted) setState(() => _openingUpdate = false);
    }
  }

  Future<void> _revealUpdate({NikoUpdateCancellation? cancellation}) async {
    final staged = _stagedMacUpdate;
    if (staged == null || _openingUpdate) return;
    setState(() {
      _openingUpdate = true;
      // Retained files are not evidence that a later validation still passes.
      _stagedMacReady = false;
    });
    try {
      await _updater.revealStagedMacUpdate(staged, cancellation: cancellation);
      if (mounted) setState(() => _stagedMacReady = true);
      _showUpdateStatus(nikoText('已在 Finder 显示安装包，尚未安装或重启。请按下方步骤完成。',
          'Installer shown in Finder; the app has not been installed or restarted. Follow the steps below.'));
    } on NikoUpdateCancelled {
      rethrow;
    } on FormatException {
      _showUpdateStatus(nikoText('安装包重新校验失败，文件可能已损坏、变更或缺失。请勿安装这些文件；可重试校验或从发布页重新下载。当前版本未更改。',
          'Installer recheck failed: files may be damaged, changed or missing. Do not install these files. Retry verification or download again from the release page. The current version is unchanged.'));
    } catch (_) {
      _showUpdateStatus(nikoText('未能在 Finder 显示或重新确认安装包。应用未删除已准备的文件，位置见下方；可重试或从发布页重新下载。当前版本未更改。',
          'Could not show or recheck the installer in Finder. This app has not deleted the prepared files; their location is below. Retry or download again from the release page. The current version is unchanged.'));
    } finally {
      if (mounted) setState(() => _openingUpdate = false);
    }
  }

  Future<void> _prepareMacUpdate(NikoReleaseInfo release,
      NikoReleaseAsset asset, NikoUpdateCancellation cancellation) async {
    setState(() {
      _downloadingUpdate = true;
      _updateProgress = null;
    });
    Directory? staging;
    var retained = false;
    try {
      staging = await Directory.systemTemp.createTemp('nikodesk-update-');
      final ok = await _updater.verifyAndStageMacUpdate(release, asset, staging,
          onPhase: (phase) {
        if (!_ownsUpdate(cancellation)) return;
        setState(() {
          _updateProgress = null;
          _updateStatus = switch (phase) {
            NikoUpdatePhase.downloading => nikoText('正在下载安装包…', 'Downloading the installer…'),
            NikoUpdatePhase.verifying => nikoText('下载完成，正在验证发行者与文件完整性…', 'Download complete. Verifying publisher and file integrity…'),
            NikoUpdatePhase.unpacking => nikoText('正在解包并检查应用，尚未安装…', 'Unpacking and checking the app; not installed yet…'),
          };
        });
      },
          cancellation: cancellation, onProgress: (received, total) {
        if (total > 0 && _ownsUpdate(cancellation)) {
          setState(() => _updateProgress = received / total);
        }
      });
      if (!ok) {
        if (mounted) {
          _showUpdateStatus(nikoText('更新包校验失败，未安装或重启。可重试或查看发布说明，当前版本未更改。',
              'Update verification failed. Nothing was installed or restarted. Retry or check the release notes; the current version is unchanged.'));
        }
        return;
      }
      cancellation.check();
      if (!_ownsUpdate(cancellation)) return;
      setState(() {
        _stagedMacUpdate = staging;
        _stagedMacVersion = release.tag;
        _stagedMacReady = false;
      });
      // Finder failure must not discard the verified package or its retry path.
      retained = true;
      await _revealUpdate(cancellation: cancellation);
    } on NikoUpdateCancelled {
      rethrow;
    } on TimeoutException {
      _showUpdateStatus(nikoText('下载或校验超时，未安装或重启。请重试；当前版本未更改。',
          'Download or verification timed out. Nothing was installed or restarted. Retry; the current version is unchanged.'));
    } catch (_) {
      if (mounted) {
        _showUpdateStatus(nikoText('下载或准备安装包失败，未安装或重启。请重试或从发布页下载；当前版本未更改。',
            'Could not download or prepare the installer. Nothing was installed or restarted. Retry or download from the release page; the current version is unchanged.'));
      }
    } finally {
      if (!retained && staging != null && await staging.exists()) {
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
                onChanged: _checkingUpdate || _openingUpdate
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
                      onPressed: _checkingUpdate || _openingUpdate ? null : _checkForUpdate,
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
            if (_updateStatus != null) ...[
              Text(_updateStatus!, key: const Key('nikodesk-update-status')),
              const SizedBox(height: 8),
            ],
            if (_stagedMacUpdate != null) ...[
              Text(_stagedMacReady
                  ? nikoText('$_stagedMacVersion 安装包已校验，仍需手动安装',
                      '$_stagedMacVersion installer checked; manual installation required')
                  : nikoText('保留了 $_stagedMacVersion 的文件，安装前需重新校验',
                      '$_stagedMacVersion files retained; recheck before installation'),
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              if (_stagedMacReady)
                Text(nikoText('1. 保存工作并结束远控会话，然后手动退出 NikoDesk。\n2. 在 Finder 将准备好的 NikoDesk.app 复制到原安装位置，按系统提示确认替换。\n3. 从原安装位置重新打开 NikoDesk，在本页核对版本。应用不会自动替换或重启。\n升级可能需要重新授予 macOS 权限；请保留备用远控入口。',
                    '1. Save your work and end remote sessions, then quit NikoDesk manually.\n2. In Finder, copy the prepared NikoDesk.app to its original installation location and confirm replacement when prompted.\n3. Reopen NikoDesk from that location and check the version here. The app will not replace itself or restart automatically.\nmacOS permissions may need to be granted again; keep a backup remote-access path.'))
              else
                Text(nikoText('请先重新校验并在 Finder 显示，成功前不要安装这些文件。也可从发布页重新下载。',
                    'Recheck and show the files in Finder before installation. Do not install them until this succeeds, or download again from the release page.')),
              SelectableText('${_stagedMacUpdate!.path}/mac/NikoDesk.app',
                  key: const Key('nikodesk-update-staged-path')),
              Align(alignment: Alignment.centerLeft, child: OutlinedButton(
                  onPressed: _checkingUpdate || _openingUpdate ? null : () => _revealUpdate(),
                  child: Text(nikoText('在 Finder 显示安装包', 'Show installer in Finder')))),
              Text(nikoText('安装前请记下文件位置；关闭此页后，可在 Finder 中按该位置找到文件。',
                  'Keep the file location before closing this page so you can find the files in Finder later.'),
                  style: TextStyle(fontSize: 11.5, color: muted)),
              const SizedBox(height: 8),
            ],
            if (_updatePage != null) ...[
              SelectableText(_updatePage.toString(), key: const Key('nikodesk-update-release-url')),
              Align(alignment: Alignment.centerLeft, child: TextButton(
                  onPressed: _checkingUpdate || _openingUpdate ? null : _openUpdatePage,
                  child: Text(nikoText('打开发布页', 'Open release page')))),
            ],
            Text(
                _updater.publisher.configured
                    ? nikoText('macOS 更新使用内置发行公钥验证签名与 SHA256，再手动安装。系统签名与公证状态请参阅发布说明。',
                        'macOS updates verify a signed SHA256 manifest with the built-in publisher key before manual installation. See release notes for OS signing and notarization status.')
                    : nikoText('此构建未配置发行验证公钥，更新仅提供手动下载入口。SHA256 本身不能确认发行者。',
                        'No publisher verification key is configured in this build. Updates offer manual download only. SHA256 alone does not authenticate a publisher.'),
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
