import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/nikodesk/cm_voice_panel.dart';
import 'package:flutter_hbb/nikodesk/mobile_chat_options.dart';
import 'package:flutter_hbb/nikodesk/theme.dart';
import 'package:flutter_hbb/nikodesk/ui.dart';
import 'package:flutter_hbb/nikodesk/voice_session_model.dart';
import 'package:flutter_test/flutter_test.dart';

import 'nikodesk_voice_session_model_test.dart'
    show
        voiceCatalog,
        voiceStatus,
        parsedVoiceStatus,
        parsedVoiceCatalog,
        voiceQueued;

NikoVoiceCatalog _androidCatalog() {
  final raw = voiceCatalog();
  for (final device in raw['devices']) {
    for (final format in device['formats']) {
      format['format_schema'] = 'android_client_pcm_f32_48k_mono_v1';
      format['channels'] = 1;
    }
  }
  return NikoVoiceCatalog.parse(jsonEncode(raw))!;
}

Future<void> _host(WidgetTester tester, Widget widget,
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
      home: Scaffold(body: SingleChildScrollView(child: widget))));
}

Future<void> _select(WidgetTester tester, String key, String text) async {
  final field = find.byKey(ValueKey(key));
  await tester.ensureVisible(field);
  await tester.tap(field);
  await tester.pumpAndSettle();
  await tester.tap(find.text(text).last);
  await tester.pumpAndSettle();
}

void main() {
  tearDown(() => NikoLanguage.english = false);
  for (final english in [false, true]) {
    for (final dark in [false, true]) {
      testWidgets('Android foreground defaults 320/200% en=$english dark=$dark',
          (tester) async {
        final sent = <NikoVoiceCommand>[];
        final model = NikoVoiceSessionModel(
            anchor: parsedVoiceStatus(),
            androidController: true,
            availability: NikoVoiceAvailability.enabled,
            transport: (command) async {
              sent.add(command);
              return voiceQueued(command);
            });
        addTearDown(model.dispose);
        model.applyCatalog(_androidCatalog());
        await _host(tester, NikoCmVoicePanel(model: model, controller: true),
            english: english, dark: dark);
        final background = find.byKey(const ValueKey('niko-voice-background'));
        await tester.ensureVisible(background);
        expect(tester.widget<CheckboxListTile>(background).value, false);
        expect(tester.getSize(background).height, greaterThanOrEqualTo(48));
        expect(sent, isEmpty);
        expect(tester.takeException(), isNull);
        await _select(tester, 'niko-voice-capture-device', 'Test microphone');
        await _select(tester, 'niko-voice-capture-format',
            english ? '48 kHz · f32 · mono' : '48 kHz · f32 · 单声道');
        await _select(tester, 'niko-voice-playback-device', 'Test speaker');
        await _select(tester, 'niko-voice-playback-format',
            english ? '48 kHz · f32 · mono' : '48 kHz · f32 · 单声道');
        final approve = find.byKey(const ValueKey('niko-voice-approve'));
        await tester.ensureVisible(approve);
        await tester.tap(approve);
        await tester.pumpAndSettle();
        expect(sent, isEmpty);
        await tester.tap(find.text(english ? 'Allow this session' : '允许此会话'));
        await tester.pumpAndSettle();
        expect(sent.single.op, 'approve');
        expect(jsonDecode(sent.single.toJson())['allow_background'], false);
        expect(model.status.phase, 'Pending');
        expect(model.status.callRunning, false);
        expect(tester.takeException(), isNull);
      });
    }
  }

  test('only Android catalog approve may carry explicit background choice',
      () async {
    final sent = <NikoVoiceCommand>[];
    final model = NikoVoiceSessionModel(
        anchor: parsedVoiceStatus(),
        androidController: true,
        availability: NikoVoiceAvailability.enabled,
        transport: (command) async {
          sent.add(command);
          return voiceQueued(command);
        });
    addTearDown(model.dispose);
    final catalog = _androidCatalog();
    model.applyCatalog(catalog);
    final input = catalog.devices.first, output = catalog.devices.last;
    final choice = catalog.select(input.token, input.formats.single.token,
        output.token, output.formats.single.token)!;
    expect(await model.send('query', allowBackground: false), false);
    expect(await model.send('enumerate', allowBackground: true), false);
    expect(sent, isEmpty);
    expect(
        await model.send('approve', selection: choice, allowBackground: true),
        true);
    expect(jsonDecode(sent.single.toJson())['allow_background'], true);
    expect(model.status.phase, 'Pending');
  });

  test(
      'native newer Pending after notification refusal permits fresh foreground approval',
      () async {
    final sent = <NikoVoiceCommand>[];
    final model = NikoVoiceSessionModel(
        anchor: parsedVoiceStatus(),
        androidController: true,
        availability: NikoVoiceAvailability.enabled,
        transport: (command) async {
          sent.add(command);
          return voiceQueued(command);
        });
    addTearDown(model.dispose);
    final first = _androidCatalog();
    model.applyCatalog(first);
    NikoVoiceSelection choose(NikoVoiceCatalog c) => c.select(
        c.devices.first.token,
        c.devices.first.formats.single.token,
        c.devices.last.token,
        c.devices.last.formats.single.token)!;
    expect(
        await model.send('approve',
            selection: choose(first), allowBackground: true),
        true);
    expect(model.approvalUnconfirmed, true);
    expect(
        await model.send('approve',
            selection: choose(first), allowBackground: false),
        false);
    final changed = voiceStatus(revision: '2');
    changed['reason'] = 'notification_permission_required';
    expect(
        model.applyStatus(NikoVoiceStatus.parse(jsonEncode(changed))!), true);
    expect(model.approvalUnconfirmed, false);
    final raw = voiceCatalog(revision: '2', roster: '2');
    for (final device in raw['devices']) {
      for (final format in device['formats']) {
        format['format_schema'] = 'android_client_pcm_f32_48k_mono_v1';
        format['channels'] = 1;
      }
    }
    final next = NikoVoiceCatalog.parse(jsonEncode(raw))!;
    expect(model.applyCatalog(next), true);
    expect(
        await model.send('approve',
            selection: choose(next), allowBackground: false),
        true);
    expect(jsonDecode(sent.last.toJson())['allow_background'], false);
    expect(model.status.phase, 'Pending');
  });

  testWidgets(
      'desktop and unknown catalogs never offer Android background approval',
      (tester) async {
    final desktop = NikoVoiceSessionModel(
        anchor: parsedVoiceStatus(),
        availability: NikoVoiceAvailability.enabled,
        transport: (c) async => voiceQueued(c));
    addTearDown(desktop.dispose);
    desktop.applyCatalog(parsedVoiceCatalog());
    await _host(tester, NikoCmVoicePanel(model: desktop));
    expect(find.byKey(const ValueKey('niko-voice-background')), findsNothing);
    final catalog = desktop.catalog!,
        input = catalog.devices.first,
        output = catalog.devices.last;
    final choice = catalog.select(input.token, input.formats.single.token,
        output.token, output.formats.single.token)!;
    expect(
        await desktop.send('approve',
            selection: choice, allowBackground: false),
        false);
  });

  testWidgets(
      'Android permission not requested wording is local app fact and click stays Pending',
      (tester) async {
    final sent = <NikoVoiceCommand>[];
    final model = NikoVoiceSessionModel(
        anchor: parsedVoiceStatus(permission: 'NotDetermined'),
        androidController: true,
        availability: NikoVoiceAvailability.enabled,
        transport: (c) async {
          sent.add(c);
          return voiceQueued(c);
        });
    addTearDown(model.dispose);
    await _host(tester, NikoCmVoicePanel(model: model, controller: true));
    expect(find.text('尚未向系统申请麦克风权限。请点击下方按钮申请。'), findsOneWidget);
    expect(sent, isEmpty);
    final permission = find.byKey(const ValueKey('niko-voice-permission'));
    await tester.ensureVisible(permission);
    await tester.tap(permission);
    await tester.pumpAndSettle();
    expect(sent.single.op, 'request_permission');
    expect(model.status.microphonePermission, 'NotDetermined');
    expect(model.status.phase, 'Pending');
  });

  testWidgets(
      'mobile owned voice menu dismisses before callback and never sends legacy command',
      (tester) async {
    var chats = 0, calls = 0;
    BuildContext? sheetOrigin;
    await _host(
        tester,
        Builder(
            builder: (context) => TextButton(
                onPressed: () => showNikoMobileChatOptions(context,
                    onTextChat: () => chats++,
                    onVoiceCall: () {
                      calls++;
                      sheetOrigin = context;
                    }),
                child: const Text('Open'))));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    final voice = find.byKey(const ValueKey('niko-mobile-owned-voice'));
    await tester.ensureVisible(voice);
    expect(tester.getSize(voice).height, greaterThanOrEqualTo(48));
    await tester.tap(voice);
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(find.byKey(const ValueKey('niko-mobile-owned-voice')), findsNothing);
    expect(chats, 0);
    expect(sheetOrigin?.mounted, true);
  });
}
