import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/thumbnail_cache.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/cover_image.dart';
import '../widgets/dialogs.dart' show confirmDialog, pickDirectory;
import '../widgets/filter_dialog.dart';
import '../widgets/folder_browser.dart';
import '../widgets/folder_panel.dart';
import '../widgets/image_detail.dart';
import '../widgets/image_grid.dart';
import '../widgets/image_viewer.dart';
import '../widgets/player_bar.dart';
import '../widgets/tag_panel.dart';
import '../widgets/thumb_backfill_chip.dart';
import '../widgets/tag_picker_dialog.dart';
import '../widgets/works_grid.dart';
import 'settings_page.dart';

/// 音频页的库名。多媒体库的常量在 `folder_panel.dart` 里（与 `works.library`
/// 和 `folders.library` 同一套取值），这里 import 过来复用。
const String kAudioLibrary = 'audio';

/// 主页面：顶部先选库（音频 / 多媒体），再渲染该库的面板。
/// - 宽屏（>=720）：左侧面板 + 中间内容（图片库还能展开右侧详情面板）
/// - 窄屏（手机）：抽屉（汉堡菜单）+ 中间内容
///
/// 音频库沿用合并前的布局与行为（作品网格 + 文件夹树 + 播放条）；
/// 多媒体库换成 `FolderPanel` + `ImageGrid` 这套资源管理器式界面，图片、视频、
/// 音频都在同一个网格里。
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  /// 当前库：`audio` / `media`
  String _library = kAudioLibrary;

  /// 图片库右侧详情面板是否展开（窄屏改成推一个页面）
  bool _detailOpen = false;

  /// 图片 / 视频库左栏当前显示「文件夹」还是「标签」
  final Map<String, String> _leftTabs = {};

  bool get _isVisual => _library != kAudioLibrary;

  Future<void> _switchLibrary(String lib) async {
    if (lib == _library) return;
    final appState = context.read<AppState>();
    setState(() => _library = lib);
    // 页签告诉状态层按哪一侧装填：多媒体栏里点进音频作品也要平铺所有类型。
    appState.setBrowsingLibrary(lib);
    // 换库必须丢掉上一个库的导航位置，否则中间区会拿着另一个库的 currentWork
    await appState.goHome();
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
            bottom: PreferredSize(
              preferredSize: const Size.fromHeight(40),
              child: _LibrarySwitcher(
                current: _library,
                onSelect: _switchLibrary,
              ),
            ),
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
        // 查看器是覆盖层：双击图片磁贴后由 ImageGrid -> AppState.openViewer 打开
        if (_isVisual && appState.showViewer) ImageViewer(state: appState),
      ],
    );
  }

  // ── 左栏：音频库是标签面板，图片/视频库是「文件夹 / 标签」两个页签 ──
  Widget _buildLeftPanel({VoidCallback? onNavigate}) {
    if (_library == kAudioLibrary) {
      return TagPanel(onNavigate: onNavigate);
    }
    final tab = _leftTabs[_library] ?? 'folders';
    return Column(
      children: [
        _leftPanelTabs(tab, onNavigate),
        const Divider(height: 1),
        Expanded(
          child: tab == 'tags'
              ? TagPanel(filterOnly: true, onNavigate: onNavigate)
              : FolderPanel(library: _library),
        ),
      ],
    );
  }

  /// 左栏页签：文件夹（树）/ 标签（筛选与打标签都在这里）。
  Widget _leftPanelTabs(String tab, VoidCallback? onNavigate) {
    Widget item(String id, String label, IconData icon) {
      final on = tab == id;
      return Expanded(
        child: InkWell(
          key: ValueKey('$_library-left-tab-$id'),
          onTap: () {
            setState(() => _leftTabs[_library] = id);
            onNavigate?.call();
          },
          child: Container(
            height: 34,
            color: on ? AppColors.surfaceOf(context) : null,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon,
                    size: 14,
                    color: on
                        ? AppColors.accent
                        : AppColors.mutedLightOf(context)),
                const SizedBox(width: 4),
                Text(label,
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: on ? FontWeight.w600 : FontWeight.w400,
                        color: on
                            ? AppColors.textPrimaryOf(context)
                            : AppColors.mutedLightOf(context))),
              ],
            ),
          ),
        ),
      );
    }

    return Row(
      children: [
        item('folders', '文件夹', Icons.folder_outlined),
        item('tags', '标签', Icons.sell_outlined),
      ],
    );
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

  // ── 中间区域：按库分派 ──
  Widget _buildCenter(AppState appState, bool isWide) {
    if (_library == kAudioLibrary) {
      if (appState.loading) {
        return const Center(
            child: CircularProgressIndicator(color: AppColors.accent));
      }
      if (appState.currentWork != null) return const FolderBrowser();
      return Column(
        children: [
          _VisualToolbar(
            library: _library,
            detailOpen: false,
            onToggleDetail: () {},
          ),
          const Divider(height: 1),
          if (appState.recentTracks.isNotEmpty) _RecentBar(appState: appState),
          const Expanded(child: WorksGrid(library: 'audio')),
        ],
      );
    }

    final centerColumn = Column(
      children: [
        _VisualToolbar(
          library: _library,
          detailOpen: _detailOpen,
          onToggleDetail: () => _openDetail(context, isWide),
        ),
        const Divider(height: 1),
        if (appState.breadcrumb.isNotEmpty) const _BreadcrumbBar(),
        if (appState.hasAdvancedFilter) const _AdvancedFilterBar(),
        if (appState.selectedIds.isNotEmpty)
          _SelectionBar(library: _library),
        Expanded(
          child: appState.currentWork == null
              ? WorksGrid(library: _library)
              : ImageGrid(library: _library),
        ),
      ],
    );

    if (_library == kAudioLibrary || !_detailOpen || !isWide) {
      return centerColumn;
    }
    return Row(
      children: [
        Expanded(child: centerColumn),
        const VerticalDivider(width: 1),
        SizedBox(
          width: 320,
          child: Container(
            color: AppColors.panelOf(context),
            child: const ImageDetail(),
          ),
        ),
      ],
    );
  }

  /// 详情入口：宽屏开右侧面板（可收），窄屏推一个独立页面
  void _openDetail(BuildContext context, bool isWide) {
    // 面板已经开着时这个按钮是「关闭」，不必管选中项。要打开时先兜底选中
    // 当前图/列表第一张：详情只画选中项，没有选中就是一片空白。
    final opening = !isWide || !_detailOpen;
    if (opening) {
      final appState = context.read<AppState>();
      if (!appState.ensureDetailSelection()) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('这个位置还没有图片，先导入或进入作品再看详情')));
        return;
      }
    }
    if (!isWide) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => Scaffold(
            appBar: AppBar(title: const Text('图片详情')),
            body: const ImageDetail(),
          ),
        ),
      );
      return;
    }
    setState(() => _detailOpen = !_detailOpen);
  }

  Widget _searchField(AppState appState) {
    final hint =
        _library == kAudioLibrary ? '搜索曲目...' : '搜索图片、视频或音频...';
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

/// 顶部库切换条：音频 / 图片 / 视频，当前库高亮 + 下划线
class _LibrarySwitcher extends StatelessWidget {
  final String current;
  final ValueChanged<String> onSelect;

  const _LibrarySwitcher({required this.current, required this.onSelect});

  static const List<({String id, String label, IconData icon})> _tabs = [
    (id: kAudioLibrary, label: '音频', icon: Icons.library_music_outlined),
    (id: kMediaLibrary, label: '多媒体', icon: Icons.photo_library_outlined),
  ];

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 40,
      child: Row(
        children: [
          for (final tab in _tabs)
            Expanded(
              child: InkWell(
                key: ValueKey('library-tab-${tab.id}'),
                onTap: () => onSelect(tab.id),
                child: Container(
                  decoration: BoxDecoration(
                    border: Border(
                      bottom: BorderSide(
                        color: current == tab.id
                            ? AppColors.accent
                            : Colors.transparent,
                        width: 2,
                      ),
                    ),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        tab.icon,
                        size: 16,
                        color: current == tab.id
                            ? AppColors.accent
                            : AppColors.mutedLightOf(context),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        tab.label,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: current == tab.id
                              ? FontWeight.w600
                              : FontWeight.normal,
                          color: current == tab.id
                              ? AppColors.accent
                              : AppColors.textSecondaryOf(context),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 图片/视频库的工具条：网格列数、视图模式、多选、标签筛选、高级筛选、
/// 刷新、清理缩略图缓存、图片详情开关。
///
/// 标签筛选入口图片库与视频库都有：标签查询按 `MediaType` 分型之后，
/// 视频同样能走 `media_tags`。
class _VisualToolbar extends StatelessWidget {
  final String library;
  final bool detailOpen;
  final VoidCallback onToggleDetail;

  const _VisualToolbar({
    required this.library,
    required this.detailOpen,
    required this.onToggleDetail,
  });

  bool get _isImage => library == kMediaLibrary;

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
                key: ValueKey('$library-toolbar-columns'),
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
                key: ValueKey('$library-toolbar-viewmode'),
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
                  key: ValueKey('$library-toolbar-sort'),
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
                key: ValueKey('$library-toolbar-select'),
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
                  key: ValueKey('$library-toolbar-play-all'),
                  tooltip: '播放本目录的音频',
                  icon: Icons.play_circle_outline,
                  onPressed: () => _playAllAudio(context),
                ),
              if (!compact && appState.currentWork != null)
                IconButton(
                  key: ValueKey('$library-toolbar-add-folder'),
                  tooltip: '添加文件夹到本作品',
                  icon: const Icon(Icons.create_new_folder_outlined, size: 18),
                  onPressed: () => _addFolderToWork(context),
                ),
              if (!compact) ...[
                IconButton(
                  key: ValueKey('$library-toolbar-tags'),
                  tooltip: '标签筛选',
                  icon: Icon(Icons.label_outline,
                      size: 18,
                      color: appState.activeTagIds.isEmpty
                          ? null
                          : AppColors.accent),
                  onPressed: () => _showTagFilter(context),
                ),
                IconButton(
                  key: ValueKey('$library-toolbar-advanced-filter'),
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
                  key: ValueKey('$library-toolbar-refresh'),
                  tooltip: '刷新',
                  icon: const Icon(Icons.refresh, size: 18),
                  onPressed: () => appState.refresh(),
                ),
                IconButton(
                  key: ValueKey('$library-toolbar-clear-thumbs'),
                  tooltip: '清理缩略图缓存',
                  icon: const Icon(Icons.cleaning_services_outlined, size: 18),
                  onPressed: () => _clearThumbCaches(context),
                ),
              ],
              if (_isImage && !compact)
                IconButton(
                  key: const ValueKey('image-toolbar-detail'),
                  tooltip: '图片详情',
                  icon: Icon(Icons.info_outline,
                      size: 18, color: detailOpen ? AppColors.accent : null),
                  onPressed: onToggleDetail,
                ),
              if (compact)
                PopupMenuButton<String>(
                  key: ValueKey('$library-toolbar-more'),
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
                        key: ValueKey('$library-toolbar-refresh'),
                        value: 'refresh',
                        child: const Text('刷新',
                            style: TextStyle(fontSize: 13))),
                    PopupMenuItem(
                        key: ValueKey('$library-toolbar-clear-thumbs'),
                        value: 'clearThumbs',
                        child: const Text('清理缩略图缓存',
                            style: TextStyle(fontSize: 13))),
                    PopupMenuItem(
                        key: ValueKey('$library-toolbar-tags'),
                        value: 'tags',
                        child: const Text('标签筛选',
                            style: TextStyle(fontSize: 13))),
                    PopupMenuItem(
                        key: ValueKey('$library-toolbar-advanced-filter'),
                        value: 'advancedFilter',
                        child: const Text('高级筛选',
                            style: TextStyle(fontSize: 13))),
                    if (appState.currentFolderPath != null)
                      PopupMenuItem(
                          key: ValueKey('$library-toolbar-play-all'),
                          value: 'playAll',
                          child: const Text('播放本目录的音频',
                              style: TextStyle(fontSize: 13))),
                    if (appState.currentWork != null)
                      PopupMenuItem(
                          key: ValueKey('$library-toolbar-add-folder'),
                          value: 'addFolder',
                          child: const Text('添加文件夹到本作品',
                              style: TextStyle(fontSize: 13))),
                    if (_isImage)
                      PopupMenuItem(
                          key: const ValueKey('image-toolbar-detail'),
                          value: 'detail',
                          child: Text(detailOpen ? '关闭图片详情' : '打开图片详情',
                              style: const TextStyle(fontSize: 13))),
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
      case 'detail':
        onToggleDetail();
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

/// 面包屑：回作品层 + 上一级 + 「全部图片/全部视频」+ 逐级文件夹
class _BreadcrumbBar extends StatelessWidget {
  const _BreadcrumbBar();

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final crumb = appState.breadcrumb;
    const rootLabel = '全部媒体';
    return SizedBox(
      height: 32,
      child: Row(
        children: [
          // 作品层（文件夹与作品的卡片列表）的一键入口：进入作品后这里也看得见，
          // 不用再靠「全部图片」返回（那条路以前只在文件夹层级里有效）。
          TextButton.icon(
            key: const ValueKey('breadcrumb-works'),
            onPressed: () => appState.goHome(),
            icon: const Icon(Icons.grid_view, size: 14),
            label: const Text('作品', style: TextStyle(fontSize: 12)),
          ),
          IconButton(
            icon: const Icon(Icons.arrow_upward, size: 16),
            tooltip: '上一级',
            onPressed: crumb.isEmpty ? null : () => appState.goUp(),
          ),
          Expanded(
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                TextButton(
                  key: const ValueKey('breadcrumb-root'),
                  onPressed: () => appState.goHome(),
                  child: Text(rootLabel, style: const TextStyle(fontSize: 12)),
                ),
                for (final f in crumb) ...[
                  Icon(Icons.chevron_right,
                      size: 14, color: AppColors.mutedLightOf(context)),
                  TextButton(
                    onPressed: f.id == null
                        ? null
                        : () {
                            // 面包屑首层是作品占位（id = -1），点它回作品层
                            if (f.id! < 0 && f.workId != null) {
                              appState.enterWork(f.workId!);
                            } else if (f.id! >= 0) {
                              appState.enterFolder(f.id!);
                            }
                          },
                    child: Text(f.name, style: const TextStyle(fontSize: 12)),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 高级筛选生效时的横条
class _AdvancedFilterBar extends StatelessWidget {
  const _AdvancedFilterBar();

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      color: AppColors.surfaceOf(context),
      child: Row(
        children: [
           Text('高级筛选',
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: AppColors.mutedLightOf(context))),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              appState.advancedFilter,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style:  TextStyle(
                  fontSize: 12,
                  fontFamily: 'monospace',
                  color: AppColors.textPrimaryOf(context)),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.edit_outlined, size: 16),
            tooltip: '编辑高级筛选',
            onPressed: () => AdvancedFilterDialog.show(context),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 16),
            tooltip: '清除高级筛选',
            onPressed: () => appState.clearAdvancedFilter(),
          ),
        ],
      ),
    );
  }
}

/// 多选生效时的横条：批量标签与批量移除记录
class _SelectionBar extends StatelessWidget {
  final String library;

  const _SelectionBar({required this.library});

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final ids = appState.selectedIds;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      color: AppColors.surfaceOf(context),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // 手机竖屏放不下 5 个带文字的按钮（连「已选 N 项」一起实测要 470 以上），
          // 窄屏改成图标按钮 + 提示气泡；键值保持不变，桌面端与测试照旧。
          final narrow = constraints.maxWidth < 520;
          // 再窄（宽版布局打开详情面板后中间列只有 218）连 5 个 36 见方图标都放不
          // 下，缩到 30 见方、标签只留数量，并给动作区套一层横向滚动兜底。
          final tight = constraints.maxWidth < 300;
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
                icon: Icon(icon, size: 16),
                label: Text(
                  label,
                  style: TextStyle(fontSize: 12, color: color),
                ),
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

          final actions = <Widget>[
            action(
              key: const ValueKey('selection-select-all'),
              tooltip: '全选',
              icon: Icons.select_all,
              onPressed: appState.selectAllImages,
              label: '全选',
            ),
            action(
              key: const ValueKey('selection-add-tags'),
              tooltip: '添加标签',
              icon: Icons.label_outline,
              onPressed: () => _addTags(context, appState, ids),
              label: '添加标签',
            ),
            action(
              key: const ValueKey('selection-remove-tags'),
              tooltip: '移除标签',
              icon: Icons.label_off_outlined,
              onPressed: () => _removeTags(context, appState, ids),
              label: '移除标签',
            ),
            action(
              key: const ValueKey('selection-delete'),
              tooltip: '移除记录',
              icon: Icons.playlist_remove,
              onPressed: () => _removeRecords(context, appState, ids),
              label: '移除记录',
              color: AppColors.danger,
            ),
            action(
              key: const ValueKey('selection-clear'),
              tooltip: '清除选择',
              icon: Icons.deselect,
              onPressed: appState.clearSelection,
              label: '清除选择',
            ),
          ];

          if (!narrow) {
            return Row(
              children: [
                Text(
                  '已选 ${ids.length} 项',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppColors.textPrimaryOf(context),
                  ),
                ),
                const Spacer(),
                ...actions,
              ],
            );
          }

          // 窄屏：数量标签 + 图标按钮，动作区可横向滚动，再窄也不会溢出。
          // reverse 让内容贴右，和宽屏 Spacer 的观感一致。
          return Row(
            children: [
              Text(
                tight ? '${ids.length} 项' : '已选 ${ids.length} 项',
                style: TextStyle(
                  fontSize: 12,
                  color: AppColors.textPrimaryOf(context),
                ),
              ),
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
        },
      ),
    );
  }

  /// 从软件移除选中记录：只删库里的行，磁盘文件保持原样。
  Future<void> _removeRecords(
      BuildContext context, AppState appState, Set<int> ids) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('移除记录'),
        content: Text(
            '从软件里移除选中的 ${ids.length} 项？\n'
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

  Future<void> _addTags(
      BuildContext context, AppState appState, Set<int> ids) async {
    final tags = await showTagPickerDialog(context, title: '批量添加标签');
    if (tags == null || tags.isEmpty) return;
    await appState.addTagsToMedia(ids, tags);
  }

  Future<void> _removeTags(
      BuildContext context, AppState appState, Set<int> ids) async {
    final current = await appState.getTagIdsOnMedia(ids);
    if (!context.mounted) return;
    final tags = await showTagPickerDialog(context,
        title: '批量移除标签', filterTagIds: current);
    if (tags == null || tags.isEmpty) return;
    await appState.removeTagsFromMedia(ids, tags);
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
