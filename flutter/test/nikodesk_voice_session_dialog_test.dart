import 'package:flutter/material.dart';
import 'package:flutter_hbb/nikodesk/theme.dart';
import 'package:flutter_hbb/nikodesk/ui.dart';
import 'package:flutter_hbb/nikodesk/voice_session_model.dart';
import 'package:flutter_hbb/nikodesk/voice_session_native.dart';
import 'package:flutter_hbb/nikodesk/voice_session_owner.dart';
import 'package:flutter_test/flutter_test.dart';

import 'nikodesk_voice_owner_test.dart' show voiceEnabled;
import 'nikodesk_voice_session_model_test.dart' show voiceQueued;

Future<void> _open(WidgetTester tester, NikoVoiceSessionOwner owner) async {
  tester.view.physicalSize = const Size(320, 700);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(
      theme: nikoTheme(Brightness.dark),
      builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(2)),
          child: child!),
      home: Scaffold(
          body: Builder(
              builder: (context) => TextButton(
                  onPressed: () => showNikoVoiceSession(context, owner),
                  child: const Text('Open'))))));
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
}

void main() {
  tearDown(() => NikoLanguage.english = false);
  testWidgets(
      'production dialog has metadata-only explicit opening and truthful queued prepare at 320/200%',
      (tester) async {
    NikoLanguage.english = true;
    var metadata = 0, prepares = 0, commands = 0;
    final owner = NikoVoiceSessionOwner(
        contextKey: 'session-A',
        namespace: 'a' * 64,
        peerId: '123456789',
        isCurrent: () => true,
        readAvailability: () async {
          metadata++;
          return voiceEnabled;
        },
        prepareNative: () async {
          prepares++;
          return '{"ok":true,"status":"queued"}';
        },
        commandNative: (c) async {
          commands++;
          return voiceQueued(c);
        });
    await _open(tester, owner);
    expect(metadata, 1);
    expect(prepares + commands, 0);
    final prepare = find.byKey(const ValueKey('niko-voice-prepare'));
    await tester.ensureVisible(prepare);
    expect(tester.getSize(prepare).height, greaterThanOrEqualTo(48));
    await tester.tap(prepare);
    await tester.pumpAndSettle();
    expect(prepares, 1);
    expect(owner.preparation.phase, 'pending');
    expect(owner.model, isNull);
    expect(tester.takeException(), isNull);
    owner.dispose();
    await tester.pumpAndSettle();
    expect(find.text('The session is closed. Connect again.'), findsOneWidget);
    expect(find.byKey(const ValueKey('niko-voice-prepare')), findsNothing);
    await tester.ensureVisible(find.text('Close panel'));
    await tester.tap(find.text('Close panel'));
    await tester.pumpAndSettle();
    expect(commands, 0);
  });
  testWidgets(
      'unsupported native availability leaves preparation disabled with feedback',
      (tester) async {
    var prepares = 0;
    final owner = NikoVoiceSessionOwner(
        contextKey: 'session-A',
        namespace: 'a' * 64,
        peerId: '123456789',
        isCurrent: () => true,
        readAvailability: () async =>
            '{"supported":false,"requests_allowed":false,"peer_supported":false,"peer_requests_allowed":false,"reason":"unsupported"}',
        prepareNative: () async {
          prepares++;
          return '{}';
        },
        commandNative: (c) async => voiceQueued(c));
    await _open(tester, owner);
    expect(owner.availability, NikoVoiceAvailability.backendUnsupported);
    final prepare = find.byKey(const ValueKey('niko-voice-prepare'));
    expect(tester.widget<FilledButton>(prepare).onPressed, isNull);
    expect(find.text('此平台的语音通话暂不可用。文字聊天可正常使用。'), findsWidgets);
    expect(prepares, 0);
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('关闭面板'));
    await tester.tap(find.text('关闭面板'));
    await tester.pumpAndSettle();
    owner.dispose();
  });
}
