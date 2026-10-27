import 'dart:async';

import 'package:flutter/material.dart';

import 'history_kit.dart';
import 'nightline.dart';
import 'policy.dart';
import 'session_audit.dart';
import 'settings_kit.dart';
import 'ui.dart';

class NikoNativeSessionHistory extends StatefulWidget {
  final String namespace;
  final SessionAuditApi? api;
  final bool active;
  final Future<void> Function(String id, bool fileTransfer, String namespace)?
      onReconnect;
  const NikoNativeSessionHistory(
      {super.key,
      required this.namespace,
      this.api,
      this.active = true,
      this.onReconnect});
  @override
  State<NikoNativeSessionHistory> createState() =>
      _NikoNativeSessionHistoryState();
}

class _NikoNativeSessionHistoryState extends State<NikoNativeSessionHistory>
    with WidgetsBindingObserver {
  late final _api = widget.api ?? NativeSessionAuditApi();
  SessionAuditSnapshot? _snapshot;
  int _generation = 0;
  bool _busy = false;
  bool _interacting = false;
  Timer? _timer;
  bool _foreground = true;
  bool _routeVisible = true;
  String? _message;
  NlTone _messageTone = NlTone.neutral;
  bool _activities = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    _syncRefresh();
  }

  bool get _visible => widget.active && _foreground && _routeVisible;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final visible = ModalRoute.isCurrentOf(context) ?? true;
    if (_routeVisible == visible) return;
    _routeVisible = visible;
    if (!_interacting) {
      _generation++;
      _busy = false;
    }
    _syncRefresh();
  }

  void _syncRefresh() {
    _timer?.cancel();
    _timer = null;
    if (!_visible) return;
    _read();
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => _read());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final foreground = state == AppLifecycleState.resumed;
    if (_foreground == foreground) return;
    _foreground = foreground;
    _generation++;
    _busy = false;
    _syncRefresh();
  }

  @override
  void didUpdateWidget(covariant NikoNativeSessionHistory oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.namespace != widget.namespace) {
      _snapshot = null;
      _message = null;
    }
    if (!widget.active || oldWidget.namespace != widget.namespace) {
      _generation++;
      _busy = false;
    }
    if (oldWidget.active != widget.active ||
        oldWidget.namespace != widget.namespace) _syncRefresh();
  }

  @override
  void dispose() {
    _generation++;
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _read() async {
    if (!_visible || _busy || _interacting) return;
    final generation = ++_generation;
    final namespace = widget.namespace;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final result =
          SessionAuditSnapshot.parse(await _api.read(namespace), namespace);
      if (!mounted ||
          generation != _generation ||
          widget.namespace != namespace) return;
      setState(() {
        _snapshot = result;
        _busy = false;
      });
    } catch (_) {
      if (!mounted ||
          generation != _generation ||
          widget.namespace != namespace) return;
      setState(() {
        _busy = false;
        _snapshot = null;
        _messageTone = NlTone.danger;
        _message = nikoText('无法读取当前私服的会话结果，请检查私服和本机文件权限。',
            'Could not read session results. Check the private server and local file permissions.');
      });
    }
  }

  Future<void> _clear() async {
    final snapshot = _snapshot;
    final generation = _generation;
    if (snapshot == null || _busy || _interacting || !_visible) return;
    setState(() => _interacting = true);
    bool? confirmed;
    try {
      confirmed = await showNlDialog<bool>(
          context: context,
          builder: (context) => NlDialog(
                  title: nikoText('清空会话结果', 'Clear session results'),
                  message: nikoText('清空本机当前私服的连接结果和功能授权记录。仍在运行的连接会继续记录后续事件。',
                      'Remove connection results and capability records for this private server on this computer. Running connections keep recording later events.'),
                  actions: [
                    NlButton.ghost(
                        onPressed: () => Navigator.pop(context, false),
                        label: nikoText('取消', 'Cancel')),
                    NlButton.danger(
                        key: const ValueKey('niko-audit-confirm-clear'),
                        autofocus: true,
                        onPressed: () => Navigator.pop(context, true),
                        label: nikoText('清空', 'Clear')),
                  ]));
    } finally {
      if (mounted) {
        // The dialog future can finish before the route dependency rebuilds.
        _routeVisible = ModalRoute.isCurrentOf(context) ?? true;
        _syncRefresh();
        setState(() => _interacting = false);
        if (widget.namespace != snapshot.namespace) _read();
      }
    }
    if (confirmed != true ||
        !mounted ||
        generation != _generation ||
        widget.namespace != snapshot.namespace) return;
    final operation = ++_generation;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final result = SessionAuditSnapshot.parse(
          await _api.clear(snapshot.namespace, snapshot.revision),
          snapshot.namespace);
      if (!mounted ||
          operation != _generation ||
          widget.namespace != snapshot.namespace) return;
      setState(() {
        _snapshot = result;
        _busy = false;
        _messageTone =
            result.status == 'conflict' ? NlTone.warn : NlTone.ok;
        _message = result.status == 'conflict'
            ? nikoText('期间新增了连接或功能事件，记录未清空。查看更新后的结果，再决定是否清空。',
                'New connection or capability events arrived. Nothing was cleared. Review the updated results before clearing.')
            : nikoText('已清空本机当前私服的会话结果。',
                'Saved results for this private server were cleared.');
      });
    } catch (_) {
      if (!mounted ||
          operation != _generation ||
          widget.namespace != snapshot.namespace) return;
      setState(() {
        _busy = false;
        _messageTone = NlTone.danger;
        _message = nikoText(
            '清空未确认，请刷新后重试。', 'Clear was not confirmed. Refresh and retry.');
      });
    }
  }

  bool _canReconnect(SessionAuditEntry entry) =>
      widget.onReconnect != null &&
      entry.role == 'controller' &&
      entry.authenticatedAt != null &&
      entry.peerId != null &&
      validDeviceId(entry.peerId!) &&
      const ['desktop', 'file_transfer'].contains(entry.kind);

  Future<void> _reconnect(SessionAuditEntry entry) async {
    if (!_visible || _busy || _interacting || !_canReconnect(entry)) return;
    final namespace = widget.namespace;
    setState(() => _interacting = true);
    try {
      await widget.onReconnect!(
          entry.peerId!, entry.kind == 'file_transfer', namespace);
    } catch (_) {
      if (mounted && widget.namespace == namespace) {
        setState(() {
          _messageTone = NlTone.danger;
          _message = nikoText(
              '无法发起连接，请重试。', 'Could not start the session. Please retry.');
        });
      }
    } finally {
      if (mounted) {
        _routeVisible = ModalRoute.isCurrentOf(context) ?? true;
        _syncRefresh();
        setState(() => _interacting = false);
        if (widget.namespace != namespace) _read();
      }
    }
  }

  String _kind(String kind) => switch (kind) {
        'file_transfer' => nikoText('文件连接', 'File connection'),
        'camera' => nikoText('摄像头连接', 'Camera connection'),
        'terminal' => nikoText('终端连接', 'Terminal connection'),
        'tunnel' => nikoText('端口隧道', 'Port tunnel'),
        _ => nikoText('远程桌面', 'Remote desktop'),
      };
  String _capability(String kind) => switch (kind) {
        'terminal' => nikoText('远程终端', 'Terminal'),
        'camera' => nikoText('摄像头', 'Camera'),
        'tunnel' => nikoText('端口隧道', 'Port tunnel'),
        _ => nikoText('语音通话', 'Voice call'),
      };
  String _stage(String stage) => switch (stage) {
        'requested' =>
          nikoText('收到请求，等待本机批准', 'Requested; awaiting local approval'),
        'approved' =>
          nikoText('本机已批准，启动尚未确认', 'Locally approved; start not yet confirmed'),
        'local_started' => nikoText('本机资源已启动', 'Local resource started'),
        'started' => nikoText('双方已接受，本机语音后端就绪',
            'Both parties accepted; local voice backend ready'),
        'revoking' =>
          nikoText('正在撤回，停止尚未确认', 'Revoking; stop not yet confirmed'),
        'cleanup_pending' => nikoText('清理尚未确认', 'Cleanup not yet confirmed'),
        'stopped' => nikoText('本机资源停止已确认', 'Local resource stop confirmed'),
        'rejected' => nikoText('本机明确拒绝', 'Explicitly denied locally'),
        'request_ended' =>
          nikoText('请求已结束，未记录批准', 'Request ended; no approval recorded'),
        _ => nikoText(
            '请求已结束，未记录启动成功', 'Request ended; no successful start recorded'),
      };
  String _phase(String phase) => switch (phase) {
        'connecting' => nikoText(
            '认证未记录，结果待确认', 'Authentication not recorded; result unknown'),
        'authenticated' =>
          nikoText('已认证，结束未记录', 'Authenticated; end not recorded'),
        'disconnected' => nikoText('已认证并断开', 'Authenticated and disconnected'),
        'not_authenticated' =>
          nikoText('本次未完成认证', 'Authentication did not complete'),
        _ => nikoText('连接处理已中断', 'Connection handling interrupted'),
      };
  String _time(DateTime time) => time.toLocal().toString().split('.').first;
  String _duration(int milliseconds) {
    final seconds = milliseconds ~/ 1000;
    return '${seconds ~/ 3600}:${((seconds % 3600) ~/ 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}';
  }

  /// Time of day when [time] falls on the day of [start], else the date too.
  String _at(DateTime time, DateTime start) {
    final local = time.toLocal(), day = start.toLocal();
    return local.year == day.year &&
            local.month == day.month &&
            local.day == day.day
        ? nikoClock(time)
        : _time(time);
  }

  IconData _kindIcon(String kind) => switch (kind) {
        'file_transfer' => NlIcons.folder,
        'camera' => NlIcons.webcam,
        'terminal' => NlIcons.squareTerminal,
        'tunnel' => NlIcons.cable,
        _ => NlIcons.monitor,
      };
  IconData _capabilityIcon(String kind) => switch (kind) {
        'terminal' => NlIcons.squareTerminal,
        'camera' => NlIcons.webcam,
        'tunnel' => NlIcons.cable,
        _ => NlIcons.phone,
      };
  NlLedState _phaseLed(String phase) => switch (phase) {
        'authenticated' || 'disconnected' => NlLedState.ok,
        'not_authenticated' => NlLedState.danger,
        _ => NlLedState.warn,
      };
  NlLedState _stageLed(String stage) => switch (stage) {
        'local_started' || 'started' => NlLedState.ok,
        'rejected' => NlLedState.danger,
        'requested' || 'approved' || 'revoking' || 'cleanup_pending' =>
          NlLedState.warn,
        _ => NlLedState.off,
      };

  Widget _peer(NlColors nl, String? peerId) => peerId == null
      ? Text(nikoText('设备 ID 未知', 'Peer ID unknown'),
          style: NlType.text(NlType.s3, weight: FontWeight.w500, color: nl.fg2))
      : SelectableText(peerId,
          maxLines: 1,
          style: NlType.monoText(NlType.s3,
              weight: FontWeight.w500, color: nl.fg));

  Widget _what(NlColors nl, String what, Widget status) => Wrap(
      spacing: NlSpace.s3,
      runSpacing: 2,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(what, style: NlType.text(NlType.s2, color: nl.fg2)),
        status,
      ]);

  List<Widget> _days<T>(List<T> items, DateTime Function(T) at,
      Widget Function(T item, bool first) row) {
    final days = nikoByDay(items, at);
    return [
      for (var d = 0; d < days.length; d++) ...[
        NikoHistoryDay(nikoDayLabel(days[d].$1), first: d == 0),
        for (var i = 0; i < days[d].$2.length; i++) row(days[d].$2[i], i == 0),
      ]
    ];
  }

  Widget _entry(NlColors nl, SessionAuditEntry entry, bool first) {
    final times = [
      if (entry.authenticatedAt != null)
        '${nikoText('认证', 'Authenticated')} ${_at(entry.authenticatedAt!, entry.startedAt)}',
      if (entry.endedAt != null)
        '${nikoText('结束', 'Ended')} ${_at(entry.endedAt!, entry.startedAt)}',
      if (entry.durationMs != null)
        '${nikoText('时长', 'Duration')} ${_duration(entry.durationMs!)}${nikoText('（含连接等待）', ' (including connection wait)')}',
    ];
    return NikoHistoryRow(
        first: first,
        icon: _kindIcon(entry.kind),
        time: nikoClock(entry.startedAt),
        title: _peer(nl, entry.peerId),
        subtitle: _what(
            nl,
            '${entry.role == 'controller' ? nikoText('主控', 'Controller') : nikoText('被控', 'Receiver')}$nikoSep${_kind(entry.kind)}',
            NikoHistoryStatus(_phase(entry.phase),
                state: _phaseLed(entry.phase),
                textKey: ValueKey('niko-audit-phase-${entry.session}'))),
        footer: times.isEmpty
            ? null
            : Text(times.join(nikoSep),
                style: NlType.text(NlType.s1, color: nl.fg3)),
        actions: [
          if (_canReconnect(entry))
            // Stays enabled through the periodic reads; _reconnect ignores
            // presses while one is running.
            NlButton.ghost(
                key: ValueKey('niko-audit-reconnect-${entry.session}'),
                small: true,
                icon: entry.kind == 'file_transfer'
                    ? NlIcons.folderOpen
                    : NlIcons.arrowRight,
                onPressed: () => _reconnect(entry),
                label: nikoText('重新连接', 'Reconnect')),
        ]);
  }

  Widget _event(NlColors nl, CapabilityAuditEvent event, bool first) =>
      NikoHistoryRow(
          first: first,
          icon: _capabilityIcon(event.kind),
          time: nikoClock(event.at),
          title: _peer(nl, event.peerId),
          subtitle: _what(
              nl,
              '${event.role == 'controller' ? nikoText('本机主控', 'Local controller') : nikoText('本机被控', 'Local receiver')}$nikoSep${_capability(event.kind)}',
              NikoHistoryStatus(_stage(event.stage),
                  state: _stageLed(event.stage),
                  textKey: ValueKey('niko-audit-event-${event.id}'))),
          footer: Text(
              '${nikoText('连接', 'Session')} ${event.session.substring(0, 8)}$nikoSep${nikoText('操作', 'Operation')} ${event.operation.substring(0, 8)}',
              style: NlType.monoText(NlType.s1, color: nl.fg3)));

  @override
  Widget build(BuildContext context) {
    final nl = NlColors.of(context);
    final snapshot = _snapshot;
    final side =
        MediaQuery.sizeOf(context).width < 600 ? NlSpace.s4 : NlSpace.s6;
    final hasRecords = snapshot?.entries.isNotEmpty == true ||
        snapshot?.activities.isNotEmpty == true;
    return ListView(
        padding: EdgeInsets.fromLTRB(side, NlSpace.s2, side, NlSpace.s10),
        children: [
          Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: NlSpace.s3,
              runSpacing: NlSpace.s2,
              children: [
                NlSegmented<bool>(
                    small: true,
                    segments: [
                      NlSegment(
                          key: const ValueKey('niko-audit-connections'),
                          value: false,
                          label: nikoText('连接结果', 'Connections')),
                      NlSegment(
                          key: const ValueKey('niko-audit-activities'),
                          value: true,
                          label: nikoText('功能授权', 'Capabilities')),
                    ],
                    selected: _activities,
                    onChanged: (activities) =>
                        setState(() => _activities = activities)),
                // Both stay enabled through the periodic reads; _read and
                // _clear ignore presses while another operation runs.
                Row(mainAxisSize: MainAxisSize.min, children: [
                  NlIconButton(
                      key: const ValueKey('niko-audit-refresh'),
                      icon: NlIcons.refreshCw,
                      tooltip: nikoText('刷新', 'Refresh'),
                      onPressed: _read),
                  if (hasRecords) ...[
                    const SizedBox(width: NlSpace.s1),
                    NlButton.ghost(
                        key: const ValueKey('niko-audit-clear'),
                        small: true,
                        onPressed: _clear,
                        label: nikoText('清空结果', 'Clear results')),
                  ],
                ]),
              ]),
          const SizedBox(height: NlSpace.s3),
          if (_message != null)
            Padding(
                padding: const EdgeInsets.only(bottom: NlSpace.s3),
                child: NikoSettingNote(_message!, tone: _messageTone)),
          if (snapshot?.incomplete == true)
            Padding(
                padding: const EdgeInsets.only(bottom: NlSpace.s3),
                child: NikoSettingNote(
                    nikoText('本次运行中有记录保存失败，列表可能不完整。',
                        'Some records could not be saved during this run. The list may be incomplete.'),
                    tone: NlTone.warn)),
          if (_busy && snapshot == null)
            const Padding(
                padding: EdgeInsets.all(NlSpace.s8),
                child: Center(child: NlSpinner(size: 20))),
          if (!_busy && !_activities && snapshot?.entries.isEmpty == true)
            NlEmptyState(
                compact: true,
                icon: NlIcons.history,
                title: nikoText('还没有会话结果', 'No session results yet'),
                message: nikoText('本机发起或接受的连接会在这里记录认证与结果。',
                    'Connections this computer starts or accepts are recorded here with their authentication and outcome.')),
          if (!_activities && snapshot != null)
            ..._days(snapshot.entries, (entry) => entry.startedAt,
                (entry, first) => _entry(nl, entry, first)),
          if (!_busy && _activities && snapshot?.activities.isEmpty == true)
            NlEmptyState(
                compact: true,
                icon: NlIcons.shieldCheck,
                title: nikoText('还没有功能授权记录', 'No capability events yet'),
                message: nikoText('语音、终端、摄像头和端口隧道的授权与启动会记录在这里。',
                    'Approvals and starts of voice, terminal, camera and port tunnels are recorded here.')),
          if (_activities && snapshot != null)
            ..._days(snapshot.activities, (event) => event.at,
                (event, first) => _event(nl, event, first)),
          if (snapshot != null)
            Padding(
                padding: const EdgeInsets.only(top: NlSpace.s8),
                child: NikoSettingNote(_activities
                    ? nikoText(
                        '功能事件反映本机原生流程；对端资源和实际声音效果需单独确认。连接认证不代表功能已获额外授权。保留本机当前私服最近 200 条功能事件。',
                        'Capability events describe the local native flow. Remote resources and actual audio require separate verification. Connection authentication does not grant additional capabilities. Keeps the latest 200 capability events for this private server.')
                    : nikoText(
                        '保留本机当前私服最近 200 条连接结果。缺少结束记录时，最终结果仍未知；被控记录中的设备 ID 由对端声明。',
                        'Keeps the latest 200 connection results for this private server. Final results remain unknown without an end record. Receiver peer IDs are reported by the peer.'))),
        ]);
  }
}
