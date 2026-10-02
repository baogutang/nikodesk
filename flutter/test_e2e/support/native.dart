// Drives the real native core through the same bridge the app uses, without
// any Flutter UI. Run only through scripts/e2e-local.sh: it supplies a core
// built with the development-profile switch, so nothing here can touch the
// real NikoDesk identity or the installed RustDesk.
import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_hbb/generated_bridge.dart';
import 'package:uuid/uuid.dart';

String env(String name) {
  final value = Platform.environment[name];
  if (value == null || value.isEmpty) {
    throw StateError('Missing $name. Run through scripts/e2e-local.sh.');
  }
  return value;
}

class NikoNative {
  NikoNative._(this.bind, this.profile, this.configDirectory);
  final RustdeskImpl bind;
  final String profile;
  final Directory configDirectory;
  final _global = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get globalEvents => _global.stream;

  static Future<NikoNative>? _starting;
  static Future<NikoNative> instance() => _starting ??= _start();

  static Future<NikoNative> _start() async {
    final profile = env('NIKODESK_DEV_PROFILE');
    final core = env('NIKODESK_E2E_CORE');
    // A core without the switch would silently use the real identity.
    final marker = Process.runSync(
        '/usr/bin/grep', ['-a', '-q', 'NIKODESK_DEV_PROFILE', core],
        environment: {'LC_ALL': 'C'});
    if (marker.exitCode != 0) {
      throw StateError('$core was not built with nikodesk-dev-profile');
    }
    final config = Directory(
        '${env('HOME')}/Library/Preferences/io.nikodesk.NikoDesk-$profile');
    final native = NikoNative._(
        RustdeskImpl(DynamicLibrary.open(core)), profile, config);
    native.bind.startGlobalEventStream(appType: 'main').listen((message) {
      try {
        native._global.add(jsonDecode(message) as Map<String, dynamic>);
      } catch (_) {}
    });
    await native.bind.mainDeviceId(id: 'e2e-$profile');
    await native.bind.mainDeviceName(name: 'NikoDesk E2E $profile');
    await native.bind.mainSetHomeDir(home: '');
    final work = Directory('${env('NIKODESK_E2E_WORK')}/$profile')
      ..createSync(recursive: true);
    await native.bind.mainInit(appDir: work.path, customClientConfig: '');
    if (!File('${config.path}/NikoDesk-$profile.toml').existsSync()) {
      throw StateError('The core did not select the "$profile" profile');
    }
    return native;
  }

  Future<Map<String, dynamic>> options() async =>
      jsonDecode(await bind.mainGetOptions()) as Map<String, dynamic>;

  /// Saves the private server through the same transaction the settings UI
  /// uses, and returns the server namespace sessions must be bound to.
  Future<String> configureServer() async {
    final wanted = {
      'idServer': env('NIKODESK_E2E_ID_SERVER'),
      'relayServer': env('NIKODESK_E2E_RELAY_SERVER'),
      'publicKey': env('NIKODESK_E2E_SERVER_KEY'),
    };
    final current = await options();
    if (current['custom-rendezvous-server'] != wanted['idServer'] ||
        current['relay-server'] != wanted['relayServer'] ||
        current['key'] != wanted['publicKey'] ||
        current['stop-service'] != 'N') {
      final reply =
          jsonDecode(await bind.mainNikoSavePrivateServer(config: jsonEncode(wanted)))
              as Map<String, dynamic>;
      if (reply['ok'] != true || reply['state'] != 'enabled') {
        throw StateError('Private server was not saved: $reply');
      }
    }
    final namespace = (await options())['nikodesk-server-namespace'];
    if (namespace is! String || namespace.length != 64) {
      throw StateError('No server namespace after saving the private server');
    }
    return namespace;
  }
}

/// One controller session. Collects every event the app's models would see.
class NikoSession {
  NikoSession._(this.native, this.id, this.peer);
  final NikoNative native;
  final UuidValue id;
  final String peer;
  final events = <Map<String, dynamic>>[];
  int frames = 0;
  DateTime? firstFrame;
  final _changed = StreamController<void>.broadcast();
  StreamSubscription<EventToUI>? _subscription;

  static Future<NikoSession> open(NikoNative native, String peer,
      {required String password,
      bool fileTransfer = false,
      bool terminal = false,
      bool viewCamera = false,
      bool forceRelay = false}) async {
    final namespace = await native.configureServer();
    final id = const Uuid().v4obj();
    final error = native.bind.sessionAddNikodeskSync(
        sessionId: id,
        id: peer,
        expectedServerNamespace: namespace,
        isFileTransfer: fileTransfer,
        isViewCamera: viewCamera,
        isPortForward: false,
        isRdp: false,
        isTerminal: terminal,
        switchUuid: '',
        forceRelay: forceRelay,
        password: password,
        isSharedPassword: false);
    if (error.isNotEmpty) throw StateError('Session was not created: $error');
    final session = NikoSession._(native, id, peer);
    session._subscription =
        native.bind.sessionStart(sessionId: id, id: peer).listen(session._on);
    return session;
  }

  void _on(EventToUI message) {
    if (message is EventToUI_Event) {
      try {
        events.add(jsonDecode(message.field0) as Map<String, dynamic>);
      } catch (_) {}
    } else if (message is EventToUI_Rgba) {
      frames++;
      firstFrame ??= DateTime.now();
      // The core holds the next frame until the previous one is released.
      native.bind.sessionNextRgba(sessionId: id, display: message.field0);
    }
    _changed.add(null);
  }

  Iterable<Map<String, dynamic>> named(String name) =>
      events.where((event) => event['name'] == name);

  /// Waits for the first event satisfying [test], including ones already seen.
  Future<Map<String, dynamic>> event(
      bool Function(Map<String, dynamic>) test, String what,
      {Duration timeout = const Duration(seconds: 30)}) async {
    final deadline = DateTime.now().add(timeout);
    var seen = 0;
    while (true) {
      for (; seen < events.length; seen++) {
        if (test(events[seen])) return events[seen];
      }
      final left = deadline.difference(DateTime.now());
      if (left <= Duration.zero) {
        throw TimeoutException(
            'No $what within ${timeout.inSeconds}s. Saw: ${summary()}');
      }
      await _changed.stream.first
          .timeout(left, onTimeout: () {});
    }
  }

  Future<void> until(bool Function() condition, String what,
      {Duration timeout = const Duration(seconds: 30)}) async {
    final deadline = DateTime.now().add(timeout);
    while (!condition()) {
      final left = deadline.difference(DateTime.now());
      if (left <= Duration.zero) {
        throw TimeoutException(
            'Not reached within ${timeout.inSeconds}s: $what. Saw: ${summary()}');
      }
      await _changed.stream.first.timeout(
          left < const Duration(milliseconds: 250)
              ? left
              : const Duration(milliseconds: 250),
          onTimeout: () {});
    }
  }

  /// Event names with counts, plus message-box texts. Never includes payloads
  /// that could carry addresses or credentials.
  String summary() {
    final counts = <String, int>{};
    for (final event in events) {
      final name = '${event['name']}';
      counts[name] = (counts[name] ?? 0) + 1;
    }
    final boxes = named('msgbox')
        .map((event) => '${event['type']}/${event['title']}/${event['text']}')
        .toList();
    return 'events=$counts frames=$frames msgbox=$boxes';
  }

  /// The last non-empty value of each quality field the core reported.
  Map<String, String> quality() {
    final latest = <String, String>{};
    for (final event in named('update_quality_status')) {
      for (final entry in event.entries) {
        final value = '${entry.value}';
        if (entry.key != 'name' && value.isNotEmpty && value != 'null') {
          latest[entry.key] = value;
        }
      }
    }
    return latest;
  }

  Future<void> close() async {
    // Closing the native session ends the stream; waiting on the stream's own
    // cancellation as well would never complete.
    await native.bind
        .sessionClose(sessionId: id)
        .timeout(const Duration(seconds: 10), onTimeout: () {});
    unawaited(_subscription?.cancel());
    unawaited(_changed.close());
  }
}
