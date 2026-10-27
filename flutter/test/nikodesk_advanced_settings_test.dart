import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/desktop/pages/desktop_setting_page.dart';
import 'package:flutter_hbb/models/native_model.dart';
import 'package:flutter_hbb/nikodesk/nightline.dart';
import 'package:flutter_hbb/nikodesk/nightline_settings.dart';
import 'package:flutter_hbb/nikodesk/ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

import 'support/nikodesk_fake_bridge.dart';

// The hosted upstream settings page runs on an in-memory bridge here; no
// native library, option file or system setting is touched.
void main() {
  late NikoFakeBridge bridge;
  setUp(() async {
    NikoLanguage.english = true;
    bridge = NikoFakeBridge();
    PlatformFFI.instance.ffiBindForTesting = bridge;
    Get.put<RxBool>(false.obs, tag: 'stop-service');
    await initGlobalFFI();
  });
  tearDown(() => NikoLanguage.english = false);

  Future<void> load(WidgetTester tester, SettingsTabKey tab,
      {Brightness brightness = Brightness.dark}) async {
    await tester.binding.setSurfaceSize(const Size(1030, 860));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
        theme: nightlineTheme(brightness),
        home: Scaffold(body: DesktopSettingPage(initialTabkey: tab))));
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<void> unload(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  }

  testWidgets('NikoDesk tabs share the Nightline cards and navigation',
      (tester) async {
    await load(tester, SettingsTabKey.general);
    expect(find.byType(NikoSettingsHeader), findsOneWidget);
    expect(find.byType(NikoSettingsNavItem), findsNWidgets(5));
    expect(find.byType(NikoSettingsCard), findsWidgets);
    expect(find.byType(Card), findsNothing);
    expect(find.byType(Checkbox), findsNothing);
    final general = tester.widget<NikoSettingsNavItem>(
        find.widgetWithText(NikoSettingsNavItem, 'General'));
    expect(general.selected, isTrue);
    expect(tester.takeException(), isNull);
    await unload(tester);
  });

  testWidgets('theme and language live only in the NikoDesk settings page',
      (tester) async {
    await load(tester, SettingsTabKey.general);
    expect(find.text('THEME'), findsNothing);
    expect(find.text('LANGUAGE'), findsNothing);
    expect(find.text('Follow System'), findsNothing);
    await unload(tester);
  });

  testWidgets('the service card names where its button goes', (tester) async {
    await load(tester, SettingsTabKey.general);
    expect(find.text('Network'), findsOneWidget); // the tab, not the button
    await tester.tap(find.text('Open network settings'));
    await tester.pumpAndSettle();
    final network = tester.widget<NikoSettingsNavItem>(
        find.widgetWithText(NikoSettingsNavItem, 'Network'));
    expect(network.selected, isTrue);
    await unload(tester);
  });

  testWidgets('a toggle row writes the same option as the old checkbox',
      (tester) async {
    await load(tester, SettingsTabKey.general);
    final row = find.widgetWithText(NikoSettingsToggle, 'Adaptive bitrate');
    await tester.ensureVisible(row);
    expect(tester.widget<NikoSettingsToggle>(row).value, isTrue);
    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(bridge.options[kOptionEnableAbr], 'N');
    expect(tester.widget<NikoSettingsToggle>(row).value, isFalse);
    await unload(tester);
  });

  testWidgets('a radio row stores the chosen default', (tester) async {
    bridge.userDefault[kOptionImageQuality] = kRemoteImageQualityBest;
    await load(tester, SettingsTabKey.display);
    final balanced = find.widgetWithText(NikoSettingsRadio<String>, 'Balanced');
    await tester.ensureVisible(balanced);
    await tester.tap(balanced);
    await tester.pumpAndSettle();
    expect(bridge.userDefault[kOptionImageQuality], kRemoteImageQualityBalanced);
    await unload(tester);
  });

  testWidgets('dropdowns use the Nightline face and hairline', (tester) async {
    await load(tester, SettingsTabKey.safety, brightness: Brightness.light);
    final dropdown = tester.widget<DropdownButton<String>>(
        find.byType(DropdownButton<String>).first);
    expect(dropdown.style!.fontFamily, NlType.ui);
    await unload(tester);
  });

  testWidgets('a dropdown starts where its card label starts', (tester) async {
    await load(tester, SettingsTabKey.safety);
    final card = find.ancestor(
        of: find.byType(DropdownButton<String>).first,
        matching: find.byType(NikoSettingsCard));
    final label = find.descendant(of: card, matching: find.byType(NlMonoLabel));
    final box = find.ancestor(
        of: find.byType(DropdownButton<String>).first,
        matching: find.byType(Container)).first;
    expect(tester.getTopLeft(box).dx, tester.getTopLeft(label).dx);
    await unload(tester);
  });

  testWidgets('the page header is in the interface language', (tester) async {
    await load(tester, SettingsTabKey.general);
    // Labels are sentence case, never tracked capitals.
    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('SETTINGS'), findsNothing);
    expect(find.text('ADVANCED'), findsNothing);
    await unload(tester);
    NikoLanguage.english = false;
    await load(tester, SettingsTabKey.general);
    expect(find.text('设置'), findsOneWidget);
    expect(find.text('高级设置'), findsOneWidget);
    await unload(tester);
  });

  testWidgets('without the NikoDesk build the upstream cards stay',
      (tester) async {
    bridge.appName = 'RustDesk';
    await load(tester, SettingsTabKey.display);
    expect(find.byType(NikoSettingsCard), findsNothing);
    expect(find.byType(NikoSettingsNavItem), findsNothing);
    expect(find.byType(Card), findsWidgets);
    await unload(tester);
  });
}
