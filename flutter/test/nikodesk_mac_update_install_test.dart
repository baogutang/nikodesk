import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/nikodesk/mac_service_settings.dart';
import 'package:flutter_hbb/nikodesk/mac_update_install.dart';
import 'package:flutter_hbb/nikodesk/mac_update_settings.dart';
import 'package:flutter_hbb/nikodesk/nightline.dart';
import 'package:flutter_hbb/nikodesk/product_build_info.dart';
import 'package:flutter_hbb/nikodesk/update_publisher.dart';
import 'package:flutter_hbb/nikodesk/updater.dart';
import 'package:flutter_test/flutter_test.dart';

const _ready = NikoMacServiceState(
    installed: true,
    appSigned: true,
    inApplications: true,
    reachable: true,
    versions: 'installed=1.0.11+22 service=1.0.11+22 previous=none');

class _Service extends NikoMacServiceGateway {
  NikoMacServiceState current;
  NikoMacServiceAnswer answer;
  final calls = <String>[];
  _Service(this.current,
      {this.answer = const NikoMacServiceAnswer(true, 'installed', '2.0.0+23')});
  @override
  Future<NikoMacServiceState> state() async => current;
  @override
  Future<NikoMacServiceAnswer> call(String op, {String bundle = ''}) async {
    calls.add('$op $bundle');
    return answer;
  }
}

class _Updater extends NikoUpdater {
  final NikoReleaseInfo? release;
  final bool stages;
  int staged = 0;
  _Updater(this.release, {this.stages = true})
      : super(
            publisher: NikoUpdatePublisher(
                publicKeyBase64: base64Encode(utf8.encode(
                    '-----BEGIN PUBLIC KEY-----\nAAAA\n-----END PUBLIC KEY-----\n'))));
  @override
  Future<NikoReleaseInfo?> checkLatest(
          {NikoUpdateChannel channel = NikoUpdateChannel.stable,
          NikoUpdateCancellation? cancellation}) async =>
      release;
  @override
  Future<bool> verifyAndStageMacUpdate(
      NikoReleaseInfo release, NikoReleaseAsset asset, Directory staging,
      {void Function(int received, int total)? onProgress,
      void Function(NikoUpdatePhase phase)? onPhase,
      NikoUpdateCancellation? cancellation}) async {
    staged++;
    if (!stages) return false;
    await Directory('${staging.path}/mac/NikoDesk.app').create(recursive: true);
    return true;
  }
}

final _release = NikoReleaseInfo(tag: 'v2.0.0', notes: '', assets: [
  NikoReleaseAsset('NikoDesk-macos-arm64.zip',
      Uri.https('github.com', '/baogutang/nikodesk/releases/download/v2.0.0/NikoDesk-macos-arm64.zip'))
]);

Future<ProductBuildInfo> _installed() async =>
    const ProductBuildInfo(version: '1.0.11', buildNumber: '22', nativeVersion: '1.0.11');

void main() {
  late Directory staging;
  setUp(() async {
    staging = await Directory.systemTemp.createTemp('niko-update-test-');
    await Directory('${staging.path}/mac/NikoDesk.app').create(recursive: true);
  });
  tearDown(() async {
    if (await staging.exists()) await staging.delete(recursive: true);
  });

  NikoMacUpdateInstaller installer(_Service service,
          {int sessions = 0, bool recheckFails = false}) =>
      NikoMacUpdateInstaller(
          service: service,
          sessions: () async => sessions,
          recheck: (dir) async {
            if (recheckFails) throw const FormatException('changed');
            return '${dir.path}/mac/NikoDesk.app';
          });

  test('the service answers and the state are read defensively', () {
    expect(NikoMacServiceAnswer.parse('{"ok":true,"code":"installed","detail":"2.0.0+23"}').detail,
        '2.0.0+23');
    expect(NikoMacServiceAnswer.parse('garbage').code, 'unreadable_answer');
    expect(_ready.version('installed'), '1.0.11+22');
    expect(_ready.version('previous'), isNull);
    expect(const NikoMacServiceState(reachable: true, appSigned: true).canInstallUpdates, isFalse,
        reason: 'only the app in /Applications is updated');
  });

  test('an active session defers the install without asking the service', () async {
    final service = _Service(_ready);
    final result = await installer(service, sessions: 1).install(staging);
    expect(result.state, NikoInstallState.deferred);
    expect(service.calls, isEmpty);
    expect(await staging.exists(), isTrue);
  });

  test('without a usable service nothing is installed', () async {
    final service = _Service(const NikoMacServiceState(installed: true, reachable: true, appSigned: true));
    expect((await installer(service).install(staging)).state, NikoInstallState.unavailable);
    expect(service.calls, isEmpty);
  });

  test('a package that changed after staging is not handed over', () async {
    final service = _Service(_ready);
    final result = await installer(service, recheckFails: true).install(staging);
    expect([result.state, result.detail], [NikoInstallState.failed, 'staged_invalid']);
    expect(service.calls, isEmpty);
  });

  test('the service installs the rechecked bundle; staging is removed', () async {
    final service = _Service(_ready);
    final result = await installer(service).install(staging);
    expect([result.state, result.detail], [NikoInstallState.installed, '2.0.0+23']);
    expect(service.calls, ['install_update ${staging.path}/mac/NikoDesk.app']);
    expect(await staging.exists(), isFalse);
  });

  test('a refusal keeps the package and reports the service code', () async {
    final service = _Service(_ready,
        answer: const NikoMacServiceAnswer(false, 'installed_check_failed_restored'));
    final result = await installer(service).install(staging);
    expect([result.state, result.detail],
        [NikoInstallState.failed, 'installed_check_failed_restored']);
    expect(nikoInstallMessage(result), contains('已恢复原来的版本'));
    expect(await staging.exists(), isTrue);
  });

  group('scheduled checks', () {
    NikoUpdateSchedule schedule(_Updater updater, _Service service,
            {NikoUpdateMode mode = NikoUpdateMode.auto,
            List<String>? reminded,
            int sessions = 0}) =>
        NikoUpdateSchedule(
            updater: updater,
            service: service,
            installer: installer(service, sessions: sessions),
            installed: _installed,
            mode: () => mode,
            remind: (release) => reminded?.add(release.tag),
            relaunch: () async {},
            sessions: () async => sessions,
            idlePoll: const Duration(milliseconds: 1),
            idleLimit: const Duration(milliseconds: 20));

    test('nothing newer: no reminder and nothing downloaded', () async {
      final updater = _Updater(NikoReleaseInfo(tag: 'v1.0.11', notes: '', assets: _release.assets));
      final reminded = <String>[];
      final run = schedule(updater, _Service(_ready), reminded: reminded);
      expect(await run.runOnce(), NikoScheduledOutcome.none);
      expect([reminded, updater.staged, run.available.value], [[], 0, null]);
    });

    test('remind mode only reminds', () async {
      final updater = _Updater(_release);
      final reminded = <String>[];
      final service = _Service(_ready);
      final run = schedule(updater, service, mode: NikoUpdateMode.remind, reminded: reminded);
      expect(await run.runOnce(), NikoScheduledOutcome.reminded);
      expect([reminded, updater.staged, service.calls], [['v2.0.0'], 0, []]);
      expect(run.available.value?.tag, 'v2.0.0');
    });

    test('auto mode without the service falls back to a reminder', () async {
      final updater = _Updater(_release);
      final reminded = <String>[];
      final run = schedule(updater, _Service(const NikoMacServiceState()), reminded: reminded);
      expect(await run.runOnce(), NikoScheduledOutcome.reminded);
      expect([reminded, updater.staged], [['v2.0.0'], 0]);
    });

    test('auto mode downloads, verifies and installs when idle', () async {
      final updater = _Updater(_release);
      final service = _Service(_ready);
      expect(await schedule(updater, service).runOnce(), NikoScheduledOutcome.installed);
      expect(updater.staged, 1);
      expect(service.calls.single, startsWith('install_update '));
    });

    test('auto mode gives up while sessions stay active and removes the download', () async {
      final updater = _Updater(_release);
      final service = _Service(_ready);
      final before = Directory.systemTemp.listSync().length;
      expect(await schedule(updater, service, sessions: 2).runOnce(), NikoScheduledOutcome.deferred);
      expect(service.calls, isEmpty);
      expect(Directory.systemTemp.listSync().length, before);
    });

    test("root's copy follows a hand-installed app only when they differ", () async {
      final service = _Service(_ready, answer: const NikoMacServiceAnswer(true, 'synced', '2.0.0+23'));
      final run = schedule(_Updater(null), service);
      expect(await run.syncServiceCopy(), isFalse, reason: 'same version');
      service.current = const NikoMacServiceState(
          installed: true,
          appSigned: true,
          inApplications: true,
          reachable: true,
          versions: 'installed=2.0.0+23 service=1.0.11+22 previous=none');
      expect(await run.syncServiceCopy(), isTrue);
      expect(service.calls, ['sync ']);
    });

    test('a failed verification installs nothing', () async {
      final updater = _Updater(_release, stages: false);
      final service = _Service(_ready);
      expect(await schedule(updater, service).runOnce(), NikoScheduledOutcome.failed);
      expect(service.calls, isEmpty);
    });
  });

  testWidgets('install now appears only when the service can install', (tester) async {
    for (final (state, shown) in [(_ready, true), (const NikoMacServiceState(installed: true), false)]) {
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: NikoMacUpdateInstallButton(
                  key: UniqueKey(),
                  staging: staging,
                  onStatus: (_) {},
                  gateway: _Service(state)))));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('nikodesk-update-install-now')), shown ? findsOneWidget : findsNothing);
    }
  });

  testWidgets('install now reports the result and reopens', (tester) async {
    final messages = <String>[];
    var reopened = false;
    final service = _Service(_ready);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: NikoMacUpdateInstallButton(
                staging: staging,
                onStatus: messages.add,
                gateway: service,
                installer: installer(service),
                relaunch: () async => reopened = true))));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('nikodesk-update-install-now')));
    // Removing the staging directory is real file I/O.
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    // The button keeps its spinner while the app reopens, so do not settle.
    await tester.pump();
    await tester.pump();
    expect(messages.last, contains('2.0.0+23'));
    expect(reopened, isTrue);
  });

  testWidgets('installing by itself can only be chosen with the service', (tester) async {
    final written = <NikoUpdateMode>[];
    Future<void> pump(NikoMacServiceState state) async {
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: NikoUpdateModeSettings(
                  key: UniqueKey(),
                  gateway: _Service(state),
                  schedule: NikoUpdateSchedule(installed: _installed, sessions: () async => 0),
                  readMode: () => NikoUpdateMode.remind,
                  writeMode: (mode) async => written.add(mode)))));
      await tester.pumpAndSettle();
    }

    await pump(const NikoMacServiceState());
    expect(find.textContaining('需要先在“无人值守”中安装系统后台服务'), findsOneWidget);
    await tester.tap(find.byKey(const Key('nikodesk-update-mode')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('空闲时自动安装').last);
    await tester.pumpAndSettle();
    expect(written, isEmpty, reason: 'a disabled entry cannot be chosen');
    // The menu stays open on a disabled entry; dismiss it by its barrier.
    await tester.tapAt(const Offset(4, 4));
    await tester.pumpAndSettle();

    await pump(_ready);
    await tester.tap(find.byKey(const Key('nikodesk-update-mode')));
    await tester.pumpAndSettle();
    // The current mode carries the pop-up list's check, as in NlSelect.
    expect(find.byIcon(NlIcons.check), findsOneWidget);
    await tester.tap(find.text('空闲时自动安装').last);
    await tester.pumpAndSettle();
    expect(written, [NikoUpdateMode.auto]);
    expect(find.textContaining('没有远控会话时安装'), findsOneWidget);
  });
}
