import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/thumbnail_cache.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/cover_image.dart';
import '../widgets/dialogs.dart' show confirmDialog, pickDirectory;
import '../widgets/filter_dialog.dart';
import '../widgets/folder_browser.dart';
import '../widgets/player_bar.dart';
import '../widgets/tag_panel.dart';
import '../widgets/thumb_backfill_chip.dart';
import '../widgets/works_grid.dart';
import 'settings_page.dart';

/// 音频页的库名。多媒体库的常量在 `folder_panel.dart` 里（与 `works.library`
/// 和 `folders.library` 同一套取值），这里 import 过来复用。
const String kAudioLibrary = 'audio';

/// 主页面：音频库单栏布局。
/// - 宽屏（>=720）：左侧标签面板 + 中间内容
/// - 窄屏（手机）：抽屉（汉堡菜单）+ 中间内容
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final isWide = MediaQuery.of(context).size.width >= 720;

    return Stack(
      children: [
        Scaffold(
          appBar: AppBar(
            title: isWide
                ? const Text('AsmrShelf',
                    style: TextStyle(fontWeight: FontWeight.bold))
                : _searchField(appState),
            actions: [
              if (isWide)
                SizedBox(width: 220, child: _searchField(appState)),
              IconButton(
                icon: const Icon(Icons.settings_outlined),
                tooltip: '设置',
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const SettingsPage()),
                ),
              ),
            ],
          ),
          drawer: isWide ? null : _buildDrawer(),
          body: isWide
              ? Row(
                  children: [
                    Container(
                      width: 260,
                      color: AppColors.panelOf(context),
                      child: _buildLeftPanel(),
                    ),
                    const VerticalDivider(width: 1),
                    Expanded(child: _buildCenter(appState, isWide)),
                  ],
                )
              : _buildCenter(appState, isWide),
          bottomNavigationBar: const PlayerBar(),
        ),
        if (appState.backfillingThumbs)
          Positioned(
            left: 12,
            bottom: MediaQuery.of(context).padding.bottom + 76,
            child: const ThumbBackfillChip(),
          ),
      ],
    );
  }

  // ── 左栏：标签面板 ──
  Widget _buildLeftPanel({VoidCallback? onNavigate}) {
    return TagPanel(onNavigate: onNavigate);
  }

  Widget _buildDrawer() {
    return Drawer(
      width: 290,
      child: SafeArea(
        child: Builder(
          builder: (drawerCtx) => _buildLeftPanel(
              onNavigate: () => Navigator.of(drawerCtx).pop()),
        ),
      ),
    );
  }

  // ── 中间区域 ──
  Widget _buildCenter(AppState appState, bool isWide) {
    if (appState.loading) {
      return const Center(
          child: CircularProgressIndicator(color: AppColors.accent));
    }
    if (appState.currentWork != null) return const FolderBrowser();
    return Column(
      children: [
        const _VisualToolbar(),
        const Divider(height: 1),
        if (appState.recentTracks.isNotEmpty) _RecentBar(appState: appState),
        const Expanded(child: WorksGrid(library: 'audio')),
      ],
    );
  }

  Widget _searchField(AppState appState) {
    const hint = '搜索曲目...';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: TextField(
        decoration: InputDecoration(
          hintText: hint,
          isDense: true,
          prefixIcon: const Icon(Icons.search, size: 18),
          contentPadding: const EdgeInsets.symmetric(vertical: 8),
        ),
        style: const TextStyle(fontSize: 13),
        onChanged: appState.setSearchQuery,
      ),
    );
  }
}

/// 音频库工具条：网格列数、视图模式、多选、排序、标签筛选、高级筛选、
/// 播放本目录、添加文件夹、刷新与清理缩略图缓存。
class _VisualToolbar extends StatelessWidget {
  const _VisualToolbar();

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    // 作品层只排作品：作品没有文件大小与修改时间，菜单只给名称与加入时间。
    // 文件层仍用完整四档。
    final worksLayer = appState.currentWork == null;
    final sortLabels = worksLayer
        ? AppState.worksSortLabels
        : AppState.visualSortLabels;
    final sortKey = worksLayer ? appState.worksSortKey : appState.visualSortKey;
    final sortDesc = worksLayer
        ? appState.worksSortDescending
        : appState.visualSortDescending;
    void setSort(String key) {
      if (worksLayer) {
        appState.setWorksSortKey(key);
      } else {
        appState.setVisualSortKey(key);
      }
    }

    void toggleSort() {
      if (worksLayer) {
        appState.setWorksSortDescending(!appState.worksSortDescending);
      } else {
        appState.setVisualSortDescending(!appState.visualSortDescending);
      }
    }

    return SizedBox(
      height: 44,
      child: LayoutBuilder(
        builder: (context, constraints) {
          // 中间区被左栏和详情面板挤窄时，尾部按钮收进「更多」菜单，
          // 否则 Row 会 RenderFlex overflow（800 宽窗口 + 详情面板时只剩约 220）。
          // 500 = 原先的 430 加上排序按钮的宽度再留点余量：非紧凑态实测要约 477。
          final compact = constraints.maxWidth < 500;
          // 720~830 是「宽版布局 + 详情面板」同时成立的最窄区段：中间列只有
          // 720 - 260 - 1 - 320 - 1 = 138，连排序按钮都放不下，于是排序也收进
          // 「更多」，并把图标按钮压到 30 见方（4 个按钮约 128）。
          final tiny = constraints.maxWidth < 220;
          final side = tiny ? 30.0 : (compact ? 36.0 : 40.0);
          final sideStyle = IconButton.styleFrom(
            padding: EdgeInsets.zero,
            minimumSize: Size.square(side),
            maximumSize: Size.square(side),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            visualDensity: VisualDensity.compact,
          );
          IconButton iconButton({
            required Key key,
            required String tooltip,
            required IconData icon,
            Color? color,
            required VoidCallback onPressed,
          }) => IconButton(
            key: key,
            tooltip: tooltip,
            icon: Icon(icon, size: tiny ? 16 : 18, color: color),
            onPressed: onPressed,
            style: sideStyle,
          );
          return Row(
            children: [
              const SizedBox(width: 4),
              PopupMenuButton<int>(
                key: ValueKey('audio-toolbar-columns'),
                tooltip: '网格列数',
                icon: Icon(Icons.grid_on_outlined, size: tiny ? 16 : 18),
                padding: EdgeInsets.zero,
                style: sideStyle,
                onSelected: (v) => appState.setGridColumns(v),
                itemBuilder: (_) => [
                  for (var c = 2; c <= 10; c++)
                    PopupMenuItem(
                        value: c,
                        child:
                            Text('$c 列', style: const TextStyle(fontSize: 13))),
                ],
              ),
              if (!compact)
                Text(
                  '${appState.gridColumns} 列',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppColors.mutedLightOf(context),
                  ),
                ),
              iconButton(
                key: ValueKey('audio-toolbar-viewmode'),
                tooltip: appState.viewMode == 'grid' ? '切换为列表视图' : '切换为网格视图',
                icon: appState.viewMode == 'grid'
                    ? Icons.view_list_outlined
                    : Icons.grid_view,
                onPressed: () => appState.setViewMode(
                  appState.viewMode == 'grid' ? 'list' : 'grid',
                ),
              ),
              if (!tiny)
                PopupMenuButton<String>(
                  key: ValueKey('audio-toolbar-sort'),
                  tooltip: '排序',
                  icon: Icon(Icons.sort, size: tiny ? 16 : 18),
                  padding: EdgeInsets.zero,
                  style: sideStyle,
                  onSelected: (v) {
                    if (v == 'toggle') {
                      toggleSort();
                    } else {
                      setSort(v);
                    }
                  },
                  itemBuilder: (_) => [
                    for (final entry in sortLabels.entries)
                      CheckedPopupMenuItem(
                        value: entry.key,
                        checked: sortKey == entry.key,
                        child: Text(
                          entry.value,
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                    const PopupMenuDivider(),
                    PopupMenuItem(
                      value: 'toggle',
                      child: Text(
                        sortDesc ? '改为升序' : '改为降序',
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                  ],
                ),
              iconButton(
                key: ValueKey('audio-toolbar-select'),
                tooltip: appState.visualSelectionMode ? '退出多选' : '多选',
                icon: appState.visualSelectionMode
                    ? Icons.check_box
                    : Icons.check_box_outline_blank,
                color: appState.visualSelectionMode ? AppColors.accent : null,
                onPressed: () => appState.visualSelectionMode
                    ? appState.exitVisualSelectionMode()
                    : appState.enterVisualSelectionMode(),
              ),
              // 音频侧独有的两个动作并进这里：本目录音频成队播放，以及往当前作品
              // 再补一个文件夹（图片、视频、音频都收）。
              if (appState.currentFolderPath != null)
                iconButton(
                  key: ValueKey('audio-toolbar-play-all'),
                  tooltip: '播放本目录的音频',
                  icon: Icons.play_circle_outline,
                  onPressed: () => _playAllAudio(context),
                ),
              if (!compact && appState.currentWork != null)
                IconButton(
                  key: ValueKey('audio-toolbar-add-folder'),
                  tooltip: '添加文件夹到本作品',
                  icon: const Icon(Icons.create_new_folder_outlined, size: 18),
                  onPressed: () => _addFolderToWork(context),
                ),
              if (!compact) ...[
                IconButton(
                  key: ValueKey('audio-toolbar-tags'),
                  tooltip: '标签筛选',
                  icon: Icon(Icons.label_outline,
                      size: 18,
                      color: appState.activeTagIds.isEmpty
                          ? null
                          : AppColors.accent),
                  onPressed: () => _showTagFilter(context),
                ),
                IconButton(
                  key: ValueKey('audio-toolbar-advanced-filter'),
                  tooltip: '高级筛选',
                  icon: Icon(Icons.filter_alt_outlined,
                      size: 18,
                      color:
                          appState.hasAdvancedFilter ? AppColors.accent : null),
                  onPressed: () => AdvancedFilterDialog.show(context),
                ),
              ],
              const Spacer(),
              if (!compact) ...[
                IconButton(
                  key: ValueKey('audio-toolbar-refresh'),
                  tooltip: '刷新',
                  icon: const Icon(Icons.refresh, size: 18),
                  onPressed: () => appState.refresh(),
                ),
                IconButton(
                  key: ValueKey('audio-toolbar-clear-thumbs'),
                  tooltip: '清理缩略图缓存',
                  icon: const Icon(Icons.cleaning_services_outlined, size: 18),
                  onPressed: () => _clearThumbCaches(context),
                ),
              ],
              if (compact)
                PopupMenuButton<String>(
                  key: ValueKey('audio-toolbar-more'),
                  tooltip: '更多操作',
                  icon: Icon(Icons.more_horiz, size: tiny ? 16 : 18),
                  padding: EdgeInsets.zero,
                  style: sideStyle,
                  onSelected: (v) => _onMore(context, v),
                  itemBuilder: (_) => [
                    // 极窄（宽版布局 + 详情面板）时排序按钮也放不下，挪进这里
                    if (tiny) ...[
                      PopupMenuItem(
                        enabled: false,
                        child: Text(
                          '排序',
                          style: TextStyle(
                            fontSize: 11,
                            color: AppColors.mutedLightOf(context),
                          ),
                        ),
                      ),
                      for (final entry in sortLabels.entries)
                        CheckedPopupMenuItem(
                          value: 'sort:${entry.key}',
                          checked: sortKey == entry.key,
                          child: Text(
                            entry.value,
                            style: const TextStyle(fontSize: 13),
                          ),
                        ),
                      PopupMenuItem(
                        value: 'sortDir',
                        child: Text(
                          sortDesc ? '改为升序' : '改为降序',
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                      const PopupMenuDivider(),
                    ],
                    PopupMenuItem(
                        key: ValueKey('audio-toolbar-refresh'),
                        value: 'refresh',
                        child: const Text('刷新',
                            style: TextStyle(fontSize: 13))),
                    PopupMenuItem(
                        key: ValueKey('audio-toolbar-clear-thumbs'),
                        value: 'clearThumbs',
                        child: const Text('清理缩略图缓存',
                            style: TextStyle(fontSize: 13))),
                    PopupMenuItem(
                        key: ValueKey('audio-toolbar-tags'),
                        value: 'tags',
                        child: const Text('标签筛选',
                            style: TextStyle(fontSize: 13))),
                    PopupMenuItem(
                        key: ValueKey('audio-toolbar-advanced-filter'),
                        value: 'advancedFilter',
                        child: const Text('高级筛选',
                            style: TextStyle(fontSize: 13))),
                    if (appState.currentFolderPath != null)
                      PopupMenuItem(
                          key: ValueKey('audio-toolbar-play-all'),
                          value: 'playAll',
                          child: const Text('播放本目录的音频',
                              style: TextStyle(fontSize: 13))),
                    if (appState.currentWork != null)
                      PopupMenuItem(
                          key: ValueKey('audio-toolbar-add-folder'),
                          value: 'addFolder',
                          child: const Text('添加文件夹到本作品',
                              style: TextStyle(fontSize: 13))),
                  ],
                ),
              const SizedBox(width: 4),
            ],
          );
        },
      ),
    );
  }

  void _onMore(BuildContext context, String action) {
    final appState = context.read<AppState>();
    switch (action) {
      case 'refresh':
        appState.refresh();
        break;
      case 'clearThumbs':
        _clearThumbCaches(context);
        break;
      case 'tags':
        _showTagFilter(context);
        break;
      case 'advancedFilter':
        AdvancedFilterDialog.show(context);
        break;
      case 'sortDir':
        if (appState.currentWork == null) {
          appState.setWorksSortDescending(!appState.worksSortDescending);
        } else {
          appState.setVisualSortDescending(!appState.visualSortDescending);
        }
        break;
      case 'playAll':
        _playAllAudio(context);
        break;
      case 'addFolder':
        _addFolderToWork(context);
        break;
      default:
        // 极窄时排序项挂在「更多」里，值形如 sort:name
        if (action.startsWith('sort:')) {
          final key = action.substring(5);
          if (appState.currentWork == null) {
            appState.setWorksSortKey(key);
          } else {
            appState.setVisualSortKey(key);
          }
        }
    }
  }

  /// 播放本目录下的音频（专辑式队列）。目录里没有音频时 `playAudioInDir` 自己
  /// 就是个空操作，不弹提示。
  Future<void> _playAllAudio(BuildContext context) async {
    final appState = context.read<AppState>();
    final dir = appState.currentFolderPath;
    if (dir == null) return;
    await appState.playAudioInDir(dir);
  }

  /// 把磁盘上的一个文件夹补进当前作品：图片、视频、音频一次都收。
  Future<void> _addFolderToWork(BuildContext context) async {
    final appState = context.read<AppState>();
    final workId = appState.currentWork?.id;
    if (workId == null) return;
    final dir = await pickDirectory(title: '选择要加入本作品的文件夹');
    if (dir == null) return;
    await appState.importDirectoryIntoWork(dir, workId);
  }

  void _showTagFilter(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (_) => const Dialog(
        child: SizedBox(
          width: 320,
          height: 480,
          child: TagPanel(filterOnly: true),
        ),
      ),
    );
  }

  Future<void> _clearThumbCaches(BuildContext context) async {
    final appState = context.read<AppState>();
    final ok = await confirmDialog(
      context,
      title: '清理缩略图缓存？',
      content: '删除本机已生成的缩略图文件，之后浏览会重新生成。',
    );
    if (ok != true) return;
    final removed = await ThumbnailService.instance.evictDiskCache(maxSizeMB: 0);
    ThumbnailService.instance.clearMemoryCache();
    // 自增 thumbEpoch，网格里的卡片据此丢弃旧缩略图并重建
    appState.markThumbnailsCleared();
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已清理 $removed 个缩略图缓存文件')),
    );
  }
}

/// 最近播放横条
class _RecentBar extends StatelessWidget {
  final AppState appState;
  const _RecentBar({required this.appState});

  @override
  Widget build(BuildContext context) {
    final tracks = appState.recentTracks;
    return SizedBox(
      height: 122,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
            child: Text('最近播放',
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimaryOf(context))),
          ),
          Expanded(
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              itemCount: tracks.length,
              itemBuilder: (ctx, i) {
                final t = tracks[i];
                return InkWell(
                  onTap: () => appState.playRecentTracks(i),
                  child: SizedBox(
                    width: 100,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          CoverImage(
                              path: t.coverPath,
                              width: 72,
                              height: 72,
                              borderRadius: 8),
                          const SizedBox(height: 4),
                          Text(
                            t.filename,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 11,
                                color: AppColors.textSecondaryOf(context)),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
