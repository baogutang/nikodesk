import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/nikodesk/home_settings.dart';
import 'package:flutter_hbb/nikodesk/product_build_info.dart';
import 'package:flutter_hbb/nikodesk/theme.dart';
import 'package:flutter_hbb/nikodesk/ui.dart';
import 'package:flutter_hbb/nikodesk/update_publisher.dart';
import 'package:flutter_hbb/nikodesk/updater.dart';
import 'package:flutter_test/flutter_test.dart';

class _Publisher extends NikoUpdatePublisher {
  const _Publisher();
  @override
  bool get configured => true;
}

// Only the handoff boundary is injected. Native updater verification remains
// covered by nikodesk_updater_test.dart; no application or Finder is launched.
class _Updater extends NikoUpdater {
  _Updater({bool signed = true})
      : super(
            publisher:
                signed ? const _Publisher() : const NikoUpdatePublisher());
  int stages = 0;
  int reveals = 0;
  bool accept = true;
  bool revealFails = false;
  bool recheckFails = false;
  Directory? staging;
  Completer<void>? holdVerification;

  @override
  Future<bool> verifyAndStageMacUpdate(
      NikoReleaseInfo release, NikoReleaseAsset asset, Directory staging,
      {void Function(int, int)? onProgress,
      void Function(NikoUpdatePhase)? onPhase,
      NikoUpdateCancellation? cancellation}) async {
    stages++;
    this.staging = staging;
    onPhase?.call(NikoUpdatePhase.downloading);
    onProgress?.call(100, 100);
    onPhase?.call(NikoUpdatePhase.verifying);
    await holdVerification?.future;
    cancellation?.check();
    onPhase?.call(NikoUpdatePhase.unpacking);
    await File('${staging.path}/synthetic-package.txt')
        .writeAsString('fixture');
    return accept;
  }

  @override
  Future<void> revealStagedMacUpdate(Directory staging,
      {NikoUpdateCancellation? cancellation}) async {
    cancellation?.check();
    reveals++;
    if (recheckFails) throw const FormatException('invalid staged bundle');
    if (revealFails) {
      throw const FileSystemException('synthetic Finder failure');
    }
  }
}

void main() {
  final release = NikoReleaseInfo(tag: 'v1.0.6', notes: '', assets: [
    NikoReleaseAsset(
        'NikoDesk-macos-arm64.zip',
        Uri.parse(
            'https://github.com/baogutang/nikodesk/releases/download/v1.0.6/NikoDesk-macos-arm64.zip')),
  ]);

  setUp(() => NikoLanguage.english = true);

  Future<void> settings(WidgetTester tester, _Updater updater,
      {Future<bool> Function(Uri)? open}) async {
    await tester.binding.setSurfaceSize(const Size(1200, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() async {
      final staging = updater.staging;
      if (staging != null && await staging.exists()) {
        await staging.delete(recursive: true);
      }
    });
    await tester.pumpWidget(MaterialApp(
        theme: nikoTheme(Brightness.light),
        home: Scaffold(
            body: NikoSettingsView(
                native: false,
                updater: updater,
                openUpdateUrl: open,
                buildInfoLoader: () async => const ProductBuildInfo(
                    version: '1.0.5',
                    buildNumber: '14',
                    nativeVersion: '1.5.0'),
                updateChecker: (_) async => release))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Check for updates'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<void> waitFor(
      WidgetTester tester, FutureOr<bool> Function() done) async {
    // The settings page owns a real, synthetic temp directory. Let its I/O
    // finish without using physical application paths or a native process.
    for (var i = 0; i < 100; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)));
      await tester.pump();
      if (await tester.runAsync(() async => await done()) == true) return;
    }
    expect(await tester.runAsync(() async => await done()), isTrue);
  }

  String status(WidgetTester tester) => tester
      .widget<Text>(find.byKey(const Key('nikodesk-update-status')))
      .data!;

  testWidgets(
      'browser refusal remains visible with the checked release URL and retry',
      (tester) async {
    final updater = _Updater(signed: false);
    var opened = false;
    final urls = <Uri>[];
    await settings(tester, updater, open: (uri) async {
      urls.add(uri);
      return opened;
    });
    await tester.tap(find.text('Download'));
    await tester.pumpAndSettle();
    expect(status(tester), startsWith('Could not open the release page.'));
    await tester.pump(const Duration(seconds: 8));
    expect(status(tester), startsWith('Could not open the release page.'));
    expect(
        find.byKey(const Key('nikodesk-update-release-url')), findsOneWidget);
    expect(urls.single.path, '/baogutang/nikodesk/releases/tag/v1.0.6');
    opened = true;
    await tester.tap(find.text('Open release page'));
    await tester.pumpAndSettle();
    expect(
        status(tester),
        startsWith(
            'Release page opened; nothing has been downloaded or installed'));
    expect(
        find.byWidgetPredicate(
            (widget) => widget is Text && widget.data == 'NikoDesk 1.0.5+14'),
        findsOneWidget);
    expect(updater.stages, 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'browser exception has a retryable result rather than a silent exit',
      (tester) async {
    await settings(tester, _Updater(signed: false),
        open: (_) async => throw StateError('fixture'));
    await tester.tap(find.text('Download'));
    await tester.pumpAndSettle();
    expect(status(tester), startsWith('Could not open the release page.'));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'verified handoff retains manual installation and restart steps beyond a snackbar',
      (tester) async {
    final updater = _Updater();
    await settings(tester, updater);
    await tester.tap(find.text('Download and verify'));
    await tester.pump();
    await waitFor(tester, () => updater.reveals == 1);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 8));
    expect(
        status(tester),
        startsWith(
            'Installer shown in Finder; the app has not been installed or restarted.'));
    expect(
        find.textContaining(
            'copy the prepared NikoDesk.app to its original installation location'),
        findsOneWidget);
    expect(
        find.textContaining(
            'Reopen NikoDesk from that location and check the version'),
        findsOneWidget);
    expect(
        find.textContaining(
            'Keep the file location before closing this page'),
        findsOneWidget);
    expect(
        find.byKey(const Key('nikodesk-update-staged-path')), findsOneWidget);
    expect(
        find.byWidgetPredicate(
            (widget) => widget is Text && widget.data == 'NikoDesk 1.0.5+14'),
        findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  }, skip: !Platform.isMacOS);

  testWidgets(
      'opening release notes after staging does not deny the completed download',
      (tester) async {
    final updater = _Updater();
    await settings(tester, updater, open: (_) async => true);
    await tester.tap(find.text('Download and verify'));
    await tester.pump();
    await waitFor(tester, () => updater.reveals == 1);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open release page'));
    await tester.pumpAndSettle();
    expect(status(tester), contains('Previously prepared files remain listed'));
    expect(status(tester), isNot(contains('nothing has been downloaded')));
    expect(find.byKey(const Key('nikodesk-update-staged-path')), findsOneWidget);
    expect(updater.stages, 1);
    await tester.pumpWidget(const SizedBox());
  }, skip: !Platform.isMacOS);

  testWidgets(
      'failed recheck retains files but withdraws installation steps until retry succeeds',
      (tester) async {
    final updater = _Updater();
    await settings(tester, updater);
    await tester.tap(find.text('Download and verify'));
    await tester.pump();
    await waitFor(tester, () => updater.reveals == 1);
    await tester.pumpAndSettle();
    expect(find.textContaining('copy the prepared NikoDesk.app'), findsOneWidget);
    updater.recheckFails = true;
    await tester.tap(find.text('Show installer in Finder'));
    await tester.pumpAndSettle();
    expect(status(tester), startsWith('Installer recheck failed:'));
    expect(find.textContaining('copy the prepared NikoDesk.app'), findsNothing);
    expect(find.textContaining('installer checked;'), findsNothing);
    expect(find.textContaining('files retained; recheck before installation'), findsOneWidget);
    expect(await tester.runAsync(() =>
        File('${updater.staging!.path}/synthetic-package.txt').exists()), isTrue);
    updater.recheckFails = false;
    await tester.tap(find.text('Show installer in Finder'));
    await tester.pumpAndSettle();
    expect(find.textContaining('copy the prepared NikoDesk.app'), findsOneWidget);
    expect(updater.stages, 1);
    expect(updater.reveals, 3);
    await tester.pumpWidget(const SizedBox());
  }, skip: !Platform.isMacOS);

  testWidgets(
      'Finder failure preserves verified files and retries without downloading again',
      (tester) async {
    final updater = _Updater()..revealFails = true;
    await settings(tester, updater);
    await tester.tap(find.text('Download and verify'));
    await tester.pump();
    await waitFor(tester, () => updater.reveals == 1);
    await tester.pumpAndSettle();
    expect(status(tester),
        startsWith('Could not show or recheck the installer in Finder.'));
    expect(find.textContaining('copy the prepared NikoDesk.app'), findsNothing);
    expect(find.textContaining('installer checked;'), findsNothing);
    expect(
        await tester.runAsync(() =>
            File('${updater.staging!.path}/synthetic-package.txt').exists()),
        isTrue);
    updater.revealFails = false;
    await tester.tap(find.text('Show installer in Finder'));
    await tester.pumpAndSettle();
    expect(updater.reveals, 2);
    expect(updater.stages, 1);
    expect(status(tester), startsWith('Installer shown in Finder;'));
    await tester.pumpWidget(const SizedBox());
  }, skip: !Platform.isMacOS);

  testWidgets(
      'verification refusal exposes failure and never offers a staged installer',
      (tester) async {
    final updater = _Updater()..accept = false;
    await settings(tester, updater);
    await tester.tap(find.text('Download and verify'));
    await tester.pump();
    await waitFor(tester, () => updater.stages == 1);
    await waitFor(tester, () async => !await updater.staging!.exists());
    await tester.pumpAndSettle();
    expect(status(tester), startsWith('Update verification failed.'));
    expect(updater.reveals, 0);
    expect(find.text('Show installer in Finder'), findsNothing);
    expect(await tester.runAsync(() => updater.staging!.exists()), isFalse);
    await tester.pumpWidget(const SizedBox());
  }, skip: !Platform.isMacOS);

  testWidgets(
      '100 percent download still shows verification and cancellation does not offer installation',
      (tester) async {
    final pending = Completer<void>();
    final updater = _Updater()..holdVerification = pending;
    await settings(tester, updater);
    await tester.tap(find.text('Download and verify'));
    await tester.pump();
    await waitFor(tester, () => updater.stages == 1);
    expect(
        status(tester), startsWith('Download complete. Verifying publisher'));
    expect(find.text('Show installer in Finder'), findsNothing);
    await tester.tap(find.text('Cancel'));
    pending.complete();
    await tester.pump();
    await waitFor(tester, () async => !await updater.staging!.exists());
    await tester.pumpAndSettle();
    expect(status(tester), 'Update cancelled.');
    expect(updater.reveals, 0);
    expect(find.text('Show installer in Finder'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  }, skip: !Platform.isMacOS);
}
