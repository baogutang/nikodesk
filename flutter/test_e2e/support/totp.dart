// RFC 6238 codes for the test profiles' own two-factor secret.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'native.dart';

class Totp {
  Totp(this.secret, this.digits, this.period, this.algorithm);
  final List<int> secret;
  final int digits;
  final int period;
  final String algorithm;

  factory Totp.fromUrl(String url) {
    final uri = Uri.parse(url);
    final parameters = uri.queryParameters;
    return Totp(
        _base32(parameters['secret'] ?? ''),
        int.parse(parameters['digits'] ?? '6'),
        int.parse(parameters['period'] ?? '30'),
        (parameters['algorithm'] ?? 'SHA1').toUpperCase());
  }

  static File get _file => File('${env('NIKODESK_E2E_WORK')}/shared/totp.json');

  void save() {
    _file.parent.createSync(recursive: true);
    _file.writeAsStringSync(jsonEncode({
      'secret': base64Encode(secret),
      'digits': digits,
      'period': period,
      'algorithm': algorithm
    }));
  }

  factory Totp.load() {
    final value = jsonDecode(_file.readAsStringSync()) as Map<String, dynamic>;
    return Totp(base64Decode(value['secret'] as String), value['digits'] as int,
        value['period'] as int, value['algorithm'] as String);
  }

  static void forget() {
    if (_file.existsSync()) _file.deleteSync();
  }

  int step([DateTime? at]) =>
      (at ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000 ~/ period;

  String code([int? atStep]) {
    final counter = ByteData(8)..setUint64(0, atStep ?? step());
    final hash = switch (algorithm) {
      'SHA1' => sha1,
      'SHA256' => sha256,
      'SHA512' => sha512,
      _ => throw StateError('Unsupported TOTP algorithm $algorithm')
    };
    final mac = Hmac(hash, secret).convert(counter.buffer.asUint8List()).bytes;
    final offset = mac.last & 0x0f;
    final binary = ((mac[offset] & 0x7f) << 24) |
        (mac[offset + 1] << 16) |
        (mac[offset + 2] << 8) |
        mac[offset + 3];
    var modulus = 1;
    for (var i = 0; i < digits; i++) {
      modulus *= 10;
    }
    return (binary % modulus).toString().padLeft(digits, '0');
  }

  /// Waits until a time step no earlier call can have consumed.
  Future<int> freshStep() async {
    final current = step();
    final next = DateTime.fromMillisecondsSinceEpoch(
        (current + 1) * period * 1000 + 1500);
    await Future<void>.delayed(next.difference(DateTime.now()));
    return step();
  }

  static List<int> _base32(String text) {
    const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
    final output = <int>[];
    var buffer = 0, bits = 0;
    for (final char in text.toUpperCase().replaceAll('=', '').split('')) {
      final value = alphabet.indexOf(char);
      if (value < 0) throw FormatException('Invalid base32 secret');
      buffer = (buffer << 5) | value;
      bits += 5;
      if (bits >= 8) {
        bits -= 8;
        output.add((buffer >> bits) & 0xff);
      }
    }
    if (output.isEmpty) throw const FormatException('Empty two-factor secret');
    return output;
  }
}
