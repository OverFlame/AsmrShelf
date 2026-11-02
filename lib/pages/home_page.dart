import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/dlsite/series_index.dart';
import '../services/import_scanner.dart';
import '../services/settings_service.dart';
import '../services/thumbnail_cache.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/cover_image.dart';
import '../widgets/dialogs.dart' show confirmDialog, pickDirectory;
import '../widgets/dlsite_queue_chip.dart';
import '../widgets/filter_dialog.dart';
import '../widgets/folder_browser.dart';
import '../widgets/player_bar.dart';
import '../widgets/split_handle.dart';
import '../widgets/tag_panel.dart';
import '../widgets/tag_picker_dialog.dart';
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
  /// 左栏宽度的当前显示值。拖动时只改这个，松手才写进设置。
  final ValueNotifier<double> _leftWidth = ValueNotifier<double>(
    SettingsService.defaultLeftWidth,
  );
  AppState? _appState;
  bool _draggingLeft = false;

  @override
  void initState() {
    super.initState();
    _appState = context.read<AppState>();
    _leftWidth.value = _appState!.leftWidth;
    _appState!.addListener(_syncLeftWidth);
  }

  @override
  void dispose() {
    _appState?.removeListener(_syncLeftWidth);
    _leftWidth.dispose();
    super.dispose();
  }

  /// 设置页改了尺寸或点了重置时，把新值同步过来。拖动中不覆盖用户手上的值。
  void _syncLeftWidth() {
    if (_draggingLeft) return;
    final width = _appState?.leftWidth;
    if (width != null && width != _leftWidth.value) {
      _leftWidth.value = width;
    }
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final isWide = MediaQuery.of(context).size.width >= 720;

    return Stack(
      children: [
        Scaffold(
          appBar: AppBar(
            title: isWide
                ? const Text(
                    'AsmrShelf',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  )
                : _searchField(appState),
            actions: [
              if (isWide) SizedBox(width: 220, child: _searchField(appState)),
              IconButton(
                key: const ValueKey('home-import-works'),
                icon: const Icon(Icons.library_add_outlined),
                tooltip: '从目录导入作品',
                onPressed: () => _importWorks(context),
              ),
              IconButton(
                icon: const Icon(Icons.settings_outlined),
                tooltip: '设置',
                onPressed: () => Navigator.of(
                  context,
                ).push(MaterialPageRoute(builder: (_) => const SettingsPage())),
              ),
            ],
          ),
          drawer: isWide ? null : _buildDrawer(),
          body: isWide
              ? _buildWideBody(appState)
              : _buildCenter(appState, isWide),
          bottomNavigationBar: const PlayerBar(),
        ),
        if (appState.backfillingThumbs)
          Positioned(
            left: 12,
            bottom: MediaQuery.of(context).padding.bottom + 76,
            child: const ThumbBackfillChip(),
          ),
        if (appState.dlsite.scrapeRunning)
          Positioned(
            right: 12,
            bottom: MediaQuery.of(context).padding.bottom + 76,
            child: const DlsiteQueueChip(),
          ),
      ],
    );
  }

  /// 宽屏布局：左栏宽度可拖，中间内容吃掉剩余空间。
  Widget _buildWideBody(AppState appState) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // 中间至少留 MIN_CENTER_WIDTH 像素，左栏本身不小于最小宽度。
        final maxLeft = _maxLeftWidth(constraints.maxWidth);
        return ValueListenableBuilder<double>(
          valueListenable: _leftWidth,
          builder: (context, stored, center) {
            final width = stored.clamp(SettingsService.minLeftWidth, maxLeft);
            return Row(
              children: [
                SizedBox(
                  width: width,
                  child: Container(
                    color: AppColors.panelOf(context),
                    child: _buildLeftPanel(),
                  ),
                ),
                SplitHandle(
                  key: const ValueKey('split-left-panel'),
                  axis: Axis.horizontal,
                  onDragDelta: (delta) {
                    _draggingLeft = true;
                    _leftWidth.value = (_leftWidth.value + delta).clamp(
                      SettingsService.minLeftWidth,
                      maxLeft,
                    );
                  },
                  onDragEnd: () {
                    _draggingLeft = false;
                    appState.setLeftWidth(_leftWidth.value);
                  },
                  onReset: () {
                    _leftWidth.value = SettingsService.defaultLeftWidth;
                    appState.setLeftWidth(SettingsService.defaultLeftWidth);
                  },
                ),
                Expanded(child: center!),
              ],
            );
          },
          child: _buildCenter(appState, true),
        );
      },
    );
  }

  /// 左栏宽度的上限：不超过 420，也不让中间窄于 420。
  double _maxLeftWidth(double totalWidth) {
    const minCenterWidth = 420.0;
    final byWindow = totalWidth - minCenterWidth - 8;
    return math.max(
      SettingsService.minLeftWidth,
      math.min(SettingsService.maxLeftWidth, byWindow),
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
          builder: (drawerCtx) =>
              _buildLeftPanel(onNavigate: () => Navigator.of(drawerCtx).pop()),
        ),
      ),
    );
  }

  // ── 中间区域 ──
  Widget _buildCenter(AppState appState, bool isWide) {
    if (appState.loading) {
      return const Center(
        child: CircularProgressIndicator(color: AppColors.accent),
      );
    }
    if (appState.currentWork != null) return const FolderBrowser();
    final series = appState.currentSeries;
    return Column(
      children: [
        if (series != null) _SeriesBar(appState: appState, series: series),
        if (appState.workSelectionMode)
          _WorkSelectionToolbar(appState: appState)
        else
          const _VisualToolbar(),
        const Divider(height: 1),
        if (series == null &&
            !appState.workSelectionMode &&
            appState.recentTracks.isNotEmpty)
          _RecentBar(appState: appState),
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

  /// 选一个根目录，把里面每部作品一次导进来。
  ///
  /// 先扫描再让用户确认数量，避免选错目录直接往库里灌几百部作品。
  Future<void> _importWorks(BuildContext context) async {
    final appState = context.read<AppState>();
    final root = await pickDirectory(title: '选择作品根目录（每部作品一个子文件夹）');
    if (root == null || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);

    messenger.showSnackBar(
      const SnackBar(content: Text('正在扫描目录…'), duration: Duration(minutes: 1)),
    );
    ImportPlan plan;
    try {
      plan = await appState.scanWorksRoot(root);
    } catch (e) {
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(SnackBar(content: Text('扫描失败：$e')));
      return;
    }
    messenger.hideCurrentSnackBar();
    if (!context.mounted) return;

    if (plan.works.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(content: Text('这个目录下没有找到带音频的作品目录')),
      );
      return;
    }
    final tracks = plan.works.fold<int>(0, (n, w) => n + w.tracks.length);
    final ok = await confirmDialog(
      context,
      title: '导入 ${plan.works.length} 部作品？',
      content: '共 $tracks 首曲目。已经导入过的作品会跳过，不会重复建。',
      okLabel: '导入',
    );
    if (ok != true || !context.mounted) return;

    final outcome = await appState.importWorksFromRoot(root);
    if (!context.mounted) return;
    if (outcome == null) {
      messenger.showSnackBar(const SnackBar(content: Text('另一个导入任务正在进行，稍后再试')));
      return;
    }
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          '导入完成：作品 ${outcome.worksCreated} 新建 / '
          '${outcome.worksSkipped} 跳过，曲目 ${outcome.tracksInserted} 首',
        ),
      ),
    );
  }
}

/// 系列页顶部：返回全部作品 + 系列名 + 已导入/总数。
class _SeriesBar extends StatelessWidget {
  const _SeriesBar({required this.appState, required this.series});

  final AppState appState;
  final DlsiteSeries series;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 36,
      child: Row(
        children: [
          TextButton.icon(
            key: const ValueKey('series-back'),
            onPressed: () => appState.goUp(),
            icon: const Icon(Icons.arrow_back, size: 16),
            label: const Text('全部作品', style: TextStyle(fontSize: 12)),
          ),
          Text('/', style: TextStyle(color: AppColors.mutedOf(context))),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              series.name,
              key: const ValueKey('series-title'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: AppColors.textPrimaryOf(context),
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Text(
            series.badge,
            key: const ValueKey('series-count'),
            style: TextStyle(color: AppColors.mutedOf(context), fontSize: 12),
          ),
          const SizedBox(width: 12),
        ],
      ),
    );
  }
}

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
                      child: Text('$c 列', style: const TextStyle(fontSize: 13)),
                    ),
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
                tooltip: '多选作品',
                icon: Icons.check_box_outline_blank,
                onPressed: () {
                  // 这根工具条只在首页作品层出现：作品多选由此进入，曲目多选
                  // 在作品内的工具条上，两者不共用同一个入口。
                  appState.clearWorkSelection();
                  appState.enterWorkSelectionMode();
                },
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
                  icon: Icon(
                    Icons.label_outline,
                    size: 18,
                    color: appState.activeTagIds.isEmpty
                        ? null
                        : AppColors.accent,
                  ),
                  onPressed: () => _showTagFilter(context),
                ),
                IconButton(
                  key: ValueKey('audio-toolbar-advanced-filter'),
                  tooltip: '高级筛选',
                  icon: Icon(
                    Icons.filter_alt_outlined,
                    size: 18,
                    color: appState.hasAdvancedFilter ? AppColors.accent : null,
                  ),
                  onPressed: () => AdvancedFilterDialog.show(context),
                ),
              ],
              const Spacer(),
              if (!compact) ...[
                IconButton(
                  key: ValueKey('audio-toolbar-refresh'),
                  tooltip: '刷新（以磁盘为准）',
                  icon: const Icon(Icons.refresh, size: 18),
                  onPressed: () => _refreshFromDisk(context, appState),
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
                      child: const Text('刷新', style: TextStyle(fontSize: 13)),
                    ),
                    PopupMenuItem(
                      key: ValueKey('audio-toolbar-clear-thumbs'),
                      value: 'clearThumbs',
                      child: const Text(
                        '清理缩略图缓存',
                        style: TextStyle(fontSize: 13),
                      ),
                    ),
                    PopupMenuItem(
                      key: ValueKey('audio-toolbar-tags'),
                      value: 'tags',
                      child: const Text('标签筛选', style: TextStyle(fontSize: 13)),
                    ),
                    PopupMenuItem(
                      key: ValueKey('audio-toolbar-advanced-filter'),
                      value: 'advancedFilter',
                      child: const Text('高级筛选', style: TextStyle(fontSize: 13)),
                    ),
                    if (appState.currentFolderPath != null)
                      PopupMenuItem(
                        key: ValueKey('audio-toolbar-play-all'),
                        value: 'playAll',
                        child: const Text(
                          '播放本目录的音频',
                          style: TextStyle(fontSize: 13),
                        ),
                      ),
                    if (appState.currentWork != null)
                      PopupMenuItem(
                        key: ValueKey('audio-toolbar-add-folder'),
                        value: 'addFolder',
                        child: const Text(
                          '添加文件夹到本作品',
                          style: TextStyle(fontSize: 13),
                        ),
                      ),
                  ],
                ),
              const SizedBox(width: 4),
            ],
          );
        },
      ),
    );
  }

  /// 刷新按钮：先按磁盘补齐/清理，再重查列表。
  ///
  /// 只查库查不出用户新拷进来的文件，也删不掉已经删掉的文件，所以这里走
  /// `rescanFromDisk`；批量扫盘放在按钮回调里，不挂在每次界面刷新上。
  Future<void> _refreshFromDisk(BuildContext context, AppState appState) async {
    final messenger = ScaffoldMessenger.of(context);
    final outcome = await appState.rescanFromDisk();
    await appState.refresh();
    if (!context.mounted) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          outcome.changed
              ? '已按磁盘刷新：新增 ${outcome.added} 首，清理 ${outcome.removed} 首'
              : '没有发现新文件，也没有失联的曲目',
        ),
      ),
    );
  }

  void _onMore(BuildContext context, String action) {
    final appState = context.read<AppState>();
    switch (action) {
      case 'refresh':
        _refreshFromDisk(context, appState);
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
    final removed = await ThumbnailService.instance.evictDiskCache(
      maxSizeMB: 0,
    );
    ThumbnailService.instance.clearMemoryCache();
    // 自增 thumbEpoch，网格里的卡片据此丢弃旧缩略图并重建
    appState.markThumbnailsCleared();
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('已清理 $removed 个缩略图缓存文件')));
  }
}

/// 作品多选工具条：批量删除、刷新、打标签与抓取 DLsite。
///
/// 与 [_VisualToolbar] 互斥显示：进多选后原工具条让位，避免两排按钮抢空间。
class _WorkSelectionToolbar extends StatelessWidget {
  const _WorkSelectionToolbar({required this.appState});

  final AppState appState;

  @override
  Widget build(BuildContext context) {
    final count = appState.selectedWorkIds.length;
    final scopeCount = appState.visibleWorks.length;
    final selectedAll = scopeCount > 0 && count == scopeCount;
    return SizedBox(
      height: 48,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          children: [
            IconButton(
              key: const ValueKey('work-select-exit'),
              tooltip: '退出多选',
              icon: const Icon(Icons.close, size: 18),
              onPressed: appState.clearWorkSelection,
            ),
            Text(
              '已选 $count 部',
              style: TextStyle(
                fontSize: 13,
                color: AppColors.textSecondaryOf(context),
              ),
            ),
            const SizedBox(width: 8),
            TextButton(
              key: const ValueKey('work-select-all'),
              onPressed: () {
                if (selectedAll) {
                  appState.clearWorkSelection();
                  appState.enterWorkSelectionMode();
                } else {
                  appState.selectAllWorks();
                }
              },
              child: Text(
                selectedAll ? '取消全选' : '全选',
                style: const TextStyle(fontSize: 12),
              ),
            ),
            IconButton(
              key: const ValueKey('work-batch-dlsite'),
              tooltip: '批量抓取 DLsite 元数据',
              icon: const Icon(Icons.cloud_download_outlined, size: 18),
              onPressed: count == 0 ? null : () => _batchScrape(context),
            ),
            IconButton(
              key: const ValueKey('work-batch-refresh'),
              tooltip: '按磁盘刷新选中作品',
              icon: const Icon(Icons.refresh, size: 18),
              onPressed: count == 0 ? null : () => _batchRefresh(context),
            ),
            IconButton(
              key: const ValueKey('work-batch-tags'),
              tooltip: '批量添加标签',
              icon: const Icon(Icons.label_outline, size: 18),
              onPressed: count == 0
                  ? null
                  : () => _batchTags(context, add: true),
            ),
            IconButton(
              key: const ValueKey('work-batch-tags-remove'),
              tooltip: '批量移除标签',
              icon: const Icon(Icons.label_off_outlined, size: 18),
              onPressed: count == 0
                  ? null
                  : () => _batchTags(context, add: false),
            ),
            const SizedBox(width: 4),
            IconButton(
              key: const ValueKey('work-batch-delete'),
              tooltip: '删除选中作品',
              icon: const Icon(Icons.delete_outline, size: 18),
              color: AppColors.danger,
              onPressed: count == 0 ? null : () => _batchDelete(context),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _batchDelete(BuildContext context) async {
    final ids = List<int>.from(appState.selectedWorkIds);
    var media = 0;
    for (final id in ids) {
      media += await appState.countMediaUnderWork(id);
    }
    if (!context.mounted) return;
    final ok = await confirmDialog(
      context,
      title: '删除选中的 ${ids.length} 部作品？',
      content:
          '将从软件里移除这些作品、它们下面的文件夹，以及其中的 $media 条媒体记录。\n'
          '磁盘文件不会被删除，之后可以重新导入。',
    );
    if (ok != true || !context.mounted) return;
    await appState.deleteWorks(ids);
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('已删除 ${ids.length} 部作品')));
  }

  Future<void> _batchRefresh(BuildContext context) async {
    final ids = List<int>.from(appState.selectedWorkIds);
    final outcome = await appState.rescanWorks(ids);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          outcome.changed
              ? '刷新完成：新增 ${outcome.added} 首，清理 ${outcome.removed} 首'
              : '这 ${ids.length} 部作品没有变化',
        ),
      ),
    );
  }

  Future<void> _batchScrape(BuildContext context) async {
    final ids = List<int>.from(appState.selectedWorkIds);
    appState.enqueueDlsiteScrape(ids);
    appState.clearWorkSelection();
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已把 ${ids.length} 部作品排进 DLsite 抓取队列')),
    );
  }

  Future<void> _batchTags(BuildContext context, {required bool add}) async {
    final ids = List<int>.from(appState.selectedWorkIds);
    final mediaIds = <int>{};
    for (final workId in ids) {
      mediaIds.addAll(await appState.mediaIdsUnderWork(workId));
    }
    if (!context.mounted) return;
    if (mediaIds.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('选中的作品里还没有媒体，先导入再看标签')));
      return;
    }
    Set<int>? current;
    if (!add) {
      current = await appState.getTagIdsOnMedia(mediaIds);
      if (!context.mounted) return;
      if (current.isEmpty) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('选中的作品里的媒体还没有标签')));
        return;
      }
    }
    final tags = await showTagPickerDialog(
      context,
      title: add
          ? '为 ${ids.length} 部作品添加标签（${mediaIds.length} 条媒体）'
          : '移除选中作品的标签',
      filterTagIds: add ? null : current,
    );
    if (tags == null || tags.isEmpty) return;
    if (add) {
      await appState.addTagsToWorks(ids, tags);
    } else {
      await appState.removeTagsFromWorks(ids, tags);
    }
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '已${add ? '添加' : '移除'} ${tags.length} 个标签 → ${mediaIds.length} 条媒体',
        ),
      ),
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
      height: 128,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 8, 2),
            child: Row(
              children: [
                Text(
                  '最近播放',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimaryOf(context),
                  ),
                ),
                const Spacer(),
                TextButton.icon(
                  key: const ValueKey('continue-last-playback'),
                  onPressed: () => appState.playRecentTracks(0),
                  icon: const Icon(Icons.play_arrow, size: 16),
                  label: const Text('继续播放', style: TextStyle(fontSize: 12)),
                  style: TextButton.styleFrom(
                    foregroundColor: AppColors.accent,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: const Size(0, 28),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              itemCount: tracks.length,
              itemBuilder: (ctx, i) {
                final t = tracks[i];
                final duration = t.durationMs ?? 0;
                final progress = duration > 0
                    ? (t.playPositionMs / duration).clamp(0.0, 1.0).toDouble()
                    : 0.0;
                return InkWell(
                  onTap: () => appState.playRecentTracks(i),
                  child: SizedBox(
                    width: 100,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: Stack(
                              children: [
                                CoverImage(
                                  path: t.coverPath,
                                  width: 72,
                                  height: 72,
                                  borderRadius: 8,
                                ),
                                if (progress > 0)
                                  Positioned(
                                    left: 0,
                                    right: 0,
                                    bottom: 0,
                                    child: LinearProgressIndicator(
                                      value: progress,
                                      minHeight: 3,
                                      backgroundColor: Colors.black45,
                                      valueColor: const AlwaysStoppedAnimation(
                                        AppColors.accent,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            t.filename,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11,
                              color: AppColors.textSecondaryOf(context),
                            ),
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
