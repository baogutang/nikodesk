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

import 'package:dash_chat_2/dash_chat_2.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart' show Terminal, TerminalView;
import 'package:flutter_hbb/common/widgets/toolbar.dart'
    show TRadioMenu, TTextMenu, TToggleMenu;
import 'package:get/get.dart';
import 'package:flutter_hbb/common.dart' hide Dialog;
import 'package:flutter_hbb/desktop/widgets/kb_layout_type_chooser.dart';
import 'package:flutter_hbb/consts.dart'
    show kPeerPlatformMacOS, kPeerPlatformWindows;
import 'package:flutter_hbb/desktop/pages/desktop_setting_page.dart';
import 'package:flutter_hbb/models/native_model.dart';
import 'package:flutter_hbb/nikodesk/chat_view.dart';
import 'package:flutter_hbb/nikodesk/cm_permissions.dart';
import 'package:flutter_hbb/nikodesk/connection_progress.dart';
import 'package:flutter_hbb/nikodesk/connection_progress_view.dart';
import 'package:flutter_hbb/nikodesk/device_store.dart';
import 'package:flutter_hbb/nikodesk/display_options_view.dart';
import 'package:flutter_hbb/nikodesk/file_conflict_dialog.dart';
import 'package:flutter_hbb/nikodesk/first_server_setup.dart';
import 'package:flutter_hbb/nikodesk/home_shell.dart';
import 'package:flutter_hbb/nikodesk/mobile_more_actions.dart';
import 'package:flutter_hbb/nikodesk/mobile_control_bar.dart';
import 'package:flutter_hbb/nikodesk/mobile_chat_options.dart';
import 'package:flutter_hbb/nikodesk/mobile_gesture_panel.dart';
import 'package:flutter_hbb/nikodesk/mobile_key_bar.dart';
import 'package:flutter_hbb/nikodesk/mobile_session_guide.dart';
import 'package:flutter_hbb/nikodesk/mobile_home.dart';
import 'package:flutter_hbb/nikodesk/metrics.dart';
import 'package:flutter_hbb/nikodesk/nightline.dart';
import 'package:flutter_hbb/nikodesk/permission_guide.dart';
import 'package:flutter_hbb/nikodesk/policy.dart';
import 'package:flutter_hbb/nikodesk/privacy_connection.dart';
import 'package:flutter_hbb/nikodesk/privacy_screen_policy.dart';
import 'package:flutter_hbb/nikodesk/privacy_style.dart';
import 'package:flutter_hbb/nikodesk/privacy_style_model.dart';
import 'package:flutter_hbb/nikodesk/quality_overlay.dart';
import 'package:flutter_hbb/nikodesk/remote_resolution_policy.dart';
import 'package:flutter_hbb/nikodesk/server_gateway.dart';
import 'package:flutter_hbb/nikodesk/server_settings.dart';
import 'package:flutter_hbb/nikodesk/wake_on_lan.dart';
import 'package:flutter_hbb/nikodesk/wake_on_lan_view.dart';
import 'package:flutter_hbb/nikodesk/wake_proxy.dart';
import 'package:flutter_hbb/nikodesk/home_chrome.dart';
import 'package:flutter_hbb/nikodesk/session_audit.dart';
import 'package:flutter_hbb/nikodesk/session_audit_view.dart';
import 'package:flutter_hbb/nikodesk/session_log.dart';
import 'package:flutter_hbb/nikodesk/session_quick_actions_view.dart';
import 'package:flutter_hbb/nikodesk/session_sheet.dart';
import 'package:flutter_hbb/nikodesk/voice_session_native.dart';
import 'package:flutter_hbb/nikodesk/voice_session_owner.dart';
import 'package:flutter_hbb/nikodesk/session_shortcuts.dart';
import 'package:flutter_hbb/nikodesk/session_toolbar.dart';
import 'package:flutter_hbb/nikodesk/session_tools_view.dart';
import 'package:flutter_hbb/nikodesk/terminal_look.dart';
import 'package:flutter_hbb/nikodesk/theme.dart' show nikoSessionTheme;
import 'package:flutter_hbb/nikodesk/tunnel_controller_view.dart';
import 'package:flutter_hbb/nikodesk/ui.dart';

import 'nikodesk_tunnel_controller_test.dart' as tunnel;
import 'nikodesk_voice_owner_test.dart' show voiceEnabled;
import 'nikodesk_voice_session_model_test.dart' show voiceQueued;
import 'support/nikodesk_cm_panels.dart';
import 'support/nikodesk_component_sheet.dart';
import 'support/nikodesk_fake_bridge.dart';
import 'support/nikodesk_file_window.dart';
import 'support/nikodesk_mobile_file_page.dart';

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

/// Session results as the native store would return them, a few hours and
/// a day old.
class _Audit implements SessionAuditApi {
  @override
  Future<String> read(String namespace) async {
    final now = DateTime.now();
    int ago(Duration duration) => now.subtract(duration).millisecondsSinceEpoch;
    String id(int n) => '${'$n' * 8}-1234-4234-8234-123456789abc';
    Map<String, Object?> entry(int n, String peer, String role, String kind,
        String phase, Duration age,
        {Duration? length}) {
      final start = ago(age);
      final end = length == null ? null : start + length.inMilliseconds;
      return {
        'session': id(n),
        'peerId': peer,
        'role': role,
        'kind': kind,
        'phase': phase,
        'startedAt': start,
        'authenticatedAt': phase == 'not_authenticated' ? null : start + 1800,
        'endedAt': end,
        'durationMs': length?.inMilliseconds,
      };
    }

    Map<String, Object?> event(int n, String role, String kind, String stage,
            Duration age) =>
        {
          'id': id(n + 5),
          'session': id(n),
          'operation': id(n + 3),
          'sequence': 1,
          'peerId': '418223905',
          'role': role,
          'kind': kind,
          'stage': stage,
          'at': ago(age),
        };
    return jsonEncode({
      'ok': true,
      'status': 'ready',
      'namespace': namespace,
      'revision': 'b' * 64,
      'incomplete': false,
      'entries': [
        entry(1, '731004562', 'receiver', 'desktop', 'authenticated',
            const Duration(minutes: 40)),
        entry(2, '418223905', 'controller', 'desktop', 'disconnected',
            const Duration(hours: 2),
            length: const Duration(hours: 1, minutes: 2, seconds: 13)),
        entry(3, '660392148', 'controller', 'file_transfer', 'disconnected',
            const Duration(days: 1, hours: 1),
            length: const Duration(minutes: 6, seconds: 41)),
        entry(4, '205118377', 'controller', 'desktop', 'not_authenticated',
            const Duration(days: 1, hours: 3),
            length: const Duration(seconds: 9)),
      ],
      'activities': [
        event(1, 'receiver', 'voice', 'started', const Duration(minutes: 35)),
        event(2, 'controller', 'terminal', 'cleanup_pending',
            const Duration(hours: 2)),
        event(3, 'receiver', 'camera', 'rejected',
            const Duration(days: 1, hours: 2)),
      ],
    });
  }

  @override
  Future<String> clear(String namespace, String revision) =>
      read(namespace);
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
  await _font('Inter', [
    'assets/fonts/Inter-Regular.ttf',
    'assets/fonts/Inter-Medium.ttf',
    'assets/fonts/Inter-SemiBold.ttf'
  ]);
  await _font('Lucide', ['assets/fonts/Lucide.ttf']);
  await _font('gestureicons', ['assets/gestures.ttf']);
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
    {Size size = const Size(1440, 900),
    Future<void> Function()? before,
    TargetPlatform platform = TargetPlatform.macOS,
    EdgeInsets padding = EdgeInsets.zero}) async {
  tester.view.physicalSize = size * 2;
  tester.view.devicePixelRatio = 2;
  tester.view.padding = FakeViewPadding(
      left: padding.left * 2,
      top: padding.top * 2,
      right: padding.right * 2,
      bottom: padding.bottom * 2);
  addTearDown(tester.view.reset);
  // Density follows the platform: pointer metrics on macOS, touch on iOS.
  debugDefaultTargetPlatformOverride = platform;
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
    debugDefaultTargetPlatformOverride = null;
  }
}

/// The traffic lights the native window draws over the title strip.
class _TrafficLights extends StatelessWidget {
  final Widget child;
  const _TrafficLights({required this.child});

  @override
  Widget build(BuildContext context) => Stack(children: [
        Positioned.fill(child: child),
        Positioned(
            left: 20,
            top: 8,
            child: IgnorePointer(
                child: Row(children: [
              for (final color in const [
                Color(0xFFFF5F57),
                Color(0xFFFEBC2E),
                Color(0xFF28C840)
              ]) ...[
                Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                        color: color,
                        shape: BoxShape.circle,
                        border: Border.all(
                            color: Colors.black.withOpacity(.12), width: .5))),
                const SizedBox(width: 8),
              ],
            ]))),
      ]);
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

  Widget macShell(Brightness brightness, {String? select}) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(brightness: brightness, useMaterial3: true),
      home: Scaffold(
          body: _TrafficLights(
              child: NikoHomeShell(
                  store: store,
                  gateway: _Gateway(),
                  sessionLog: sessionLog,
                  macTitleBar: true,
                  deviceIdProvider: () => '590 216 734',
                  temporaryPasswordProvider: () async => 'k7x2m9qa',
                  screenRecordingProbe: () => true,
                  accessibilityProbe: () => true))));

  Widget mobile(Brightness brightness) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(brightness: brightness, useMaterial3: true),
      home: NikoMobileHome(
          store: store, gateway: _Gateway(), sessionLog: sessionLog));

  Future<void> settle(WidgetTester tester) async {
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      for (var i = 0; i < 20; i++) {
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    await tester.pumpAndSettle();
  }

  for (final english in [true, false]) {
    final lang = english ? 'en' : 'zh';
    for (final brightness in Brightness.values) {
      final b = brightness.name;
      testWidgets('orbit desktop $b $lang', (tester) async {
        NikoLanguage.english = english;
        await _capture(tester, macShell(brightness), 'orbit-desktop-$b-$lang-1440x900');
      }, skip: _out.isEmpty || (!english && _cjk.isEmpty));
      testWidgets('orbit desktop inspector $b $lang', (tester) async {
        NikoLanguage.english = english;
        await _capture(tester, macShell(brightness),
            'orbit-desktop-inspector-$b-$lang-1440x900', before: () async {
          await tester.tap(find.text('Office Workstation'));
          await settle(tester);
        });
      }, skip: _out.isEmpty || (!english && _cjk.isEmpty));
      testWidgets('orbit desktop palette $b $lang', (tester) async {
        NikoLanguage.english = english;
        await _capture(tester, macShell(brightness),
            'orbit-desktop-palette-$b-$lang-1440x900', before: () async {
          await tester.tap(find.text(english ? 'Search and commands' : '搜索与命令'));
          await settle(tester);
        });
      }, skip: _out.isEmpty || (!english && _cjk.isEmpty));
      testWidgets('orbit desktop narrow $b $lang', (tester) async {
        NikoLanguage.english = english;
        await _capture(tester, macShell(brightness),
            'orbit-desktop-narrow-$b-$lang-1000x720',
            size: const Size(1000, 720));
      }, skip: _out.isEmpty || (!english && _cjk.isEmpty));
      for (final section in ['general', 'appearance', 'server', 'updates', 'about']) {
        testWidgets('orbit settings $section $b $lang', (tester) async {
          NikoLanguage.english = english;
          await _capture(tester, macShell(brightness),
              'orbit-settings-$section-$b-$lang-1440x900', before: () async {
            await tester.tap(find.text(english ? 'Settings' : '设置'));
            await settle(tester);
            await tester.tap(find.byKey(Key('nikodesk-settings-nav-$section')));
            await settle(tester);
          });
        }, skip: _out.isEmpty || (!english && _cjk.isEmpty));
      }
      testWidgets('orbit history $b $lang', (tester) async {
        NikoLanguage.english = english;
        await _capture(tester, macShell(brightness),
            'orbit-history-$b-$lang-1440x900', before: () async {
          await tester.tap(find.text(english ? 'Sessions' : '会话'));
          await settle(tester);
        });
      }, skip: _out.isEmpty || (!english && _cjk.isEmpty));
      for (final tab in ['sessions', 'settings']) {
        testWidgets('orbit phone $tab $b $lang', (tester) async {
          NikoLanguage.english = english;
          await _capture(tester, mobile(brightness),
              'orbit-phone-$tab-$b-$lang-390x844',
              size: const Size(390, 844),
              platform: TargetPlatform.iOS,
              padding: const EdgeInsets.only(top: 47, bottom: 34),
              before: () async {
            await tester.tap(find.text(tab == 'sessions'
                    ? (english ? 'Sessions' : '会话')
                    : (english ? 'Settings' : '设置'))
                .last);
            await settle(tester);
          });
        }, skip: _out.isEmpty || (!english && _cjk.isEmpty));
      }
      testWidgets('orbit settings narrow $b $lang', (tester) async {
        NikoLanguage.english = english;
        await _capture(tester, macShell(brightness),
            'orbit-settings-narrow-$b-$lang-1000x720',
            size: const Size(1000, 720), before: () async {
          await tester.tap(find.text(english ? 'Settings' : '设置'));
          await settle(tester);
        });
      }, skip: _out.isEmpty || (!english && _cjk.isEmpty));
      for (final (label, size) in [
        ('ipad-landscape', const Size(1376, 1032)),
        ('ipad-portrait', const Size(1032, 1376)),
        ('phone', const Size(390, 844)),
      ]) {
        final phone = label == 'phone';
        testWidgets('orbit $label $b $lang', (tester) async {
          NikoLanguage.english = english;
          await _capture(tester, mobile(brightness),
              'orbit-$label-$b-$lang-${size.width.toInt()}x${size.height.toInt()}',
              size: size,
              platform: TargetPlatform.iOS,
              padding: EdgeInsets.only(top: phone ? 47 : 24, bottom: phone ? 34 : 20));
        }, skip: _out.isEmpty || (!english && _cjk.isEmpty));
      }
      testWidgets('orbit ipad inspector $b $lang', (tester) async {
        NikoLanguage.english = english;
        await _capture(tester, mobile(brightness),
            'orbit-ipad-inspector-$b-$lang-1376x1032',
            size: const Size(1376, 1032),
            platform: TargetPlatform.iOS,
            padding: const EdgeInsets.only(top: 24, bottom: 20), before: () async {
          await tester.tap(find.text('Studio Mac').last);
          await settle(tester);
        });
      }, skip: _out.isEmpty || (!english && _cjk.isEmpty));
    }
  }

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
              theme: nightlineTheme(brightness)
                  .copyWith(platform: TargetPlatform.macOS),
              home: Scaffold(
                  body: NikoFirstServerSetup(
                      gateway: _EmptyGateway(),
                      onSaved: () {},
                      onLanguageChanged: () async {},
                      child: const SizedBox()))),
          'setup-${brightness.name}-${_cjk.isEmpty ? 'en' : 'zh'}-1100x760',
          size: const Size(1100, 760));
    }, skip: _out.isEmpty);
    // Saving checks each field and says what is wrong under it.
    testWidgets('first-time setup errors ${brightness.name}', (tester) async {
      NikoLanguage.english = true;
      await _capture(
          tester,
          MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: nightlineTheme(brightness)
                  .copyWith(platform: TargetPlatform.macOS),
              home: Scaffold(
                  body: NikoFirstServerSetup(
                      gateway: _EmptyGateway(),
                      onSaved: () {},
                      onLanguageChanged: () async {},
                      child: const SizedBox()))),
          'setup-errors-${brightness.name}-en-1100x760',
          size: const Size(1100, 760), before: () async {
        await tester.enterText(
            find.byKey(const ValueKey('niko-server-id')), 'https://nas');
        await tester.enterText(find.byKey(const ValueKey('niko-server-relay')),
            'nas.example.net:21117');
        await tester.tap(find.text('Save and enable private server'));
      });
    }, skip: _out.isEmpty);
    // Settings opens the same form in a dialog.
    // Wake-on-LAN through an online proxy on the target's network.
    testWidgets('wake dialog ${brightness.name}', (tester) async {
      NikoLanguage.english = _cjk.isEmpty;
      const scope =
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      final proxies = jsonEncode({
        'schema': 1,
        'namespace': scope,
        'endpoints': [
          {
            'namespace': scope,
            'peer_id': '123456789',
            'local_port': 21129,
            'target': {'host': '127.0.0.1', 'port': 21128},
            'generation': '1',
            'revision': '1',
            'phase': 'Listening',
            'reason': 'tunnel_listening',
            'remote_phase': 'Running',
            'local_resources_closed': false,
          }
        ],
      });
      await _capture(
          tester,
          MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: nightlineTheme(brightness)
                  .copyWith(platform: TargetPlatform.macOS),
              home: Builder(
                  builder: (context) => Scaffold(
                      body: TextButton(
                          onPressed: () => showWakeOnLan(context,
                              title: nikoText('唤醒书房台式机', 'Wake Studio PC'),
                              initial: const WakeProfile(
                                  '02:11:22:33:44:55', '192.168.1.255',
                                  proxyId: '123456789'),
                              proxies: NikoWakeTunnelDirectory(scope,
                                  readStatus: () async => proxies),
                              proxyLabels: {
                                '123456789': nikoText('书房 NAS', 'Studio NAS')
                              },
                              connectProxy: () async {},
                              send: (_) async => 3),
                          child: const Text('Open'))))),
          'wake-${brightness.name}-${_cjk.isEmpty ? 'en' : 'zh'}-1100x760',
          size: const Size(1100, 760), before: () async {
        await tester.tap(find.text('Open'));
      });
    }, skip: _out.isEmpty);
    testWidgets('server settings dialog ${brightness.name}', (tester) async {
      NikoLanguage.english = _cjk.isEmpty;
      await _capture(
          tester,
          MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: nightlineTheme(brightness)
                  .copyWith(platform: TargetPlatform.macOS),
              home: Scaffold(
                  body: Center(
                      child: Dialog(
                          child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 560),
                              child: PrivateServerForm(
                                  gateway: _EmptyGateway(),
                                  initial: const PrivateServerConfig(
                                      'nas.example.net:21116',
                                      'nas.example.net:21117',
                                      ''))))))),
          'server-dialog-${brightness.name}-${_cjk.isEmpty ? 'en' : 'zh'}-1100x760',
          size: const Size(1100, 760));
    }, skip: _out.isEmpty);
  }

  testWidgets('home compact dark with navigation open', (tester) async {
    NikoLanguage.english = _cjk.isEmpty;
    await _capture(tester, shell(Brightness.dark),
        'home-dark-${_cjk.isEmpty ? 'en' : 'zh'}-compact-800x600',
        size: const Size(800, 600), before: () async {
      await tester.tap(find.byTooltip('打开导航'));
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
              // The connection manager is a desktop window.
              theme: nightlineTheme(brightness)
                  .copyWith(platform: TargetPlatform.macOS),
              home: Scaffold(
                  body: NikoCmSessionLayout(
                      header: NikoCmRequestHeader(
                          requester: 'Studio Mac',
                          peerId: '418 223 905',
                          action: zh ? '画面与键鼠控制' : 'Screen and input control',
                          status: zh ? '已连接' : 'Connected',
                          duration: const Text('00:12:48'),
                          trailing: NlIconButton(
                              icon: NlIcons.messageSquare,
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
    for (final b in Brightness.values) {
      await _capture(
          tester,
          MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: nightlineTheme(b).copyWith(platform: TargetPlatform.macOS),
              home: Scaffold(
                  body: SingleChildScrollView(
                      padding: const EdgeInsets.all(NlSpace.s5),
                      child: NlPanel(
                          padding: const EdgeInsets.all(NlSpace.s4),
                          child: NikoPrivacyStyleEditor(
                              initial: const NikoPrivacyStyle(
                                  motion: false, clock: true),
                              allowed: true,
                              active: true,
                              onApply: (_) async {}))))),
          'privacy-style-${b.name}-${_cjk.isEmpty ? 'en' : 'zh'}-480x900',
          size: const Size(480, 900));
    }
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

  // The stock dialogs every part of the app opens through CustomAlertDialog:
  // a msgBox error and a titled confirmation, over a session.
  group('dialogs', () {
    setUp(() async {
      PlatformFFI.instance.ffiBindForTesting = NikoFakeBridge();
      await initGlobalFFI();
    });
    for (final (device, size, platform, padding) in const [
      ('desktop', Size(1100, 760), TargetPlatform.macOS, EdgeInsets.zero),
      ('ipad', Size(1180, 820), TargetPlatform.iOS,
          EdgeInsets.only(top: 24, bottom: 20)),
      ('phone', Size(390, 844), TargetPlatform.iOS,
          EdgeInsets.only(top: 47, bottom: 34)),
    ]) {
      for (final brightness in Brightness.values) {
        for (final kind in ['error', 'confirm']) {
          final name = 'dialog-$kind-$device-${brightness.name}-en-'
              '${size.width.toInt()}x${size.height.toInt()}';
          testWidgets(name, (tester) async {
            NikoLanguage.english = true;
            final dialog = kind == 'error'
                ? CustomAlertDialog(
                    title: null,
                    content: msgboxContent('error', 'Connection Error',
                        'Failed to connect via relay server'),
                    actions: [
                      dialogButton('Close', onPressed: () {}, isOutline: true),
                      dialogButton('Retry', onPressed: () {}),
                    ],
                    onCancel: () {})
                : CustomAlertDialog(
                    title: const Text('Delete this device?'),
                    content: const Text(
                        'It leaves your list on this computer. Its saved password is removed too.'),
                    actions: [
                      dialogButton('Cancel',
                          icon: const Icon(Icons.close_rounded),
                          onPressed: () {},
                          isOutline: true),
                      dialogButton('OK',
                          icon: const Icon(Icons.done_rounded),
                          onPressed: () {}),
                    ],
                    onSubmit: () {},
                    onCancel: () {});
            await _capture(
                tester,
                MaterialApp(
                    debugShowCheckedModeBanner: false,
                    theme: nightlineTheme(brightness).copyWith(platform: platform),
                    home: Scaffold(
                        body: Stack(children: [
                      const Positioned.fill(child: _RemotePicture()),
                      Positioned.fill(
                          child: ColoredBox(
                              color: brightness == Brightness.light
                                  ? Colors.black12
                                  : Colors.black45)),
                      Positioned.fill(child: dialog),
                    ]))),
                name,
                size: size,
                platform: platform,
                padding: padding);
          }, skip: _out.isEmpty);
        }
      }
    }
  });

  // The local keyboard type chooser, which a Windows or Linux computer
  // shows on its first session to a Mac; the stock dialog and chooser run
  // through their NikoDesk hooks.
  group('keyboard type', () {
    setUp(() async {
      PlatformFFI.instance.ffiBindForTesting = NikoFakeBridge();
      await initGlobalFFI();
    });
    for (final brightness in Brightness.values) {
      final name = 'kb-layout-desktop-${brightness.name}-en-1100x760';
      testWidgets(name, (tester) async {
        NikoLanguage.english = true;
        await _capture(
            tester,
            MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: nightlineTheme(brightness)
                    .copyWith(platform: TargetPlatform.windows),
                home: Scaffold(
                    body: Stack(children: [
                  const Positioned.fill(child: _RemotePicture()),
                  Positioned.fill(
                      child: ColoredBox(
                          color: brightness == Brightness.light
                              ? Colors.black12
                              : Colors.black45)),
                  Positioned.fill(
                      child: CustomAlertDialog(
                          title: Text(
                              '${translate('Select local keyboard type')} (Windows)'),
                          content: KBLayoutTypeChooser(
                              chosenType: 'ISO'.obs,
                              width: 360,
                              height: 200,
                              dividerWidth: 4,
                              cb: (_) async => true),
                          actions: [dialogButton('Close', onPressed: () {})],
                          onCancel: () {})),
                ]))),
            name,
            size: const Size(1100, 760),
            platform: TargetPlatform.windows);
      }, skip: _out.isEmpty);
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
                  theme: nightlineTheme(brightness)
                    .copyWith(platform: TargetPlatform.macOS),
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
                theme: nightlineTheme(brightness)
                    .copyWith(platform: TargetPlatform.macOS),
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
                theme: nightlineTheme(brightness)
                    .copyWith(platform: TargetPlatform.macOS),
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
              theme: nightlineTheme(Brightness.dark)
                  .copyWith(platform: TargetPlatform.macOS),
              home: const NikoTestFileWindow(withJobs: false)),
          'files-empty-dark-en-1280x720',
          size: const Size(1280, 720));
    }, skip: _out.isEmpty);
    // Search turns the path bar into a field that filters the list.
    testWidgets('files-search-light-en-1280x720', (tester) async {
      NikoLanguage.english = true;
      await _capture(
          tester,
          MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: nightlineTheme(Brightness.light)
                  .copyWith(platform: TargetPlatform.macOS),
              home: const NikoTestFileWindow()),
          'files-search-light-en-1280x720',
          size: const Size(1280, 720), before: () async {
        await tester.tap(find.byTooltip('Search').first);
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField).first, 're');
      });
    }, skip: _out.isEmpty);
    testWidgets('files-dark-zh-1440x900', (tester) async {
      NikoLanguage.english = false;
      await _capture(
          tester,
          MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: nightlineTheme(Brightness.dark)
                  .copyWith(platform: TargetPlatform.macOS),
              home: const NikoTestFileWindow()),
          'files-dark-zh-1440x900');
    }, skip: _out.isEmpty || _cjk.isEmpty);
  });

  // The phone and iPad file transfer page on the same fixed directories:
  // both sides next to each other on an iPad in landscape, with the tasks
  // beside them on a 13-inch one, and one side at a time in portrait and on
  // a phone.
  group('mobile file transfer', () {
    setUp(() async {
      PlatformFFI.instance.ffiBindForTesting = NikoFakeBridge();
      await initGlobalFFI();
    });
    for (final brightness in Brightness.values) {
      for (final (device, size) in const [
        ('ipad', Size(1180, 820)),
        ('ipad13', Size(1376, 1032)),
        ('ipad-portrait', Size(820, 1180)),
        ('phone', Size(390, 844)),
      ]) {
        for (final selecting in [false, true]) {
          final name = 'mobile-files-$device${selecting ? '-select' : ''}-'
              '${brightness.name}-${_cjk.isEmpty ? 'en' : 'zh'}-'
              '${size.width.toInt()}x${size.height.toInt()}';
          testWidgets(name, (tester) async {
            NikoLanguage.english = _cjk.isEmpty;
            await _capture(
                tester,
                MaterialApp(
                    debugShowCheckedModeBanner: false,
                    theme: nightlineTheme(brightness)
                        .copyWith(platform: TargetPlatform.iOS),
                    home: NikoTestMobileFilePage(selecting: selecting)),
                name,
                size: size,
                platform: TargetPlatform.iOS,
                padding: device == 'phone'
                    ? const EdgeInsets.only(top: 47, bottom: 34)
                    : const EdgeInsets.only(top: 24, bottom: 20));
          }, skip: _out.isEmpty);
        }
        final menu = 'mobile-files-$device-menu-${brightness.name}-'
            '${_cjk.isEmpty ? 'en' : 'zh'}-'
            '${size.width.toInt()}x${size.height.toInt()}';
        testWidgets(menu, (tester) async {
          NikoLanguage.english = _cjk.isEmpty;
          await _capture(
              tester,
              MaterialApp(
                  debugShowCheckedModeBanner: false,
                  theme: nightlineTheme(brightness)
                      .copyWith(platform: TargetPlatform.iOS),
                  home: const NikoTestMobileFilePage()),
              menu,
              size: size,
              platform: TargetPlatform.iOS,
              padding: device == 'phone'
                  ? const EdgeInsets.only(top: 47, bottom: 34)
                  : const EdgeInsets.only(top: 24, bottom: 20),
              before: () async {
            await tester.tap(find.byTooltip(nikoText('文件操作', 'File actions')));
            await settle(tester);
          });
        }, skip: _out.isEmpty);
      }
    }
  });

  // The TCP tunnel window (desktop) and page (phone and iPad) with a
  // listening tunnel, one waiting for approval and a wake proxy.
  group('tunnel', () {
    Map<String, dynamic> status(
            int port, String phase, String host, int target) =>
        {
          ...tunnel.status(phase: phase, port: port, host: host),
          'target': {'host': host, 'port': target},
          'reason': phase == 'Listening'
              ? 'tunnel_listening'
              : 'tunnel_waiting_approval',
          'remote_phase': phase == 'Listening' ? 'Running' : null,
        };
    Widget view(bool mobile) {
      final model = tunnel.model();
      for (final value in [
        status(8000, 'Listening', '127.0.0.1', 22),
        status(8443, 'WaitingApproval', 'nas.local', 443),
        status(21129, 'Listening', '127.0.0.1', 21128),
      ]) {
        model.handleEvent(tunnel.event(value));
      }
      return NikoTunnelControllerView(
          controller: model,
          mobile: mobile,
          sendCommand: (_) async => '{"ok":true,"reason":"queued"}');
    }

    for (final brightness in Brightness.values) {
      for (final (device, size, platform) in const [
        ('desktop', Size(1100, 760), TargetPlatform.macOS),
        ('ipad', Size(1180, 820), TargetPlatform.iOS),
        ('phone', Size(390, 844), TargetPlatform.iOS),
      ]) {
        final name = 'tunnel-$device-${brightness.name}-'
            '${_cjk.isEmpty ? 'en' : 'zh'}-'
            '${size.width.toInt()}x${size.height.toInt()}';
        testWidgets(name, (tester) async {
          NikoLanguage.english = _cjk.isEmpty;
          final mobile = device != 'desktop';
          await _capture(
              tester,
              MaterialApp(
                  debugShowCheckedModeBanner: false,
                  theme:
                      nightlineTheme(brightness).copyWith(platform: platform),
                  home: Scaffold(
                      appBar: mobile
                          ? AppBar(
                              title: Text(nikoText('TCP 隧道', 'TCP tunnel')),
                              centerTitle: true,
                              leading: NlIconButton(
                                  icon: NlIcons.arrowLeft,
                                  tooltip:
                                      nikoText('退出隧道会话', 'Exit tunnel session'),
                                  onPressed: () {}))
                          : null,
                      body: view(mobile))),
              name,
              size: size,
              platform: platform,
              padding: device == 'phone'
                  ? const EdgeInsets.only(top: 47, bottom: 34)
                  : device == 'ipad'
                      ? const EdgeInsets.only(top: 24, bottom: 20)
                      : EdgeInsets.zero);
        }, skip: _out.isEmpty);
      }
    }
  });

  // The remote terminal's content area in both themes: a prompt, git
  // output and all sixteen colours as text and as backgrounds.
  group('terminal', () {
    const names = [
      'black', 'red', 'green', 'yellow', 'blue', 'magenta', 'cyan', 'white'
    ];
    const prompt =
        '\x1b[1;32mniko@studio\x1b[0m:\x1b[1;34m~/nikodesk\x1b[0m\$ ';
    final sample = [
      '${prompt}git status',
      'On branch \x1b[36mmain\x1b[0m',
      "Your branch is up to date with '\x1b[36morigin/main\x1b[0m'.",
      '',
      'Changes not staged for commit:',
      '        \x1b[31mmodified:   flutter/lib/nikodesk/terminal_look.dart\x1b[0m',
      '',
      'Untracked files:',
      '        \x1b[31mdocs/笔记.md\x1b[0m',
      '',
      '${prompt}palette',
      [for (final (i, n) in names.indexed) '\x1b[3${i}m${n.padRight(9)}\x1b[0m']
          .join(),
      [for (final (i, n) in names.indexed) '\x1b[9${i}m${n.padRight(9)}\x1b[0m']
          .join(),
      [for (var i = 0; i < 8; i++) '\x1b[4${i}m        \x1b[0m '].join(),
      [for (var i = 0; i < 8; i++) '\x1b[10${i}m        \x1b[0m '].join(),
      '',
      '${prompt}ls',
      '\x1b[1;34mdocs\x1b[0m  \x1b[1;34mflutter\x1b[0m  \x1b[1;34mlibs\x1b[0m  '
          'README.md  \x1b[1;32mbuild.sh\x1b[0m',
      prompt,
    ].join('\r\n');
    for (final brightness in Brightness.values) {
      final name = 'terminal-desktop-${brightness.name}-960x560';
      testWidgets(name, (tester) async {
        final terminal = Terminal(maxLines: 200)..write(sample);
        await _capture(
            tester,
            MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: nightlineTheme(brightness)
                    .copyWith(platform: TargetPlatform.macOS),
                home: Builder(
                    builder: (context) => Scaffold(
                        body: TerminalView(terminal,
                            theme: nikoTerminalTheme(NlColors.of(context)),
                            textStyle: nikoTerminalStyle,
                            padding: const EdgeInsets.symmetric(
                                horizontal: 5, vertical: 2))))),
            name,
            size: const Size(960, 560),
            platform: TargetPlatform.macOS);
      }, skip: _out.isEmpty);
    }
  });

  // The native session results, which release builds show on the Sessions
  // page; the shell shots use the local initiation log instead.
  group('orbit results', () {
    const namespace =
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    Widget page(Brightness brightness) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: nightlineTheme(brightness),
        home: Scaffold(
            body: NlScrollWatcher(
                header: (context, scrolled) => NikoPageBar(
                    title: nikoText('会话记录', 'Session history'),
                    subtitle: nikoText('每次会话的认证与结果', 'How each session went'),
                    divider: scrolled),
                child: NikoNativeSessionHistory(
                    namespace: namespace,
                    api: _Audit(),
                    onReconnect: (_, __, ___) async {}))));
    for (final english in [true, false]) {
      final lang = english ? 'en' : 'zh';
      for (final brightness in Brightness.values) {
        final b = brightness.name;
        for (final activities in [false, true]) {
          final tab = activities ? 'capabilities' : 'connections';
          for (final phone in [false, true]) {
            final size = phone ? const Size(390, 844) : const Size(1100, 760);
            final name =
                'orbit-results-$tab-$b-$lang-${size.width.toInt()}x${size.height.toInt()}';
            testWidgets(name, (tester) async {
              NikoLanguage.english = english;
              await _capture(tester, page(brightness), name,
                  size: size,
                  platform: phone ? TargetPlatform.iOS : TargetPlatform.macOS,
                  padding: phone
                      ? const EdgeInsets.only(top: 47, bottom: 34)
                      : EdgeInsets.zero,
                  before: activities
                      ? () => tester.tap(find.byKey(
                          const ValueKey('niko-audit-activities')))
                      : null);
            }, skip: _out.isEmpty || (!english && _cjk.isEmpty));
          }
        }
      }
    }
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
            theme: nightlineTheme(brightness)
                .copyWith(platform: TargetPlatform.macOS),
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
    // Dark: the remote has not allowed it; light: it can turn on now.
    for (final b in Brightness.values) {
      await _capture(
          tester,
          MaterialApp(
              debugShowCheckedModeBanner: false,
              // Desktop metrics, as in the session window.
              theme: nightlineTheme(b)
                  .copyWith(platform: TargetPlatform.macOS),
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
                                allowed: b == Brightness.light,
                                auto: b == Brightness.light,
                                busy: false,
                                onAuto: (_) {},
                                onEnable: () {},
                                onSkip: () {})))),
              ]))),
          'privacy-arrival-${b.name}-${_cjk.isEmpty ? 'en' : 'zh'}-1000x560',
          size: const Size(1000, 560));
    }
  }, skip: _out.isEmpty);

  testWidgets('home compact light, as in the real-app check', (tester) async {
    NikoLanguage.english = _cjk.isEmpty;
    await _capture(tester, shell(Brightness.light),
        'home-light-${_cjk.isEmpty ? 'en' : 'zh'}-compact-800x600',
        size: const Size(800, 600));
  }, skip: _out.isEmpty);

  // The card a session window shows until the first picture arrives.
  for (final step in ['connecting', 'approval', 'video']) {
    for (final english in [true, false]) {
      final lang = english ? 'en' : 'zh';
      testWidgets('session connecting $step $lang', (tester) async {
        NikoLanguage.english = english;
        final progress = NikoConnectionProgress()..begin();
        if (step != 'connecting') progress.transportReady();
        if (step == 'approval') {
          progress.message('wait-remote-accept-nook', 'Prompt');
        }
        if (step == 'video') progress.authenticated(expectsFrame: true);
        await _capture(
            tester,
            MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: nightlineTheme(Brightness.dark),
                // The current step's bar sweeps forever; a still frame
                // lets the capture settle.
                builder: (context, child) => MediaQuery(
                    data: MediaQuery.of(context)
                        .copyWith(disableAnimations: true),
                    child: child!),
                home: Scaffold(
                    backgroundColor: const Color(0xFF212121),
                    body: Center(
                        child: nikoConnectionProgressDialog(progress,
                            onCancel: () {})))),
            'session-connecting-$step-dark-$lang-900x620',
            size: const Size(900, 620));
      }, skip: _out.isEmpty || (!english && _cjk.isEmpty));
    }
  }

  // The control center over a session, as the dialog manager shows it.
  for (final (device, size, platform) in const [
    ('desktop', Size(1100, 760), TargetPlatform.macOS),
    ('ipad', Size(1180, 820), TargetPlatform.iOS),
    ('phone', Size(390, 844), TargetPlatform.iOS),
  ]) {
    for (final section in NikoQuickSection.values) {
      for (final english in [true, false]) {
        final lang = english ? 'en' : 'zh';
        testWidgets('session control center $device ${section.name} $lang',
            (tester) async {
          NikoLanguage.english = english;
          // Only a Windows or Linux desktop maps its keyboard to a Mac.
          final desktop = device == 'desktop';
          await _capture(
              tester,
              MaterialApp(
                  debugShowCheckedModeBanner: false,
                  // The theme is built before _capture overrides the
                  // platform; give it the device's density here.
                  theme: nightlineTheme(Brightness.dark)
                      .copyWith(platform: platform),
                  home: Scaffold(
                      body: Stack(children: [
                    const Positioned.fill(child: _RemotePicture()),
                    const Positioned.fill(
                        child: ColoredBox(color: Colors.black45)),
                    Positioned.fill(
                        child: NikoSessionSheet(
                            onCancel: () {},
                            child: NikoSessionQuickActionsPanel(
                                peerPlatform: 'Mac OS',
                                keyboardAllowed: true,
                                canvasAllowed: true,
                                viewStyle: 'adaptive',
                                macShortcutMode: desktop
                                    ? NikoMacShortcutMode.automatic
                                    : null,
                                onMacShortcutMode:
                                    desktop ? (_) async {} : null,
                                onShortcut: (_) async {},
                                onViewStyle: (_) async {},
                                onResetCanvas: desktop ? null : () {},
                                remoteResolution: const NikoRemoteResolution(
                                    current: NikoDisplayMode(2560, 1440),
                                    original: NikoDisplayMode(2560, 1440),
                                    capturedPixels: NikoDisplayMode(5120, 2880),
                                    fit: NikoDisplayMode(1920, 1080)),
                                autoFitResolution: false,
                                onRemoteResolution: (_) async {},
                                onAutoFitResolution: (_) async {},
                                captureMode: NikoCaptureMode.fit,
                                onCaptureMode: (_) async {},
                                privacyScreen: NikoPrivacyScreenStatus.off,
                                onPrivacyScreen: (_) async {},
                                privacyPasswordExit: true,
                                privacyStyle: NikoPrivacyStyleEditor(
                                    initial:
                                        const NikoPrivacyStyle(motion: false),
                                    allowed: true,
                                    active: false,
                                    onApply: (_) async {}),
                                initialSection: section,
                                onClose: () {}))),
                  ]))),
              'session-control-$device-${section.name}-dark-$lang-'
              '${size.width.toInt()}x${size.height.toInt()}',
              size: size,
              platform: platform);
        }, skip: _out.isEmpty || (!english && _cjk.isEmpty));
      }
    }
  }

  for (final (device, size) in [
    ('ipad', Size(1180, 820)),
    ('phone', Size(390, 844)),
  ]) {
    for (final english in [true, false]) {
      final lang = english ? 'en' : 'zh';
      testWidgets('session display options $device $lang', (tester) async {
        NikoLanguage.english = english;
        List<TRadioMenu<String>> radios(List<String> values, String selected) =>
            [
              for (final value in values)
                TRadioMenu<String>(
                    child: Text(value),
                    value: value,
                    groupValue: selected,
                    onChanged: (_) {}),
            ];
        List<TToggleMenu> toggles(Map<String, bool> values) => [
              for (final MapEntry(key: label, :value) in values.entries)
                TToggleMenu(
                    child: Text(label), value: value, onChanged: (_) {}),
            ];
        await _capture(
            tester,
            MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: nightlineTheme(Brightness.dark)
                    .copyWith(platform: TargetPlatform.iOS),
                home: Scaffold(
                    body: Stack(children: [
                  const Positioned.fill(child: _RemotePicture()),
                  const Positioned.fill(
                      child: ColoredBox(color: Colors.black45)),
                  Positioned.fill(
                      child: NikoSessionSheet(
                          onCancel: () {},
                          child: NikoDisplayOptionsPanel(
                              connection: english
                                  ? 'Relayed and encrypted connection (TCP)'
                                  : '中继加密连接 (TCP)',
                              displays: 2,
                              currentDisplay: 0,
                              onDisplay: (_) {},
                              viewStyles: radios(
                                  ['original', 'adaptive', 'custom'], 'custom'),
                              customScale: (_) => NikoScaleSlider(
                                  percent: 125,
                                  position: .36,
                                  divisions: 995,
                                  onChanged: (_) {},
                                  onStep: (_) {}),
                              qualities: radios(
                                  ['best', 'balanced', 'low', 'custom'],
                                  'balanced'),
                              codecs: radios(
                                  ['auto', 'vp8', 'vp9', 'av1', 'h264', 'h265'],
                                  'auto'),
                              codecInUse: 'H265',
                              onPictureMode: () {},
                              resolution: '2560×1440',
                              onResolution: () {},
                              onVirtualDisplay: () {},
                              cursors: toggles(english
                                  ? {'Show remote cursor': true}
                                  : {'显示远程光标': true}),
                              toggles: toggles(english
                                  ? {
                                      'Lock canvas': false,
                                      'Show quality monitor': true,
                                      'Mute': false,
                                      'Disable clipboard': false,
                                      'Lock after session end': false,
                                    }
                                  : {
                                      '锁定画布': false,
                                      '显示质量监测': true,
                                      '静音': false,
                                      '禁用剪贴板': false,
                                      '会话结束后锁定远程电脑': false,
                                    }),
                              onDiagnostics: () {},
                              onClose: () {}))),
                ]))),
            'session-display-$device-dark-$lang-'
            '${size.width.toInt()}x${size.height.toInt()}',
            size: size,
            platform: TargetPlatform.iOS);
      }, skip: _out.isEmpty || (!english && _cjk.isEmpty));
    }
  }

  // The key bar over a session: a Mac from the iPad, a PC from a phone.
  for (final (device, size, platform, keys) in [
    ('ipad', const Size(1180, 820), kPeerPlatformMacOS, false),
    ('phone', const Size(390, 844), kPeerPlatformWindows, true),
  ]) {
    for (final english in [true, false]) {
      final lang = english ? 'en' : 'zh';
      testWidgets('session key bar $device $lang', (tester) async {
        NikoLanguage.english = english;
        await _capture(
            tester,
            MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: nightlineTheme(Brightness.light)
                    .copyWith(platform: TargetPlatform.iOS),
                home: Scaffold(
                    body: Stack(children: [
                  const Positioned.fill(child: _RemotePicture()),
                  NikoKeyBarFrame(
                      keyboardIsVisible: true,
                      child: NikoKeyBar(
                          peerPlatform: platform,
                          down: {
                            keys ? NikoModifier.control : NikoModifier.command
                          },
                          more: !keys,
                          fn: keys,
                          onModifier: (_) {},
                          onKey: (_) {},
                          onShortcut: (_) {},
                          onMore: () {},
                          onFn: () {},
                          onPin: () {})),
                ]))),
            'session-keys-$device-$lang-'
            '${size.width.toInt()}x${size.height.toInt()}',
            size: size,
            platform: TargetPlatform.iOS);
      }, skip: _out.isEmpty || (!english && _cjk.isEmpty));
    }
  }

  // The chat and voice choice over a session: a sheet on a phone, a card
  // on an iPad.
  for (final (device, size, padding) in const [
    ('phone', Size(390, 844), EdgeInsets.only(top: 47, bottom: 34)),
    ('ipad', Size(1180, 820), EdgeInsets.only(top: 24, bottom: 20)),
  ]) {
  for (final english in [true, false]) {
    final lang = english ? 'en' : 'zh';
    testWidgets('session chat options $device $lang', (tester) async {
      NikoLanguage.english = english;
      await _capture(
          tester,
          MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: nightlineTheme(Brightness.light)
                  .copyWith(platform: TargetPlatform.iOS),
              home: Scaffold(
                  body: Stack(children: [
                const Positioned.fill(child: _RemotePicture()),
                // The dock's chat button opens it; here an unseen one does,
                // below the iOS status bar, which takes taps of its own.
                Positioned(
                    left: 0,
                    top: 120,
                    child: Opacity(
                        opacity: 0,
                        child: Builder(
                            builder: (context) => TextButton(
                                onPressed: () => showNikoMobileChatOptions(
                                    context,
                                    onTextChat: () {},
                                    onVoiceCall: () {}),
                                child: const Text('open'))))),
              ]))),
          'session-chat-$device-$lang-${size.width.toInt()}x${size.height.toInt()}',
          size: size,
          platform: TargetPlatform.iOS,
          padding: padding, before: () async {
        await tester.tap(find.text('open'));
      });
    }, skip: _out.isEmpty || (!english && _cjk.isEmpty));
  }
  }

  // The chat window over a session, with the round button that brings it
  // back once tucked away.
  for (final (device, size, padding) in const [
    ('ipad', Size(1180, 820), EdgeInsets.only(top: 24, bottom: 20)),
    ('phone', Size(390, 844), EdgeInsets.only(top: 47, bottom: 34)),
  ]) {
    for (final english in [true, false]) {
      final lang = english ? 'en' : 'zh';
      testWidgets('session chat window $device $lang', (tester) async {
        NikoLanguage.english = english;
        final today = DateTime.now();
        DateTime at(int minute) =>
            DateTime(today.year, today.month, today.day, 14, minute);
        final me = ChatUser(id: '', firstName: 'Me');
        final peer = ChatUser(id: '123456789', firstName: 'Mac mini');
        String t(String zh, String en) => english ? en : zh;
        final messages = [
          ChatMessage(
              user: peer,
              text: t('好的，稍等。', 'Sure, one moment.'),
              createdAt: at(5)),
          ChatMessage(
              user: me,
              text: t('顺便把日志发我一份', 'Send me the log too'),
              createdAt: at(3)),
          ChatMessage(
              user: me,
              text: t('收到，我看一下。', 'Got it, taking a look.'),
              createdAt: at(3)),
          ChatMessage(
              user: peer,
              text: t('构建跑完了，结果在桌面上。',
                  'The build finished; the results are on the desktop.'),
              createdAt: at(2)),
        ];
        final text = TextEditingController();
        addTearDown(text.dispose);
        final window = nikoChatWindowSize(size);
        final wide = size.width >= 600;
        await _capture(
            tester,
            MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: nightlineTheme(Brightness.light)
                    .copyWith(platform: TargetPlatform.iOS),
                home: Scaffold(
                    body: Stack(children: [
                  const Positioned.fill(child: _RemotePicture()),
                  Positioned(
                      left: wide ? null : (size.width - window.width) / 2,
                      right: wide ? 24 : null,
                      top: wide ? 80 : 120,
                      width: window.width,
                      height: window.height,
                      child: Builder(
                          builder: (context) => Theme(
                              data: nikoSessionTheme(context),
                              child: NikoChatWindowFrame(
                                  onPanUpdate: (_) {},
                                  onMinimize: () {},
                                  onClose: () {},
                                  child: NikoChatView(
                                      me: me,
                                      messages: messages,
                                      onSend: (_) {},
                                      textController: text))))),
                  Positioned(
                      right: 16,
                      bottom: 120,
                      width: 60,
                      height: 60,
                      child: NikoChatBubbleButton(onPressed: () {})),
                ]))),
            'session-chat-window-$device-$lang-'
            '${size.width.toInt()}x${size.height.toInt()}',
            size: size,
            platform: TargetPlatform.iOS,
            padding: padding);
      }, skip: _out.isEmpty || (!english && _cjk.isEmpty));
    }
  }

  // The voice call panel over a session, before anything is prepared.
  for (final (device, size, platform, padding) in const [
    ('desktop', Size(1100, 760), TargetPlatform.macOS, EdgeInsets.zero),
    ('ipad', Size(1180, 820), TargetPlatform.iOS,
        EdgeInsets.only(top: 24, bottom: 20)),
    ('phone', Size(390, 844), TargetPlatform.iOS,
        EdgeInsets.only(top: 47, bottom: 34)),
  ]) {
    for (final english in [true, false]) {
      final lang = english ? 'en' : 'zh';
      testWidgets('session voice $device $lang', (tester) async {
        NikoLanguage.english = english;
        // Fixtures only: no native voice call is made.
        final owner = NikoVoiceSessionOwner(
            contextKey: 'session-A',
            namespace: 'a' * 64,
            peerId: '123456789',
            isCurrent: () => true,
            readAvailability: () async => voiceEnabled,
            prepareNative: () async => '{"ok":true,"status":"queued"}',
            commandNative: (c) async => voiceQueued(c));
        addTearDown(owner.dispose);
        await _capture(
            tester,
            MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: nightlineTheme(Brightness.light)
                    .copyWith(platform: platform),
                home: Scaffold(
                    body: Stack(children: [
                  const Positioned.fill(child: _RemotePicture()),
                  Positioned(
                      left: 0,
                      top: 120,
                      child: Opacity(
                          opacity: 0,
                          child: Builder(
                              builder: (context) => TextButton(
                                  onPressed: () =>
                                      showNikoVoiceSession(context, owner),
                                  child: const Text('open'))))),
                ]))),
            'session-voice-$device-$lang-'
            '${size.width.toInt()}x${size.height.toInt()}',
            size: size,
            platform: platform,
            padding: padding, before: () async {
          await tester.tap(find.text('open'));
        });
      }, skip: _out.isEmpty || (!english && _cjk.isEmpty));
    }
  }

  // The picture modes and the diagnostics over a session.
  for (final (device, size, platform) in const [
    ('desktop', Size(1100, 760), TargetPlatform.macOS),
    ('ipad', Size(1180, 820), TargetPlatform.iOS),
    ('phone', Size(390, 844), TargetPlatform.iOS),
  ]) {
    for (final english in [true, false]) {
      final lang = english ? 'en' : 'zh';
      for (final tool in ['picture', 'diagnostics']) {
        testWidgets('session $tool $device $lang', (tester) async {
          NikoLanguage.english = english;
          final metrics = SessionMetrics()
            ..connection(secure: true, direct: false, transport: 'TCP')
            ..relayTarget = 'relay.example.net:21117'
            ..proxyInUse = false
            ..update({
              'fps': '{"0":59}',
              'delay': '24',
              'speed': '845.2kB/s',
              'target_bitrate': '7200',
              'codec_format': 'h265',
              'chroma': '4:2:0',
            })
            ..hostVideo(jsonEncode({
              'display': 0,
              'width': 2560,
              'height': 1440,
              'encoder': 'H265',
              'hardware': true,
              'fps': 59.6,
              'captureMs': 4.12,
              'convertMs': 1.2,
              'encodeMs': 3.4,
            }));
          await _capture(
              tester,
              MaterialApp(
                  debugShowCheckedModeBanner: false,
                  theme: nightlineTheme(Brightness.dark)
                      .copyWith(platform: platform),
                  home: Scaffold(
                      body: Stack(children: [
                    const Positioned.fill(child: _RemotePicture()),
                    const Positioned.fill(
                        child: ColoredBox(color: Colors.black45)),
                    Positioned.fill(
                        child: NikoSessionSheet(
                            width: tool == 'picture' ? 590 : 690,
                            onCancel: () {},
                            child: tool == 'picture'
                                ? NikoPictureModePanel(
                                    loading: false,
                                    mode: PictureMode.custom,
                                    onMode: (_) {},
                                    smoothFps: 120,
                                    quality: 50,
                                    onQuality: (_) {},
                                    fps: 60,
                                    onFps: (_) {},
                                    supportsFps: true,
                                    currentQuality: 'custom',
                                    currentFps: '60',
                                    message: english
                                        ? 'Request sent and saved for this device. See diagnostics for observed results; the peer may adapt to its capabilities and load.'
                                        : '请求已发送并按设备保存。请在诊断中查看实际结果；对端可能继续按能力和负载调整。',
                                    onApply: () {},
                                    onClose: () {})
                                : NikoDiagnosticsPanel(
                                    metrics: metrics,
                                    sampling: true,
                                    onSampling: (_) {},
                                    onReloadSampling: () {},
                                    resolutions: const [(2560, 1440)],
                                    scale: 1,
                                    onExport: () {},
                                    onClose: () {}))),
                  ]))),
              'session-$tool-$device-dark-$lang-'
              '${size.width.toInt()}x${size.height.toInt()}',
              size: size,
              platform: platform);
        }, skip: _out.isEmpty || (!english && _cjk.isEmpty));
      }
    }
  }

  for (final (device, size) in [
    ('ipad', Size(1180, 820)),
    ('phone', Size(390, 844)),
  ]) {
    for (final english in [true, false]) {
      final lang = english ? 'en' : 'zh';
      testWidgets('session more actions $device $lang', (tester) async {
        NikoLanguage.english = english;
        String translated(String key) => english
            ? key
            : const {
                  'OS Password': '操作系统密码',
                  'Send clipboard keystrokes': '发送剪贴板按键',
                  'Reset canvas': '重置画布',
                  'Note': '备注',
                  'Insert Ctrl + Alt + Del': '插入 Ctrl + Alt + Del',
                  'Restart remote device': '重启远程电脑',
                  'Insert Lock': '锁定远程电脑',
                  'Refresh': '刷新画面',
                  'Start session recording': '开始录屏',
                  'Copy Fingerprint': '复制指纹',
                  'Back': '回退',
                  'Home': '主页',
                  'Apps': '应用',
                  'Volume up': '提升音量',
                  'Volume down': '降低音量',
                  'Power': '电源',
                }[key] ??
                key;
        List<TTextMenu> menus(List<String> keys) => [
              for (final key in keys)
                TTextMenu(child: Text(translated(key)), onPressed: () {}),
            ];
        // The iPad controls a Mac; the phone an Android phone.
        final android = device == 'phone';
        final entries = nikoMoreActionEntries(
            phone: android
                ? menus([
                    'Back',
                    'Home',
                    'Apps',
                    'Volume up',
                    'Volume down',
                    'Power'
                  ])
                : const [],
            controls: menus([
              if (!android) ...[
                'OS Password',
                'Send clipboard keystrokes',
              ],
              'Reset canvas',
              'Note',
              if (!android) ...[
                'Insert Ctrl + Alt + Del',
                'Restart remote device',
                'Insert Lock',
              ],
              'Refresh',
              'Start session recording',
              'Copy Fingerprint',
            ]),
            translate: translated,
            onEditOsPassword: () {})!;
        final ink = NikoMobileControlBar.ink;
        Widget button(IconData icon, String tooltip) => IconButton(
            color: ink, tooltip: tooltip, icon: Icon(icon), onPressed: () {});
        final more = nikoText('更多操作', 'More actions');
        await _capture(
            tester,
            MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: nightlineTheme(Brightness.dark)
                    .copyWith(platform: TargetPlatform.iOS),
                home: Scaffold(
                    backgroundColor: Colors.black,
                    body: Column(children: [
                      const Expanded(child: _RemotePicture()),
                      // The session page's bar: 8 pt at the sides, 12
                      // above and below, then the home indicator's inset.
                      Padding(
                          padding: const EdgeInsets.fromLTRB(8, 12, 8, 46),
                          child: NikoMobileControlBar(
                              actions: Row(children: [
                                button(NlIcons.zap, 'Control center'),
                                button(NlIcons.monitor, 'Display'),
                                button(NlIcons.keyboard, 'Keyboard'),
                                button(NlIcons.mouse, 'Mouse'),
                                button(NlIcons.messageSquare, 'Chat'),
                              ]),
                              more: Builder(
                                  builder: (anchor) => IconButton(
                                      color: ink,
                                      tooltip: more,
                                      icon: const Icon(NlIcons.ellipsis),
                                      onPressed: () =>
                                          showNikoDockMenu(anchor, entries))),
                              collapse: button(NlIcons.chevronDown, 'Hide'),
                              endSession: IconButton(
                                  tooltip: 'End',
                                  icon: Icon(NlIcons.power,
                                      color: NlColors.dark.dangerText),
                                  onPressed: () {}))),
                    ]))),
            'session-more-$device-dark-$lang-'
            '${size.width.toInt()}x${size.height.toInt()}',
            size: size,
            platform: TargetPlatform.iOS,
            before: () => tester.tap(find.byTooltip(more)));
      }, skip: _out.isEmpty || (!english && _cjk.isEmpty));
    }
  }

  for (final (device, size, touch) in [
    ('ipad', Size(1180, 820), false),
    ('phone', Size(390, 844), true),
  ]) {
    for (final english in [true, false]) {
      final lang = english ? 'en' : 'zh';
      testWidgets('session gestures $device $lang', (tester) async {
        NikoLanguage.english = english;
        await _capture(
            tester,
            MaterialApp(
                debugShowCheckedModeBanner: false,
                // A light app theme: session chrome stays dark.
                theme: nightlineTheme(Brightness.light)
                    .copyWith(platform: TargetPlatform.iOS),
                home: Scaffold(
                    backgroundColor: Colors.black,
                    body: Column(children: [
                      const Expanded(child: _RemotePicture()),
                      Padding(
                          padding: const EdgeInsets.only(bottom: 34),
                          child: NikoGestureCard(
                              child: NikoGesturePanel(
                                  touchMode: touch,
                                  onTouchMode: (_) {},
                                  virtualMouse: true,
                                  onVirtualMouse: (_) {},
                                  mouseScale: 1.2,
                                  onMouseScale: (_) {},
                                  joystick: true,
                                  onJoystick: (_) {},
                                  relative: false,
                                  onRelative: (_) {}))),
                    ]))),
            'session-gestures-$device-${touch ? 'touch' : 'mouse'}-$lang-'
            '${size.width.toInt()}x${size.height.toInt()}',
            size: size,
            platform: TargetPlatform.iOS);
      }, skip: _out.isEmpty || (!english && _cjk.isEmpty));

      testWidgets('session guide $device $lang', (tester) async {
        NikoLanguage.english = english;
        await _capture(
            tester,
            MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: nightlineTheme(Brightness.light)
                    .copyWith(platform: TargetPlatform.iOS),
                home: Scaffold(
                    backgroundColor: Colors.black,
                    body: Stack(children: [
                      const Positioned.fill(child: _RemotePicture()),
                      const Positioned.fill(
                          child: ColoredBox(color: Colors.black45)),
                      Positioned.fill(
                          child: NikoMobileSessionGuide(touchMode: touch)),
                    ]))),
            'session-guide-$device-$lang-'
            '${size.width.toInt()}x${size.height.toInt()}',
            size: size,
            platform: TargetPlatform.iOS,
            padding: const EdgeInsets.only(bottom: 34));
      }, skip: _out.isEmpty || (!english && _cjk.isEmpty));
    }
  }

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

  for (final preset in NlPreset.values) {
    for (final brightness in Brightness.values) {
      final name = 'components-${preset.name}-${brightness.name}';
      Widget sheet() => MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: nightlineTheme(brightness, preset: preset)
              .copyWith(platform: TargetPlatform.macOS),
          builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: true),
              child: child!),
          home: const Scaffold(body: NikoComponentSheet()));
      testWidgets(name, (tester) async {
        NikoLanguage.english = true;
        await _capture(tester, sheet(), name,
            size: const Size(1600, 1120), before: () async {
          NlToast.show(tester.element(find.byType(NikoComponentSheet)),
              'Device ID copied',
              tone: NlToastTone.ok, duration: const Duration(minutes: 1));
        });
        NlToast.dismiss();
      }, skip: _out.isEmpty);
      if (preset == NlPreset.orbit) {
        testWidgets('$name-menu', (tester) async {
          NikoLanguage.english = true;
          await _capture(tester, sheet(), '$name-menu',
              size: const Size(1600, 1120),
              before: () =>
                  tester.tap(find.byKey(NikoComponentSheet.menuKey)));
        }, skip: _out.isEmpty);
      }
    }
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
