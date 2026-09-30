import 'package:flutter/material.dart';

import 'peer_event_scope.dart';
import 'theme.dart';
import 'ui.dart';

/// A failed or missing reply must never look like a confirmed empty directory.
class NikoPeerLoadNotice extends StatelessWidget {
  final bool configured;
  final bool hasPreviousRows;
  final NikoPeerLoadFailure? failure;
  final VoidCallback? onRetry;

  const NikoPeerLoadNotice({
    super.key,
    required this.configured,
    required this.hasPreviousRows,
    this.failure,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final title = !configured
        ? nikoText('请先配置私有服务器', 'Configure your private server first')
        : failure == null
            ? nikoText('设备列表尚未读取', 'Device list has not been loaded')
            : nikoText('无法读取设备列表', 'Device list could not be loaded');
    final explanation = !configured
        ? nikoText(
            '完成服务器设置后再查看此列表。', 'Complete server setup to view this list.')
        : hasPreviousRows
            ? nikoText('下方保留上次成功读取的列表，当前结果尚未确认。',
                'The last successfully loaded list is shown below. The current result is unconfirmed.')
            : failure == null
                ? nikoText('可以重新读取，尚不能确认此服务器没有设备。',
                    'Try loading again. An empty list has not been confirmed.')
                : nikoText('请重试；持续失败时检查本地存储访问权限和诊断信息。',
                    'Retry. If it keeps failing, check local storage access and diagnostics.');
    return Semantics(
      liveRegion: true,
      child: SingleChildScrollView(
        child: NikoGlassCard(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              Text(explanation),
              if (configured && onRetry != null) ...[
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh),
                  label: Text(nikoText('重新读取', 'Reload list')),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
