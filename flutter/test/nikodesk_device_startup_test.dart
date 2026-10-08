import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/generated_bridge.dart';
import 'package:flutter_hbb/nikodesk/device_page.dart';
import 'package:flutter_hbb/nikodesk/device_store.dart';
import 'package:flutter_hbb/nikodesk/server_gateway.dart';
import 'package:flutter_hbb/nikodesk/theme.dart';
import 'package:flutter_hbb/nikodesk/ui.dart';
import 'package:flutter_test/flutter_test.dart';

// The production gateway waits on this controlled IPC response. The widget and
// directory read are real; the native bridge never accesses an installed app.
class _Bridge implements Rustdesk {
  final status = Completer<String>();
  Object? optionsError;
  String enabled = 'N';
  int optionReads = 0;

  @override
  Future<String> mainGetConnectStatus({dynamic hint}) => status.future;

  @override
  Future<String> mainGetOptions({dynamic hint}) async {
    optionReads++;
    if (optionsError != null) throw optionsError!;
    return jsonEncode({
      'custom-rendezvous-server': 'fixture.invalid',
      'relay-server': 'fixture.invalid:21117',
      'key': base64Encode(List.filled(32, 1)),
      'stop-service': enabled,
      'nikodesk-server-namespace': 'a' * 64,
    });
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _HeldDirectory extends DeviceStore {
  final release = Completer<void>();
  _HeldDirectory(super.directory, {super.serverNamespace});

  @override
  Future<DeviceDirectory> load() async {
    final directory = await super.load();
    await release.future;
    return directory;
  }
}

void main() {
  late Directory directory;
  late DeviceStore store;
  late _Bridge bridge;
  setUp(() async {
    NikoLanguage.english = false;
    directory = await Directory.systemTemp.createTemp('niko-device-startup-');
    store = DeviceStore(directory, serverNamespace: 'a' * 64);
    await store.save(const DeviceEntry(id: '123456', alias: 'Office fixture'));
    bridge = _Bridge();
  });
  tearDown(() async => directory.delete(recursive: true));

  Future<void> showPage(WidgetTester tester,
      {DeviceStore? directoryStore}) async {
    await tester.binding.setSurfaceSize(const Size(1100, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: NikoDevicePage(
                store: directoryStore ?? store,
                gateway: NativeServerGateway(bridge: bridge),
                native: false))));
  }

  Future<void> drainFileRead(WidgetTester tester) async {
    await tester.runAsync(() async {
      for (var attempt = 0; attempt < 20; attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        await tester.pump();
        if (find.text('Office fixture').evaluate().isNotEmpty) break;
      }
    });
    await tester.pump();
  }

  NikoPrimaryButton connectButton(WidgetTester tester) =>
      tester.widget(find.byKey(const Key('nikodesk-device-connect-123456')));

  Future<void> completeStatus(WidgetTester tester) async {
    await tester.runAsync(() async {
      bridge.status.complete('{"status_num":1}');
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pumpAndSettle();
  }

  testWidgets('local devices appear while registration IPC is still pending',
      (tester) async {
    await showPage(tester);
    await drainFileRead(tester);
    expect(bridge.optionReads, 0);
    expect(bridge.status.isCompleted, false);
    expect(find.text('Office fixture'), findsOneWidget);
    expect(find.textContaining('在线未知'), findsOneWidget);
    expect(find.text('私服配置状态未知'), findsOneWidget);
    expect(find.text('已注册'), findsNothing);
    expect(connectButton(tester).onPressed, isNull);

    await completeStatus(tester);
    expect(bridge.optionReads, 1);
    expect(find.text('已注册'), findsOneWidget);
    expect(connectButton(tester).onPressed, isNotNull);
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'late invalid settings preserve visible devices but block connect',
      (tester) async {
    await showPage(tester);
    await drainFileRead(tester);
    expect(find.text('Office fixture'), findsOneWidget);
    bridge.optionsError = const FormatException('Synthetic settings failure');
    await completeStatus(tester);
    expect(find.text('Office fixture'), findsOneWidget);
    expect(find.textContaining('无法读取私服配置或设备目录'), findsOneWidget);
    expect(connectButton(tester).onPressed, isNull);
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  testWidgets('late paused settings never enable the earlier device list',
      (tester) async {
    await showPage(tester);
    await drainFileRead(tester);
    expect(find.text('Office fixture'), findsOneWidget);
    bridge.enabled = 'Y';
    await completeStatus(tester);
    expect(find.text('注册服务已停止'), findsOneWidget);
    expect(connectButton(tester).onPressed, isNull);
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  testWidgets('directory schema failure is not erased by late valid settings',
      (tester) async {
    await tester.runAsync(
        () => store.file.writeAsString('{"version":999,"devices":[]}'));
    await showPage(tester);
    await drainFileRead(tester);
    await completeStatus(tester);
    expect(find.textContaining('设备目录由更高版本创建'), findsOneWidget);
    expect(
        tester
            .widget<NikoPrimaryButton>(
                find.byKey(const Key('nikodesk-hero-connect')))
            .onPressed,
        isNull);
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  testWidgets('disposing during either pending read cannot update the page',
      (tester) async {
    final held = _HeldDirectory(directory, serverNamespace: 'a' * 64);
    await showPage(tester, directoryStore: held);
    await tester.pumpWidget(const SizedBox());
    bridge.status.complete('{"status_num":1}');
    held.release.complete();
    await drainFileRead(tester);
    expect(find.text('Office fixture'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
