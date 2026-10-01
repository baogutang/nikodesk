import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/nikodesk/virtual_driver.dart';
import 'package:flutter_hbb/nikodesk/virtual_driver_settings.dart';

final scope = 'a' * 64;
const id = '0848eceb-0821-41c1-8576-afbb230ab5bb';
String reply(
        {String? namespace,
        String job = '',
        String phase = 'idle',
        bool ok = false,
        bool joined = false,
        String reason = 'unchecked'}) =>
    jsonEncode({
      'ok': ok,
      'namespace': namespace ?? scope,
      'job_id': job,
      'phase': phase,
      'reason': reason,
      'elevated': true,
      'os_supported': true,
      'joined': joined
    });

void main() {
  test('a foreign INF is rejected before native dispatch', () async {
    var calls = 0;
    final model = NikoVirtualDriver(
        command: (_) async {
          calls++;
          return reply();
        },
        currentNamespace: () => scope);
    await model.refresh();
    await model.install(r'C:\selected\RustDeskIddDriver.inf');
    expect(calls, 1);
    expect(model.notice, 'invalid_request');
    expect(model.uncertain, false);
    model.dispose();
  });
  test('ready requires the native job to finish and join', () async {
    var response = reply();
    final model = NikoVirtualDriver(
        command: (_) async => response, currentNamespace: () => scope);
    await model.refresh();
    expect(model.canBegin, true);
    response = reply(job: id, phase: 'ready', ok: true, reason: '');
    await model.probe();
    expect(model.reply!.confirmed, false);
    expect(model.canBegin, false);
    response =
        reply(job: id, phase: 'ready', ok: true, joined: true, reason: '');
    await model.refresh();
    expect(model.reply!.confirmed, true);
    model.dispose();
  });
  test('a timed out installation cannot start a duplicate', () async {
    var calls = 0;
    final pending = Completer<String>();
    final model = NikoVirtualDriver(
        command: (raw) {
          calls++;
          return calls == 1 ? Future.value(reply()) : pending.future;
        },
        currentNamespace: () => scope,
        timeout: const Duration(milliseconds: 5));
    await model.refresh();
    await model.install(r'C:\selected\NikoDeskIddDriver.inf');
    expect(model.uncertain, true);
    await model.install(r'C:\selected\NikoDeskIddDriver.inf');
    expect(calls, 2);
    pending.complete(reply(job: id, phase: 'ready', ok: true, joined: true));
    model.dispose();
  });
  test('a response for the old server cannot confirm this server', () async {
    String current = scope;
    final pending = Completer<String>();
    final model = NikoVirtualDriver(
        command: (_) => pending.future, currentNamespace: () => current);
    final load = model.refresh();
    current = 'b' * 64;
    model.scopeChanged();
    pending.complete(reply(job: id, phase: 'ready', ok: true, joined: true));
    await load;
    expect(model.reply, isNull);
    expect(model.canBegin, false);
    model.dispose();
  });
  test('malformed or fabricated completion is rejected', () {
    final malformed = jsonDecode(reply()) as Map<String, dynamic>;
    malformed['ok'] = true;
    expect(NikoVirtualDriverReply.parse(jsonEncode(malformed)), isNull);
    malformed['ok'] = false;
    malformed['approved'] = true;
    expect(NikoVirtualDriverReply.parse(jsonEncode(malformed)), isNull);
    expect(NikoVirtualDriverReply.parse(reply(namespace: '0' * 64)), isNull);
  });
  testWidgets('driver settings fit a narrow view with larger text',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final model = NikoVirtualDriver(
        command: (_) async => reply(reason: 'catalog_trust_unconfirmed'),
        currentNamespace: () => scope);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: MediaQuery(
                data: const MediaQueryData(
                    size: Size(320, 1000), textScaler: TextScaler.linear(2)),
                child: SingleChildScrollView(
                    child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: NikoVirtualDriverSettings(model: model)))))));
    await tester.pumpAndSettle();
    expect(find.text('安装／修复驱动'), findsOneWidget);
    expect(find.textContaining('Windows 未确认签名'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    model.dispose();
  });
}
