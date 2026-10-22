// Renders the Nightline home shell and component sheet to PNG for visual
// review. Not part of the regression glob (test/nikodesk_*_test.dart); it
// only runs when an output directory is given:
//
//   flutter test --no-pub --dart-define=NIKODESK=true \
//     --dart-define=NIKO_SHOT_DIR=/abs/out \
//     [--dart-define=NIKO_CJK_DIR=/abs/dir-with-PingFang-SC-*.ttf] \
//     test/nightline_screenshots_test.dart
//
// The test renderer has no system font fallback, so Chinese screens need
// NIKO_CJK_DIR; without it only the English screens are written.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/desktop/pages/desktop_setting_page.dart';
import 'package:flutter_hbb/models/native_model.dart';
import 'package:flutter_hbb/nikodesk/cm_permissions.dart';
import 'package:flutter_hbb/nikodesk/device_store.dart';
import 'package:flutter_hbb/nikodesk/file_conflict_dialog.dart';
import 'package:flutter_hbb/nikodesk/first_server_setup.dart';
import 'package:flutter_hbb/nikodesk/home_shell.dart';
import 'package:flutter_hbb/nikodesk/metrics.dart';
import 'package:flutter_hbb/nikodesk/nightline.dart';
import 'package:flutter_hbb/nikodesk/permission_guide.dart';
import 'package:flutter_hbb/nikodesk/policy.dart';
import 'package:flutter_hbb/nikodesk/privacy_connection.dart';
import 'package:flutter_hbb/nikodesk/privacy_style.dart';
import 'package:flutter_hbb/nikodesk/privacy_style_model.dart';
import 'package:flutter_hbb/nikodesk/quality_overlay.dart';
import 'package:flutter_hbb/nikodesk/server_gateway.dart';
import 'package:flutter_hbb/nikodesk/session_log.dart';
import 'package:flutter_hbb/nikodesk/session_toolbar.dart';
import 'package:flutter_hbb/nikodesk/ui.dart';

import 'support/nikodesk_cm_panels.dart';
import 'support/nikodesk_fake_bridge.dart';
import 'support/nikodesk_file_window.dart';

const _out = String.fromEnvironment('NIKO_SHOT_DIR');
const _cjk = String.fromEnvironment('NIKO_CJK_DIR');

class _Gateway implements ServerGateway {
  @override
  Future<ServerSnapshot> read() async => ServerSnapshot(
      PrivateServerConfig('desk.example.net:21116', 'desk.example.net:21117',
          base64Encode(List.filled(32, 7))),
      1,
      true);
  @override
  Future<void> save(PrivateServerConfig config) async {}
}

class _EmptyGateway implements ServerGateway {
  @override
  Future<ServerSnapshot> read() async =>
      const ServerSnapshot(PrivateServerConfig('', '', ''), null, false);
  @override
  Future<void> save(PrivateServerConfig config) async {}
}

Future<void> _font(String family, List<String> paths) async {
  final loader = FontLoader(family);
  for (final path in paths) {
    final bytes = File(path).readAsBytesSync();
    loader.addFont(Future.value(ByteData.view(bytes.buffer)));
  }
  await loader.load();
}

Future<void> _loadFonts() async {
  await _font('Inter',
      ['assets/fonts/Inter-Regular.ttf', 'assets/fonts/Inter-SemiBold.ttf']);
  await _font('JetBrains Mono', [
    'assets/fonts/JetBrainsMono-Regular.ttf',
    'assets/fonts/JetBrainsMono-Medium.ttf'
  ]);
  final artifacts = File(Platform.resolvedExecutable).parent.parent.parent;
  await _font('MaterialIcons',
      ['${artifacts.path}/material_fonts/MaterialIcons-Regular.otf']);
  if (_cjk.isNotEmpty) {
    await _font('PingFang SC', [
      '$_cjk/PingFang-SC-Regular.ttf',
      '$_cjk/PingFang-SC-Medium.ttf',
      '$_cjk/PingFang-SC-Semibold.ttf'
    ]);
  }
}

Future<void> _capture(WidgetTester tester, Widget app, String name,
    {Size size = const Size(1440, 900), Future<void> Function()? before}) async {
  tester.view.physicalSize = size * 2;
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  // flutter_test draws Material shadows as solid black outlines; render
  // them as the app does, and restore the test default before it ends.
  final shadows = debugDisableShadows;
  debugDisableShadows = false;
  try {
    final key = GlobalKey();
    await tester.runAsync(() async {
      await tester.pumpWidget(RepaintBoundary(key: key, child: app));
      for (var i = 0; i < 80; i++) {
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    await tester.pumpAndSettle();
    // The shell's missing accessibility grant shows the permission guide
    // first; shots of the home skip it as the user would.
    final skip = find.text(nikoText('跳过，进入 NikoDesk', 'Skip for now'));
    if (!name.startsWith('permissions') && skip.evaluate().isNotEmpty) {
      await tester.tap(skip);
      await tester.runAsync(() async {
        for (var i = 0; i < 40; i++) {
          await tester.pump();
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      await tester.pumpAndSettle();
    }
    if (before != null) {
      await before();
      await tester.pumpAndSettle();
    }
    await tester.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 2);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      File('$_out/$name.png').writeAsBytesSync(png!.buffer.asUint8List());
    });
    await tester.pumpWidget(const SizedBox());
  } finally {
    debugDisableShadows = shadows;
  }
}

void main() {
  late Directory directory;
  late DeviceStore store;
  late SessionLogStore sessionLog;

  setUpAll(_loadFonts);
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('nightline-shots-');
    store = DeviceStore(directory);
    sessionLog = SessionLogStore(directory);
    final now = DateTime.now();
    for (final device in [
      DeviceEntry(
          id: '418223905',
          alias: 'Studio Mac',
          group: 'Home',
          favorite: true,
          lastConnectedAt: now.subtract(const Duration(hours: 2))),
      DeviceEntry(
          id: '731004562',
          alias: 'Office Workstation',
          group: 'Work',
          lastConnectedAt: now.subtract(const Duration(days: 1))),
      const DeviceEntry(id: '205118377', alias: 'NAS', group: 'Home'),
      DeviceEntry(
          id: '660392148',
          alias: 'Living Room PC',
          group: 'Home',
          lastConnectedAt: now.subtract(const Duration(days: 3))),
      const DeviceEntry(id: '987650021', alias: 'Lab Linux'),
    ]) {
      await store.save(device);
    }
    for (final entry in [
      SessionLogEntry(
          id: '418223905',
          alias: 'Studio Mac',
          startedAt: now.subtract(const Duration(hours: 2))),
      SessionLogEntry(
          id: '731004562',
          alias: 'Office Workstation',
          fileTransfer: true,
          startedAt: now.subtract(const Duration(hours: 3))),
      SessionLogEntry(
          id: '660392148',
          alias: 'Living Room PC',
          forceRelay: true,
          startedAt: now.subtract(const Duration(days: 1, hours: 1))),
      SessionLogEntry(
          id: '418223905',
          alias: 'Studio Mac',
          startedAt: now.subtract(const Duration(days: 1, hours: 5))),
    ].reversed) {
      // record() prepends, so the oldest goes in first.
      await sessionLog.record(entry);
    }
  });
  tearDown(() async => directory.delete(recursive: true));

  Widget shell(Brightness brightness) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(brightness: brightness, useMaterial3: true),
      home: Scaffold(
          body: NikoHomeShell(
              store: store,
              gateway: _Gateway(),
              sessionLog: sessionLog,
              deviceIdProvider: () => '590 216 734',
              temporaryPasswordProvider: () async => 'k7x2m9qa',
              screenRecordingProbe: () => true,
              accessibilityProbe: () => false)));

  for (final english in [true, false]) {
    for (final brightness in Brightness.values) {
      final lang = english ? 'en' : 'zh';
      testWidgets('home ${brightness.name} $lang', (tester) async {
        NikoLanguage.english = english;
        await _capture(tester, shell(brightness),
            'home-${brightness.name}-$lang-1440x900');
      }, skip: _out.isEmpty || (!english && _cjk.isEmpty));
    }
  }

  for (final brightness in Brightness.values) {
    for (final (screen, input) in [(false, false), (true, true)]) {
      final state = screen ? 'ready' : 'missing';
      testWidgets('permissions $state ${brightness.name}', (tester) async {
        NikoLanguage.english = _cjk.isEmpty;
        await _capture(
            tester,
            MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: nightlineTheme(brightness),
                home: Scaffold(
                    body: NikoPermissionGuide(
                        screenRecording: () => screen,
                        accessibility: () => input,
                        requestScreenRecording: () {},
                        requestAccessibility: () {},
                        onContinue: () {},
                        onSilence: () {}))),
            'permissions-$state-${brightness.name}-${_cjk.isEmpty ? 'en' : 'zh'}-1100x760',
            size: const Size(1100, 760));
      }, skip: _out.isEmpty);
    }
    testWidgets('first-time setup ${brightness.name}', (tester) async {
      NikoLanguage.english = _cjk.isEmpty;
      await _capture(
          tester,
          MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: nightlineTheme(brightness),
              home: Scaffold(
                  body: NikoFirstServerSetup(
                      gateway: _EmptyGateway(),
                      onSaved: () {},
                      onLanguageChanged: () async {},
                      child: const SizedBox()))),
          'setup-${brightness.name}-${_cjk.isEmpty ? 'en' : 'zh'}-1100x760',
          size: const Size(1100, 760));
    }, skip: _out.isEmpty);
  }

  testWidgets('home compact dark with navigation open', (tester) async {
    NikoLanguage.english = _cjk.isEmpty;
    await _capture(tester, shell(Brightness.dark),
        'home-dark-${_cjk.isEmpty ? 'en' : 'zh'}-compact-800x600',
        size: const Size(800, 600), before: () async {
      await tester.tap(find.byIcon(Icons.menu_rounded));
    });
  }, skip: _out.isEmpty);

  for (final brightness in Brightness.values) {
    for (final (page, label) in [('settings', '设置'), ('history', '会话')]) {
      testWidgets('$page ${brightness.name}', (tester) async {
        NikoLanguage.english = _cjk.isEmpty;
        await _capture(tester, shell(brightness),
            '$page-${brightness.name}-${_cjk.isEmpty ? 'en' : 'zh'}-1440x900',
            before: () async {
          await tester.tap(find.text(_cjk.isEmpty
              ? (page == 'settings' ? 'Settings' : 'Sessions')
              : label));
          await tester.pumpAndSettle();
          await tester.runAsync(() async {
            for (var i = 0; i < 20; i++) {
              await tester.pump();
              await Future<void>.delayed(const Duration(milliseconds: 20));
            }
          });
        });
      }, skip: _out.isEmpty);
    }

    testWidgets('connection manager ${brightness.name}', (tester) async {
      NikoLanguage.english = _cjk.isEmpty;
      final zh = !NikoLanguage.english;
      await _capture(
          tester,
          MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: nightlineTheme(brightness),
              home: Scaffold(
                  body: NikoCmSessionLayout(
                      header: NikoCmRequestHeader(
                          requester: 'Studio Mac',
                          peerId: '418 223 905',
                          action: zh ? '画面与键鼠控制' : 'Screen and input control',
                          status: zh ? '已连接' : 'Connected',
                          duration: const Text('00:12:48'),
                          trailing: NlIconButton(
                              icon: Icons.chat_bubble_outline_rounded,
                              tooltip: zh ? '聊天' : 'Chat',
                              onPressed: () {})),
                      permissions: NikoCmPermissions(
                          canModify: true,
                          onChange: (_, __) {},
                          permissions: [
                            NikoCmPermission('keyboard', zh ? '键鼠控制' : 'Keyboard and mouse', Icons.keyboard_outlined, true),
                            NikoCmPermission('clipboard', zh ? '文字剪贴板' : 'Text clipboard', Icons.content_paste_rounded, true),
                            NikoCmPermission('audio', zh ? '设备音频' : 'Device audio', Icons.volume_up_outlined, false),
                            NikoCmPermission('file', zh ? '文件复制粘贴' : 'File copy and paste', Icons.folder_outlined, true),
                            NikoCmPermission('restart', zh ? '远程重启' : 'Remote restart', Icons.restart_alt_rounded, false),
                            NikoCmPermission('recording', zh ? '会话录制' : 'Session recording', Icons.fiber_manual_record_outlined, false),
                            NikoCmPermission('privacy_mode', zh ? '隐私屏' : 'Privacy screen', Icons.visibility_off_outlined, true),
                          ]),
                      controls: Row(children: [
                        Expanded(
                            child: NikoCmActionButton(
                                outlined: true,
                                label: zh ? '聊天' : 'Chat',
                                icon: const Icon(Icons.chat_bubble_outline_rounded, size: 16),
                                onPressed: () {})),
                        const SizedBox(width: NlSpace.s2),
                        Expanded(
                            child: NikoCmActionButton(
                                danger: true,
                                label: zh ? '断开' : 'Disconnect',
                                icon: const Icon(Icons.power_settings_new_rounded, size: 16),
                                onPressed: () {})),
                      ])))),
          'cm-${brightness.name}-${_cjk.isEmpty ? 'en' : 'zh'}-400x680',
          size: const Size(400, 680));
    }, skip: _out.isEmpty);
  }

  testWidgets('connect dialog from history', (tester) async {
    NikoLanguage.english = _cjk.isEmpty;
    await _capture(tester, shell(Brightness.dark),
        'dialog-dark-${_cjk.isEmpty ? 'en' : 'zh'}-1440x900', before: () async {
      await tester.tap(find.text(_cjk.isEmpty ? 'Sessions' : '会话'));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        for (var i = 0; i < 20; i++) {
          await tester.pump();
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      await tester.pumpAndSettle();
      await tester.tap(find.text(_cjk.isEmpty ? 'Files' : '传文件'));
    });
  }, skip: _out.isEmpty);

  testWidgets('privacy style editor in the session window', (tester) async {
    NikoLanguage.english = _cjk.isEmpty;
    await _capture(
        tester,
        MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: nightlineTheme(Brightness.dark),
            home: Scaffold(
                body: SingleChildScrollView(
                    padding: const EdgeInsets.all(NlSpace.s5),
                    child: NlPanel(
                        padding: const EdgeInsets.all(NlSpace.s4),
                        child: NikoPrivacyStyleEditor(
                            initial: const NikoPrivacyStyle(motion: false, clock: true),
                            allowed: true,
                            active: true,
                            onApply: (_) async {}))))),
        'privacy-style-dark-${_cjk.isEmpty ? 'en' : 'zh'}-480x900',
        size: const Size(480, 900));
  }, skip: _out.isEmpty);

  // The hosted upstream page reads native options; it runs here on the
  // in-memory bridge, so upstream labels show their untranslated keys.
  group('advanced', () {
    setUp(() async {
      final bridge = NikoFakeBridge();
      bridge.options.addAll({
        'custom-rendezvous-server': 'desk.example.net:21116',
        'relay-server': 'desk.example.net:21117',
        'key': base64Encode(List.filled(32, 7)),
        'stop-service': 'N',
      });
      bridge.userDefault.addAll({
        'view_style': 'adaptive',
        'scroll_style': 'scrollauto',
        'image_quality': 'balanced',
        'codec-preference': 'auto',
      });
      PlatformFFI.instance.ffiBindForTesting = bridge;
      Get.put<RxBool>(false.obs, tag: 'stop-service');
      await initGlobalFFI();
    });
    for (final brightness in Brightness.values) {
      for (final tab in [
        SettingsTabKey.general,
        SettingsTabKey.safety,
        SettingsTabKey.network,
        SettingsTabKey.display,
        SettingsTabKey.about,
      ]) {
        testWidgets('advanced ${tab.name} ${brightness.name}', (tester) async {
          NikoLanguage.english = true;
          await _capture(
              tester,
              MaterialApp(
                  debugShowCheckedModeBanner: false,
                  theme: nightlineTheme(brightness),
                  home:
                      Scaffold(body: DesktopSettingPage(initialTabkey: tab))),
              'advanced-${tab.name}-${brightness.name}-en-1030x860',
              size: const Size(1030, 860));
          // Upstream pages leave short timers behind; let them run out.
          await tester.pump(const Duration(seconds: 3));
        }, skip: _out.isEmpty);
      }
    }
  });

  // The same tree FileManagerPage builds in the NikoDesk build, on real file
  // controllers with fixed directories; no session or native call is made.
  group('file transfer', () {
    setUp(() async {
      PlatformFFI.instance.ffiBindForTesting = NikoFakeBridge();
      await initGlobalFFI();
    });
    for (final brightness in Brightness.values) {
      // 1280 x 720 is the size a new file transfer window opens at.
      for (final size in const [
        Size(1440, 900),
        Size(1280, 720),
        Size(900, 640)
      ]) {
        final name = 'files-${brightness.name}-en-'
            '${size.width.toInt()}x${size.height.toInt()}';
        testWidgets(name, (tester) async {
          NikoLanguage.english = true;
          await _capture(
              tester,
              MaterialApp(
                  debugShowCheckedModeBanner: false,
                  theme: nightlineTheme(brightness),
                  home: const NikoTestFileWindow()),
              name,
              size: size);
        }, skip: _out.isEmpty);
      }
      testWidgets('files-tasks-${brightness.name}-en-900x640', (tester) async {
        NikoLanguage.english = true;
        await _capture(
            tester,
            MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: nightlineTheme(brightness),
                home: const NikoTestFileWindow()),
            'files-tasks-${brightness.name}-en-900x640',
            size: const Size(900, 640), before: () async {
          await tester.tap(find.byKey(const Key('niko-file-pane-2')));
        });
      }, skip: _out.isEmpty);
      testWidgets('files-conflict-${brightness.name}', (tester) async {
        NikoLanguage.english = _cjk.isEmpty;
        await _capture(
            tester,
            MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: nightlineTheme(brightness),
                home: Scaffold(
                    body: Center(
                        child: NikoFileConflictDialog(
                            path: r'C:\Users\demo\Desktop\Quarterly report.pdf',
                            identical: false,
                            showRemember: true,
                            remember: false,
                            onRemember: (_) {},
                            onDecision: (_) {})))),
            'files-conflict-${brightness.name}-${_cjk.isEmpty ? 'en' : 'zh'}-640x560',
            size: const Size(640, 560));
      }, skip: _out.isEmpty);
    }
    testWidgets('files-empty-dark-en-1280x720', (tester) async {
      NikoLanguage.english = true;
      await _capture(
          tester,
          MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: nightlineTheme(Brightness.dark),
              home: const NikoTestFileWindow(withJobs: false)),
          'files-empty-dark-en-1280x720',
          size: const Size(1280, 720));
    }, skip: _out.isEmpty);
    testWidgets('files-dark-zh-1440x900', (tester) async {
      NikoLanguage.english = false;
      await _capture(
          tester,
          MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: nightlineTheme(Brightness.dark),
              home: const NikoTestFileWindow()),
          'files-dark-zh-1440x900');
    }, skip: _out.isEmpty || _cjk.isEmpty);
  });

  // Connection manager cards with a terminal, camera, voice or tunnel panel,
  // or the offer to call the controller. 300 px is the width the window
  // opens at; the tall captures show the whole card, which the window
  // scrolls.
  group('connection manager panels', () {
    Widget card(Brightness brightness, NikoTestCmPanel panel,
            {bool running = false}) =>
        MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: nightlineTheme(brightness),
            home: Scaffold(body: NikoTestCmCard(panel, running: running)));
    for (final panel in NikoTestCmPanel.values) {
      for (final brightness in Brightness.values) {
        final name = 'cm-${panel.name}-${brightness.name}-en-300x1100';
        testWidgets(name, (tester) async {
          NikoLanguage.english = true;
          await _capture(tester, card(brightness, panel), name,
              size: const Size(300, 1100));
        }, skip: _out.isEmpty);
      }
      if (panel == NikoTestCmPanel.voiceStart) continue;
      final running = 'cm-${panel.name}-running-dark-en-300x1100';
      testWidgets(running, (tester) async {
        NikoLanguage.english = true;
        await _capture(
            tester, card(Brightness.dark, panel, running: true), running,
            size: const Size(300, 1100));
      }, skip: _out.isEmpty);
    }
    testWidgets('cm-terminal-dark-en-300x490', (tester) async {
      NikoLanguage.english = true;
      await _capture(tester, card(Brightness.dark, NikoTestCmPanel.terminal),
          'cm-terminal-dark-en-300x490',
          size: const Size(300, 490));
    }, skip: _out.isEmpty);
    testWidgets('cm-camera-chosen-light-en-300x1300', (tester) async {
      NikoLanguage.english = true;
      await _capture(tester, card(Brightness.light, NikoTestCmPanel.camera),
          'cm-camera-chosen-light-en-300x1300',
          size: const Size(300, 1300), before: () async {
        await tester.tap(find.byKey(const ValueKey('niko-camera-device')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('FaceTime HD Camera').last);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('niko-camera-format')));
        await tester.pumpAndSettle();
        await tester.tap(find.textContaining('1280 × 720').last);
        await tester.pumpAndSettle();
        await tester.enterText(
            find.byKey(const ValueKey('niko-camera-fps')), '30');
      });
    }, skip: _out.isEmpty);
    testWidgets('cm-camera-dark-zh-300x1100', (tester) async {
      NikoLanguage.english = false;
      await _capture(tester, card(Brightness.dark, NikoTestCmPanel.camera),
          'cm-camera-dark-zh-300x1100',
          size: const Size(300, 1100));
    }, skip: _out.isEmpty || _cjk.isEmpty);
  });

  testWidgets('privacy arrival reminder in the session window', (tester) async {
    NikoLanguage.english = _cjk.isEmpty;
    await _capture(
        tester,
        MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: nightlineTheme(Brightness.dark),
            home: Scaffold(
                body: Stack(children: [
              const Positioned.fill(child: _RemotePicture()),
              // remote_page.dart places the reminder 96 px down on desktop,
              // clear of a dock docked at the top edge.
              Positioned(
                  top: 96,
                  left: 12,
                  right: 12,
                  child: Align(
                      alignment: Alignment.topCenter,
                      child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 480),
                          child: NikoPrivacyArrivalView(
                              allowed: false,
                              auto: false,
                              busy: false,
                              onAuto: (_) {},
                              onEnable: () {},
                              onSkip: () {})))),
            ]))),
        'privacy-arrival-dark-${_cjk.isEmpty ? 'en' : 'zh'}-1000x560',
        size: const Size(1000, 560));
  }, skip: _out.isEmpty);

  testWidgets('home compact light, as in the real-app check', (tester) async {
    NikoLanguage.english = _cjk.isEmpty;
    await _capture(tester, shell(Brightness.light),
        'home-light-${_cjk.isEmpty ? 'en' : 'zh'}-compact-800x600',
        size: const Size(800, 600));
  }, skip: _out.isEmpty);

  testWidgets('session dock and telemetry', (tester) async {
    NikoLanguage.english = _cjk.isEmpty;
    final metrics = SessionMetrics()
      ..connection(secure: true, direct: true, transport: 'UDP')
      ..update({
        'fps': '{"0":59}',
        'delay': '24',
        'speed': '845.2kB/s',
        'target_bitrate': '7200',
        'codec_format': 'h265',
        'chroma': '4:2:0',
      });
    Widget action(IconData icon, String label,
            {NikoToolbarTone tone = NikoToolbarTone.action, bool? selected}) =>
        NikoToolbarButton(
            icon: Icon(icon), label: label, tone: tone, selected: selected,
            onPressed: () {});
    await _capture(
        tester,
        MaterialApp(
            debugShowCheckedModeBanner: false,
            // Session windows are dark in both modes (nikoSessionWindow).
            theme: nightlineTheme(Brightness.dark),
            home: Scaffold(
                body: Stack(children: [
              const Positioned.fill(child: _RemotePicture()),
              Positioned(
                  left: 12,
                  top: 0,
                  bottom: 0,
                  child: Center(
                      child: NikoSessionToolbar(
                          direction: Axis.vertical,
                          actions: [
                            action(Icons.push_pin_rounded, 'Pin', selected: true),
                            action(Icons.desktop_windows_outlined, 'Displays'),
                            action(Icons.tune_rounded, 'Picture mode'),
                            action(Icons.visibility_off_rounded, 'Privacy screen',
                                tone: NikoToolbarTone.engaged, selected: true),
                            action(Icons.keyboard_outlined, 'Keyboard'),
                            action(Icons.content_paste_rounded, 'Clipboard'),
                            action(Icons.folder_outlined, 'Files'),
                            action(Icons.monitor_heart_outlined, 'Diagnostics',
                                selected: true),
                            action(Icons.chat_bubble_outline_rounded, 'Chat'),
                            action(Icons.fiber_manual_record_outlined, 'Record',
                                tone: NikoToolbarTone.inactive),
                          ],
                          endSession: action(Icons.power_settings_new_rounded,
                              'Disconnect',
                              tone: NikoToolbarTone.danger)))),
              Positioned(
                  right: 14,
                  top: 14,
                  child: NikoQualityOverlay(metrics: metrics, display: 0)),
            ]))),
        'session-dark-${_cjk.isEmpty ? 'en' : 'zh'}-1440x900');
  }, skip: _out.isEmpty);

  for (final brightness in Brightness.values) {
    testWidgets('components ${brightness.name}', (tester) async {
      NikoLanguage.english = true;
      await _capture(
          tester,
          MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: nightlineTheme(brightness),
              builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(disableAnimations: true),
                  child: child!),
              home: const Scaffold(body: _ComponentSheet())),
          'components-${brightness.name}',
          size: const Size(1200, 900));
    }, skip: _out.isEmpty);
  }
}

class _ComponentSheet extends StatefulWidget {
  const _ComponentSheet();
  @override
  State<_ComponentSheet> createState() => _ComponentSheetState();
}

class _ComponentSheetState extends State<_ComponentSheet> {
  String _filter = 'online';
  final _chips = {'Screen': true, 'Input': true, 'Files': false, 'Audio': true};

  @override
  Widget build(BuildContext context) {
    final nl = NlColors.of(context);
    Widget section(String label, Widget child) => Padding(
        padding: const EdgeInsets.only(bottom: NlSpace.s6),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          NlMonoLabel(label),
          const SizedBox(height: NlSpace.s3),
          child,
        ]));
    final swatches = {
      'page': nl.page, 'bg': nl.bg, 'bg-2': nl.bg2, 'surface': nl.surface,
      'surface-2': nl.surface2, 'overlay': nl.overlay, 'line': nl.line,
      'line-2': nl.line2, 'fg': nl.fg, 'fg-2': nl.fg2, 'fg-3': nl.fg3,
      'accent': nl.accent, 'accent-text': nl.accentText, 'accent-2': nl.accent2,
      'ok': nl.ok, 'warn': nl.warn, 'danger': nl.danger,
    };
    return ColoredBox(
        color: nl.bg,
        child: Padding(
            padding: const EdgeInsets.all(NlSpace.s8),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Row(children: [
                      const NlMark(),
                      const SizedBox(width: NlSpace.s3),
                      Text('Nightline · ${nl.isDark ? 'dark' : 'light'}',
                          style: NlType.text(NlType.s6,
                              weight: FontWeight.w600, color: nl.fg)),
                    ]),
                    const SizedBox(height: NlSpace.s6),
                    section(
                        'Buttons',
                        Wrap(spacing: NlSpace.s2, runSpacing: NlSpace.s2, children: [
                          NlButton(
                              onPressed: () {},
                              icon: Icons.bolt_rounded,
                              label: 'Connect',
                              shortcut: '⏎'),
                          NlButton.ghost(
                              onPressed: () {}, label: 'Cancel', shortcut: 'esc'),
                          NlButton.danger(onPressed: () {}, label: 'Disconnect'),
                          const NlButton(onPressed: null, label: 'Disabled'),
                          NlButton.ghost(
                              small: true,
                              onPressed: () {},
                              icon: Icons.key_rounded,
                              label: 'Small ghost'),
                          NlIconButton(
                              icon: Icons.copy_rounded,
                              tooltip: 'Copy',
                              onPressed: () {}),
                          NlIconButton(
                              icon: Icons.visibility_rounded,
                              tooltip: 'Show',
                              active: true,
                              onPressed: () {}),
                        ])),
                    section(
                        'Segmented control',
                        NlSegmented<String>(
                            segments: const [
                              NlSegment(value: 'all', label: 'All', count: '8'),
                              NlSegment(value: 'online', label: 'Online', count: '5'),
                              NlSegment(value: 'fav', label: 'Starred', count: '3'),
                              NlSegment(value: 'recent', label: 'Recent', count: '6'),
                            ],
                            selected: _filter,
                            onChanged: (value) => setState(() => _filter = value))),
                    section(
                        'Chips',
                        Wrap(spacing: NlSpace.s2, runSpacing: NlSpace.s2, children: [
                          for (final entry in _chips.entries)
                            NlChip(
                                label: entry.key,
                                icon: Icons.check_rounded,
                                selected: entry.value,
                                strikeWhenOff: true,
                                onChanged: (value) =>
                                    setState(() => _chips[entry.key] = value)),
                        ])),
                    section(
                        'Panel, list rows, LED, kbd',
                        SizedBox(
                            width: 420,
                            child: NlPanel(
                                child: Column(children: [
                              const NlListRow(
                                  divider: false,
                                  leading: NlLed(NlLedState.ok),
                                  title: 'Private server',
                                  subtitle: 'desk.example.net',
                                  trailing: NlMonoLabel('18 ms')),
                              NlListRow(
                                  leading: const NlLed(NlLedState.warn),
                                  title: 'Accessibility',
                                  subtitle: 'Required for remote input',
                                  trailing: NlButton.ghost(
                                      small: true, onPressed: () {}, label: 'Grant')),
                              const NlListRow(
                                  leading: NlLed(NlLedState.off),
                                  title: 'Command palette',
                                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                                    NlKbd('⌘'),
                                    SizedBox(width: NlSpace.s1),
                                    NlKbd('K'),
                                  ])),
                            ])))),
                    section(
                        'Mono labels',
                        const Wrap(spacing: NlSpace.s4, children: [
                          NlMonoLabel('Neutral'),
                          NlMonoLabel('Accent', tone: NlTone.accent),
                          NlMonoLabel('Ok', tone: NlTone.ok, leading: NlLed(NlLedState.live)),
                          NlMonoLabel('Warn', tone: NlTone.warn),
                          NlMonoLabel('Danger', tone: NlTone.danger),
                        ])),
                  ])),
              const SizedBox(width: NlSpace.s8),
              SizedBox(
                  width: 420,
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    section(
                        'Type · Inter / JetBrains Mono',
                        Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              for (final size in NlType.scale.reversed)
                                Text('${size.toInt()} · Remote desktop 远程桌面',
                                    style: NlType.text(size,
                                        weight: size >= NlType.s5
                                            ? FontWeight.w600
                                            : FontWeight.w400,
                                        color: nl.fg)),
                              const SizedBox(height: NlSpace.s2),
                              Text('590 216 734 · 59 FPS · 24 MS',
                                  style: NlType.monoText(NlType.s5,
                                      weight: FontWeight.w500, color: nl.fg)),
                            ])),
                    section(
                        'Elevation 1 · 2 · 3',
                        Row(children: [
                          for (final level in [1, 2, 3]) ...[
                            Expanded(
                                child: NlPanel(
                                    elevation: level,
                                    child: SizedBox(
                                        height: 48,
                                        child: Center(
                                            child: NlMonoLabel('Level $level'))))),
                            if (level < 3) const SizedBox(width: NlSpace.s4),
                          ]
                        ])),
                    section(
                        'Colour tokens',
                        Wrap(spacing: NlSpace.s2, runSpacing: NlSpace.s2, children: [
                          for (final entry in swatches.entries)
                            SizedBox(
                                width: 96,
                                child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Container(
                                          height: 28,
                                          decoration: BoxDecoration(
                                              color: entry.value,
                                              borderRadius: BorderRadius.circular(
                                                  NlRadius.r1),
                                              border: Border.all(color: nl.line))),
                                      const SizedBox(height: NlSpace.s1),
                                      Text(entry.key,
                                          style: NlType.monoText(NlType.s1,
                                              color: nl.fg2)),
                                    ])),
                        ])),
                  ])),
            ])));
  }
}

/// Stand-in for the remote picture behind the session chrome. It is not a
/// NikoDesk widget; it only gives the dock and HUD something to sit on.
class _RemotePicture extends StatelessWidget {
  const _RemotePicture();

  @override
  Widget build(BuildContext context) => DecoratedBox(
      decoration: const BoxDecoration(
          gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF1B3A5C), Color(0xFF2E6F86), Color(0xFFB7C9C2)])),
      child: Center(
          child: Container(
              width: 860,
              height: 540,
              decoration: BoxDecoration(
                  color: const Color(0xFFF7F8FA),
                  borderRadius: BorderRadius.circular(10),
                  boxShadow: const [
                    BoxShadow(color: Color(0x55000000), blurRadius: 40, offset: Offset(0, 20))
                  ]),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Container(
                    height: 36,
                    decoration: const BoxDecoration(
                        color: Color(0xFFE9ECEF),
                        borderRadius: BorderRadius.vertical(top: Radius.circular(10)))),
                Padding(
                    padding: const EdgeInsets.all(28),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      for (final width in [520.0, 680.0, 610.0, 300.0, 640.0, 560.0, 420.0])
                        Container(
                            width: width,
                            height: 12,
                            margin: const EdgeInsets.only(bottom: 18),
                            decoration: BoxDecoration(
                                color: const Color(0xFFD5DBE1),
                                borderRadius: BorderRadius.circular(6))),
                    ])),
              ]))));
}
