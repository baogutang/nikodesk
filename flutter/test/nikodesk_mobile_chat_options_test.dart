import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/nikodesk/mobile_chat_options.dart';
import 'package:flutter_hbb/nikodesk/theme.dart';
import 'package:flutter_hbb/nikodesk/ui.dart';
import 'package:flutter_test/flutter_test.dart';

const _chat = ValueKey('niko-mobile-text-chat');
const _voice = ValueKey('niko-mobile-voice-unavailable');

Future<void> _open(WidgetTester tester,
    {bool english = false,
    Brightness brightness = Brightness.light,
    required VoidCallback onTextChat,
    ValueNotifier<bool>? originVisible}) async {
  NikoLanguage.english = english;
  tester.view.physicalSize = const Size(320, 640);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final visible = originVisible ?? ValueNotifier(true);
  if (originVisible == null) addTearDown(visible.dispose);
  await tester.pumpWidget(MaterialApp(
      theme: nikoTheme(brightness),
      builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(2)),
          child: child!),
      home: Scaffold(
          body: ValueListenableBuilder<bool>(
              valueListenable: visible,
              builder: (context, visible, _) => visible
                  ? Builder(
                      builder: (context) => TextButton(
                          onPressed: () => showNikoMobileChatOptions(context,
                              onTextChat: onTextChat),
                          child: const Text('Open chat options')))
                  : const Text('Origin closed')))));
  await tester.tap(find.text('Open chat options'));
  await tester.pumpAndSettle();
}

void main() {
  tearDown(() => NikoLanguage.english = false);

  for (final english in [false, true]) {
    for (final brightness in [Brightness.light, Brightness.dark]) {
      testWidgets('320px/200% menu english=$english $brightness',
          (tester) async {
        var chats = 0;
        await _open(tester,
            english: english,
            brightness: brightness,
            onTextChat: () => chats++);
        expect(
            find.text(english
                ? 'Voice calls are not supported in this version. Text chat is available.'
                : '此版本暂不支持语音通话。文字聊天可正常使用。'),
            findsOneWidget);
        final disabled = tester.widget<ListTile>(find.descendant(
            of: find.byKey(_voice), matching: find.byType(ListTile)));
        expect(disabled.enabled, isFalse);
        expect(disabled.onTap, isNull);
        await tester.ensureVisible(find.byKey(_voice));
        await tester.tap(find.byKey(_voice));
        await tester.pumpAndSettle();
        expect(chats, 0);
        expect(find.byKey(_voice), findsOneWidget);
        await tester.ensureVisible(find.byKey(_chat));
        expect(
            tester.getSize(find.byKey(_chat)).height, greaterThanOrEqualTo(48));
        await tester.tap(find.byKey(_chat));
        await tester.pumpAndSettle();
        expect(chats, 1);
        expect(find.byKey(_voice), findsNothing);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('voice is announced as a disabled button with no tap action',
      (tester) async {
    final semantics = tester.ensureSemantics();
    try {
      await _open(tester, onTextChat: () {});
      await tester.ensureVisible(find.byKey(_voice));
      final data = tester.getSemantics(find.byKey(_voice)).getSemanticsData();
      expect(data.hasFlag(SemanticsFlag.isButton), isTrue);
      expect(data.hasFlag(SemanticsFlag.hasEnabledState), isTrue);
      expect(data.hasFlag(SemanticsFlag.isEnabled), isFalse);
      expect(data.hasAction(SemanticsAction.tap), isFalse);
      expect(tester.takeException(), isNull);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('keyboard can select text chat without entering a voice action',
      (tester) async {
    var chats = 0;
    await _open(tester, onTextChat: () => chats++);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(
        FocusManager.instance.primaryFocus?.context
            ?.findAncestorWidgetOfExactType<ListTile>()
            ?.key,
        _chat);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(chats, 1);
    expect(find.byKey(_voice), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('closing the menu does not dispatch text or voice',
      (tester) async {
    var chats = 0;
    await _open(tester, onTextChat: () => chats++);
    await tester.ensureVisible(find.text('关闭'));
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(chats, 0);
    expect(find.byKey(_voice), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('closing the original page retires the menu callback',
      (tester) async {
    var chats = 0;
    final visible = ValueNotifier(true);
    addTearDown(visible.dispose);
    await _open(tester, onTextChat: () => chats++, originVisible: visible);
    visible.value = false;
    await tester.pump();
    await tester.ensureVisible(find.byKey(_chat));
    await tester.tap(find.byKey(_chat));
    await tester.pumpAndSettle();
    expect(chats, 0);
    expect(find.byKey(_voice), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
