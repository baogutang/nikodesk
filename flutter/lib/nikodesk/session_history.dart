import 'package:flutter/material.dart';
import 'connect_dialog.dart';
import 'home_chrome.dart';
import 'server_gateway.dart';
import 'server_scope.dart';

import 'session_log.dart';
import 'session_audit_view.dart';
import 'history_kit.dart';
import 'home_board.dart';
import 'nightline.dart';
import 'settings_kit.dart';
import 'theme.dart';
import 'ui.dart';

/// Local history of sessions this client initiated. Entries record what was
/// requested from this Mac; they do not claim the remote side accepted.
class NikoSessionHistoryPage extends StatefulWidget {
  final SessionLogStore? store;
  final ServerGateway? gateway;
  final bool active;
  final Future<void> Function(BuildContext, String, bool,
      {bool isFileTransfer, String? password})? onConnect;
  const NikoSessionHistoryPage(
      {super.key,
      this.store,
      this.onConnect,
      this.gateway,
      this.active = true});
  @override
  State<NikoSessionHistoryPage> createState() => _NikoSessionHistoryPageState();
}

class _NikoSessionHistoryPageState extends State<NikoSessionHistoryPage> {
  late final _store = widget.store ?? SessionLogStore.instance;
  List<SessionLogEntry> _entries = [];
  bool _loading = true;
  String? _error;
  int _refreshGeneration = 0;
  bool _showNativeHistory = true;
  bool get _nativeHistory =>
      const bool.fromEnvironment('NIKODESK') && widget.store == null;

  @override
  void initState() {
    super.initState();
    if (!_nativeHistory) _refresh();
  }

  @override
  void didUpdateWidget(covariant NikoSessionHistoryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active &&
        !oldWidget.active &&
        (!_nativeHistory || !_showNativeHistory)) _refresh();
  }

  Future<void> _refresh() async {
    final generation = ++_refreshGeneration;
    try {
      final result = await _store.load();
      if (!mounted || generation != _refreshGeneration) return;
      setState(() {
        _entries = result.entries;
        _loading = false;
        _error = null;
      });
    } catch (_) {
      if (mounted && generation == _refreshGeneration) {
        setState(() {
          _loading = false;
          _error = nikoText('读取会话记录失败。请检查本地文件权限。',
              'Could not read the session history. Check local file permissions.');
        });
      }
    }
  }

  Future<void> _clear() async {
    final confirmed = await showNlDialog<bool>(
        context: context,
        builder: (dialog) => NlDialog(
                title: nikoText('清空会话记录', 'Clear session history'),
                message: nikoText('仅删除本机的发起记录，不影响设备目录和远端设备。',
                    'Only local initiation records are removed. Devices and remotes are unchanged.'),
                actions: [
                  NlButton.ghost(
                      onPressed: () => Navigator.pop(dialog, false),
                      label: nikoText('取消', 'Cancel')),
                  NlButton.danger(
                      autofocus: true,
                      onPressed: () => Navigator.pop(dialog, true),
                      label: nikoText('清空', 'Clear')),
                ]));
    if (confirmed != true) return;
    try {
      await _store.clear();
      await _refresh();
    } catch (_) {
      if (mounted) {
        nikoNotice(
            context, nikoText('清空失败，请重试。', 'Clear failed. Please retry.'));
      }
    }
  }

  Future<void> _reconnect(SessionLogEntry entry) async {
    final dispatched = await nikoConnectWithPassword(context,
        id: entry.id,
        alias: entry.alias,
        fileTransfer: entry.fileTransfer,
        forceRelay: entry.forceRelay,
        gateway: widget.gateway,
        expectedServerNamespace: NikoServerScope.current ?? _store.serverNamespace,
        onConnect: widget.onConnect);
    if (!dispatched) return;
    try {
      await _store.record(SessionLogEntry(
          id: entry.id,
          alias: entry.alias,
          fileTransfer: entry.fileTransfer,
          forceRelay: entry.forceRelay,
          startedAt: DateTime.now().toUtc()));
      await _refresh();
    } catch (_) {
      if (mounted) {
        nikoNotice(
            context,
            nikoText('连接已发起，但无法保存历史记录。',
                'The session was started, but history could not be saved.'));
      }
    }
  }

  Future<void> _reconnectResult(
      String id, bool fileTransfer, String namespace) async {
    await nikoConnectWithPassword(context,
        id: id,
        fileTransfer: fileTransfer,
        gateway: widget.gateway,
        expectedServerNamespace:
            NikoServerScope.validate(namespace) ?? NikoServerScope.current ?? _store.serverNamespace,
        onConnect: widget.onConnect);
  }

  @override
  Widget build(BuildContext context) {
    if (_nativeHistory && _showNativeHistory) {
      return FocusTraversalGroup(
          child: NlScrollWatcher(
              header: (context, scrolled) => NikoPageBar(
                      title: nikoText('会话记录', 'Session history'),
                      subtitle: nikoText('每次会话的认证与结果', 'How each session went'),
                      divider: scrolled,
                      actions: [
                        NlButton.ghost(
                            key: const ValueKey('niko-history-show-attempts'),
                            small: true,
                            icon: NlIcons.history,
                            onPressed: () {
                              setState(() => _showNativeHistory = false);
                              _refresh();
                            },
                            label: nikoText('查看发起记录', 'View initiation history')),
                      ]),
              child: NikoNativeSessionHistory(
                  namespace:
                      NikoServerScope.current ?? _store.serverNamespace ?? '',
                  active: widget.active,
                  onReconnect: _reconnectResult)));
    }
    final nightline = NlColors.maybeOf(context);
    if (nightline != null) return _nightlinePage(context, nightline);
    final muted =
        nikoIsLight(context) ? NikoPalette.lightMuted : NikoPalette.darkMuted;
    final list = ListView(
            padding: const EdgeInsets.all(NikoTokens.pagePadding),
            children: [
          if (_nativeHistory)
            Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  key: const ValueKey('niko-history-show-results'),
                  onPressed: () => setState(() => _showNativeHistory = true),
                  icon: const Icon(Icons.fact_check_outlined),
                  label: Text(nikoText('查看会话结果', 'View session results')),
                )),
          Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 12,
              runSpacing: 10,
              children: [
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(nikoText('会话记录', 'Session history'),
                      style: Theme.of(context)
                          .textTheme
                          .headlineMedium
                          ?.copyWith(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 6),
                  Text(
                      nikoText('记录本机发起过的连接；远端是否接受以每次会话为准。',
                          'Sessions this client initiated. Remote acceptance is verified per session.'),
                      style: TextStyle(color: muted)),
                ]),
                TextButton.icon(
                    onPressed: _refresh,
                    icon: const Icon(Icons.refresh_rounded),
                    label: Text(nikoText('刷新', 'Refresh'))),
                if (_entries.isNotEmpty)
                  OutlinedButton(
                      onPressed: _clear,
                      child: Text(nikoText('清空记录', 'Clear history'))),
              ]),
          const SizedBox(height: 20),
          if (_loading)
            const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: CircularProgressIndicator()))
          else if (_error != null)
            NikoGlassCard(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Text(_error!,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error)),
                  TextButton(
                      onPressed: _refresh,
                      child: Text(nikoText('重试', 'Retry'))),
                ]))
          else if (_entries.isEmpty)
            NikoGlassCard(
                padding: const EdgeInsets.all(36),
                child: Column(children: [
                  Icon(Icons.history_rounded, size: 34, color: muted),
                  const SizedBox(height: 14),
                  Text(nikoText('还没有连接记录', 'No sessions yet'),
                      style: Theme.of(context)
                          .textTheme
                          .titleMedium
                          ?.copyWith(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 6),
                  Text(
                      nikoText('从设备页发起一次连接后，这里会记录发起历史。',
                          'Start a session from the devices page and it will be recorded here.'),
                      textAlign: TextAlign.center,
                      style: TextStyle(color: muted, fontSize: 12.5)),
                ]))
          else
            ..._grouped(context, muted),
        ]);
    return FocusTraversalGroup(child: list);
  }

  Widget _nightlinePage(BuildContext context, NlColors nl) {
    final narrow = MediaQuery.sizeOf(context).width < 600;
    final side = narrow ? NlSpace.s4 : NlSpace.s6;
    final list = ListView(
        padding: EdgeInsets.fromLTRB(side, NlSpace.s2, side, NlSpace.s10),
        children: [
          if (_loading)
            const Padding(
                padding: EdgeInsets.all(NlSpace.s8),
                child: Center(child: NlSpinner(size: 20)))
          else if (_error != null)
            NikoSettingNote(_error!,
                tone: NlTone.danger,
                actionLabel: nikoText('重试', 'Retry'),
                onAction: _refresh)
          else if (_entries.isEmpty)
            NlEmptyState(
                icon: NlIcons.history,
                title: nikoText('还没有连接记录', 'No sessions yet'),
                message: nikoText('从设备页发起一次连接后，这里会记录发起历史。',
                    'Start a session from the devices page and it will be recorded here.'))
          else
            ..._nightlineGroups(context, nl),
        ]);
    return FocusTraversalGroup(
        child: NlScrollWatcher(
            header: (context, scrolled) => NikoPageBar(
                    title: nikoText('会话记录', 'Session history'),
                    subtitle: nikoText('本机发起过的连接；远端是否接受以每次会话为准',
                        'Sessions this client started. Remote acceptance is checked per session'),
                    divider: scrolled,
                    actions: [
                      if (_nativeHistory)
                        NlButton.ghost(
                            key: const ValueKey('niko-history-show-results'),
                            small: true,
                            icon: NlIcons.clipboardCheck,
                            onPressed: () =>
                                setState(() => _showNativeHistory = true),
                            label: nikoText('查看会话结果', 'View session results')),
                      NlIconButton(
                          icon: NlIcons.refreshCw,
                          tooltip: nikoText('刷新', 'Refresh'),
                          onPressed: _refresh),
                      if (_entries.isNotEmpty)
                        NlButton.ghost(
                            small: true,
                            onPressed: _clear,
                            label: nikoText('清空记录', 'Clear history')),
                    ]),
            child: list));
  }

  Future<void> _delete(SessionLogEntry entry) async {
    try {
      await _store.removeAt(entry.startedAt);
      await _refresh();
    } catch (_) {}
  }

  /// Nightline: flat rows under a heading per day. The route is shown only
  /// when it was forced to the relay; anything else is not known here and
  /// is not claimed.
  List<Widget> _nightlineGroups(BuildContext context, NlColors nl) {
    final days = nikoByDay(_entries, (entry) => entry.startedAt);
    Widget row(SessionLogEntry entry, bool first) {
      final details = [
        if (entry.title != entry.id)
          Text(nikoGroupedId(entry.id),
              style: NlType.monoText(NlType.s1, color: nl.fg3)),
        if (entry.forceRelay) NlBadge(nikoText('中继', 'Relay')),
      ];
      return NikoHistoryRow(
          first: first,
          icon: entry.fileTransfer ? NlIcons.folder : NlIcons.monitor,
          time: nikoClock(entry.startedAt),
          title: Text(entry.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: NlType.text(NlType.s3,
                  weight: FontWeight.w500, color: nl.fg)),
          subtitle: details.isEmpty
              ? null
              : Wrap(
                  spacing: NlSpace.s2,
                  runSpacing: 2,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: details),
          actions: [
            NlButton.ghost(
                small: true,
                icon: entry.fileTransfer
                    ? NlIcons.folderOpen
                    : NlIcons.arrowRight,
                onPressed: () => _reconnect(entry),
                label: nikoText(entry.fileTransfer ? '传文件' : '连接',
                    entry.fileTransfer ? 'Files' : 'Connect')),
            NlIconButton(
                icon: NlIcons.close,
                tooltip: nikoText('删除该记录', 'Delete record'),
                onPressed: () => _delete(entry)),
          ]);
    }

    return [
      for (var d = 0; d < days.length; d++) ...[
        NikoHistoryDay(nikoDayLabel(days[d].$1), first: d == 0),
        for (var i = 0; i < days[d].$2.length; i++)
          row(days[d].$2[i], i == 0),
      ]
    ];
  }

  List<Widget> _grouped(BuildContext context, Color muted) {
    final groups = <String, List<SessionLogEntry>>{};
    for (final entry in _entries) {
      final local = entry.startedAt.toLocal();
      final key =
          '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')}';
      groups.putIfAbsent(key, () => []).add(entry);
    }
    final widgets = <Widget>[];
    for (final day in groups.keys) {
      widgets.add(Padding(
          padding: const EdgeInsets.only(top: 10, bottom: 8),
          child: Text(day,
              style: TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w700, color: muted))));
      for (final entry in groups[day]!) {
        widgets.add(Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: NikoGlassCard(
                padding: const EdgeInsets.all(14),
                child: LayoutBuilder(builder: (context, constraints) {
                  final avatar = Container(
                      width: 38,
                      height: 38,
                      decoration: BoxDecoration(
                          color: nikoIsLight(context) ? NikoPalette.lightAction : null,
                          gradient: nikoIsLight(context) ? null : LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors:
                                  NikoPalette.deviceAvatarGradient(entry.id)),
                          borderRadius:
                              BorderRadius.circular(NikoShapes.avatar)),
                      child: Icon(
                          entry.fileTransfer
                              ? Icons.folder_rounded
                              : Icons.desktop_windows_rounded,
                          color: Colors.white,
                          size: 18));
                  final details = Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(entry.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context)
                                .textTheme
                                .titleSmall
                                ?.copyWith(fontWeight: FontWeight.w700)),
                        const SizedBox(height: 2),
                        Text(
                            '${nikoGroupedId(entry.id)}$nikoSep${_time(entry.startedAt)}${entry.forceRelay ? '$nikoSep${nikoText('中继', 'relay')}' : ''}',
                            style: TextStyle(fontSize: 11.5, color: muted)),
                      ]);
                  final actions = Wrap(
                      spacing: 6,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        NikoPrimaryButton(
                            compact: true,
                            onPressed: () => _reconnect(entry),
                            child: Text(nikoText(
                                entry.fileTransfer ? '传文件' : '连接',
                                entry.fileTransfer ? 'Files' : 'Connect'))),
                        IconButton(
                            constraints: const BoxConstraints(
                                minWidth: 48, minHeight: 48),
                            visualDensity: VisualDensity.standard,
                            tooltip: nikoText('删除该记录', 'Delete record'),
                            onPressed: () async {
                              try {
                                await _store.removeAt(entry.startedAt);
                                await _refresh();
                              } catch (_) {}
                            },
                            icon: Icon(Icons.close_rounded,
                                size: 18, color: muted)),
                      ]);
                  if (constraints.maxWidth /
                          MediaQuery.textScalerOf(context).scale(1) <
                      500) {
                    return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(children: [
                            avatar,
                            const SizedBox(width: 12),
                            Expanded(child: details)
                          ]),
                          const SizedBox(height: 12),
                          Align(
                              alignment: Alignment.centerRight, child: actions),
                        ]);
                  }
                  return Row(children: [
                    avatar,
                    const SizedBox(width: 12),
                    Expanded(child: details),
                    const SizedBox(width: 8),
                    actions
                  ]);
                }))));
      }
    }
    return widgets;
  }

  String _time(DateTime date) {
    final local = date.toLocal();
    return '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}:${local.second.toString().padLeft(2, '0')}';
  }
}
