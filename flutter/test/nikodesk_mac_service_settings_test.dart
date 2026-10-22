import 'package:flutter/material.dart';
import 'package:flutter_hbb/nikodesk/mac_background_agent.dart';
import 'package:flutter_hbb/nikodesk/mac_background_settings.dart';
import 'package:flutter_hbb/nikodesk/mac_service_settings.dart';
import 'package:flutter_test/flutter_test.dart';

class _Gateway extends NikoMacServiceGateway {
  NikoMacServiceState current;
  final String error;
  final calls = <bool>[];
  _Gateway(this.current, {this.error = ''});
  @override
  Future<NikoMacServiceState> state() async => current;
  @override
  Future<String> set(bool install) async {
    calls.add(install);
    if (error.isEmpty) {
      current = NikoMacServiceState(
          installed: install, appSigned: true, reachable: install);
    }
    return error;
  }
}

class _Agent extends NikoMacBackgroundAgent {
  @override
  Future<bool> configured() async => false;
  @override
  Future<bool> hasOwnedConfiguration() async => false;
}

Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
  await tester.pumpAndSettle();
}

void main() {
  test('the native state is read defensively', () {
    final state = NikoMacServiceState.parse(
        '{"installed":true,"app_signed":false,"reachable":true}');
    expect([state.installed, state.appSigned, state.reachable],
        [true, false, true]);
    expect(NikoMacServiceState.parse('not json').installed, isFalse);
    expect(NikoMacServiceState.parse('[]').installed, isFalse);
  });

  testWidgets('an unsigned copy explains why it cannot install',
      (tester) async {
    final gateway = _Gateway(const NikoMacServiceState());
    await _pump(tester, NikoMacServiceSettings(gateway: gateway));
    final install = tester.widget<FilledButton>(
        find.byKey(const Key('niko-mac-service-install')));
    expect(install.onPressed, isNull);
    expect(find.textContaining('证书签名'), findsOneWidget);
  });

  testWidgets('install, then remove, with the result shown', (tester) async {
    final gateway = _Gateway(const NikoMacServiceState(appSigned: true));
    await _pump(tester, NikoMacServiceSettings(gateway: gateway));
    await tester.tap(find.byKey(const Key('niko-mac-service-install')));
    await tester.pumpAndSettle();
    expect(gateway.calls, [true]);
    expect(find.text('已安装，运行正常'), findsOneWidget);
    await tester.tap(find.byKey(const Key('niko-mac-service-remove')));
    await tester.pumpAndSettle();
    expect(gateway.calls, [true, false]);
    expect(find.text('未安装'), findsOneWidget);
  });

  testWidgets('a cancelled administrator prompt changes nothing',
      (tester) async {
    final gateway = _Gateway(const NikoMacServiceState(appSigned: true),
        error: 'administrator_step_failed_or_cancelled');
    await _pump(tester, NikoMacServiceSettings(gateway: gateway));
    await tester.tap(find.byKey(const Key('niko-mac-service-install')));
    await tester.pumpAndSettle();
    expect(find.text('未安装'), findsOneWidget);
    expect(find.textContaining('已取消'), findsOneWidget);
  });

  testWidgets('background recovery defers to the system service',
      (tester) async {
    await _pump(
        tester,
        NikoMacBackgroundSettings(
            agent: _Agent(),
            permissionsGranted: () => true,
            systemServiceInstalled: () async => true));
    expect(find.byKey(const Key('niko-mac-background-by-service')),
        findsOneWidget);
    expect(find.byType(TextField), findsNothing);
  });
}
