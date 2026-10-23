import 'dart:math' as math;

import 'package:dash_chat_2/dash_chat_2.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart' show WorkaroundFreezeLinuxMint;
import 'package:flutter_hbb/models/chat_model.dart' show ChatModel;
import 'package:get/get.dart';
import 'package:provider/provider.dart';

import 'nightline.dart';
import 'theme.dart' show nikoSessionTheme;
import 'ui.dart';

/// The floating chat window's size: roomier than the stock 250×350 on a
/// tablet or a desktop, and inside a phone's width.
Size nikoChatWindowSize(Size screen) {
  final wide = screen.width >= NlLayout.compactMax;
  return Size(wide ? 360 : math.min(340, screen.width - 2 * NlSpace.s4),
      math.min(wide ? 500 : 440, screen.height * (wide ? .7 : .6)));
}

String _two(int value) => value.toString().padLeft(2, '0');

String _clock(DateTime time) {
  final local = time.toLocal();
  return '${_two(local.hour)}:${_two(local.minute)}';
}

const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

/// The day a run of messages starts on, as the line between days says it.
String nikoChatDay(DateTime time, {DateTime? now}) {
  final local = time.toLocal();
  final today = (now ?? DateTime.now()).toLocal();
  final day = DateTime(local.year, local.month, local.day);
  final age = DateTime(today.year, today.month, today.day).difference(day);
  if (age.inDays == 0) return nikoText('今天', 'Today');
  if (age.inDays == 1) return nikoText('昨天', 'Yesterday');
  final month = _months[local.month - 1];
  if (local.year == today.year) {
    return nikoText('${local.month}月${local.day}日', '$month ${local.day}');
  }
  return nikoText('${local.year}年${local.month}月${local.day}日',
      '$month ${local.day}, ${local.year}');
}

/// The messages of one chat and the line to write the next: own messages in
/// the accent, the peer's on the raised surface, each with its time, and
/// the day between runs of them.
class NikoChatView extends StatelessWidget {
  final ChatUser me;
  final List<ChatMessage> messages;
  final ValueChanged<ChatMessage> onSend;
  final TextEditingController textController;
  final FocusNode? focusNode;
  final bool readOnly;
  const NikoChatView(
      {super.key,
      required this.me,
      required this.messages,
      required this.onSend,
      required this.textController,
      this.focusNode,
      this.readOnly = false});

  @override
  Widget build(BuildContext context) {
    final nl = NlColors.of(context);
    final field = OutlineInputBorder(
        borderRadius: BorderRadius.circular(NlRadius.r3),
        borderSide: BorderSide(color: nl.line));
    return LayoutBuilder(builder: (context, constraints) {
      final chat = DashChat(
          currentUser: me,
          onSend: onSend,
          messages: messages,
          readOnly: readOnly,
          inputOptions: InputOptions(
              focusNode: focusNode,
              textController: textController,
              alwaysShowSend: true,
              inputTextStyle: NlType.text(NlType.s4, color: nl.fg),
              cursorStyle: CursorStyle(color: nl.accent),
              inputToolbarMargin: EdgeInsets.zero,
              inputToolbarPadding: const EdgeInsets.fromLTRB(
                  NlSpace.s3, NlSpace.s2, NlSpace.s2, NlSpace.s3),
              inputToolbarStyle: BoxDecoration(
                  border: Border(top: BorderSide(color: nl.line))),
              inputDecoration: InputDecoration(
                  isDense: true,
                  hintText: nikoText('输入消息', 'Write a message'),
                  hintStyle: NlType.text(NlType.s4, color: nl.fg3),
                  filled: true,
                  fillColor: nl.surface2,
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: NlSpace.s3, vertical: 10),
                  border: field,
                  enabledBorder: field,
                  focusedBorder:
                      field.copyWith(borderSide: BorderSide(color: nl.accent))),
              sendButtonBuilder: (send) =>
                  _SendButton(controller: textController, onSend: send)),
          messageOptions: MessageOptions(
              showOtherUsersAvatar: false,
              showOtherUsersName: false,
              spaceWhenAvatarIsHidden: NlSpace.s3,
              maxWidth: constraints.maxWidth * .78,
              messagePadding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
              marginDifferentAuthor: const EdgeInsets.only(top: NlSpace.s3),
              marginSameAuthor: const EdgeInsets.only(top: 3),
              messageTextBuilder: (message, _, __) =>
                  _BubbleText(message: message, own: message.user.id == me.id),
              messageDecorationBuilder: (message, _, next) {
                final own = message.user.id == me.id;
                // The last of a run gets a tail on the speaker's side.
                final tail = next == null || next.user.id != message.user.id;
                const round = Radius.circular(16), point = Radius.circular(5);
                return BoxDecoration(
                    color: own ? nl.accent : nl.surface2,
                    borderRadius: BorderRadius.only(
                        topLeft: round,
                        topRight: round,
                        bottomLeft: !own && tail ? point : round,
                        bottomRight: own && tail ? point : round));
              }),
          messageListOptions: MessageListOptions(
              // Room between the newest message and the input line.
              chatFooterBuilder: const SizedBox(height: NlSpace.s3),
              dateSeparatorBuilder: (date) => Padding(
                  padding: const EdgeInsets.only(
                      top: NlSpace.s4, bottom: NlSpace.s1),
                  child: Text(nikoChatDay(date),
                      style: NlType.text(NlType.s1,
                          weight: FontWeight.w500, color: nl.fg3)))),
          scrollToBottomOptions: ScrollToBottomOptions(
              scrollToBottomBuilder: (controller) =>
                  _ScrollToBottom(controller: controller)));
      return Stack(children: [
        SelectionArea(child: chat.workaroundFreezeLinuxMint()),
        if (messages.isEmpty)
          // Above the input line, which stays usable.
          Positioned.fill(
              bottom: readOnly ? 0 : 64,
              child: IgnorePointer(
                  child: Center(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(NlIcons.messageSquare, size: 22, color: nl.fg3),
                const SizedBox(height: NlSpace.s2),
                Text(nikoText('还没有消息', 'No messages yet'),
                    style: NlType.text(NlType.s3, color: nl.fg3)),
              ])))),
      ]);
    });
  }
}

class _BubbleText extends StatelessWidget {
  final ChatMessage message;
  final bool own;
  const _BubbleText({required this.message, required this.own});

  @override
  Widget build(BuildContext context) {
    final nl = NlColors.of(context);
    // As wide as the longer of the text and its time, with the time in the
    // bottom corner.
    return IntrinsicWidth(
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
          Text(message.text,
              style: NlType.text(NlType.s4, color: own ? nl.onAccent : nl.fg)),
          const SizedBox(height: 2),
          Text(_clock(message.createdAt),
              textAlign: TextAlign.end,
              style: NlType.text(NlType.s1,
                  color: own ? nl.onAccent.withOpacity(.72) : nl.fg3)),
        ]));
  }
}

class _SendButton extends StatelessWidget {
  final TextEditingController controller;
  final VoidCallback onSend;
  const _SendButton({required this.controller, required this.onSend});

  @override
  Widget build(BuildContext context) {
    final nl = NlColors.of(context);
    return ValueListenableBuilder<TextEditingValue>(
        valueListenable: controller,
        builder: (context, value, _) {
          final ready = value.text.isNotEmpty;
          return Padding(
              padding: const EdgeInsets.only(left: NlSpace.s2),
              child: NlPressable(
                  key: const Key('nikodesk-chat-send'),
                  onTap: ready ? onSend : null,
                  semanticLabel: nikoText('发送', 'Send'),
                  pressScale: .92,
                  builder: (context, states) => AnimatedContainer(
                      duration: NlMotion.of(context, NlMotion.fast),
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                          color: ready ? nl.accent : nl.surface2,
                          shape: BoxShape.circle),
                      child: Icon(NlIcons.arrowUp,
                          size: 18, color: ready ? nl.onAccent : nl.fg3))));
        });
  }
}

class _ScrollToBottom extends StatelessWidget {
  final ScrollController controller;
  const _ScrollToBottom({required this.controller});

  @override
  Widget build(BuildContext context) {
    final nl = NlColors.of(context);
    return Positioned(
        right: NlSpace.s3,
        bottom: NlSpace.s3,
        child: NlPressable(
            onTap: () => controller.animateTo(0,
                duration: NlMotion.of(context, NlMotion.slow),
                curve: NlMotion.standard),
            semanticLabel: nikoText('回到最新', 'Latest messages'),
            builder: (context, states) => Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                    color: nl.overlay,
                    shape: BoxShape.circle,
                    border: Border.all(color: nl.line2),
                    boxShadow: nl.shadow2),
                child: Icon(NlIcons.chevronDown, size: 18, color: nl.fg2))));
  }
}

/// The chat window floating over a session: a card dragged by its header,
/// closed from it, and on touch also tucked away behind its round button.
class NikoChatWindowFrame extends StatelessWidget {
  final GestureDragUpdateCallback onPanUpdate;
  final VoidCallback onClose;
  final VoidCallback? onMinimize;

  /// Dims the title while the session, not the chat, takes the keyboard.
  final bool focused;
  final Widget child;
  const NikoChatWindowFrame(
      {super.key,
      required this.onPanUpdate,
      required this.onClose,
      this.onMinimize,
      this.focused = true,
      required this.child});

  @override
  Widget build(BuildContext context) {
    final nl = NlColors.of(context);
    final radius = BorderRadius.circular(NlRadius.r4);
    return Material(
        type: MaterialType.transparency,
        child: DecoratedBox(
            decoration: BoxDecoration(
                color: nl.overlay,
                borderRadius: radius,
                border: Border.all(color: nl.line),
                boxShadow: nl.shadow3),
            child: ClipRRect(
                borderRadius: radius,
                child: Column(children: [
                  GestureDetector(
                      key: const Key('nikodesk-chat-header'),
                      behavior: HitTestBehavior.opaque,
                      onPanUpdate: onPanUpdate,
                      child: Padding(
                          padding: const EdgeInsets.fromLTRB(
                              NlSpace.s4, NlSpace.s1, NlSpace.s1, NlSpace.s1),
                          child: Row(children: [
                            Expanded(
                                child: AnimatedOpacity(
                                    opacity: focused ? 1 : .45,
                                    duration:
                                        NlMotion.of(context, NlMotion.fast),
                                    child: Row(children: [
                                      Icon(NlIcons.messageSquare,
                                          size: 16, color: nl.fg2),
                                      const SizedBox(width: NlSpace.s2),
                                      Flexible(
                                          child: Semantics(
                                              header: true,
                                              child: Text(
                                                  nikoText('聊天', 'Chat'),
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: NlType.text(NlType.s4,
                                                      weight: FontWeight.w600,
                                                      color: nl.fg)))),
                                    ]))),
                            if (onMinimize != null)
                              NlIconButton(
                                  key: const Key('nikodesk-chat-minimize'),
                                  icon: NlIcons.chevronDown,
                                  tooltip: nikoText('收起', 'Minimize'),
                                  onPressed: onMinimize),
                            NlIconButton(
                                key: const Key('nikodesk-chat-close'),
                                icon: NlIcons.close,
                                tooltip: nikoText('关闭', 'Close'),
                                onPressed: onClose),
                          ]))),
                  Divider(height: 1, thickness: 1, color: nl.line),
                  Expanded(child: child),
                ]))));
  }
}

/// A session's chat window: [NikoChatWindowFrame] around the current chat,
/// dark like the rest of the session chrome.
class NikoSessionChatWindow extends StatelessWidget {
  final ChatModel chatModel;
  final GestureDragUpdateCallback onPanUpdate;
  final bool touch;
  const NikoSessionChatWindow(
      {super.key,
      required this.chatModel,
      required this.onPanUpdate,
      required this.touch});

  @override
  Widget build(BuildContext context) => Theme(
      data: nikoSessionTheme(context),
      child: Obx(() => NikoChatWindowFrame(
          onPanUpdate: onPanUpdate,
          focused: chatModel.isWindowFocus.value,
          onMinimize: touch ? chatModel.hideChatWindowOverlay : null,
          onClose: touch
              ? () {
                  chatModel.hideChatWindowOverlay();
                  chatModel.hideChatIconOverlay();
                }
              : chatModel.hideChatWindowOverlay,
          child: ChangeNotifierProvider.value(
              value: chatModel,
              child: Consumer<ChatModel>(
                  builder: (context, model, _) => NikoChatView(
                      me: model.me,
                      messages:
                          model.messages[model.currentKey]?.chatMessages ?? [],
                      onSend: model.send,
                      focusNode: model.inputNode,
                      textController: model.textController))))));
}

/// The round button that brings a tucked-away chat back, in the dock's
/// colours.
class NikoChatBubbleButton extends StatelessWidget {
  final VoidCallback onPressed;
  const NikoChatBubbleButton({super.key, required this.onPressed});

  @override
  Widget build(BuildContext context) => Center(
      child: NlPressable(
          onTap: onPressed,
          semanticLabel: nikoText('聊天', 'Chat'),
          pressScale: .92,
          builder: (context, states) => Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                  color: NlDock.background,
                  shape: BoxShape.circle,
                  border: Border.all(color: NlDock.line),
                  boxShadow: NlColors.dark.shadow2),
              child: const Icon(NlIcons.messageSquare,
                  size: 22, color: Colors.white))));
}
