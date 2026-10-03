import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/nikodesk/session_quick_actions_view.dart';
import 'package:flutter_hbb/nikodesk/session_shortcuts.dart';
import 'package:flutter_hbb/nikodesk/theme.dart';
import 'package:flutter_hbb/nikodesk/ui.dart';

class _RecordingInput implements NikoShortcutInput {
  final events = <String>[];
  bool failPress = false;
  bool failRelease = false;
  Completer<void>? pending;
  VoidCallback? onCaptureReleased;

  @override
  void releaseCapture() {
    events.add('release capture');
    onCaptureReleased?.call();
  }

  @override
  void setModifiers(NikoShortcutKeys? keys) =>
      events.add(keys == null ? 'clear modifiers' : keys.label);

  @override
  Future<void> inputKey(String key, {required bool press}) async {
    events.add('${press ? 'press' : 'release'} $key');
    if (press && pending != null) await pending!.future;
    if (press && failPress) throw StateError('Submission failed');
    if (!press && failRelease) throw StateError('Cleanup failed');
  }
}

void main() {
  tearDown(() => NikoLanguage.english = false);

  // Only action dispatch fixtures are used; no FFI session or OS input starts.
  for (final platform in ['Windows', 'Linux', 'Mac OS']) {
    test('shortcuts use the remote $platform modifier and native key names',
        () {
      for (final shortcut in NikoSessionShortcut.values) {
        final keys = nikoShortcutKeys(shortcut, platform)!;
        if (shortcut == NikoSessionShortcut.switchApp) {
          expect(keys.key, 'VK_TAB');
          expect(keys.command, platform == 'Mac OS');
          expect(keys.alt, platform != 'Mac OS');
          expect(keys.control, isFalse);
        } else {
          expect(
              keys.key,
              {
                NikoSessionShortcut.copy: 'VK_C',
                NikoSessionShortcut.paste: 'VK_V',
                NikoSessionShortcut.selectAll: 'VK_A',
                NikoSessionShortcut.undo: 'VK_Z',
                NikoSessionShortcut.save: 'VK_S',
              }[shortcut]);
          expect(keys.command, platform == 'Mac OS');
          expect(keys.control, platform != 'Mac OS');
          expect(keys.alt, isFalse);
        }
      }
    });
  }

  test('unsupported remote platforms cannot produce a desktop shortcut', () {
    for (final platform in ['', 'Android', 'unknown']) {
      for (final shortcut in NikoSessionShortcut.values) {
        expect(nikoShortcutKeys(shortcut, platform), isNull);
      }
    }
  });

  test('denied or obsolete session cannot send any shortcut', () async {
    final input = _RecordingInput();
    await expectLater(
        sendNikoShortcut(const NikoShortcutKeys('VK_C', control: true), input,
            allowed: () => false),
        throwsStateError);
    expect(input.events, isEmpty);
  });

  test('permission is checked again after held keys are released', () async {
    var allowed = true;
    final input = _RecordingInput()..onCaptureReleased = () => allowed = false;
    await expectLater(
        sendNikoShortcut(const NikoShortcutKeys('VK_C', control: true), input,
            allowed: () => allowed),
        throwsStateError);
    expect(input.events, ['release capture']);
  });

  for (final failure in [false, true]) {
    test(
        'key and modifiers are released after ${failure ? 'failed' : 'successful'} submission',
        () async {
      final input = _RecordingInput()..failPress = failure;
      final action = sendNikoShortcut(
          const NikoShortcutKeys('VK_TAB', command: true), input,
          allowed: () => true);
      if (failure) {
        await expectLater(action, throwsStateError);
      } else {
        await action;
      }
      expect(input.events, [
        'release capture',
        'Cmd+Tab',
        'press VK_TAB',
        'clear modifiers',
        'release VK_TAB',
      ]);
    });
  }

  test('disconnect during pending submission still releases the original key',
      () async {
    var allowed = true;
    final input = _RecordingInput()..pending = Completer<void>();
    final action = sendNikoShortcut(
        const NikoShortcutKeys('VK_V', control: true), input,
        allowed: () => allowed);
    final result = expectLater(action, throwsStateError);
    await Future<void>.delayed(Duration.zero);
    expect(input.events.last, 'press VK_V');
    allowed = false;
    input.pending!.complete();
    await result;
    expect(input.events.sublist(input.events.length - 2),
        ['clear modifiers', 'release VK_V']);
  });

  test('cleanup failure is reported after local modifiers are cleared',
      () async {
    final input = _RecordingInput()..failRelease = true;
    await expectLater(
        sendNikoShortcut(const NikoShortcutKeys('VK_C', control: true), input,
            allowed: () => true),
        throwsStateError);
    expect(input.events.sublist(input.events.length - 2),
        ['clear modifiers', 'release VK_C']);
  });

  Widget panel(
          {bool keyboardAllowed = true,
          bool canvasAllowed = true,
          String peerPlatform = 'Windows',
          String? viewStyle,
          Future<void> Function(NikoSessionShortcut)? shortcut,
          Future<void> Function(String)? view,
          VoidCallback? reset,
          VoidCallback? close}) =>
      NikoSessionQuickActionsPanel(
        peerPlatform: peerPlatform,
        keyboardAllowed: keyboardAllowed,
        canvasAllowed: canvasAllowed,
        viewStyle: viewStyle,
        onShortcut: shortcut ?? (_) async {},
        onViewStyle: view ?? (_) async {},
        onResetCanvas: reset,
        onClose: close ?? () {},
      );

  testWidgets('view-only session keeps local display actions available',
      (tester) async {
    var styles = <String>[];
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: panel(
                keyboardAllowed: false,
                view: (style) async => styles.add(style)))));
    expect(
        tester
            .widget<OutlinedButton>(
                find.byKey(const ValueKey('nikodesk-shortcut-copy')))
            .onPressed,
        isNull);
    final fit = find.byKey(const ValueKey('nikodesk-view-adaptive'));
    expect(tester.widget<OutlinedButton>(fit).onPressed, isNotNull);
    await tester.tap(fit);
    await tester.pumpAndSettle();
    expect(styles, ['adaptive']);
    expect(find.text('画面缩放已更新，并按设备保存。'), findsOneWidget);
  });

  testWidgets('pending action blocks duplicate shortcuts and view changes',
      (tester) async {
    var submissions = 0;
    final pending = Completer<void>();
    await tester
        .pumpWidget(MaterialApp(home: Scaffold(body: panel(shortcut: (_) async {
      submissions++;
      await pending.future;
    }))));
    final copy = find.byKey(const ValueKey('nikodesk-shortcut-copy'));
    await tester.tap(copy);
    await tester.pump();
    expect(submissions, 1);
    expect(tester.widget<OutlinedButton>(copy).onPressed, isNull);
    expect(
        tester
            .widget<OutlinedButton>(
                find.byKey(const ValueKey('nikodesk-view-original')))
            .onPressed,
        isNull);
    pending.complete();
    await tester.pumpAndSettle();
    expect(tester.widget<OutlinedButton>(copy).onPressed, isNotNull);
    expect(find.text('已发送快捷键，执行结果请查看远端画面。'), findsOneWidget);
  });

  testWidgets('submission failure shows feedback without claiming success',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: panel(
                shortcut: (_) async =>
                    throw StateError('private native detail')))));
    await tester.tap(find.byKey(const ValueKey('nikodesk-shortcut-paste')));
    await tester.pumpAndSettle();
    expect(find.text('快捷键未确认发送，请检查会话和远端输入权限后重试。'), findsOneWidget);
    expect(find.textContaining('private native'), findsNothing);
    expect(find.text('已发送快捷键，执行结果请查看远端画面。'), findsNothing);
  });

  testWidgets(
      'unsupported remote exposes local canvas and explains input limit',
      (tester) async {
    NikoLanguage.english = true;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: panel(peerPlatform: 'Android', canvasAllowed: false))));
    expect(find.byKey(const ValueKey('nikodesk-shortcut-copy')), findsNothing);
    expect(
        find.text(
            'These desktop shortcuts are unavailable on this remote system.'),
        findsOneWidget);
    expect(
        tester
            .widget<OutlinedButton>(
                find.byKey(const ValueKey('nikodesk-view-adaptive')))
            .onPressed,
        isNull);
    expect(find.text('Remote video or display dimensions are not ready.'),
        findsOneWidget);
  });

  testWidgets('permission change disables already open shortcut actions',
      (tester) async {
    var allowed = true;
    late StateSetter change;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: StatefulBuilder(builder: (context, setState) {
      change = setState;
      return panel(keyboardAllowed: allowed);
    }))));
    final copy = find.byKey(const ValueKey('nikodesk-shortcut-copy'));
    expect(tester.widget<OutlinedButton>(copy).onPressed, isNotNull);
    change(() => allowed = false);
    await tester.pump();
    expect(tester.widget<OutlinedButton>(copy).onPressed, isNull);
  });

  for (final english in [false, true]) {
    for (final brightness in Brightness.values) {
      testWidgets('quick actions fit 320px at 200% text ($english/$brightness)',
          (tester) async {
        NikoLanguage.english = english;
        await tester.binding.setSurfaceSize(const Size(320, 640));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        var resets = 0;
        var closes = 0;
        await tester.pumpWidget(MaterialApp(
          theme: nikoTheme(brightness),
          builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(2)),
              child: child!),
          home: Scaffold(
              body: Padding(
                  padding: const EdgeInsets.all(24),
                  child: panel(
                      peerPlatform: 'Mac OS',
                      viewStyle: 'original',
                      reset: () => resets++,
                      close: () => closes++))),
        ));
        await tester.pumpAndSettle();
        final reset = find.byKey(const Key('nikodesk-reset-canvas'));
        await tester.ensureVisible(reset);
        await tester.tap(reset);
        await tester.pumpAndSettle();
        expect(resets, 1);
        final close = find.text(english ? 'Close' : '关闭');
        await tester.ensureVisible(close);
        await tester.tap(close);
        expect(closes, 1);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
