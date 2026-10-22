import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/utils/multi_window_manager.dart';
import 'package:flutter_hbb/utils/platform_channel.dart';

import 'mac_service_settings.dart';
import 'product_build_info.dart';
import 'ui.dart';
import 'updater.dart';

/// Installing verified macOS updates through the privileged service (C13).
/// The app only hands over the bundle it downloaded, verified and staged; the
/// service copies it where the user can no longer change it, checks that copy
/// (fixed certificate, newer version), swaps it into /Applications and puts
/// the previous app back after any failure.

/// Whether a newer release installs itself (when idle) or only reminds.
/// Installing needs the privileged service; without it both modes remind.
enum NikoUpdateMode { remind, auto }

const _modeOption = 'nikodesk-update-mode';
const _remindedOption = 'nikodesk-update-reminded';

NikoUpdateMode nikoUpdateMode() =>
    bind.mainGetLocalOption(key: _modeOption) == 'auto'
        ? NikoUpdateMode.auto
        : NikoUpdateMode.remind;

Future<void> setNikoUpdateMode(NikoUpdateMode mode) => bind.mainSetLocalOption(
    key: _modeOption, value: mode == NikoUpdateMode.auto ? 'auto' : '');

/// Remote sessions in either direction: people controlling this Mac, and the
/// windows this app opened to control others.
Future<int> nikoActiveSessions() async {
  var incoming = 0;
  try {
    final status = jsonDecode(await bind.mainGetConnectStatus());
    if (status is Map && status['video_conn_count'] is int) {
      incoming = status['video_conn_count'];
    }
  } catch (_) {
    // An unreadable status must not count as idle.
    incoming = 1;
  }
  return incoming + (await rustDeskWinManager.getAllSubWindowIds()).length;
}

/// Opens /Applications/NikoDesk.app again once this process has exited (`open`
/// would only bring a running copy to the front), then quits.
Future<void> nikoRelaunch() async {
  await Process.start(
      '/bin/sh',
      [
        '-c',
        'for i in \$(seq 1 150); do kill -0 $pid 2>/dev/null || break; sleep 0.2; done; '
            '/usr/bin/open /Applications/NikoDesk.app'
      ],
      mode: ProcessStartMode.detached);
  // The core belongs to the service's agent, so nothing else stops with this
  // window; exit even if the platform channel does not answer.
  Timer(const Duration(seconds: 3), () => exit(0));
  await RdPlatformChannel.instance.terminate();
}

enum NikoInstallState { installed, deferred, unavailable, failed }

class NikoInstallResult {
  final NikoInstallState state;

  /// The installed version, or the failure code.
  final String detail;
  const NikoInstallResult(this.state, [this.detail = '']);
}

class NikoMacUpdateInstaller {
  final NikoMacServiceGateway service;
  final Future<String> Function(Directory staging) recheck;
  final Future<int> Function() sessions;

  NikoMacUpdateInstaller(
      {this.service = const NikoMacServiceGateway(),
      Future<String> Function(Directory staging)? recheck,
      Future<int> Function()? sessions})
      : recheck = recheck ?? const NikoUpdater().recheckStagedMacUpdate,
        sessions = sessions ?? nikoActiveSessions;

  /// Installs the update staged in `staging` unless a session is active.
  /// Every refusal leaves the installed app as it was.
  Future<NikoInstallResult> install(Directory staging) async {
    if (await sessions() > 0) {
      return const NikoInstallResult(NikoInstallState.deferred);
    }
    if (!(await service.state()).canInstallUpdates) {
      return const NikoInstallResult(NikoInstallState.unavailable);
    }
    final String bundle;
    try {
      bundle = await recheck(staging);
    } catch (_) {
      return const NikoInstallResult(NikoInstallState.failed, 'staged_invalid');
    }
    final answer = await service.call('install_update', bundle: bundle);
    if (!answer.ok) {
      return NikoInstallResult(NikoInstallState.failed, answer.code);
    }
    try {
      await staging.delete(recursive: true);
    } catch (_) {
      debugPrint('nikodesk update: staging cleanup failed');
    }
    return NikoInstallResult(NikoInstallState.installed, answer.detail);
  }
}

String nikoInstallMessage(NikoInstallResult result) => switch (result.state) {
      NikoInstallState.installed => nikoText(
          '已安装 ${result.detail}，NikoDesk 正在重新打开。',
          'Installed ${result.detail}; NikoDesk is reopening.'),
      NikoInstallState.deferred => nikoText(
          '有远控会话或会话窗口未关闭，结束后再安装。当前版本未更改。',
          'A remote session or session window is open. Install after it ends; the installed version is unchanged.'),
      NikoInstallState.unavailable => nikoText(
          '需要先在“无人值守”中安装系统后台服务，并从“应用程序”文件夹打开 NikoDesk。',
          'Install the system background service under Unattended access and open NikoDesk from the Applications folder first.'),
      NikoInstallState.failed => result.detail == 'staged_invalid'
          ? nikoText('安装包重新校验失败，请重新检查更新。当前版本未更改。',
              'The package failed its recheck. Check for updates again; the installed version is unchanged.')
          : nikoMacServiceError(result.detail),
    };

enum NikoScheduledOutcome { none, reminded, installed, deferred, failed }

/// Checks for a newer stable release while the app runs: three minutes after
/// start, then every six hours. In auto mode, with the service ready, the
/// release is downloaded, verified and installed once no session is active.
class NikoUpdateSchedule {
  final NikoUpdater updater;
  final NikoMacServiceGateway service;
  final NikoMacUpdateInstaller installer;
  final Future<ProductBuildInfo> Function() installed;
  final NikoUpdateMode Function() mode;
  final void Function(NikoReleaseInfo release) remind;
  final Future<void> Function() relaunch;
  final Future<int> Function() sessions;
  final Duration idlePoll, idleLimit;

  /// The newer release the last check found.
  final available = ValueNotifier<NikoReleaseInfo?>(null);
  bool _running = false;
  bool _started = false;

  NikoUpdateSchedule(
      {this.updater = const NikoUpdater(),
      this.service = const NikoMacServiceGateway(),
      NikoMacUpdateInstaller? installer,
      Future<ProductBuildInfo> Function()? installed,
      this.mode = nikoUpdateMode,
      this.remind = _remindOnce,
      this.relaunch = nikoRelaunch,
      Future<int> Function()? sessions,
      this.idlePoll = const Duration(minutes: 1),
      this.idleLimit = const Duration(hours: 12)})
      : installer = installer ?? NikoMacUpdateInstaller(),
        installed = installed ??
            (() => ProductBuildInfo.read(nativeVersionLoader: bind.mainGetVersion)),
        sessions = sessions ?? nikoActiveSessions;

  static final instance = NikoUpdateSchedule();

  void start() {
    if (_started) return;
    _started = true;
    Timer(const Duration(minutes: 3), _tick);
    Timer(const Duration(seconds: 30), () => unawaited(syncServiceCopy()));
  }

  /// After an update installed by hand, root's copy of the app follows it;
  /// the service itself never moves that copy back to an older version.
  Future<bool> syncServiceCopy() async {
    try {
      final state = await service.state();
      final app = state.version('installed');
      if (!state.canInstallUpdates || app == null || app == state.version('service')) {
        return false;
      }
      return (await service.call('sync')).ok;
    } catch (_) {
      return false;
    }
  }

  Future<void> _tick() async {
    try {
      final outcome = await runOnce();
      if (outcome == NikoScheduledOutcome.installed) {
        await relaunch();
        return;
      }
    } catch (_) {
      debugPrint('nikodesk update: scheduled check failed');
    }
    Timer(const Duration(hours: 6), _tick);
  }

  /// One check; never runs twice at the same time.
  Future<NikoScheduledOutcome> runOnce() async {
    if (_running) return NikoScheduledOutcome.none;
    _running = true;
    try {
      return await _check();
    } finally {
      _running = false;
    }
  }

  Future<NikoScheduledOutcome> _check() async {
    final release = await updater.checkLatest();
    if (release == null || release.isNightly) return NikoScheduledOutcome.none;
    final local = await installed();
    if (local.relationTo(release.tag) != PublishedVersionRelation.newerRelease) {
      available.value = null;
      return NikoScheduledOutcome.none;
    }
    available.value = release;
    final asset = updater.publisher.configured ? release.assetFor('macos-arm64') : null;
    if (mode() != NikoUpdateMode.auto ||
        asset == null ||
        !(await service.state()).canInstallUpdates) {
      remind(release);
      return NikoScheduledOutcome.reminded;
    }
    final staging = await Directory.systemTemp.createTemp('nikodesk-update-');
    var keep = false;
    try {
      if (!await updater.verifyAndStageMacUpdate(release, asset, staging)) {
        return NikoScheduledOutcome.failed;
      }
      final waited = Stopwatch()..start();
      while (await sessions() > 0) {
        if (waited.elapsed >= idleLimit) return NikoScheduledOutcome.deferred;
        await Future.delayed(idlePoll);
      }
      final result = await installer.install(staging);
      keep = result.state == NikoInstallState.installed;
      return switch (result.state) {
        NikoInstallState.installed => NikoScheduledOutcome.installed,
        NikoInstallState.deferred => NikoScheduledOutcome.deferred,
        _ => NikoScheduledOutcome.failed,
      };
    } finally {
      // The installer removes the staging directory itself on success.
      if (!keep && await staging.exists()) {
        try {
          await staging.delete(recursive: true);
        } catch (_) {
          debugPrint('nikodesk update: staging cleanup failed');
        }
      }
    }
  }
}

/// A short notice, once per release.
void _remindOnce(NikoReleaseInfo release) {
  if (bind.mainGetLocalOption(key: _remindedOption) == release.tag) return;
  unawaited(bind.mainSetLocalOption(key: _remindedOption, value: release.tag));
  showToast(
      nikoText('NikoDesk ${release.tag} 可以更新了，可在“设置 → 软件更新”中安装。',
          'NikoDesk ${release.tag} is available. Install it in Settings → Software update.'),
      timeout: const Duration(seconds: 8));
}
