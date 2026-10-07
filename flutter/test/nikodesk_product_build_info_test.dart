import 'package:flutter/material.dart';
import 'package:flutter_hbb/nikodesk/home_settings.dart';
import 'package:flutter_hbb/nikodesk/product_build_info.dart';
import 'package:flutter_hbb/nikodesk/theme.dart';
import 'package:flutter_hbb/nikodesk/ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';

// Deliberately arbitrary fixtures, not assertions about a current native build.
const _fixture = ProductBuildInfo(
    version: '9.8.7', buildNumber: '42', nativeVersion: '0.9.0');

void main() {
  test('only the known preview build gets a manual stable transition', () {
    const preview = ProductBuildInfo(version: '1.1.0', buildNumber: '9');
    expect(preview.canMigrateLegacyPreviewTo('v1.0.7'), isTrue);
    expect(preview.relationTo('v1.0.7'), PublishedVersionRelation.localAhead);
    expect(preview.canMigrateLegacyPreviewTo('v1.0.6'), isFalse);
    expect(preview.canMigrateLegacyPreviewTo('nightly'), isFalse);
    expect(const ProductBuildInfo(version: '1.1.0', buildNumber: '10')
        .canMigrateLegacyPreviewTo('v1.0.7'), isFalse);
    expect(const ProductBuildInfo(version: '1.1.0')
        .canMigrateLegacyPreviewTo('v1.0.7'), isFalse);
  });

  setUp(() => NikoLanguage.english = true);

  test('reads package version/build independently from native protocol',
      () async {
    final value = await ProductBuildInfo.read(
        packageLoader: () async => PackageInfo(
            appName: 'NikoDesk',
            packageName: 'fixture.example',
            version: _fixture.version!,
            buildNumber: _fixture.buildNumber!),
        nativeVersionLoader: () async => _fixture.nativeVersion!);
    expect(value.fullVersion, '9.8.7+42');
    expect(value.nativeVersion, '0.9.0');
  });

  test('failed package read never substitutes the native protocol version',
      () async {
    final value = await ProductBuildInfo.read(
        packageLoader: () async => throw StateError('fixture failure'),
        nativeVersionLoader: () async => '0.9.0');
    expect(value.version, isNull);
    expect(value.buildNumber, isNull);
    expect(value.fullVersion, contains('Unknown'));
    expect(value.fullVersion, isNot(contains('0.9.0')));
    expect(value.nativeVersion, '0.9.0');
  });

  test('failed native read preserves real package metadata', () async {
    final value = await ProductBuildInfo.read(
        packageLoader: () async => PackageInfo(
            appName: 'NikoDesk',
            packageName: 'fixture.example',
            version: '9.8.7',
            buildNumber: '42'),
        nativeVersionLoader: () async => throw StateError('fixture failure'));
    expect(value.fullVersion, '9.8.7+42');
    expect(value.nativeVersion, isNull);
  });

  test('malformed package metadata stays unknown', () async {
    final value = await ProductBuildInfo.read(
        packageLoader: () async => PackageInfo(
            appName: 'NikoDesk',
            packageName: 'fixture.example',
            version: '',
            buildNumber: 'invalid'),
        nativeVersionLoader: () async => '');
    expect(value.version, isNull);
    expect(value.buildNumber, isNull);
    expect(value.nativeVersion, isNull);
    expect(value.relationTo('v9.8.7'), PublishedVersionRelation.unknown);
  });

  test('a missing build number is not silently omitted', () {
    const value = ProductBuildInfo(version: '9.8.7');
    expect(value.fullVersion, '9.8.7 (build unknown)');
  });

  test('local ahead reports both current full version and published latest',
      () {
    expect(_fixture.relationTo('v9.8.6'), PublishedVersionRelation.localAhead);
    final message = _fixture.updateStatus('v9.8.6');
    expect(message, contains('Installed: 9.8.7+42'));
    expect(message, contains('latest published: v9.8.6'));
    expect(message, contains('ahead'));
    expect(message, isNot(contains('Up to date')));
  });

  test('equal version does not claim build/publication identity', () {
    expect(_fixture.relationTo('v9.8.7'), PublishedVersionRelation.sameVersion);
    expect(_fixture.updateStatus('v9.8.7'),
        contains('does not confirm the build number or publication status'));
  });

  test('comparison is numeric and does not compare build to release tag', () {
    expect(
        _fixture.relationTo('v9.10.0'), PublishedVersionRelation.newerRelease);
    expect(
        _fixture.relationTo('v10.0.0'), PublishedVersionRelation.newerRelease);
    expect(
        _fixture.relationTo('v9.8.7-rc.1'), PublishedVersionRelation.unknown);
    expect(_fixture.relationTo('garbage'), PublishedVersionRelation.unknown);
  });

  for (final english in [false, true]) {
    for (final brightness in [Brightness.light, Brightness.dark]) {
      testWidgets('about card fits 320px/200% $english $brightness',
          (tester) async {
        NikoLanguage.english = english;
        await tester.binding.setSurfaceSize(const Size(320, 700));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(MaterialApp(
            theme: nikoTheme(brightness),
            builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: const TextScaler.linear(2)),
                child: child!),
            home: Scaffold(
                body: SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: NikoProductAbout(loadInfo: () async => _fixture)))));
        await tester.pumpAndSettle();
        expect(find.text('NikoDesk 9.8.7+42'), findsOneWidget);
        expect(find.text('RustDesk 0.9.0'), findsOneWidget);
        expect(find.textContaining('AGPL-3.0'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });
    }
  }

  testWidgets('about read failure visibly stays unknown', (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: NikoProductAbout(
                loadInfo: () async => throw StateError('fixture failure')))));
    await tester.pumpAndSettle();
    expect(find.text('NikoDesk Unknown (build unknown)'), findsOneWidget);
    expect(find.text('RustDesk Unknown'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('settings uses the same explicit product/core metadata',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1100, 1800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
        theme: nikoTheme(Brightness.light),
        home: Scaffold(
            body: NikoSettingsView(
                native: false, buildInfoLoader: () async => _fixture))));
    await tester.pumpAndSettle();
    expect(find.text('NikoDesk 9.8.7+42'), findsNWidgets(2));
    expect(find.text('RustDesk 0.9.0'), findsOneWidget);
    expect(find.text('RustDesk 1.5.0 · AGPL v3'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
