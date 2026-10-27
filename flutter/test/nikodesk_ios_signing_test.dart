import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/nikodesk/ios_signing.dart';
import 'package:flutter_hbb/nikodesk/ui.dart';

// A profile is a signed envelope around this kind of property list.
List<int> _profile(String date) => [
      0x30, 0x82, 0x0f, 0x00, // envelope bytes before the plist
      ...latin1.encode('<?xml version="1.0"?><plist><dict>'
          '<key>AppIDName</key><string>NikoDesk</string>'
          '<key>ExpirationDate</key>\n\t<date>$date</date>'
          '</dict></plist>'),
      0xa0, 0x82, 0x0b, // signature bytes after it
    ];

void main() {
  setUp(() => NikoLanguage.english = false);

  test('the expiry is read from the profile around its property list', () {
    expect(nikoProfileExpiry(_profile('2026-10-30T07:19:04Z')),
        DateTime.utc(2026, 10, 30, 7, 19, 4));
    expect(nikoProfileExpiry(latin1.encode('<plist></plist>')), isNull);
  });

  test('the home warns only within two days, and after expiry', () {
    final now = DateTime.utc(2026, 10, 27, 12);
    expect(nikoSigningWarning(null, now), isNull);
    expect(nikoSigningWarning(now.add(const Duration(days: 3)), now), isNull);
    expect(nikoSigningWarning(now.add(const Duration(days: 1)), now),
        contains('过期后打不开'));
    expect(nikoSigningWarning(now.subtract(const Duration(hours: 1)), now),
        contains('已经过期'));
  });

  test('a build without a profile reports nothing', () async {
    final directory = await Directory.systemTemp.createTemp('niko-signing-');
    addTearDown(() => directory.delete(recursive: true));
    expect(await nikoSigningExpiry(executable: '${directory.path}/Runner'),
        isNull);
    await File('${directory.path}/embedded.mobileprovision')
        .writeAsBytes(_profile('2026-11-03T01:00:00Z'));
    expect(await nikoSigningExpiry(executable: '${directory.path}/Runner'),
        DateTime.utc(2026, 11, 3, 1));
  });
}
