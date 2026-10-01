import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/nikodesk/cm_voice_panel.dart';
import 'package:flutter_hbb/nikodesk/theme.dart';
import 'package:flutter_hbb/nikodesk/ui.dart';
import 'package:flutter_hbb/nikodesk/voice_call_panel.dart';
import 'package:flutter_hbb/nikodesk/voice_session_model.dart';
import 'package:flutter_test/flutter_test.dart';

import 'nikodesk_voice_session_model_test.dart'
    show parsedVoiceStatus, parsedVoiceCatalog, voiceQueued;

Widget _host(Widget panel, {double scale = 1, bool dark = false}) =>
    MaterialApp(
        theme: nikoTheme(dark ? Brightness.dark : Brightness.light),
        home: Builder(
            builder: (context) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(scale)),
                child: Scaffold(body: SingleChildScrollView(child: panel)))));

NikoVoiceSessionModel _model(List<NikoVoiceCommand> sent,
    {String phase = 'Pending',
    String permission = 'Authorized',
    bool peerAccepted = false,
    bool muted = false,
    String? label}) {
  final model = NikoVoiceSessionModel(
      anchor: parsedVoiceStatus(
          phase: phase,
          permission: permission,
          peerAccepted: peerAccepted,
          muted: muted),
      availability: NikoVoiceAvailability.enabled,
      transport: (command) async {
        sent.add(command);
        return voiceQueued(command);
      });
  if (phase == 'Pending') {
    model
        .applyCatalog(parsedVoiceCatalog(permission: permission, label: label));
  }
  return model;
}

Future<void> _choose(WidgetTester tester) async {
  for (final direction in ['capture', 'playback']) {
    final device = find.byKey(ValueKey('niko-voice-$direction-device'));
    await tester.ensureVisible(device);
    await tester.tap(device);
    await tester.pumpAndSettle();
    await tester.tap(find
        .text(direction == 'capture' ? 'Test microphone' : 'Test speaker')
        .last);
    await tester.pumpAndSettle();
    final format = find.byKey(ValueKey('niko-voice-$direction-format'));
    await tester.ensureVisible(format);
    await tester.tap(format);
    await tester.pumpAndSettle();
    await tester.tap(find
        .text(direction == 'capture'
            ? '48 kHz · f32 · 单声道'
            : '48 kHz · f32 · 双声道')
        .last);
    await tester.pumpAndSettle();
  }
}

void main() {
  tearDown(() => NikoLanguage.english = false);
  testWidgets(
      'opening a panel never enumerates, requests permission or grants audio',
      (tester) async {
    final sent = <NikoVoiceCommand>[];
    final model = _model(sent);
    await tester.pumpWidget(_host(NikoCmVoicePanel(model: model)));
    await tester.pumpAndSettle();
    expect(sent, isEmpty);
    final approve = tester
        .widget<FilledButton>(find.byKey(const ValueKey('niko-voice-approve')));
    expect(approve.onPressed, isNull);
    await tester
        .ensureVisible(find.byKey(const ValueKey('niko-voice-enumerate')));
    await tester.tap(find.byKey(const ValueKey('niko-voice-enumerate')));
    await tester.pumpAndSettle();
    expect(sent.single.op, 'enumerate');
    expect(find.text('语音请求等待本机批准'), findsOneWidget);
    expect(find.text('语音通话中'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    model.dispose();
  });
  testWidgets(
      'NotDetermined has an explicit permission action and never auto approves',
      (tester) async {
    final sent = <NikoVoiceCommand>[];
    final model = _model(sent, permission: 'NotDetermined');
    await tester.pumpWidget(_host(NikoCmVoicePanel(model: model)));
    expect(sent, isEmpty);
    await tester
        .ensureVisible(find.byKey(const ValueKey('niko-voice-permission')));
    await tester.tap(find.byKey(const ValueKey('niko-voice-permission')));
    await tester.pumpAndSettle();
    expect(sent.single.op, 'request_permission');
    expect(model.status.microphonePermission, 'NotDetermined');
    expect(
        tester
            .widget<FilledButton>(
                find.byKey(const ValueKey('niko-voice-approve')))
            .onPressed,
        isNull);
    await tester.pumpWidget(const SizedBox());
    model.dispose();
  });
  testWidgets(
      'approval requires four explicit choices and confirmation before dispatch',
      (tester) async {
    final sent = <NikoVoiceCommand>[];
    final model = _model(sent);
    await tester.pumpWidget(_host(NikoCmVoicePanel(model: model)));
    await _choose(tester);
    await tester
        .ensureVisible(find.byKey(const ValueKey('niko-voice-approve')));
    await tester.tap(find.byKey(const ValueKey('niko-voice-approve')));
    await tester.pumpAndSettle();
    expect(sent, isEmpty);
    await tester.tap(find.descendant(
        of: find.byType(AlertDialog), matching: find.text('允许此会话')));
    await tester.pumpAndSettle();
    expect(sent.single.op, 'approve');
    expect(sent.single.selection!.captureToken, 'a' * 32);
    expect(sent.single.selection!.playbackToken, 'b' * 32);
    expect(model.status.phase, 'Pending');
    expect(model.status.localReady, false);
    expect(find.text('语音通话中'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    model.dispose();
  });
  testWidgets(
      'a status change while confirmation is open retires captured approval',
      (tester) async {
    final sent = <NikoVoiceCommand>[];
    final model = _model(sent);
    await tester.pumpWidget(_host(NikoCmVoicePanel(model: model)));
    await _choose(tester);
    await tester
        .ensureVisible(find.byKey(const ValueKey('niko-voice-approve')));
    await tester.tap(find.byKey(const ValueKey('niko-voice-approve')));
    await tester.pumpAndSettle();
    model.applyStatus(parsedVoiceStatus(phase: 'Starting', revision: '2'));
    await tester.pump();
    await tester.tap(find.descendant(
        of: find.byType(AlertDialog), matching: find.text('允许此会话')));
    await tester.pumpAndSettle();
    expect(sent, isEmpty);
    await tester.pumpWidget(const SizedBox());
    model.dispose();
  });
  testWidgets(
      'a new roster clears all choices instead of substituting an index or default',
      (tester) async {
    final sent = <NikoVoiceCommand>[];
    final model = _model(sent);
    await tester.pumpWidget(_host(NikoCmVoicePanel(model: model)));
    await _choose(tester);
    expect(
        tester
            .widget<FilledButton>(
                find.byKey(const ValueKey('niko-voice-approve')))
            .onPressed,
        isNotNull);
    model.applyCatalog(parsedVoiceCatalog(roster: '2'));
    await tester.pump();
    expect(
        tester
            .widget<FilledButton>(
                find.byKey(const ValueKey('niko-voice-approve')))
            .onPressed,
        isNull);
    expect(
        tester
            .widget<DropdownButtonFormField<String>>(
                find.byKey(const ValueKey('niko-voice-capture-device')))
            .initialValue,
        isNull);
    expect(sent, isEmpty);
    await tester.pumpWidget(const SizedBox());
    model.dispose();
  });
  testWidgets(
      'end timeout survives panel rebuilding and does not display stopped',
      (tester) async {
    final pending = Completer<String>();
    final model = NikoVoiceSessionModel(
        anchor: parsedVoiceStatus(phase: 'Running'),
        availability: NikoVoiceAvailability.enabled,
        transport: (_) => pending.future);
    await tester.pumpWidget(_host(NikoCmVoicePanel(model: model)));
    await tester.ensureVisible(find.byKey(const ValueKey('niko-voice-end')));
    await tester.tap(find.byKey(const ValueKey('niko-voice-end')));
    await tester.pump(const Duration(seconds: 6));
    expect(model.cleanupUnconfirmed, true);
    expect(model.busy, false);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(_host(NikoCmVoicePanel(model: model)));
    expect(find.byKey(const ValueKey('niko-voice-cleanup')), findsOneWidget);
    expect(find.text('本机音频已确认停止'), findsNothing);
    expect(find.byKey(const ValueKey('niko-voice-enumerate')), findsNothing);
    await tester.pumpWidget(const SizedBox());
    model.dispose();
  });
  testWidgets(
      'retired panel exposes cleanup only and cannot restore a camera or new call row',
      (tester) async {
    final sent = <NikoVoiceCommand>[];
    final model = NikoVoiceSessionModel(
        anchor: parsedVoiceStatus(phase: 'RecoveryRequired'),
        cleanupOnly: true,
        transport: (command) async {
          sent.add(command);
          return voiceQueued(command);
        });
    await tester.pumpWidget(_host(NikoCmVoicePanel(model: model)));
    expect(find.byKey(const ValueKey('niko-voice-enumerate')), findsNothing);
    expect(find.byKey(const ValueKey('niko-voice-approve')), findsNothing);
    expect(find.byKey(const ValueKey('niko-voice-permission')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('niko-voice-cleanup')));
    await tester.pumpAndSettle();
    expect(sent.single.op, 'retry_cleanup');
    expect(find.text('本机音频已确认停止'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    model.dispose();
  });
  testWidgets(
      'controller ready and peer accepted are separate; mute never claims microphone release',
      (tester) async {
    final model = _model(<NikoVoiceCommand>[], phase: 'Running', muted: true);
    await tester.pumpWidget(_host(NikoVoiceCallPanel(model: model)));
    expect(find.text('本机音频：已就绪'), findsOneWidget);
    expect(find.text('对端接听：未确认'), findsOneWidget);
    expect(find.text('语音通话中'), findsNothing);
    expect(find.text('已静音：不发送声音，麦克风仍在使用中。'), findsOneWidget);
    model.applyStatus(parsedVoiceStatus(
        phase: 'Running', revision: '2', peerAccepted: true, muted: true));
    await tester.pump();
    expect(find.text('语音通话中'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    model.dispose();
  });
  testWidgets('unknown backend codes are not displayed to users',
      (tester) async {
    final model = NikoVoiceSessionModel(
        anchor: parsedVoiceStatus(),
        transport: (command) async => jsonEncode({
              'ok': false,
              'status': 'error',
              'identity': command.captured.identity.toJson(),
              'revision': command.captured.revision,
              'reason': 'synthetic_backend_secret'
            }));
    await tester.pumpWidget(_host(NikoCmVoicePanel(model: model)));
    await tester.ensureVisible(find.byKey(const ValueKey('niko-voice-query')));
    await tester.tap(find.byKey(const ValueKey('niko-voice-query')));
    await tester.pumpAndSettle();
    expect(find.text('synthetic_backend_secret'), findsNothing);
    expect(find.text('请按当前通话状态操作。'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    model.dispose();
  });
  testWidgets(
      'a new controller preparation appears only after actual shutdown confirmation',
      (tester) async {
    var calls = 0;
    final model = _model(<NikoVoiceCommand>[], phase: 'RecoveryRequired');
    final preparation = NikoVoicePreparation(
        contextKey: 'synthetic-next-call',
        availability: NikoVoiceAvailability.enabled,
        prepare: () async {
          calls++;
          return NikoVoicePrepareResult.queued;
        });
    await tester.pumpWidget(
        _host(NikoVoiceCallPanel(model: model, preparation: preparation)));
    expect(find.byKey(const ValueKey('niko-voice-prepare')), findsNothing);
    expect(calls, 0);
    model.applyStatus(parsedVoiceStatus(phase: 'Stopped', revision: '2'));
    await tester.pump();
    await tester
        .ensureVisible(find.byKey(const ValueKey('niko-voice-prepare')));
    await tester.tap(find.byKey(const ValueKey('niko-voice-prepare')));
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(model.status.phase, 'Stopped');
    expect(preparation.phase, 'pending');
    await tester.pumpWidget(const SizedBox());
    model.dispose();
    preparation.dispose();
  });
  testWidgets(
      'prepare supports keyboard and minimum touch size; queued is not a call',
      (tester) async {
    var calls = 0;
    final preparation = NikoVoicePreparation(
        contextKey: 'synthetic-session',
        availability: NikoVoiceAvailability.enabled,
        prepare: () async {
          calls++;
          return NikoVoicePrepareResult.queued;
        });
    final semantics = tester.ensureSemantics();
    try {
      await tester
          .pumpWidget(_host(NikoVoiceCallPanel(preparation: preparation)));
      expect(calls, 0);
      final prepare = find.byKey(const ValueKey('niko-voice-prepare'));
      expect(tester.getSize(prepare).height, greaterThanOrEqualTo(48));
      expect(
          tester.getSemantics(prepare).hasFlag(SemanticsFlag.isButton), true);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(calls, 1);
      expect(preparation.phase, 'pending');
      expect(find.text('语音通话中'), findsNothing);
    } finally {
      semantics.dispose();
      await tester.pumpWidget(const SizedBox());
      preparation.dispose();
    }
  });
  testWidgets(
      'unsupported controller gives feedback and cannot send an ineffective command',
      (tester) async {
    var calls = 0;
    final preparation = NikoVoicePreparation(
        contextKey: 'synthetic-android',
        availability: NikoVoiceAvailability.backendUnsupported,
        prepare: () async {
          calls++;
          return NikoVoicePrepareResult.queued;
        });
    await tester
        .pumpWidget(_host(NikoVoiceCallPanel(preparation: preparation)));
    expect(find.text('此平台的语音通话暂不可用。文字聊天可正常使用。'), findsOneWidget);
    expect(
        tester
            .widget<FilledButton>(
                find.byKey(const ValueKey('niko-voice-prepare')))
            .onPressed,
        isNull);
    expect(calls, 0);
    await tester.pumpWidget(const SizedBox());
    preparation.dispose();
  });
  testWidgets(
      'retiring controller context prevents a late prepare result from changing a new panel',
      (tester) async {
    final late = Completer<NikoVoicePrepareResult>();
    final old = NikoVoicePreparation(
        contextKey: 'synthetic-old',
        availability: NikoVoiceAvailability.enabled,
        prepare: () => late.future);
    final current = NikoVoicePreparation(
        contextKey: 'synthetic-new',
        availability: NikoVoiceAvailability.enabled,
        prepare: () async => NikoVoicePrepareResult.queued);
    await tester.pumpWidget(_host(NikoVoiceCallPanel(preparation: old)));
    await tester.tap(find.byKey(const ValueKey('niko-voice-prepare')));
    await tester.pump();
    await tester.pumpWidget(_host(NikoVoiceCallPanel(preparation: current)));
    old.dispose();
    late.complete(NikoVoicePrepareResult.queued);
    await tester.pump();
    expect(current.phase, 'idle');
    expect(
        tester
            .widget<FilledButton>(
                find.byKey(const ValueKey('niko-voice-prepare')))
            .onPressed,
        isNotNull);
    await tester.pumpWidget(const SizedBox());
    current.dispose();
  });
  for (final english in [false, true]) {
    for (final dark in [false, true]) {
      testWidgets(
          'CM voice 320px 200% ${english ? 'English' : 'Chinese'} ${dark ? 'dark' : 'light'} fits long devices',
          (tester) async {
        NikoLanguage.english = english;
        tester.view.physicalSize = const Size(320, 640);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final sent = <NikoVoiceCommand>[];
        final model = _model(sent, label: 'Long device name ' * 30);
        await tester.pumpWidget(
            _host(NikoCmVoicePanel(model: model), scale: 2, dark: dark));
        await tester.pumpAndSettle();
        await tester.ensureVisible(
            find.byKey(const ValueKey('niko-voice-capture-device')));
        await tester
            .tap(find.byKey(const ValueKey('niko-voice-capture-device')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('Long device name ' * 30).last);
        await tester.pumpAndSettle();
        await tester
            .ensureVisible(find.byKey(const ValueKey('niko-voice-approve')));
        expect(tester.takeException(), isNull);
        expect(sent, isEmpty);
        await tester.pumpWidget(const SizedBox());
        model.dispose();
      });
    }
  }
}
