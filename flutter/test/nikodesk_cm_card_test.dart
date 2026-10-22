import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/desktop/pages/server_page.dart';
import 'package:flutter_hbb/models/native_model.dart';
import 'package:flutter_hbb/models/server_model.dart';
import 'package:flutter_hbb/nikodesk/cm_capability_frame.dart';
import 'package:flutter_hbb/nikodesk/cm_permissions.dart';
import 'package:flutter_hbb/nikodesk/nightline.dart';
import 'package:flutter_hbb/nikodesk/ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'nikodesk_cm_tunnel_client_test.dart' show tunnelClient;
import 'support/nikodesk_fake_bridge.dart';

// The connection manager card as server_page.dart builds it, over an
// in-memory bridge: which actions end the connection, and that a tunnel's
// panel sits in the Nightline frame.
void main() {
  const nikodesk = bool.fromEnvironment('NIKODESK');

  setUpAll(() async {
    PlatformFFI.instance.ffiBindForTesting = NikoFakeBridge()
      ..appName = nikodesk ? 'NikoDesk' : 'RustDesk';
    await initGlobalFFI();
  });
  setUp(() => NikoLanguage.english = true);
  tearDown(() {
    NikoLanguage.english = false;
    gFFI.serverModel.clients.clear();
  });

  Future<void> load(WidgetTester tester, Client client) async {
    await tester.binding.setSurfaceSize(const Size(300, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
        theme: nightlineTheme(Brightness.dark),
        home: Scaffold(
            body: ChangeNotifierProvider<ServerModel>.value(
                value: gFFI.serverModel, child: buildConnectionCard(client)))));
    await tester.pump();
  }

  testWidgets('Disconnect is the destructive action of a control session',
      (tester) async {
    final client = Client(
        1, true, false, false, 'Studio Mac', '418223905', true, true, false);
    gFFI.serverModel.clients.add(client);
    await load(tester, client);
    if (nikodesk) {
      // The card passes redAccent for Disconnect; it drew as the accent.
      final disconnect = tester.widget<NikoCmActionButton>(
          find.widgetWithText(NikoCmActionButton, 'Disconnect'));
      expect(disconnect.danger, isTrue);
    } else {
      expect(find.byType(NikoCmActionButton), findsNothing);
      expect(find.text('Disconnect'), findsOneWidget);
    }
    expect(tester.takeException(), isNull);
  });

  if (nikodesk) {
    testWidgets('a tunnel card frames its panel and leaves destructively',
        (tester) async {
      // A new tab raises the window and later minimises it; a test has no
      // window, so keep the window hidden and drop the minimise timer.
      gFFI.serverModel.hideCm = true;
      addTearDown(() => gFFI.serverModel.hideCm = false);
      gFFI.serverModel.addConnection({'client': jsonEncode(tunnelClient())});
      gFFI.serverModel.cmHiddenTimer?.cancel();
      final client = gFFI.serverModel.clients.single;
      await load(tester, client);
      // The tab bar's own jump runs 100 ms later.
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byType(NikoCmCapabilityFrame), findsOneWidget);
      expect(find.text('LOCAL TUNNEL APPROVAL'), findsOneWidget);
      final leave = tester.widget<NikoCmActionButton>(
          find.widgetWithText(NikoCmActionButton, 'Leave connection'));
      expect(leave.danger, isTrue);
      expect(tester.getSize(find.byType(NikoCmActionButton)).width,
          greaterThan(260),
          reason: 'leaving spans the card, as Disconnect does');
      expect(tester.takeException(), isNull);
    });
  }
}
