import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/models/platform_model.dart';

import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'autostart.dart';
import 'policy.dart';
import 'updater.dart';
import 'server_gateway.dart';
import 'server_settings.dart';
import 'theme.dart';
import 'ui.dart';

/// Settings page of the NikoDesk home: private server, appearance, language,
/// autostart, and a hosted entry into the full upstream settings.
class NikoSettingsView extends StatefulWidget {
  final ServerGateway? gateway;
  final bool native;
  final VoidCallback? onServerSaved;
  final VoidCallback? onOpenAdvanced;
  final NikoAutostart? autostart;
  const NikoSettingsView(
      {super.key,
      this.gateway,
      this.native = true,
      this.onServerSaved,
      this.onOpenAdvanced,
      this.autostart});

  @override
  State<NikoSettingsView> createState() => _NikoSettingsViewState();
}

class _NikoSettingsViewState extends State<NikoSettingsView> {
  final _updater = const NikoUpdater();
  String _appVersion = '';
  bool _checkingUpdate = false;
  bool _downloadingUpdate = false;
  double? _updateProgress;
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

  Future<void> _refresh() async {
    PrivateServerConfig? config;
    int? registration;
    var enabled = false;
    var mode = _mode;
    var autostartOn = false;
    var appVersion = '';
    String? buildDate;
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
        buildDate = await bind.mainGetBuildDate();
        final info = await PackageInfo.fromPlatform();
        appVersion = info.version;
      }
      final autostart = _autostart;
      if (autostart != null) {
        autostartOn = autostart.enabled;
      }
    } catch (_) {
      error = nikoText('读取设置失败，可重试。', 'Could not read settings. Retry.');
    }
    if (!mounted) return;
    setState(() {
      _config = config ?? _config;
      _registration = registration;
      _enabled = enabled;
      _mode = mode;
      _autostartOn = autostartOn;
      _appVersion = appVersion;
      _buildDate = buildDate;
      _loadError = error;
    });
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
    if (!_native) return;
    final language = english ? 'en' : 'zh-cn';
    await bind.mainSetLocalOption(key: 'lang', value: language);
    await bind.mainChangeLanguage(lang: language);
    await reloadAllWindows();
  }

  Future<void> _checkForUpdate() async {
    if (_checkingUpdate || !_native) return;
    setState(() => _checkingUpdate = true);
    try {
      final release = await _updater.checkLatest();
      final info = await PackageInfo.fromPlatform();
      if (!mounted) return;
      if (release == null) {
        nikoNotice(
            context,
            nikoText('暂无已发布版本。', 'No published release yet.'));
        return;
      }
      if (!_updater.isNewer(info.version, release.tag)) {
        nikoNotice(
            context,
            nikoText('已是最新版本（${release.tag}）。',
                'Up to date (${release.tag}).'));
        return;
      }
      final macAsset = release.assetFor('macos-arm64');
      final confirmed = await showDialog<bool>(
          context: context,
          builder: (dialog) => AlertDialog(
                title: Text(nikoText('发现新版本', 'Update available')),
                content: SizedBox(
                    width: 420,
                    child: SingleChildScrollView(
                        child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                          Text(release.tag,
                              style: const TextStyle(
                                  fontWeight: FontWeight.w700)),
                          const SizedBox(height: 6),
                          Text(nikoText(
                              '当前版本 ${info.version} → 新版本 ${release.tag}',
                              'Current ${info.version} → ${release.tag}')),
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
                                  ? nikoText(
                                      '本平台请从 GitHub Releases 下载更新包。',
                                      'Download the update from GitHub Releases for this platform.')
                                  : nikoText(
                                      '下载将通过 HTTPS 校验 SHA256 后替换 /Applications/NikoDesk.app。',
                                      'Downloads over HTTPS, verifies SHA256, then replaces the installed app.'),
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
                          : nikoText('立即更新', 'Update now'))),
                ],
              ));
      if (confirmed != true) return;
      if (macAsset == null) {
        await launchUrl(Uri.https('github.com',
            '/${_updater.owner}/${_updater.repo}/releases/latest'));
        return;
      }
      await _applyMacUpdate(release, macAsset);
    } catch (_) {
      if (mounted) {
        nikoNotice(
            context,
            nikoText('检查更新失败，请稍后重试。', 'Update check failed. Retry later.'));
      }
    } finally {
      if (mounted) setState(() => _checkingUpdate = false);
    }
  }

  Future<void> _applyMacUpdate(
      NikoReleaseInfo release, NikoReleaseAsset asset) async {
    setState(() {
      _downloadingUpdate = true;
      _updateProgress = null;
    });
    try {
      final staging = Directory.systemTemp.createTempSync('nikodesk-update-');
      final ok = await _updater.verifyAndStageMacUpdate(
          release, asset, staging,
          onProgress: (received, total) {
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
        staging.deleteSync(recursive: true);
        return;
      }
      nikoNotice(
          context, nikoText('校验通过，正在替换并重启…', 'Verified, swapping and restarting…'));
      await Future<void>.delayed(const Duration(milliseconds: 800));
      _updater.applyStagedMacUpdate(staging);
      exit(0);
    } catch (_) {
      if (mounted) {
        nikoNotice(
            context,
            nikoText('更新失败，当前版本未受影响。', 'Update failed. Current version is untouched.'));
      }
    } finally {
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
    final muted = nikoIsLight(context)
        ? NikoPalette.lightMuted
        : NikoPalette.darkMuted;
    return FocusTraversalGroup(
        child: ListView(padding: const EdgeInsets.all(NikoTokens.pagePadding), children: [
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(nikoText('设置', 'Settings'),
            style: Theme.of(context)
                .textTheme
                .headlineMedium
                ?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        Text(nikoText('外观、服务器与高级选项。', 'Appearance, server and advanced options.'),
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
                  value: ThemeMode.dark, label: Text(nikoText('暗黑', 'Dark'))),
            ],
            selected: {_mode},
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
            selected: {NikoLanguage.english ? 1 : 0},
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
              title:
                  Text(nikoText('登录后自动启动', 'Start automatically after login')),
              subtitle: Text(nikoText(
                  '用户级 LaunchAgent，无需管理员权限；仅在本用户登录后可达，不提供开机（登录前）被控。',
                  'User-level LaunchAgent, no administrator rights. Reachable only after this user logs in; no pre-login control.'))),
        ]),
      const SizedBox(height: 16),
      _section(context, nikoText('软件更新', 'Software update'), [
        Row(children: [
          Icon(Icons.system_update_rounded, color: muted),
          const SizedBox(width: 10),
          Expanded(
              child: Text(
                  _appVersion.isEmpty
                      ? nikoText('NikoDesk', 'NikoDesk')
                      : 'NikoDesk $_appVersion',
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
        ]),
        const SizedBox(height: 6),
        Text(
            nikoText('更新来自 GitHub Releases，HTTPS 传输并校验 SHA256 后替换本机应用。',
                'Updates come from GitHub Releases over HTTPS; SHA256 is verified before replacing the installed app.'),
            style: TextStyle(fontSize: 11.5, color: muted)),
      ]),
      const SizedBox(height: 16),
      _section(context, nikoText('高级', 'Advanced'), [
        ListTile(
          leading: Icon(Icons.tune_rounded, color: muted),
          title: Text(nikoText('打开高级设置', 'Open advanced settings')),
          subtitle: Text(
              nikoText('安全、网络、显示、编解码等完整上游选项。',
                  'Full upstream options for security, network, display and codecs.')),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: widget.onOpenAdvanced,
        ),
      ]),
      const SizedBox(height: 16),
      _section(context, nikoText('关于', 'About'), [
        _row(context, nikoText('应用', 'App'),
            _appVersion.isEmpty ? 'NikoDesk' : 'NikoDesk $_appVersion'),
        _row(context, nikoText('内核', 'Core'),
            nikoText('RustDesk 1.5.0 · AGPL v3', 'RustDesk 1.5.0 · AGPL v3')),
        if (_buildDate != null && _buildDate!.isNotEmpty)
          _row(context, nikoText('构建', 'Build'), _buildDate!),
        _row(context, nikoText('边界', 'Boundaries'),
            nikoText('仅私服 · 无自动更新 · 本地签名', 'Private-server only · no auto update · locally signed')),
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
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 12),
                ...children,
              ]));

  Widget _row(BuildContext context, String label, String value) {
    final muted = nikoIsLight(context)
        ? NikoPalette.lightMuted
        : NikoPalette.darkMuted;
    return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(
              width: 92,
              child: Text(label,
                  style: TextStyle(fontSize: 12.5, color: muted))),
          Expanded(
              child: Text(value,
                  style: const TextStyle(
                      fontSize: 12.5, fontWeight: FontWeight.w600))),
        ]));
  }
}
