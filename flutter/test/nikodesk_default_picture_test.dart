import 'package:flutter_hbb/generated_bridge.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/nikodesk/default_picture.dart';
import 'package:flutter_hbb/nikodesk/remote_resolution.dart' show nikoAutomaticFpsOption;
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

class _Model implements FfiModel {
  _Model(String version) : pi = PeerInfo()..version = version;
  @override
  final PeerInfo pi;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Session implements FFI {
  _Session({String version = '1.4.0'}) : ffiModel = _Model(version);
  @override
  final sessionId = const Uuid().v4obj();
  @override
  bool closed = false;
  @override
  final _Model ffiModel;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Bindings implements RustdeskImpl {
  _Bindings({this.saved = '', this.quality = 'balanced'});
  final String saved;
  final String quality;
  final writes = <String>[];
  @override
  Future<String> sessionGetPeerOption({required UuidValue sessionId, required String name, dynamic hint}) async =>
      name == 'nikodesk-picture-mode' ? saved : '';
  @override
  Future<String?> sessionGetImageQuality({required UuidValue sessionId, dynamic hint}) async => quality;
  @override
  Future<void> sessionSetImageQuality({required UuidValue sessionId, required String value, dynamic hint}) async =>
      writes.add('quality=$value');
  @override
  Future<void> sessionSetCustomImageQuality({required UuidValue sessionId, required int value, dynamic hint}) async =>
      writes.add('percent=$value');
  @override
  Future<void> sessionSetCustomFps({required UuidValue sessionId, required int fps, dynamic hint}) async =>
      writes.add('fps=$fps');
  @override
  Future<void> sessionPeerOption({required UuidValue sessionId, required String name, required String value, dynamic hint}) async =>
      writes.add('$name=$value');
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('an unchosen device starts responsive at the screen refresh rate', () async {
    final api = _Bindings();
    await nikoApplyDefaultPicture(_Session(), 120, bindings: api);
    expect(api.writes, ['quality=custom', 'percent=50', 'fps=120',
      '$nikoAutomaticFpsOption=120', 'nikodesk-picture-mode=smooth']);
  });

  test('an unknown refresh rate asks for 60', () async {
    final api = _Bindings();
    await nikoApplyDefaultPicture(_Session(), null, bindings: api);
    expect(api.writes, contains('fps=60'));
  });

  test('a chosen mode, a changed default quality or an old peer is left alone', () async {
    for (final api in [_Bindings(saved: 'office'), _Bindings(saved: 'custom'),
      _Bindings(quality: 'best'), _Bindings(quality: 'custom')]) {
      await nikoApplyDefaultPicture(_Session(), 120, bindings: api);
      expect(api.writes, isEmpty, reason: '${api.saved}/${api.quality}');
    }
    final old = _Bindings();
    await nikoApplyDefaultPicture(_Session(version: '1.1.9'), 120, bindings: old);
    expect(old.writes, isEmpty);
  });

  test('a closed session writes nothing', () async {
    final api = _Bindings();
    await nikoApplyDefaultPicture(_Session()..closed = true, 120, bindings: api);
    expect(api.writes, isEmpty);
  });
}
