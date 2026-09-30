import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_hbb/models/file_model.dart';
import 'package:get/get.dart';

import 'file_transfer.dart';
import 'ui.dart';

String nikoFileRetryReason(NikoRetryBlock block) => switch (block) {
      NikoRetryBlock.missingRequest => nikoText('没有本次传输的完整参数，请重新选择源文件。',
          'This task has no complete transfer request. Select the source again.'),
      NikoRetryBlock.directoryNeedsSelection => nikoText(
          '未保留原始目录核验参数，请重新选择文件夹发送。',
          'The original directory verification details are missing. Select the folder again.'),
      NikoRetryBlock.changedSession => nikoText('会话已变化。请重新连接并选择源文件。',
          'The session changed. Reconnect and select the source again.'),
      NikoRetryBlock.disconnected => nikoText('会话未连接，请重新连接并选择源文件。',
          'The session is disconnected. Reconnect and select the source again.'),
      NikoRetryBlock.permission => nikoText('远端未允许文件传输，请先在远端授权。',
          'File transfer is not allowed by the peer. Obtain permission on the remote device.'),
      NikoRetryBlock.cancelled => nikoText('该任务已请求取消。请重新选择源文件。',
          'Cancellation was requested for this task. Select the source again.'),
      NikoRetryBlock.busy =>
        nikoText('正在提交新传输请求。', 'Submitting a new transfer request.'),
      NikoRetryBlock.readUnconfirmed => nikoText(
          '目录读取结果未确认，请关闭并重新打开文件传输后再选择源文件夹。',
          'The directory read is unconfirmed. Close and reopen file transfer, then select the source folder again.'),
      NikoRetryBlock.notFailed => nikoText('只能重新发送本次会话中失败的传输任务。',
          'Only failed transfers from this session can be resent.'),
    };

String nikoDocumentFeedback(String action, NikoDocumentOutcome result) {
  final counts = nikoText('$action：成功 ${result.succeeded}，失败 ${result.failed}',
      '$action: ${result.succeeded} succeeded, ${result.failed} failed');
  final skipped = result.skipped > 0
      ? nikoText('，跳过 ${result.skipped}', ', ${result.skipped} skipped')
      : '';
  final cancelled =
      result.cancelled ? nikoText('；操作已取消', '; operation cancelled') : '';
  final incomplete = result.incomplete
      ? nikoText('；其余结果未确认', '; remaining outcomes unconfirmed')
      : '';
  final error = result.errorCode == null
      ? ''
      : switch (result.errorCode) {
          'picker_in_progress' =>
            nikoText('；另一个文件选择窗口仍打开', '; another file picker is open'),
          'picker_unavailable' =>
            nikoText('；系统文件选择器不可用', '; the system file picker is unavailable'),
          'invalid_source' || 'invalid_destination' => nikoText(
              '；文件必须位于应用文件区内', '; the file must be inside the app file area'),
          'invalid_uri' =>
            nikoText('；所选文件无法读取', '; the selected document cannot be read'),
          'destination_exists' => nikoText('；目标已有同名文件，无法导入文件夹',
              '; a file already occupies the folder destination'),
          'directory_refresh_failed' => nikoText('；文件操作结果已保留，目录刷新失败，请手动刷新',
              '; the file operation result is retained; directory refresh failed, refresh manually'),
          'nothing_to_export' => nikoText('；没有可导出的日志或录像',
              '; no logs or recordings are available to export'),
          'invalid_document_result' => nikoText('；系统未返回完整计数，结果未确认',
              '; the system returned incomplete counts; outcomes are unconfirmed'),
          _ => nikoText('；无法完成文件读写，请检查空间和系统授权',
              '; file I/O could not finish; check storage and system access'),
        };
  return '$counts$skipped$cancelled$incomplete$error';
}

String nikoFolderDetail(NikoFolderProgress folder) {
  if (folder.issue != null) {
    return switch (folder.issue!) {
      NikoFolderIssue.sourceChanged => nikoText('源文件或文件夹已删除或类型已变化，请重新选择。',
          'The source file or folder was deleted or changed type. Select it again.'),
      NikoFolderIssue.destinationChanged => nikoText(
          '目标文件或文件夹已删除或类型已变化，请重新选择目标。',
          'The destination was deleted or changed type. Choose the destination again.'),
      NikoFolderIssue.invalidPaths => nikoText('空目录响应不完整或不在原始源文件夹内，已拒绝创建。',
          'The empty-directory response is incomplete or outside the source folder; creation was refused.'),
      NikoFolderIssue.sessionChanged => nikoText('会话已变化，已停止后续空目录请求。',
          'The session changed. Further empty-directory requests were stopped.'),
      NikoFolderIssue.disconnected => nikoText('会话已断开，文件夹结构未确认。',
          'The session disconnected; the folder structure is unconfirmed.'),
      NikoFolderIssue.permission => nikoText('文件权限已撤销，已停止后续空目录请求。',
          'File permission was revoked. Further empty-directory requests were stopped.'),
      NikoFolderIssue.cancelled => nikoText('已请求取消，已阻止后续空目录请求；已发出的请求状态仍需确认。',
          'Cancellation requested. Further directory requests were blocked; previously sent requests remain unconfirmed.'),
      NikoFolderIssue.nativeError => nikoText('空目录阶段失败，请检查目标权限、空间和任务错误。',
          'The empty-directory phase failed. Check destination access, storage and task errors.'),
      NikoFolderIssue.timeout => nikoText('空目录请求超时，远端是否完成尚未确认。',
          'An empty-directory request timed out; remote completion is unconfirmed.'),
      NikoFolderIssue.readFailed => nikoText('无法读取或核对原始目录，文件夹结构未确认。',
          'The original directories could not be read or verified; the folder structure is unconfirmed.'),
      NikoFolderIssue.readUnconfirmed => nikoText(
          '目录读取结果未确认，已拒绝后续创建。请关闭并重新打开文件传输后再选择源文件夹。',
          'The directory read is unconfirmed. Further creation was refused. Close and reopen file transfer, then select the source folder again.'),
    };
  }
  return switch (folder.state) {
    NikoFolderState.preparing => nikoText('正在核对原始目录并读取空目录。',
        'Verifying the original paths and reading empty directories.'),
    NikoFolderState.creating => nikoText(
        '空目录已确认 ${folder.confirmed}/${folder.expected}。',
        '${folder.confirmed}/${folder.expected} empty directories confirmed.'),
    NikoFolderState.confirmed => nikoText('空目录阶段已确认（${folder.confirmed} 个）。',
        'Empty-directory phase confirmed (${folder.confirmed}).'),
    _ => nikoText('文件夹结构未确认。', 'Folder structure unconfirmed.'),
  };
}

String nikoFileRequestIssue(NikoFolderIssue issue) => switch (issue) {
      NikoFolderIssue.sourceChanged ||
      NikoFolderIssue.destinationChanged =>
        nikoFolderDetail(
            NikoFolderProgress(NikoFolderState.failed, issue: issue)),
      NikoFolderIssue.permission => nikoText('文件权限已撤销，传输请求未发送。',
          'File permission was revoked. The transfer request was not sent.'),
      NikoFolderIssue.cancelled => nikoText('已请求取消，未继续发送本次传输。',
          'Cancellation was requested. This transfer was not sent further.'),
      NikoFolderIssue.sessionChanged || NikoFolderIssue.disconnected => nikoText(
          '会话已变化或断开，传输请求未发送。请重新连接。',
          'The session changed or disconnected. The transfer request was not sent. Reconnect.'),
      _ => nikoText('无法核对原始路径或发送请求，请检查目录并重新连接。',
          'The original paths could not be verified or sent. Check the directories and reconnect.')
    };

class NikoFileTaskCard extends StatelessWidget {
  final JobProgress job;
  final NikoTransferRequest? request;
  final NikoCancelState cancellation;
  final NikoRetryBlock? retryBlock;
  final NikoFolderProgress? folder;
  final NikoFolderIssue? requestIssue;
  final VoidCallback? onCancel;
  final VoidCallback? onRetry;
  final VoidCallback? onRemove;
  const NikoFileTaskCard(
      {super.key,
      required this.job,
      this.request,
      this.cancellation = NikoCancelState.none,
      this.retryBlock,
      this.folder,
      this.requestIssue,
      this.onCancel,
      this.onRetry,
      this.onRemove});

  @override
  Widget build(BuildContext context) {
    final transfer = job.type == JobType.transfer;
    final dataActive =
        job.state == JobState.inProgress || job.state == JobState.none;
    final active = dataActive || folder?.pending == true;
    final failed = job.state == JobState.error ||
        (job.state == JobState.done && folder?.incomplete == true);
    final dataDoneFolderPending = job.state == JobState.done &&
        folder != null &&
        folder!.state != NikoFolderState.confirmed;
    final status = switch (cancellation) {
      NikoCancelState.requesting =>
        nikoText('正在请求取消', 'Requesting cancellation'),
      NikoCancelState.requested => nikoText('取消请求已发出，远端状态未确认',
          'Cancellation requested; remote status unconfirmed'),
      NikoCancelState.failed =>
        nikoText('取消请求未能发送', 'The cancellation request could not be sent'),
      NikoCancelState.none => switch (job.state) {
          JobState.none => nikoText('等待处理', 'Waiting'),
          JobState.inProgress => job.recvJobRes
              ? nikoText('传输中', 'Transferring')
              : nikoText(
                  '请求已提交，等待进度', 'Request submitted; waiting for progress'),
          JobState.done => dataDoneFolderPending
              ? nikoText('文件数据已完成；文件夹结构未确认',
                  'File data completed; folder structure unconfirmed')
              : job.err == 'skipped'
                  ? nikoText('已跳过', 'Skipped')
                  : job.err == 'cancel'
                      ? nikoText('取消已请求，状态未确认',
                          'Cancellation requested; status unconfirmed')
                      : nikoText('已完成', 'Completed'),
          JobState.error => nikoText('失败', 'Failed'),
          JobState.paused =>
            nikoText('历史任务待处理', 'Previous task awaiting action'),
        },
    };
    final direction = transfer
        ? (job.isRemoteToLocal
            ? nikoText('远端 → 本地文件区', 'Remote → local file area')
            : nikoText('本地文件区 → 远端', 'Local file area → remote'))
        : (job.isRemoteToLocal
            ? nikoText('远端删除', 'Delete on remote')
            : nikoText('本地删除', 'Delete locally'));
    final bytes = '${job.finishedSize}/${job.totalSize} B';
    final progress = job.totalSize > 0
        ? (job.finishedSize / job.totalSize).clamp(0.0, 1.0)
        : null;
    return NikoCard(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(job.fileName.isEmpty ? job.jobName : job.fileName,
              style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 6),
          Text(direction),
          Semantics(
              liveRegion: true,
              child: Text(status,
                  style: TextStyle(
                      color: failed
                          ? Theme.of(context).colorScheme.error
                          : null))),
          if (request != null) ...[
            const SizedBox(height: 8),
            Text('${nikoText('源', 'Source')}: ${request!.source}',
                softWrap: true),
            Text('${nikoText('目标', 'Destination')}: ${request!.destination}',
                softWrap: true),
          ],
          if (folder != null) ...[
            const SizedBox(height: 8),
            Semantics(liveRegion: true, child: Text(nikoFolderDetail(folder!))),
          ],
          if (requestIssue != null && folder == null) ...[
            const SizedBox(height: 8),
            Semantics(
                liveRegion: true,
                child: Text(nikoFileRequestIssue(requestIssue!))),
          ],
          if (transfer &&
              dataActive &&
              cancellation != NikoCancelState.requested) ...[
            const SizedBox(height: 8),
            LinearProgressIndicator(value: progress),
            const SizedBox(height: 6),
            Text(job.recvJobRes
                ? '$bytes · ${job.speed.toStringAsFixed(0)} B/s'
                : nikoText('尚未收到传输进度', 'No transfer progress received yet')),
          ],
          if (job.state == JobState.error && job.err.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text('${nikoText('错误', 'Error')}: ${job.err}',
                key: Key('niko-file-error-${job.id}')),
          ],
          if (failed || job.state == JobState.paused) ...[
            const SizedBox(height: 8),
            Text(retryBlock == null
                ? nikoText('重新发送会从头开始；同名文件会再次询问是否覆盖。',
                    'Resending starts from the beginning. A same-name destination prompts for overwrite again.')
                : nikoFileRetryReason(retryBlock!)),
          ],
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 4, children: [
            if (active && cancellation != NikoCancelState.requested)
              OutlinedButton(
                  key: Key('niko-file-cancel-${job.id}'),
                  onPressed: cancellation == NikoCancelState.requesting
                      ? null
                      : onCancel,
                  child: Text(nikoText('请求取消', 'Request cancel'))),
            if (transfer && failed && retryBlock == null)
              FilledButton(
                  key: Key('niko-file-resend-${job.id}'),
                  onPressed: onRetry,
                  child: Text(nikoText('重新发送', 'Resend'))),
            if (!active || cancellation == NikoCancelState.requested)
              TextButton(
                  key: Key('niko-file-remove-${job.id}'),
                  onPressed: onRemove,
                  child: Text(nikoText('移除记录', 'Remove record'))),
          ]),
        ]));
  }
}

class NikoFileTasks extends StatelessWidget {
  final JobController controller;
  const NikoFileTasks({super.key, required this.controller});

  @override
  Widget build(BuildContext context) => Obx(() {
        final jobs = controller.jobTable.toList();
        if (jobs.isEmpty) {
          return Center(
              child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Text(nikoText('暂无文件任务', 'No file tasks'))));
        }
        return ListView.separated(
            padding: const EdgeInsets.all(12),
            itemCount: jobs.length,
            separatorBuilder: (_, __) => const SizedBox(height: 10),
            itemBuilder: (context, index) {
              final job = jobs[index];
              return NikoFileTaskCard(
                  job: job,
                  request: controller.niko.request(job.id),
                  cancellation: controller.niko.cancellation(job.id),
                  folder: controller.niko.folder(job.id),
                  requestIssue: controller.niko.failure(job.id),
                  retryBlock: controller.nikoRetryBlock(job),
                  onCancel: () => controller.nikoCancelJob(job.id),
                  onRemove: () => controller.nikoRemoveRecord(job.id),
                  onRetry: () async {
                    final sent = await controller.nikoResendJob(job.id);
                    if (!sent && context.mounted) {
                      nikoNotice(
                          context,
                          nikoText('重新发送未全部完成，请查看任务状态或重新连接。',
                              'Resending did not fully finish. Check the task status or reconnect.'));
                    }
                  });
            });
      });
}

class NikoFileWorkspace extends StatefulWidget {
  final Widget local;
  final Widget remote;
  final Widget tasks;
  final bool alwaysCompact;
  final int? selectedPane;
  final ValueChanged<int>? onPaneChanged;
  final String? localLabel;
  const NikoFileWorkspace(
      {super.key,
      required this.local,
      required this.remote,
      required this.tasks,
      this.alwaysCompact = false,
      this.selectedPane,
      this.onPaneChanged,
      this.localLabel});
  @override
  State<NikoFileWorkspace> createState() => _NikoFileWorkspaceState();
}

class _NikoFileWorkspaceState extends State<NikoFileWorkspace> {
  int _selected = 0;
  @override
  Widget build(BuildContext context) =>
      LayoutBuilder(builder: (context, constraints) {
        final scale =
            math.max(1.0, MediaQuery.textScalerOf(context).scale(16) / 16);
        final selected = widget.selectedPane ?? _selected;
        if (!widget.alwaysCompact && constraints.maxWidth / scale >= 1100) {
          return Row(children: [
            Flexible(flex: 3, child: widget.local),
            Flexible(flex: 3, child: widget.remote),
            Flexible(flex: 2, child: widget.tasks),
          ]);
        }
        return Column(children: [
          Padding(
              padding: const EdgeInsets.all(8),
              child: Wrap(spacing: 8, runSpacing: 4, children: [
                for (var i = 0; i < 3; i++)
                  ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 48),
                      child: ChoiceChip(
                          key: Key('niko-file-pane-$i'),
                          selected: selected == i,
                          label: Text([
                            widget.localLabel ?? nikoText('本地', 'Local'),
                            nikoText('远端', 'Remote'),
                            nikoText('任务', 'Tasks')
                          ][i]),
                          onSelected: (_) {
                            setState(() => _selected = i);
                            widget.onPaneChanged?.call(i);
                          })),
              ])),
          Expanded(
              child: IndexedStack(index: selected, children: [
            for (var i = 0; i < 3; i++)
              ExcludeFocus(
                  excluding: selected != i,
                  child: [widget.local, widget.remote, widget.tasks][i]),
          ])),
        ]);
      });
}

class NikoAppFileAreaNotice extends StatelessWidget {
  final String? status;
  final VoidCallback onDismiss;
  final bool showGuide;
  const NikoAppFileAreaNotice(
      {super.key,
      this.status,
      required this.onDismiss,
      required this.showGuide});

  @override
  Widget build(BuildContext context) => ConstrainedBox(
      constraints: BoxConstraints(
          maxHeight: math.min(240, MediaQuery.sizeOf(context).height * .28)),
      child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
        if (showGuide)
          ExpansionTile(
            title: Text(nikoText('应用文件区说明', 'About the app file area')),
            childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            children: [
              ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 140),
                  child: SingleChildScrollView(
                      child: Text(nikoText(
                          '这里显示本应用可访问的文件。通过右上角菜单从系统导入；下载到这里的文件可选中后另存到系统。系统选择器可能需要你选择位置或授予访问权限。',
                          'This area shows files accessible to this app. Import from system files using the top-right menu. Select downloaded files here to save them to system files. The system picker may ask you to choose a location or grant access.'))))
            ],
          ),
        if (status != null)
          Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
              child:
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(
                    child: Semantics(liveRegion: true, child: Text(status!))),
                IconButton(
                    tooltip: nikoText('关闭操作结果', 'Dismiss result'),
                    constraints:
                        const BoxConstraints(minWidth: 48, minHeight: 48),
                    onPressed: onDismiss,
                    icon: const Icon(Icons.close)),
              ])),
      ])));
}

class NikoFilePaneTools extends StatelessWidget {
  final Widget child;
  const NikoFilePaneTools({super.key, required this.child});

  @override
  Widget build(BuildContext context) =>
      LayoutBuilder(builder: (context, constraints) {
        final scale =
            math.max(1.0, MediaQuery.textScalerOf(context).scale(16) / 16);
        return SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SizedBox(
                width: math.max(constraints.maxWidth, 520 * scale),
                child: child));
      });
}

double nikoFileRowExtent(BuildContext context, double base) => math.max(48,
    base * math.max(1, MediaQuery.textScalerOf(context).scale(16) / 16) + 8);

/// Keeps the real sortable columns and file list readable on a narrow window.
class NikoFileDirectoryTable extends StatelessWidget {
  final Widget child;
  const NikoFileDirectoryTable({super.key, required this.child});

  @override
  Widget build(BuildContext context) =>
      LayoutBuilder(builder: (context, constraints) {
        final scale =
            math.max(1.0, MediaQuery.textScalerOf(context).scale(16) / 16);
        return SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SizedBox(
                width: math.max(constraints.maxWidth, 540 * scale),
                height: constraints.maxHeight,
                child: child));
      });
}
