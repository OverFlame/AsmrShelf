import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../db/folder_dao.dart';
import '../db/media_dao.dart';
import '../db/tag_dao.dart';
import '../db/track_dao.dart';
import '../db/work_dao.dart';
import '../services/media_rules.dart';
import '../services/dlsite/series_index.dart';
import '../utils/log_util.dart';
import 'tag_filter.dart';

/// 作品库状态：作品集、文件夹导航、中间栏内容、搜索与曲目多选。
///
/// 拆分自 `AppState`。这里只管「库里有什麼、现在停在哪一层」；
/// 排序口径、标签筛选命中、封面与元数据由调用方注入或读别的状态对象，
/// 所以本文件不 import 其它状态对象。
class LibraryState extends ChangeNotifier {
  LibraryState({
    required this.trackDao,
    required this.workDao,
    required this.folderDao,
    required this.mediaDao,
    required this.tagDao,
    required this.hasAdvancedFilter,
    required this.tagFilter,
    required this.matchingIds,
    required this.filterFolders,
    required this.sortTracks,
    this.onBeforeRefresh,
  });

  final TrackDao Function() trackDao;
  final WorkDao Function() workDao;
  final FolderDao Function() folderDao;
  final MediaDao Function() mediaDao;
  final TagDao Function() tagDao;

  /// 是否用着高级筛选表达式。
  final bool Function() hasAdvancedFilter;

  /// 标签筛选的三个集合。
  final TagFilter Function() tagFilter;

  /// 当前筛选命中的媒体 id，由标签层算。
  final Future<Set<int>> Function(MediaType? type) matchingIds;

  /// 文件夹层的筛选，由标签层算（要读 folder_tags）。
  final Future<List<VirtualFolder>> Function(
      List<VirtualFolder> folders, Set<int> ids) filterFolders;

  /// 曲目排序口径（读设置）。
  final List<TrackItem> Function(List<TrackItem> tracks) sortTracks;

  /// 每次刷新前清掉派生缓存（字幕缓存等）。
  final void Function()? onBeforeRefresh;

  // ── 作品集 ──
  List<Work> works = const [];
  List<VirtualFolder> unassignedFolders = const [];
  Work? currentWork;

  /// 当前停靠的系列（「大作品」）；与 [currentWork] 互斥。
  DlsiteSeries? currentSeries;

  // ── 文件夹导航 ──
  int? currentFolderId;
  VirtualFolder? currentFolder;
  String? currentFolderPath;
  List<VirtualFolder> breadcrumb = const [];
  int folderVersion = 0;

  // ── 中间栏内容 ──
  List<VirtualFolder> centerFolders = const [];
  List<TrackItem> tracks = const [];
  bool loading = false;

  // ── 搜索 ──
  String searchQuery = '';

  // ── 曲目多选 ──
  final Set<int> selectedTrackIds = {};
  bool selectionMode = false;
  int? anchorTrackId;

  // ── 作品多选 ──
  /// 作品层批量操作（删除、刷新、抓取、打标签）的选中集合。
  final Set<int> selectedWorkIds = {};
  bool workSelectionMode = false;

  /// 每次 refresh 递增。用于丢弃「先发起但后完成」的旧结果。
  int _refreshGeneration = 0;

  Future<void> refresh() async {
    final gen = ++_refreshGeneration;
    logInfo('LibraryState', 'refresh() gen=$gen');
    onBeforeRefresh?.call();
    final allWorks = await workDao().listAll();
    final unassigned = await folderDao().listUnassignedRoots();
    if (gen != _refreshGeneration) {
      logInfo('LibraryState', 'refresh() gen=$gen 已被新一代取代，丢弃结果');
      return;
    }
    works = allWorks;
    unassignedFolders = unassigned;
    // 作品选中集合只保留库里还在的：别处删掉的作品不能继续参与批量操作。
    final liveIds = allWorks.map((w) => w.id).whereType<int>().toSet();
    selectedWorkIds.retainAll(liveIds);
    notifyListeners();
    await _loadCenter(gen);
  }

  /// 加载中间栏。[gen] 是发起时的 [refresh] 代际。
  Future<void> _loadCenter(int gen) async {
    loading = true;
    notifyListeners();
    try {
      final search = searchQuery.trim();
      final filterActive = hasAdvancedFilter() || tagFilter().active;

      List<VirtualFolder> folders;
      List<TrackItem> tracks;

      if (search.isNotEmpty) {
        folders = const [];
        var list = await trackDao().searchByName(search);
        if (filterActive) {
          final ids = await matchingIds(MediaType.audio);
          list = list.where((t) => ids.contains(t.id)).toList();
        }
        tracks = list;
      } else {
        final work = currentWork;
        if (work != null && currentFolderId != null) {
          folders = await folderDao().listChildren(currentFolderId!);
          final path = currentFolderPath;
          tracks = path == null
              ? <TrackItem>[]
              : await trackDao().queryDirectInDir(path);
        } else if (work != null) {
          // 作品层保留入口文件夹，它是进入专辑/歌单的入口。
          folders = await folderDao().listRootsByWork(work.id!);
          tracks = const [];
        } else {
          folders = const [];
          tracks = const [];
        }

        if (filterActive) {
          final ids = await matchingIds(MediaType.audio);
          tracks = tracks.where((t) => ids.contains(t.id)).toList();
          folders = await filterFolders(folders, ids);
        }
      }

      // 等待期间又有新的 refresh 发起，本次结果作废，不覆盖更新的状态。
      if (gen != _refreshGeneration) {
        logInfo('LibraryState', 'Center load gen=$gen 已被取代，丢弃结果');
        return;
      }
      centerFolders = _sortFolders(folders);
      this.tracks = sortTracks(tracks);
      // 选中集合只保留当前可见的条目。切到别的作品或文件夹之后，
      // 「批量打标签」「移动」不会落到看不见的条目上。
      final visibleTrackIds =
          this.tracks.map((t) => t.id).whereType<int>().toSet();
      final selectedBefore = selectedTrackIds.length;
      selectedTrackIds.retainAll(visibleTrackIds);
      if (anchorTrackId != null && !visibleTrackIds.contains(anchorTrackId)) {
        anchorTrackId = null;
      }
      if (selectedTrackIds.isEmpty) selectionMode = false;
      if (selectedBefore != selectedTrackIds.length) {
        logInfo('LibraryState',
            '选中集合随上下文收窄: $selectedBefore -> ${selectedTrackIds.length}');
      }

      logInfo('LibraryState',
          'Center loaded: ${centerFolders.length} folders, ${this.tracks.length} tracks');
    } finally {
      // 只有最新一代有资格清 loading，否则会提前关掉新一轮的转圈。
      if (gen == _refreshGeneration) {
        loading = false;
        notifyListeners();
      }
    }
  }

  List<VirtualFolder> _sortFolders(List<VirtualFolder> list) {
    // 先复制：入参可能是 const []（不可变），直接 sort 会抛 Unsupported operation
    final sorted = List<VirtualFolder>.from(list);
    // 自然序：第 2 卷排在第 10 卷前面（BUILD_GUIDE 第 20.2 节）
    sorted.sort((a, b) => naturalCompare(a.name, b.name));
    return sorted;
  }

  // ═══════════════ 导航状态 ═══════════════

  void resetToHome() {
    currentWork = null;
    currentSeries = null;
    currentFolderId = null;
    currentFolder = null;
    currentFolderPath = null;
    breadcrumb = const [];
  }

  /// 进入系列书套。系列内再点作品才进 [showWork]。
  void showSeries(DlsiteSeries series) {
    currentSeries = series;
    currentWork = null;
    currentFolderId = null;
    currentFolder = null;
    currentFolderPath = null;
    breadcrumb = [rootCrumb, seriesCrumb(series)];
  }

  void showWork(Work work, {DlsiteSeries? series}) {
    currentSeries = series;
    currentWork = work;
    currentFolderId = null;
    currentFolder = null;
    currentFolderPath = null;
    breadcrumb = [
      rootCrumb,
      if (series != null) seriesCrumb(series),
      VirtualFolder(id: -1, name: work.name, workId: work.id),
    ];
  }

  void showFolder(VirtualFolder folder, {String? path}) {
    currentFolderId = folder.id;
    currentFolder = folder;
    currentFolderPath = path;
  }

  void setCurrentWork(Work? work) => currentWork = work;

  /// 关库重建前调用：在途的 refresh 拿到结果后发现代际不匹配会丢弃。
  void invalidatePendingRefresh() {
    _refreshGeneration++;
  }

  void bumpFolderVersion() {
    folderVersion++;
    notifyListeners();
  }

  /// 面包屑的根节点。id 用 -2，与作品标记 -1 区分，不落库。
  static const VirtualFolder rootCrumb =
      VirtualFolder(id: -2, name: '全部作品', library: 'audio');

  /// 系列面包屑节点。id 用 -3，与根、作品、真实文件夹区分。
  static VirtualFolder seriesCrumb(DlsiteSeries series) =>
      VirtualFolder(id: -3, name: series.name, library: 'audio');

  Future<List<VirtualFolder>> buildBreadcrumb() async {
    final work = currentWork;
    final series = currentSeries;
    final chain = <VirtualFolder>[];
    var cur = currentFolder;
    while (cur != null) {
      chain.insert(0, cur);
      if (cur.parentId == null) break;
      cur = await folderDao().getById(cur.parentId!);
    }
    if (work != null) {
      chain.insert(
          0,
          VirtualFolder(
              id: -1, name: work.name, parentId: null, workId: work.id));
    }
    if (series != null) chain.insert(0, seriesCrumb(series));
    // 链首固定是全部作品。没有作品归属的文件夹也走这里，不再缺根节点。
    chain.insert(0, rootCrumb);
    return chain;
  }

  // ═══════════════ 搜索 ═══════════════

  void applySearch(String q) {
    searchQuery = q;
  }

  // ═══════════════ 曲目多选 ═══════════════

  bool isSelected(int id) => selectedTrackIds.contains(id);

  void toggleSelect(int id) {
    if (selectedTrackIds.contains(id)) {
      selectedTrackIds.remove(id);
    } else {
      selectedTrackIds.add(id);
    }
    anchorTrackId = id;
    notifyListeners();
  }

  void rangeSelect(int id) {
    final list = tracks;
    final anchorIdx =
        anchorTrackId == null ? -1 : list.indexWhere((t) => t.id == anchorTrackId);
    final curIdx = list.indexWhere((t) => t.id == id);
    if (anchorIdx < 0 || curIdx < 0) {
      toggleSelect(id);
      return;
    }
    final lo = anchorIdx < curIdx ? anchorIdx : curIdx;
    final hi = anchorIdx < curIdx ? curIdx : anchorIdx;
    for (final t in list.sublist(lo, hi + 1)) {
      if (t.id != null) selectedTrackIds.add(t.id!);
    }
    anchorTrackId = id;
    notifyListeners();
  }

  /// 长按进入多选模式（移动端）；桌面 Ctrl+点击也可走此路径
  void enterSelection(int id) {
    selectionMode = true;
    selectedTrackIds.add(id);
    anchorTrackId = id;
    notifyListeners();
  }

  void clearSelection() {
    selectionMode = false;
    selectedTrackIds.clear();
    anchorTrackId = null;
    notifyListeners();
  }

  /// 只开多选模式，不预先选中任何曲目（工具条的「选择」按钮走这条路）
  void enterSelectionMode() {
    selectionMode = true;
    notifyListeners();
  }

  /// 选中当前列表里的全部曲目（多选工具条的「全选」）
  void selectAll() {
    selectionMode = true;
    selectedTrackIds
      ..clear()
      ..addAll(tracks.map((t) => t.id).whereType<int>());
    anchorTrackId = tracks.isEmpty ? null : tracks.first.id;
    notifyListeners();
  }

  /// 只读快照，调用方改不到内部集合。
  Set<int> get selectedView => UnmodifiableSetView(selectedTrackIds);

  // ═══════════════ 作品多选 ═══════════════

  /// 只读快照，调用方改不到内部集合。
  Set<int> get selectedWorkView => UnmodifiableSetView(selectedWorkIds);

  bool isWorkSelected(int id) => selectedWorkIds.contains(id);

  void toggleWorkSelect(int id) {
    if (selectedWorkIds.contains(id)) {
      selectedWorkIds.remove(id);
    } else {
      selectedWorkIds.add(id);
    }
    notifyListeners();
  }

  void enterWorkSelectionMode() {
    workSelectionMode = true;
    notifyListeners();
  }

  bool isSeriesSelected(DlsiteSeries series) {
    if (series.workIds.isEmpty) return false;
    return series.workIds.every(selectedWorkIds.contains);
  }

  bool isSeriesPartiallySelected(DlsiteSeries series) {
    final selected = series.workIds.where(selectedWorkIds.contains).length;
    return selected > 0 && selected < series.workIds.length;
  }

  /// 系列卡多选：全选时取消全系列，否则把整个系列选上。
  void toggleSeriesSelect(DlsiteSeries series) {
    if (isSeriesSelected(series)) {
      selectedWorkIds.removeAll(series.workIds);
    } else {
      selectedWorkIds.addAll(series.workIds);
    }
    notifyListeners();
  }

  void enterSeriesSelection(DlsiteSeries series) {
    workSelectionMode = true;
    selectedWorkIds.addAll(series.workIds);
    notifyListeners();
  }

  void clearWorkSelection() {
    workSelectionMode = false;
    selectedWorkIds.clear();
    notifyListeners();
  }

  /// 选中当前作品列表里的全部（多选工具条的「全选」）。
  ///
  /// 系列页只选该系列成员，不会把首页散作品一起选进来。
  void selectAllWorks() {
    workSelectionMode = true;
    final series = currentSeries;
    final scoped = series == null
        ? works
        : works.where((w) => series.workIds.contains(w.id)).toList();
    selectedWorkIds
      ..clear()
      ..addAll(scoped.map((w) => w.id).whereType<int>());
    notifyListeners();
  }
}
