import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_hbb/generated_bridge.dart';
import 'package:flutter_hbb/models/input_model.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/nikodesk/session_shortcuts.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

class _KeyboardBridge implements Rustdesk {
  String source = 'Input source 2';
  String? mode = '';
  Completer<void>? pendingPress;
  final events = <Map<String, Object?>>[];

  @override
  String mainGetInputSource({dynamic hint}) => source;

  @override
  Future<void> sessionHandleFlutterKeyEvent(
      {required UuidValue sessionId,
      required String character,
      required int usbHid,
      required int lockModes,
      required bool downOrUp,
      dynamic hint}) async {
    events.add({
      'route': 'key',
      'session': sessionId,
      'usb': usbHid,
      'down': downOrUp
    });
  }

  @override
  Future<void> sessionHandleFlutterRawKeyEvent(
      {required UuidValue sessionId,
      required String name,
      required int platformCode,
      required int positionCode,
      required int lockModes,
      required bool downOrUp,
      dynamic hint}) async {
    events.add({
      'route': 'raw',
      'session': sessionId,
      'position': positionCode,
      'down': downOrUp
    });
  }

  @override
  Future<void> sessionInputKey(
      {required UuidValue sessionId,
      required String name,
      required bool down,
      required bool press,
      required bool alt,
      required bool ctrl,
      required bool shift,
      required bool command,
      dynamic hint}) async {
    events.add({
      'route': 'legacy',
      'session': sessionId,
      'key': name,
      'down': down,
      'press': press,
      'ctrl': ctrl,
      'cmd': command,
      'shift': shift,
      'alt': alt
    });
    if (press && pendingPress != null) await pendingPress!.future;
  }

  @override
  void sessionEnterOrLeave(
      {required UuidValue sessionId, required bool enter, dynamic hint}) {
    events.add({'route': 'focus', 'session': sessionId, 'enter': enter});
  }

  @override
  Future<String?> sessionGetOption(
          {required UuidValue sessionId,
          required String arg,
          dynamic hint}) async =>
      mode;

  @override
  Future<void> sessionPeerOption(
      {required UuidValue sessionId,
      required String name,
      required String value,
      dynamic hint}) async {
    events.add({
      'route': 'option',
      'session': sessionId,
      'name': name,
      'value': value
    });
    mode = value;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _KeyboardState implements FfiModel {
  @override
  bool keyboard = true;
  @override
  bool viewOnly = false;
  @override
  final permissions = <String, bool>{};
  @override
  final pi = PeerInfo()
    ..platform = 'Mac OS'
    ..version = '1.5.0';
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _KeyboardFfi implements FFI {
  @override
  UuidValue sessionId = UuidValue('11111111-1111-4111-8111-111111111111');
  @override
  final _KeyboardState ffiModel = _KeyboardState();
  @override
  final connType = ConnType.defaultConn;
  @override
  final id = '';
  @override
  bool closed = false;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(RawKeyboard.instance.clearKeysPressed);

  ({_KeyboardFfi ffi, _KeyboardBridge bridge, InputModel input}) fixture() {
    final ffi = _KeyboardFfi();
    final bridge = _KeyboardBridge();
    final input = InputModel(WeakReference(ffi), keyboardBridge: bridge);
    // Relative mouse capture is never enabled in this keyboard-only fixture.
    // Closing the observer avoids the production relative-mouse OS cleanup.
    addTearDown(input.relativeMouseMode.close);
    return (ffi: ffi, bridge: bridge, input: input);
  }

  test(
      'actual KeyEvent entry sends matching physical down, repeat and up to the same native session',
      () {
    final f = fixture();
    final keys = [
      const KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.controlLeft,
          logicalKey: LogicalKeyboardKey.controlLeft,
          timeStamp: Duration.zero),
      const KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.keyC,
          logicalKey: LogicalKeyboardKey.keyC,
          timeStamp: Duration.zero),
      const KeyRepeatEvent(
          physicalKey: PhysicalKeyboardKey.keyC,
          logicalKey: LogicalKeyboardKey.keyC,
          timeStamp: Duration.zero),
      const KeyUpEvent(
          physicalKey: PhysicalKeyboardKey.keyC,
          logicalKey: LogicalKeyboardKey.keyC,
          timeStamp: Duration.zero),
      const KeyUpEvent(
          physicalKey: PhysicalKeyboardKey.controlLeft,
          logicalKey: LogicalKeyboardKey.controlLeft,
          timeStamp: Duration.zero),
    ];
    for (final key in keys) {
      f.input.handleKeyEvent(key);
    }
    expect(f.bridge.events.map((e) => e['route']), everyElement('key'));
    expect(f.bridge.events.map((e) => e['session']),
        everyElement(f.ffi.sessionId));
    expect(
        f.bridge.events.map((e) => e['usb']), [0xe0, 0x06, 0x06, 0x06, 0xe0]);
    expect(f.bridge.events.map((e) => e['down']),
        [true, true, true, false, false]);
    expect(f.input.ctrl, false);
  });

  for (final mode in ['map', 'legacy']) {
    test(
        'actual RawKeyEvent $mode entry preserves Control+arrow and reaches native dispatch',
        () {
      final f = fixture();
      f.input.keyboardMode = mode;
      final keys = [
        RawKeyDownEvent(
            data: const RawKeyEventDataWindows(
                keyCode: 0x11,
                scanCode: 0x1d,
                modifiers: RawKeyEventDataWindows.modifierControl |
                    RawKeyEventDataWindows.modifierLeftControl)),
        RawKeyDownEvent(
            data: const RawKeyEventDataWindows(
                keyCode: 0x43,
                scanCode: 0x2e,
                modifiers: RawKeyEventDataWindows.modifierControl |
                    RawKeyEventDataWindows.modifierLeftControl)),
        RawKeyUpEvent(
            data: const RawKeyEventDataWindows(
                keyCode: 0x43,
                scanCode: 0x2e,
                modifiers: RawKeyEventDataWindows.modifierControl |
                    RawKeyEventDataWindows.modifierLeftControl)),
        RawKeyDownEvent(
            data: const RawKeyEventDataWindows(
                keyCode: 0x25,
                scanCode: 0xe04b,
                modifiers: RawKeyEventDataWindows.modifierControl |
                    RawKeyEventDataWindows.modifierLeftControl)),
        RawKeyUpEvent(
            data: const RawKeyEventDataWindows(
                keyCode: 0x25,
                scanCode: 0xe04b,
                modifiers: RawKeyEventDataWindows.modifierControl |
                    RawKeyEventDataWindows.modifierLeftControl)),
        RawKeyUpEvent(
            data: const RawKeyEventDataWindows(keyCode: 0x11, scanCode: 0x1d)),
      ];
      for (final key in keys) {
        RawKeyboard.instance.handleRawKeyEvent(key);
        f.input.handleRawKeyEvent(key);
      }
      expect(f.bridge.events, hasLength(6));
      expect(f.bridge.events.map((e) => e['session']),
          everyElement(f.ffi.sessionId));
      if (mode == 'map') {
        expect(f.bridge.events.map((e) => e['route']), everyElement('raw'));
        expect(f.bridge.events.map((e) => e['position']),
            [0x1d, 0x2e, 0x2e, 0xe04b, 0xe04b, 0x1d]);
      } else {
        expect(f.bridge.events.map((e) => e['key']),
            ['VK_CONTROL', 'VK_C', 'VK_C', 'VK_LEFT', 'VK_LEFT', 'VK_CONTROL']);
        expect(f.bridge.events[3]['ctrl'], true);
        expect(f.bridge.events.map((e) => e['cmd']), everyElement(false));
      }
    });
  }

  test(
      'default native capture does not dispatch physical keys twice through Flutter',
      () {
    final f = fixture();
    f.bridge.source = 'Input source 1';
    f.input.handleKeyEvent(const KeyDownEvent(
        physicalKey: PhysicalKeyboardKey.keyC,
        logicalKey: LogicalKeyboardKey.keyC,
        timeStamp: Duration.zero));
    f.input.handleRawKeyEvent(RawKeyDownEvent(
        data: const RawKeyEventDataWindows(
            keyCode: 0x43,
            scanCode: 0x2e,
            modifiers: RawKeyEventDataWindows.modifierControl |
                RawKeyEventDataWindows.modifierLeftControl)));
    expect(f.bridge.events, isEmpty);
  });

  test(
      'window blur releases held physical modifiers and explicitly clears native mapping even in Flutter source',
      () {
    final f = fixture();
    f.input.handleKeyEvent(const KeyDownEvent(
        physicalKey: PhysicalKeyboardKey.controlLeft,
        logicalKey: LogicalKeyboardKey.controlLeft,
        timeStamp: Duration.zero));
    f.bridge.events.clear();
    f.input.onWindowBlur();
    if (!(const bool.fromEnvironment('NIKODESK'))) {
      expect(f.bridge.events, isEmpty,
          reason: 'stock keeps the existing blur path');
      return;
    }
    expect(f.bridge.events.map((e) => e['route']), ['key', 'focus']);
    expect(f.bridge.events.first['down'], false);
    expect(f.bridge.events.last['enter'], false);
    expect(f.input.ctrl, false);
  });

  test(
      'semantic button release retains the original session after a pending press and session replacement',
      () async {
    final f = fixture();
    final original = f.ffi.sessionId;
    if (!(const bool.fromEnvironment('NIKODESK'))) {
      await expectLater(
          f.input.inputNikoShortcutKey(original, 'VK_TAB', press: true),
          throwsStateError);
      expect(f.bridge.events, isEmpty);
      return;
    }
    f.input.command = true;
    f.input.shift = true;
    f.bridge.pendingPress = Completer<void>();
    final press = f.input.inputNikoShortcutKey(original, 'VK_TAB', press: true);
    expect(f.bridge.events.single['key'], 'NikoShortcut:VK_TAB');
    expect(f.bridge.events.single['cmd'], true);
    expect(f.bridge.events.single['shift'], true);
    f.ffi.sessionId = UuidValue('22222222-2222-4222-8222-222222222222');
    f.ffi.ffiModel.keyboard = false;
    f.bridge.pendingPress!.complete();
    await press;
    f.input.resetModifiers();
    await f.input.inputNikoShortcutKey(original, 'VK_TAB', press: false);
    expect(f.bridge.events.last['session'], original);
    expect(f.bridge.events.last['cmd'], false);
    await expectLater(
        f.input.inputNikoShortcutKey(original, 'VK_C', press: true),
        throwsStateError);
    expect(f.bridge.events, hasLength(2));
  });

  test(
      'automatic/original selection reaches real peer option and does not confirm a missing session',
      () async {
    final f = fixture();
    expect(
        await f.input.readNikoMacShortcutMode(), NikoMacShortcutMode.automatic);
    if (!(const bool.fromEnvironment('NIKODESK'))) {
      await expectLater(
          f.input.setNikoMacShortcutMode(
              f.ffi.sessionId, NikoMacShortcutMode.original),
          throwsStateError);
      expect(f.bridge.events, isEmpty);
      return;
    }
    await f.input
        .setNikoMacShortcutMode(f.ffi.sessionId, NikoMacShortcutMode.original);
    expect(f.bridge.events.map((e) => e['route']), ['focus', 'option']);
    expect(f.bridge.events.last['name'], 'nikodesk-mac-shortcuts');
    expect(f.bridge.events.last['value'], 'original');
    f.bridge.mode = null;
    await expectLater(f.input.readNikoMacShortcutMode(), throwsStateError);
  });
}
