import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/nikodesk/nightline.dart';
import 'package:flutter_hbb/nikodesk/session_sheet.dart';
import 'package:flutter_hbb/nikodesk/theme.dart';
import 'package:flutter_hbb/nikodesk/ui.dart';
import 'package:flutter_hbb/nikodesk/voice_session_owner.dart';
import 'package:flutter_hbb/nikodesk/voice_session_view.dart';

import 'nikodesk_voice_owner_test.dart' show voiceEnabled, voiceEvent;
import 'nikodesk_voice_session_model_test.dart' show voiceQueued, voiceStatus;

void main() {
  tearDown(() => NikoLanguage.english = false);

  // Fixtures only: no native voice call is made.
  NikoVoiceSessionOwner owner({bool current = true, List<String>? calls}) {
    final owner = NikoVoiceSessionOwner(
        contextKey: 'session-A',
        namespace: 'a' * 64,
        peerId: '123456789',
        isCurrent: () => current,
        readAvailability: () async {
          calls?.add('read');
          return voiceEnabled;
        },
        prepareNative: () async {
          calls?.add('prepare');
          return '{"ok":true,"status":"queued"}';
        },
        commandNative: (command) async {
          calls?.add('command');
          return voiceQueued(command);
        });
    addTearDown(owner.dispose);
    return owner;
  }

  Widget host(Widget panel, {double textScale = 1}) => MaterialApp(
      theme: nikoTheme(Brightness.light),
      builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!),
      home: Scaffold(body: NikoSessionSheet(onCancel: () {}, child: panel)));

  testWidgets('the call panel names the call once and closes', (tester) async {
    NikoLanguage.english = true;
    final calls = <String>[];
    final voice = owner(calls: calls);
    await voice.refreshAvailability();
    await tester.pumpWidget(host(NikoVoiceSessionPanel(
        owner: voice, onClose: () => calls.add('close'))));
    await tester.pumpAndSettle();
    // Dark in a light app, like the rest of the session chrome.
    expect(NlColors.of(tester.element(find.text('Voice call'))).isDark, isTrue);
    expect(find.text('Call status'), findsOneWidget);
    // Only the sheet names the call.
    expect(find.text('Voice call'), findsOneWidget);
    expect(find.byKey(const ValueKey('niko-voice-prepare')), findsOneWidget);

    await tester.tap(find.byKey(const Key('niko-voice-refresh')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('niko-voice-close')));
    // Reading availability prepares nothing.
    expect(calls, ['read', 'read', 'close']);
  });

  testWidgets('a closed session says so and only closes', (tester) async {
    NikoLanguage.english = true;
    final calls = <String>[];
    await tester.pumpWidget(host(NikoVoiceSessionPanel(
        owner: owner(current: false, calls: calls),
        onClose: () => calls.add('close'))));
    await tester.pumpAndSettle();
    expect(find.text('The session is closed. Connect again.'), findsOneWidget);
    expect(find.byKey(const ValueKey('niko-voice-prepare')), findsNothing);
    await tester.tap(find.byKey(const Key('niko-voice-refresh')));
    await tester.tap(find.byKey(const Key('niko-voice-close')));
    expect(calls, ['close']);
  });

  testWidgets('an incoming call shows its panel until it ends', (tester) async {
    NikoLanguage.english = true;
    final voice = owner();
    expect(voice.handleEvent(voiceEvent(voiceStatus())..['initiator'] = 'peer'),
        isTrue);
    final call = voice.model!;
    var hidden = 0;
    await tester.pumpWidget(host(NikoIncomingVoicePanel(
        owner: voice, call: call, onHide: () => hidden++)));
    await tester.pumpAndSettle();
    expect(find.text('Incoming voice call'), findsOneWidget);
    expect(find.text('Call status'), findsOneWidget);
    expect(find.text('This incoming call has ended.'), findsNothing);
    await tester.tap(find.byKey(const Key('niko-voice-hide')));
    expect(hidden, 1);

    // Once the session is gone the panel only says the call ended.
    await tester.pumpWidget(host(NikoIncomingVoicePanel(
        owner: owner(current: false), call: call, onHide: () => hidden++)));
    await tester.pumpAndSettle();
    expect(find.text('This incoming call has ended.'), findsOneWidget);
    expect(find.text('Call status'), findsNothing);
  });

  testWidgets('without a call the panel explains and closes', (tester) async {
    var closed = false;
    await tester.pumpWidget(host(NikoVoiceUnavailablePanel(
        message: '会话已关闭，请重新连接。', onClose: () => closed = true)));
    await tester.pumpAndSettle();
    expect(find.text('会话已关闭，请重新连接。'), findsOneWidget);
    await tester.tap(find.byKey(const Key('niko-voice-close')));
    expect(closed, isTrue);
  });

  // A phone, where the panel is a bottom sheet, and a small window, where
  // it floats.
  for (final size in const [Size(320, 640), Size(640, 400)]) {
    for (final english in [false, true]) {
      testWidgets(
          'voice panels fit ${size.width.toInt()}x${size.height.toInt()} '
          'at 200% text ($english)', (tester) async {
        NikoLanguage.english = english;
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final voice = owner();
        await voice.refreshAvailability();
        final incoming = owner();
        incoming.handleEvent(voiceEvent(voiceStatus())..['initiator'] = 'peer');
        for (final panel in [
          NikoVoiceSessionPanel(owner: voice, onClose: () {}),
          NikoIncomingVoicePanel(
              owner: incoming, call: incoming.model!, onHide: () {}),
          NikoVoiceUnavailablePanel(
              message: nikoText(
                  '会话已关闭，请重新连接。', 'The session is closed. Connect again.'),
              onClose: () {}),
        ]) {
          await tester.pumpWidget(host(panel, textScale: 2));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        }
      });
    }
  }
}
