import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../db/folder_dao.dart';
import '../db/track_dao.dart';
import '../state/app_state.dart';
import '../state/player_controller.dart';
import '../theme/app_theme.dart';
import '../utils/format.dart';
import 'dialogs.dart';
import 'launch_result_snack.dart';
import 'scan_access_snack.dart';
import 'subtitle_assign_dialog.dart';
import 'tag_picker_dialog.dart';

/// 中间栏：作品/文件夹浏览（面包屑 + 子文件夹 + 曲目列表）
class FolderBrowser extends StatelessWidget {
  const FolderBrowser({super.key});

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    // 手机上从磁贴长按进多选之后，返回键先退出多选，而不是直接离开这一页。
    return PopScope(
      canPop: !appState.selectionMode,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && appState.selectionMode) {
          appState.clearTrackSelection();
        }
      },
      child: Column(
        children: [
          _breadcrumbBar(context, appState),
          _toolbar(context, appState),
          const Divider(height: 1),
          Expanded(child: _content(context, appState)),
        ],
      ),
    );
  }

  Widget _breadcrumbBar(BuildContext context, AppState appState) {
    final crumbs = appState.breadcrumb;
    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      color: AppColors.panelOf(context),
      child: Row(
        children: [
          IconButton(
            icon: Icon(Icons.arrow_back, size: 18, color: AppColors.mutedLightOf(context)),
            tooltip: '返回上一级',
            onPressed: () => appState.goUp(),
          ),
          Expanded(
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (int i = 0; i < crumbs.length; i++) ...[
                  if (i > 0)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Icon(Icons.chevron_right,
                          size: 16, color: AppColors.mutedOf(context)),
                    ),
                  InkWell(
                    onTap: () => _onCrumbTap(appState, crumbs[i]),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
                      child: Text(
                        crumbs[i].name,
                        style: TextStyle(
                          color: i == crumbs.length - 1
                              ? AppColors.textPrimaryOf(context)
                              : AppColors.mutedLightOf(context),
                          fontSize: 13,
                          fontWeight: i == crumbs.length - 1
                              ? FontWeight.w600
                              : FontWeight.normal,
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _onCrumbTap(AppState appState, VirtualFolder crumb) {
    if (crumb.id == -1) {
      // 作品标记
      if (crumb.workId != null) appState.enterWork(crumb.workId!);
    } else {
      appState.enterFolder(crumb.id!);
    }
  }

  Widget _toolbar(BuildContext context, AppState appState) {
    final isWorkLevel = appState.currentFolderId == null;
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      color: AppColors.backgroundOf(context),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // 手机竖屏放不下多选时那一长串（已选 N 首 / 全选 / 批量加标签 / 批量移除
          // 标签 / 移除记录…），早期实现是固定高度的 Row，超出的按钮直接被裁掉，
          // 「批量移除标签」的入口就是这样在手机上消失的。窄屏改成图标按钮 +
          // 提示气泡，动作区再套一层横向滚动兜底。
          final narrow = constraints.maxWidth < 560;
          final tight = constraints.maxWidth < 320;
          final side = tight ? 30.0 : 36.0;
          final iconStyle = IconButton.styleFrom(
            padding: EdgeInsets.zero,
            minimumSize: Size.square(side),
            maximumSize: Size.square(side),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            visualDensity: VisualDensity.compact,
          );
          Widget action({
            required Key key,
            required String tooltip,
            required IconData icon,
            required VoidCallback onPressed,
            required String label,
            Color? color,
          }) {
            if (!narrow) {
              return TextButton.icon(
                key: key,
                onPressed: onPressed,
                icon: Icon(icon, size: 15),
                label: Text(label, style: TextStyle(fontSize: 12, color: color)),
              );
            }
            return IconButton(
              key: key,
              tooltip: tooltip,
              icon: Icon(icon, size: tight ? 16 : 18, color: color),
              onPressed: onPressed,
              style: iconStyle,
            );
          }

          if (appState.selectionMode) {
            final count = appState.selectedTrackIds.length;
            final actions = <Widget>[
              // 退出多选写成带文字的按钮：原来只用一个勾选框图标加提示气泡，
              // 触屏上既看不出那是开关、也看不到气泡，退出路径不清楚。
              action(
                key: const ValueKey('track-toolbar-select'),
                tooltip: '退出多选',
                icon: Icons.close,
                onPressed: appState.clearTrackSelection,
                label: '退出多选',
              ),
              action(
                key: const ValueKey('track-select-all'),
                tooltip: '全选',
                icon: Icons.select_all,
                onPressed: appState.selectAllTracks,
                label: '全选',
              ),
              action(
                key: const ValueKey('track-batch-add-tags'),
                tooltip: '批量加标签',
                icon: Icons.sell_outlined,
                onPressed: () => _batchAddTags(context, appState),
                label: '批量加标签',
              ),
              action(
                key: const ValueKey('track-batch-remove-tags'),
                tooltip: '批量移除标签',
                icon: Icons.label_off_outlined,
                onPressed: () => _batchRemoveTags(context, appState),
                label: '批量移除标签',
              ),
              action(
                key: const ValueKey('track-remove-records'),
                tooltip: '移除记录',
                icon: Icons.playlist_remove,
                onPressed: () => _batchRemoveRecords(context, appState),
                label: '移除记录',
                color: AppColors.danger,
              ),
            ];
            // reverse 让动作贴右，跟宽屏上 Spacer 的观感一致；
            // 再窄也只是滚动，不会把入口裁掉。
            return Row(
              children: [
                Text(tight ? '$count 首' : '已选 $count 首',
                    style: TextStyle(
                        color: AppColors.textPrimaryOf(context), fontSize: 12)),
                const SizedBox(width: 4),
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    reverse: true,
                    child: Row(mainAxisSize: MainAxisSize.min, children: actions),
                  ),
                ),
              ],
            );
          }

          return Row(
            children: [
              if (narrow)
                IconButton(
                  key: const ValueKey('track-play-all'),
                  tooltip: isWorkLevel ? '播放全部' : '播放本文件夹',
                  icon: Icon(Icons.play_arrow,
                      size: 22,
                      color: appState.tracks.isEmpty ? null : AppColors.accent),
                  onPressed: appState.tracks.isEmpty
                      ? null
                      : () => appState.playAllCurrent(),
                  style: iconStyle,
                )
              else
                FilledButton.icon(
                  onPressed: appState.tracks.isEmpty
                      ? null
                      : () => appState.playAllCurrent(),
                  icon: const Icon(Icons.play_arrow, size: 16),
                  label: Text(isWorkLevel ? '播放全部' : '播放本文件夹'),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.accent,
                    foregroundColor: AppColors.backgroundOf(context),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                  ),
                ),
              if (isWorkLevel && appState.currentWork != null) ...[
                const SizedBox(width: 8),
                if (narrow)
                  IconButton(
                    key: const ValueKey('track-add-folder'),
                    // 导入进行中再点一次会开第二个导入，这里跟 tag_panel 保持一致都禁用。
                    onPressed: appState.importing
                        ? null
                        : () => _addFolderToWork(context, appState),
                    tooltip: '添加文件夹到本作品',
                    icon: const Icon(Icons.create_new_folder_outlined, size: 20),
                    style: iconStyle,
                  )
                else
                  OutlinedButton.icon(
                    // 导入进行中再点一次会开第二个导入，这里跟 tag_panel 保持一致都禁用。
                    onPressed: appState.importing
                        ? null
                        : () => _addFolderToWork(context, appState),
                    icon: const Icon(Icons.create_new_folder_outlined, size: 15),
                    label: const Text('添加文件夹到本作品'),
                  ),
              ],
              const Spacer(),
              Text('${appState.tracks.length} 首',
                  style: TextStyle(
                      color: AppColors.mutedLightOf(context), fontSize: 12)),
              const SizedBox(width: 4),
              IconButton(
                key: const ValueKey('track-toolbar-select'),
                tooltip: '多选',
                icon: const Icon(Icons.check_box_outline_blank, size: 18),
                onPressed: appState.enterTrackSelectionMode,
                style: iconStyle,
              ),
              const SizedBox(width: 4),
              _sortMenu(context, appState),
            ],
          );
        },
      ),
    );
  }

  Future<void> _addFolderToWork(BuildContext context, AppState appState) async {
    final work = appState.currentWork;
    if (work == null) return;
    if (!await ensureScanAccessOrPrompt(context)) return;
    final path = await pickDirectory(title: '选择要加入「${work.name}」的文件夹');
    if (path == null) return;
    await appState.importDirectoryIntoWork(path, work.id!);
    // 导入的调用方是按钮回调，没有错误边界：失败原因只能在这里弹出来。
    final err = appState.importError;
    if (err != null && context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('导入失败：$err')));
    }
  }

  Future<void> _batchAddTags(BuildContext context, AppState appState) async {
    final ids = appState.selectedTrackIds.toList();
    if (ids.isEmpty) return;
    final existing = await appState.getTagIdsOnTracks(ids);
    if (!context.mounted) return;
    final tags = await showTagPickerDialog(context,
        title: '为选中曲目添加标签', selectedTagIds: existing);
    if (tags == null) return;
    await appState.addTagsToTracks(ids, tags);
    appState.clearTrackSelection();
  }

  Future<void> _batchRemoveTags(BuildContext context, AppState appState) async {
    final ids = appState.selectedTrackIds.toList();
    if (ids.isEmpty) return;
    final existing = await appState.getTagIdsOnTracks(ids);
    if (!context.mounted) return;
    final tags = await showTagPickerDialog(context,
        title: '移除选中曲目的标签', filterTagIds: existing);
    if (tags == null) return;
    await appState.removeTagsFromTracks(ids, tags);
    appState.clearTrackSelection();
  }

  /// 从软件移除选中曲目的记录：只删库里的行，磁盘文件保持原样。
  Future<void> _batchRemoveRecords(
      BuildContext context, AppState appState) async {
    final ids = appState.selectedTrackIds.toList();
    if (ids.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('移除记录'),
        content: Text(
            '从软件里移除选中的 ${ids.length} 首？\n'
            '磁盘上的文件不会被删除，标签关联会一起解除。',
            style: TextStyle(
                color: AppColors.textSecondaryOf(ctx), fontSize: 13)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child:
                const Text('移除', style: TextStyle(color: AppColors.danger)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final deleted = await appState.deleteMediaByIds(ids);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已移除 $deleted 条记录，磁盘文件未改动')));
  }

  Widget _sortMenu(BuildContext context, AppState appState) {
    return PopupMenuButton<String>(
      tooltip: '排序',
      icon: Icon(Icons.sort, size: 18, color: AppColors.mutedLightOf(context)),
      onSelected: (v) {
        if (v == 'toggle') {
          appState.setSortDescending(!appState.sortDescending);
        } else {
          appState.setSortKey(v);
        }
      },
      itemBuilder: (_) => [
        CheckedPopupMenuItem(
          value: 'filename',
          checked: appState.sortKey == 'filename',
          child: const Text('按文件名', style: TextStyle(fontSize: 13)),
        ),
        CheckedPopupMenuItem(
          value: 'title',
          checked: appState.sortKey == 'title',
          child: const Text('按标题', style: TextStyle(fontSize: 13)),
        ),
        CheckedPopupMenuItem(
          value: 'duration',
          checked: appState.sortKey == 'duration',
          child: const Text('按时长', style: TextStyle(fontSize: 13)),
        ),
        CheckedPopupMenuItem(
          value: 'added_at',
          checked: appState.sortKey == 'added_at',
          child: const Text('按导入时间', style: TextStyle(fontSize: 13)),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: 'toggle',
          child: Text(
            appState.sortDescending ? '切换为升序' : '切换为降序',
            style: const TextStyle(fontSize: 13),
          ),
        ),
      ],
    );
  }

  Widget _content(BuildContext context, AppState appState) {
    final folders = appState.centerFolders;
    final tracks = appState.tracks;

    if (folders.isEmpty && tracks.isEmpty) {
      return Center(
        child: Text(
          appState.currentFolderId == null ? '该作品暂无内容' : '该文件夹为空',
          style: TextStyle(color: AppColors.mutedLightOf(context), fontSize: 13),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.only(bottom: 8),
      children: [
        for (final f in folders) _FolderTile(folder: f),
        if (folders.isNotEmpty && tracks.isNotEmpty)
          const Divider(height: 1),
        for (int i = 0; i < tracks.length; i++)
          _TrackTile(track: tracks[i], index: i),
      ],
    );
  }
}

class _FolderTile extends StatelessWidget {
  final VirtualFolder folder;
  const _FolderTile({required this.folder});

  @override
  Widget build(BuildContext context) {
    final appState = context.read<AppState>();
    return InkWell(
      onTap: () => appState.enterFolder(folder.id!),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            const Icon(Icons.folder, size: 20, color: AppColors.warning),
            const SizedBox(width: 10),
            Expanded(
              child: Text(folder.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: AppColors.textPrimaryOf(context),
                      fontSize: 14,
                      fontWeight: FontWeight.w500)),
            ),
            PopupMenuButton<String>(
              icon: Icon(Icons.more_vert, size: 16, color: AppColors.mutedOf(context)),
              onSelected: (v) => _onMenu(context, appState, v),
              itemBuilder: (_) => const [
                PopupMenuItem(
                  value: 'open',
                  child: Text('打开', style: TextStyle(fontSize: 13)),
                ),
                PopupMenuItem(
                  value: 'playAll',
                  child: Text('播放全部', style: TextStyle(fontSize: 13)),
                ),
                PopupMenuItem(
                  value: 'playExternal',
                  child: Text('用外部播放器播放', style: TextStyle(fontSize: 13)),
                ),
                PopupMenuItem(
                  value: 'rename',
                  child: Text('重命名', style: TextStyle(fontSize: 13)),
                ),
                PopupMenuItem(
                  value: 'move',
                  child: Text('移动到作品...', style: TextStyle(fontSize: 13)),
                ),
                PopupMenuItem(
                  value: 'tags',
                  child: Text('添加标签...', style: TextStyle(fontSize: 13)),
                ),
                PopupMenuItem(
                  value: 'untag',
                  child: Text('移除标签...', style: TextStyle(fontSize: 13)),
                ),
                PopupMenuDivider(),
                PopupMenuItem(
                    value: 'delete',
                    child: Text('删除', style: TextStyle(fontSize: 13, color: AppColors.danger))),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _onMenu(BuildContext context, AppState appState, String v) async {
    switch (v) {
      case 'open':
        await appState.enterFolder(folder.id!);
        break;
      case 'playAll':
        await appState.playFolderAll(folder.id!);
        break;
      case 'playExternal':
        final r = await appState.playFolderExternal(folder.id!);
        if (context.mounted) showLaunchResult(context, r);
        break;
      case 'rename':
        final name = await promptText(context,
            title: '重命名文件夹', initial: folder.name);
        if (name != null && name.isNotEmpty) {
          await appState.renameFolder(folder.id!, name);
        }
        break;
      case 'move':
        final target = await showWorkPicker(context);
        if (target == null) return;
        await appState.moveFolderToWork(
            folder.id!, target == kUnassignedWork ? null : target);
        break;
      case 'tags':
        final tags = await showTagPickerDialog(context, title: '为文件夹添加标签');
        if (tags == null || tags.isEmpty) return;
        if (!context.mounted) return;
        final recursive = await _confirmSync(context);
        if (recursive == null) return;
        await appState.addTagsToFolder(folder.id!, tags, recursive: recursive);
        break;
      case 'untag':
        final folderTags = await appState.getFolderTags(folder.id!);
        final ids = folderTags.map((t) => t.id).whereType<int>().toSet();
        if (!context.mounted) return;
        if (ids.isEmpty) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('该文件夹没有标签')));
          return;
        }
        final removed = await showTagPickerDialog(
          context,
          title: '移除文件夹标签',
          filterTagIds: ids,
        );
        if (removed == null || removed.isEmpty) return;
        if (!context.mounted) return;
        final recursiveRemove = await _confirmSync(context, removing: true);
        if (recursiveRemove == null) return;
        await appState.removeTagsFromFolder(
          folder.id!,
          removed,
          recursive: recursiveRemove,
        );
        break;
      case 'delete':
        final count = await appState.countMediaUnderFolder(folder.id!);
        if (!context.mounted) return;
        final ok = await confirmDialog(context,
            title: '删除文件夹「${folder.name}」？',
            content: '将从软件里移除这个文件夹、它的子文件夹，以及其中的 '
                '$count 条媒体记录（音频、图片、视频、字幕都算；'
                '别的文件夹仍覆盖到的记录保留）。\n'
                '磁盘文件不会被删除，之后可以重新导入。');
        if (ok == true) {
          await appState.deleteFolderDeep(folder.id!);
        }
        break;
    }
  }

  /// 询问是否递归同步到子文件夹曲目；null=取消, true=同步, false=仅当前文件夹
  Future<bool?> _confirmSync(BuildContext context, {bool removing = false}) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('同步操作'),
        content: Text(
          removing ? '是否把该标签从文件夹内所有曲目及子文件夹中一并移除？' : '是否把该标签同步到文件夹内所有曲目及子文件夹？',
          style: const TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(removing ? '仅移除文件夹标签' : '仅标记文件夹'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(removing ? '同步移除所有曲目' : '同步到所有曲目'),
          ),
        ],
      ),
    );
  }
}

class _TrackTile extends StatelessWidget {
  final TrackItem track;
  final int index;
  const _TrackTile({required this.track, required this.index});

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    // 用 select 只监听当前曲目/播放态，避免随进度 tick 全量重建列表
    final isCurrent = context.select<PlayerController, bool>(
        (p) => p.currentTrack?.path == track.path);
    final isPlaying =
        context.select<PlayerController, bool>((p) => p.playing);
    final isSelected = appState.isTrackSelected(track.id ?? -1);

    return InkWell(
      onTap: () {
        final id = track.id;
        if (id == null) {
          appState.playTrackAt(index);
          return;
        }
        // 多选模式下点击 = 切换选中
        if (appState.selectionMode) {
          appState.toggleTrackSelect(id);
          return;
        }
        final ctrl = HardwareKeyboard.instance.isControlPressed;
        final shift = HardwareKeyboard.instance.isShiftPressed;
        if (ctrl) {
          appState.toggleTrackSelect(id);
        } else if (shift) {
          appState.rangeTrackSelect(id);
        } else {
          appState.clearTrackSelection();
          appState.playTrackAt(index);
        }
      },
      onLongPress: () {
        // 长按进入多选模式（移动端），并选中该曲目
        final id = track.id;
        if (id == null) return;
        appState.enterSelectionMode(id);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        color: (isCurrent || isSelected)
            ? AppColors.surfaceOf(context)
            : null,
        child: Row(
          children: [
            SizedBox(
              width: 28,
              child: isSelected
                  ? const Icon(Icons.check_box, size: 16, color: AppColors.accent)
                  : isCurrent
                      ? (isPlaying
                          ? const Icon(Icons.graphic_eq, size: 16, color: AppColors.accent)
                          : const Icon(Icons.play_arrow, size: 16, color: AppColors.accent))
                      : Text('${index + 1}',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: AppColors.mutedOf(context), fontSize: 12)),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    track.displayTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: isCurrent ? AppColors.accent : AppColors.textPrimaryOf(context),
                      fontSize: 14,
                      fontWeight:
                          isCurrent ? FontWeight.w600 : FontWeight.normal,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    [track.artist, track.album, track.format?.toUpperCase()]
                        .where((e) => e != null && e.isNotEmpty)
                        .join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: AppColors.textSecondaryOf(context), fontSize: 12),
                  ),
                ],
              ),
            ),
            if (track.subtitlePath != null)
              const Padding(
                padding: EdgeInsets.only(right: 6),
                child: Icon(Icons.subtitles, size: 15, color: AppColors.teal),
              ),
            if (track.durationMs != null)
              Text(
                // 已播时间 / 总时长：没播过的显示 0:00，播过的能一眼看出听到哪里
                '${formatDuration(Duration(milliseconds: track.playPositionMs))}'
                ' / ${formatDuration(Duration(milliseconds: track.durationMs!))}',
                style: TextStyle(color: AppColors.mutedLightOf(context), fontSize: 12),
              ),
            PopupMenuButton<String>(
              icon: Icon(Icons.more_vert, size: 16, color: AppColors.mutedOf(context)),
              onSelected: (v) => _onMenu(context, appState, v),
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'play', child: Text('播放', style: TextStyle(fontSize: 13))),
                PopupMenuItem(value: 'subtitle', child: Text('替换字幕...', style: TextStyle(fontSize: 13))),
                PopupMenuItem(value: 'subtitle_assign', child: Text('字幕归属...', style: TextStyle(fontSize: 13))),
                PopupMenuItem(value: 'clear_subtitle', child: Text('清除字幕', style: TextStyle(fontSize: 13))),
                PopupMenuItem(value: 'tags', child: Text('添加标签...', style: TextStyle(fontSize: 13))),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _onMenu(BuildContext context, AppState appState, String v) async {
    switch (v) {
      case 'play':
        await appState.playTrackAt(index);
        break;
      case 'subtitle':
        if (track.id != null) {
          await showReplaceSubtitleDialog(context, track.id!);
        }
        break;
      case 'subtitle_assign':
        if (track.id != null) {
          await SubtitleAssignDialog.show(context,
              state: appState,
              audioId: track.id!,
              audioLabel: track.title ?? track.filename);
        }
        break;
      case 'clear_subtitle':
        if (track.id != null) {
          await appState.clearSubtitle(track.id!);
        }
        break;
      case 'tags':
        if (track.id == null) return;
        final existing = (await appState.getTrackTags(track.id!))
            .map((t) => t.id)
            .whereType<int>()
            .toSet();
        if (!context.mounted) return;
        final tags =
            await showTagPickerDialog(context, title: '为曲目添加标签', selectedTagIds: existing);
        if (tags == null) return;
        for (final t in tags) {
          await appState.toggleTagOnTrack(track.id!, t);
        }
        break;
    }
  }
}
