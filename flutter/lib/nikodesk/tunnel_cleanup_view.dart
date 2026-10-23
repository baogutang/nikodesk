import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/generated_bridge.dart';
import 'package:uuid/uuid.dart';

import 'alert_dialog.dart';
import 'nightline.dart';
import 'tunnel_cleanup.dart';
import 'tunnel_controller.dart';
import 'tunnel_controller_view.dart' show NikoTunnelNote;
import 'ui.dart';

class NativeNikoTunnelCleanupTransport {
  final Rustdesk? bridge;
  const NativeNikoTunnelCleanupTransport({this.bridge});
  Rustdesk get _api => bridge ?? bind;
  Future<String> read() => _api.sessionNikoTunnelRetired();
  Future<String> command(
      NikoTunnelOwnerIdentity owner, NikoTunnelCommand command) {
    if (owner.namespace != command.namespace ||
        owner.peerId != command.peerId) {
      return Future.value('{"ok":false,"reason":"identity_mismatch"}');
    }
    return _api.sessionNikoTunnelCommand(
        sessionId: UuidValue(owner.sessionId), json: command.json);
  }

  Future<String> close(NikoTunnelOwnerIdentity owner) =>
      _api.sessionNikoTunnelClose(
          sessionId: UuidValue(owner.sessionId), json: owner.requestJson);
  Future<String> query(NikoTunnelOwnerIdentity owner) =>
      _api.sessionNikoTunnelQuery(
          sessionId: UuidValue(owner.sessionId), json: owner.requestJson);
  NikoTunnelCleanupModel createModel() =>
      NikoTunnelCleanupModel(readRetired: read, query: query);
}

class NikoTunnelCleanupEntryPoint extends StatefulWidget {
  final NikoTunnelCleanupModel? model;
  final Duration interval;
  const NikoTunnelCleanupEntryPoint(
      {super.key, this.model, this.interval = const Duration(seconds: 3)});
  @override
  State<NikoTunnelCleanupEntryPoint> createState() => _EntryPointState();
}

class _EntryPointState extends State<NikoTunnelCleanupEntryPoint>
    with WidgetsBindingObserver {
  late final _model =
      widget.model ?? const NativeNikoTunnelCleanupTransport().createModel();
  Timer? _timer;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _resume();
    });
  }

  void _resume() {
    _timer?.cancel();
    _model.refresh();
    _timer = Timer.periodic(widget.interval, (_) => _model.refresh());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _timer?.cancel();
    if (state == AppLifecycleState.resumed && mounted) _resume();
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    if (widget.model == null) _model.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
      animation: _model,
      builder: (context, _) {
        if (!_model.visible) return const SizedBox.shrink();
        if (NlColors.maybeOf(context) != null) return _nightline(context);
        return Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: NikoCard(
                padding: const EdgeInsets.all(12),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(nikoText('此前隧道的本机资源尚待确认退出',
                          'Previous tunnel resources still need exit confirmation')),
                      const SizedBox(height: 8),
                      OutlinedButton(
                          key: const Key('niko-tunnel-cleanup-open'),
                          style: OutlinedButton.styleFrom(
                              minimumSize: const Size(48, 48)),
                          onPressed: () => showDialog<void>(
                              context: context,
                              builder: (context) => Dialog(
                                  child: ConstrainedBox(
                                      constraints:
                                          const BoxConstraints(maxWidth: 560),
                                      child: SingleChildScrollView(
                                          padding: const EdgeInsets.all(16),
                                          child: Column(
                                              mainAxisSize: MainAxisSize.min,
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.stretch,
                                              children: [
                                                NikoTunnelCleanupPanel(
                                                    model: _model),
                                                TextButton(
                                                    style: TextButton.styleFrom(
                                                        minimumSize:
                                                            const Size(48, 48)),
                                                    onPressed: () =>
                                                        Navigator.pop(context),
                                                    child: Text(nikoText('关闭面板',
                                                        'Close panel'))),
                                              ]))))),
                          child: Text(
                              nikoText('查看隧道清理', 'Review tunnel cleanup'))),
                    ])));
      });

  /// Nightline: the reminder as a note with its action; the panel opens in
  /// the design-system dialog.
  Widget _nightline(BuildContext context) => Padding(
      padding: const EdgeInsets.symmetric(vertical: NlSpace.s2),
      child: NikoTunnelNote(
          nikoText('此前隧道的本机资源尚待确认退出',
              'Previous tunnel resources still need exit confirmation'),
          warn: true,
          actions: [
            NlButton.ghost(
                key: const Key('niko-tunnel-cleanup-open'),
                small: true,
                label: nikoText('查看隧道清理', 'Review tunnel cleanup'),
                onPressed: () => showDialog<void>(
                    context: context,
                    builder: (context) => NikoAlertDialog(
                            constraints: const BoxConstraints(maxWidth: 520),
                            content: NikoTunnelCleanupPanel(model: _model),
                            actions: [
                              NikoDialogButton(
                                  label: nikoText('关闭面板', 'Close panel'),
                                  primary: false,
                                  onPressed: () => Navigator.pop(context)),
                            ]))),
          ]));
}

class NikoTunnelCleanupPanel extends StatelessWidget {
  final NikoTunnelCleanupModel model;
  const NikoTunnelCleanupPanel({super.key, required this.model});
  @override
  Widget build(BuildContext context) => NlColors.maybeOf(context) == null
      ? _material(context)
      : AnimatedBuilder(
          animation: model,
          builder: (context, _) => _nightline(context, NlColors.of(context)));

  Widget _material(BuildContext context) => AnimatedBuilder(
      animation: model,
      builder: (context, _) => Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(nikoText('此前隧道的清理', 'Cleanup for previous tunnels'),
                    style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 8),
                Text(nikoText(
                    '仅确认原会话的本机资源退出，不会重连或创建隧道。切换私服不会隐藏这些记录，也不能据此确认远端已经清理。',
                    'Confirm exit of local resources belonging to the original session. This does not reconnect or create a tunnel. Changing servers does not hide these records or confirm remote cleanup.')),
                if (model.unconfirmed)
                  Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Semantics(
                          liveRegion: true,
                          child: Text(nikoText('清理状态未确认，仍保留已知记录。',
                              'Cleanup status is unconfirmed. Known records are retained.')))),
                const SizedBox(height: 12),
                OutlinedButton(
                    key: const Key('niko-tunnel-cleanup-refresh'),
                    style: OutlinedButton.styleFrom(
                        minimumSize: const Size(48, 48)),
                    onPressed: model.reading ? null : model.refresh,
                    child: Text(nikoText('刷新清理状态', 'Refresh cleanup status'))),
                for (final entry in model.entries)
                  Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: NikoCard(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Text(
                                    '${nikoText('此前设备', 'Previous device')}: ${entry.owner.peerId}'),
                                const SizedBox(height: 4),
                                Text(nikoText(
                                    entry.reason == 'tunnel_worker_failed'
                                        ? '本机资源退出失败，尚未确认已释放。'
                                        : '等待本机资源退出确认。',
                                    entry.reason == 'tunnel_worker_failed'
                                        ? 'Local resource exit failed; release is unconfirmed.'
                                        : 'Waiting for local resource exit confirmation.')),
                                const SizedBox(height: 8),
                                OutlinedButton(
                                    key: Key(
                                        'niko-tunnel-cleanup-${entry.owner.key}'),
                                    style: OutlinedButton.styleFrom(
                                        minimumSize: const Size(48, 48)),
                                    onPressed: model.busy(entry)
                                        ? null
                                        : () => model.retry(entry),
                                    child: Text(nikoText(
                                        '查询并重试清理', 'Check and retry cleanup'))),
                              ]))),
              ]));

  /// Nightline: what the panel confirms, the refresh, and one row per
  /// earlier session with its state and retry. Same keys and calls as above.
  Widget _nightline(BuildContext context, NlColors nl) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(nikoText('此前隧道的清理', 'Cleanup for previous tunnels'),
                style: NlType.text(NlType.s5,
                    weight: FontWeight.w600, color: nl.fg)),
            const SizedBox(height: NlSpace.s2),
            Text(
                nikoText('仅确认原会话的本机资源退出，不会重连或创建隧道。切换私服不会隐藏这些记录，也不能据此确认远端已经清理。',
                    'Confirm exit of local resources belonging to the original session. This does not reconnect or create a tunnel. Changing servers does not hide these records or confirm remote cleanup.'),
                style: NlType.text(NlType.s3, color: nl.fg2)),
            if (model.unconfirmed) ...[
              const SizedBox(height: NlSpace.s3),
              NikoTunnelNote(
                  nikoText('清理状态未确认，仍保留已知记录。',
                      'Cleanup status is unconfirmed. Known records are retained.'),
                  warn: true),
            ],
            const SizedBox(height: NlSpace.s4),
            Align(
                alignment: AlignmentDirectional.centerStart,
                child: NlButton.ghost(
                    key: const Key('niko-tunnel-cleanup-refresh'),
                    small: true,
                    icon: NlIcons.refreshCw,
                    loading: model.reading,
                    label: nikoText('刷新清理状态', 'Refresh cleanup status'),
                    onPressed: model.reading ? null : model.refresh)),
            if (model.entries.isNotEmpty) ...[
              const SizedBox(height: NlSpace.s3),
              NlPanel(
                  padding: EdgeInsets.zero,
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final (i, entry) in model.entries.indexed)
                          Container(
                              decoration: i == 0
                                  ? null
                                  : BoxDecoration(
                                      border: Border(
                                          top: BorderSide(color: nl.line))),
                              padding: const EdgeInsets.all(NlSpace.s3),
                              child: Row(children: [
                                NlLed(entry.reason == 'tunnel_worker_failed'
                                    ? NlLedState.danger
                                    : NlLedState.warn),
                                const SizedBox(width: NlSpace.s3),
                                Expanded(
                                    child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                      Text(
                                          '${nikoText('此前设备', 'Previous device')}: ${entry.owner.peerId}',
                                          style: NlType.text(NlType.s3,
                                              weight: FontWeight.w500,
                                              color: nl.fg)),
                                      const SizedBox(height: 2),
                                      Text(
                                          nikoText(
                                              entry.reason ==
                                                      'tunnel_worker_failed'
                                                  ? '本机资源退出失败，尚未确认已释放。'
                                                  : '等待本机资源退出确认。',
                                              entry.reason ==
                                                      'tunnel_worker_failed'
                                                  ? 'Local resource exit failed; release is unconfirmed.'
                                                  : 'Waiting for local resource exit confirmation.'),
                                          style: NlType.text(NlType.s2,
                                              color: nl.fg2)),
                                    ])),
                                const SizedBox(width: NlSpace.s2),
                                NlButton.ghost(
                                    key: Key(
                                        'niko-tunnel-cleanup-${entry.owner.key}'),
                                    small: true,
                                    label: nikoText(
                                        '查询并重试清理', 'Check and retry cleanup'),
                                    onPressed: model.busy(entry)
                                        ? null
                                        : () => model.retry(entry)),
                              ])),
                      ])),
            ],
          ]);
}
