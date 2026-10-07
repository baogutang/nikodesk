import 'dart:ui' as ui;
import 'dart:async';

// fake_async is supplied by flutter_test's locked dependency graph.
// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_hbb/generated_bridge.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/nikodesk/connection_progress.dart';
import 'package:flutter_hbb/nikodesk/remote_resolution.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

class _Canvas extends ChangeNotifier implements CanvasModel {
  @override
  ui.Size get size => const ui.Size(900, 600);
  void changed() => notifyListeners();
  bool get observed => hasListeners;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Progress extends NikoConnectionProgress {
  bool get observed => hasListeners;
}

class _Model implements FfiModel {
  @override
  final pi = PeerInfo()..version = '1.4.0';
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Bindings implements RustdeskImpl {
  final options = <String, String>{nikoCaptureModeOption: '',
    nikoCaptureWidthOption: '3840', 'custom-fps': '120',
    'nikodesk-picture-mode': 'smooth', nikoAutomaticFpsOption: '120'};
  final writes = <String>[];
  Completer<void>? pendingFps;
  @override
  Future<String?> sessionGetOption({required UuidValue sessionId, required String arg, dynamic hint}) async => options[arg];
  @override
  Future<String> sessionGetPeerOption({required UuidValue sessionId, required String name, dynamic hint}) async => options[name] ?? '';
  @override
  Future<void> sessionPeerOption({required UuidValue sessionId, required String name, required String value, dynamic hint}) async {
    writes.add('$name=$value');
    options[name] = value;
  }
  @override
  Future<String?> sessionGetViewStyle({required UuidValue sessionId, dynamic hint}) async => 'adaptive';
  @override
  Future<String?> sessionGetImageQuality({required UuidValue sessionId, dynamic hint}) async => 'custom';
  @override
  Future<Int32List?> sessionGetCustomImageQuality({required UuidValue sessionId, dynamic hint}) async => Int32List.fromList([50]);
  @override
  Future<void> sessionSetCustomFps({required UuidValue sessionId, required int fps, dynamic hint}) async {
    writes.add('fps=$fps');
    options['custom-fps'] = '$fps';
    final pending = pendingFps;
    pendingFps = null;
    if (pending != null) await pending.future;
  }
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// Native bridges are never initialized. Requests use explicit in-memory
// bindings; the real controller owns its listeners, debounce and cancellation.
class _Session implements FFI {
  @override
  final sessionId = const Uuid().v4obj();
  @override
  bool closed = false;
  @override
  var connType = ConnType.defaultConn;
  @override
  final _Canvas canvasModel = _Canvas();
  @override
  final ffiModel = _Model();
  @override
  final _Progress nikoConnectionProgress = _Progress()
    ..value = const NikoConnectionState(NikoConnectionPhase.connected);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a window requests its own canvas pixels, not its whole screen', (tester) async {
    tester.view.physicalSize = const ui.Size(1800, 1200);
    tester.view.devicePixelRatio = 2;
    tester.view.display.size = const ui.Size(3840, 2160);
    addTearDown(tester.view.reset);
    addTearDown(tester.view.display.reset);
    expect(nikoLocalLongEdge(view: tester.view), 1800);
    expect(nikoLocalLongEdge(view: tester.view, viewport: const ui.Size(820, 520)), 1640);
    tester.view.display.size = const ui.Size(7680, 4320);
    expect(nikoLocalLongEdge(view: tester.view, viewport: const ui.Size(820, 520)), 1640);
  });

  testWidgets('Retina backing demand is capped to the associated display', (tester) async {
    tester.view.physicalSize = const ui.Size(5120, 2880);
    tester.view.devicePixelRatio = 2;
    tester.view.display.size = const ui.Size(4480, 2520);
    addTearDown(tester.view.reset);
    addTearDown(tester.view.display.reset);
    expect(nikoLocalLongEdge(view: tester.view), 4480);
    tester.view.physicalSize = ui.Size.zero;
    expect(nikoLocalLongEdge(view: tester.view), 0);
  });

  testWidgets('refresh follows the view display and unknown remains unknown', (tester) async {
    addTearDown(tester.view.display.reset);
    tester.view.display.refreshRate = 60;
    expect(nikoViewRefreshRate(tester.view), 60);
    tester.view.display.refreshRate = 120;
    expect(nikoViewRefreshRate(tester.view), 120);
    tester.view.display.refreshRate = 0;
    expect(nikoViewRefreshRate(tester.view), isNull);
  });

  test('fit resizes have hysteresis and native/manual modes retain intent', () {
    expect(nikoCaptureWidthNeedsUpdate(1920, 1919), isFalse);
    expect(nikoCaptureWidthNeedsUpdate(1920, 1800), isFalse);
    expect(nikoCaptureWidthNeedsUpdate(1920, 1600), isTrue);
    expect(nikoCaptureWidthNeedsUpdate(1600, 1920), isTrue);
    expect(nikoCaptureWidthNeedsUpdate(nikoNativeCaptureWidth, 1920), isTrue);
    expect(nikoCaptureWidthNeedsUpdate(1920, nikoNativeCaptureWidth), isTrue);
    expect(nikoSessionCaptureWidth(NikoCaptureMode.fit, 900, 'adaptive'), 900);
    expect(nikoSessionCaptureWidth(NikoCaptureMode.fit, 900, 'original'), nikoNativeCaptureWidth);
    expect(nikoSessionCaptureWidth(NikoCaptureMode.fit, 900, 'custom'), nikoNativeCaptureWidth);
    expect(nikoSessionCaptureWidth(NikoCaptureMode.native, 900, 'adaptive'), nikoNativeCaptureWidth);
    expect(nikoSessionCaptureWidth(NikoCaptureMode.small, 900, 'original'), nikoSmallestCaptureWidth);
  });

  test('automatic FPS never overrides an untracked or manually changed request', () {
    int? next({String? saved = 'smooth', int? managed = 120, int? fps = 120,
        String? quality = 'custom', int? percent = 50, double? rate = 60}) =>
        nikoAutomaticFpsUpdate(savedMode: saved, managed: managed, current: fps,
            quality: quality, percent: percent, refreshRate: rate);
    expect(next(), 60);
    expect(next(managed: 60, fps: 60, rate: 120), 120);
    expect(next(managed: null), isNull); // Existing 1.0.6 preference is ambiguous.
    expect(next(saved: 'custom'), isNull);
    expect(next(fps: 90), isNull); // Manual legacy FPS changed after the preset.
    expect(next(quality: 'best'), isNull);
    expect(next(percent: 70), isNull);
    expect(next(rate: null), isNull);
    expect(next(rate: double.nan), isNull);
    expect(next(rate: 120), isNull);
  });

  testWidgets('resize bursts debounce once and disposal removes both listeners', (tester) async {
    fakeAsync((clock) {
      final ffi = _Session();
      final watcher = NikoSessionViewport(ffi)..updateView(tester.view);
      for (var i = 0; i < 20; ++i) {
        clock.elapse(const Duration(milliseconds: 20));
        ffi.canvasModel.changed();
      }
      expect(clock.nonPeriodicTimerCount, 1);
      expect(ffi.canvasModel.observed, isTrue);
      expect(ffi.nikoConnectionProgress.observed, isTrue);
      watcher.dispose();
      expect(clock.nonPeriodicTimerCount, 0);
      expect(ffi.canvasModel.observed, isFalse);
      expect(ffi.nikoConnectionProgress.observed, isFalse);
      clock.elapse(const Duration(seconds: 1));
    });
  });

  testWidgets('disconnect cancels the queued resize before any native request', (tester) async {
    fakeAsync((clock) {
      final ffi = _Session();
      final watcher = NikoSessionViewport(ffi)..updateView(tester.view);
      expect(clock.nonPeriodicTimerCount, 1);
      ffi.nikoConnectionProgress.value = const NikoConnectionState(NikoConnectionPhase.reconnecting);
      expect(clock.nonPeriodicTimerCount, 0);
      ffi.nikoConnectionProgress.value = const NikoConnectionState(NikoConnectionPhase.connected);
      expect(clock.nonPeriodicTimerCount, 1);
      nikoCancelViewportUpdate(ffi.sessionId);
      expect(clock.nonPeriodicTimerCount, 0);
      watcher.dispose();
    });
  });

  testWidgets('real viewport updater sends one canvas request and follows a 60Hz screen', (tester) async {
    tester.view.devicePixelRatio = 2;
    tester.view.physicalSize = const ui.Size(1920, 1200);
    tester.view.display.size = const ui.Size(3840, 2160);
    tester.view.display.refreshRate = 60;
    addTearDown(tester.view.reset);
    addTearDown(tester.view.display.reset);
    final ffi = _Session();
    final api = _Bindings();
    final watcher = NikoSessionViewport(ffi, bindings: api)..updateView(tester.view);
    addTearDown(watcher.dispose);
    for (var i = 0; i < 8; ++i) {
      await tester.pump(const Duration(milliseconds: 50));
      watcher.schedule();
    }
    expect(api.writes, isEmpty);
    await tester.pump(const Duration(milliseconds: 650));
    expect(api.writes, ['nikodesk-capture-width=1800', 'fps=60', '$nikoAutomaticFpsOption=60']);
    watcher.schedule();
    await tester.pump(const Duration(milliseconds: 650));
    expect(api.writes.length, 3);
  });

  testWidgets('manual 120FPS remains fixed after stopping automatic 120FPS and moving to 60Hz', (tester) async {
    tester.view.display.refreshRate = 60;
    addTearDown(tester.view.display.reset);
    final ffi = _Session();
    final api = _Bindings()..options[nikoCaptureModeOption] = 'native';
    final watcher = NikoSessionViewport(ffi, bindings: api)..updateView(tester.view);
    addTearDown(watcher.dispose);
    // The same native calls, in the same order as the legacy FPS callback.
    await nikoStopAutomaticFps(ffi.sessionId, bindings: api);
    await api.sessionSetCustomFps(sessionId: ffi.sessionId, fps: 120);
    watcher.schedule();
    await tester.pump(const Duration(milliseconds: 650));
    expect(api.writes, ['$nikoAutomaticFpsOption=', 'fps=120']);
    expect(api.options['custom-fps'], '120');
    expect(api.options[nikoCaptureWidthOption], '3840');
  });

  testWidgets('resize during FPS acknowledgement preserves marker and samples the latest screen', (tester) async {
    tester.view.display.refreshRate = 60;
    addTearDown(tester.view.display.reset);
    final ffi = _Session();
    final committed = Completer<void>();
    final api = _Bindings()..options[nikoCaptureModeOption] = 'native'
      ..pendingFps = committed;
    final watcher = NikoSessionViewport(ffi, bindings: api)..updateView(tester.view);
    addTearDown(watcher.dispose);
    await tester.pump(const Duration(milliseconds: 650));
    expect(api.options['custom-fps'], '60');
    expect(api.options[nikoAutomaticFpsOption], '120');
    tester.view.display.refreshRate = 120;
    watcher.schedule();
    committed.complete();
    await tester.pump();
    expect(api.options[nikoAutomaticFpsOption], '60');
    await tester.pump(const Duration(milliseconds: 650));
    expect(api.options['custom-fps'], '120');
    expect(api.options[nikoAutomaticFpsOption], '120');
  });

  testWidgets('manual FPS during automatic acknowledgement wins over the old marker', (tester) async {
    tester.view.display.refreshRate = 60;
    addTearDown(tester.view.display.reset);
    final ffi = _Session();
    final committed = Completer<void>();
    final api = _Bindings()..options[nikoCaptureModeOption] = 'native'
      ..pendingFps = committed;
    final watcher = NikoSessionViewport(ffi, bindings: api)..updateView(tester.view);
    addTearDown(watcher.dispose);
    await tester.pump(const Duration(milliseconds: 650));
    await nikoStopAutomaticFps(ffi.sessionId, bindings: api);
    await api.sessionSetCustomFps(sessionId: ffi.sessionId, fps: 120);
    committed.complete();
    await tester.pump();
    watcher.schedule();
    await tester.pump(const Duration(milliseconds: 650));
    expect(api.options['custom-fps'], '120');
    expect(api.options[nikoAutomaticFpsOption], isEmpty);
    expect(api.writes.last, 'fps=120');
  });
}
