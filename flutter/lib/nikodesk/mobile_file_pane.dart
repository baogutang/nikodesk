import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart' show readableFileSize, versionCmp;
import 'package:flutter_hbb/common/formatter/id_formatter.dart' show formatID;
import 'package:flutter_hbb/consts.dart' show StringExtension;
import 'package:flutter_hbb/models/file_model.dart';
import 'package:get/get.dart';

import 'file_pane.dart' show NikoFileListColors, nikoPlatformName;
import 'file_tasks.dart' show NikoFileWorkspace;
import 'nightline.dart';
import 'ui.dart';

/// Nightline pieces for the phone and iPad file page (upstream mobile
/// FileManagerView and its selection sheet). Each returns null outside the
/// NikoDesk build or a Nightline theme, where the upstream piece stays.

bool _styled(BuildContext context) =>
    const bool.fromEnvironment('NIKODESK') && NlColors.maybeOf(context) != null;

/// One entry as a list row: glyph, name, date and size, and either the
/// selection box or a menu of the entry's actions. [onCheck] adds or removes
/// the entry from the selection; [onMultiSelect] starts or ends selecting,
/// with the entry chosen, as a long press does.
Widget? nikoMobileFileRow(BuildContext context,
        {required FileController controller,
        required Entry entry,
        required bool selected,
        required bool checking,
        required ValueChanged<bool> onCheck,
        required VoidCallback onMultiSelect}) =>
    _styled(context)
        ? NikoMobileFileRow(
            key: ValueKey(entry.name),
            controller: controller,
            entry: entry,
            selected: selected,
            checking: checking,
            onCheck: onCheck,
            onMultiSelect: onMultiSelect)
        : null;

class NikoMobileFileRow extends StatelessWidget {
  final FileController controller;
  final Entry entry;
  final bool selected;
  final bool checking;
  final ValueChanged<bool> onCheck;
  final VoidCallback onMultiSelect;
  const NikoMobileFileRow(
      {super.key,
      required this.controller,
      required this.entry,
      required this.selected,
      required this.checking,
      required this.onCheck,
      required this.onMultiSelect});

  /// Glyph column plus the gap before the name; the hairline starts there.
  static const inset = NlSpace.s4 + 36 + NlSpace.s3;

  String get _detail {
    final at = entry.lastModified();
    String two(int value) => value.toString().padLeft(2, '0');
    final date = '${at.year}-${two(at.month)}-${two(at.day)} '
        '${two(at.hour)}:${two(at.minute)}';
    return entry.isFile
        ? '$date · ${readableFileSize(entry.size.toDouble())}'
        : date;
  }

  /// The upstream rule: peers from 1.3.0 on can rename.
  bool get _canRename =>
      versionCmp(
          controller.rootState.target?.ffiModel.pi.version ?? '', '1.3.0') >=
      0;

  void _open() {
    if (checking) {
      onCheck(!selected);
    } else if (entry.isDirectory || entry.isDrive) {
      controller.openDirectory(entry.path);
    }
  }

  void _menu(BuildContext anchor) {
    showNlMenu(anchor, anchor: nlAnchorOf(anchor), width: 220, entries: [
      NlMenuItem(
          label: nikoText('多选', 'Select'),
          icon: NlIcons.circleCheck,
          onSelected: onMultiSelect),
      if (_canRename)
        NlMenuItem(
            label: nikoText('重命名', 'Rename'),
            icon: NlIcons.pencil,
            onSelected: () =>
                controller.renameAction(entry, controller.isLocal)),
      const NlMenuDivider(),
      NlMenuItem(
          label: nikoText('删除', 'Delete'),
          icon: NlIcons.trash2,
          danger: true,
          onSelected: () {
            final items = SelectedItems(isLocal: controller.isLocal);
            items.add(entry);
            controller.removeAction(items);
          }),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final nl = NlColors.of(context);
    final colors = NikoFileListColors.of(context);
    final touch = NlLayout.touch(context);
    final (IconData glyph, Color ink) = entry.isDrive
        ? (NlIcons.hardDrive, nl.fg2)
        : entry.isFile
            ? (NlIcons.file, nl.fg3)
            : (NlIcons.folder, nl.accent);
    final duration = NlMotion.of(context, NlMotion.fast);
    return Semantics(
        selected: selected,
        child: NlPressable(
            onTap: _open,
            // A long press starts selecting, as it does upstream.
            onContextMenu: entry.isDrive ? null : (_) => onMultiSelect(),
            pressScale: 1,
            builder: (context, states) => AnimatedContainer(
                duration: duration,
                constraints: BoxConstraints(minHeight: touch ? 60 : 48),
                color: selected
                    ? colors?.selected ?? nl.selected
                    : states.contains(WidgetState.pressed)
                        ? nl.hover
                        : Colors.transparent,
                child: Stack(children: [
                  Padding(
                      padding: const EdgeInsets.fromLTRB(
                          NlSpace.s4, NlSpace.s2, NlSpace.s2, NlSpace.s2),
                      child: Row(children: [
                        SizedBox(
                            width: 36,
                            child: Icon(glyph, size: 22, color: ink)),
                        const SizedBox(width: NlSpace.s3),
                        Expanded(
                            child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                              // Cut the name, not a word, at the end.
                              Text(entry.name.nonBreaking,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: NlType.text(
                                      touch ? NlType.s4 : NlType.s3,
                                      color: nl.fg)),
                              if (!entry.isDrive)
                                Padding(
                                    padding: const EdgeInsets.only(top: 2),
                                    child: Text(_detail,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: NlType.text(NlType.s2,
                                            color: colors?.meta ?? nl.fg2))),
                            ])),
                        const SizedBox(width: NlSpace.s2),
                        if (entry.isDrive)
                          const SizedBox.shrink()
                        else if (checking)
                          NlCheckbox(
                              value: selected,
                              onChanged: onCheck,
                              semanticLabel: entry.name)
                        else
                          Builder(
                              builder: (anchor) => NlIconButton(
                                  icon: NlIcons.ellipsis,
                                  tooltip: nikoText('更多操作', 'More actions'),
                                  onPressed: () => _menu(anchor))),
                      ])),
                  Positioned(
                      left: inset,
                      right: 0,
                      bottom: 0,
                      child: Container(height: 1, color: nl.line)),
                ]))));
  }
}

/// Home, the folders down to the current one, and back, up and sort.
Widget? nikoMobilePathBar(BuildContext context, FileController controller) =>
    _styled(context) ? NikoMobilePathBar(controller: controller) : null;

class NikoMobilePathBar extends StatefulWidget {
  final FileController controller;
  const NikoMobilePathBar({super.key, required this.controller});

  @override
  State<NikoMobilePathBar> createState() => _PathBarState();
}

class _PathBarState extends State<NikoMobilePathBar> {
  final _scroll = ScrollController();
  StreamSubscription<FileDirectory>? _directory;

  FileController get _controller => widget.controller;

  @override
  void initState() {
    super.initState();
    // The deepest folder stays in view as the path grows.
    _directory = _controller.directory
        .listen((_) => WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted && _scroll.hasClients) {
                _scroll.animateTo(_scroll.position.maxScrollExtent,
                    duration: NlMotion.of(context, NlMotion.base),
                    curve: NlMotion.standard);
              }
            }));
  }

  @override
  void dispose() {
    _directory?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  /// The upstream breadcrumb's rule: a path under home is relative to it.
  void _openSegment(List<String> list) {
    final options = _controller.options.value;
    var path = options.home.startsWith(list[0]) ? '' : options.home;
    for (final item in list) {
      path = PathUtil.join(path, item, options.isWindows);
    }
    _controller.openDirectory(path);
  }

  void _sort(BuildContext anchor) {
    String name(SortBy sort) => switch (sort) {
          SortBy.name => nikoText('名称', 'Name'),
          SortBy.type => nikoText('类型', 'Kind'),
          SortBy.modified => nikoText('修改时间', 'Date modified'),
          SortBy.size => nikoText('大小', 'Size'),
        };
    // Upstream's ascending puts the largest and the newest first.
    String order(SortBy sort, bool ascending) => switch ((sort, ascending)) {
          (SortBy.modified, true) => nikoText('最新的在前', 'Newest first'),
          (SortBy.modified, false) => nikoText('最早的在前', 'Oldest first'),
          (SortBy.size, true) => nikoText('最大的在前', 'Largest first'),
          (SortBy.size, false) => nikoText('最小的在前', 'Smallest first'),
          (_, true) => 'A → Z',
          (_, false) => 'Z → A',
        };
    final current = _controller.sortBy.value;
    showNlMenu(anchor, anchor: nlAnchorOf(anchor), width: 220, entries: [
      NlMenuHeader('${order(current, _controller.sortAscending)} · '
          '${nikoText('再选一次反转', 'choose again to reverse')}'),
      for (final sort in SortBy.values)
        NlMenuItem(
            label: name(sort),
            checked: sort == current,
            // The same choice again reverses the order, as upstream.
            onSelected: () => _controller.changeSortStyle(sort,
                ascending:
                    sort == current ? !_controller.sortAscending : true)),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final nl = NlColors.of(context);
    return Padding(
        padding: const EdgeInsets.fromLTRB(
            NlSpace.s2, NlSpace.s1, NlSpace.s2, NlSpace.s1),
        child: Row(children: [
          NlIconButton(
              icon: NlIcons.house,
              tooltip: nikoText('主目录', 'Home folder'),
              onPressed: _controller.goToHomeDirectory),
          Expanded(child: Obx(() {
            final options = _controller.options.value;
            // Read so a new directory rebuilds the trail.
            _controller.directory.value;
            final list =
                PathUtil.split(_controller.shortPath, options.isWindows);
            return SingleChildScrollView(
                controller: _scroll,
                scrollDirection: Axis.horizontal,
                child: Row(children: [
                  for (final (index, folder) in list.indexed) ...[
                    Icon(NlIcons.chevronRight, size: 14, color: nl.fg3),
                    NlPressable(
                        onTap: () => _openSegment(list.sublist(0, index + 1)),
                        builder: (context, states) => Container(
                            constraints: BoxConstraints(
                                minHeight: NlLayout.target(context)),
                            alignment: Alignment.center,
                            padding: const EdgeInsets.symmetric(
                                horizontal: NlSpace.s2),
                            decoration: BoxDecoration(
                                color: states.contains(WidgetState.pressed) ||
                                        states.contains(WidgetState.hovered)
                                    ? nl.hover
                                    : Colors.transparent,
                                borderRadius:
                                    BorderRadius.circular(NlRadius.r2)),
                            child: Text(folder,
                                style: NlType.text(NlType.s3,
                                    weight: index == list.length - 1
                                        ? FontWeight.w600
                                        : FontWeight.w400,
                                    color: index == list.length - 1
                                        ? nl.fg
                                        : nl.fg2)))),
                  ],
                ]));
          })),
          const SizedBox(width: NlSpace.s1),
          NlIconButton(
              icon: NlIcons.arrowLeft,
              tooltip: nikoText('返回', 'Back'),
              onPressed: _controller.goBack),
          NlIconButton(
              icon: NlIcons.cornerLeftUp,
              tooltip: nikoText('上一级', 'Enclosing folder'),
              onPressed: _controller.goToParentDirectory),
          Builder(
              builder: (anchor) => NlIconButton(
                  icon: NlIcons.arrowUpDown,
                  tooltip: nikoText('排序', 'Sort'),
                  onPressed: () => _sort(anchor))),
        ]));
  }
}

/// The current path and how many entries it holds, under the list. With
/// [clearance] the list can scroll its last row above the selection bar.
Widget? nikoMobileListTail(BuildContext context, FileController controller,
    {bool clearance = false}) {
  if (!_styled(context)) return null;
  final nl = NlColors.of(context);
  return Obx(() {
    final directory = controller.directory.value;
    return Padding(
        padding: EdgeInsets.fromLTRB(NlSpace.s4, NlSpace.s4, NlSpace.s4,
            NlSpace.s10 + (clearance ? 96 : 0)),
        child: Column(children: [
          Text(directory.path,
              textAlign: TextAlign.center,
              style: NlType.monoText(NlType.s2, color: nl.fg3)),
          const SizedBox(height: 2),
          Text(
              nikoText('共 ${directory.entries.length} 项',
                  '${directory.entries.length} items'),
              style: NlType.text(NlType.s2, color: nl.fg3)),
        ]));
  });
}

/// The selection sheet as a bar: what is chosen on the left, its actions on
/// the right. [actions] are the upstream icon buttons; each is drawn with the
/// Lucide match of its glyph, or kept as it is when there is none.
BottomSheet? nikoSelectionSheet(BuildContext context,
    {required String title,
    required String text,
    required Widget leading,
    VoidCallback? onCanceled,
    List<IconButton>? actions}) {
  if (!_styled(context)) return null;
  final nl = NlColors.of(context);
  final mark = leading is Icon ? _lucide(leading.icon) : null;
  return _selectionBar(
      context,
      Row(children: [
        if (mark != null) ...[
          Icon(mark, size: 20, color: nl.accent),
          const SizedBox(width: NlSpace.s3),
        ],
        Expanded(
            child: Semantics(
                liveRegion: true,
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: NlType.text(NlType.s3,
                              weight: FontWeight.w600, color: nl.fg)),
                      Text(text,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: NlType.text(NlType.s2, color: nl.fg2)),
                    ]))),
        const SizedBox(width: NlSpace.s2),
        Wrap(children: [
          for (final button in actions ?? <IconButton>[])
            nikoMobileIconButton(context, button),
          NlIconButton(
              icon: NlIcons.close,
              tooltip: nikoText('取消选择', 'Cancel selection'),
              onPressed: onCanceled),
        ]),
      ]));
}

/// The floating frame of the selection bars around [child].
BottomSheet _selectionBar(BuildContext context, Widget child) {
  final nl = NlColors.of(context);
  return BottomSheet(
      enableDrag: false,
      onClosing: () {},
      backgroundColor: Colors.transparent,
      elevation: 0,
      shape: const RoundedRectangleBorder(),
      // The scaffold hands its bottom sheet no bottom padding, so the bar
      // reads the view's to stay clear of the home indicator.
      builder: (context) => SafeArea(
          top: false,
          bottom: false,
          minimum: const EdgeInsets.symmetric(horizontal: NlSpace.s3),
          child: Container(
              margin: EdgeInsets.only(
                  bottom: math.max(
                      NlSpace.s3,
                      MediaQueryData.fromView(View.of(context))
                          .padding
                          .bottom)),
              padding: const EdgeInsets.fromLTRB(
                  NlSpace.s4, NlSpace.s2, NlSpace.s2, NlSpace.s2),
              decoration: BoxDecoration(
                  color: nl.overlay,
                  borderRadius: BorderRadius.circular(NlRadius.r4),
                  border: Border.all(color: nl.isDark ? nl.line2 : nl.line),
                  boxShadow: nl.shadow3),
              child: child)));
}

/// Whether the file page shows app files and the remote side next to each
/// other: at least 1000 points across at the current text size, an iPad in
/// landscape for one. Narrower windows keep one side at a time.
bool nikoMobileFileSplit(BuildContext context) =>
    _styled(context) &&
    MediaQuery.sizeOf(context).width / _textScale(context) >=
        NlLayout.mediumMax;

double _textScale(BuildContext context) =>
    math.max(1.0, MediaQuery.textScalerOf(context).scale(16) / 16);

String _sideName(bool local) =>
    local ? nikoText('应用文件', 'App files') : nikoText('远端', 'Remote');

/// The side the actions menu works on, as its header, while both sides
/// show; null otherwise.
String? nikoMobileMenuSide(BuildContext context, bool local) =>
    nikoMobileFileSplit(context) ? _sideName(local) : null;

/// The file page under its notice. Where [nikoMobileFileSplit] holds, both
/// sides stand next to each other, each under its name, and from 1240
/// points the tasks take a column beside them as in the desktop window;
/// below that a Files | Tasks switch shows the tasks instead. Narrower
/// windows keep one side at a time behind the upstream-shaped switch.
///
/// [pane] is the side the page's actions menu and back button work on (0
/// app files, 1 the remote side) or 2 while the tasks show, when
/// [localActive] keeps which side that was. A touch on a side makes it the
/// one. [selecting] reads the page's select mode: true while app files are
/// being chosen, false for the remote side, null otherwise.
class NikoMobileFileArea extends StatelessWidget {
  final Widget local;
  final Widget remote;
  final Widget tasks;
  final FileController localController;
  final FileController remoteController;
  final RxList<JobProgress> jobs;
  final int pane;
  final bool localActive;
  final ValueChanged<int> onPaneChanged;
  final bool? Function() selecting;
  const NikoMobileFileArea(
      {super.key,
      required this.local,
      required this.remote,
      required this.tasks,
      required this.localController,
      required this.remoteController,
      required this.jobs,
      required this.pane,
      required this.localActive,
      required this.onPaneChanged,
      required this.selecting});

  @override
  Widget build(BuildContext context) {
    if (!nikoMobileFileSplit(context)) {
      return NikoFileWorkspace(
          alwaysCompact: true,
          selectedPane: pane,
          localLabel: _sideName(true),
          onPaneChanged: onPaneChanged,
          local: local,
          remote: remote,
          tasks: tasks,
          jobs: jobs);
    }
    return LayoutBuilder(
        builder: (context, box) =>
            _split(context, box.maxWidth / _textScale(context)));
  }

  Widget _split(BuildContext context, double width) {
    final nl = NlColors.of(context);
    Widget side(bool isLocal) => Listener(
        onPointerDown: (_) {
          if (pane == 2 || isLocal != localActive) {
            onPaneChanged(isLocal ? 0 : 1);
          }
        },
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _SplitHeader(
              controller: isLocal ? localController : remoteController,
              active: pane < 2 && isLocal == localActive,
              selecting: selecting),
          Expanded(child: isLocal ? local : remote),
        ]));
    final files =
        Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Expanded(child: side(true)),
      Container(width: 1, color: nl.line),
      Expanded(child: side(false)),
    ]);
    if (width >= 1240) {
      return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Expanded(child: files),
        Container(
            width: 300,
            decoration: BoxDecoration(
                color: nl.bg2,
                border: Border(left: BorderSide(color: nl.line))),
            child: tasks),
      ]);
    }
    final showTasks = pane == 2;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
          padding: const EdgeInsets.fromLTRB(
              NlSpace.s6, NlSpace.s3, NlSpace.s6, NlSpace.s3),
          child: Align(
              alignment: Alignment.centerLeft,
              child: Obx(() => NlSegmented<bool>(
                      segments: [
                        NlSegment(
                            key: const Key('niko-file-split-files'),
                            value: false,
                            label: nikoText('文件', 'Files')),
                        NlSegment(
                            key: const Key('niko-file-split-tasks'),
                            value: true,
                            label: nikoText('任务', 'Tasks'),
                            count: jobs.isEmpty ? null : '${jobs.length}'),
                      ],
                      selected: showTasks,
                      onChanged: (tasks) =>
                          onPaneChanged(tasks ? 2 : (localActive ? 0 : 1)))))),
      Expanded(
          child: IndexedStack(index: showTasks ? 1 : 0, children: [
        ExcludeFocus(excluding: showTasks, child: files),
        ExcludeFocus(excluding: !showTasks, child: tasks),
      ])),
    ]);
  }
}

/// A side's name above its path bar, with the remote's ID and platform, and
/// its part in a selection: the entries come from here, or go to the folder
/// open here. The active side's name is in full ink.
class _SplitHeader extends StatelessWidget {
  final FileController controller;
  final bool active;
  final bool? Function() selecting;
  const _SplitHeader(
      {required this.controller,
      required this.active,
      required this.selecting});

  @override
  Widget build(BuildContext context) {
    final nl = NlColors.of(context);
    final local = controller.isLocal;
    return Obx(() {
      // The session reports the peer's platform before its first folder.
      controller.directory.value;
      final ffi = controller.rootState.target;
      final id = local ? '' : formatID(ffi?.id ?? '');
      final platform =
          local ? '' : nikoPlatformName(ffi?.ffiModel.pi.platform ?? '');
      final side = selecting();
      return Container(
          constraints: BoxConstraints(minHeight: NlLayout.target(context)),
          padding: const EdgeInsets.symmetric(horizontal: NlSpace.s4),
          decoration:
              BoxDecoration(border: Border(bottom: BorderSide(color: nl.line))),
          child: Row(children: [
            Icon(local ? NlIcons.tablet : NlIcons.monitor,
                size: 16, color: active ? nl.accent : nl.fg3),
            const SizedBox(width: NlSpace.s2),
            Semantics(
                header: true,
                child: Text(_sideName(local),
                    style: NlType.text(NlType.s3,
                        weight: FontWeight.w600,
                        color: active ? nl.fg : nl.fg2))),
            const SizedBox(width: NlSpace.s2),
            Expanded(
                child: Text.rich(
                    TextSpan(children: [
                      if (id.isNotEmpty)
                        TextSpan(
                            text: id,
                            style: NlType.monoText(NlType.s2, color: nl.fg2)),
                      if (platform.isNotEmpty) TextSpan(text: ' · $platform'),
                    ]),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: NlType.text(NlType.s2, color: nl.fg3))),
            if (side == local)
              NlBadge(nikoText('从这里', 'From here'))
            else if (side != null)
              NlBadge(nikoText('到这里', 'To here'),
                  tone: NlTone.accent, icon: NlIcons.folderInput),
          ]));
    });
  }
}

/// The selection bar while both sides show: how many entries are chosen,
/// the folder they go to (the one open on the other side), and sending
/// them there as its one primary action, beside delete and cancel. Sending
/// needs a folder, not a Windows drive list or a side still loading.
/// [onDone] leaves select mode once the entries are sent, deleted or let
/// go. [extra] are upstream icon buttons kept before delete, such as
/// Android's export to system files.
BottomSheet? nikoSplitSelectionBar(BuildContext context,
    {required FileController source,
    required FileController destination,
    required VoidCallback onDone,
    List<IconButton> extra = const []}) {
  if (!_styled(context)) return null;
  final selection = source.selectedItems;
  void finish() {
    selection.clear();
    onDone();
  }

  return _selectionBar(context, Obx(() {
    final nl = NlColors.of(context);
    final count = selection.items.length;
    final folder = destination.directory.value.path;
    final windows = destination.options.value.isWindows;
    final open = folder.isNotEmpty && !(windows && folder == '/');
    final parts = PathUtil.split(folder, windows);
    final name = parts.isEmpty ? folder : parts.last;
    final side = _sideName(destination.isLocal);
    return Row(children: [
      Icon(NlIcons.circleCheck, size: 20, color: nl.accent),
      const SizedBox(width: NlSpace.s3),
      Expanded(
          child: Semantics(
              liveRegion: true,
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(nikoText('已选 $count 项', '$count selected'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: NlType.text(NlType.s3,
                            weight: FontWeight.w600, color: nl.fg)),
                    Text(
                        open
                            ? nikoText('目标：$side › $name', 'To: $side › $name')
                            : destination.isLocal
                                ? nikoText('先在应用文件里打开一个文件夹',
                                    'Open a folder in app files first')
                                : nikoText('先在远端打开一个文件夹',
                                    'Open a folder on the remote side first'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: NlType.text(NlType.s2, color: nl.fg2)),
                  ]))),
      const SizedBox(width: NlSpace.s2),
      for (final button in extra) nikoMobileIconButton(context, button),
      NlIconButton(
          icon: NlIcons.trash2,
          tooltip: nikoText('删除所选文件', 'Delete selected files'),
          color: nl.dangerText,
          onPressed: count == 0
              ? null
              : () async {
                  await source.removeAction(selection);
                  finish();
                }),
      const SizedBox(width: NlSpace.s2),
      NlButton(
          key: const Key('niko-file-split-send'),
          onPressed: open && SelectedItems.valid(selection.items)
              ? () {
                  source.sendFiles(selection, destination.directoryData());
                  finish();
                }
              : null,
          icon: source.isLocal ? NlIcons.arrowRight : NlIcons.arrowLeft,
          label: source.isLocal
              ? nikoText('发送', 'Send')
              : nikoText('接收', 'Receive')),
      NlIconButton(
          icon: NlIcons.close,
          tooltip: nikoText('取消选择', 'Cancel selection'),
          onPressed: finish),
    ]);
  }));
}

/// The Lucide match of a glyph the upstream file page draws, or null.
IconData? _lucide(IconData? glyph) => switch (glyph) {
      Icons.close => NlIcons.close,
      Icons.more_vert => NlIcons.ellipsis,
      Icons.refresh => NlIcons.refreshCw,
      Icons.add_to_drive => NlIcons.fileInput,
      Icons.create_new_folder_outlined => NlIcons.folderInput,
      Icons.article_outlined => NlIcons.fileText,
      Icons.check => NlIcons.circleCheck,
      Icons.folder_outlined => NlIcons.folderPlus,
      Icons.check_box_outlined || Icons.check_box_outline_blank => NlIcons.eye,
      Icons.input || Icons.save_alt => NlIcons.download,
      Icons.drive_folder_upload => NlIcons.upload,
      Icons.compare_arrows => NlIcons.arrowLeftRight,
      Icons.delete_forever => NlIcons.trash2,
      Icons.paste => NlIcons.clipboard,
      _ => null,
    };

/// An upstream icon button of the file page drawn as a Nightline one with
/// the Lucide match of its glyph; kept as it is when there is none.
Widget nikoMobileIconButton(BuildContext context, IconButton button) {
  final icon = button.icon;
  final glyph = _styled(context) && icon is Icon ? _lucide(icon.icon) : null;
  if (glyph == null) return button;
  return NlIconButton(
      icon: glyph,
      tooltip: button.tooltip ?? '',
      color: glyph == NlIcons.trash2 ? NlColors.of(context).dangerText : null,
      onPressed: button.onPressed);
}

String? _labelOf(Widget? widget) => switch (widget) {
      Text(data: final data?) => data,
      Flex(children: final children) =>
        children.map(_labelOf).nonNulls.firstOrNull,
      ProxyWidget(child: final child) => _labelOf(child),
      _ => null,
    };

IconData? _glyphOf(Widget? widget) => switch (widget) {
      Icon(icon: final icon) => icon,
      Flex(children: final children) =>
        children.map(_glyphOf).nonNulls.firstOrNull,
      _ => null,
    };

/// The page's upstream actions menu as a Nightline one. Each item keeps its
/// label, state and action and takes the Lucide match of its glyph; a
/// checkbox glyph becomes the item's check. [header] names what the menu
/// works on, e.g. [nikoMobileMenuSide]. Kept as it is outside the design
/// system, or when an item is not a labelled PopupMenuItem.
Widget nikoMobileActionsMenu(
    BuildContext context, PopupMenuButton<String> button,
    {String? header}) {
  if (!_styled(context)) return button;
  // Built when the menu opens, as upstream does, so each item's state is
  // the current one.
  List<NlMenuItem>? entries(BuildContext context) {
    final entries = <NlMenuItem>[];
    for (final item in button.itemBuilder(context)) {
      if (item is! PopupMenuItem<String>) return null;
      final (label, glyph, value) =
          (_labelOf(item.child), _glyphOf(item.child), item.value);
      if (label == null || value == null) return null;
      entries.add(NlMenuItem(
          label: label,
          icon: _lucide(glyph),
          checked: glyph == Icons.check_box_outlined,
          enabled: item.enabled,
          onSelected: () => button.onSelected?.call(value)));
    }
    return entries;
  }

  if (entries(context) == null) return button;
  return Builder(
      builder: (anchor) => NlIconButton(
          icon: NlIcons.ellipsis,
          tooltip: button.tooltip ?? '',
          onPressed: button.enabled
              ? () => showNlMenu(anchor,
                      anchor: nlAnchorOf(anchor),
                      width: 248,
                      entries: [
                        if (header != null) NlMenuHeader(header),
                        ...?entries(anchor),
                      ])
              : null));
}
