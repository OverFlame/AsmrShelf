import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../db/work_dao.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import '../utils/log_util.dart';
import 'cover_image.dart';
import 'dialogs.dart';
import 'launch_result_snack.dart';
import 'scan_access_snack.dart';
import 'tag_picker_dialog.dart';

/// 主页作品集网格。
///
/// [library] 为空与 `audio` 等价，都表示音频页。
/// 传 `media` 时列出多媒体作品与音频作品：音频只导一次，两个页签看到的是同一份
/// 数据，删一处另一处同步消失。
class WorksGrid extends StatelessWidget {
  final String? library;

  const WorksGrid({super.key, this.library});

  /// 空值与 audio 都按音频页处理（音频页显式传 audio）。
  String get _lib => library ?? 'audio';

  bool get _isAudio => _lib == 'audio';

  /// 本页签列出的作品归属。多媒体页把音频作品也列进来。
  Set<String> get _libs =>
      _isAudio ? const <String>{'audio'} : const <String>{'audio', 'media'};

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final works = appState.works.where((w) => _libs.contains(w.library)).toList();
    works.sort(appState.worksComparator);

    if (works.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
                _isAudio ? Icons.album_outlined : Icons.photo_library_outlined,
                size: 56,
                color: AppColors.mutedOf(context)),
            const SizedBox(height: 12),
            Text(
                '还没有作品',
                style: TextStyle(
                    color: AppColors.textSecondaryOf(context), fontSize: 14)),
            const SizedBox(height: 4),
            Text(
                _isAudio
                    ? '在左侧点击「添加文件夹」导入音频，自动生成作品'
                    : '点击下面的「添加文件夹」导入图片或视频，自动生成作品',
                style: TextStyle(color: AppColors.mutedOf(context), fontSize: 12)),
            // 音频页的导入入口在左栏，这里不再重复给按钮。
            if (!_isAudio) ...[
              const SizedBox(height: 20),
              OutlinedButton.icon(
                key: const ValueKey('works-empty-add-folder'),
                onPressed: () => _pickFolder(context),
                icon: const Icon(Icons.create_new_folder_outlined, size: 18),
                label: const Text('添加文件夹'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.accent,
                  side:  BorderSide(color: AppColors.surfaceAltOf(context)),
                ),
              ),
              const SizedBox(height: 8),
              TextButton.icon(
                key: const ValueKey('works-empty-batch-import'),
                onPressed: () => _pickBatchFolder(context),
                icon: const Icon(Icons.library_add_outlined, size: 16),
                label: const Text(
                  '批量导入：每个子文件夹一个作品',
                  style: TextStyle(fontSize: 12),
                ),
                style: TextButton.styleFrom(foregroundColor: AppColors.teal),
              ),
            ],
          ],
        ),
      );
    }

    if (appState.viewMode == 'list') {
      return ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: works.length,
        itemBuilder: (_, i) => Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: _WorkCard(
            key: ValueKey('work-card-${works[i].id}'),
            work: works[i],
            library: library,
            row: true,
          ),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final cols = appState.gridColumns.clamp(2, 10);
        // 高列数时缩小间距，窄屏 10 列也留得下标题和菜单。
        final spacing = cols >= 8 ? 8.0 : 16.0;
        final cellWidth =
            (constraints.maxWidth - 32 - spacing * (cols - 1)) / cols;
        // 宽卡片保持 0.82；窄到放不下标题时改为固定留出文字高度，避免溢出。
        final cellHeight =
            cellWidth < 120 ? cellWidth + 34 : cellWidth / 0.82;
        return GridView.builder(
          padding: const EdgeInsets.all(16),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: cols,
            mainAxisSpacing: spacing,
            crossAxisSpacing: spacing,
            childAspectRatio: cellWidth / cellHeight,
          ),
          itemCount: works.length,
          itemBuilder: (_, i) => _WorkCard(
            key: ValueKey('work-card-${works[i].id}'),
            work: works[i],
            library: library,
          ),
        );
      },
    );
  }

  /// 空态里的导入入口：选目录 -> 按本库落库（走 AppState 现成导入通道）
  Future<void> _pickFolder(BuildContext context) async {
    if (_isAudio) return;
    final lib = _lib;
    final appState = context.read<AppState>();
    if (!await ensureScanAccessOrPrompt(context)) return;
    final result = await pickDirectory(title: '选择包含图片或视频的文件夹');
    if (result != null && result.isNotEmpty && context.mounted) {
      await appState.importDirectory(result, library: lib);
    }
  }

  /// 批量导入：选父目录，里面的每个子文件夹各建一个作品。
  Future<void> _pickBatchFolder(BuildContext context) async {
    if (_isAudio) return;
    final lib = _lib;
    final appState = context.read<AppState>();
    if (!await ensureScanAccessOrPrompt(context)) return;
    final result = await pickDirectory(title: '选择父文件夹（每个子文件夹一个作品）');
    if (result == null || result.isEmpty || !context.mounted) return;
    final created = await appState.importSubdirectoriesAsWorks(
      result,
      library: lib,
    );
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          created > 0 ? '批量导入完成：新建 $created 个作品' : '没有发现可导入的子文件夹（或里面的媒体都已在库里）',
        ),
      ),
    );
  }
}

class _WorkCard extends StatelessWidget {
  final Work work;

  /// 所属库：null = 音频库（行为与改造前一致）。
  final String? library;

  /// 列表视图：封面、名称、菜单一行显示。
  final bool row;

  const _WorkCard({
    super.key,
    required this.work,
    this.library,
    this.row = false,
  });

  /// 「播放全部」只对音频有效（视频不做应用内解码）
  bool get _playAll => library == null || library == 'audio';

  /// 「用外部播放器播放」只在可能含视频的作品上给：外链只推视频。
  bool get _playExternal => library == null || library == 'audio' || work.library != 'audio';

  @override
  Widget build(BuildContext context) {
    final appState = context.read<AppState>();
    if (row) {
      return InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => appState.enterWork(work.id!),
        child: SizedBox(
          height: 64,
          child: Row(
            children: [
              CoverImage(
                path: work.coverPath,
                width: 56,
                height: 56,
                borderRadius: 8,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  work.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: AppColors.textPrimaryOf(context),
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              _menu(context, appState),
            ],
          ),
        ),
      );
    }
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () => appState.enterWork(work.id!),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                CoverImage(
                  path: work.coverPath,
                  width: double.infinity,
                  height: double.infinity,
                  borderRadius: 10,
                ),
                Positioned(
                  top: 4,
                  right: 4,
                  child: _menu(context, appState),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            work.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                color: AppColors.textPrimaryOf(context),
                fontSize: 14,
                fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }

  Widget _menu(BuildContext context, AppState appState) {
    return Material(
      color: Colors.black45,
      borderRadius: BorderRadius.circular(6),
      child: PopupMenuButton<String>(
        icon: const Icon(Icons.more_vert, size: 16, color: Colors.white),
        tooltip: '作品操作',
        onSelected: (v) => _onMenu(context, appState, v),
        itemBuilder: (_) => [
          if (_playAll)
            const PopupMenuItem(value: 'playAll', child: Text('播放全部', style: TextStyle(fontSize: 13))),
          if (_playExternal)
            const PopupMenuItem(
              value: 'playExternal',
              child: Text('用外部播放器播放', style: TextStyle(fontSize: 13)),
            ),
          const PopupMenuItem(
            value: 'rename',
            child: Text('重命名', style: TextStyle(fontSize: 13)),
          ),
          const PopupMenuItem(
            value: 'cover',
            child: Text('设置封面', style: TextStyle(fontSize: 13)),
          ),
          const PopupMenuItem(
            value: 'tags',
            child: Text('添加标签...', style: TextStyle(fontSize: 13)),
          ),
          const PopupMenuItem(
            value: 'untag',
            child: Text('移除标签...', style: TextStyle(fontSize: 13)),
          ),
          const PopupMenuDivider(),
          const PopupMenuItem(
              value: 'delete',
              child: Text('删除作品', style: TextStyle(fontSize: 13, color: AppColors.danger))),
        ],
      ),
    );
  }

  Future<void> _onMenu(
      BuildContext context, AppState appState, String v) async {
    switch (v) {
      case 'playAll':
        await appState.playWorkAll(work.id!);
        break;
      case 'playExternal':
        final r = await appState.playWorkExternal(work.id!);
        if (context.mounted) showLaunchResult(context, r);
        break;
      case 'rename':
        final name = await promptText(context,
            title: '重命名作品', initial: work.name);
        if (name != null && name.isNotEmpty) {
          await appState.renameWork(work.id!, name);
        }
        break;
      case 'cover':
        await showImportCoverDialog(context, work.id!);
        break;
      case 'tags':
        await _editWorkTags(context, appState, add: true);
        break;
      case 'untag':
        await _editWorkTags(context, appState, add: false);
        break;
      case 'delete':
        final count = await appState.countMediaUnderWork(work.id!);
        if (!context.mounted) return;
        final ok = await confirmDialog(context,
            title: '删除作品「${work.name}」？',
            content: '将从软件里移除这个作品、它下面的文件夹，以及其中的 '
                '$count 条媒体记录（音频、图片、视频、字幕都算）。\n'
                '磁盘文件不会被删除，之后可以重新导入。');
        if (ok == true) {
          await appState.deleteWorkDeep(work.id!);
        }
        break;
    }
  }

  /// 作品层标签增删：一次作用于这个作品下所有媒体（含子文件夹）。
  ///
  /// 作品层没有「只标作品」这个概念——标签本来就挂在媒体行上，所以这里直接
  /// 批量写全部媒体；先把已有标签收窄成可选集合，避免给没标签的东西移除。
  Future<void> _editWorkTags(
    BuildContext context,
    AppState appState, {
    required bool add,
  }) async {
    final ids = await appState.mediaIdsUnderWork(work.id!);
    if (!context.mounted) return;
    if (ids.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('这个作品里还没有媒体，先导入再看标签')));
      return;
    }
    Set<int>? current;
    if (!add) {
      current = await appState.getTagIdsOnMedia(ids);
      if (!context.mounted) return;
      if (current.isEmpty) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('这个作品里的媒体还没有标签')));
        return;
      }
    }
    final tags = await showTagPickerDialog(
      context,
      title: add ? '为作品添加标签（${ids.length} 条媒体）' : '移除作品标签',
      filterTagIds: add ? null : current,
    );
    if (tags == null || tags.isEmpty) return;
    if (add) {
      await appState.addTagsToMedia(ids, tags);
    } else {
      await appState.removeTagsFromMedia(ids, tags);
    }
    logInfo(
      'WorksGrid',
      '${add ? '添加' : '移除'}作品标签 ${tags.length} 个 → ${ids.length} 条媒体',
    );
  }
}
