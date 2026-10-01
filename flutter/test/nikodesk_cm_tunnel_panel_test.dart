import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/nikodesk/cm_tunnel.dart';
import 'package:flutter_hbb/nikodesk/cm_tunnel_panel.dart';
import 'package:flutter_hbb/nikodesk/theme.dart';
import 'package:flutter_hbb/nikodesk/ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'nikodesk_cm_tunnel_test.dart'
    show tunnelStatus, tunnelModel, tunnelQueued, resolvedTunnel;

Widget _host(NikoCmTunnelModel model, {bool dark = false, double scale = 1}) =>
    MaterialApp(
        theme: nikoTheme(dark ? Brightness.dark : Brightness.light),
        home: Builder(
            builder: (context) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(scale)),
                child: Scaffold(
                    body: SingleChildScrollView(
                        child: NikoCmTunnelPanel(model: model))))));
Future<void> _choose(WidgetTester tester, String address) async {
  final field = find.byKey(const ValueKey('niko-tunnel-address'));
  await tester.ensureVisible(field);
  await tester.tap(field);
  await tester.pumpAndSettle();
  await tester.tap(find.text(address).last);
  await tester.pumpAndSettle();
}

Future<void> _openApproval(WidgetTester tester) async {
  final approve = find.byKey(const ValueKey('niko-tunnel-approve'));
  await tester.ensureVisible(approve);
  await tester.tap(approve);
  await tester.pumpAndSettle();
}

void main() {
  tearDown(() => NikoLanguage.english = false);
  testWidgets('opening the panel sends no query, DNS request or approval',
      (tester) async {
    final sent = <NikoTunnelCommand>[];
    final model = tunnelModel(tunnelStatus(), transport: (command) async {
      sent.add(command);
      return tunnelQueued(command);
    });
    addTearDown(model.dispose);
    await tester.pumpWidget(_host(model));
    await tester.pumpAndSettle();
    expect(sent, isEmpty);
    expect(find.byKey(const ValueKey('niko-tunnel-approve')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('niko-tunnel-resolve')));
    await tester.pumpAndSettle();
    expect(sent.single.op, 'resolve');
    expect(find.text('所选目标连接已建立'), findsNothing);
    expect(find.text('请求已排队，等待本机状态确认。'), findsOneWidget);
  });
  testWidgets(
      'manual address and local confirmation are required, with cancel inert',
      (tester) async {
    final sent = <NikoTunnelCommand>[];
    final model = tunnelModel(resolvedTunnel(), transport: (command) async {
      sent.add(command);
      return tunnelQueued(command);
    });
    addTearDown(model.dispose);
    await tester.pumpWidget(_host(model));
    expect(
        tester
            .widget<FilledButton>(
                find.byKey(const ValueKey('niko-tunnel-approve')))
            .onPressed,
        isNull);
    await _choose(tester, '127.0.0.1:23456');
    await _openApproval(tester);
    expect(find.textContaining('127.0.0.1:23456'), findsWidgets);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(sent, isEmpty);
    await _openApproval(tester);
    await tester.tap(find.byKey(const ValueKey('niko-tunnel-confirm')));
    await tester.pumpAndSettle();
    expect(sent.single.op, 'approve');
    expect(sent.single.toJson()['address'], '127.0.0.1:23456');
    expect(sent.single.toJson()['access'], 'loopback');
    expect(model.status.phase, 'Pending');
    expect(find.text('所选目标连接已建立'), findsNothing);
  });
  testWidgets(
      'nonloopback is unchecked and must be explicitly allowed each selection',
      (tester) async {
    final sent = <NikoTunnelCommand>[];
    final model = tunnelModel(
        resolvedTunnel(addresses: ['10.0.0.7:23456', '10.0.0.8:23456']),
        transport: (command) async {
      sent.add(command);
      return tunnelQueued(command);
    });
    addTearDown(model.dispose);
    await tester.pumpWidget(_host(model));
    await _choose(tester, '10.0.0.7:23456');
    final checkbox = find.byKey(const ValueKey('niko-tunnel-non-loopback'));
    expect(tester.widget<CheckboxListTile>(checkbox).value, isFalse);
    expect(
        tester
            .widget<FilledButton>(
                find.byKey(const ValueKey('niko-tunnel-approve')))
            .onPressed,
        isNull);
    await tester.ensureVisible(checkbox);
    await tester.tap(checkbox);
    await tester.pumpAndSettle();
    await _choose(tester, '10.0.0.8:23456');
    expect(tester.widget<CheckboxListTile>(checkbox).value, isFalse);
    await tester.ensureVisible(checkbox);
    await tester.tap(checkbox);
    await tester.pumpAndSettle();
    await _openApproval(tester);
    await tester.tap(find.byKey(const ValueKey('niko-tunnel-confirm')));
    await tester.pumpAndSettle();
    expect(sent.single.address!.value, '10.0.0.8:23456');
    expect(sent.single.toJson()['access'], 'non_loopback');
  });
  testWidgets(
      'a newer native revision while confirmation is open cancels dispatch',
      (tester) async {
    final sent = <NikoTunnelCommand>[];
    final model = tunnelModel(resolvedTunnel(), transport: (command) async {
      sent.add(command);
      return tunnelQueued(command);
    });
    addTearDown(model.dispose);
    await tester.pumpWidget(_host(model));
    await _choose(tester, '127.0.0.1:23456');
    await _openApproval(tester);
    model.applyStatus(resolvedTunnel(revision: '3'));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('niko-tunnel-confirm')));
    await tester.pumpAndSettle();
    expect(sent, isEmpty);
  });
  testWidgets('timeout cleanup latch survives panel removal and reconstruction',
      (tester) async {
    final model = tunnelModel(tunnelStatus(phase: 'RecoveryRequired'),
        cleanupOnly: true,
        timeout: const Duration(milliseconds: 10),
        transport: (_) => Completer<String>().future);
    addTearDown(model.dispose);
    await tester.pumpWidget(_host(model));
    await tester
        .ensureVisible(find.byKey(const ValueKey('niko-tunnel-retry_cleanup')));
    await tester.tap(find.byKey(const ValueKey('niko-tunnel-retry_cleanup')));
    await tester.pump(const Duration(milliseconds: 20));
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(_host(model));
    expect(model.cleanupUnconfirmed, isTrue);
    expect(find.byKey(const ValueKey('niko-tunnel-resolve')), findsNothing);
    expect(find.byKey(const ValueKey('niko-tunnel-address')), findsNothing);
    expect(find.byKey(const ValueKey('niko-tunnel-approve')), findsNothing);
    expect(find.text('隧道已确认停止'), findsNothing);
    expect(find.byKey(const ValueKey('niko-tunnel-retry_cleanup')),
        findsOneWidget);
  });
  testWidgets(
      'native Starting is waiting and only actual Running shows established',
      (tester) async {
    final model = tunnelModel(tunnelStatus(
        phase: 'Starting',
        revision: '3',
        reason: 'awaiting_first_owned_socket',
        addresses: ['127.0.0.1:23456'],
        selected: '127.0.0.1:23456'));
    addTearDown(model.dispose);
    await tester.pumpWidget(_host(model));
    expect(find.text('等待实际目标连接'), findsOneWidget);
    expect(find.text('所选目标连接已建立'), findsNothing);
    model.applyStatus(tunnelStatus(
        phase: 'Running',
        revision: '4',
        reason: 'running',
        addresses: ['127.0.0.1:23456'],
        selected: '127.0.0.1:23456'));
    await tester.pump();
    expect(find.text('所选目标连接已建立'), findsOneWidget);
  });
  testWidgets('keyboard actions have native button semantics and 48px targets',
      (tester) async {
    final semantics = tester.ensureSemantics();
    try {
      final sent = <NikoTunnelCommand>[];
      final model = tunnelModel(tunnelStatus(), transport: (command) async {
        sent.add(command);
        return tunnelQueued(command);
      });
      addTearDown(model.dispose);
      await tester.pumpWidget(_host(model));
      for (final key in ['resolve', 'query']) {
        final control = find.byKey(ValueKey('niko-tunnel-$key'));
        expect(tester.getSize(control).height, greaterThanOrEqualTo(48));
        expect(tester.getSemantics(control).hasFlag(SemanticsFlag.isButton),
            isTrue);
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(sent.single.op, 'resolve');
    } finally {
      semantics.dispose();
    }
  });
  for (final english in [false, true]) {
    for (final dark in [false, true]) {
      testWidgets(
          '320px 200% ${english ? 'English' : 'Chinese'} ${dark ? 'dark' : 'light'} selection and cleanup fit',
          (tester) async {
        tester.view.physicalSize = const Size(320, 720);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        NikoLanguage.english = english;
        final model = tunnelModel(resolvedTunnel(
            addresses: ['[2001:db8:1234:5678:9abc:def0:1234:5678]:23456']));
        addTearDown(model.dispose);
        await tester.pumpWidget(_host(model, dark: dark, scale: 2));
        await _choose(tester, '[2001:db8:1234:5678:9abc:def0:1234:5678]:23456');
        expect(tester.takeException(), isNull);
        final box = find.byKey(const ValueKey('niko-tunnel-non-loopback'));
        await tester.ensureVisible(box);
        expect(tester.getSize(box).height, greaterThanOrEqualTo(48));
        expect(tester.takeException(), isNull);
        await tester.tap(box);
        await tester.pumpAndSettle();
        await _openApproval(tester);
        expect(tester.takeException(), isNull);
        final cancel = find.text(english ? 'Cancel' : '取消');
        await tester.ensureVisible(cancel);
        await tester.tap(cancel);
        await tester.pumpAndSettle();
        expect(model.approvalUnconfirmed, isFalse);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        final cleanup = tunnelModel(
            tunnelStatus(
                phase: 'RecoveryRequired', reason: 'writer_drain_unconfirmed'),
            cleanupOnly: true);
        addTearDown(cleanup.dispose);
        await tester.pumpWidget(_host(cleanup, dark: dark, scale: 2));
        await tester.ensureVisible(
            find.byKey(const ValueKey('niko-tunnel-retry_cleanup')));
        expect(tester.takeException(), isNull);
      });
    }
  }
}
