import 'dart:async';

import 'package:flutter/material.dart';

import 'ui.dart';
import 'voice_cleanup_model.dart';
import 'voice_cleanup_native.dart';

class NikoVoiceCleanupEntryPoint extends StatefulWidget {
  final NikoVoiceCleanupModel? model;
  final Duration pollInterval;
  const NikoVoiceCleanupEntryPoint(
      {super.key, this.model, this.pollInterval = const Duration(seconds: 3)});
  @override
  State<NikoVoiceCleanupEntryPoint> createState() => _CleanupEntryPointState();
}

class _CleanupEntryPointState extends State<NikoVoiceCleanupEntryPoint>
    with WidgetsBindingObserver {
  late final NikoVoiceCleanupModel _model =
      widget.model ?? const NativeNikoVoiceCleanupTransport().createModel();
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _resume();
    });
  }

  void _resume() {
    _timer?.cancel();
    _model.refresh();
    _timer = Timer.periodic(widget.pollInterval, (_) => _model.refresh());
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
        return Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: NikoCard(
                padding: const EdgeInsets.all(12),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                          _model.pending.isEmpty
                              ? nikoText('语音清理状态未确认',
                                  'Voice cleanup status unconfirmed')
                              : nikoText('此前会话的语音尚待清理',
                                  'Previous calls still need cleanup'),
                          style: Theme.of(context).textTheme.labelLarge),
                      const SizedBox(height: 4),
                      OutlinedButton(
                          key: const Key('nikodesk-voice-cleanup-open'),
                          style: OutlinedButton.styleFrom(
                              minimumSize: const Size(48, 48)),
                          onPressed: () =>
                              showNikoVoiceCleanup(context, _model),
                          child:
                              Text(nikoText('查看语音清理', 'Review voice cleanup')))
                    ])));
      });
}

Future<void> showNikoVoiceCleanup(
        BuildContext context, NikoVoiceCleanupModel model) =>
    showDialog<void>(
        context: context,
        builder: (context) => Dialog(
            child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          NikoVoiceCleanupPanel(model: model),
                          TextButton(
                              style: TextButton.styleFrom(
                                  minimumSize: const Size(48, 48)),
                              onPressed: () => Navigator.pop(context),
                              child: Text(nikoText('关闭面板', 'Close panel')))
                        ])))));

class NikoVoiceCleanupPanel extends StatelessWidget {
  final NikoVoiceCleanupModel model;
  const NikoVoiceCleanupPanel({super.key, required this.model});
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
      animation: model,
      builder: (context, _) => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(nikoText('此前会话的语音清理', 'Cleanup for previous calls'),
                    style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 8),
                Text(nikoText('这些会话已关闭。确认本机音频资源已释放后，记录会自动移除。切换私服不会隐藏此前的清理记录。',
                    'These sessions are closed. Entries disappear after local audio resources are confirmed released. Switching servers keeps previous cleanup entries visible.')),
                const SizedBox(height: 12),
                if (model.readUnconfirmed)
                  Text(nikoText('无法确认最新清理状态，保留上次记录。请刷新后重试。',
                      'The latest cleanup state is unconfirmed. Previous entries are retained. Refresh and retry.')),
                if (model.pending.isEmpty && !model.readUnconfirmed)
                  Text(model.reading
                      ? nikoText('正在读取清理状态…', 'Reading cleanup state…')
                      : nikoText(
                          '没有待确认的语音清理。', 'No voice cleanup is pending.')),
                for (final entry in model.pending) ...[
                  const SizedBox(height: 12),
                  NikoCard(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(nikoText(
                                '此前会话 · ${entry.status.identity.peerId}',
                                'Previous session · ${entry.status.identity.peerId}')),
                            const SizedBox(height: 6),
                            Semantics(
                                liveRegion: true,
                                child: Text(entry.joinState == 'failed'
                                    ? nikoText('语音清理失败，资源释放尚未确认。',
                                        'Voice cleanup failed. Resource release is unconfirmed.')
                                    : nikoText('正在确认语音清理，资源释放尚未确认。',
                                        'Confirming voice cleanup. Resource release is unconfirmed.'))),
                            const SizedBox(height: 8),
                            OutlinedButton(
                                key: ValueKey(
                                    'voice-cleanup-query-${entry.key}'),
                                style: OutlinedButton.styleFrom(
                                    minimumSize: const Size(48, 48)),
                                onPressed: model.busy(entry)
                                    ? null
                                    : () => model.send(entry, 'query'),
                                child: Text(nikoText('读取状态', 'Read state'))),
                            const SizedBox(height: 6),
                            FilledButton(
                                key: ValueKey(
                                    'voice-cleanup-retry-${entry.key}'),
                                style: FilledButton.styleFrom(
                                    minimumSize: const Size(48, 48)),
                                onPressed: model.busy(entry)
                                    ? null
                                    : () => model.send(entry, 'retry_cleanup'),
                                child: Text(nikoText('重试清理', 'Retry cleanup'))),
                            if (model.message(entry) != null) ...[
                              const SizedBox(height: 6),
                              Semantics(
                                  liveRegion: true,
                                  child: Text(model.message(entry) == 'queued'
                                      ? nikoText('请求已发送，仍在等待清理确认。',
                                          'Request sent. Cleanup confirmation is still pending.')
                                      : nikoText('操作未确认。请刷新状态后重试。',
                                          'The outcome is unconfirmed. Refresh the state and retry.')))
                            ],
                          ]))
                ],
                const SizedBox(height: 12),
                OutlinedButton(
                    key: const Key('nikodesk-voice-cleanup-refresh'),
                    style: OutlinedButton.styleFrom(
                        minimumSize: const Size(48, 48)),
                    onPressed: model.reading ? null : model.refresh,
                    child: Text(model.reading
                        ? nikoText('正在刷新…', 'Refreshing…')
                        : nikoText('刷新清理状态', 'Refresh cleanup state')))
              ]));
}
