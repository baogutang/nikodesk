import 'package:flutter/material.dart';

import 'session_audit.dart';
import 'theme.dart';
import 'ui.dart';

class NikoNativeSessionHistory extends StatefulWidget {
  final String namespace;
  final SessionAuditApi? api;
  final bool active;
  const NikoNativeSessionHistory(
      {super.key, required this.namespace, this.api, this.active = true});
  @override
  State<NikoNativeSessionHistory> createState() =>
      _NikoNativeSessionHistoryState();
}

class _NikoNativeSessionHistoryState extends State<NikoNativeSessionHistory> {
  late final _api = widget.api ?? NativeSessionAuditApi();
  SessionAuditSnapshot? _snapshot;
  int _generation = 0;
  bool _busy = true;
  String? _message;
  bool _activities = false;
  @override
  void initState() {
    super.initState();
    if (widget.active) {
      _read();
    } else {
      _busy = false;
    }
  }

  @override
  void didUpdateWidget(covariant NikoNativeSessionHistory oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.namespace != widget.namespace) {
      _snapshot = null;
    }
    if (!widget.active || oldWidget.namespace != widget.namespace) {
      _generation++;
      _busy = false;
    }
    if (widget.active &&
        (!oldWidget.active || oldWidget.namespace != widget.namespace)) _read();
  }

  Future<void> _read() async {
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
        _message = nikoText('无法读取当前私服的会话结果，请检查私服和本机文件权限。',
            'Could not read session results. Check the private server and local file permissions.');
      });
    }
  }

  Future<void> _clear() async {
    final snapshot = _snapshot;
    final generation = _generation;
    if (snapshot == null || _busy) return;
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
              title: Text(nikoText('清空会话结果', 'Clear session results')),
              content: Text(nikoText('清空本机当前私服的连接结果和功能授权记录。仍在运行的连接会继续记录后续事件。',
                  'Remove connection results and capability records for this private server on this computer. Running connections keep recording later events.')),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: Text(nikoText('取消', 'Cancel'))),
                TextButton(
                    key: const ValueKey('niko-audit-confirm-clear'),
                    onPressed: () => Navigator.pop(context, true),
                    child: Text(nikoText('清空', 'Clear'))),
              ],
            ));
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
        _message = nikoText(
            '清空未确认，请刷新后重试。', 'Clear was not confirmed. Refresh and retry.');
      });
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

  @override
  Widget build(BuildContext context) {
    final snapshot = _snapshot;
    return ListView(
        padding: const EdgeInsets.all(NikoTokens.pagePadding),
        children: [
          Wrap(
              spacing: 12,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(nikoText('会话结果', 'Session results'),
                    style: Theme.of(context).textTheme.headlineMedium),
                TextButton.icon(
                    key: const ValueKey('niko-audit-refresh'),
                    onPressed: _busy ? null : _read,
                    icon: const Icon(Icons.refresh_rounded),
                    label: Text(nikoText('刷新', 'Refresh'))),
                if (snapshot?.entries.isNotEmpty == true ||
                    snapshot?.activities.isNotEmpty == true)
                  OutlinedButton(
                      key: const ValueKey('niko-audit-clear'),
                      onPressed: _busy ? null : _clear,
                      child: Text(nikoText('清空结果', 'Clear results'))),
              ]),
          const SizedBox(height: 8),
          Text(nikoText(
              '保留本机当前私服最近 200 条连接结果和 200 条功能事件。缺少结束记录时，最终结果仍未知；被控记录中的设备 ID 由对端声明。',
              'Keeps the latest 200 connection results and 200 capability events for this private server. Final results remain unknown without an end record. Receiver peer IDs are reported by the peer.')),
          const SizedBox(height: 8),
          Text(nikoText('功能事件反映本机原生流程；对端资源和实际声音效果需单独确认。连接认证不代表功能已获额外授权。',
              'Capability events describe the local native flow. Remote resources and actual audio require separate verification. Connection authentication does not grant additional capabilities.')),
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, children: [
            ChoiceChip(
                key: const ValueKey('niko-audit-connections'),
                label: Text(nikoText('连接结果', 'Connections')),
                selected: !_activities,
                onSelected: (_) => setState(() => _activities = false)),
            ChoiceChip(
                key: const ValueKey('niko-audit-activities'),
                label: Text(nikoText('功能授权', 'Capabilities')),
                selected: _activities,
                onSelected: (_) => setState(() => _activities = true)),
          ]),
          const SizedBox(height: 16),
          if (_busy) const Center(child: CircularProgressIndicator()),
          if (_message != null)
            Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Text(_message!)),
          if (snapshot?.incomplete == true)
            Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Text(nikoText('本次运行中有记录保存失败，列表可能不完整。',
                    'Some records could not be saved during this run. The list may be incomplete.'))),
          if (!_busy && !_activities && snapshot?.entries.isEmpty == true)
            NikoGlassCard(
                child: Text(nikoText('尚无已保存的原生会话结果。',
                    'No native session results have been saved yet.'))),
          if (!_activities)
            ...?snapshot?.entries.map((entry) => Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: NikoGlassCard(
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                        Text(
                            '${entry.role == 'controller' ? nikoText('主控', 'Controller') : nikoText('被控', 'Receiver')} · ${_kind(entry.kind)}',
                            style: Theme.of(context).textTheme.titleSmall),
                        const SizedBox(height: 6),
                        SelectableText(entry.peerId ??
                            nikoText('设备 ID 未知', 'Peer ID unknown')),
                        Text(_phase(entry.phase),
                            key: ValueKey('niko-audit-phase-${entry.session}')),
                        Text(
                            '${nikoText('发起时间', 'Started')}: ${_time(entry.startedAt)}'),
                        if (entry.authenticatedAt != null)
                          Text(
                              '${nikoText('认证时间', 'Authenticated')}: ${_time(entry.authenticatedAt!)}'),
                        if (entry.endedAt != null)
                          Text(
                              '${nikoText('结束时间', 'Ended')}: ${_time(entry.endedAt!)}'),
                        if (entry.durationMs != null)
                          Text(
                              '${nikoText('总时长（含连接等待）', 'Duration (including connection wait)')}: ${_duration(entry.durationMs!)}'),
                      ])),
                )),
          if (!_busy && _activities && snapshot?.activities.isEmpty == true)
            NikoGlassCard(
                child: Text(nikoText('尚无已保存的功能授权记录。',
                    'No capability events have been saved yet.'))),
          if (_activities)
            ...?snapshot?.activities.map((event) => Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: NikoGlassCard(
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                        Text(
                            '${event.role == 'controller' ? nikoText('本机主控', 'Local controller') : nikoText('本机被控', 'Local receiver')} · ${_capability(event.kind)}',
                            style: Theme.of(context).textTheme.titleSmall),
                        const SizedBox(height: 6),
                        SelectableText(event.peerId ??
                            nikoText('设备 ID 未知', 'Peer ID unknown')),
                        Text(_stage(event.stage),
                            key: ValueKey('niko-audit-event-${event.id}')),
                        Text(_time(event.at)),
                        Text(
                            '${nikoText('连接', 'Session')}: ${event.session.substring(0, 8)} · ${nikoText('操作', 'Operation')}: ${event.operation.substring(0, 8)}'),
                      ])),
                )),
        ]);
  }
}
