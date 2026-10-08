import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

/// Called only by the NikoDesk desktop main window, before any connection UI.
Future<bool> initializeNikoMainWindow(
    Future<void> Function() initialize) async {
  try {
    await initialize();
    return true;
  } catch (_) {
    debugPrint(
        'NikoDesk initialization failed; showing the startup error page.');
  }

  // This path cannot use bind, gFFI, saved window settings or the normal App.
  runApp(const NikoStartupFailureApp());
  try {
    await windowManager.waitUntilReadyToShow(const WindowOptions(
      size: Size(640, 400),
      minimumSize: Size(360, 260),
      title: 'NikoDesk',
      titleBarStyle: TitleBarStyle.normal,
      backgroundColor: Color(0xfff7f8fa),
      skipTaskbar: false,
    ));
    await windowManager.setPreventClose(false);
    if (Platform.isMacOS) await windowManager.setMovable(true);
    await windowManager.setOpacity(1);
    await windowManager.show();
    await windowManager.focus();
  } catch (_) {
    debugPrint('NikoDesk startup error page could not be shown: '
        'the window manager is unavailable.');
  }
  return false;
}

Future<void> quitNikoStartupWindow() async {
  try {
    await windowManager.destroy();
  } catch (_) {
    debugPrint('NikoDesk could not close its startup window: '
        'the window manager is unavailable.');
  }
}

class NikoStartupFailureApp extends StatelessWidget {
  const NikoStartupFailureApp({super.key});

  @override
  Widget build(BuildContext context) {
    final chinese =
        WidgetsBinding.instance.platformDispatcher.locale.languageCode == 'zh';
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'NikoDesk',
      theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff356be9)),
          scaffoldBackgroundColor: const Color(0xfff7f8fa)),
      home: Scaffold(
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(32),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('NikoDesk',
                        style:
                            TextStyle(fontSize: 14, color: Color(0xff667085))),
                    const SizedBox(height: 16),
                    Text(chinese ? '启动失败' : 'Unable to start',
                        style: const TextStyle(
                            fontSize: 26, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 12),
                    Text(
                        chinese
                            ? '初始化未完成，工作界面暂时无法打开。请退出后重新打开 NikoDesk。如果仍然失败，请重新安装应用。'
                            : 'Initialization did not finish, so the workspace could not open. Quit and reopen NikoDesk. If this continues, reinstall the app.',
                        style: const TextStyle(fontSize: 15, height: 1.6)),
                    const SizedBox(height: 24),
                    FilledButton(
                      key: const Key('nikodesk-startup-quit'),
                      onPressed: quitNikoStartupWindow,
                      child: Text(chinese ? '退出' : 'Quit'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
