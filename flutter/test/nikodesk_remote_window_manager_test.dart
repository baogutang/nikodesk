import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/main.dart' as app;
import 'package:flutter_hbb/nikodesk/remote_window_scope.dart';
import 'package:flutter_hbb/utils/multi_window_manager.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('mixin.one/flutter_multi_window_channel');
  final a = 'a' * 64;
  final b = 'b' * 64;
  const peer = '1000000001';
  Map<String, dynamic> geometry(int window, String namespace,
          {String id = peer}) =>
      {
        ...NikoRemoteWindowIdentity(window, id, namespace).toJson(),
        'windowRect': {'l': 100.0, 't': 0.0, 'w': 600.0, 'h': 400.0},
        'remoteRect': {'l': 0.0, 't': 0.0, 'w': 1920.0, 'h': 1080.0},
        'canvas': {
          'x': 0.0,
          'y': 0.0,
          'scale': 1.0,
          'scrollX': 0.0,
          'scrollY': 0.0,
          'scrollStyle': 'scrollauto',
          'size': {'w': 600.0, 'h': 400.0},
        },
        'cursor': {'offset_x': 0.0, 'offset_y': 0.0},
      };
  int? previousWindow;
  setUp(() {
    previousWindow = app.kWindowId;
    app.kWindowId = 1;
  });
  tearDown(() {
    app.kWindowId = previousWindow;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  if (!const bool.fromEnvironment('NIKODESK')) {
    test('feature-off retains the upstream window-id RPC and geometry decoder',
        () async {
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return jsonEncode([jsonEncode(geometry(2, b))]);
      });
      final result =
          await rustDeskWinManager.getOtherRemoteWindowCoordsFromMain();
      expect(calls.single.method, kWindowEventRemoteWindowCoords);
      expect(calls.single.arguments, {'targetWindowId': 0, 'arguments': '1'});
      expect(result.single.remoteRect.width, 1920.0);
    });
  } else {
    test(
        'Niko production window RPC sends the captured identity and filters replies',
        () async {
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return jsonEncode([
          jsonEncode(geometry(2, a)),
          jsonEncode(geometry(3, b)),
          jsonEncode(geometry(4, a, id: '1000000002')),
          jsonEncode(geometry(1, a)),
        ]);
      });
      final result = await rustDeskWinManager
          .getOtherRemoteWindowCoordsFromMain(peerId: peer, serverNamespace: a);
      expect(calls.single.arguments['targetWindowId'], 0);
      final request =
          NikoRemoteWindowIdentity.parse(calls.single.arguments['arguments']);
      expect(request?.windowId, 1);
      expect(request?.peerId, peer);
      expect(request?.namespace, a);
      expect(result, hasLength(1));
      expect(result.single.remoteRect.width, 1920.0);
    });

    test('Niko production query refuses unknown identity before the RPC',
        () async {
      var calls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) async {
        calls++;
        return '[]';
      });
      expect(
          await rustDeskWinManager.getOtherRemoteWindowCoordsFromMain(
              peerId: peer),
          isEmpty);
      expect(calls, 0);
    });

    test('Niko production query treats a closed main window as empty',
        () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) async {
        throw PlatformException(code: 'closed');
      });
      expect(
          await rustDeskWinManager.getOtherRemoteWindowCoordsFromMain(
              peerId: peer, serverNamespace: a),
          isEmpty);
    });
  }
}
