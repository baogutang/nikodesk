import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/nikodesk/auto_lock_settings.dart';
import 'package:flutter_hbb/nikodesk/nightline.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
      'lock toggle displays persisted policy only after confirmed readback',
      (tester) async {
    var stored = false;
    var saves = 0;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: NikoAutoLockSettings(
                readOptions: () async =>
                    jsonEncode({nikoAutoLockOption: stored ? 'Y' : 'N'}),
                writeEnabled: (value) async {
                  stored = value;
                  saves++;
                }))));
    await tester.pumpAndSettle();
    final toggle = find.byType(NlSwitch);
    expect(tester.widget<NlSwitch>(toggle).value, false);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(saves, 1);
    expect(tester.widget<NlSwitch>(toggle).value, true);
  });

  testWidgets('unconfirmed write preserves old value and requires reload',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: NikoAutoLockSettings(
                readOptions: () async => '{}', writeEnabled: (_) async {}))));
    await tester.pumpAndSettle();
    final toggle = find.byType(NlSwitch);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(tester.widget<NlSwitch>(toggle).value, false);
    expect(tester.widget<NlSwitch>(toggle).onChanged, isNull);
    expect(tester.takeException(), isNull);
  });
}
