import 'package:flutter/material.dart';

import 'peer_preferences.dart';
import 'server_scope.dart';
import 'ui.dart';

Future<void> showNikoPeerPreferences(BuildContext context,
        NikoPeerPreferences preferences, String namespace) =>
    showDialog<void>(
        context: context,
        builder: (_) => NikoPeerPreferencesView(
            preferences: preferences, namespace: namespace));

/// Explicitly attribute legacy connection preferences to the captured server.
/// The native importer keeps originals and confirms each published target.
class NikoPeerPreferencesView extends StatefulWidget {
  final NikoPeerPreferences preferences;
  final String namespace;
  final ValueNotifier<String?>? scopeChanges;
  const NikoPeerPreferencesView(
      {super.key,
      required this.preferences,
      required this.namespace,
      this.scopeChanges});

  @override
  State<NikoPeerPreferencesView> createState() =>
      _NikoPeerPreferencesViewState();
}

class _NikoPeerPreferencesViewState extends State<NikoPeerPreferencesView> {
  NikoLegacyPreview? _preview;
  final _selected = <String>{};
  bool _busy = false;
  bool _addFavorites = false;
  bool _scopeChanged = false;
  String? _message;
  int _generation = 0;
  ValueNotifier<String?> get _changes =>
      widget.scopeChanges ?? NikoServerScope.changes;

  @override
  void initState() {
    super.initState();
    _changes.addListener(_onScopeChanged);
    _load();
  }

  @override
  void dispose() {
    _changes.removeListener(_onScopeChanged);
    _generation++;
    super.dispose();
  }

  void _onScopeChanged() {
    if (_changes.value == widget.namespace || !mounted) return;
    _generation++;
    setState(() {
      _scopeChanged = true;
      _busy = false;
      _preview = null;
      _selected.clear();
      _addFavorites = false;
      _message = nikoText('服务器已变更，请关闭此窗口后重新查看。',
          'The server changed. Close this dialog and open it again.');
    });
  }

  String _failure(String status) {
    switch (status) {
      case 'peer_writers_not_coordinated':
        return nikoText('暂时无法确认旧窗口已停止写入，未执行导入。旧数据已保留。',
            'Import is blocked because writes from older windows cannot be ruled out. Original data is preserved.');
      case 'revision_changed':
        return nikoText('旧数据已变更，请重新查看再选择。',
            'Legacy data changed. Refresh the preview before selecting again.');
      case 'namespace_changed':
        return nikoText(
            '服务器已变更，请重新打开此窗口。', 'The server changed. Open this dialog again.');
      case 'timeout_unconfirmed':
      case 'write_unconfirmed':
        return nikoText('无法确认导入结果。请重新查看；不要重复提交旧的选择。',
            'The import result is unconfirmed. Refresh the preview before trying again.');
      default:
        return nikoText('无法安全读取或导入这些偏好，请稍后重试。',
            'These preferences could not be safely read or imported. Retry later.');
    }
  }

  Future<void> _load({String? message}) async {
    if (_scopeChanged || _busy) return;
    final generation = ++_generation;
    setState(() {
      _busy = true;
      _message = message;
      _selected.clear();
      _addFavorites = false;
    });
    try {
      final preview = await widget.preferences.previewLegacy(widget.namespace);
      if (!mounted || generation != _generation) return;
      setState(() => _preview = preview);
    } on NikoPeerPreferencesFailure catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _preview = null;
        _message = _failure(error.status);
      });
    } finally {
      if (mounted && generation == _generation) setState(() => _busy = false);
    }
  }

  Future<void> _import() async {
    final preview = _preview;
    if (_busy || _scopeChanged || preview == null || _selected.isEmpty) return;
    final generation = ++_generation;
    final selected = Set<String>.of(_selected);
    final addFavorites = _addFavorites;
    setState(() {
      _busy = true;
      _message = null;
    });
    String message;
    try {
      final result = await widget.preferences.importLegacy(preview, selected);
      message = result.confirmed
          ? nikoText(
              '已确认导入 ${result.imported.length} 台；跳过 ${result.skipped.length} 台。',
              '${result.imported.length} imported; ${result.skipped.length} skipped.')
          : nikoText('部分结果尚未确认，请核对新预览。已确认导入 ${result.imported.length} 台，原文件保留。',
              'Some results are unconfirmed. Check the refreshed preview. ${result.imported.length} imports were confirmed; originals are preserved.');
      if (addFavorites && result.imported.isNotEmpty) {
        if (!mounted || generation != _generation) return;
        try {
          final expected =
              await widget.preferences.readFavorites(widget.namespace);
          if (!mounted || generation != _generation) return;
          final saved = await widget.preferences
              .patchFavorites(expected, add: result.imported);
          message += saved.conflict
              ? nikoText(' 收藏列表已变更，本次未加入收藏。请在设备列表重新选择。',
                  ' The favorites changed; this addition was not saved. Select the devices again in the device list.')
              : result.imported.every(saved.ids.contains)
                  ? nikoText(' 已确认加入收藏。', ' Added to favorites.')
                  : nikoText(' 收藏结果尚未确认，请刷新收藏列表。',
                      ' Favorites are unconfirmed. Refresh the favorites list.');
        } on NikoPeerPreferencesFailure {
          message += nikoText(' 收藏结果尚未确认，请刷新收藏列表。',
              ' Favorites are unconfirmed. Refresh the favorites list.');
        }
      }
    } on NikoPeerPreferencesFailure catch (error) {
      message = _failure(error.status);
    }
    if (!mounted || generation != _generation) return;
    // A timeout or partial write can have published targets. Invalidate the
    // old selection/revision and read again rather than resubmitting it.
    setState(() {
      _busy = false;
      _preview = null;
      _selected.clear();
    });
    await _load(message: message);
  }

  @override
  Widget build(BuildContext context) {
    final preview = _preview;
    return AlertDialog(
      insetPadding: const EdgeInsets.all(12),
      title: Text(nikoText('旧连接偏好', 'Legacy connection preferences')),
      content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
              child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(nikoText(
                  '选择确实属于当前私有服务器的设备。导入显示、控制和别名等偏好；不导入密码。原文件保留，已有偏好会跳过。',
                  'Select devices that belong to the current private server. Import display, control and alias preferences without passwords. Originals are preserved; existing preferences are skipped.')),
              if (preview?.requiresLocalRestart == true) ...[
                const SizedBox(height: 12),
                Text(nikoText('导入前需要关闭旧版本窗口；程序会检查是否可以安全写入。',
                    'Close older app windows before importing. The app checks that writes are safe.')),
              ],
              const SizedBox(height: 12),
              if (_busy) const LinearProgressIndicator(),
              if (_message != null) ...[
                const SizedBox(height: 12),
                Semantics(liveRegion: true, child: Text(_message!)),
              ],
              if (preview != null && preview.items.isEmpty)
                Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: Text(nikoText('没有可归属的旧连接偏好。',
                        'No legacy connection preferences to attribute.'))),
              if (preview != null)
                for (final item in preview.items)
                  CheckboxListTile(
                    key: ValueKey('peer-legacy-select-${item.id}'),
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    value: _selected.contains(item.id),
                    onChanged: _busy || _scopeChanged || item.targetExists
                        ? null
                        : (on) {
                            setState(() {
                              on == true
                                  ? _selected.add(item.id)
                                  : _selected.remove(item.id);
                            });
                          },
                    title: Text(item.alias.isEmpty ? item.id : item.alias),
                    subtitle: Text(item.targetExists
                        ? nikoText('${item.id} · 已有偏好，跳过',
                            '${item.id} · Already configured; skipped')
                        : item.fieldCount == 0
                            ? nikoText(
                                '可导入设备记录', 'Device record available to import')
                            : item.alias.isEmpty
                                ? nikoText('可选择导入', 'Available to import')
                                : item.id),
                  ),
              if (preview != null &&
                  preview.items.any((item) => !item.targetExists))
                CheckboxListTile(
                  key: const Key('peer-legacy-add-favorites'),
                  contentPadding: EdgeInsets.zero,
                  value: _addFavorites,
                  onChanged: _busy || _scopeChanged
                      ? null
                      : (on) => setState(() => _addFavorites = on == true),
                  title: Text(nikoText('将本次成功导入的设备加入收藏',
                      'Add successfully imported devices to favorites')),
                ),
            ],
          ))),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(nikoText('关闭', 'Close'))),
        TextButton(
            onPressed: _busy || _scopeChanged ? null : _load,
            child: Text(nikoText('重新查看', 'Refresh preview'))),
        FilledButton(
            onPressed:
                _busy || _scopeChanged || _selected.isEmpty ? null : _import,
            child: Text(nikoText('归属并导入', 'Attribute and import'))),
      ],
    );
  }
}
