import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/nikodesk/home_settings.dart';
import 'package:flutter_hbb/nikodesk/policy.dart';
import 'package:flutter_hbb/nikodesk/product_build_info.dart';
import 'package:flutter_hbb/nikodesk/server_gateway.dart';
import 'package:flutter_hbb/nikodesk/theme.dart';
import 'package:flutter_hbb/nikodesk/ui.dart';
import 'package:flutter_hbb/nikodesk/updater.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';

// Explicit metadata/gateway fixtures, not installed-package or session evidence.
const _fixture = ProductBuildInfo(
    version: '9.8.7', buildNumber: '42', nativeVersion: '0.9.0');
const _later = ProductBuildInfo(
    version: '9.8.9', buildNumber: '43', nativeVersion: '0.9.0');
const _obsolete = ProductBuildInfo(
    version: '100.0.0', buildNumber: '1', nativeVersion: '0.9.0');
const _release = NikoReleaseInfo(tag: 'v9.8.6', notes: '', assets: []);

PackageInfo _package() => PackageInfo(
    appName: 'NikoDesk',
    packageName: 'fixture.example',
    version: _fixture.version!,
    buildNumber: _fixture.buildNumber!);

class _Gateway implements ServerGateway {
  @override
  Future<ServerSnapshot> read() async => ServerSnapshot(
      PrivateServerConfig('private.example', 'private.example:21117',
          base64Encode(List.filled(32, 7))),
      1,
      true);
  @override
  Future<void> save(PrivateServerConfig config) async {}
}

void main() {
  setUp(() => NikoLanguage.english = true);

  test('never completing package does not delay starting native read',
      () async {
    final package = Completer<PackageInfo>();
    var nativeStarted = false;
    final value = await ProductBuildInfo.read(
        timeout: const Duration(milliseconds: 20),
        packageLoader: () => package.future,
        nativeVersionLoader: () async {
          nativeStarted = true;
          expect(package.isCompleted, isFalse);
          return '0.9.0';
        });
    expect(nativeStarted, isTrue);
    expect(value.version, isNull);
    expect(value.buildNumber, isNull);
    expect(value.nativeVersion, '0.9.0');
  });

  test('never completing native preserves the successful package fields',
      () async {
    final native = Completer<String>();
    final value = await ProductBuildInfo.read(
        timeout: const Duration(milliseconds: 20),
        packageLoader: () async => _package(),
        nativeVersionLoader: () => native.future);
    expect(value.fullVersion, '9.8.7+42');
    expect(value.nativeVersion, isNull);
    expect(value.hasUnknown, isTrue);
  });

  test('late package/native completion cannot mutate a timed-out snapshot',
      () async {
    final package = Completer<PackageInfo>();
    final native = Completer<String>();
    final value = await ProductBuildInfo.read(
        timeout: const Duration(milliseconds: 20),
        packageLoader: () => package.future,
        nativeVersionLoader: () => native.future);
    package.complete(_package());
    native.complete('0.9.0');
    await Future<void>.delayed(Duration.zero);
    expect(value.version, isNull);
    expect(value.nativeVersion, isNull);
    expect(
        value.updateStatus(_release.tag), contains('availability is unknown'));
    expect(value.updateStatus(_release.tag), isNot(contains('No higher')));
  });

  testWidgets(
      'About waiting times out to unknown and retry ignores late old data',
      (tester) async {
    final old = Completer<ProductBuildInfo>();
    final retry = Completer<ProductBuildInfo>();
    var reads = 0;
    await tester.pumpWidget(MaterialApp(
        theme: nikoTheme(Brightness.light),
        home: Scaffold(
            body: SingleChildScrollView(
                child: NikoProductAbout(
                    timeout: const Duration(milliseconds: 50),
                    loadInfo: () =>
                        ++reads == 1 ? old.future : retry.future)))));
    expect(find.text('Reading version information…'), findsOneWidget);
    expect(find.textContaining('NikoDesk Unknown'), findsNothing);
    await tester.pump(const Duration(milliseconds: 51));
    await tester.pump();
    expect(find.text('NikoDesk Unknown (build unknown)'), findsOneWidget);
    await tester.tap(find.text('Retry version read'));
    await tester.pump();
    expect(find.text('Reading version information…'), findsOneWidget);
    retry.complete(_fixture);
    await tester.pumpAndSettle();
    old.complete(_obsolete);
    await tester.pumpAndSettle();
    expect(find.text('NikoDesk 9.8.7+42'), findsOneWidget);
    expect(find.text('NikoDesk 100.0.0+1'), findsNothing);
    expect(reads, 2);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  Future<void> settings(WidgetTester tester, NikoSettingsView view) async {
    await tester.binding.setSurfaceSize(const Size(1100, 1800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
        theme: nikoTheme(Brightness.light), home: Scaffold(body: view)));
    await tester.pump();
    await tester.pump();
  }

  testWidgets('nightly is an explicit preview with manual download',
      (tester) async {
    final nightly = NikoReleaseInfo(
        tag: 'nightly',
        name: 'NikoDesk nightly (abcdef0)',
        notes: 'Preview fixture',
        publishedAt: DateTime.utc(2026, 10, 2, 18, 34),
        assets: [
          NikoReleaseAsset('NikoDesk-macos-arm64.zip',
              Uri.parse('https://github.com/preview.zip'))
        ]);
    await settings(
        tester,
        NikoSettingsView(
            native: false,
            gateway: _Gateway(),
            buildInfoLoader: () async => _fixture,
            updateChecker: (_) async => nightly));
    await tester.pumpAndSettle();
    final channel = find.byKey(const Key('nikodesk-update-channel'));
    expect(
        tester
            .widget<DropdownButtonFormField<NikoUpdateChannel>>(channel)
            .initialValue,
        NikoUpdateChannel.stable);
    await tester.tap(channel);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Nightly preview').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Check for updates'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('NikoDesk nightly (abcdef0)'), findsOneWidget);
    expect(find.textContaining('Published:'), findsOneWidget);
    expect(find.textContaining('cannot establish whether it is newer'),
        findsOneWidget);
    expect(find.text('Update available'), findsNothing);
    expect(find.text('Download'), findsOneWidget);
    expect(find.text('Download and verify'), findsNothing);
    await tester.tap(find.text('Later'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('channel cannot change while a check is pending', (tester) async {
    final pending = Completer<NikoReleaseInfo?>();
    await settings(
        tester,
        NikoSettingsView(
            native: false,
            gateway: _Gateway(),
            buildInfoLoader: () async => _fixture,
            updateChecker: (_) => pending.future));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Check for updates'));
    await tester.pump();
    final channel = find.byKey(const Key('nikodesk-update-channel'));
    expect(
        tester
            .widget<DropdownButtonFormField<NikoUpdateChannel>>(channel)
            .onChanged,
        isNull);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<DropdownButtonFormField<NikoUpdateChannel>>(channel)
            .onChanged,
        isNotNull);
    pending.complete(null);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a synchronous retry failure remains unknown and can retry again',
      (tester) async {
    var reads = 0;
    await tester.pumpWidget(MaterialApp(home: Scaffold(
        body: SingleChildScrollView(child: NikoProductAbout(loadInfo: () {
      reads++;
      if (reads <= 2) throw StateError('fixture synchronous failure');
      return Future.value(_fixture);
    })))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Retry version read'));
    await tester.pumpAndSettle();
    expect(find.text('NikoDesk Unknown (build unknown)'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Retry version read'));
    await tester.pumpAndSettle();
    expect(find.text('NikoDesk 9.8.7+42'), findsOneWidget);
    expect(reads, 3);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('server state is committed before hung metadata, with retry',
      (tester) async {
    final pending = Completer<ProductBuildInfo>();
    var reads = 0;
    await settings(
        tester,
        NikoSettingsView(
            native: false,
            gateway: _Gateway(),
            buildInfoLoader: () =>
                ++reads == 1 ? pending.future : Future.value(_fixture)));
    expect(find.text('Registered'), findsOneWidget);
    expect(find.text('Reading version information…'), findsOneWidget);
    await tester.pump(ProductBuildInfo.loadTimeout);
    await tester.pump();
    expect(find.text('NikoDesk Unknown (build unknown)'), findsNWidgets(2));
    await tester.tap(find.byKey(const Key('nikodesk-version-retry')));
    await tester.pumpAndSettle();
    expect(find.text('NikoDesk 9.8.7+42'), findsNWidgets(2));
    pending.complete(_obsolete);
    await tester.pumpAndSettle();
    expect(find.text('NikoDesk 100.0.0+1'), findsNothing);
    expect(find.text('Registered'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('new settings refresh refuses the older metadata result',
      (tester) async {
    final old = Completer<ProductBuildInfo>();
    final gateway = _Gateway();
    var reads = 0;
    Future<ProductBuildInfo> loader() =>
        ++reads == 1 ? old.future : Future.value(_fixture);
    await settings(
        tester,
        NikoSettingsView(
            native: false,
            active: false,
            gateway: gateway,
            buildInfoLoader: loader));
    await settings(
        tester,
        NikoSettingsView(
            native: false,
            active: true,
            gateway: gateway,
            buildInfoLoader: loader));
    await tester.pumpAndSettle();
    old.complete(_obsolete);
    await tester.pumpAndSettle();
    expect(find.text('NikoDesk 9.8.7+42'), findsNWidgets(2));
    expect(find.text('NikoDesk 100.0.0+1'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'cancel metadata update restores actions and rejects old completion',
      (tester) async {
    final old = Completer<ProductBuildInfo>();
    var reads = 0;
    Future<ProductBuildInfo> loader() {
      reads++;
      if (reads == 1) return Future.value(_fixture);
      if (reads == 2) return old.future;
      return Future.value(_later);
    }

    await settings(
        tester,
        NikoSettingsView(
            native: false,
            gateway: _Gateway(),
            buildInfoLoader: loader,
            updateChecker: (_) async => _release));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Check for updates'));
    await tester.pump();
    await tester.pump();
    expect(reads, 2);
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    await tester.pump();
    final button = find.widgetWithText(OutlinedButton, 'Check for updates');
    expect(tester.widget<OutlinedButton>(button).onPressed, isNotNull);
    await tester.tap(button);
    await tester.pump();
    await tester.pump();
    expect(reads, 3);
    old.complete(_obsolete);
    await tester.pump();
    await tester.pump();
    expect(find.text('NikoDesk 9.8.9+43'), findsNWidgets(2));
    expect(find.text('NikoDesk 100.0.0+1'), findsNothing);
    expect(tester.widget<OutlinedButton>(button).onPressed, isNotNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(ProductBuildInfo.loadTimeout);
  });

  testWidgets(
      'cancel a hung release lookup and no-release skips pending metadata',
      (tester) async {
    final oldRelease = Completer<NikoReleaseInfo?>();
    final initialMetadata = Completer<ProductBuildInfo>();
    var checks = 0;
    var reads = 0;
    await settings(
        tester,
        NikoSettingsView(
            native: false,
            gateway: _Gateway(),
            buildInfoLoader: () {
              reads++;
              return initialMetadata.future;
            },
            updateChecker: (_) =>
                ++checks == 1 ? oldRelease.future : Future.value(null)));
    await tester.tap(find.text('Check for updates'));
    await tester.pump();
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    await tester.pump();
    await tester.tap(find.text('Check for updates'));
    await tester.pump();
    await tester.pump();
    expect(checks, 2);
    expect(reads, 1);
    oldRelease.complete(_release);
    initialMetadata.complete(_fixture);
    await tester.pumpAndSettle();
    expect(find.text('Update available'), findsNothing);
    expect(find.text('NikoDesk 9.8.7+42'), findsNWidgets(2));
    final button = find.widgetWithText(OutlinedButton, 'Check for updates');
    expect(tester.widget<OutlinedButton>(button).onPressed, isNotNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(ProductBuildInfo.loadTimeout);
  });
}
