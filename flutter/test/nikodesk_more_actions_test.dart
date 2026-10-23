import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/common/widgets/toolbar.dart' show TTextMenu;
import 'package:flutter_hbb/nikodesk/mobile_more_actions.dart';
import 'package:flutter_hbb/nikodesk/nightline.dart';
import 'package:flutter_hbb/nikodesk/theme.dart';
import 'package:flutter_hbb/nikodesk/ui.dart';

// Stock menu models stand in for a session; no FFI call is made.
String _zh(String key) =>
    const {
      'OS Password': '操作系统密码',
      'Restart remote device': '重启远程电脑',
      'Refresh': '刷新画面',
      'Back': '回退',
    }[key] ??
    key;

void main() {
  tearDown(() => NikoLanguage.english = false);

  test('labels come from the text of a stock entry', () {
    expect(nikoMenuLabel(const Text('Refresh')), 'Refresh');
    expect(
        nikoMenuLabel(Row(children: const [
          Icon(Icons.edit),
          Padding(padding: EdgeInsets.zero, child: Text('OS Password')),
        ])),
        'OS Password');
    expect(nikoMenuLabel(const Text.rich(TextSpan(text: 'Note'))), 'Note');
    expect(
        nikoMenuLabel(Builder(builder: (_) => const Text('hidden'))), isNull);
  });

  test('entries keep stock handlers, icons, order and dividers', () {
    final calls = <String>[];
    TTextMenu menu(String label, {bool enabled = true}) => TTextMenu(
        child: Text(_zh(label)),
        onPressed: enabled ? () => calls.add(label) : null);
    final entries = nikoMoreActionEntries(phone: [
      menu('Back')
    ], controls: [
      TTextMenu(child: const Offstage(), onPressed: () {}, divider: true),
      menu('OS Password'),
      menu('Refresh'),
      TTextMenu(child: const Offstage(), onPressed: () {}, divider: true),
      TTextMenu(child: const Offstage(), onPressed: () {}, divider: true),
      menu('Restart remote device', enabled: false),
      TTextMenu(child: const Offstage(), onPressed: () {}, divider: true),
    ], translate: _zh, onEditOsPassword: () => calls.add('edit'))!;

    final shape = [
      for (final entry in entries)
        switch (entry) {
          NlMenuHeader(:final label) => 'header $label',
          NlMenuDivider() => 'divider',
          NlMenuItem(:final label) => label,
        }
    ];
    expect(shape, [
      'header 远端手机',
      '回退',
      'divider',
      '操作系统密码',
      '修改系统密码',
      '刷新画面',
      'divider',
      '重启远程电脑',
    ]);
    final items = entries.whereType<NlMenuItem>().toList();
    expect(items.map((e) => e.icon), [
      NlIcons.arrowLeft,
      NlIcons.keyRound,
      NlIcons.pencil,
      NlIcons.refreshCw,
      NlIcons.rotateCw,
    ]);
    final restart = items.last;
    expect(restart.danger, isTrue);
    expect(restart.enabled, isFalse);
    for (final item in items) {
      item.onSelected?.call();
    }
    expect(calls, ['Back', 'OS Password', 'edit', 'Refresh']);
  });

  test('an entry without a label keeps the stock menu', () {
    expect(
        nikoMoreActionEntries(phone: const [], controls: [
          TTextMenu(child: const Text('Refresh'), onPressed: () {}),
          TTextMenu(
              child: Builder(builder: (_) => const Text('Lazy')),
              onPressed: () {}),
        ], translate: (key) => key),
        isNull);
  });

  for (final english in [false, true]) {
    testWidgets('menu opens by its button on a phone ($english)',
        (tester) async {
      NikoLanguage.english = english;
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final calls = <String>[];
      await tester.pumpWidget(MaterialApp(
          theme:
              nikoTheme(Brightness.dark).copyWith(platform: TargetPlatform.iOS),
          home: Scaffold(
              body: Align(
                  alignment: const Alignment(.6, .95),
                  child: Builder(
                      builder: (button) => IconButton(
                          tooltip: 'More',
                          icon: const Icon(NlIcons.ellipsis),
                          onPressed: () => showNlMenu(button,
                              anchor: nlAnchorOf(button),
                              entries: nikoMoreActionEntries(
                                  phone: const [],
                                  controls: [
                                    for (final label in [
                                      'Send clipboard keystrokes',
                                      'Insert Ctrl + Alt + Del',
                                      'Refresh',
                                    ])
                                      TTextMenu(
                                          child: Text(label),
                                          onPressed: () => calls.add(label)),
                                  ],
                                  translate: (key) => key)!)))))));
      final button = tester.getRect(find.byTooltip('More'));
      await tester.tap(find.byTooltip('More'));
      await tester.pumpAndSettle();
      final refresh = find.text('Refresh');
      expect(refresh, findsOneWidget);
      // The menu rises above the dock button and stays on screen.
      final menu = tester.getRect(refresh);
      expect(menu.bottom, lessThan(button.top));
      expect(menu.right, lessThanOrEqualTo(390));
      await tester.tap(refresh);
      await tester.pumpAndSettle();
      expect(calls, ['Refresh']);
      expect(find.text('Refresh'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}
