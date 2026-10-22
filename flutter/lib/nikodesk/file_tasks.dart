import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart' show readableFileSize;
import 'package:flutter_hbb/models/file_model.dart';
import 'package:get/get.dart';

import 'file_transfer.dart';
import 'nightline.dart';
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
    final nl = NlColors.maybeOf(context);
    if (nl != null) {
      return _nightline(context, nl,
          transfer: transfer,
          dataActive: dataActive,
          active: active,
          failed: failed,
          status: status,
          direction: direction,
          progress: progress);
    }
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

  /// Nightline task: a glyph and colour for the state, the same status and
  /// explanation texts, the draft's 4 px bar, and the paths in mono.
  Widget _nightline(BuildContext context, NlColors nl,
      {required bool transfer,
      required bool dataActive,
      required bool active,
      required bool failed,
      required String status,
      required String direction,
      required double? progress}) {
    final cancelling = cancellation != NikoCancelState.none ||
        (job.state == JobState.done && job.err == 'cancel');
    final (IconData glyph, Color ink, Color wash) = failed
        ? (Icons.error_outline_rounded, nl.dangerText, nl.dangerSoft)
        : cancelling || job.state == JobState.paused
            ? (Icons.pause_rounded, nl.warnText, nl.warnSoft)
            : !transfer || job.err == 'skipped'
                ? (
                    transfer
                        ? Icons.redo_rounded
                        : Icons.delete_outline_rounded,
                    nl.fg2,
                    nl.surface2
                  )
                : job.state == JobState.done && !active
                    ? (Icons.check_rounded, nl.okText, nl.okSoft)
                    : (
                        job.isRemoteToLocal
                            ? Icons.south_rounded
                            : Icons.north_rounded,
                        nl.accentText,
                        nl.accentSoft
                      );
    final showProgress = transfer &&
        dataActive &&
        cancellation != NikoCancelState.requested;
    final removable = !active || cancellation == NikoCancelState.requested;
    final reduced = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final small = NlType.text(NlType.s2, color: nl.fg2);
    // A zero-width space after each separator lets a long path wrap at a
    // folder boundary instead of inside a name or after "C:".
    Widget path(String label, String value) => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              NlMonoLabel(label),
              Text(
                  value.replaceAllMapped(
                      RegExp(r'[\\/]'), (match) => '${match[0]}​'),
                  style: NlType.monoText(NlType.s1, color: nl.fg2)),
            ]);
    return NlPanel(
        padding: const EdgeInsets.all(NlSpace.s3),
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                        color: wash,
                        borderRadius: BorderRadius.circular(NlRadius.r2)),
                    child: Icon(glyph, size: 16, color: ink)),
                const SizedBox(width: NlSpace.s3),
                Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      Tooltip(
                          message: job.jobName,
                          child: Text(
                              job.fileName.isEmpty ? job.jobName : job.fileName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: NlType.text(NlType.s3,
                                  weight: FontWeight.w600, color: nl.fg))),
                      Text(direction,
                          style: NlType.text(NlType.s2, color: nl.fg3)),
                    ])),
                if (showProgress && job.totalSize > 0) ...[
                  const SizedBox(width: NlSpace.s2),
                  Text(job.percentText,
                      style: NlType.monoText(NlType.s2,
                          weight: FontWeight.w500, color: nl.fg2)),
                ],
                if (removable)
                  NlIconButton(
                      key: Key('niko-file-remove-${job.id}'),
                      icon: Icons.close_rounded,
                      tooltip: nikoText('移除记录', 'Remove record'),
                      onPressed: onRemove),
              ]),
              const SizedBox(height: NlSpace.s2),
              Semantics(
                  liveRegion: true,
                  child: Text(status,
                      style: NlType.text(NlType.s2,
                          weight: FontWeight.w500, color: ink))),
              if (showProgress) ...[
                const SizedBox(height: NlSpace.s2),
                ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                        value: progress ?? (reduced ? 0 : null),
                        minHeight: 4,
                        color: nl.accent,
                        backgroundColor: nl.surface2)),
                const SizedBox(height: NlSpace.s1),
                job.recvJobRes
                    ? Tooltip(
                        message:
                            '${job.finishedSize}/${job.totalSize} B · ${job.speed.toStringAsFixed(0)} B/s',
                        child: Text(
                            '${readableFileSize(job.finishedSize.toDouble())} / '
                            '${readableFileSize(job.totalSize.toDouble())} · '
                            '${readableFileSize(job.speed)}/s',
                            style: NlType.monoText(NlType.s1, color: nl.fg2)))
                    : Text(
                        nikoText('尚未收到传输进度', 'No transfer progress received yet'),
                        style: small),
              ],
              if (request != null) ...[
                const SizedBox(height: NlSpace.s3),
                path(nikoText('源', 'Source'), request!.source),
                const SizedBox(height: NlSpace.s2),
                path(nikoText('目标', 'Destination'), request!.destination),
              ],
              if (folder != null) ...[
                const SizedBox(height: NlSpace.s2),
                Semantics(
                    liveRegion: true,
                    child: Text(nikoFolderDetail(folder!), style: small)),
              ],
              if (requestIssue != null && folder == null) ...[
                const SizedBox(height: NlSpace.s2),
                Semantics(
                    liveRegion: true,
                    child: Text(nikoFileRequestIssue(requestIssue!),
                        style: NlType.text(NlType.s2, color: nl.warnText))),
              ],
              if (job.state == JobState.error && job.err.isNotEmpty) ...[
                const SizedBox(height: NlSpace.s2),
                Text('${nikoText('错误', 'Error')}: ${job.err}',
                    key: Key('niko-file-error-${job.id}'),
                    style: NlType.text(NlType.s2, color: nl.dangerText)),
              ],
              if (failed || job.state == JobState.paused) ...[
                const SizedBox(height: NlSpace.s2),
                Text(
                    retryBlock == null
                        ? nikoText('重新发送会从头开始；同名文件会再次询问是否覆盖。',
                            'Resending starts from the beginning. A same-name destination prompts for overwrite again.')
                        : nikoFileRetryReason(retryBlock!),
                    style: small),
              ],
              if ((active && cancellation != NikoCancelState.requested) ||
                  (transfer && failed && retryBlock == null)) ...[
                const SizedBox(height: NlSpace.s3),
                Wrap(spacing: NlSpace.s2, runSpacing: NlSpace.s2, children: [
                  if (active && cancellation != NikoCancelState.requested)
                    NlButton.ghost(
                        key: Key('niko-file-cancel-${job.id}'),
                        small: true,
                        onPressed: cancellation == NikoCancelState.requesting
                            ? null
                            : onCancel,
                        label: nikoText('请求取消', 'Request cancel')),
                  if (transfer && failed && retryBlock == null)
                    NlButton(
                        key: Key('niko-file-resend-${job.id}'),
                        small: true,
                        icon: Icons.refresh_rounded,
                        onPressed: onRetry,
                        label: nikoText('重新发送', 'Resend')),
                ]),
              ],
            ]));
  }
}

class NikoFileTasks extends StatelessWidget {
  final JobController controller;
  const NikoFileTasks({super.key, required this.controller});

  @override
  Widget build(BuildContext context) => Obx(() {
        final jobs = controller.jobTable.toList();
        final nl = NlColors.maybeOf(context);
        if (nl != null) return _nightline(context, nl, jobs);
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
            itemBuilder: (context, index) => _card(context, jobs[index]));
      });

  Widget _card(BuildContext context, JobProgress job) => NikoFileTaskCard(
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

  /// Nightline: a titled column with the running count, the cards, and an
  /// empty state that says how a transfer starts.
  Widget _nightline(BuildContext context, NlColors nl, List<JobProgress> jobs) {
    final running = jobs
        .where((job) =>
            job.state == JobState.inProgress || job.state == JobState.none)
        .length;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
          padding: const EdgeInsets.fromLTRB(
              NlSpace.s4, NlSpace.s4, NlSpace.s4, NlSpace.s3),
          child: Row(children: [
            Expanded(child: NlMonoLabel(nikoText('传输任务', 'Transfers'))),
            if (jobs.isNotEmpty)
              Text(
                  running > 0
                      ? nikoText('$running 进行中 · 共 ${jobs.length}',
                          '$running active · ${jobs.length}')
                      : '${jobs.length}',
                  style: NlType.monoText(NlType.s1, color: nl.fg3)),
          ])),
      Expanded(
          child: jobs.isEmpty
              ? Center(
                  child: SingleChildScrollView(
                      padding: const EdgeInsets.all(NlSpace.s6),
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        Icon(Icons.swap_vert_rounded, size: 28, color: nl.fg3),
                        const SizedBox(height: NlSpace.s3),
                        Text(nikoText('暂无传输任务', 'No transfers yet'),
                            textAlign: TextAlign.center,
                            style: NlType.text(NlType.s3,
                                weight: FontWeight.w600, color: nl.fg)),
                        const SizedBox(height: NlSpace.s1),
                        Text(
                            nikoText('在一侧选中文件后点“发送”或“接收”；也可以把文件拖到远端一侧发送。',
                                'Select files on one side and choose Send or Receive, or drop files on the remote side to send them.'),
                            textAlign: TextAlign.center,
                            style: NlType.text(NlType.s2, color: nl.fg2)),
                      ])))
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(
                      NlSpace.s3, 0, NlSpace.s3, NlSpace.s3),
                  itemCount: jobs.length,
                  separatorBuilder: (_, __) =>
                      const SizedBox(height: NlSpace.s2),
                  itemBuilder: (context, index) =>
                      _card(context, jobs[index]))),
    ]);
  }
}

class NikoFileWorkspace extends StatefulWidget {
  final Widget local;
  final Widget remote;
  final Widget tasks;
  final bool alwaysCompact;
  final int? selectedPane;
  final ValueChanged<int>? onPaneChanged;
  final String? localLabel;

  /// The task list; its length is shown on the Tasks switch in Nightline.
  final RxList<JobProgress>? jobs;
  const NikoFileWorkspace(
      {super.key,
      required this.local,
      required this.remote,
      required this.tasks,
      this.alwaysCompact = false,
      this.selectedPane,
      this.onPaneChanged,
      this.localLabel,
      this.jobs});
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
        final nl = NlColors.maybeOf(context);
        if (nl != null) return _nightline(nl, constraints.maxWidth / scale, selected);
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

  /// Nightline: both directories side by side with the tasks in an inspector
  /// column once each pane can hold its table (about 420 px plus the pane's
  /// margins); below that, one pane at a time behind a segmented switch.
  Widget _nightline(NlColors nl, double width, int selected) {
    if (!widget.alwaysCompact && width >= 1240) {
      return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Expanded(child: widget.local),
        Expanded(child: widget.remote),
        Container(
            width: 300,
            decoration: BoxDecoration(
                color: nl.bg2,
                border: Border(left: BorderSide(color: nl.line))),
            child: widget.tasks),
      ]);
    }
    Widget switcher(int? tasks) => NlSegmented<int>(
        segments: [
          NlSegment(
              key: const Key('niko-file-pane-0'),
              value: 0,
              label: widget.localLabel ?? nikoText('本地', 'Local')),
          NlSegment(
              key: const Key('niko-file-pane-1'),
              value: 1,
              label: nikoText('远端', 'Remote')),
          NlSegment(
              key: const Key('niko-file-pane-2'),
              value: 2,
              label: nikoText('任务', 'Tasks'),
              count: tasks == null || tasks == 0 ? null : '$tasks'),
        ],
        selected: selected,
        onChanged: (pane) {
          setState(() => _selected = pane);
          widget.onPaneChanged?.call(pane);
        });
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
          padding: const EdgeInsets.fromLTRB(
              NlSpace.s6, NlSpace.s3, NlSpace.s6, 0),
          child: Align(
              alignment: Alignment.centerLeft,
              child: widget.jobs == null
                  ? switcher(null)
                  : Obx(() => switcher(widget.jobs!.length)))),
      Expanded(
          child: IndexedStack(index: selected, children: [
        for (var i = 0; i < 3; i++)
          ExcludeFocus(
              excluding: selected != i,
              child: [widget.local, widget.remote, widget.tasks][i]),
      ])),
    ]);
  }
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
        // Two rows of 38 px icon buttons plus the send button fit in 320.
        return SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SizedBox(
                width: math.max(constraints.maxWidth, 320 * scale),
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
        // Name 190 + modified 160 + dividers leave about 64 for the size.
        return SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SizedBox(
                width: math.max(constraints.maxWidth, 420 * scale),
                height: constraints.maxHeight,
                child: child));
      });
}
