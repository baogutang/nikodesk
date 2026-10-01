import 'dart:convert';
import 'package:flutter/widgets.dart';

import 'package:flutter_hbb/generated_bridge.dart';
import 'package:flutter_hbb/desktop/widgets/tabbar_widget.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/nikodesk/tunnel_cleanup.dart';
import 'package:flutter_hbb/nikodesk/tunnel_cleanup_view.dart';
import 'package:flutter_hbb/nikodesk/tunnel_controller.dart';
import 'package:flutter_hbb/nikodesk/voice_session_owner.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

import 'nikodesk_tunnel_controller_test.dart' as fixtures;

// Actual generated interface substitute; no native initialization or command.
class _Bridge implements Rustdesk {
  final calls = <String>[];
  final sessions = <String>[];
  final payloads = <Map>[];
  Future<String> capture(String op, UuidValue sessionId, String json) async {
    calls.add(op);
    sessions.add(sessionId.toString());
    payloads.add(jsonDecode(json));
    return '{"ok":true,"reason":"queued"}';
  }

  @override
  Future<String> sessionNikoTunnelCommand(
          {required UuidValue sessionId, required String json, dynamic hint}) =>
      capture('command', sessionId, json);
  @override
  Future<String> sessionNikoTunnelClose(
          {required UuidValue sessionId, required String json, dynamic hint}) =>
      capture('close', sessionId, json);
  @override
  Future<String> sessionNikoTunnelQuery(
          {required UuidValue sessionId, required String json, dynamic hint}) =>
      capture('query', sessionId, json);
  @override
  Future<String> sessionNikoTunnelRetired({dynamic hint}) async {
    calls.add('retired');
    return '{"ok":true,"reason":"closed","owners":[]}';
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _Ffi implements FFI {
  @override
  final sessionId = const Uuid().v4obj();
  @override
  NikoVoiceSessionOwner? get nikoVoiceOwner => null;
  @override
  NikoTunnelController? nikoTunnelController;
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

// Substitute only the native window-selection endpoint; real closeBy/remove
// and callbacks remain under test, without initializing installed client state.
class _TabController extends DesktopTabController {
  _TabController({required Function(int, String) onRemoved})
      : super(tabType: DesktopTabType.portForward, onRemoved: onRemoved);
  @override
  bool jumpTo(int index, {bool callOnSelected = true}) => true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
      'production transport passes immutable original UUID/scope/peer to actual generated API',
      () async {
    final bridge = _Bridge();
    final transport = NativeNikoTunnelCleanupTransport(bridge: bridge);
    final owner =
        NikoTunnelOwnerIdentity(const Uuid().v4(), fixtures.scope, '123456789');
    await transport.command(
        owner,
        NikoTunnelCommand.add(
            owner.namespace, owner.peerId, 8000, 'target.invalid', 443)!);
    await transport.command(
        owner, NikoTunnelCommand.remove(owner.namespace, owner.peerId, 8000)!);
    await transport.close(owner);
    await transport.query(owner);
    await transport.read();
    expect(bridge.calls, ['command', 'command', 'close', 'query', 'retired']);
    expect(bridge.sessions.every((id) => id == owner.sessionId), true);
    expect(bridge.payloads[1].keys,
        unorderedEquals(['namespace', 'peer_id', 'op', 'local_port']));
    expect(bridge.payloads[2],
        {'namespace': owner.namespace, 'peer_id': owner.peerId});
    expect(bridge.payloads[3], bridge.payloads[2]);
    await transport.command(
        owner,
        NikoTunnelCommand.add(
            'b' * 64, owner.peerId, 8000, 'target.invalid', 443)!);
    expect(bridge.calls.length, 5);
  });
  test(
      'actual controller closeBy preserves Niko PF tab until its callback approves; stock removes directly',
      () {
    var callback = 0, removed = 0;
    final controller = _TabController(onRemoved: (_, __) => removed++);
    controller.state.value.tabs.add(TabInfo(
        key: '123456789',
        label: 'fixture',
        onTabCloseButton: () => callback++,
        page: const SizedBox()));
    controller.closeBy('123456789');
    if (const bool.fromEnvironment('NIKODESK')) {
      expect(callback, 1);
      expect(removed, 0);
      expect(controller.length, 1);
    } else {
      expect(callback, 0);
      expect(removed, 1);
      expect(controller.length, 0);
    }
  });
  test(
      'real FfiModel listener captures original model; old sink cannot populate a new scope',
      () async {
    var oldCurrent = true;
    final old = fixtures.model(current: () => oldCurrent);
    final next = NikoTunnelController(
        contextKey: 'new-uuid/b/987654321',
        namespace: 'b' * 64,
        peerId: '987654321',
        isCurrent: () => true);
    addTearDown(old.dispose);
    addTearDown(next.dispose);
    final ffi = _Ffi()..nikoTunnelController = old;
    final events = FfiModel(WeakReference(ffi));
    final oldSink = events.startEventListener(ffi.sessionId, '123456789');
    await oldSink(fixtures.event(fixtures.status(phase: 'Listening')));
    expect(old.statuses.length, 1);
    oldCurrent = false;
    ffi.nikoTunnelController = next;
    await oldSink(fixtures.event(fixtures.status(
        namespace: 'b' * 64, peer: '987654321', phase: 'Listening')));
    expect(next.statuses, isEmpty);
    final newSink = events.startEventListener(ffi.sessionId, '987654321');
    await newSink(fixtures.event(fixtures.status(
        namespace: 'b' * 64, peer: '987654321', phase: 'Listening')));
    expect(next.statuses.length, 1);
    events.dispose();
  }, skip: !const bool.fromEnvironment('NIKODESK'));
  test('stock FfiModel ignores Niko tunnel events', () async {
    final model = fixtures.model();
    addTearDown(model.dispose);
    final ffi = _Ffi()..nikoTunnelController = model;
    final events = FfiModel(WeakReference(ffi));
    await events.startEventListener(
        ffi.sessionId, '123456789')(fixtures.event(fixtures.status()));
    expect(model.statuses, isEmpty);
    events.dispose();
  }, skip: const bool.fromEnvironment('NIKODESK'));
}
