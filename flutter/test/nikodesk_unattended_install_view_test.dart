import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/nikodesk/theme.dart';
import 'package:flutter_hbb/nikodesk/ui.dart';
import 'package:flutter_hbb/nikodesk/unattended_install_view.dart';
import 'package:flutter_test/flutter_test.dart';

import 'nikodesk_unattended_install_test.dart'
    show
        InstallTransportDouble,
        installModel,
        installReply,
        installComplete,
        installJob,
        otherInstallJob,
        installNoDispatch;

Future<void> _host(WidgetTester tester, Widget child,
    {bool english = false, bool dark = false}) async {
  NikoLanguage.english = english;
  tester.view.physicalSize = const Size(320, 700);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(
      theme: nikoTheme(dark ? Brightness.dark : Brightness.light),
      builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(2)),
          child: child!),
      home: Scaffold(
          body: SingleChildScrollView(
              child:
                  Padding(padding: const EdgeInsets.all(16), child: child)))));
  await tester.pumpAndSettle();
}

void main() {
  tearDown(() => NikoLanguage.english = false);
  testWidgets(
      'password change requires matching entries and keeps resume off at 320/200%',
      (tester) async {
    final transport = InstallTransportDouble()
      ..onCurrent = () async => installComplete();
    transport.onBegin = (_) async =>
        installReply(job: otherInstallJob, action: 'change_password');
    final model = installModel(transport);
    addTearDown(model.dispose);
    await _host(
        tester,
        NikoUnattendedInstallView(
            model: model,
            initialSetup: r'C:\setup.exe',
            pollInterval: const Duration(days: 1)));
    final change = find.byKey(const Key('unattended-change_password'));
    await tester.ensureVisible(change);
    await tester.tap(change);
    await tester.pumpAndSettle();
    final password = find.byKey(const Key('unattended-new-password'));
    final confirmation = find.byKey(const Key('unattended-confirm-password'));
    final confirm = find.byKey(const Key('unattended-confirm-password-change'));
    expect(tester.widget<TextField>(password).obscureText, true);
    expect(tester.widget<TextField>(confirmation).obscureText, true);
    expect(
        tester
            .widget<CheckboxListTile>(
                find.byKey(const Key('unattended-password-resume')))
            .value,
        false);
    await tester.ensureVisible(password);
    await tester.enterText(password, 'synthetic-new-password');
    await tester.ensureVisible(confirmation);
    await tester.enterText(confirmation, 'different');
    await tester.ensureVisible(confirm);
    await tester.tap(confirm);
    await tester.pumpAndSettle();
    expect(transport.requests, isEmpty);
    expect(find.text('两次输入的密码不同。'), findsOneWidget);
    await tester.ensureVisible(confirmation);
    await tester.enterText(confirmation, 'synthetic-new-password');
    await tester.ensureVisible(confirm);
    await tester.tap(confirm);
    await tester.pumpAndSettle();
    expect(transport.requests.single['action'], 'change_password');
    expect(transport.requests.single['password'], 'synthetic-new-password');
    expect(transport.requests.single['start_after_commit'], false);
    expect(model.operationConfirmed, false);
    expect(password, findsNothing);
    expect(confirmation, findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('cancelling password change discards both entries',
      (tester) async {
    final transport = InstallTransportDouble()
      ..onCurrent = () async => installComplete();
    final model = installModel(transport);
    addTearDown(model.dispose);
    await _host(
        tester,
        NikoUnattendedInstallView(
            model: model,
            initialSetup: r'C:\setup.exe',
            pollInterval: const Duration(days: 1)));
    final change = find.byKey(const Key('unattended-change_password'));
    await tester.ensureVisible(change);
    await tester.tap(change);
    await tester.pumpAndSettle();
    final password = find.byKey(const Key('unattended-new-password'));
    await tester.ensureVisible(password);
    await tester.enterText(password, 'synthetic-secret-to-discard');
    final cancel = find.widgetWithText(TextButton, '取消');
    await tester.ensureVisible(cancel);
    await tester.tap(cancel);
    await tester.pumpAndSettle();
    expect(transport.requests, isEmpty);
    await tester.ensureVisible(change);
    await tester.tap(change);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(password).controller!.text, isEmpty);
    expect(
        tester
            .widget<TextField>(
                find.byKey(const Key('unattended-confirm-password')))
            .controller!
            .text,
        isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
      'machine policy changes require explicit complete choices with restart off by default',
      (tester) async {
    final transport = InstallTransportDouble()
      ..onCurrent = () async => installComplete();
    transport.onBegin =
        (_) async => installReply(job: otherInstallJob, action: 'configure');
    final model = installModel(transport);
    addTearDown(model.dispose);
    await _host(
        tester,
        NikoUnattendedInstallView(
            model: model,
            initialSetup: r'C:\setup.exe',
            pollInterval: const Duration(days: 1)));
    final configure = find.byKey(const Key('unattended-configure'));
    await tester.ensureVisible(configure);
    await tester.tap(configure);
    await tester.pumpAndSettle();
    expect(transport.requests, isEmpty);
    final privacy = find.byKey(const Key('unattended-policy-privacy'));
    await tester.ensureVisible(privacy);
    await tester.tap(privacy);
    await tester.pumpAndSettle();
    final confirm = find.byKey(const Key('unattended-confirm-maintenance'));
    await tester.ensureVisible(confirm);
    await tester.tap(confirm);
    await tester.pumpAndSettle();
    expect(transport.requests.single['action'], 'configure');
    expect(transport.requests.single['allow_privacy'], true);
    expect(transport.requests.single['allow_virtual_display'], false);
    expect(transport.requests.single['lock_on_disconnect'], false);
    expect(transport.requests.single['allow_remote_restart'], false);
    expect(transport.requests.single['start_after_commit'], false);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
      'removal requires explicit local confirmation and does not present the removed identity as usable',
      (tester) async {
    final transport = InstallTransportDouble()
      ..onCurrent = () async => installComplete();
    transport.onBegin =
        (_) async => installReply(job: otherInstallJob, action: 'remove');
    final model = installModel(transport);
    addTearDown(model.dispose);
    await _host(
        tester,
        NikoUnattendedInstallView(
            model: model,
            initialSetup: r'C:\setup.exe',
            pollInterval: const Duration(days: 1)));
    final remove = find.byKey(const Key('unattended-remove'));
    await tester.ensureVisible(remove);
    await tester.tap(remove);
    await tester.pumpAndSettle();
    expect(transport.requests, isEmpty);
    final confirm = find.byKey(const Key('unattended-confirm-maintenance'));
    await tester.ensureVisible(confirm);
    await tester.tap(confirm);
    await tester.pumpAndSettle();
    expect(transport.requests.single['action'], 'remove');
    expect(transport.requests.single['password'], '');
    transport.onStatus = (_) async => installReply(
        job: otherInstallJob,
        action: 'remove',
        phase: 'complete',
        reason: 'complete',
        quiescent: true,
        processExited: true,
        taskJoined: true);
    await model.refresh();
    await tester.pumpAndSettle();
    expect(find.text('服务和机器身份已卸载'), findsOneWidget);
    expect(find.textContaining('原机器 ID 和密码已失效'), findsOneWidget);
    expect(find.text('复制机器 ID'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
      'actual no-dispatch proof permits explicit new installer selection and default-off restart',
      (tester) async {
    final transport = InstallTransportDouble()
      ..onCurrent = () async => installNoDispatch();
    transport.onBegin = (_) async => installReply(job: otherInstallJob);
    final model = installModel(transport);
    addTearDown(model.dispose);
    await _host(
        tester,
        NikoUnattendedInstallView(
            model: model,
            pollInterval: const Duration(days: 1),
            pickSetup: () async => r'C:\corrected-setup.exe'));
    expect(find.text('安装程序未启动'), findsOneWidget);
    expect(find.byKey(const Key('unattended-cancel')), findsNothing);
    final choose = find.byKey(const Key('unattended-choose-setup'));
    await tester.ensureVisible(choose);
    await tester.tap(choose);
    await tester.pumpAndSettle();
    final password = find.byKey(const Key('unattended-password'));
    await tester.ensureVisible(password);
    await tester.enterText(password, 'synthetic');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(
        transport.requests.single['selected_setup'], r'C:\corrected-setup.exe');
    expect(transport.requests.single['start_after_commit'], false);
    expect(model.reply!.jobId, otherInstallJob);
    expect(model.installConfirmed, false);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
      'native unsupported reply disables the installer picker as well as Begin',
      (tester) async {
    final transport = InstallTransportDouble()
      ..onCurrent = () async => installReply(
          ok: false,
          job: '',
          namespace: '',
          phase: 'idle',
          reason: 'unsupported');
    final model = installModel(transport);
    addTearDown(model.dispose);
    var picks = 0;
    await _host(
        tester,
        NikoUnattendedInstallView(
            model: model,
            pollInterval: const Duration(days: 1),
            pickSetup: () async {
              picks++;
              return r'C:\setup.exe';
            }));
    expect(find.byKey(const Key('unattended-begin')), findsNothing);
    expect(find.byKey(const Key('unattended-choose-setup')), findsNothing);
    expect(picks, 0);
    expect(transport.requests, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });
  for (final english in [false, true]) {
    for (final dark in [false, true]) {
      testWidgets(
          'explicit installer/password keyboard flow 320/200% en=$english dark=$dark',
          (tester) async {
        final semantics = tester.ensureSemantics();
        final transport = InstallTransportDouble();
        final model = installModel(transport);
        addTearDown(model.dispose);
        var picked = 0;
        await _host(
            tester,
            NikoUnattendedInstallView(
                model: model,
                pollInterval: const Duration(days: 1),
                pickSetup: () async {
                  picked++;
                  return r'C:\synthetic\NikoDesk-setup.exe';
                }),
            english: english,
            dark: dark);
        expect(transport.calls, ['current']);
        expect(picked, 0);
        final begin = find.byKey(const Key('unattended-begin'));
        expect(tester.widget<FilledButton>(begin).onPressed, isNull);
        final start = find.byKey(const Key('unattended-start'));
        expect(tester.widget<CheckboxListTile>(start).value, false);
        final choose = find.byKey(const Key('unattended-choose-setup'));
        await tester.ensureVisible(choose);
        expect(tester.getSize(choose).height, greaterThanOrEqualTo(48));
        await tester.tap(choose);
        await tester.pumpAndSettle();
        expect(picked, 1);
        expect(transport.requests, isEmpty);
        final password = find.byKey(const Key('unattended-password'));
        await tester.ensureVisible(password);
        await tester.enterText(password, 'synthetic');
        await tester.pumpAndSettle();
        expect(tester.widget<TextField>(password).obscureText, true);
        expect(tester.widget<FilledButton>(begin).onPressed, isNotNull);
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pumpAndSettle();
        expect(transport.requests, hasLength(1));
        expect(transport.requests.single['start_after_commit'], false);
        expect(model.installConfirmed, false);
        expect(find.byKey(const Key('unattended-password')), findsNothing);
        expect(find.textContaining(english ? 'request queued' : '已排队'),
            findsOneWidget);
        final cancel = find.byKey(const Key('unattended-cancel'));
        await tester.ensureVisible(cancel);
        expect(tester.getSize(cancel).height, greaterThanOrEqualTo(48));
        expect(tester.getSemantics(cancel).label,
            contains(english ? 'Request cancellation' : '请求取消安装'));
        await tester.tap(cancel);
        await tester.pumpAndSettle();
        expect(transport.calls.last, 'cancel:$installJob');
        expect(model.installConfirmed, false);
        expect(model.hasJob, true);
        expect(
            find.textContaining(
                english ? 'Cancellation was requested' : '取消请求已发送'),
            findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        semantics.dispose();
      });
    }
  }
  testWidgets(
      'unsupported platform has no installation controls and no native or picker calls',
      (tester) async {
    final transport = InstallTransportDouble();
    final model = installModel(transport, supported: false);
    addTearDown(model.dispose);
    var picks = 0;
    await _host(
        tester,
        NikoUnattendedInstallView(
            model: model,
            pickSetup: () async {
              picks++;
              return null;
            }));
    expect(find.byKey(const Key('unattended-begin')), findsNothing);
    expect(find.byKey(const Key('unattended-choose-setup')), findsNothing);
    expect(transport.calls, isEmpty);
    expect(picks, 0);
    expect(find.textContaining('仅支持 Windows 本机'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
      'empty Current is not a claim that Windows system service is absent',
      (tester) async {
    final transport = InstallTransportDouble();
    final model = installModel(transport);
    addTearDown(model.dispose);
    await _host(
        tester,
        NikoUnattendedInstallView(
            model: model, pollInterval: const Duration(days: 1)));
    expect(find.text('本进程暂无安装任务'), findsOneWidget);
    expect(find.text('这不是对系统服务是否已安装的判断。'), findsOneWidget);
    expect(transport.requests, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
      'unknown submission clears visible password and cannot resubmit after rebuilding',
      (tester) async {
    final never = Completer<String>();
    final transport = InstallTransportDouble()..onBegin = (_) => never.future;
    final model =
        installModel(transport, timeout: const Duration(milliseconds: 20));
    addTearDown(model.dispose);
    NikoUnattendedInstallView view() => NikoUnattendedInstallView(
        model: model,
        pollInterval: const Duration(days: 1),
        pickSetup: () async => r'C:\setup.exe');
    await tester.pumpWidget(const SizedBox());
    await _host(tester, view());
    final choose = find.byKey(const Key('unattended-choose-setup'));
    await tester.ensureVisible(choose);
    await tester.tap(choose);
    await tester.pumpAndSettle();
    final password = find.byKey(const Key('unattended-password'));
    await tester.ensureVisible(password);
    await tester.enterText(password, 'synthetic');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump(const Duration(milliseconds: 30));
    await tester.pumpAndSettle();
    expect(model.uncertain, true);
    expect(transport.requests, hasLength(1));
    expect(tester.widget<TextField>(password).controller!.text, isEmpty);
    await _host(tester, view());
    expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('unattended-begin')))
            .onPressed,
        isNull);
    never.complete(installComplete());
    await tester.pumpAndSettle();
    expect(model.installConfirmed, false);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
      'Current restores previous server task; timeout retains cancel and status actions',
      (tester) async {
    final transport = InstallTransportDouble()
      ..onCurrent = () async => installReply();
    final model = installModel(transport,
        currentNamespace: () => 'b' * 64,
        timeout: const Duration(milliseconds: 20));
    addTearDown(model.dispose);
    await _host(
        tester,
        NikoUnattendedInstallView(
            model: model, pollInterval: const Duration(days: 1)));
    expect(find.byKey(const Key('unattended-begin')), findsNothing);
    expect(find.textContaining('此前私服下的安装任务'), findsOneWidget);
    final never = Completer<String>();
    transport.onCancel = (_) => never.future;
    final cancel = find.byKey(const Key('unattended-cancel'));
    await tester.ensureVisible(cancel);
    await tester.tap(cancel);
    await tester.pump(const Duration(milliseconds: 30));
    await tester.pumpAndSettle();
    expect(find.text('安装结果尚未确认'), findsOneWidget);
    expect(model.hasJob, true);
    expect(tester.widget<OutlinedButton>(cancel).onPressed, isNotNull);
    expect(tester.takeException(), isNull);
    never.complete(installReply(reason: 'cancel_requested'));
    await tester.pumpAndSettle();
    expect(model.uncertain, true);
    await tester.pumpWidget(const SizedBox());
  });
}
