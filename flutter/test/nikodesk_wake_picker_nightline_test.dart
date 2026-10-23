import 'package:flutter/material.dart';
import 'package:flutter_hbb/nikodesk/device_store.dart';
import 'package:flutter_hbb/nikodesk/nightline.dart';
import 'package:flutter_hbb/nikodesk/ui.dart';
import 'package:flutter_hbb/nikodesk/wake_device_picker.dart';
import 'package:flutter_test/flutter_test.dart';

// The wake target picker under the Nightline theme pops what the stock
// dialog pops: the device's index, -1 for manual entry and null on cancel.

const _devices = [
  DeviceEntry(id: '123456789', alias: 'Studio'),
  DeviceEntry(id: '987654321'),
];

void main() {
  setUp(() => NikoLanguage.english = true);
  tearDown(() => NikoLanguage.english = false);

  Future<int?> pick(WidgetTester tester, String row) async {
    int? picked = -2;
    await tester.pumpWidget(MaterialApp(
        theme: nightlineTheme(Brightness.light),
        home: Builder(
            builder: (context) => Center(
                child: TextButton(
                    onPressed: () async => picked = await showDialog<int>(
                        context: context,
                        builder: (dialog) =>
                            NikoWakePicker.of(dialog, _devices)!),
                    child: const Text('open'))))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Choose a device to wake'), findsOneWidget);
    await tester.tap(find.text(row));
    await tester.pumpAndSettle();
    expect(find.text('Choose a device to wake'), findsNothing);
    expect(tester.takeException(), isNull);
    return picked;
  }

  testWidgets('a device row pops its index', (tester) async {
    expect(await pick(tester, 'Studio'), 0);
    // A device without an alias is listed by its ID.
    expect(await pick(tester, '987654321'), 1);
  });

  testWidgets('manual entry pops -1 and Cancel pops nothing', (tester) async {
    expect(await pick(tester, 'Enter NIC manually'), -1);
    expect(await pick(tester, 'Cancel'), isNull);
  });

  testWidgets('outside the Nightline theme the stock dialog stays',
      (tester) async {
    Widget? picker;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) {
      picker = NikoWakePicker.of(context, _devices);
      return const SizedBox.shrink();
    })));
    expect(picker, isNull);
  });
}
