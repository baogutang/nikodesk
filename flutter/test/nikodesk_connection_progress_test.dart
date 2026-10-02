import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/nikodesk/connection_progress.dart';
import 'package:flutter_hbb/nikodesk/connection_progress_view.dart';
import 'package:flutter_hbb/nikodesk/theme.dart';
import 'package:flutter_hbb/nikodesk/ui.dart';

void main() {
  late NikoConnectionProgress progress;
  setUp(() => progress = NikoConnectionProgress());
  tearDown(() {
    progress.dispose();
    NikoLanguage.english = false;
  });

  // Event sequences exercise presentation, not native remote acceptance.
  test('transport, cached identity and early video cannot prove authentication', () {
    progress.begin();
    progress.transportReady();
    progress.authenticated(expectsFrame: true, fromCache: true);
    progress.frameReceived();
    expect(progress.value.phase, NikoConnectionPhase.authenticating);
    progress.authenticated(expectsFrame: true);
    expect(progress.value.phase, NikoConnectionPhase.waitingForFrame);
    progress.frameReceived();
    expect(progress.value.phase, NikoConnectionPhase.connected);
  });

  test('late transport updates retain approval or credential requirements', () {
    progress.begin();
    progress.message('wait-remote-accept-nook', 'Wait for the remote to accept');
    progress.transportReady();
    expect(progress.value.phase, NikoConnectionPhase.waitingForApproval);
    progress.message('input-2fa', 'Authentication');
    progress.transportReady();
    expect(progress.value.phase, NikoConnectionPhase.waitingForCredentials);
    expect(progress.value.pending, isFalse);
    progress.credentialsSubmitted();
    expect(progress.value.phase, NikoConnectionPhase.authenticating);
  });

  test('failure preserves the last observed stage despite late events', () {
    progress.begin();
    progress.transportReady();
    progress.authenticated(expectsFrame: true);
    progress.message('error', 'Connection Error');
    progress.transportReady();
    progress.authenticated(expectsFrame: true);
    progress.frameReceived();
    progress.message('error', 'Disconnected');
    expect(progress.value.phase, NikoConnectionPhase.failed);
    expect(progress.value.failedAt, NikoConnectionPhase.waitingForFrame);
  });

  test('reconnect cannot reuse previous authentication or video completion', () {
    progress.begin();
    progress.authenticated(expectsFrame: true);
    progress.frameReceived();
    progress.begin(reconnecting: true);
    progress.frameReceived();
    expect(progress.value.phase, NikoConnectionPhase.reconnecting);
    progress.authenticated(expectsFrame: true, fromCache: true);
    expect(progress.value.phase, NikoConnectionPhase.reconnecting);
    progress.authenticated(expectsFrame: true);
    expect(progress.value.phase, NikoConnectionPhase.waitingForFrame);
  });

  test('nonvisual authentication never claims remote video or operation success', () {
    progress.begin();
    progress.authenticated(expectsFrame: false);
    progress.frameReceived();
    expect(progress.value.phase, NikoConnectionPhase.authenticated);
    expect(progress.value.pending, isFalse);
  });

  test('capability errors do not turn an established control session into failure', () {
    progress.begin();
    progress.authenticated(expectsFrame: true);
    progress.frameReceived();
    progress.message('error', 'Credential storage');
    progress.message('elevation-error', 'Prompt');
    expect(progress.value.phase, NikoConnectionPhase.connected);
  });

  test('close ignores late progress and authentication events', () {
    progress.begin();
    progress.close();
    progress.transportReady();
    progress.authenticated(expectsFrame: true);
    progress.message('wait-remote-accept-nook', 'Prompt');
    progress.frameReceived();
    expect(progress.value.phase, NikoConnectionPhase.closed);
  });

  for (final english in [false, true]) {
    for (final brightness in [Brightness.light, Brightness.dark]) {
      testWidgets('connection stages and cancel fit 320/200% ($english, $brightness)',
          (tester) async {
        NikoLanguage.english = english;
        await tester.binding.setSurfaceSize(const Size(320, 700));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final semantics = tester.ensureSemantics();
        var cancelled = 0;
        progress.begin();
        await tester.pumpWidget(MaterialApp(
          theme: nikoTheme(brightness),
          builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(2)),
              child: child!),
          home: Scaffold(body: nikoConnectionProgressDialog(
              progress, onCancel: () => cancelled++)),
        ));
        await tester.pump();
        expect(find.text(english ? 'Establishing connection' : '建立连接'), findsOneWidget);
        progress.authenticated(expectsFrame: true);
        await tester.pump();
        expect(find.text(english ? 'Waiting for remote video' : '等待远端画面'), findsOneWidget);
        final cancel = find.text(english ? 'Cancel connection' : '取消连接');
        await tester.ensureVisible(cancel);
        expect(tester.getSemantics(find.byType(OutlinedButton)).hasFlag(SemanticsFlag.isButton), isTrue);
        expect(tester.getSize(find.byType(OutlinedButton)).height, greaterThanOrEqualTo(48));
        await tester.tap(cancel);
        expect(cancelled, 1);
        expect(tester.takeException(), isNull);
        semantics.dispose();
        await tester.pump(const Duration(milliseconds: 1));
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(milliseconds: 1));
      });
    }
  }

  testWidgets('error context identifies the observed stage, not an invented cause',
      (tester) async {
    NikoLanguage.english = true;
    progress.begin();
    progress.transportReady();
    progress.fail();
    await tester.pumpWidget(MaterialApp(home: Scaffold(body:
        NikoConnectionFailureContext(state: progress.value))));
    expect(find.text('Last observed stage: Verifying remote identity'), findsOneWidget);
    expect(find.textContaining('password'), findsNothing);
  });
}
