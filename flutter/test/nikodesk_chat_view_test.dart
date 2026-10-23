import 'package:dash_chat_2/dash_chat_2.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/nikodesk/chat_view.dart';
import 'package:flutter_hbb/nikodesk/nightline.dart';
import 'package:flutter_hbb/nikodesk/theme.dart';
import 'package:flutter_hbb/nikodesk/ui.dart';

void main() {
  tearDown(() => NikoLanguage.english = false);

  final me = ChatUser(id: '', firstName: 'Me');
  final peer = ChatUser(id: '123456789', firstName: 'Mac mini');
  final now = DateTime(2026, 10, 23, 14, 5);

  // Layout and callback fixtures only; nothing reaches a session.
  Widget host(Widget child, {double textScale = 1, Size? size}) => MaterialApp(
      theme: nikoTheme(Brightness.dark),
      builder: (context, app) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: app!),
      home: Scaffold(
          body: Center(
              child: SizedBox(
                  width: size?.width ?? 360,
                  height: size?.height ?? 480,
                  child: child))));

  Widget chat(List<ChatMessage> messages, TextEditingController text,
          {ValueChanged<ChatMessage>? onSend, bool readOnly = false}) =>
      NikoChatView(
          me: me,
          messages: messages,
          onSend: onSend ?? (_) {},
          textController: text,
          readOnly: readOnly);

  testWidgets('bubbles take the speaker colour and show their time',
      (tester) async {
    final text = TextEditingController();
    addTearDown(text.dispose);
    await tester.pumpWidget(host(chat([
      ChatMessage(user: me, text: 'On my way', createdAt: now),
      ChatMessage(
          user: peer,
          text: 'Build finished',
          createdAt: now.subtract(const Duration(minutes: 2))),
    ], text)));
    await tester.pumpAndSettle();
    final nl = NlColors.of(tester.element(find.text('On my way')));
    BoxDecoration bubble(String text) => tester
        .widgetList<Container>(find.ancestor(
            of: find.text(text), matching: find.byType(Container)))
        .map((c) => c.decoration)
        .whereType<BoxDecoration>()
        .first;
    expect(bubble('On my way').color, nl.accent);
    expect(bubble('Build finished').color, nl.surface2);
    expect(find.text('14:05'), findsOneWidget);
    expect(find.text('14:03'), findsOneWidget);
    expect(find.text('No messages yet'), findsNothing);
  });

  testWidgets('send waits for text and hands the message over', (tester) async {
    NikoLanguage.english = true;
    final text = TextEditingController();
    addTearDown(text.dispose);
    final sent = <String>[];
    await tester
        .pumpWidget(host(chat([], text, onSend: (m) => sent.add(m.text))));
    await tester.pumpAndSettle();
    expect(find.text('No messages yet'), findsOneWidget);
    final send = find.byKey(const Key('nikodesk-chat-send'));
    await tester.tap(send);
    expect(sent, isEmpty);
    await tester.enterText(find.byType(TextField), 'hello');
    await tester.pumpAndSettle();
    await tester.tap(send);
    await tester.pumpAndSettle();
    expect(sent, ['hello']);
    expect(text.text, isEmpty);
  });

  testWidgets('a read-only chat has no input line', (tester) async {
    final text = TextEditingController();
    addTearDown(text.dispose);
    await tester.pumpWidget(host(chat([], text, readOnly: true)));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('the window frame drags, tucks away and closes', (tester) async {
    final calls = <String>[];
    final text = TextEditingController();
    addTearDown(text.dispose);
    await tester.pumpWidget(host(NikoChatWindowFrame(
        onPanUpdate: (_) => calls.add('drag'),
        onMinimize: () => calls.add('minimize'),
        onClose: () => calls.add('close'),
        child: chat([], text))));
    await tester.pumpAndSettle();
    await tester.drag(
        find.byKey(const Key('nikodesk-chat-header')), const Offset(40, 30));
    await tester.tap(find.byKey(const Key('nikodesk-chat-minimize')));
    await tester.tap(find.byKey(const Key('nikodesk-chat-close')));
    expect(calls.toSet(), {'drag', 'minimize', 'close'});
    expect(calls.last, 'close');

    // A desktop window only closes.
    await tester.pumpWidget(host(NikoChatWindowFrame(
        onPanUpdate: (_) {}, onClose: () {}, child: chat([], text))));
    expect(find.byKey(const Key('nikodesk-chat-minimize')), findsNothing);
  });

  testWidgets('the round button brings the chat back', (tester) async {
    var pressed = 0;
    await tester.pumpWidget(host(SizedBox(
        width: 60,
        height: 60,
        child: NikoChatBubbleButton(onPressed: () => pressed++))));
    await tester.tap(find.byType(NikoChatBubbleButton));
    expect(pressed, 1);
  });

  test('the window fits a phone and grows on wider screens', () {
    expect(nikoChatWindowSize(const Size(390, 844)), const Size(340, 440));
    expect(nikoChatWindowSize(const Size(320, 568)).width, 288);
    expect(nikoChatWindowSize(const Size(320, 568)).height,
        moreOrLessEquals(568 * .6));
    expect(nikoChatWindowSize(const Size(1180, 820)), const Size(360, 500));
  });

  test('days read as today, yesterday or a date', () {
    NikoLanguage.english = true;
    expect(nikoChatDay(now, now: now), 'Today');
    expect(nikoChatDay(DateTime(2026, 10, 22, 23), now: now), 'Yesterday');
    expect(nikoChatDay(DateTime(2026, 3, 9), now: now), 'Mar 9');
    expect(nikoChatDay(DateTime(2025, 12, 31), now: now), 'Dec 31, 2025');
    NikoLanguage.english = false;
    expect(nikoChatDay(DateTime(2026, 3, 9), now: now), '3月9日');
  });

  for (final english in [false, true]) {
    testWidgets('the window fits 320px at 200% text ($english)',
        (tester) async {
      NikoLanguage.english = english;
      final text = TextEditingController();
      addTearDown(text.dispose);
      await tester.pumpWidget(host(
          NikoChatWindowFrame(
              onPanUpdate: (_) {},
              onMinimize: () {},
              onClose: () {},
              child: chat([
                ChatMessage(
                    user: peer,
                    text: 'A longer message that wraps over a few lines.',
                    createdAt: now),
              ], text)),
          textScale: 2,
          size: nikoChatWindowSize(const Size(320, 640))));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }
}
