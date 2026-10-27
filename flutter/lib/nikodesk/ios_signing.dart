import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;

import 'settings_kit.dart';
import 'ui.dart';

/// An iPad or iPhone build signed with a free Apple ID stops opening when its
/// provisioning profile expires, seven days after signing. App Store builds
/// carry no such profile, so they never warn.
DateTime? nikoProfileExpiry(List<int> profile) {
  // The profile is a signed envelope around a plain XML property list.
  final text = latin1.decode(profile, allowInvalid: true);
  final match = RegExp(r'<key>ExpirationDate</key>\s*<date>([^<]+)</date>')
      .firstMatch(text);
  return match == null ? null : DateTime.tryParse(match.group(1)!)?.toUtc();
}

Future<DateTime?> nikoSigningExpiry({String? executable}) async {
  if (executable == null && !Platform.isIOS) return null;
  final file = File(path.join(
      path.dirname(executable ?? Platform.resolvedExecutable),
      'embedded.mobileprovision'));
  try {
    return nikoProfileExpiry(await file.readAsBytes());
  } catch (_) {
    return null;
  }
}

String nikoSigningDate(DateTime expiry) {
  final local = expiry.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
  ];
  final time = '${two(local.hour)}:${two(local.minute)}';
  return nikoText('${local.month} 月 ${local.day} 日 $time',
      '${months[local.month - 1]} ${local.day}, $time');
}

/// The warning for the home screen within two days of expiry, else null.
String? nikoSigningWarning(DateTime? expiry, DateTime now) {
  if (expiry == null || expiry.difference(now) > const Duration(days: 2)) {
    return null;
  }
  return expiry.isAfter(now)
      ? nikoText(
          '这台设备上的 NikoDesk 签名在 ${nikoSigningDate(expiry)} 过期，过期后打不开。请在这之前重新签名安装。',
          'NikoDesk’s signature on this device expires ${nikoSigningDate(expiry)}; after that it will not open. Sign and install it again before then.')
      : nikoText('这台设备上的 NikoDesk 签名已经过期，请重新签名安装。',
          'NikoDesk’s signature on this device has expired. Sign and install it again.');
}

/// Settings row with the signature's expiry; nothing on builds without one.
class NikoSigningRow extends StatelessWidget {
  final Future<DateTime?> expiry;
  const NikoSigningRow({super.key, required this.expiry});

  @override
  Widget build(BuildContext context) => FutureBuilder<DateTime?>(
      future: expiry,
      builder: (context, snapshot) {
        final value = snapshot.data;
        if (value == null) return const SizedBox.shrink();
        return NikoSettingRow(
            title: nikoText('签名到期', 'Signature expires'),
            description: nikoText(
                '用免费 Apple ID 签名的版本 7 天后过期，过期前要重新签名安装。',
                'Builds signed with a free Apple ID expire after 7 days; sign and install again before then.'),
            trailing: Text(nikoSigningDate(value)));
      });
}
