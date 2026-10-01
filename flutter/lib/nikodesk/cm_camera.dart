import 'dart:convert';

import 'cm_capabilities.dart';

bool _fields(Map raw, Set<String> fields) =>
    raw.keys.toSet().difference(fields).isEmpty;
bool _text(dynamic value, int max, {bool empty = false}) =>
    value is String &&
    (empty || value.isNotEmpty) &&
    value.length <= max &&
    !RegExp(r'[\x00-\x1f\x7f]').hasMatch(value);
bool _reason(dynamic value) =>
    value is String && RegExp(r'^[a-z0-9_]{0,96}$').hasMatch(value);
bool _positive(dynamic value, int max) =>
    value is int && value > 0 && value <= max;
bool _revision(dynamic value) =>
    value is String && NikoCapabilityIdentity.validEpoch(value);

class NikoCameraFormat {
  final String token;
  final String schema;
  final int width, height;
  final int? minFpsMilli, maxFpsMilli, fpsNum, fpsDen;
  const NikoCameraFormat(this.token, this.schema, this.width, this.height,
      {this.minFpsMilli, this.maxFpsMilli, this.fpsNum, this.fpsDen});

  static NikoCameraFormat? parse(dynamic raw) {
    if (raw is! Map ||
        !_fields(raw, {
          'format_token',
          'format_schema',
          'width',
          'height',
          'min_fps_milli',
          'max_fps_milli',
          'fps_num',
          'fps_den'
        }) ||
        raw['format_token'] is! String ||
        !NikoCapabilityIdentity.validNonce(raw['format_token']) ||
        !_positive(raw['width'], 4096) ||
        !_positive(raw['height'], 4096)) return null;
    final schema = raw['format_schema'];
    if (schema == 'mac-fps-range-v1') {
      if (!_positive(raw['min_fps_milli'], 1000000) ||
          !_positive(raw['max_fps_milli'], 1000000) ||
          raw['min_fps_milli'] > raw['max_fps_milli'] ||
          raw.containsKey('fps_num') ||
          raw.containsKey('fps_den')) return null;
    } else if (schema == 'windows-native-v1') {
      if (!_positive(raw['fps_num'], 4294967295) ||
          !_positive(raw['fps_den'], 4294967295) ||
          raw.containsKey('min_fps_milli') ||
          raw.containsKey('max_fps_milli')) return null;
    } else {
      return null;
    }
    return NikoCameraFormat(
        raw['format_token'], schema, raw['width'], raw['height'],
        minFpsMilli: raw['min_fps_milli'],
        maxFpsMilli: raw['max_fps_milli'],
        fpsNum: raw['fps_num'],
        fpsDen: raw['fps_den']);
  }

  bool acceptsFps(int? fps) => schema == 'windows-native-v1'
      ? fps == null
      : fps != null &&
          fps > 0 &&
          fps <= 60 &&
          fps * 1000 >= minFpsMilli! &&
          fps * 1000 <= maxFpsMilli!;
}

class NikoCameraDevice {
  final String uid, name;
  final List<NikoCameraFormat> formats;
  const NikoCameraDevice(this.uid, this.name, this.formats);
  static NikoCameraDevice? parse(dynamic raw) {
    if (raw is! Map ||
        !_fields(raw, {'uid', 'name', 'formats'}) ||
        !_text(raw['uid'], 1024) ||
        !_text(raw['name'], 1024, empty: true) ||
        raw['formats'] is! List ||
        raw['formats'].length > 512) return null;
    final formats = <NikoCameraFormat>[];
    for (final value in raw['formats']) {
      final format = NikoCameraFormat.parse(value);
      if (format == null || formats.any((f) => f.token == format.token)) {
        return null;
      }
      formats.add(format);
    }
    return NikoCameraDevice(
        raw['uid'], raw['name'], List.unmodifiable(formats));
  }
}

class NikoCameraSelection {
  final String uid, token, schema;
  final int width, height, fpsNum, fpsDen;
  const NikoCameraSelection(this.uid, this.token, this.schema, this.width,
      this.height, this.fpsNum, this.fpsDen);
  static NikoCameraSelection? parse(dynamic raw) {
    if (raw is! Map ||
        !_fields(raw, {
          'uid',
          'format_token',
          'width',
          'height',
          'fps_num',
          'fps_den',
          'format_schema'
        }) ||
        !_text(raw['uid'], 1024) ||
        raw['format_token'] is! String ||
        !NikoCapabilityIdentity.validNonce(raw['format_token']) ||
        !{'mac-fps-range-v1', 'windows-native-v1'}
            .contains(raw['format_schema']) ||
        !_positive(raw['width'], 4096) ||
        !_positive(raw['height'], 4096) ||
        !_positive(raw['fps_num'], 4294967295) ||
        !_positive(raw['fps_den'], 4294967295)) return null;
    return NikoCameraSelection(
        raw['uid'],
        raw['format_token'],
        raw['format_schema'],
        raw['width'],
        raw['height'],
        raw['fps_num'],
        raw['fps_den']);
  }
}

class NikoCameraStatus {
  final NikoCapabilityIdentity identity;
  final String phase, reason, resourceEpoch, revision;
  final NikoCameraSelection? selection;
  const NikoCameraStatus(this.identity, this.phase, this.reason,
      this.resourceEpoch, this.revision, this.selection);
  static NikoCameraStatus? parse(String json) {
    if (json.length > 8192) return null;
    try {
      final raw = jsonDecode(json);
      if (raw is! Map ||
          !_fields(raw, {
            'identity',
            'kind',
            'phase',
            'reason',
            'resource_epoch',
            'revision',
            'selection'
          }) ||
          raw['kind'] != 'camera') return null;
      final identity = NikoCapabilityIdentity.parse(raw['identity']);
      final selection = raw['selection'] == null
          ? null
          : NikoCameraSelection.parse(raw['selection']);
      if (identity == null ||
          !{
            'Pending',
            'Starting',
            'Running',
            'Revoking',
            'RecoveryRequired',
            'Stopped'
          }.contains(raw['phase']) ||
          !_reason(raw['reason']) ||
          !_revision(raw['revision']) ||
          !_revision(raw['resource_epoch']) ||
          (raw['selection'] != null && selection == null)) return null;
      return NikoCameraStatus(identity, raw['phase'], raw['reason'],
          raw['resource_epoch'], raw['revision'], selection);
    } catch (_) {
      return null;
    }
  }
}

class NikoCameraCatalog {
  final NikoCapabilityIdentity identity;
  final String revision, rosterRevision, authorization, reason;
  final List<NikoCameraDevice> devices;
  const NikoCameraCatalog(this.identity, this.revision, this.rosterRevision,
      this.authorization, this.reason, this.devices);
  static NikoCameraCatalog? parse(String json) {
    if (json.length > 1048576) return null;
    try {
      final raw = jsonDecode(json);
      if (raw is! Map ||
          !_fields(raw, {
            'identity',
            'revision',
            'roster_revision',
            'authorization',
            'devices',
            'reason'
          })) return null;
      final identity = NikoCapabilityIdentity.parse(raw['identity']);
      if (identity == null ||
          !_revision(raw['revision']) ||
          !_revision(raw['roster_revision']) ||
          !_reason(raw['reason']) ||
          !{
            'not_determined',
            'authorized',
            'denied',
            'restricted',
            'unavailable'
          }.contains(raw['authorization']) ||
          raw['devices'] is! List ||
          raw['devices'].length > 64) return null;
      final devices = <NikoCameraDevice>[];
      var formatCount = 0;
      for (final value in raw['devices']) {
        final device = NikoCameraDevice.parse(value);
        if (device == null || devices.any((d) => d.uid == device.uid)) {
          return null;
        }
        formatCount += device.formats.length;
        if (formatCount > 4096) return null;
        devices.add(device);
      }
      return NikoCameraCatalog(
          identity,
          raw['revision'],
          raw['roster_revision'],
          raw['authorization'],
          raw['reason'],
          List.unmodifiable(devices));
    } catch (_) {
      return null;
    }
  }
}

/// CM's verified initial snapshot supplies the anchor; events cannot replace it.
class NikoCameraState {
  NikoCameraStatus status;
  NikoCameraCatalog? catalog;
  bool cleanupUnconfirmed = false;
  NikoCameraState(this.status);
  bool update(NikoCameraStatus value) {
    if (!status.identity.sameRequest(value.identity) ||
        BigInt.parse(value.revision) < BigInt.parse(status.revision) ||
        BigInt.parse(value.resourceEpoch) <
            BigInt.parse(status.resourceEpoch)) {
      return false;
    }
    if (value.revision == status.revision &&
        (value.phase != status.phase ||
            value.reason != status.reason ||
            value.resourceEpoch != status.resourceEpoch ||
            !_sameSelection(value.selection, status.selection))) return false;
    status = value;
    if (value.phase == 'Stopped') cleanupUnconfirmed = false;
    if (catalog?.revision != value.revision) catalog = null;
    return true;
  }

  bool markCleanup(NikoCameraStatus captured) {
    if (!status.identity.sameRequest(captured.identity) ||
        status.revision != captured.revision ||
        status.resourceEpoch != captured.resourceEpoch) return false;
    cleanupUnconfirmed = true;
    return true;
  }

  bool _sameSelection(NikoCameraSelection? a, NikoCameraSelection? b) =>
      a == null
          ? b == null
          : b != null &&
              a.uid == b.uid &&
              a.token == b.token &&
              a.schema == b.schema &&
              a.width == b.width &&
              a.height == b.height &&
              a.fpsNum == b.fpsNum &&
              a.fpsDen == b.fpsDen;

  bool acceptCatalog(NikoCameraCatalog value) {
    if (!status.identity.sameRequest(value.identity) ||
        value.revision != status.revision ||
        status.phase != 'Pending' ||
        (catalog != null &&
            BigInt.parse(value.rosterRevision) <
                BigInt.parse(catalog!.rosterRevision))) return false;
    catalog = value;
    return true;
  }
}

NikoCameraState nikoCameraAnchor(
    NikoCameraState? previous, NikoCameraStatus snapshot) {
  if (previous != null &&
      previous.status.identity.sameRequest(snapshot.identity)) {
    previous.update(snapshot);
    return previous;
  }
  return NikoCameraState(snapshot);
}

String nikoCameraCommand(NikoCameraStatus status, String op,
        {String? uid, String? rosterRevision, String? formatToken, int? fps}) =>
    jsonEncode({
      'identity': status.identity.toJson(),
      'revision': status.revision,
      'op': op,
      if (uid != null) 'uid': uid,
      if (rosterRevision != null) 'roster_revision': rosterRevision,
      if (formatToken != null) 'format_token': formatToken,
      if (fps != null) 'fps': fps,
    });

bool nikoCameraQueued(String json, NikoCameraStatus request) {
  if (json.length > 8192) return false;
  try {
    final raw = jsonDecode(json);
    if (raw is! Map ||
        !_fields(raw, {'ok', 'status', 'identity', 'revision', 'reason'})) {
      return false;
    }
    final identity = NikoCapabilityIdentity.parse(raw['identity']);
    return raw['ok'] == true &&
        raw['status'] == 'queued' &&
        identity != null &&
        identity.sameRequest(request.identity) &&
        raw['revision'] == request.revision &&
        _reason(raw['reason']);
  } catch (_) {
    return false;
  }
}
