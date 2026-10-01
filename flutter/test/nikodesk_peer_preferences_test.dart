import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/nikodesk/peer_preferences.dart';
import 'package:flutter_hbb/nikodesk/favorite_actions.dart';
import 'package:flutter_hbb/nikodesk/peer_event_scope.dart';
import 'package:flutter_hbb/models/peer_model.dart';
import 'package:flutter_hbb/nikodesk/peer_preferences_view.dart';
import 'package:flutter_hbb/nikodesk/theme.dart';
import 'package:flutter_hbb/nikodesk/ui.dart';

final _a = 'a' * 64;
final _b = 'b' * 64;
final _revision = 'c' * 64;

String _favorites(
        {bool conflict = false, List<String> ids = const ['123456789']}) =>
    jsonEncode({
      'ok': !conflict,
      'status': conflict ? 'conflict' : 'ready',
      'namespace': _a,
      'revision': _revision,
      'ids': ids
    });

String _preview({bool existing = false}) => jsonEncode({
      'ok': true,
      'status': 'preview',
      'namespace': _a,
      'revision': _revision,
      'requires_local_restart': true,
      'items': [
        {
          'id': '123456789',
          'alias': '工作电脑 / Work computer',
          'fields': ['options'],
          'target_exists': existing,
          'status': existing ? 'target_exists' : 'available'
        }
      ]
    });

class _Transport implements NikoPeerPreferencesTransport {
  String favoritesResponse = _favorites();
  String previewResponse = _preview();
  String importResponse =
      jsonEncode({'ok': false, 'status': 'peer_writers_not_coordinated'});
  Future<String> Function()? delayedFavorites;
  Future<String> Function()? delayedPatch;
  final calls = <List<Object>>[];
  @override
  Future<String> favorites(String namespace) async {
    calls.add(['read', namespace]);
    return delayedFavorites == null
        ? favoritesResponse
        : await delayedFavorites!();
  }

  @override
  Future<String> patchFavorites(String namespace, String revision,
      List<String> add, List<String> remove) async {
    calls.add(['patch', namespace, revision, add, remove]);
    return delayedPatch == null ? favoritesResponse : await delayedPatch!();
  }

  @override
  Future<String> previewLegacy(String namespace) async {
    calls.add(['preview', namespace]);
    return previewResponse;
  }

  @override
  Future<String> importLegacy(
      String namespace, String revision, List<String> ids) async {
    calls.add(['import', namespace, revision, ids]);
    return importResponse;
  }
}

Matcher _failure(String status) => isA<NikoPeerPreferencesFailure>()
    .having((error) => error.status, 'status', status);

void main() {
  test(
      'delayed, failed or unscoped peer events cannot replace the displayed list',
      () {
    final ready = {
      'nikodesk-server-namespace': _a,
      'nikodesk-load-status': 'ready',
      'peers': jsonEncode([
        {'id': '123456789', 'alias': 'Work'}
      ])
    };
    final event = nikoScopedPeerEvent(ready, _a)!;
    final peer =
        Peer.fromJson(event.peers.single, serverNamespace: event.namespace);
    expect(peer.serverNamespace, _a);
    expect(Peer.copy(peer).serverNamespace, _a);
    expect(peer.toJson().containsKey('serverNamespace'), isFalse);
    expect(
        Peer.fromJson({'id': '123456789', 'serverNamespace': _b})
            .serverNamespace,
        isNull);
    expect(nikoScopedPeerEvent(ready, _b), isNull);
    expect(nikoScopedPeerEvent({'peers': ready['peers']}, _a), isNull);
    expect(nikoScopedPeerEvent({...ready, 'nikodesk-load-status': 'error'}, _a),
        isNull);
    expect(nikoScopedPeerEvent({...ready, 'peers': 'not-json'}, _a), isNull);
    expect(
        nikoScopedPeerEvent({...ready, 'peers': '[{"id":"host.example"}]'}, _a),
        isNull);
  });

  test('favorite batch rejects mixed/stale/unscoped rows before native calls',
      () async {
    final transport = _Transport();
    final service = NikoPeerPreferences(transport, currentNamespace: () => _a);
    for (final rows in [
      [NikoFavoritePeerRef('123456789', null)],
      [NikoFavoritePeerRef('123456789', _b)],
      [
        NikoFavoritePeerRef('123456789', _a),
        NikoFavoritePeerRef('987654321', _b)
      ],
    ]) {
      await expectLater(nikoChangeFavorites(service, rows, favorite: true),
          throwsA(_failure('namespace_changed')));
    }
    expect(transport.calls, isEmpty);
  });

  test('displayed favorite selection uses captured scope and CAS patch only',
      () async {
    final transport = _Transport();
    final service = NikoPeerPreferences(transport, currentNamespace: () => _a);
    await nikoChangeFavorites(
        service,
        [
          NikoFavoritePeerRef('123456789', _a),
          NikoFavoritePeerRef('987654321', _a)
        ],
        favorite: false);
    expect(transport.calls, [
      ['read', _a],
      [
        'patch',
        _a,
        _revision,
        <String>[],
        ['123456789', '987654321']
      ]
    ]);
  });

  test('invalid or stale namespace never reaches native I/O', () async {
    final transport = _Transport();
    final service = NikoPeerPreferences(transport, currentNamespace: () => _b);
    await expectLater(
        service.readFavorites(_a), throwsA(_failure('namespace_changed')));
    await expectLater(service.previewLegacy('invalid'),
        throwsA(_failure('invalid_namespace')));
    expect(transport.calls, isEmpty);
  });

  test('server change while native read is pending cannot update the new scope',
      () async {
    final completer = Completer<String>();
    final transport = _Transport()..delayedFavorites = () => completer.future;
    var current = _a;
    final service =
        NikoPeerPreferences(transport, currentNamespace: () => current);
    final result = service.readFavorites(_a);
    final assertion =
        expectLater(result, throwsA(_failure('namespace_changed')));
    current = _b;
    completer.complete(_favorites());
    await assertion;
    expect(transport.calls.single, ['read', _a]);
  });

  test('disk failure is an error, never a successful empty favorite list',
      () async {
    final transport = _Transport()
      ..favoritesResponse = jsonEncode({'ok': false, 'status': 'disk_error'});
    final service = NikoPeerPreferences(transport, currentNamespace: () => _a);
    await expectLater(
        service.readFavorites(_a), throwsA(_failure('disk_error')));
  });

  test('CAS conflict returns current set without retrying or claiming saved',
      () async {
    final transport = _Transport();
    final service = NikoPeerPreferences(transport, currentNamespace: () => _a);
    final expected = await service.readFavorites(_a);
    transport.favoritesResponse =
        _favorites(conflict: true, ids: ['987654321']);
    final result = await service.patchFavorites(expected, add: ['111111111']);
    expect(result.conflict, isTrue);
    expect(result.ids, {'987654321'});
    expect(
        transport.calls.where((call) => call.first == 'patch'), hasLength(1));
    expect(transport.calls.last, [
      'patch',
      _a,
      _revision,
      ['111111111'],
      <String>[]
    ]);
  });

  test('mutation timeout remains unconfirmed and does not retry', () async {
    final pending = Completer<String>();
    final transport = _Transport()..delayedPatch = () => pending.future;
    final service = NikoPeerPreferences(transport,
        currentNamespace: () => _a, timeout: const Duration(milliseconds: 5));
    final expected = await service.readFavorites(_a);
    await expectLater(service.patchFavorites(expected, remove: ['123456789']),
        throwsA(_failure('timeout_unconfirmed')));
    pending.complete(_favorites(ids: []));
    expect(
        transport.calls.where((call) => call.first == 'patch'), hasLength(1));
  });

  test('malformed/foreign reply cannot replace a known favorite snapshot',
      () async {
    final transport = _Transport();
    final service = NikoPeerPreferences(transport, currentNamespace: () => _a);
    final expected = await service.readFavorites(_a);
    for (final bad in [
      {
        'ok': true,
        'status': 'saved',
        'namespace': _b,
        'revision': _revision,
        'ids': []
      },
      {
        'ok': true,
        'status': 'saved',
        'namespace': _a,
        'revision': _revision,
        'ids': ['123456789', '123456789']
      },
      {
        'ok': true,
        'status': 'saved',
        'namespace': _a,
        'revision': _revision,
        'ids': ['host.example']
      },
    ]) {
      transport.favoritesResponse = jsonEncode(bad);
      await expectLater(service.patchFavorites(expected, add: ['111111111']),
          throwsA(_failure('invalid_data')));
      expect(expected.ids, {'123456789'});
    }
  });

  test('import uses the exact preview scope/revision and explicit selection',
      () async {
    final transport = _Transport()
      ..importResponse = jsonEncode({
        'ok': true,
        'status': 'imported',
        'namespace': _a,
        'revision': _revision,
        'imported': ['123456789'],
        'skipped': {}
      });
    final service = NikoPeerPreferences(transport, currentNamespace: () => _a);
    final preview = await service.previewLegacy(_a);
    final result = await service.importLegacy(preview, ['123456789']);
    expect(result.confirmed, isTrue);
    expect(result.imported, {'123456789'});
    expect(transport.calls.last, [
      'import',
      _a,
      _revision,
      ['123456789']
    ]);
    await expectLater(service.importLegacy(preview, ['987654321']),
        throwsA(_failure('invalid_data')));
    expect(
        transport.calls.where((call) => call.first == 'import'), hasLength(1));
  });

  test(
      'existing targets cannot be submitted and partial native result is not success',
      () async {
    final transport = _Transport()..previewResponse = _preview(existing: true);
    final service = NikoPeerPreferences(transport, currentNamespace: () => _a);
    final existing = await service.previewLegacy(_a);
    await expectLater(service.importLegacy(existing, ['123456789']),
        throwsA(_failure('invalid_data')));
    expect(transport.calls.where((call) => call.first == 'import'), isEmpty);
    transport.previewResponse = _preview();
    transport.importResponse = jsonEncode({
      'ok': false,
      'status': 'partial_or_unconfirmed',
      'namespace': _a,
      'revision': _revision,
      'imported': [],
      'skipped': {},
      'failed': '123456789'
    });
    final result = await service
        .importLegacy(await service.previewLegacy(_a), ['123456789']);
    expect(result.confirmed, isFalse);
  });

  for (final conflict in [false, true]) {
    testWidgets('selected import can add favorites with conflict=$conflict',
        (tester) async {
      NikoLanguage.english = false;
      addTearDown(() => NikoLanguage.english = false);
      await tester.binding.setSurfaceSize(const Size(320, 760));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final changes = ValueNotifier<String?>(_a);
      addTearDown(changes.dispose);
      final transport = _Transport()
        ..favoritesResponse = _favorites(ids: [])
        ..previewResponse = jsonEncode(
            (jsonDecode(_preview()) as Map<String, dynamic>)
              ..['requires_local_restart'] = false)
        ..importResponse = jsonEncode({
          'ok': true,
          'status': 'imported',
          'namespace': _a,
          'revision': _revision,
          'imported': ['123456789'],
          'skipped': {}
        })
        ..delayedPatch = () async => _favorites(
            conflict: conflict, ids: conflict ? ['987654321'] : ['123456789']);
      await tester.pumpWidget(MaterialApp(
          theme: nikoTheme(Brightness.light),
          builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: const TextScaler.linear(2)),
              child: child!),
          home: NikoPeerPreferencesView(
              namespace: _a,
              scopeChanges: changes,
              preferences: NikoPeerPreferences(transport,
                  currentNamespace: () => changes.value))));
      await tester.pumpAndSettle();
      final favorites = find.byKey(const Key('peer-legacy-add-favorites'));
      expect(tester.widget<CheckboxListTile>(favorites).value, false);
      expect(find.textContaining('导入前需要关闭旧版本窗口'), findsNothing);
      expect(transport.calls.where((call) => call.first == 'import'), isEmpty);
      final selected = find.byKey(const Key('peer-legacy-select-123456789'));
      await tester.ensureVisible(selected);
      await tester.tap(selected);
      await tester.ensureVisible(favorites);
      await tester.tap(favorites);
      await tester.pumpAndSettle();
      await tester.tap(find.byType(FilledButton));
      await tester.pumpAndSettle();
      expect(transport.calls.where((call) => call.first == 'import'),
          hasLength(1));
      expect(transport.calls.where((call) => call.first == 'patch').single, [
        'patch',
        _a,
        _revision,
        ['123456789'],
        <String>[]
      ]);
      expect(find.textContaining('已确认导入 1 台'), findsOneWidget);
      expect(find.textContaining(conflict ? '本次未加入收藏' : '已确认加入收藏'),
          findsOneWidget);
      expect(tester.widget<CheckboxListTile>(favorites).value, false);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
  for (final english in [false, true]) {
    for (final brightness in [Brightness.light, Brightness.dark]) {
      testWidgets(
          'migration at 320/200% $english $brightness is explicit and reports blocked',
          (tester) async {
        NikoLanguage.english = english;
        addTearDown(() => NikoLanguage.english = false);
        await tester.binding.setSurfaceSize(const Size(320, 760));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final changes = ValueNotifier<String?>(_a);
        addTearDown(changes.dispose);
        final transport = _Transport();
        await tester.pumpWidget(MaterialApp(
            theme: nikoTheme(brightness),
            builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(2)),
                child: child!),
            home: NikoPeerPreferencesView(
                namespace: _a,
                scopeChanges: changes,
                preferences: NikoPeerPreferences(transport,
                    currentNamespace: () => changes.value))));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(
            transport.calls.where((call) => call.first == 'import'), isEmpty);
        expect(
            tester
                .widget<CheckboxListTile>(
                    find.byKey(const Key('peer-legacy-select-123456789')))
                .value,
            isFalse);
        final selected = find.descendant(
            of: find.byKey(const Key('peer-legacy-select-123456789')),
            matching: find.byType(Checkbox));
        await tester.ensureVisible(selected);
        await tester.pumpAndSettle();
        await tester.tap(selected);
        await tester.pumpAndSettle();
        await tester.tap(find.byType(FilledButton));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.textContaining(english ? 'Import is blocked' : '暂时无法确认'),
            findsOneWidget);
        expect(transport.calls.where((call) => call.first == 'import'),
            hasLength(1));
        expect(
            tester
                .widget<CheckboxListTile>(
                    find.byKey(const Key('peer-legacy-select-123456789')))
                .value,
            isFalse);
        changes.value = _b;
        await tester.pumpAndSettle();
        expect(find.byType(CheckboxListTile), findsNothing);
        expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
            isNull);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });
    }
  }
}
