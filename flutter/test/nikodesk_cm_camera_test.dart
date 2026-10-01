import 'dart:convert';

import 'package:flutter_hbb/nikodesk/cm_camera.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> cameraIdentity(
        {String namespace = 'a', String epoch = '1'}) =>
    {
      'connection_id': 12,
      'namespace': namespace * 64,
      'peer_id': '123456789',
      'connection_nonce': 'b' * 32,
      'request_nonce': 'c' * 32,
      'epoch': epoch,
    };
Map<String, dynamic> cameraStatus(
        {String phase = 'Pending',
        String revision = '1',
        String namespace = 'a',
        String resourceEpoch = '1'}) =>
    {
      'identity': cameraIdentity(namespace: namespace),
      'kind': 'camera',
      'phase': phase,
      'reason': 'camera_pending',
      'resource_epoch': resourceEpoch,
      'revision': revision,
      'selection': null,
    };
Map<String, dynamic> windowsFormat() => {
      'format_token': 'd' * 32,
      'format_schema': 'windows-native-v1',
      'width': 1920,
      'height': 1080,
      'fps_num': 30000,
      'fps_den': 1001,
    };
Map<String, dynamic> macFormat() => {
      'format_token': 'e' * 32,
      'format_schema': 'mac-fps-range-v1',
      'width': 1280,
      'height': 720,
      'min_fps_milli': 15000,
      'max_fps_milli': 60000,
    };
Map<String, dynamic> cameraCatalog(
        {String revision = '1',
        String namespace = 'a',
        String authorization = 'authorized',
        List<Map<String, dynamic>>? formats}) =>
    {
      'identity': cameraIdentity(namespace: namespace),
      'revision': revision,
      'roster_revision': '7',
      'authorization': authorization,
      'reason': 'camera_pending',
      'devices': [
        {
          'uid': 'native-exact-uid',
          'name': 'Camera name',
          'formats': formats ?? [windowsFormat()]
        }
      ],
    };

void main() {
  test('native format token and fractional FPS survive without reconstruction',
      () {
    final catalog = NikoCameraCatalog.parse(jsonEncode(cameraCatalog()))!;
    final format = catalog.devices.single.formats.single;
    expect(format.fpsNum, 30000);
    expect(format.fpsDen, 1001);
    expect(format.acceptsFps(null), isTrue);
    expect(format.acceptsFps(30), isFalse);
    final request = jsonDecode(nikoCameraCommand(
        NikoCameraStatus.parse(jsonEncode(cameraStatus()))!, 'approve',
        uid: catalog.devices.single.uid,
        rosterRevision: catalog.rosterRevision,
        formatToken: format.token));
    expect(request['format_token'], 'd' * 32);
    expect(request['uid'], 'native-exact-uid');
    expect(request.containsKey('fps'), isFalse);
    expect(request.containsKey('index'), isFalse);
  });
  test('Mac explicit integer FPS is bounded by native range without a default',
      () {
    final format = NikoCameraFormat.parse(macFormat())!;
    for (final fps in [null, 0, 14, 61]) {
      expect(format.acceptsFps(fps), isFalse);
    }
    expect(format.acceptsFps(15), isTrue);
    expect(format.acceptsFps(60), isTrue);
    expect(NikoCameraFormat.parse(macFormat()..['fps_num'] = 30), isNull);
    expect(NikoCameraFormat.parse(windowsFormat()..['min_fps_milli'] = 1000),
        isNull);
  });
  test(
      'format indices, unknown schema, malformed fraction and duplicate token reject the entire catalog',
      () {
    for (final changes in [
      {'index': 1},
      {'format_schema': 'legacy'},
      {'fps_den': 0},
      {'width': 4097}
    ]) {
      expect(NikoCameraFormat.parse(windowsFormat()..addAll(changes)), isNull);
    }
    expect(
        NikoCameraCatalog.parse(jsonEncode(
            cameraCatalog(formats: [windowsFormat(), windowsFormat()]))),
        isNull);
    expect(
        NikoCameraCatalog.parse(jsonEncode(
            cameraCatalog()..['devices'] = List.generate(65, (_) => {}))),
        isNull);
    expect(NikoCameraCatalog.parse('x' * 1048577), isNull);
  });
  test('camera discovery permits metadata-only devices with no formats', () {
    expect(
        NikoCameraCatalog.parse(jsonEncode(cameraCatalog(formats: [])))!
            .devices
            .single
            .formats,
        isEmpty);
  });
  test(
      'invalid identity, unbounded raw reason and unsupported phase fail closed',
      () {
    expect(
        NikoCameraStatus.parse(
            jsonEncode(cameraStatus()..['phase'] = 'Preparing')),
        isNull);
    expect(
        NikoCameraStatus.parse(
            jsonEncode(cameraStatus()..['reason'] = '/Users/private/path')),
        isNull);
    expect(
        NikoCameraStatus.parse(jsonEncode(cameraStatus()
          ..['identity'] = (cameraIdentity()..['epoch'] = '01'))),
        isNull);
    expect(
        NikoCameraStatus.parse(
            jsonEncode(cameraStatus()..['unexpected'] = true)),
        isNull);
  });
  test('anchored state rejects another namespace, peer nonce and epoch', () {
    final state =
        NikoCameraState(NikoCameraStatus.parse(jsonEncode(cameraStatus()))!);
    expect(
        state.update(NikoCameraStatus.parse(
            jsonEncode(cameraStatus(namespace: 'f', revision: '2')))!),
        isFalse);
    for (final changes in [
      {'peer_id': '987654321'},
      {'connection_nonce': 'f' * 32},
      {'epoch': '2'}
    ]) {
      final raw = cameraStatus(revision: '2')
        ..['identity'] = (cameraIdentity()..addAll(changes));
      expect(state.update(NikoCameraStatus.parse(jsonEncode(raw))!), isFalse);
    }
    expect(state.status.revision, '1');
  });
  test(
      'status revision and resource epoch cannot roll back or mutate at the same revision',
      () {
    final state = NikoCameraState(NikoCameraStatus.parse(
        jsonEncode(cameraStatus(revision: '4', resourceEpoch: '3')))!);
    expect(
        state.update(NikoCameraStatus.parse(
            jsonEncode(cameraStatus(revision: '3', resourceEpoch: '3')))!),
        isFalse);
    expect(
        state.update(NikoCameraStatus.parse(
            jsonEncode(cameraStatus(revision: '5', resourceEpoch: '2')))!),
        isFalse);
    expect(
        state.update(NikoCameraStatus.parse(jsonEncode(cameraStatus(
            revision: '4', resourceEpoch: '3', phase: 'Stopped')))!),
        isFalse);
    expect(
        state.update(NikoCameraStatus.parse(jsonEncode(cameraStatus(
            revision: '5', resourceEpoch: '4', phase: 'RecoveryRequired')))!),
        isTrue);
  });
  test('catalog is accepted only at current pending identity and revision', () {
    final state =
        NikoCameraState(NikoCameraStatus.parse(jsonEncode(cameraStatus()))!);
    expect(
        state.acceptCatalog(NikoCameraCatalog.parse(
            jsonEncode(cameraCatalog(namespace: 'f')))!),
        isFalse);
    expect(
        state.acceptCatalog(
            NikoCameraCatalog.parse(jsonEncode(cameraCatalog(revision: '2')))!),
        isFalse);
    expect(
        state.acceptCatalog(
            NikoCameraCatalog.parse(jsonEncode(cameraCatalog()))!),
        isTrue);
    state.update(
        NikoCameraStatus.parse(jsonEncode(cameraStatus(revision: '2')))!);
    expect(state.catalog, isNull);
    expect(
        state.acceptCatalog(
            NikoCameraCatalog.parse(jsonEncode(cameraCatalog()))!),
        isFalse);
    state.update(NikoCameraStatus.parse(
        jsonEncode(cameraStatus(revision: '3', phase: 'Starting')))!);
    expect(
        state.acceptCatalog(
            NikoCameraCatalog.parse(jsonEncode(cameraCatalog(revision: '3')))!),
        isFalse);
  });
  test('queued command reply must echo precise captured identity and revision',
      () {
    final request = NikoCameraStatus.parse(jsonEncode(cameraStatus()))!;
    Map<String, dynamic> reply() => {
          'ok': true,
          'status': 'queued',
          'identity': cameraIdentity(),
          'revision': '1',
          'reason': ''
        };
    expect(nikoCameraQueued(jsonEncode(reply()), request), isTrue);
    expect(nikoCameraQueued(jsonEncode(reply()..['revision'] = '2'), request),
        isFalse);
    expect(
        nikoCameraQueued(
            jsonEncode(reply()..['identity'] = cameraIdentity(namespace: 'f')),
            request),
        isFalse);
    expect(nikoCameraQueued('{"ok":true,"status":"queued"}', request), isFalse);
    expect(NikoCameraStatus.parse(jsonEncode(reply())), isNull);
  });
  test(
      'unconfirmed cleanup persists through pending status refresh until actual stopped',
      () {
    final initial = NikoCameraStatus.parse(jsonEncode(cameraStatus()))!;
    final state = NikoCameraState(initial);
    expect(
        state.markCleanup(
            NikoCameraStatus.parse(jsonEncode(cameraStatus(namespace: 'f')))!),
        isFalse);
    expect(state.markCleanup(initial), isTrue);
    expect(state.cleanupUnconfirmed, isTrue);
    state.update(
        NikoCameraStatus.parse(jsonEncode(cameraStatus(revision: '2')))!);
    expect(state.cleanupUnconfirmed, isTrue);
    state.update(NikoCameraStatus.parse(
        jsonEncode(cameraStatus(revision: '3', phase: 'Stopped')))!);
    expect(state.cleanupUnconfirmed, isFalse);
  });
  test(
      'production client snapshot anchor preserves cleanup state and rejects older snapshots',
      () {
    final initial =
        NikoCameraStatus.parse(jsonEncode(cameraStatus(revision: '3')))!;
    final state = nikoCameraAnchor(null, initial)..markCleanup(initial);
    final refreshed = nikoCameraAnchor(state,
        NikoCameraStatus.parse(jsonEncode(cameraStatus(revision: '4')))!);
    expect(identical(refreshed, state), isTrue);
    expect(refreshed.cleanupUnconfirmed, isTrue);
    nikoCameraAnchor(refreshed,
        NikoCameraStatus.parse(jsonEncode(cameraStatus(revision: '2')))!);
    expect(refreshed.status.revision, '4');
    final replacement = nikoCameraAnchor(refreshed,
        NikoCameraStatus.parse(jsonEncode(cameraStatus(namespace: 'f')))!);
    expect(identical(replacement, state), isFalse);
    expect(replacement.status.identity.namespace, 'f' * 64);
  });
}
