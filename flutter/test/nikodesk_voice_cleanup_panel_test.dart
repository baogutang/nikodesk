import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/nikodesk/theme.dart';
import 'package:flutter_hbb/nikodesk/ui.dart';
import 'package:flutter_hbb/nikodesk/voice_cleanup_model.dart';
import 'package:flutter_hbb/nikodesk/voice_cleanup_panel.dart';
import 'package:flutter_test/flutter_test.dart';

import 'nikodesk_voice_cleanup_model_test.dart'
    show cleanupEntry, cleanupList, cleanupQueued;

Future<void> _host(WidgetTester tester, Widget widget,
    {bool english = false, bool dark = false}) async {
  NikoLanguage.english = english;
  tester.view.physicalSize = const Size(320, 700);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(
      theme: nikoTheme(dark ? Brightness.dark : Brightness.light),
      builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(2)),
          child: child!),
      home: Scaffold(body: SingleChildScrollView(child: widget))));
}

void main() {
  tearDown(() => NikoLanguage.english = false);
  for (final english in [false, true]) {
    for (final dark in [false, true]) {
      testWidgets(
          'cleanup 320/200% en=$english dark=$dark has no grant controls',
          (tester) async {
        final commands = <String>[];
        final model = NikoVoiceCleanupModel(
            readPending: () async => cleanupList([
                  cleanupEntry(),
                  cleanupEntry(namespace: 'b', joinState: 'failed')
                ]),
            command: (_, json) async {
              commands.add(json);
              return cleanupQueued(json);
            });
        addTearDown(model.dispose);
        await model.refresh();
        await _host(tester, NikoVoiceCleanupPanel(model: model),
            english: english, dark: dark);
        expect(
            find.text(english
                ? 'Confirming voice cleanup. Resource release is unconfirmed.'
                : '正在确认语音清理，资源释放尚未确认。'),
            findsOneWidget);
        expect(
            find.text(english
                ? 'Voice cleanup failed. Resource release is unconfirmed.'
                : '语音清理失败，资源释放尚未确认。'),
            findsOneWidget);
        final retry = find
            .byKey(ValueKey('voice-cleanup-retry-${model.pending.first.key}'));
        await tester.ensureVisible(retry);
        expect(tester.getSize(retry).height, greaterThanOrEqualTo(48));
        await tester.tap(retry);
        await tester.pumpAndSettle();
        expect(commands.single, contains('"op":"retry_cleanup"'));
        expect(model.pending.length, 2);
        expect(find.byType(CheckboxListTile), findsNothing);
        expect(find.byType(DropdownButtonFormField<String>), findsNothing);
        expect(find.textContaining('已确认停止'), findsNothing);
        expect(find.textContaining('confirmed stopped'), findsNothing);
        expect(tester.takeException(), isNull);
      });
    }
  }
  testWidgets('opening, rebuilding and dismissing panel do not issue commands',
      (tester) async {
    var reads = 0, commands = 0;
    var raw = cleanupList();
    final model = NikoVoiceCleanupModel(readPending: () async {
      reads++;
      return raw;
    }, command: (_, __) async {
      commands++;
      return '{}';
    });
    addTearDown(model.dispose);
    final entry = NikoVoiceCleanupEntryPoint(model: model);
    await _host(tester, entry);
    await tester.pumpAndSettle();
    expect(reads, 1);
    expect(commands, 0);
    await tester.tap(find.byKey(const Key('nikodesk-voice-cleanup-open')));
    await tester.pumpAndSettle();
    expect(find.byType(NikoVoiceCleanupPanel), findsOneWidget);
    expect(commands, 0);
    await tester.ensureVisible(find.text('关闭面板'));
    await tester.tap(find.text('关闭面板'));
    await tester.pumpAndSettle();
    await _host(tester, entry);
    expect(model.pending.length, 1);
    raw = cleanupList([]);
    await model.refresh();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('nikodesk-voice-cleanup-open')), findsNothing);
    expect(commands, 0);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
      'retained read failures provide visible refresh and original rows',
      (tester) async {
    var raw = cleanupList();
    final model = NikoVoiceCleanupModel(
        readPending: () async => raw, command: (_, __) async => '{}');
    addTearDown(model.dispose);
    await model.refresh();
    raw = '{"ok":false,"pending":[],"reason":"raw_backend_error"}';
    await model.refresh();
    await _host(tester, NikoVoiceCleanupPanel(model: model));
    expect(find.textContaining('保留上次记录'), findsOneWidget);
    expect(find.textContaining('raw_backend'), findsNothing);
    final refresh = find.byKey(const Key('nikodesk-voice-cleanup-refresh'));
    await tester.ensureVisible(refresh);
    await tester.tap(refresh);
    await tester.pumpAndSettle();
    expect(model.pending.length, 1);
    expect(tester.widget<OutlinedButton>(refresh).onPressed, isNotNull);
    expect(tester.takeException(), isNull);
  });
  testWidgets('keyboard cleanup action exposes real button semantics',
      (tester) async {
    var commands = 0;
    final model = NikoVoiceCleanupModel(
        readPending: () async => cleanupList(),
        command: (_, json) async {
          commands++;
          return cleanupQueued(json);
        });
    addTearDown(model.dispose);
    final semantics = tester.ensureSemantics();
    await model.refresh();
    await _host(tester, NikoVoiceCleanupPanel(model: model), english: true);
    final button = find.text('Retry cleanup');
    await tester.ensureVisible(button);
    Focus.of(tester.element(button)).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(commands, 1);
    expect(
        tester.getSemantics(button),
        matchesSemantics(
            label: 'Retry cleanup',
            isButton: true,
            hasEnabledState: true,
            isEnabled: true,
            isFocusable: true,
            isFocused: true,
            hasTapAction: true,
            hasFocusAction: true));
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });
  testWidgets('entry poll pauses in background, resumes and stops on dispose',
      (tester) async {
    var reads = 0;
    final model = NikoVoiceCleanupModel(
        readPending: () async {
          reads++;
          return cleanupList([]);
        },
        command: (_, __) async => '{}');
    addTearDown(model.dispose);
    await _host(
        tester,
        NikoVoiceCleanupEntryPoint(
            model: model, pollInterval: const Duration(seconds: 1)));
    await tester.pump();
    expect(reads, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump(const Duration(seconds: 2));
    expect(reads, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(reads, 2);
    await tester.pump(const Duration(seconds: 1));
    expect(reads, 3);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
    expect(reads, 3);
    expect(model.visible, false);
  });
  testWidgets('hung read is bounded and opens an actionable unconfirmed entry',
      (tester) async {
    final model = NikoVoiceCleanupModel(
        timeout: const Duration(seconds: 1),
        readPending: () => Completer<String>().future,
        command: (_, __) async => '{}');
    addTearDown(model.dispose);
    await _host(
        tester,
        NikoVoiceCleanupEntryPoint(
            model: model, pollInterval: const Duration(seconds: 10)));
    await tester.pump(const Duration(seconds: 1));
    expect(model.reading, false);
    expect(model.readUnconfirmed, true);
    expect(
        find.byKey(const Key('nikodesk-voice-cleanup-open')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
