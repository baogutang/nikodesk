import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_hbb/nikodesk/privacy_style.dart';
import 'package:flutter_hbb/nikodesk/privacy_style_events.dart';
import 'package:flutter_hbb/nikodesk/privacy_style_image.dart';
import 'package:flutter_hbb/nikodesk/privacy_style_model.dart';
import 'package:flutter_hbb/nikodesk/privacy_wallpaper.dart';
import 'package:flutter_hbb/nikodesk/ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => NikoLanguage.english = true);
  tearDown(() => NikoLanguage.english = false);

  test('only the three selected presets and custom are saved', () {
    expect(NikoPrivacyPreset.values.map((value) => value.name),
        ['snow', 'paper', 'rain', 'custom']);
    for (final preset in NikoPrivacyPreset.values.take(3)) {
      final style = NikoPrivacyStyle(
          preset: preset, effect: NikoPrivacyStyle.effectFor(preset));
      expect(style.valid, isTrue);
      expect(NikoPrivacyStyle.read(style.saved())!.preset, preset);
    }
    final input =
        jsonDecode(const NikoPrivacyStyle().saved()) as Map<String, dynamic>;
    for (final removed in ['black', 'ocean', '../file', 'https://image']) {
      input['preset'] = removed;
      expect(NikoPrivacyStyle.read(jsonEncode(input)), isNull);
    }
  });
  test('bad options and missing or oversized custom images are rejected', () {
    for (final style in [
      const NikoPrivacyStyle(brightness: 39),
      const NikoPrivacyStyle(intensity: 201),
      const NikoPrivacyStyle(preset: NikoPrivacyPreset.paper),
      const NikoPrivacyStyle(preset: NikoPrivacyPreset.custom),
      NikoPrivacyStyle(
          preset: NikoPrivacyPreset.custom,
          image: Uint8List(nikoPrivacyImageLimit + 1)),
    ]) {
      expect(style.valid, isFalse);
    }
    final custom = NikoPrivacyStyle(
        preset: NikoPrivacyPreset.custom,
        effect: NikoPrivacyEffect.rain,
        image: Uint8List.fromList([1, 2, 3]));
    expect(NikoPrivacyStyle.read(custom.saved())!.image, [1, 2, 3]);
    expect(
        custom
            .copyWith(
                preset: NikoPrivacyPreset.snow, effect: NikoPrivacyEffect.fog)
            .command(7)['image_base64'],
        '');
  });

  test('stale, malformed and other-session replies cannot confirm a request',
      () async {
    final id = NikoPrivacyStyleReplies.nextId();
    var completed = false;
    final reply = NikoPrivacyStyleReplies.wait('current', id)
        .then((_) => completed = true);
    final applied =
        jsonEncode({'request_id': id, 'applied': true, 'active': true});
    NikoPrivacyStyleReplies.handle('old-session', applied);
    NikoPrivacyStyleReplies.handle('current', '{bad');
    NikoPrivacyStyleReplies.handle(
        'current', jsonEncode({'request_id': id, 'applied': true}));
    await Future<void>.delayed(Duration.zero);
    expect(completed, isFalse);
    NikoPrivacyStyleReplies.handle('current', applied);
    await reply;
    expect(completed, isTrue);
  });
  test('a failed update on an active screen reports failure', () async {
    final id = NikoPrivacyStyleReplies.nextId();
    final expected = expectLater(
        NikoPrivacyStyleReplies.wait('owner', id),
        throwsA(isA<NikoPrivacyStyleError>()
            .having((error) => error.reason, 'reason', 'invalid_image')));
    NikoPrivacyStyleReplies.handle(
        'owner',
        jsonEncode({
          'request_id': id,
          'applied': false,
          'active': true,
          'error': 'invalid_image'
        }));
    await expected;
  });
  test('queued or inactive replies are never treated as application success',
      () async {
    final id = NikoPrivacyStyleReplies.nextId();
    final expected = expectLater(NikoPrivacyStyleReplies.wait('owner', id),
        throwsA(isA<NikoPrivacyStyleError>()));
    NikoPrivacyStyleReplies.handle('owner',
        jsonEncode({'request_id': id, 'applied': true, 'active': false}));
    await expected;
  });

  test('transparent images normalize to opaque bounded JPEG', () async {
    final source = image.Image(width: 2, height: 2, numChannels: 4);
    image.fill(source, color: image.ColorRgba8(255, 0, 0, 0));
    final normalized = await nikoNormalizePrivacyImage(image.encodePng(source));
    final decoded = image.decodeJpg(normalized)!;
    expect(normalized.length, lessThanOrEqualTo(nikoPrivacyImageLimit));
    expect(decoded.numChannels, 3);
    expect(decoded.getPixel(0, 0).r, lessThan(3));
    expect(decoded.getPixel(0, 0).g, lessThan(3));
  });
  test('wrong formats and excessive dimensions fail before import', () async {
    await expectLater(nikoNormalizePrivacyImage(Uint8List.fromList([1, 2, 3])),
        throwsA(isA<NikoPrivacyStyleError>()));
    final wide = image.encodePng(image.Image(width: 4097, height: 1));
    await expectLater(
        nikoNormalizePrivacyImage(wide),
        throwsA(isA<NikoPrivacyStyleError>().having(
            (error) => error.reason, 'reason', 'image_dimensions_limit')));
  });

  Widget editor(Future<void> Function(NikoPrivacyStyle) apply,
          {bool allowed = true}) =>
      MaterialApp(
          home: Scaffold(
              body: SingleChildScrollView(
                  child: SizedBox(
                      width: 400,
                      child: NikoPrivacyStyleEditor(
                          allowed: allowed, active: false, onApply: apply)))));
  testWidgets('selection has four choices and waits for remote confirmation',
      (tester) async {
    final confirmation = Completer<void>();
    NikoPrivacyStyle? requested;
    await tester.pumpWidget(editor((style) {
      requested = style;
      return confirmation.future;
    }));
    for (final preset in NikoPrivacyPreset.values) {
      expect(find.byKey(ValueKey('privacy-preset-${preset.name}')),
          findsOneWidget);
    }
    await tester.tap(find.byKey(const ValueKey('privacy-preset-paper')));
    await tester.pump();
    final button = find.byKey(const Key('privacy-apply-style'));
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pump();
    expect(requested!.preset, NikoPrivacyPreset.paper);
    expect(find.text('Applied'), findsNothing);
    expect(tester.widget<FilledButton>(button).onPressed, isNull);
    confirmation.complete();
    await tester.pump();
    expect(find.text('Applied'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('denied permission and empty custom image disable apply',
      (tester) async {
    await tester.pumpWidget(editor((_) async {}, allowed: false));
    final button = find.byKey(const Key('privacy-apply-style'));
    expect(tester.widget<FilledButton>(button).onPressed, isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(editor((_) async {}));
    await tester.tap(find.byKey(const ValueKey('privacy-preset-custom')));
    await tester.pump();
    expect(find.byKey(const Key('privacy-custom-image')), findsOneWidget);
    expect(tester.widget<FilledButton>(button).onPressed, isNull);
    await tester.pumpWidget(const SizedBox());
  });

  for (final preset in NikoPrivacyPreset.values.take(3)) {
    testWidgets(
        '${preset.name} renders real motion and respects reduced motion',
        (tester) async {
      final key = GlobalKey();
      final style = NikoPrivacyStyle(
          preset: preset,
          effect: NikoPrivacyStyle.effectFor(preset),
          hint: false);
      Widget screen(bool reduced) => MaterialApp(
          home: MediaQuery(
              data: MediaQueryData(disableAnimations: reduced),
              child: Center(
                  child: RepaintBoundary(
                      key: key,
                      child: SizedBox(
                          width: 320,
                          height: 200,
                          child: NikoPrivacyWallpaper(style: style))))));
      await tester.pumpWidget(screen(false));
      await tester.runAsync(() => precacheImage(
          AssetImage(nikoPrivacyAsset(preset)!), key.currentContext!));
      await tester.pump();
      Future<Uint8List> pixels() async {
        final capture = await tester.runAsync(() async {
          final photo = await (key.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary)
              .toImage();
          final data =
              await photo.toByteData(format: ui.ImageByteFormat.rawRgba);
          photo.dispose();
          return data!.buffer.asUint8List();
        });
        return capture!;
      }

      final before = await pixels();
      await tester.pump(const Duration(seconds: 2));
      expect(await pixels(), isNot(equals(before)));
      await tester.pumpWidget(screen(true));
      final frozen = await pixels();
      await tester.pump(const Duration(seconds: 2));
      expect(await pixels(), equals(frozen));
      await tester.pumpWidget(const SizedBox());
    });
  }
}
