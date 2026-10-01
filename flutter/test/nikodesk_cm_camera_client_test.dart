import 'package:flutter_hbb/models/server_model.dart';
import 'package:flutter_test/flutter_test.dart';

import 'nikodesk_cm_camera_test.dart' show cameraStatus;

Map<String, dynamic> _client() => {
      'id': 12,
      'authorized': true,
      'is_file_transfer': false,
      'is_view_camera': true,
      'is_terminal': false,
      'port_forward': '',
      'name': 'Camera peer',
      'avatar': '',
      'peer_id': '123456789',
      'keyboard': false,
      'clipboard': false,
      'audio': false,
      'file': false,
      'restart': false,
      'recording': false,
      'block_input': false,
      'privacy_mode': false,
      'disconnected': false,
      'from_switch': false,
      'in_voice_call': false,
      'incoming_voice_call': false,
      'niko_camera': cameraStatus(),
    };

void main() {
  test(
      'actual CM parser retains cleanup-only disconnected snapshots without granting permissions',
      () {
    for (final phase in ['RecoveryRequired', 'Revoking', 'Stopped']) {
      final client = Client.fromJson(_client()
        ..addAll({
          'authorized': false,
          'disconnected': true,
          'niko_camera_cleanup': true,
          'niko_camera': cameraStatus(phase: phase, revision: '2')
        }));
      expect(client.nikoCameraCleanup, const bool.fromEnvironment('NIKODESK'));
      expect(client.authorized, isFalse);
      expect(client.disconnected, isTrue);
      if (const bool.fromEnvironment('NIKODESK')) {
        expect(client.nikoCamera!.phase, phase);
      }
    }
    for (final phase in ['Pending', 'Starting', 'Running']) {
      final client = Client.fromJson(_client()
        ..addAll({
          'authorized': false,
          'disconnected': true,
          'niko_camera_cleanup': true,
          'niko_camera': cameraStatus(phase: phase)
        }));
      expect(client.nikoCamera, isNull);
      expect(client.nikoCameraCleanup, isFalse);
    }
  });

  test(
      'actual CM client parser takes camera identity only from authorized native snapshot',
      () {
    final client = Client.fromJson(_client());
    expect(client.nikoCamera != null, const bool.fromEnvironment('NIKODESK'));
    expect(client.nikoCapability, isNull);
    if (const bool.fromEnvironment('NIKODESK')) {
      expect(client.nikoCamera!.identity.namespace, 'a' * 64);
      expect(client.nikoCamera!.phase, 'Pending');
    }
  });
  test(
      'actual CM client parser refuses camera anchor from foreign or unauthorized connection',
      () {
    for (final changes in [
      {'id': 13},
      {'peer_id': '987654321'},
      {'authorized': false},
      {'disconnected': true},
      {'is_view_camera': false},
      {'niko_camera': cameraStatus()..['revision'] = '01'},
    ]) {
      expect(Client.fromJson(_client()..addAll(changes)).nikoCamera, isNull);
    }
  });
}
