import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/nikodesk/policy.dart';

void main() {
  test('private endpoints support host names, IPv4, bracketed IPv6 and ports',
      () {
    for (final value in [
      'nas.example.net',
      '192.168.1.10:21116',
      '[fd00::1]:21116',
      'localhost:21117'
    ]) {
      expect(validServerEndpoint(value), isTrue, reason: value);
    }
  });
  test(
      'endpoint validation rejects URLs, credentials, bypasses and invalid ports',
      () {
    for (final value in [
      '',
      'https://nas.example.net',
      'user@nas',
      'nas:0',
      'nas:65536',
      'nas:-1',
      'nas:abc',
      'nas/path',
      'nas?foo',
      ' nas ',
      '::1',
      '[::1',
      'a..b',
      '-nas',
      'nas-',
      '999.999.1.2',
      'rs-ny.rustdesk.com',
      'RUSTDESK.COM',
      'public',
      '0.0.0.0',
      '[::]',
      '224.0.0.1',
      '[ff02::1]'
    ]) {
      expect(validServerEndpoint(value), isFalse, reason: value);
    }
  });
  test('server key must be canonical nonzero Base64 for exactly 32 bytes', () {
    expect(validServerKey(base64Encode(List.filled(32, 1))), isTrue);
    for (final key in [
      base64Encode(List.filled(31, 1)),
      base64Encode(List.filled(33, 1)),
      base64Encode(List.filled(32, 0)),
      'not-a-key',
      '${base64Encode(List.filled(32, 1))}\n'
    ]) {
      expect(validServerKey(key), isFalse);
    }
  });
  test('device IDs match the core numeric-only private-server policy', () {
    expect(validDeviceId('123 456 789'), isTrue);
    for (final id in [
      '12345',
      '1' * 17,
      'company_pc',
      '123456@server',
      '127.0.0.1',
      '123456/r'
    ]) {
      expect(validDeviceId(id), isFalse, reason: id);
    }
  });
  test('complete configuration requires both server fields and public key', () {
    final key = base64Encode(List.filled(32, 1));
    expect(PrivateServerConfig('nas:21116', 'nas:21117', key).isValid, isTrue);
    expect(PrivateServerConfig('nas:21116', '', key).isValid, isFalse);
  });
  test('presets map to upstream image-quality semantics without forcing codecs',
      () {
    final office = PictureRequest.forMode(PictureMode.office);
    expect(office.imageQuality, 'best');
    expect(office.originalScale, isTrue);
    expect(office.requestsCustomFps, isFalse);
    expect(PictureRequest.forMode(PictureMode.smooth).imageQuality, 'balanced');
    final weak = PictureRequest.forMode(PictureMode.constrained);
    expect(weak.imageQuality, 'custom');
    expect(weak.bitratePercent, 30);
    expect(weak.fps, 15);
  });
  test('custom quality is a bounded ratio, not an absolute kbps value', () {
    final request = PictureRequest.forMode(PictureMode.custom,
        customPercent: 75, customFps: 40);
    expect(request.bitratePercent, 75);
    expect(request.fps, 40);
    expect(
        () => PictureRequest.forMode(PictureMode.custom, customPercent: 3000),
        throwsArgumentError);
    expect(() => PictureRequest.forMode(PictureMode.custom, customFps: 120),
        throwsArgumentError);
  });
  test('custom FPS capability rejects old, empty and malformed peer versions',
      () {
    for (final version in ['', 'unknown', '1.1.9', '0.9.9']) {
      expect(PictureRequest.supportsCustomFps(version), isFalse);
    }
    for (final version in ['1.2.0', '1.5.0', '2.0.0', '1.2.0-alpha']) {
      expect(PictureRequest.supportsCustomFps(version), isTrue);
    }
  });
}
