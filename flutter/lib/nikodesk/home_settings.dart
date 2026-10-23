import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/models/platform_model.dart';

import 'package:url_launcher/url_launcher.dart';

import 'autostart.dart';
import 'diagnostics_bundle.dart';
import 'home_chrome.dart';
import 'auto_lock_settings.dart';
import 'privacy_settings.dart';
import 'virtual_display_settings.dart';
import 'wake_proxy_settings.dart';
import 'mac_background_settings.dart';
import 'mac_service_settings.dart';
import 'mac_update_install.dart' show nikoRelaunch;
import 'mac_update_settings.dart';
import 'nightline.dart';
import 'policy.dart';
import 'updater.dart';
import 'server_gateway.dart';
import 'server_settings.dart';
import 'settings_kit.dart';
import 'ui.dart';
import 'peer_preferences_native.dart';
import 'peer_preferences_view.dart';
import 'server_scope.dart';
import 'capability_policy_native.dart';
import 'capability_policy_view.dart';
import 'product_build_info.dart';
import 'update_transfer.dart' show NikoUpdateTask;

/// The pages of NikoDesk settings, in the order the navigation lists them.
enum NikoSettingsSection {
  general,
  appearance,
  server,
  unattended,
  security,
  wake,
  updates,
  advanced,
  about,
}

/// Settings page of the NikoDesk home: one section at a time beside a
/// section list on a wide page, every section in one scroll on a narrow
/// one.
class NikoSettingsView extends StatefulWidget {
  final ServerGateway? gateway;
  final bool native;
  final bool active;
  final VoidCallback? onServerSaved;
  final VoidCallback? onLanguageChanged;
  final VoidCallback? onAppearanceChanged;
  final VoidCallback? onOpenAdvanced;

  /// The section shown first.
  final NikoSettingsSection? initialSection;

  /// Changing it opens [initialSection] again on a page already shown.
  final int sectionRequest;
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
      this.onAppearanceChanged,
      this.onOpenAdvanced,
      this.initialSection,
      this.sectionRequest = 0,
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

  late NikoSettingsSection _section =
      widget.initialSection ?? NikoSettingsSection.general;
  final _content = ScrollController();

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
    final section = widget.initialSection;
    if (section != null && widget.sectionRequest != oldWidget.sectionRequest) {
      _open(section);
    }
  }

  @override
  void dispose() {
    _updateCancellation?.cancel();
    _content.dispose();
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

  Future<void> _changePreset(NlPreset preset) async {
    if (preset == NlColors.active) return;
    setState(() => NlColors.active = preset);
    widget.onAppearanceChanged?.call();
    if (!_native) return;
    await bind.mainSetLocalOption(
        key: NikoAppearance.option,
        value: preset == NlPreset.clay ? 'clay' : 'orbit');
    // Other windows read the preset again when the language is announced.
    await bind.mainChangeLanguage(lang: bind.mainGetLocalOption(key: 'lang'));
    await reloadAllWindows();
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
      final confirmed = await showNlDialog<bool>(
          context: context,
          builder: (dialog) {
            final nl = NlColors.of(dialog);
            Widget para(String text, {Color? color}) => Padding(
                padding: const EdgeInsets.only(top: NlSpace.s3),
                child: Text(text,
                    style: NlType.text(NlType.s2, color: color ?? nl.fg2)));
            return NlDialog(
                width: 460,
                icon: NlIconTile(
                    icon: NlIcons.cloudDownload, color: nl.accent, size: 40),
                title: release.isNightly
                    ? nikoText('预览版本', 'Nightly preview')
                    : legacyTransition
                        ? nikoText('切换到正式版', 'Switch to stable')
                        : nikoText('发现新版本', 'Update available'),
                content: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(release.displayName,
                          style: NlType.text(NlType.s4,
                              weight: FontWeight.w600, color: nl.fg)),
                      const SizedBox(height: NlSpace.s1),
                      Text(
                          nikoText(
                              '当前本机 ${info.fullVersion} → 公开版本 ${release.tag}',
                              'Installed ${info.fullVersion} → published ${release.tag}'),
                          style: NlType.monoText(NlType.s2, color: nl.fg2)),
                      if (release.publishedAt != null)
                        para(nikoText(
                            '发布时间：${release.publishedAt!.toLocal()}',
                            'Published: ${release.publishedAt!.toLocal()}')),
                      if (release.isNightly)
                        para(
                            nikoText(
                                '预览版随 main 更新，可能尚未完成真机验收。相同版本号不能判断是否比本机构建更新；请核对发布名称和时间后手动下载。',
                                'Nightly follows main and may still be awaiting device acceptance. Matching version numbers cannot establish whether it is newer than your installed build; review the release name and time before downloading manually.'),
                            color: nl.warnText),
                      if (legacyTransition)
                        para(nikoText(
                            '本机 1.1.0+9 使用旧预览版编号；1.0.7 是新的正式版编号。本次仅打开发布页供你核对并手动切换，请保留备用远控入口。',
                            'Installed 1.1.0+9 uses the old preview numbering. Stable 1.0.7 uses the new scheme. Open the release page to review and switch manually, keeping a backup remote-access path.')),
                      if (release.notes.isNotEmpty)
                        Container(
                            width: double.infinity,
                            margin: const EdgeInsets.only(top: NlSpace.s4),
                            padding: const EdgeInsets.all(NlSpace.s3),
                            decoration: BoxDecoration(
                                color: nl.bg2,
                                borderRadius:
                                    BorderRadius.circular(NlRadius.r2)),
                            child: Text(release.notes,
                                maxLines: 12,
                                overflow: TextOverflow.ellipsis,
                                style:
                                    NlType.text(NlType.s2, color: nl.fg2))),
                      para(
                          macAsset == null
                              ? nikoText('请前往 GitHub Releases 手动下载。此构建未提供本平台的发行者签名验证下载流程。',
                                  'Download manually from GitHub Releases. This build does not provide publisher-verified downloads for this platform.')
                              : nikoText(
                                  '验证发行者签名和更新包完整性后，在 Finder 中显示供你手动安装；当前应用会继续运行。',
                                  'Verify the publisher signature and update integrity, then show it in Finder for manual installation. The current app keeps running.'),
                          color: nl.fg3),
                    ]),
                actions: [
                  NlButton.ghost(
                      onPressed: () => Navigator.pop(dialog, false),
                      label: nikoText('稍后', 'Later')),
                  NlButton(
                      autofocus: true,
                      icon: macAsset == null
                          ? NlIcons.externalLink
                          : NlIcons.shieldCheck,
                      onPressed: () => Navigator.pop(dialog, true),
                      label: macAsset == null
                          ? nikoText('去下载', 'Download')
                          : nikoText('下载并校验', 'Download and verify')),
                ]);
          });
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

  List<NikoSettingsSection> get _sections => [
        NikoSettingsSection.general,
        NikoSettingsSection.appearance,
        NikoSettingsSection.server,
        if (_native && Platform.isMacOS) NikoSettingsSection.unattended,
        if (_native && (Platform.isMacOS || Platform.isWindows)) ...[
          NikoSettingsSection.security,
          NikoSettingsSection.wake,
        ],
        NikoSettingsSection.updates,
        NikoSettingsSection.advanced,
        NikoSettingsSection.about,
      ];

  (IconData, String, String) _meta(NikoSettingsSection section) =>
      switch (section) {
        NikoSettingsSection.general => (
            NlIcons.settings,
            nikoText('通用', 'General'),
            nikoText('语言与启动', 'Language and startup')
          ),
        NikoSettingsSection.appearance => (
            NlIcons.palette,
            nikoText('外观', 'Appearance'),
            nikoText('主题与主题色，所有窗口同步', 'Theme and accent, shared by every window')
          ),
        NikoSettingsSection.server => (
            NlIcons.server,
            nikoText('私有服务器', 'Private server'),
            nikoText('NikoDesk 只连接你自己的服务器', 'NikoDesk connects only to your own server')
          ),
        NikoSettingsSection.unattended => (
            NlIcons.monitorCheck,
            nikoText('无人值守', 'Unattended access'),
            nikoText('电脑前没人时也能被远控', 'Accept remote control when nobody is at this computer')
          ),
        NikoSettingsSection.security => (
            NlIcons.shield,
            nikoText('会话安全', 'Session security'),
            nikoText('锁屏、隐私屏与虚拟屏', 'Locking, privacy screen and virtual displays')
          ),
        NikoSettingsSection.wake => (
            NlIcons.power,
            nikoText('远程开机', 'Remote wake'),
            nikoText('让本机替同一网络里的电脑开机', 'Wake computers on this computer’s network')
          ),
        NikoSettingsSection.updates => (
            NlIcons.cloudDownload,
            nikoText('软件更新', 'Software update'),
            nikoText('版本、更新渠道与安装方式', 'Version, channel and how updates install')
          ),
        NikoSettingsSection.advanced => (
            NlIcons.slidersHorizontal,
            nikoText('高级', 'Advanced'),
            nikoText('高级功能请求与完整的上游选项', 'Capability requests and the full upstream options')
          ),
        NikoSettingsSection.about => (
            NlIcons.info,
            nikoText('关于', 'About'),
            nikoText('版本、许可与诊断', 'Version, license and diagnostics')
          ),
      };

  void _open(NikoSettingsSection section) {
    if (section == _section) return;
    setState(() => _section = section);
    if (_content.hasClients) _content.jumpTo(0);
  }

  @override
  Widget build(BuildContext context) {
    final sections = _sections;
    final current = sections.contains(_section) ? _section : sections.first;
    return FocusTraversalGroup(
        child: LayoutBuilder(builder: (context, box) {
      final wide = box.maxWidth >= 760;
      final side = box.maxWidth < NlLayout.compactMax ? NlSpace.s4 : NlSpace.s6;
      return NlScrollWatcher(
          header: (context, scrolled) => NikoPageBar(
              title: nikoText('设置', 'Settings'),
              subtitle: wide
                  ? null
                  : nikoText('外观、服务器与高级选项',
                      'Appearance, server and advanced options'),
              divider: scrolled),
          child: wide
              ? _wide(context, sections, current, side)
              : ListView(
                  key: const Key('nikodesk-settings-scroll'),
                  padding: EdgeInsets.fromLTRB(
                      side, NlSpace.s2, side, NlSpace.s12),
                  children: [
                      for (final section in sections)
                        _page(context, section, wide: false),
                    ]));
    }));
  }

  Widget _wide(BuildContext context, List<NikoSettingsSection> sections,
      NikoSettingsSection current, double side) {
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SizedBox(
          width: 216,
          // The list scrolling on a short window says nothing about the page.
          child: NotificationListener<ScrollNotification>(
              onNotification: (_) => true,
              child: ListView(
                  padding: EdgeInsets.fromLTRB(
                      side - NlSpace.s2, NlSpace.s2, 0, NlSpace.s6),
                  children: [
                    for (final section in sections)
                      NlSidebarItem(
                          key: Key('nikodesk-settings-nav-${section.name}'),
                          icon: _meta(section).$1,
                          label: _meta(section).$2,
                          selected: section == current,
                          onTap: () => _open(section)),
                  ]))),
      Expanded(
          child: SingleChildScrollView(
              key: const Key('nikodesk-settings-scroll'),
              controller: _content,
              padding: EdgeInsets.fromLTRB(
                  NlSpace.s8, NlSpace.s2, side, NlSpace.s12),
              child: Align(
                  alignment: Alignment.topLeft,
                  child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 680),
                      child: AnimatedSwitcher(
                          duration: NlMotion.of(context, NlMotion.base),
                          switchInCurve: NlMotion.ease,
                          switchOutCurve: NlMotion.exit,
                          layoutBuilder: (shown, previous) => Stack(
                              alignment: Alignment.topLeft,
                              children: [...previous, if (shown != null) shown]),
                          transitionBuilder: (child, animation) =>
                              FadeTransition(
                                  opacity: animation,
                                  child: SlideTransition(
                                      position: Tween(
                                              begin: const Offset(0, .015),
                                              end: Offset.zero)
                                          .animate(animation),
                                      child: child)),
                          child: KeyedSubtree(
                              key: ValueKey(current),
                              child: _page(context, current, wide: true))))))),
    ]);
  }

  Widget _page(BuildContext context, NikoSettingsSection section,
      {required bool wide}) {
    final nl = NlColors.of(context);
    final (_, title, subtitle) = _meta(section);
    return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
              padding: EdgeInsets.only(
                  top: wide ? NlSpace.s1 : NlSpace.s6, bottom: NlSpace.s5),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Semantics(
                        header: true,
                        child: Text(title,
                            style: NlType.text(wide ? NlType.s6 : NlType.s5,
                                weight: FontWeight.w600, color: nl.fg))),
                    const SizedBox(height: 2),
                    Text(subtitle,
                        style: NlType.text(NlType.s3, color: nl.fg2)),
                  ])),
          if (_loadError != null &&
              (section == NikoSettingsSection.general ||
                  section == NikoSettingsSection.server))
            Padding(
                padding: const EdgeInsets.only(bottom: NlSpace.s5),
                child: NikoSettingNote(_loadError!,
                    tone: NlTone.danger,
                    actionLabel: nikoText('重试', 'Retry'),
                    onAction: _refresh)),
          ...switch (section) {
            NikoSettingsSection.general => _general(context),
            NikoSettingsSection.appearance => _appearance(context),
            NikoSettingsSection.server => _server(context),
            NikoSettingsSection.unattended => const [
                NikoMacBackgroundSettings(),
                NikoMacServiceSettings(relaunch: nikoRelaunch),
              ],
            NikoSettingsSection.security => const [
                NikoSettingsGroup(children: [
                  NikoAutoLockSettings(),
                  NikoPrivacySettings(),
                  NikoVirtualDisplaySettings(),
                ]),
              ],
            NikoSettingsSection.wake => const [NikoWakeProxySettings()],
            NikoSettingsSection.updates => _updates(context),
            NikoSettingsSection.advanced => _advanced(context),
            NikoSettingsSection.about => _about(context),
          },
        ]);
  }

  List<Widget> _general(BuildContext context) => [
        NikoSettingsGroup(children: [
          NikoSettingRow(
              title: nikoText('语言', 'Language'),
              description: nikoText('所有窗口一起切换', 'Applies to every window'),
              trailing: NlSegmented<bool>(
                  small: true,
                  segments: const [
                    NlSegment(value: false, label: '中文'),
                    NlSegment(value: true, label: 'English'),
                  ],
                  selected: NikoLanguage.english,
                  onChanged: _changeLanguage)),
          if (_autostart != null)
            NikoSettingRow(
                title: nikoText('登录时启动', 'Open at login'),
                description: nikoText(
                    '开关表示本应用的登录启动配置已验证；实际重新登录后运行需另行确认。不会安装特权服务，也不提供登录前被控。',
                    'The switch shows that this app’s login configuration is verified; running after a real login needs separate confirmation. It installs no privileged service and provides no pre-login control.'),
                trailing: NlSwitch(
                    value: _autostartOn,
                    onChanged: _changeAutostart,
                    semanticLabel: nikoText('登录时启动', 'Open at login'))),
        ]),
      ];

  List<Widget> _appearance(BuildContext context) => [
        NikoSettingsGroup(children: [
          NikoSettingRow(
              title: nikoText('主题', 'Theme'),
              description: nikoText('跟随系统时随电脑的浅色和深色设置切换',
                  'System follows the light or dark setting of this computer'),
              trailing: NlSegmented<ThemeMode>(
                  small: true,
                  segments: [
                    NlSegment(
                        value: ThemeMode.system,
                        icon: NlIcons.sunMoon,
                        label: nikoText('跟随系统', 'System')),
                    NlSegment(
                        value: ThemeMode.light,
                        icon: NlIcons.sun,
                        label: nikoText('浅色', 'Light')),
                    NlSegment(
                        value: ThemeMode.dark,
                        icon: NlIcons.moon,
                        label: nikoText('深色', 'Dark')),
                  ],
                  selected: _mode,
                  onChanged: _changeMode)),
          NikoSettingRow(
              title: nikoText('主题色', 'Accent'),
              description: nikoText('Orbit 是默认的蓝色；Clay 是更温暖的陶土色',
                  'Orbit is the default blue; Clay is a warmer terracotta'),
              trailing: Wrap(spacing: NlSpace.s2, children: [
                for (final preset in NlPreset.values)
                  _PresetSwatch(
                      preset: preset,
                      selected: NlColors.active == preset,
                      onTap: () => _changePreset(preset)),
              ])),
        ]),
      ];

  List<Widget> _server(BuildContext context) {
    final config = _config;
    String shown(String? value) =>
        value == null || value.isEmpty ? '—' : value;
    return [
      NikoSettingsGroup(
          trailing: NlButton.ghost(
              small: true,
              icon: NlIcons.squarePen,
              onPressed: _gateway == null ? null : _configure,
              label: nikoText('配置服务器', 'Configure server')),
          title: nikoText('连接', 'Connection'),
          children: [
            NikoSettingRow(
                title: nikoText('ID 服务器', 'ID server'),
                trailing: NikoSettingValue(shown(config?.idServer), mono: true)),
            NikoSettingRow(
                title: nikoText('中继服务器', 'Relay server'),
                trailing:
                    NikoSettingValue(shown(config?.relayServer), mono: true)),
            NikoSettingRow(
                title: nikoText('公钥', 'Public key'),
                trailing: NikoSettingValue(_maskedKey(), mono: true)),
            NikoSettingRow(
                title: nikoText('注册状态', 'Registration'),
                trailing: NikoSettingValue(_registrationLabel(),
                    leading: NlLed(_registrationLed))),
          ]),
      NikoSettingNote(
          nikoText('未配置或配置错误时不回退公共协调服务。',
              'Never falls back to public rendezvous services.'),
          tone: NlTone.ok),
    ];
  }

  List<Widget> _updates(BuildContext context) {
    final busy = _checkingUpdate || _openingUpdate;
    final staged = _stagedMacUpdate;
    return [
      NikoSettingsGroup(children: [
        NikoSettingRow(
            leading: const NlMark(size: 36),
            title: _buildInfoLoading
                ? nikoText('正在读取本机版本…', 'Reading installed version…')
                : 'NikoDesk ${_buildInfo.fullVersion}',
            description: _updateChannel == NikoUpdateChannel.stable
                ? nikoText('正式版渠道', 'Stable channel')
                : nikoText('预览版渠道', 'Nightly channel'),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              if (_checkingUpdate) ...[
                NlButton.quiet(
                    small: true,
                    onPressed: () => _updateCancellation?.cancel(),
                    label: nikoText('取消', 'Cancel')),
                const SizedBox(width: NlSpace.s2),
              ],
              if (_downloadingUpdate)
                SizedBox(
                    width: 120,
                    child: ClipRRect(
                        borderRadius: BorderRadius.circular(NlRadius.pill),
                        child: LinearProgressIndicator(
                            value: _updateProgress, minHeight: 4)))
              else
                NlButton(
                    small: true,
                    loading: _checkingUpdate,
                    onPressed: busy ? null : _checkForUpdate,
                    label: nikoText('检查更新', 'Check for updates')),
            ]),
            below: _updateStatus == null
                ? null
                : NikoSettingNote(_updateStatus!,
                    textKey: const Key('nikodesk-update-status'))),
        NikoSettingRow(
            title: nikoText('更新渠道', 'Update channel'),
            description: _updateChannel == NikoUpdateChannel.stable
                ? nikoText('只接收正式发布的版本', 'Published releases only')
                : nikoText('随 main 更新，可能尚未完成真机验收',
                    'Follows main and may still be awaiting device acceptance'),
            trailing: NlSegmented<NikoUpdateChannel>(
                key: const Key('nikodesk-update-channel'),
                small: true,
                segments: [
                  NlSegment(
                      value: NikoUpdateChannel.stable,
                      label: nikoText('正式版', 'Stable')),
                  NlSegment(
                      value: NikoUpdateChannel.nightly,
                      label: nikoText('预览版', 'Nightly')),
                ],
                selected: _updateChannel,
                onChanged: busy
                    ? null
                    : (channel) => setState(() => _updateChannel = channel))),
        if (_native && Platform.isMacOS) const NikoUpdateModeSettings(),
      ]),
      if (staged != null)
        NikoSettingsGroup(
            title: _stagedMacReady
                ? nikoText('$_stagedMacVersion 安装包已校验，仍需手动安装',
                    '$_stagedMacVersion installer checked; manual installation required')
                : nikoText('保留了 $_stagedMacVersion 的文件，安装前需重新校验',
                    '$_stagedMacVersion files retained; recheck before installation'),
            children: [
              NikoSettingRow(
                  title: nikoText('安装包位置', 'Installer location'),
                  description: _stagedMacReady
                      ? nikoText(
                          '1. 保存工作并结束远控会话，然后手动退出 NikoDesk。\n2. 在 Finder 将准备好的 NikoDesk.app 复制到原安装位置，按系统提示确认替换。\n3. 从原安装位置重新打开 NikoDesk，在本页核对版本。手动安装时应用不会自行替换或重启。\n升级可能需要重新授予 macOS 权限；请保留备用远控入口。',
                          '1. Save your work and end remote sessions, then quit NikoDesk manually.\n2. In Finder, copy the prepared NikoDesk.app to its original installation location and confirm replacement when prompted.\n3. Reopen NikoDesk from that location and check the version here. When installing by hand, the app does not replace itself or restart.\nmacOS permissions may need to be granted again; keep a backup remote-access path.')
                      : nikoText('请先重新校验并在 Finder 显示，成功前不要安装这些文件。也可从发布页重新下载。',
                          'Recheck and show the files in Finder before installation. Do not install them until this succeeds, or download again from the release page.'),
                  below: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SelectableText('${staged.path}/mac/NikoDesk.app',
                            key: const Key('nikodesk-update-staged-path'),
                            style: NlType.monoText(NlType.s2,
                                color: NlColors.of(context).fg)),
                        const SizedBox(height: NlSpace.s3),
                        Wrap(
                            spacing: NlSpace.s2,
                            runSpacing: NlSpace.s2,
                            children: [
                              if (_stagedMacReady && _native && Platform.isMacOS)
                                NikoMacUpdateInstallButton(
                                    staging: staged,
                                    onStatus: _showUpdateStatus),
                              NlButton.ghost(
                                  small: true,
                                  icon: NlIcons.folderOpen,
                                  onPressed: busy ? null : () => _revealUpdate(),
                                  label: nikoText(
                                      '在 Finder 显示安装包', 'Show installer in Finder')),
                            ]),
                        const SizedBox(height: NlSpace.s2),
                        NikoSettingNote(nikoText(
                            '安装前请记下文件位置；关闭此页后，可在 Finder 中按该位置找到文件。',
                            'Keep the file location before closing this page so you can find the files in Finder later.')),
                      ])),
            ]),
      if (_updatePage != null)
        NikoSettingsGroup(children: [
          NikoSettingRow(
              title: nikoText('发布页', 'Release page'),
              trailing: NlButton.ghost(
                  small: true,
                  icon: NlIcons.externalLink,
                  onPressed: busy ? null : _openUpdatePage,
                  label: nikoText('打开发布页', 'Open release page')),
              below: SelectableText(_updatePage.toString(),
                  key: const Key('nikodesk-update-release-url'),
                  style: NlType.monoText(NlType.s2,
                      color: NlColors.of(context).fg2))),
        ]),
      NikoSettingNote(_updater.publisher.configured
          ? nikoText('macOS 更新使用内置发行公钥验证签名与 SHA256，再手动安装。系统签名与公证状态请参阅发布说明。',
              'macOS updates verify a signed SHA256 manifest with the built-in publisher key before manual installation. See release notes for OS signing and notarization status.')
          : nikoText('此构建未配置发行验证公钥，更新仅提供手动下载入口。SHA256 本身不能确认发行者。',
              'No publisher verification key is configured in this build. Updates offer manual download only. SHA256 alone does not authenticate a publisher.')),
    ];
  }

  List<Widget> _advanced(BuildContext context) {
    void scoped(void Function(String namespace) open) {
      final namespace = NikoServerScope.current;
      if (namespace == null) {
        nikoNotice(context,
            nikoText('请先配置有效的私有服务器。', 'Configure a valid private server first.'));
        return;
      }
      open(namespace);
    }

    return [
      NikoSettingsGroup(children: [
        if (_native && (Platform.isMacOS || Platform.isWindows))
          NikoSettingRow(
              title: nikoText('高级功能请求', 'Advanced capability requests'),
              description: nikoText('默认关闭；允许请求后仍需每次单独批准。',
                  'Off by default. Every request still needs separate approval.'),
              onTap: () => scoped((namespace) => showNikoCapabilityPolicy(
                  context, nativeNikoCapabilityPolicy, namespace))),
        if (_native)
          NikoSettingRow(
              title: nikoText('查看旧连接偏好', 'Review legacy connection preferences'),
              description: nikoText('选择设备归属当前私服；保留原文件，不导入密码。',
                  'Attribute selected devices to this server. Preserve originals without importing passwords.'),
              onTap: () => scoped((namespace) => showNikoPeerPreferences(
                  context, nativeNikoPeerPreferences, namespace))),
        NikoSettingRow(
            title: nikoText('打开高级设置', 'Open advanced settings'),
            description: nikoText('安全、网络、显示、编解码等完整上游选项。',
                'Full upstream options for security, network, display and codecs.'),
            onTap: widget.onOpenAdvanced),
      ]),
    ];
  }

  List<Widget> _about(BuildContext context) {
    final nl = NlColors.of(context);
    return [
      Padding(
          padding: const EdgeInsets.only(bottom: NlSpace.s6),
          child: Row(children: [
            const NlMark(size: 52),
            const SizedBox(width: NlSpace.s4),
            Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Text('NikoDesk',
                      style: NlType.text(NlType.s6,
                          weight: FontWeight.w600, color: nl.fg)),
                  Text(
                      nikoText('私有服务器上的远程桌面', 'Remote desktop on your own server'),
                      style: NlType.text(NlType.s3, color: nl.fg2)),
                ])),
          ])),
      NikoSettingsGroup(children: [
        if (_buildInfoLoading)
          Semantics(
              liveRegion: true,
              child: NikoSettingRow(
                  busy: true,
                  title: nikoText('正在读取版本信息…', 'Reading version information…')))
        else ...[
          NikoProductInfoRows(info: _buildInfo, buildDate: _buildDate),
          if (_buildInfo.hasUnknown)
            Padding(
                padding: const EdgeInsets.symmetric(vertical: NlSpace.s2),
                child: Align(
                    alignment: Alignment.centerLeft,
                    child: NlButton.ghost(
                        key: const Key('nikodesk-version-retry'),
                        small: true,
                        icon: NlIcons.refreshCw,
                        onPressed: _refreshBuildInfo,
                        label: nikoText('重试读取版本', 'Retry version read')))),
        ],
        NikoSettingRow(
            title: nikoText('边界', 'Boundaries'),
            trailing: NikoSettingValue(nikoText(
                '仅私服 · 本地签名', 'Private-server only · locally signed'))),
      ]),
      if (_native && (Platform.isMacOS || Platform.isWindows))
        NikoSettingsGroup(children: [
          NikoSettingRow(
              title: nikoText('诊断包', 'Diagnostics'),
              description: nikoText('导出日志与配置摘要，便于排查问题；不含密码与私钥。',
                  'Export logs and a configuration summary for troubleshooting; passwords and private keys are left out.'),
              trailing: const NikoDiagnosticsExportButton()),
        ]),
    ];
  }

  NlLedState get _registrationLed {
    if (_loadError != null || !_enabled) return NlLedState.off;
    return switch (_registration) {
      1 => NlLedState.ok,
      0 => NlLedState.warn,
      -1 => NlLedState.danger,
      _ => NlLedState.off,
    };
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
}

/// One colour preset, shown as its accent dot and name.
class _PresetSwatch extends StatelessWidget {
  final NlPreset preset;
  final bool selected;
  final VoidCallback onTap;
  const _PresetSwatch(
      {required this.preset, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final nl = NlColors.of(context);
    final swatch = NlColors.palette(preset, nl.brightness);
    final name = switch (preset) {
      NlPreset.orbit => 'Orbit',
      NlPreset.clay => 'Clay',
    };
    return Semantics(
        button: true,
        selected: selected,
        label: name,
        excludeSemantics: true,
        child: NlPressable(
            key: Key('nikodesk-preset-${preset.name}'),
            onTap: onTap,
            builder: (context, states) => AnimatedContainer(
                duration: NlMotion.of(context, NlMotion.fast),
                height: NlLayout.touch(context) ? 40 : 30,
                padding: const EdgeInsets.symmetric(horizontal: NlSpace.s3),
                decoration: BoxDecoration(
                    color: selected
                        ? nl.accentSoft
                        : states.contains(WidgetState.hovered)
                            ? nl.hover
                            : Colors.transparent,
                    borderRadius: BorderRadius.circular(NlRadius.r2),
                    border: Border.all(
                        color: selected ? nl.accent : nl.line2,
                        width: selected ? 1.5 : 1),
                    boxShadow: states.contains(WidgetState.focused)
                        ? nl.focusRing
                        : null),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Container(
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: swatch.accent,
                          border: Border.all(color: swatch.accentFill))),
                  const SizedBox(width: NlSpace.s2),
                  Text(name,
                      style: NlType.text(NlType.s3,
                          weight: FontWeight.w500, color: nl.fg)),
                ]))));
  }
}
