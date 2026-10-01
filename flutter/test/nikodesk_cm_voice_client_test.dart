import 'package:flutter_hbb/models/server_model.dart';
import 'package:flutter_test/flutter_test.dart';

import 'nikodesk_voice_session_model_test.dart' show voiceStatus, voiceCatalog;

Map<String, dynamic> _client() => {
      'id': 7,
      'authorized': true,
      'is_file_transfer': false,
      'is_view_camera': false,
      'is_terminal': false,
      'port_forward': '',
      'name': 'Synthetic voice peer',
      'peer_id': '123456789',
      'keyboard': false,
      'clipboard': false,
      'audio': false,
      'file': false,
      'restart': false,
      'recording': false,
      'block_input': false,
      'disconnected': false,
      'from_switch': false,
      'in_voice_call': false,
      'incoming_voice_call': false,
      'niko_voice': voiceStatus(),
      'niko_voice_catalog': voiceCatalog(),
    };

void main() {
  test('production Client parser anchors only authorized ordinary remote voice',
      () {
    final client = Client.fromJson(_client());
    expect(client.nikoVoice != null, const bool.fromEnvironment('NIKODESK'));
    expect(client.nikoVoiceCatalog != null,
        const bool.fromEnvironment('NIKODESK'));
    expect(client.nikoVoiceCleanup, false);
    expect(client.inVoiceCall, false);
  });
  test(
      'production Client parser denies unauthenticated foreign and wrong-kind voice anchor',
      () {
    for (final changes in [
      {'id': 8},
      {'peer_id': '987654321'},
      {'authorized': false},
      {'disconnected': true},
      {'is_file_transfer': true},
      {'is_view_camera': true},
      {'is_terminal': true},
      {'port_forward': '127.0.0.1:1234'},
      {'niko_voice': voiceStatus()..['cleanup_only'] = true},
    ]) {
      expect(Client.fromJson(_client()..addAll(changes)).nikoVoice, isNull);
    }
  });
  test(
      'only trusted native retired flag retains cleanup and never ordinary status self retires',
      () {
    for (final phase in ['Revoking', 'RecoveryRequired', 'Stopped']) {
      final client = Client.fromJson(_client()
        ..addAll({
          'authorized': false,
          'disconnected': true,
          'niko_voice_cleanup': true,
          'niko_voice': voiceStatus(phase: phase, revision: '2')
            ..['cleanup_only'] = true,
        }));
      expect(client.nikoVoiceCleanup, const bool.fromEnvironment('NIKODESK'));
      expect(client.nikoVoiceCatalog, isNull);
      expect(client.authorized, false);
    }
    for (final phase in ['Pending', 'Starting', 'Running']) {
      expect(
          Client.fromJson(_client()
                ..addAll({
                  'authorized': false,
                  'disconnected': true,
                  'niko_voice_cleanup': true,
                  'niko_voice': voiceStatus(phase: phase),
                }))
              .nikoVoice,
          isNull);
    }
  });
  test('native snapshot catalog mismatch is not attached to trusted status',
      () {
    for (final catalog in [
      voiceCatalog(namespace: 'b'),
      voiceCatalog(revision: '2'),
      voiceCatalog(permission: 'NotDetermined'),
      voiceCatalog()..['identity']['request_nonce'] = '9' * 32,
    ]) {
      expect(
          Client.fromJson(_client()..['niko_voice_catalog'] = catalog)
              .nikoVoiceCatalog,
          isNull);
    }
  });
}
