import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

// RepeatMode 与 Flutter 的同名枚举冲突，隐藏框架那个
import 'package:flutter/material.dart' hide RepeatMode;
import 'package:path/path.dart' as p;

import '../db/database.dart';
import '../db/folder_dao.dart';
import '../db/media_dao.dart';
import '../db/tag_dao.dart';
import '../db/track_dao.dart';
import '../db/work_dao.dart';
import '../db/work_metadata_dao.dart';
import '../services/auto_import_scanner.dart';
import '../services/cover_finder.dart';
import '../services/data_dir_service.dart';
import '../services/file_scanner.dart';
import '../services/folder_tree_mirror.dart';
import '../services/import_scanner.dart';
import '../services/dlsite/dlsite_api.dart';
import '../services/dlsite/dlsite_cover.dart';
import '../services/dlsite/dlsite_models.dart';
import '../services/dlsite/dlsite_repository.dart';
import '../services/dlsite/manual_series.dart';
import '../services/dlsite/series_index.dart';
import '../services/dlsite/work_code.dart';
import '../services/import_service.dart';
import '../services/plan_importer.dart';
import '../services/playlist_writer.dart';
import '../services/segment_service.dart';
import '../services/settings_service.dart';
import 'cover_state.dart';
import 'dlsite_state.dart';
import 'import_state.dart';
import 'tag_filter.dart';
import 'library_state.dart';
import 'playback_state.dart';
import 'settings_state.dart';
import 'tag_state.dart';

export 'tag_filter.dart';
import '../services/subtitle_overlay_bridge.dart';
import '../services/subtitle_overlay_controller.dart';
import '../services/subtitle_parser.dart';
import '../services/subtitle_service.dart';
import '../services/thumbnail_cache.dart';
import '../services/video_launcher.dart';
import '../services/volume_cover_service.dart';
import '../utils/image_cache_util.dart';
import '../utils/log_util.dart';
import '../utils/progress_throttle.dart';
import 'player_controller.dart';

/// 标签筛选规则
/// 应用状态 — 作品集 / 文件夹导航 / 曲目 / 标签 / 导入 / 播放
class AppState extends ChangeNotifier {
  final PlayerController player;

  /// 外链播放器。用例注入假实现，界面用例才能断言交给系统的命令
  final VideoLauncher _launcher;

  /// 抓 DLsite 元数据用的接口层。用例注入假传输层，避免真联网。
  final DlsiteApi? dlsiteApi;

  /// 下载远程封面用。用例注入假字节，避免真联网。
  final DlsiteCoverDownloader? dlsiteCoverDownloader;

  // ── 作品集与导航（数据在 LibraryState）──
  List<Work> get works => library.works;
  Work? get currentWork => library.currentWork;
  List<VirtualFolder> get unassignedFolders => library.unassignedFolders;
  int? get currentFolderId => library.currentFolderId;
  VirtualFolder? get currentFolder => library.currentFolder;
  String? get currentFolderPath => library.currentFolderPath;
  List<VirtualFolder> get breadcrumb => library.breadcrumb;
  int get folderVersion => library.folderVersion;

  // ── 中间栏内容 ──
  List<VirtualFolder> get centerFolders => library.centerFolders;

  /// 播放位置落盘的节流（见 lib/services/play_position.dart）

  List<TrackItem> get tracks => library.tracks;

  /// 媒体行增删的代数，界面据此知道该重查。
  int _mediaRevision = 0;
  int get mediaRevision => _mediaRevision;

  bool get loading => library.loading;

  // ── 搜索 ──
  String get searchQuery => library.searchQuery;

  // ── 标签（数据与逻辑在 TagState）──
  final TagState tags = TagState(
    tagDao: () => TagDao(DatabaseManager.instance.db),
    folderDao: () => FolderDao(DatabaseManager.instance.db),
    trackDao: () => TrackDao(DatabaseManager.instance.db),
  );

  // ── 曲目多选（状态在 LibraryState）──
  /// 只读视图：调用方拿不到内部集合，改不到选中状态。
  Set<int> get selectedTrackIds => library.selectedView;
  bool get selectionMode => library.selectionMode;
  bool isTrackSelected(int id) => library.isSelected(id);

  // ── 作品多选（状态在 LibraryState）──
  Set<int> get selectedWorkIds => library.selectedWorkView;
  bool get workSelectionMode => library.workSelectionMode;
  bool isWorkSelected(int id) => library.isWorkSelected(id);
  void toggleWorkSelect(int id) => library.toggleWorkSelect(id);
  void enterWorkSelectionMode() => library.enterWorkSelectionMode();
  void clearWorkSelection() => library.clearWorkSelection();
  void selectAllWorks() => library.selectAllWorks();
  bool isSeriesSelected(DlsiteSeries series) =>
      library.isSeriesSelected(series);
  bool isSeriesPartiallySelected(DlsiteSeries series) =>
      library.isSeriesPartiallySelected(series);
  void toggleSeriesSelect(DlsiteSeries series) =>
      library.toggleSeriesSelect(series);
  void enterSeriesSelection(DlsiteSeries series) =>
      library.enterSeriesSelection(series);

  TagFilter get tagFilter => tags.tagFilter;
  String get advancedFilter => tags.advancedFilter;
  bool get hasAdvancedFilter => tags.hasAdvancedFilter;

  // ── 图片视图设置 ──
  int get gridColumns => settings.gridColumns;

  // ── 界面布局 ──
  /// 宽屏左栏宽度。界面层还会按窗口宽度再夹一次，这里只保证落在设置允许的范围内。
  double get leftWidth => settings.leftWidth;

  /// 左栏里作品集列表的高度。标签区占剩余空间。
  double get libraryHeight => settings.libraryHeight;

  /// 缩略图缓存上限（MB）。复用封面缓存设置键，见 [setCacheSizeMB]。
  int get cacheSizeMB => covers.cacheLimitMB;

  String get viewMode => settings.viewMode;

  // ── 字幕页外观 ──
  /// 非当前句的透明度是否按封面明暗自动算。
  bool get subtitleOpacityAuto => settings.subtitleOpacityAuto;

  /// 固定模式下非当前句的透明度。
  double get subtitleInactiveOpacity => settings.subtitleInactiveOpacity;

  /// 滑动之后留在原地的秒数。
  int get subtitleResumeSeconds => settings.subtitleResumeSeconds;

  /// 缩略图缓存世代。清空缓存时自增，图片卡片据此重新生成缩略图。
  int _thumbEpoch = 0;
  int get thumbEpoch => _thumbEpoch;

  /// 后台缩略图补齐进度，只用于界面提示。
  ///
  /// 补齐过程不改 [thumbEpoch]：卡片自己会在生成完成后刷新，整屏重置只会
  /// 造成闪烁。进度通知按 [_thumbBackfillNotifyGap] 节流。
  int _thumbBackfillTotal = 0;
  int _thumbBackfillDone = 0;
  bool get backfillingThumbs => _thumbBackfillRunning;
  int get thumbBackfillTotal => _thumbBackfillTotal;
  int get thumbBackfillDone => _thumbBackfillDone;

  double get thumbBackfillProgress => _thumbBackfillTotal <= 0
      ? 0
      : (_thumbBackfillDone / _thumbBackfillTotal).clamp(0.0, 1.0);

  String get thumbBackfillLabel =>
      '缩略图补齐 $_thumbBackfillDone/$_thumbBackfillTotal';

  static const Duration _thumbBackfillNotifyGap = Duration(milliseconds: 250);
  DateTime? _thumbBackfillLastNotify;

  // ── 导入状态 ──
  /// 导入进度与并发守卫拆到了 [ImportState]。
  final ImportState importState = ImportState();
  bool get importing => importState.importing;
  double get importProgress => importState.progress;

  /// 最近一次导入的失败原因；null 表示上次导入没有出错。
  ///
  /// 导入的调用方是按钮回调，没有错误边界，所以不往上抛异常；改成把这个字段
  /// 交给界面，让失败可见，而不是只写一行日志当没事发生。
  String? get importError => importState.error;

  // ── 最近播放 ──
  List<TrackItem> get recentTracks => playback.recentTracks;

  /// [loadRecentTracks] 的代际：快速切歌会并发触发多次重载，只有最后一次能写回。

  // ── 播放队列来源作品的封面（在 CoverState 里）──
  /// 当前播放队列来源作品的封面。队列建立时记录，与「当前浏览的作品」解耦。
  String? get playingWorkCover => covers.playingWorkCover;

  // ── 封面缓存上限（MB，0 表示不限制）──
  int get coverCacheLimitMB => covers.cacheLimitMB;

  // ── 当前曲目的收藏选段（BUILD_GUIDE 第 24.3 节）──
  List<MediaSegment> get segments => playback.segments;

  // ── 设置 ──

  /// 界面设置的持有者。排序、主题、列数、布局尺寸与字幕外观都在这里。
  final SettingsState settings = SettingsState();

  ThemeMode get themeMode => settings.themeMode;
  String get sortKey => settings.sortKey;
  bool get sortDescending => settings.sortDescending;

  // ── 图片 / 视频库排序 ──
  //
  // 音频那套是单份 `_sortKey`；视觉库按库各存一份：图片与视频的行数、
  // 关心的字段都不一样（视频常按大小/时间，图片常按文件名自然序）。

  /// 视觉库排序字段：`name`（自然序，默认）/ `mtime` / `size` / `added`。
  static const Map<String, String> visualSortLabels = {
    'name': '文件名',
    'mtime': '修改时间',
    'size': '文件大小',
    'added': '加入时间',
  };

  /// 多媒体库的排序字段。图片与视频合并成一个库之后只剩这一套设置。
  String get visualSortKey => settings.visualSortKey;

  /// 多媒体库是否降序。
  bool get visualSortDescending => settings.visualSortDescending;

  /// 作品层可用的排序字段。作品没有文件大小与修改时间，只留名称、加入时间与编号。
  static const Map<String, String> worksSortLabels = {
    'name': '文件名',
    'added': '加入时间',
    'code': 'RJ 号',
  };

  /// 作品层排序独立于文件层：默认按加入时间倒序，与列表原有的「新作品在前」一致。
  String get worksSortKey => worksSortLabels.containsKey(settings.worksSortKey)
      ? settings.worksSortKey
      : 'added';

  bool get worksSortDescending => settings.worksSortDescending;

  Future<void> setWorksSortKey(String key) async {
    if (!worksSortLabels.containsKey(key)) return;
    await settings.setWorksSortKey(key);
    notifyListeners();
  }

  Future<void> setWorksSortDescending(bool desc) async {
    await settings.setWorksSortDescending(desc);
    notifyListeners();
  }

  /// 作品层排序比较器。同值时按加入时间、id 兜底，降序整体取负。
  ///
  /// `code` 走已缓存的 RJ/VJ 号；没有编号的作品无论升序还是降序都排最后。
  int Function(Work, Work) get worksComparator {
    final key = worksSortKey;
    final desc = worksSortDescending;
    return (a, b) {
      int cmp;
      if (key == 'code') {
        final aCode = _codeNumber(dlsite.codeForWork(a));
        final bCode = _codeNumber(dlsite.codeForWork(b));
        if (aCode == null && bCode == null) {
          cmp = 0;
        } else if (aCode == null) {
          return 1;
        } else if (bCode == null) {
          return -1;
        } else {
          cmp = aCode.compareTo(bCode);
        }
      } else if (key == 'added') {
        cmp = a.createdAt.compareTo(b.createdAt);
      } else {
        cmp = naturalCompare(a.name, b.name);
      }
      if (cmp == 0) cmp = a.createdAt.compareTo(b.createdAt);
      if (cmp == 0) cmp = (a.id ?? 0).compareTo(b.id ?? 0);
      return desc ? -cmp : cmp;
    };
  }

  /// 从 `RJ01234567` / `VJ01234567` 里取数字部分；没有编号返回 null。
  int? _codeNumber(String? code) {
    if (code == null || code.length < 3) return null;
    return int.tryParse(code.substring(2));
  }

  /// 已导入 ≥2 部的系列。
  List<DlsiteSeries> get seriesGroups => dlsite.seriesIndex.groups;

  /// 当前停靠的系列；不在系列页时为 null。
  DlsiteSeries? get currentSeries => library.currentSeries;

  /// 当前系列页要展示的作品；首页或作品页时就是全部作品。
  List<Work> get visibleWorks {
    final series = library.currentSeries;
    if (series == null) return library.works;
    final ids = series.workIds.toSet();
    return [
      for (final work in library.works)
        if (ids.contains(work.id)) work,
    ];
  }

  /// 当前视觉库的排序比较器。
  ///
  /// `name` 走自然序（`sort_key` 补零，见 BUILD_GUIDE 第 20.2 节），其余字段
  /// 比完再按自然序兜底，保证同一时间戳的行不会每次刷新换位置。
  int Function(MediaItem, MediaItem) get visualSortComparator {
    final key = visualSortKey;
    final desc = visualSortDescending;
    return (a, b) {
      int cmp;
      switch (key) {
        case 'mtime':
          cmp = (a.fileMtime ?? 0).compareTo(b.fileMtime ?? 0);
          break;
        case 'size':
          cmp = (a.fileSize ?? 0).compareTo(b.fileSize ?? 0);
          break;
        case 'added':
          cmp = a.addedAt.compareTo(b.addedAt);
          break;
        default:
          cmp = MediaDao.compareNatural(a, b);
          break;
      }
      if (cmp == 0 && key != 'name') cmp = MediaDao.compareNatural(a, b);
      return desc ? -cmp : cmp;
    };
  }

  Future<void> setVisualSortKey(String key) async {
    if (!visualSortLabels.containsKey(key)) return;
    await settings.setVisualSortKey(key);
    await _afterVisualSortChanged();
  }

  Future<void> setVisualSortDescending(bool desc) async {
    await settings.setVisualSortDescending(desc);
    await _afterVisualSortChanged();
  }

  /// 排序一变：中间栏重排，作品层的网格靠 [mediaRevision] 知道要重查。
  Future<void> _afterVisualSortChanged() async {
    _mediaRevision++;
    notifyListeners();
    await refresh();
  }

  // ── 字幕缓存 ──
  final Map<String, SubtitleDocument> _subtitleCache = {};
  final Set<String> _subtitleRepairTried = <String>{};

  // ═══════════════ DAO 便捷访问 ═══════════════

  WorkDao get _workDao => WorkDao(DatabaseManager.instance.db);
  FolderDao get _folderDao => FolderDao(DatabaseManager.instance.db);
  TrackDao get _trackDao => TrackDao(DatabaseManager.instance.db);
  TagDao get _tagDao => TagDao(DatabaseManager.instance.db);
  MediaDao get _mediaDao => MediaDao(DatabaseManager.instance.db);
  SegmentService get _segmentService =>
      SegmentService(DatabaseManager.instance.db);

  AppState({
    required this.player,
    VideoLauncher? videoLauncher,
    this.dlsiteApi,
    this.dlsiteCoverDownloader,
  }) : _launcher = videoLauncher ?? VideoLauncher() {
    // 标签状态只通知界面重画；筛选变了要让列表重查，所以把 refresh 注进去。
    tags.addListener(notifyListeners);
    tags.onRefresh = refresh;
    // 封面缓存驱逐要知道「正在播的曲目」和「当前作品的封面」，用回调注入，
    // 不让 CoverState 反向依赖播放器与作品库。
    covers = CoverState(
      db: () => DatabaseManager.instance.db,
      protectedPaths: _protectedCoverPaths,
    )..addListener(notifyListeners);
    dlsite = DlsiteState(
      db: () => DatabaseManager.instance.db,
      workDao: () => _workDao,
      api: dlsiteApi,
      downloader: dlsiteCoverDownloader,
      onRefresh: refresh,
    )..addListener(notifyListeners);
    subtitleOverlay = SubtitleOverlayController(
      player: player,
      subtitleFor: subtitleFor,
      bridge: MethodChannelSubtitleOverlayBridge(),
      persistEnabled: settings.setSubtitleOverlayEnabled,
      persistLocked: settings.setSubtitleOverlayLocked,
    )..addListener(notifyListeners);
    // 播放状态持有队列命令、播放历史、选段与续播位置；队列在 player 里，
    // 它只决定「播哪些、从哪首开始、播完写回什么」。
    playback = PlaybackState(
      player: player,
      trackDao: () => _trackDao,
      mediaDao: () => _mediaDao,
      segmentService: () => _segmentService,
      currentTracks: () => library.tracks,
      onTracksChanged: (tracks) {
        library.tracks = tracks;
        notifyListeners();
      },
      rememberQueueCover: covers.rememberQueueCover,
      queueCoverPath: () => currentWork?.coverPath,
    )..addListener(notifyListeners);
    // 作品库只通知界面重画；跨对象协作（封面、元数据、标签）留在 AppState。
    library = LibraryState(
      trackDao: () => _trackDao,
      workDao: () => _workDao,
      folderDao: () => _folderDao,
      mediaDao: () => _mediaDao,
      tagDao: () => _tagDao,
      hasAdvancedFilter: () => hasAdvancedFilter,
      tagFilter: () => tags.tagFilter,
      matchingIds: _computeMatchingIds,
      filterFolders: (folders, ids) =>
          _filterFolders(folders, ids, MediaType.audio),
      sortTracks: _sortTracks,
      onBeforeRefresh: _subtitleCache.clear,
    )..addListener(notifyListeners);
  }

  /// 播放状态：队列命令、播放历史、选段与续播位置。
  late final PlaybackState playback;

  /// 作品库状态：作品集、导航、中间栏内容、搜索与曲目多选。
  late final LibraryState library;

  /// 封面相关状态：卷封面、播放来源封面、缓存上限与驱逐。
  late final CoverState covers;

  /// DLsite 元数据状态：编号解析、抓取、预览与应用。
  late final DlsiteState dlsite;

  /// 系统级常驻字幕：只把当前/下一句推给原生窗口。
  late final SubtitleOverlayController subtitleOverlay;

  Future<void> init() async {
    logInfo('AppState', 'Initializing...');
    // 缩略图服务必须在这里初始化：界面一建卡片就会调 thumbPath()，
    // 漏掉这一步时缩略图一张都生成不出来（网格只剩占位图标）。
    await ThumbnailService.instance.init();
    player.onTrackStarted = playback.onTrackStarted;
    player.resumeFrom = playback.resumeOf;
    player.onPositionChanged = playback.onPosition;
    player.onPlaybackPaused = playback.onPlaybackPaused;
    player.onTrackCompleted = playback.onTrackCompleted;
    player.onRepeatModeChanged = _persistRepeatMode;
    player.onShuffleChanged = _persistShuffle;
    player.onSpeedChanged = _persistSpeed;
    await loadSettings();
    // 规则标签只放定义行，筛选时翻成列条件（BUILD_GUIDE 第 18.4 节）。
    await _tagDao.ensureRuleTags(extNames: _ruleTagExtensions);
    await loadTags();
    await tags.initNotTagIds();
    await tags.initCollapsedNamespaces();
    await loadRecentTracks();
    await loadCoverCacheLimit();
    await refresh();
    await dlsite.loadCodes();
    await dlsite.loadSeriesIndex();
    logInfo('AppState', 'Initialized OK');
    // 启动后的自动导入不挡界面：先让首页画出来，再在后台扫目录。
    unawaited(autoImportOnStartup());
  }

  // ═══════════════ 设置 ═══════════════

  /// 载入设置期间不回写，避免把刚读到的值又原样写一遍
  bool _loadingSettings = false;

  Future<void> loadSettings() async {
    final ss = SettingsService.instance;
    _loadingSettings = true;
    try {
      settings.load(ss);
      await subtitleOverlay.configure(
        enabled: settings.subtitleOverlayEnabled,
        locked: settings.subtitleOverlayLocked,
      );
      player.setRepeatMode(_repeatModeFromName(ss.repeatModeName));
      player.setShuffle(ss.shuffle);
      await player.setSpeed(ss.playSpeed);
    } finally {
      _loadingSettings = false;
    }
    notifyListeners();
  }

  /// 规则标签要补的全部扩展名，四种媒体各自的扫描白名单并集。
  static Iterable<String> get _ruleTagExtensions => {
    ...audioExtensions,
    ...imageExtensions,
    ...videoExtensions,
    ...knownSubtitleExtensions,
  };

  static RepeatMode _repeatModeFromName(String name) => switch (name) {
    'off' => RepeatMode.off,
    'one' => RepeatMode.one,
    _ => RepeatMode.all,
  };

  static String _repeatModeName(RepeatMode mode) => switch (mode) {
    RepeatMode.off => 'off',
    RepeatMode.one => 'one',
    RepeatMode.all => 'all',
  };

  Future<void> _persistRepeatMode(RepeatMode mode) async {
    if (_loadingSettings) return;
    await SettingsService.instance.setRepeatModeName(_repeatModeName(mode));
  }

  Future<void> _persistShuffle(bool on) async {
    if (_loadingSettings) return;
    await SettingsService.instance.setShuffle(on);
  }

  Future<void> _persistSpeed(double speed) async {
    if (_loadingSettings) return;
    await SettingsService.instance.setPlaySpeed(speed);
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    await settings.setThemeMode(mode);
    notifyListeners();
  }

  Future<void> setSortKey(String key) async {
    await settings.setSortKey(key);
    await refresh();
  }

  Future<void> setSortDescending(bool desc) async {
    await settings.setSortDescending(desc);
    await refresh();
  }

  // ── 图片视图设置 ──

  Future<void> setGridColumns(int cols) async {
    await settings.setGridColumns(cols);
    notifyListeners();
  }

  // ── 界面布局 ──

  Future<void> setLeftWidth(double width) async {
    await settings.setLeftWidth(width);
    notifyListeners();
  }

  Future<void> setLibraryHeight(double height) async {
    await settings.setLibraryHeight(height);
    notifyListeners();
  }

  /// 恢复默认布局。只动两个尺寸，不碰主题、列数、排序与筛选。
  Future<void> resetLayoutSizes() async {
    await settings.resetLayoutSizes();
    notifyListeners();
  }

  /// 缩略图缓存上限。与封面缓存上限共用 `cover_cache_mb` 设置键，
  /// 落到 [setCoverCacheLimit] 上，避免同一份配额存两遍。
  Future<void> setCacheSizeMB(int mb) => setCoverCacheLimit(mb);

  // ── 字幕页外观 ──

  Future<void> setSubtitleOpacityAuto(bool auto) async {
    await settings.setSubtitleOpacityAuto(auto);
    notifyListeners();
  }

  Future<void> setSubtitleInactiveOpacity(double value) async {
    await settings.setSubtitleInactiveOpacity(value);
    notifyListeners();
  }

  Future<void> setSubtitleResumeSeconds(int seconds) async {
    await settings.setSubtitleResumeSeconds(seconds);
    notifyListeners();
  }

  /// 当前字幕是否已放到系统级常驻窗口。
  bool get subtitleOverlayEnabled => subtitleOverlay.enabled;

  /// 常驻字幕是否锁定（鼠标/触摸穿透）。
  bool get subtitleOverlayLocked => subtitleOverlay.locked;

  /// 最近一次开启常驻字幕失败的原因。
  String? get subtitleOverlayError => subtitleOverlay.error;

  /// 开启/关闭常驻字幕。失败时返回 false，原因见 [subtitleOverlayError]。
  Future<bool> setSubtitleOverlayEnabled(bool enabled) =>
      subtitleOverlay.setEnabled(enabled);

  Future<void> setSubtitleOverlayLocked(bool locked) =>
      subtitleOverlay.setLocked(locked);

  Future<void> setViewMode(String mode) async {
    await settings.setViewMode(mode);
    notifyListeners();
  }

  /// 缩略图缓存被清空：自增世代，让在屏的图片卡片重新生成缩略图。
  void markThumbnailsCleared() {
    _thumbEpoch++;
    notifyListeners();
  }

  // ═══════════════ 图片列表 / 选中 / 查看器 ═══════════════

  /// 当前浏览上下文的库标识：`audio` / `media`，没有上下文时为 null。
  String? get currentLibrary =>
      library.currentWork?.library ?? library.currentFolder?.library;

  /// 批量「从软件移除」：只删库里的媒体行，磁盘文件不动。
  ///
  /// 返回真正删掉的行数。关联的标签行由外键级联清掉。
  Future<int> deleteMediaByIds(Iterable<int> ids) async {
    final list = ids.toSet().toList();
    if (list.isEmpty) return 0;
    final deleted = await _mediaDao.deleteByIds(list);
    for (final id in list) {
      tags.clearCaches();
      library.selectedTrackIds.remove(id);
    }
    if (library.selectedTrackIds.isEmpty) library.selectionMode = false;
    if (library.anchorTrackId != null &&
        !library.selectedTrackIds.contains(library.anchorTrackId)) {
      library.anchorTrackId = null;
    }
    _mediaRevision++;
    await refresh();
    logInfo('AppState', '批量移除媒体 $deleted 条（请求 ${list.length} 条）');
    return deleted;
  }

  // ═══════════════ 刷新 / 中间栏加载（实现在 LibraryState）═══════════════

  Future<void> refresh() => library.refresh();

  /// 目录结构变了，界面据此重查文件夹树。
  void _bumpFolderVersion() => library.bumpFolderVersion();

  /// 当前筛选下命中的媒体 id 集合。[type] 是当前库的媒体类型：音频库用
  /// `MediaType.audio`，多媒体库传 null（不限类型）。
  Future<Set<int>> _computeMatchingIds(MediaType? type) async {
    if (hasAdvancedFilter) {
      return _tagDao.getIdsByExpression(
        type,
        tags.advancedFilter,
        tags.allTags,
      );
    }
    return _tagDao.getIdsByTags(
      type,
      andTagIds: tags.tagFilter.andTagIds,
      orTagIds: tags.tagFilter.orTagIds,
      notTagIds: tags.tagFilter.notTagIds,
    );
  }

  Future<List<VirtualFolder>> _filterFolders(
    List<VirtualFolder> folders,
    Set<int> matchingIds,
    MediaType? type,
  ) async {
    if (folders.isEmpty) return [];
    final matchingPaths = matchingIds.isEmpty
        ? <String>[]
        : type == MediaType.audio
        ? await _trackDao.pathsByIds(matchingIds)
        : await _mediaDao.pathsByIds(matchingIds, type: type);

    Map<int, List<Tag>> folderTags = {};
    if (!hasAdvancedFilter && tags.tagFilter.active) {
      folderTags = await _tagDao.getTagsForFolders(
        folders.map((f) => f.id!).toList(),
      );
    }

    // 一次取全部目录路径，再把命中路径排好序做二分查找。
    // 旧实现每个文件夹查一次库，再对每个匹配路径做 O(F×M) 的 any。
    final allPaths = await _folderDao.getAllPaths();
    final matchingLower = matchingPaths.map((p) => p.toLowerCase()).toList()
      ..sort();

    final result = <VirtualFolder>[];
    for (final f in folders) {
      final paths = allPaths[f.id!] ?? const <FolderPath>[];
      final containsTrack = paths.any(
        (p) => _hasPathUnder(matchingLower, p.path),
      );
      if (containsTrack) {
        result.add(f);
        continue;
      }
      if (!hasAdvancedFilter && tagFilter.active) {
        final tags = folderTags[f.id] ?? const <Tag>[];
        if (_folderTagsMatch(tags)) result.add(f);
      }
    }
    return result;
  }

  bool _folderTagsMatch(List<Tag> tags) {
    final ids = tags.map((t) => t.id).whereType<int>().toSet();
    if (tagFilter.andTagIds.any((id) => !ids.contains(id))) return false;
    if (tagFilter.orTagIds.isNotEmpty &&
        !tagFilter.orTagIds.any((id) => ids.contains(id))) {
      return false;
    }
    if (tagFilter.notTagIds.any((id) => ids.contains(id))) return false;
    return true;
  }

  /// [sortedLower] 必须已按字典序排好，且全部转小写。
  bool _hasPathUnder(List<String> sortedLower, String dir) {
    var d = dir.toLowerCase();
    while (d.endsWith('\\') || d.endsWith('/')) {
      d = d.substring(0, d.length - 1);
    }
    for (final sep in const ['/', '\\']) {
      final prefix = '$d$sep';
      var lo = 0;
      var hi = sortedLower.length;
      while (lo < hi) {
        final mid = (lo + hi) >> 1;
        if (sortedLower[mid].compareTo(prefix) >= 0) {
          hi = mid;
        } else {
          lo = mid + 1;
        }
      }
      if (lo < sortedLower.length && sortedLower[lo].startsWith(prefix)) {
        return true;
      }
    }
    return false;
  }

  /// 图片/视频按当前视觉库的排序方式排；默认 `name` 是自然序，
  /// 与 [MediaDao.naturalOrderBy] 的 SQL 顺序一致（BUILD_GUIDE 第 20.2 节）。
  List<MediaItem> _sortImages(List<MediaItem> list) {
    final sorted = List<MediaItem>.from(list);
    sorted.sort(visualSortComparator);
    return sorted;
  }

  List<TrackItem> _sortTracks(List<TrackItem> list) {
    final sorted = List<TrackItem>.from(list);
    final dir = settings.sortDescending ? -1 : 1;
    sorted.sort((a, b) {
      int cmp;
      switch (settings.sortKey) {
        case 'title':
          cmp = a.displayTitle.toLowerCase().compareTo(
            b.displayTitle.toLowerCase(),
          );
          break;
        case 'duration':
          cmp = (a.durationMs ?? 0).compareTo(b.durationMs ?? 0);
          break;
        case 'added_at':
          cmp = a.addedAt.compareTo(b.addedAt);
          break;
        default:
          cmp = a.filename.toLowerCase().compareTo(b.filename.toLowerCase());
          break;
      }
      if (cmp == 0) {
        cmp = a.filename.toLowerCase().compareTo(b.filename.toLowerCase());
      }
      return cmp * dir;
    });
    return sorted;
  }

  // ═══════════════ 搜索 ═══════════════

  void setSearchQuery(String q) {
    library.applySearch(q);
    refresh();
  }

  // ═══════════════ 导航 ═══════════════

  Future<void> goHome() async {
    library.resetToHome();
    await refresh();
  }

  Future<void> enterWork(int workId) async {
    final work = await _workDao.getById(workId);
    if (work == null) return;
    // 旧版一次性导入只建根文件夹，曲目全在子目录里，点进作品会显示为空。
    // 进入前按 media 路径补齐一次树；幂等，正常导入的作品只会多一次查询。
    await _repairWorkFolderTree(work);
    // 旧版一次性导入也没有扫描同名字幕；进入时补一次，避免用户重导整个库。
    await _repairWorkSubtitles(work);
    // 从系列页进的，面包屑保留系列；从首页进的就没有系列节点。
    library.showWork(work, series: library.currentSeries);
    // 元数据先装进内存，详情头同步读，省一次闪烁。
    await dlsite.prefetch(workId);
    library.setCurrentWork(await _workDao.getById(workId) ?? work);
    await refresh();
    subtitleOverlay.refresh();
  }

  /// 一次性导入的旧数据兼容：根文件夹存在、却没有子文件夹，但根目录下确实
  /// 有曲目时，按 media 路径重建目录树。
  Future<void> _repairWorkFolderTree(Work work) async {
    final workId = work.id;
    if (workId == null) return;
    final roots = await _folderDao.listRootsByWork(workId);
    if (roots.length > 1) return;

    var rootPath = work.rootPath;
    if (roots.length == 1) {
      // 优先用已经落库的根路径，避免大小写/尾斜杠差异让 ensureByPath 又建
      // 一个同名的根文件夹。
      final paths = await _folderDao.getPaths(roots.first.id!);
      if (paths.isNotEmpty) rootPath = paths.first.path;
    }
    if (rootPath == null || rootPath.trim().isEmpty) {
      return;
    }

    if (roots.length == 1) {
      final children = await _folderDao.listChildren(roots.first.id!);
      if (children.isNotEmpty) return;
    }

    // 不能因为根目录里有直属曲目就提前返回：旧数据可能同时有根目录曲目和
    // 01_mp3 / 02_wav 子目录曲目，后者同样需要补出文件夹。
    final tracks = await _trackDao.queryByDirs([rootPath]);
    if (tracks.isEmpty) return;
    await FolderTreeMirror(_folderDao).ensureForPaths(
      rootPath: rootPath,
      rootName: work.name,
      workId: workId,
      mediaPaths: tracks.map((t) => t.path),
    );
    logInfo('AppState', '补齐作品文件夹树: ${work.name} (${tracks.length} 首)');
  }

  /// 旧版一次性导入的作品没有扫描同名字幕；第一次进入时补一遍。
  ///
  /// 只填空字幕的音频，不覆盖用户手选的字幕。本次运行里同一作品只扫一次，
  /// 避免没有字幕的作品每次进入都遍历目录。
  Future<void> _repairWorkSubtitles(Work work) async {
    final rootPath = work.rootPath;
    if (rootPath == null || rootPath.trim().isEmpty) return;
    final key = rootPath.toLowerCase();
    if (!_subtitleRepairTried.add(key)) return;

    final tracks = await _trackDao.queryByDirs([rootPath]);
    final missing = tracks
        .where((t) =>
            t.id != null &&
            (t.subtitlePath == null || t.subtitlePath!.isEmpty))
        .toList();
    if (missing.isEmpty) return;

    final matched = await FileScanner.scanSubtitlesForAudio(
      rootPath,
      missing.map((t) => t.path),
    );
    var repaired = 0;
    for (final track in missing) {
      final subtitle = matched[track.path];
      if (subtitle == null) continue;
      await _trackDao.setSubtitlePath(track.id!, subtitle);
      repaired++;
    }
    if (repaired > 0) {
      logInfo('AppState', '补齐作品字幕: ${work.name} ($repaired 首)');
    }
  }

  /// 点开系列「大作品」，进入与全部作品页相同的封面视图。
  Future<void> enterSeries(DlsiteSeries series) async {
    library.showSeries(series);
    await refresh();
  }

  /// 手动把若干作品圈成一个系列。返回刷新后的系列；少于 2 部时报错。
  Future<DlsiteSeries?> createManualSeries(
    Iterable<int> workIds, {
    required String name,
  }) async {
    final cleanName = name.trim();
    if (cleanName.isEmpty) throw StateError('系列名不能为空');
    final ids = <int>[];
    for (final id in workIds) {
      if (!ids.contains(id)) ids.add(id);
    }
    if (ids.length < 2) throw StateError('至少选 2 部作品才能建系列');

    final existing = SettingsService.instance.manualSeries;
    for (final item in existing) {
      if (item.name.toLowerCase() == cleanName.toLowerCase()) {
        throw StateError('已经有同名系列了');
      }
    }

    // 一部作品只能属于一个手动系列：从其它系列里摘掉这些 id。
    final next = <ManualSeries>[];
    for (final item in existing) {
      final kept = item.workIds.where((id) => !ids.contains(id)).toList();
      if (kept.length >= 2) {
        next.add(ManualSeries(id: item.id, name: item.name, workIds: kept));
      }
    }
    final id = 'm${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}'
        '${math.Random().nextInt(1296).toRadixString(36).padLeft(2, '0')}';
    next.add(ManualSeries(id: id, name: cleanName, workIds: ids));
    await SettingsService.instance.setManualSeries(next);
    await dlsite.loadSeriesIndex();
    return _seriesByKey('manual:$id');
  }

  /// 重命名手动系列；自动系列不能改。
  Future<void> renameManualSeries(String key, String name) async {
    final cleanName = name.trim();
    if (cleanName.isEmpty) throw StateError('系列名不能为空');
    final id = key.startsWith('manual:') ? key.substring('manual:'.length) : null;
    if (id == null) throw StateError('只有手动创建的系列才能重命名');

    final existing = SettingsService.instance.manualSeries;
    if (!existing.any((item) => item.id == id)) {
      throw StateError('系列不存在，可能已被删除');
    }
    for (final item in existing) {
      if (item.id != id && item.name.toLowerCase() == cleanName.toLowerCase()) {
        throw StateError('已经有同名系列了');
      }
    }

    await SettingsService.instance.setManualSeries([
      for (final item in existing)
        item.id == id
            ? ManualSeries(id: item.id, name: cleanName, workIds: item.workIds)
            : item,
    ]);
    await dlsite.loadSeriesIndex();
    final updated = _seriesByKey(key);
    if (updated != null && library.currentSeries?.key == key) {
      library.showSeries(updated);
      await refresh();
    }
  }

  /// 解散手动系列；作品回到普通卡片或自动系列。
  Future<void> deleteManualSeries(String key) async {
    final id = key.startsWith('manual:') ? key.substring('manual:'.length) : null;
    if (id == null) throw StateError('只有手动创建的系列才能解散');
    final existing = SettingsService.instance.manualSeries;
    await SettingsService.instance.setManualSeries([
      for (final item in existing)
        if (item.id != id) item,
    ]);
    await dlsite.loadSeriesIndex();
    if (library.currentSeries?.key == key) await goHome();
  }

  DlsiteSeries? _seriesByKey(String key) {
    for (final series in dlsite.seriesIndex.groups) {
      if (series.key == key) return series;
    }
    return null;
  }

  Future<void> enterFolder(int folderId) async {
    final folder = await _folderDao.getById(folderId);
    if (folder == null) return;
    final paths = await _folderDao.getPaths(folderId);
    library.showFolder(folder, path: paths.isEmpty ? null : paths.first.path);
    // 若文件夹属于某作品，确保 currentWork 一致
    final work = library.currentWork;
    if (folder.workId != null && work?.id != folder.workId) {
      final w = await _workDao.getById(folder.workId!);
      if (w != null) library.setCurrentWork(w);
    }
    library.breadcrumb = await library.buildBreadcrumb();
    await refresh();
  }

  Future<void> goUp() async {
    if (library.currentFolderId == null) {
      final work = library.currentWork;
      final series = library.currentSeries;
      if (work != null && series != null) {
        // 作品根再往上回到系列书套，而不是直接回首页。
        await enterSeries(series);
        return;
      }
      // 作品层或系列层再往上就是全部作品。
      await goHome();
      return;
    }
    final parent = library.currentFolder?.parentId;
    if (parent == null) {
      // 回到作品层
      final work = library.currentWork;
      if (work != null) {
        await enterWork(work.id!);
      } else {
        await goHome();
      }
      return;
    }
    await enterFolder(parent);
  }

  Future<void> enterWorkOrHome() async {
    final work = library.currentWork;
    if (work != null) {
      await enterWork(work.id!);
    } else {
      await goHome();
    }
  }

  // ═══════════════ 作品集操作 ═══════════════

  Future<Work> createWork(String name) async {
    final work = await _workDao.create(name);
    await refresh();
    return work;
  }

  Future<void> renameWork(int id, String name) async {
    await _workDao.rename(id, name);
    if (library.currentWork?.id == id) {
      library.currentWork = Work(
        id: id,
        name: name,
        coverPath: library.currentWork!.coverPath,
        createdAt: library.currentWork!.createdAt,
      );
    }
    await refresh();
  }

  Future<void> deleteWork(int id) async {
    // WorkDao.delete 内部用事务完成「摘归属 + 删作品」。
    await _workDao.delete(id);
    if (library.currentWork?.id == id) {
      await goHome();
    } else {
      await refresh();
    }
  }

  Future<void> setWorkCover(int id, String? coverPath) async {
    await _workDao.setCover(id, coverPath);
    if (library.currentWork?.id == id) {
      library.currentWork = Work(
        id: id,
        name: library.currentWork!.name,
        coverPath: coverPath,
        createdAt: library.currentWork!.createdAt,
      );
    }
    notifyListeners();
    await refresh();
  }

  // ═══════════════ 文件夹操作 ═══════════════

  Future<void> renameFolder(int id, String newName) async {
    await _folderDao.rename(id, newName);
    _bumpFolderVersion();
    await refresh();
  }

  Future<void> deleteFolder(int id) async {
    // 先记下这个文件夹自己挂在哪几条路径上：删完之后 folder_paths 会被 CASCADE 清掉，
    // 再想问「哪些曲目本来是靠它才可见的」就没有依据了。
    final removedPaths = (await _folderDao.getPaths(
      id,
    )).map((fp) => fp.path).toList();
    await _folderDao.delete(id);
    await _pruneTracksLeftBehind(removedPaths);
    _bumpFolderVersion();
    if (library.currentFolderId == id) {
      library.currentFolderId = null;
      library.currentFolder = null;
      library.currentFolderPath = null;
    }
    await refresh();
  }

  /// 删除文件夹后，把「落在被删路径下、又不再被任何文件夹覆盖」的曲目从曲库移除。
  ///
  /// 曲目行只通过 folder_paths 里的路径前缀可见。留下这些孤儿行会同时坏两件事：
  /// 搜索能搜到但树里进不去；同一个目录再导入会被「全部已入库」挡掉，
  /// 于是那个目录永远挂不回来。
  ///
  /// 返回实际删除的曲目行数。
  Future<int> _pruneTracksLeftBehind(List<String> removedPaths) async {
    if (removedPaths.isEmpty) return 0;

    final alive = <String>[];
    for (final list in (await _folderDao.getAllPaths()).values) {
      for (final fp in list) {
        alive.add(fp.path);
      }
    }

    final orphan = <String>[];
    for (final track in await _trackDao.queryAll()) {
      final wasInside = removedPaths.any((r) => p.isWithin(r, track.path));
      if (!wasInside) continue;
      // 还有别的文件夹挂着它的上级目录，就留着。
      if (alive.any((a) => p.isWithin(a, track.path))) continue;
      orphan.add(track.path);
    }
    if (orphan.isEmpty) return 0;

    final deleted = await _trackDao.deleteByPaths(orphan);
    tags.clearCaches();
    if (deleted > 0) _mediaRevision++;
    logInfo('AppState', '删除文件夹后清理失联曲目 ${orphan.length} 条（实删 $deleted 行）');
    return deleted;
  }

  /// 深度删除文件夹：连子文件夹与其中所有媒体记录一起从软件里移除。
  ///
  /// 与 [deleteFolder] 的区别是这个方法把「目录里的东西」也一起清掉；两者都只动
  /// 数据库，不碰磁盘文件，用户之后重新导入就能拿回来。返回移除的媒体行数。
  Future<int> deleteFolderDeep(int id) async {
    final ids = await _expandFoldersDeep(<int>{id});
    final deleted = await _deleteFoldersDeep(ids);
    _bumpFolderVersion();
    if (library.currentFolderId != null &&
        ids.contains(library.currentFolderId)) {
      library.currentFolderId = null;
      library.currentFolder = null;
      library.currentFolderPath = null;
    }
    await refresh();
    return deleted;
  }

  /// 深度删除作品：作品、它下面的文件夹与其中的媒体记录一起移除。
  ///
  /// 与 [deleteWork] 的区别是不再留下「未归类」的文件夹树。
  Future<int> deleteWorkDeep(int workId) async {
    final owned = await _folderDao.listByWork(workId);
    final ids = await _expandFoldersDeep(
      owned.map((f) => f.id).whereType<int>().toSet(),
    );
    final deleted = await _deleteFoldersDeep(ids);
    // 文件夹已删，这里只剩摘掉已不存在的归属并删除作品行。
    await _workDao.delete(workId);
    _bumpFolderVersion();
    if (library.currentWork?.id == workId) {
      await goHome();
    } else {
      await refresh();
    }
    await dlsite.loadSeriesIndex();
    await _syncCurrentSeriesAfterDelete();
    return deleted;
  }

  /// 删作品后重建系列索引；当前系列掉到 1 部以下就退出书套回首页。
  Future<void> _syncCurrentSeriesAfterDelete() async {
    if (library.currentSeries == null) return;
    final key = library.currentSeries?.key;
    DlsiteSeries? match;
    for (final series in dlsite.seriesIndex.groups) {
      if (series.key == key) {
        match = series;
        break;
      }
    }
    if (match == null) {
      await goHome();
    } else {
      library.currentSeries = match;
      notifyListeners();
    }
  }

  /// 深度删除某文件夹会移除多少条媒体记录（删除前用来提示用户）。
  Future<int> countMediaUnderFolder(int folderId) async {
    final ids = await _expandFoldersDeep(<int>{folderId});
    return _countMediaInFolders(ids);
  }

  /// 作品下全部媒体的 id：作品卡片的标签增删要用（一次作用于整个作品）。
  ///
  /// 取法同 [countMediaUnderWork]，但这里要全部命中项——作品视图里看到的本来
  /// 就是这些目录下的媒体，标签也该整批生效。
  Future<List<int>> mediaIdsUnderWork(int workId) async {
    final rows = await _mediaUnderWork(workId);
    return rows.map((m) => m.id).whereType<int>().toList();
  }

  /// 作品下的全部图片（按自然序）：作品封面的「从作品图片里选」用它当候选。
  Future<List<MediaItem>> imagesUnderWork(int workId) =>
      _mediaUnderWork(workId, type: MediaType.image);

  /// 作品封面的候选图路径（自然序）。
  ///
  /// 图片作品直接取入库的图片行。音频作品的封面图不在媒体表里（导入音频时
  /// 只写音频行），若仍只查图片行，选择器会空着；这里退回作品根目录做一次
  /// 递归扫描，把同目录的封面图与扫图也列出来。
  Future<List<String>> coverCandidatesUnderWork(int workId) async {
    final images = await imagesUnderWork(workId);
    final paths = <String>{for (final item in images) item.path};
    if (paths.isEmpty) {
      final roots = await _folderDao.listRootsByWork(workId);
      final rootPaths = await _pathsOfFolders(
        roots.map((f) => f.id).whereType<int>().toSet(),
      );
      for (final root in rootPaths) {
        try {
          await for (final entity in Directory(
            root,
          ).list(recursive: true, followLinks: false)) {
            if (entity is File && isImageFile(entity.path)) {
              paths.add(entity.path);
            }
          }
        } catch (e) {
          logWarn('AppState', '扫描封面候选失败: $root', e);
        }
      }
    }
    return paths.toList()..sort(naturalCompare);
  }

  /// 作品目录闭包里的媒体行。[type] 非空时只取该类型。
  Future<List<MediaItem>> _mediaUnderWork(int workId, {MediaType? type}) async {
    final owned = await _folderDao.listByWork(workId);
    if (owned.isEmpty) return const [];
    final ids = await _expandFoldersDeep(
      owned.map((f) => f.id).whereType<int>().toSet(),
    );
    final paths = await _pathsOfFolders(ids);
    if (paths.isEmpty) return const [];
    return _mediaDao.queryByDirs(
      paths.toList(),
      type: type,
      orderBy: MediaDao.naturalOrderBy,
    );
  }

  /// 深度删除某作品会移除多少条媒体记录（删除前用来提示用户）。
  Future<int> countMediaUnderWork(int workId) async {
    final owned = await _folderDao.listByWork(workId);
    final ids = await _expandFoldersDeep(
      owned.map((f) => f.id).whereType<int>().toSet(),
    );
    return _countMediaInFolders(ids);
  }

  /// 把一批文件夹扩成闭包：先补后代，再吸收「路径落在被删目录里」的其它文件夹。
  ///
  /// 后一步是为了跨库：同一条物理目录常同时登记在音频树与图片树（专辑目录里的
  /// 封面、扫描件）。只删音频那一份会让图片侧的文件夹留在树里，指向已经不在库中
  /// 的文件。吸收是迭代的——新吸进来的文件夹可能又带进别的库。
  Future<Set<int>> _expandFoldersDeep(Set<int> seed) async {
    final ids = <int>{};
    for (final id in seed) {
      ids.addAll(await _folderDao.collectDescendants(id));
    }
    final removed = await _pathsOfFolders(ids);
    var grew = true;
    while (grew) {
      grew = false;
      final all = await _folderDao.getAllPaths();
      for (final entry in all.entries) {
        if (ids.contains(entry.key)) continue;
        final inside = entry.value.any(
          (fp) => removed.any((r) => fp.path == r || p.isWithin(r, fp.path)),
        );
        if (!inside) continue;
        ids.addAll(await _folderDao.collectDescendants(entry.key));
        removed.addAll(entry.value.map((fp) => fp.path));
        grew = true;
      }
    }
    return ids;
  }

  Future<Set<String>> _pathsOfFolders(Set<int> ids) async {
    final out = <String>{};
    for (final id in ids) {
      out.addAll((await _folderDao.getPaths(id)).map((fp) => fp.path));
    }
    return out;
  }

  /// 深度删除的执行体：先删文件夹行，再清掉因此失联的媒体行。
  Future<int> _deleteFoldersDeep(Set<int> ids) async {
    if (ids.isEmpty) return 0;
    final removed = await _pathsOfFolders(ids);
    await _folderDao.deleteMany(ids);
    return _pruneMediaLeftBehind(removed.toList());
  }

  /// 清掉落在 [removedPaths] 下、又不再被任何文件夹覆盖的媒体行（全部类型）。
  ///
  /// [deleteFolder] 用的 [_pruneTracksLeftBehind] 只管音频，这里的「深度删除」
  /// 要连图片、视频、字幕记录一起清，否则树里没入口、网格里却还看得见。
  Future<int> _pruneMediaLeftBehind(List<String> removedPaths) async {
    if (removedPaths.isEmpty) return 0;
    final alive = <String>[];
    for (final list in (await _folderDao.getAllPaths()).values) {
      for (final fp in list) {
        alive.add(fp.path);
      }
    }
    final under = await _mediaDao.queryByDirs(removedPaths);
    final victims = <String>[];
    for (final m in under) {
      if (alive.any((a) => p.isWithin(a, m.path))) continue;
      victims.add(m.path);
    }
    if (victims.isEmpty) return 0;
    final deleted = await _mediaDao.deleteByPaths(victims);
    tags.clearCaches();
    // 媒体行被删了就要推进代数：作品层的 ImageGrid 缓存着查过的列表，
    // 只靠 folderVersion 它不知道该重查，删掉的磁贴会留在界面上。
    if (deleted > 0) _mediaRevision++;
    logInfo('AppState', '深度删除后清理媒体 ${victims.length} 条（实删 $deleted 行）');
    return deleted;
  }

  Future<int> _countMediaInFolders(Set<int> ids) async {
    if (ids.isEmpty) return 0;
    final removed = await _pathsOfFolders(ids);
    if (removed.isEmpty) return 0;
    final alive = <String>[];
    for (final entry in (await _folderDao.getAllPaths()).entries) {
      if (ids.contains(entry.key)) continue;
      for (final fp in entry.value) {
        alive.add(fp.path);
      }
    }
    final under = await _mediaDao.queryByDirs(removed.toList());
    return under.where((m) => !alive.any((a) => p.isWithin(a, m.path))).length;
  }

  /// 把文件夹（及其后代）移动到另一作品
  Future<void> moveFolderToWork(int folderId, int? workId) async {
    final ids = await _folderDao.collectDescendants(folderId);
    await _folderDao.setWorkMany(ids, workId);
    _bumpFolderVersion();
    await refresh();
  }

  Future<List<Work>> loadWorks() => _workDao.listAll();

  // ═══════════════ 导入 ═══════════════

  /// 导入目录（自动创建同名作品）。
  ///
  /// [library] 指定库归属：`audio` / `image` / `video`。传 null 时按扫描结果
  /// 推断：有音频走音频，否则有图片走图片库，否则走视频库（BUILD_GUIDE 第 18.2 节）。
  ///
  /// 返回 null 表示没有导入：已有别的导入在跑，目录里没有可导入的媒体，
  /// 或者这批媒体都已经在库里。目录里没有新媒体时不建作品，避免留下空作品。
  Future<Work?> importDirectory(String dirPath, {String? library}) async {
    if (!_beginImport('importDirectory')) return null;
    try {
      final scan = await FileScanner.scanDirectoryOffThread(dirPath);
      if (scan.isEmpty) {
        logWarn('AppState', '目录内没有可导入的媒体，未创建作品: $dirPath');
        return null;
      }
      final lib = library ?? _libraryForScan(scan);
      if (lib != 'audio') return await _importVisualWork(dirPath, lib, scan);
      if (scan.audioPaths.isEmpty) {
        logWarn('AppState', '目录内无音频，未创建作品: $dirPath');
        return null;
      }
      if (!await _hasNewAudio(scan)) {
        logWarn('AppState', '目录内音频均已导入，未创建作品: $dirPath');
        return null;
      }

      final work = await _workDao.create(_baseName(dirPath));
      final imported = await _runImport(dirPath, work.id!, scan: scan);
      if (imported == 0) {
        // 一条都没落库就删掉刚建的作品：可能是并发插入被 UNIQUE 忽略，
        // 也可能是这次导入直接失败（建树失败时曲目还没开始写，所以也是 0）。
        // 失败原因留在 importState 里给界面显示。
        final why = importState.error ?? '没有新曲目落库';
        logWarn('AppState', '导入没有落库（$why），删除空作品: ${work.name}');
        await _workDao.delete(work.id!);
        return null;
      }
      return work;
    } finally {
      _endImport();
    }
  }

  /// 按扫描结果推断库归属。
  ///
  /// 优先级：音频 > 多媒体。目录里只要有音频，走音频栏那套导入（时长、内嵌封面、
  /// 字幕配对都在那里做）；纯图片与视频目录归多媒体库。
  static String _libraryForScan(ScanResult scan) {
    if (scan.audioPaths.isNotEmpty) return 'audio';
    return 'media';
  }

  /// 多媒体库要落行的文件：图片与视频一起。音频走 [ImportService]，因为时长、
  /// 内嵌封面与字幕配对都在那条链上。
  static List<String> _visualPaths(ScanResult scan) => <String>[
    ...scan.imagePaths,
    ...scan.videoPaths,
  ];

  /// 新建一个多媒体作品，把扫描到的图片、视频与音频一起落库并挂上虚拟文件夹。
  ///
  /// 图片与视频直接写 media 表；音频交给 [ImportService]，这样时长、内嵌封面、
  /// 字幕配对与音频栏一致。同一个目录两条链都跑，作品与文件夹共用一份。
  Future<Work?> _importVisualWork(
    String dirPath,
    String library,
    ScanResult scan,
  ) async {
    final visualPaths = _visualPaths(scan);
    final paths = <String>[...visualPaths, ...scan.audioPaths];
    if (paths.isEmpty) {
      logWarn('AppState', '$library 库没有可导入的文件: $dirPath');
      return null;
    }
    final existing = await _mediaDao.existingPaths(paths);
    if (existing.length == paths.length) {
      logWarn('AppState', '目录内媒体均已导入，未创建作品: $dirPath');
      return null;
    }
    final work = await _workDao.create(_baseName(dirPath), library: library);
    var imported = 0;
    if (visualPaths.isNotEmpty) {
      imported += await _runVisualImport(
        dirPath,
        work.id!,
        library,
        visualPaths,
      );
    }
    if (scan.audioPaths.isNotEmpty) {
      imported += await _runImport(
        dirPath,
        work.id!,
        scan: scan,
        library: library,
      );
    }
    if (imported == 0) {
      final why = importState.error ?? '没有新条目落库';
      logWarn('AppState', '导入没有落库（$why），删除空作品: ${work.name}');
      await _workDao.delete(work.id!);
      return null;
    }
    return work;
  }

  /// 把图片与视频写进 media 表，并在目标库下建/复用虚拟文件夹。
  Future<int> _runVisualImport(
    String dirPath,
    int workId,
    String library,
    List<String> paths,
  ) async {
    var imported = 0;
    final freshPaths = <String>[];
    try {
      final existing = await _mediaDao.existingPaths(paths);
      final now = DateTime.now().millisecondsSinceEpoch;
      final rows = <Map<String, Object?>>[];
      for (final path in paths) {
        if (existing.contains(path)) continue;
        freshPaths.add(path);
        var size = 0;
        var mtime = 0;
        try {
          final stat = File(path).statSync();
          size = stat.size;
          mtime = stat.modified.millisecondsSinceEpoch;
        } catch (e) {
          // 读不到 stat 不影响入库：尺寸与时间留 0，路径照样能用。
          logWarn('AppState', 'stat 失败 "$path": $e');
        }
        rows.add({
          'path': path,
          // 落到多媒体作品里的行按文件自己的类型写，[library] 只决定作品与文件夹
          // 的归属。这样图片、视频、音频在同一个目录里也能各算各的类型。
          'media_type': mediaTypeOfPath(path) ?? library,
          'ext': extOfPath(path),
          'name_lower': nameLowerOfPath(path),
          'filename': baseNameOfPath(path),
          'file_size': size,
          'file_mtime': mtime,
          'added_at': now,
          'sort_key': sortKeyOfPath(path),
        });
      }
      imported = await _mediaDao.insertRows(rows);
      // 目录本身挂成一个虚拟文件夹，ensureByPath 内部会补 folder_paths。
      await _folderDao.ensureByPath(
        dirPath,
        name: _baseName(dirPath),
        workId: workId,
        library: library,
      );
      logInfo('AppState', '导入落库 $imported 条（扫描 ${paths.length} 条）: $dirPath');
    } catch (e) {
      importState.fail(e);
      logError('AppState', '导入失败', e.toString());
    } finally {
      importState.reportProgress(imported > 0 ? 1.0 : 0.0);
      _bumpFolderVersion();
      await refresh();
    }
    // README 承诺「缩略图进库时后台补齐」：这里接着补，不占导入的关键路径。
    // 只有图片值得生成缩略图，音频路径进来只会解码失败再记一条日志。
    final imagePaths = freshPaths
        .where((path) => imageExtensions.contains(extOfPath(path)))
        .toList();
    if (imported > 0 && imagePaths.isNotEmpty) {
      unawaited(backfillThumbnails(imagePaths));
    }
    return imported;
  }

  /// 已经排进补齐队列的路径，避免同一批被反复排队。
  final List<String> _thumbBackfillQueue = <String>[];

  /// 与队列同步的集合，用来 O(1) 判重。
  ///
  /// 队列从前只有 List：`contains` 判重要扫全表，`removeAt(0)` 出队要把后面
  /// 的元素整体前移。5000 张缩略图，两边各自都是一千两百多万次操作。
  final Set<String> _thumbBackfillPending = <String>{};

  bool _thumbBackfillRunning = false;

  /// 在后台把 [paths] 的 300px 缩略图逐张补齐（已存在就跳过）。
  ///
  /// 进库时同步生成会把导入卡住（几百张原图解码很久），所以导入一结束就把
  /// 新路径丢进来异步跑。补齐过程只推进进度，不动 [thumbEpoch]：可见卡片
  /// 自己会在生成完成后刷新，整屏重置只会造成闪烁。
  Future<void> backfillThumbnails(Iterable<String> paths) async {
    var added = 0;
    for (final path in paths) {
      if (path.isNotEmpty && _thumbBackfillPending.add(path)) {
        _thumbBackfillQueue.add(path);
        added++;
      }
    }
    if (added == 0) return;
    if (_thumbBackfillRunning) {
      _thumbBackfillTotal += added;
      return;
    }
    final service = ThumbnailService.instance;
    _thumbBackfillRunning = true;
    _thumbBackfillTotal = _thumbBackfillQueue.length;
    _thumbBackfillDone = 0;
    _thumbBackfillLastNotify = null;
    var generated = 0;
    try {
      while (_thumbBackfillQueue.isNotEmpty) {
        // 从尾部取：补齐顺序对用户没有意义，而 removeLast 是 O(1)。
        final path = _thumbBackfillQueue.removeLast();
        _thumbBackfillPending.remove(path);
        try {
          final file = File(service.thumbPath(path, size: 300));
          if (!await file.exists()) {
            await service.ensureThumbnail(path, size: 300);
            generated++;
          }
        } catch (e) {
          logDebug('AppState', '缩略图补齐失败 "$path": $e');
        } finally {
          _thumbBackfillDone++;
          _maybeNotifyThumbBackfill();
        }
      }
    } finally {
      _thumbBackfillRunning = false;
      if (generated > 0) {
        logInfo('AppState', '缩略图后台补齐 $generated 张');
      }
      notifyListeners();
    }
  }

  /// 补齐进度按 [_thumbBackfillNotifyGap] 节流，避免每张图都重建整屏。
  void _maybeNotifyThumbBackfill() {
    final now = DateTime.now();
    final last = _thumbBackfillLastNotify;
    if (last != null && now.difference(last) < _thumbBackfillNotifyGap) {
      return;
    }
    _thumbBackfillLastNotify = now;
    notifyListeners();
  }

  /// 导入目录到指定作品（合并）
  /// 从作品目录里挑一张图当封面，并把封面文件写进作品根目录。
  ///
  /// 回退链在 `lib/services/cover_finder.dart`：根目录白名单、信号目录、
  /// 根目录任意图、整棵子树按打分。已经有封面的作品不动，返回提示。
  Future<String?> findLocalCoverForWork(int workId) async {
    final work = await _workDao.getById(workId);
    final root = work?.rootPath;
    if (root == null || root.trim().isEmpty) {
      return '这部作品没有登记目录，找不了封面';
    }
    if (work!.coverPath != null && work.coverPath!.trim().isNotEmpty) {
      return '这部作品已经有封面了';
    }
    final code = parseWorkCode(p.basename(root))?.code;
    final written = await CoverFinder().fetchAndWrite(root, code: code);
    if (written == null) return '这个目录里没找到能当封面的图片';
    await _workDao.setCover(workId, written);
    await refresh();
    return null;
  }

  /// 以磁盘为准重扫音频作品：补新文件、删失联行。
  ///
  /// 刷新按钮走这条，普通 `refresh()` 不走：库可能有几千条路径，逐条 stat 不能
  /// 挂在每次界面刷新上。传 [workIds] 时只重扫这几部（作品层批量刷新）。
  /// 返回给界面弹提示用的计数。
  Future<RescanOutcome> rescanFromDisk({Iterable<int>? workIds}) async {
    final wanted = workIds?.toSet();
    final works = await _workDao.listAll();
    var added = 0;
    var removed = 0;
    var missingRoots = 0;
    for (final work in works) {
      if (wanted != null && !wanted.contains(work.id)) continue;
      final outcome = await _rescanOneWork(work);
      added += outcome.added;
      removed += outcome.removed;
      if (outcome.missingRoots > 0) missingRoots++;
    }
    logInfo('AppState', '重扫磁盘：新增 $added 条，删除失联 $removed 条，缺目录 $missingRoots 个');
    return RescanOutcome(
      added: added,
      removed: removed,
      missingRoots: missingRoots,
    );
  }

  /// 重扫一部作品：补磁盘上多出来的音频行，删库里已失联的行。
  Future<RescanOutcome> _rescanOneWork(Work work) async {
    final root = work.rootPath?.trim();
    if (work.library != 'audio' || root == null || root.isEmpty) {
      return const RescanOutcome(added: 0, removed: 0, missingRoots: 0);
    }
    if (!await Directory(root).exists()) {
      return const RescanOutcome(added: 0, removed: 0, missingRoots: 1);
    }
    var added = 0;
    var removed = 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    final rows = <Map<String, Object?>>[];
    await for (final entity in Directory(
      root,
    ).list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final path = entity.path;
      if (!audioExtensions.contains(extOfPath(path))) continue;
      final fileName = baseNameOfPath(path);
      rows.add({
        'path': path,
        'media_type': MediaType.audio.value,
        'filename': fileName,
        'title': trackTitle(fileName),
        'added_at': now,
        'sort_key': sortKeyOfPath(path),
      });
    }
    if (rows.isNotEmpty) added += await _mediaDao.insertRows(rows);
    // 失联行：库里登记在这部作品下、磁盘上已经没有的音频
    final existing = await _mediaDao.queryByDirs([root], type: MediaType.audio);
    final stale = <String>[];
    for (final item in existing) {
      if (!await File(item.path).exists()) stale.add(item.path);
    }
    removed += await _mediaDao.deleteByPaths(stale, type: MediaType.audio);
    return RescanOutcome(added: added, removed: removed, missingRoots: 0);
  }

  /// 批量删除选中的作品（只删库里的记录与文件夹，不动磁盘文件）。
  Future<int> deleteWorks(Iterable<int> workIds) async {
    var deleted = 0;
    for (final id in workIds.toSet()) {
      deleted += await deleteWorkDeep(id);
    }
    clearWorkSelection();
    await refresh();
    logInfo('AppState', '批量删除作品 ${workIds.length} 部，媒体记录 $deleted 条');
    return deleted;
  }

  /// 批量刷新选中的作品：以磁盘为准补新文件、清理失联行。
  Future<RescanOutcome> rescanWorks(Iterable<int> workIds) async {
    final outcome = await rescanFromDisk(workIds: workIds);
    await refresh();
    return outcome;
  }

  /// 批量给作品下的全部媒体加标签。返回实际作用的媒体条数。
  Future<int> addTagsToWorks(Iterable<int> workIds, List<Tag> list) async {
    final ids = <int>{};
    for (final workId in workIds) {
      ids.addAll(await mediaIdsUnderWork(workId));
    }
    if (ids.isEmpty) return 0;
    await addTagsToMedia(ids, list);
    return ids.length;
  }

  /// 批量移除作品标签。返回实际作用的媒体条数。
  Future<int> removeTagsFromWorks(Iterable<int> workIds, List<Tag> list) async {
    final ids = <int>{};
    for (final workId in workIds) {
      ids.addAll(await mediaIdsUnderWork(workId));
    }
    if (ids.isEmpty) return 0;
    await removeTagsFromMedia(ids, list);
    return ids.length;
  }

  /// 把选中的作品排进 DLsite 批量抓取队列。
  void enqueueDlsiteScrape(Iterable<int> workIds) =>
      dlsite.enqueueScrape(workIds);

  /// 给一部作品抓 DLsite 元数据并直接落库。
  ///
  /// 编号优先按作品目录名解析，目录名没有再看库里登记过的编号。抓不到时返回
  /// 带说明的结果，不抛异常，界面直接拿去弹提示。
  Future<DlsiteFetchResult> fetchDlsiteMetadata(
    int workId, {
    bool applyCover = false,
  }) => dlsite.fetch(workId, applyCover: applyCover);

  /// 只抓取不落标签，给预览对话框看。
  Future<DlsiteFetchResult> previewDlsiteMetadata(int workId) =>
      dlsite.preview(workId);

  /// 手动登记作品编号；返回规范化后的编号，格式不对返回 null。
  Future<String?> setDlsiteCode(int workId, String input) =>
      dlsite.setManualCode(workId, input);

  /// 用户在预览里确认后应用元数据，[applyCover] 时把封面也换成远程图。
  Future<DlsiteFetchResult> applyDlsiteMetadata(
    int workId,
    DlsiteWork work, {
    bool applyCover = false,
  }) => dlsite.apply(workId, work, applyCover: applyCover);

  /// 下载远程封面并设为作品封面，返回本地路径；失败抛 [DlsiteImageException]。
  Future<String> downloadDlsiteCover(int workId, String url) =>
      dlsite.downloadCover(workId, url);

  /// 作品的 DLsite 元数据（简介、社团、系列、发售日），界面详情用。
  Future<WorkMetadata?> workMetadata(int workId) => dlsite.metadataOf(workId);

  /// 同步读已预取的元数据（详情头用）。
  WorkMetadata? workMetadataSync(int workId) => dlsite.metadataSync(workId);

  /// 同步读已反解的 DLsite 信息（发售日、评分）。
  DlsiteWork? cachedDlsiteWorkSync(int workId) => dlsite.workSync(workId);

  /// 缓存里的完整 DLsite 作品信息（发售日、评分），不联网。
  Future<DlsiteWork?> cachedDlsiteWork(int workId) => dlsite.cachedWork(workId);

  /// 从一个根目录一次性导入多部作品（每部作品一个子目录）。
  ///
  /// 只扫描不落库，给界面先弹预览用。
  Future<ImportPlan> scanWorksRoot(String rootPath, {bool nested = false}) =>
      scanImportTree(rootPath, nested: nested);

  /// 执行一次性导入：落库后刷新列表。
  ///
  /// 与普通导入共用 [_beginImport] 的互斥标志，避免和扫描任务同时改库。
  Future<ImportOutcome?> importWorksFromRoot(
    String rootPath, {
    bool nested = false,
  }) async {
    if (!_beginImport('importWorksFromRoot')) return null;
    try {
      final plan = await scanImportTree(rootPath, nested: nested);
      final outcome = await PlanImporter(
        DatabaseManager.instance.db,
      ).apply(plan);
      logInfo(
        'AppState',
        '一次性导入：作品 ${outcome.worksCreated} 新建 / ${outcome.worksSkipped} 跳过，'
            '曲目 ${outcome.tracksInserted} 新增 / ${outcome.tracksSkipped} 已存在',
      );
      _autoScrapeNewWorks(outcome);
      await refresh();
      return outcome;
    } finally {
      _endImport();
    }
  }

  /// 设置开着时，把刚导入的作品排进 DLsite 抓取队列。
  void _autoScrapeNewWorks(ImportOutcome outcome) {
    if (!SettingsService.instance.autoScrapeAfterImport) return;
    if (outcome.createdWorkIds.isEmpty) return;
    dlsite.enqueueScrape(outcome.createdWorkIds);
  }

  // ═══════════════ 自动导入 ═══════════════

  /// 启动时是否自动扫描 [autoImportRoots]。
  bool get autoImportEnabled => SettingsService.instance.autoImportEnabled;

  /// 自动导入的根目录列表。每部作品占一个子目录。
  List<String> get autoImportRoots => SettingsService.instance.autoImportRoots;

  /// 第一个根目录，兼容旧调用点。
  String? get autoImportRoot => SettingsService.instance.autoImportRoot;

  /// 用户标记为「不要导入」的目录。
  List<String> get autoImportIgnored =>
      SettingsService.instance.autoImportIgnored;

  /// 上一次自动导入的时间（毫秒时间戳）。没跑过为 null。
  int? get lastAutoImportAt => SettingsService.instance.lastAutoImportAt;

  bool get autoScrapeAfterImport =>
      SettingsService.instance.autoScrapeAfterImport;

  Future<void> setAutoScrapeAfterImport(bool enabled) async {
    await SettingsService.instance.setAutoScrapeAfterImport(enabled);
    notifyListeners();
  }

  /// 抓 DLsite 用的 HTTP 代理，空串表示直连。传输层每次请求时现读。
  String get dlsiteProxy => SettingsService.instance.dlsiteProxy;

  Future<void> setDlsiteProxy(String proxy) async {
    await SettingsService.instance.setDlsiteProxy(proxy);
    notifyListeners();
  }

  Future<void> setAutoImportEnabled(bool enabled) async {
    await SettingsService.instance.setAutoImportEnabled(enabled);
    notifyListeners();
  }

  Future<void> setAutoImportRoot(String? root) async {
    await SettingsService.instance.setAutoImportRoot(root);
    notifyListeners();
  }

  Future<void> addAutoImportRoot(String root) async {
    await SettingsService.instance.addAutoImportRoot(root);
    notifyListeners();
  }

  Future<void> removeAutoImportRoot(String root) async {
    await SettingsService.instance.removeAutoImportRoot(root);
    notifyListeners();
  }

  Future<void> setAutoImportIgnored(Iterable<String> dirs) async {
    await SettingsService.instance.setAutoImportIgnored(dirs);
    notifyListeners();
  }

  Future<void> clearAutoImportIgnored() => setAutoImportIgnored(const []);

  /// 扫一遍所有根目录，返回待确认的候选。只读，不落库。
  Future<List<AutoImportCandidate>> scanAutoImportCandidates() {
    return AutoImportScanner(
      DatabaseManager.instance.db,
    ).scan(roots: autoImportRoots, ignored: autoImportIgnored);
  }

  /// 落库用户勾选的候选：新建作品走导入计划，有新文件的作品走按盘刷新。
  ///
  /// 没有任何可导入项时返回空结果；导入闸门被占时返回 null。
  Future<ImportOutcome?> applyAutoImportCandidates(
    Iterable<AutoImportCandidate> candidates,
  ) async {
    final selected = candidates.where((c) => c.selectable).toList();
    if (selected.isEmpty) return const ImportOutcome();
    if (!_beginImport('applyAutoImportCandidates')) return null;
    try {
      var created = 0;
      var skipped = 0;
      var inserted = 0;
      var insertedSkipped = 0;
      final createdIds = <int>[];
      for (final c in selected) {
        if (c.state == AutoImportState.newWork) {
          final work = await planImportWork(c.dirPath);
          if (work == null) {
            skipped++;
            continue;
          }
          final outcome = await PlanImporter(
            DatabaseManager.instance.db,
          ).apply(ImportPlan(rootPath: c.dirPath, works: [work]));
          created += outcome.worksCreated;
          skipped += outcome.worksSkipped;
          inserted += outcome.tracksInserted;
          insertedSkipped += outcome.tracksSkipped;
          createdIds.addAll(outcome.createdWorkIds);
        } else if (c.state == AutoImportState.newTracks && c.workId != null) {
          final work = await _workDao.getById(c.workId!);
          if (work == null) {
            skipped++;
            continue;
          }
          final rescan = await _rescanOneWork(work);
          inserted += rescan.added;
        }
      }
      if (created > 0 || inserted > 0) {
        await SettingsService.instance.setLastAutoImportAt(
          DateTime.now().millisecondsSinceEpoch,
        );
      }
      await refresh();
      logInfo('AppState', '确认导入：新建 $created 部，新增 $inserted 首，跳过 $skipped 部');
      if (createdIds.isNotEmpty &&
          SettingsService.instance.autoScrapeAfterImport) {
        dlsite.enqueueScrape(createdIds);
      }
      return ImportOutcome(
        worksCreated: created,
        worksSkipped: skipped,
        tracksInserted: inserted,
        tracksSkipped: insertedSkipped,
        createdWorkIds: createdIds,
      );
    } finally {
      _endImport();
    }
  }

  /// 按设置里的所有根目录导一次。没配目录、目录都不存在或已有导入在跑都返回 null。
  ///
  /// 与手动「导入目录」走同一条 [importWorksFromRoot] 路径，已存在的作品
  /// 与曲目按跳过处理，所以可以每次启动都跑。
  Future<ImportOutcome?> autoImportFromRoot() async {
    final roots = autoImportRoots;
    if (roots.isEmpty) return null;
    var created = 0;
    var skipped = 0;
    var inserted = 0;
    var tracksSkipped = 0;
    var ran = false;
    for (final root in roots) {
      if (!await Directory(root).exists()) {
        logWarn('AppState', '自动导入目录不存在，跳过：$root');
        continue;
      }
      final outcome = await importWorksFromRoot(root);
      if (outcome == null) continue;
      ran = true;
      created += outcome.worksCreated;
      skipped += outcome.worksSkipped;
      inserted += outcome.tracksInserted;
      tracksSkipped += outcome.tracksSkipped;
    }
    if (!ran) return null;
    await SettingsService.instance.setLastAutoImportAt(
      DateTime.now().millisecondsSinceEpoch,
    );
    notifyListeners();
    return ImportOutcome(
      worksCreated: created,
      worksSkipped: skipped,
      tracksInserted: inserted,
      tracksSkipped: tracksSkipped,
    );
  }

  /// 启动时调用一次。开关关着时什么都不做。
  Future<ImportOutcome?> autoImportOnStartup() async {
    if (!autoImportEnabled) return null;
    final outcome = await autoImportFromRoot();
    if (outcome != null) {
      logInfo(
        'AppState',
        '启动自动导入：新建 ${outcome.worksCreated} 部，'
            '新增 ${outcome.tracksInserted} 首',
      );
    }
    return outcome;
  }

  Future<void> importDirectoryIntoWork(String dirPath, int workId) async {
    if (!_beginImport('importDirectoryIntoWork')) return;
    try {
      final work = await _workDao.getById(workId);
      final scan = await FileScanner.scanDirectoryOffThread(dirPath);
      if (work != null && work.library != 'audio') {
        final paths = _visualPaths(scan);
        if (paths.isNotEmpty) {
          await _runVisualImport(dirPath, workId, work.library, paths);
        }
        if (scan.audioPaths.isNotEmpty) {
          await _runImport(dirPath, workId, scan: scan, library: work.library);
        }
        return;
      }
      await _runImport(dirPath, workId);
    } finally {
      _endImport();
    }
  }

  /// 是否至少有一首曲目还没入库。
  Future<bool> _hasNewAudio(ScanResult scan) async {
    final existing = await _trackDao.existingPaths(scan.audioPaths);
    return existing.length < scan.audioPaths.length;
  }

  /// 同步置位导入标志，返回 false 表示本次请求被拒。
  ///
  /// 标志必须在第一个 await 之前置上：两次导入同时进来时，第二次要在这里就被挡住，
  /// 不能等 `_runImport` 里再判断。
  bool _beginImport(String caller) {
    if (_migrating) {
      logInfo('AppState', '数据目录迁移中，拒绝导入: $caller');
      return false;
    }
    if (!importState.begin(caller)) return false;
    notifyListeners();
    return true;
  }

  void _endImport() {
    importState.end();
    notifyListeners();
  }

  /// 真正干活的部分。调用方负责用 [_beginImport] / [_endImport] 圈住导入期。
  /// 返回处理过的新曲目数，0 表示这次导入没有新增内容。
  Future<int> _runImport(
    String dirPath,
    int workId, {
    ScanResult? scan,
    String library = 'audio',
  }) async {
    var imported = 0;
    try {
      final importService = ImportService.fromDB();
      final stream = importService.importDirectory(
        dirPath,
        workId: workId,
        scan: scan,
        library: library,
      );
      // 导入流按文件吐进度。逐条 notifyListeners 会让整页重建上千次，
      // 进度条却看不出差别，所以按 1% 粒度通知。
      final throttle = ProgressThrottle();
      await for (final p in stream) {
        imported++;
        importState.reportProgress(p.percent);
        if (throttle.shouldNotify(p.percent)) notifyListeners();
      }
    } catch (e) {
      importState.fail(e);
      logError('AppState', '导入失败', e.toString());
    } finally {
      notifyListeners();
      _bumpFolderVersion();
      await refresh();
      await enforceCoverCacheLimit();
    }
    return imported;
  }

  String _baseName(String path) {
    final idx = path.lastIndexOf(RegExp(r'[\\/]'));
    final base = idx >= 0 ? path.substring(idx + 1) : path;
    return base.isEmpty ? path : base;
  }

  // ═══════════════ 卷封面（转发到 CoverState）═══════════════

  /// 卷封面或裁剪改动后自增，界面据此重新读取封面。
  int get coverVersion => covers.coverVersion;

  Future<List<VolumeCoverCandidate>> volumeCoverCandidates(int folderId) =>
      covers.volumeCoverCandidates(folderId);

  Future<String?> volumeCover(int folderId) => covers.volumeCover(folderId);

  Future<void> setVolumeCover(int folderId, String? path) =>
      covers.setVolumeCover(folderId, path);

  Future<Rect?> volumeCoverCrop(int folderId) =>
      covers.volumeCoverCrop(folderId);

  Future<void> setVolumeCoverCrop(int folderId, Rect? crop) =>
      covers.setVolumeCoverCrop(folderId, crop);

  Future<void> setVolumeCoverWithCrop(int folderId, String? path, Rect? crop) =>
      covers.setVolumeCoverWithCrop(folderId, path, crop);

  // ═══════════════ 字幕归属（BUILD_GUIDE 第 18.5、23.6 节）═══════════════

  SubtitleService get _subtitleService =>
      SubtitleService(DatabaseManager.instance.db);

  /// 某条音频名下的字幕，默认项排在最前（第 23.6 节的三级顺序）。
  Future<List<SubtitleEntry>> subtitleEntriesFor(int audioId) =>
      _subtitleService.listForAudio(audioId);

  /// 这条音频该显示哪条字幕。没有归属关系时返回 null。
  Future<SubtitleEntry?> defaultSubtitleFor(int audioId) =>
      _subtitleService.defaultFor(audioId);

  /// 还没归属任何音频的字幕行，供「手动指定归属」用。
  Future<List<SubtitleEntry>> unassignedSubtitles() =>
      _subtitleService.listUnassigned();

  /// 把某条字幕设为它所属音频的默认项。
  Future<void> setDefaultSubtitle(int subtitleId) async {
    await _subtitleService.setDefault(subtitleId);
    _subtitleCache.clear();
    notifyListeners();
  }

  /// 手动指定字幕归属某个音频，并把它设为默认项。
  Future<void> attachSubtitleToAudio(int subtitleId, int audioId) async {
    await _subtitleService.attach(subtitleId, audioId);
    _subtitleCache.clear();
    notifyListeners();
  }

  Future<void> detachSubtitle(int subtitleId) async {
    await _subtitleService.detach(subtitleId);
    _subtitleCache.clear();
    notifyListeners();
  }

  // ═══════════════ 系列与卷导入（BUILD_GUIDE 第 19.5 节）═══════════════

  /// 按系列导入：选中的目录是系列，其下每个含音频的一级子目录各成一卷。
  ///
  /// 没有含音频的一级子目录时，目录自己就是唯一那一卷。导入根那一层不单独建
  /// 文件夹，所以树里不会多出一层（第 19.5 节）。
  Future<Work?> importSeries(String dirPath) async {
    if (!_beginImport('importSeries')) return null;
    try {
      final children = await _audioChildDirs(dirPath);
      if (children.isEmpty) {
        final scan = await FileScanner.scanDirectoryOffThread(dirPath);
        if (scan.audioPaths.isEmpty) {
          logWarn('AppState', '目录内无音频，未创建系列: $dirPath');
          return null;
        }
        final work = await _workDao.create(
          _baseName(dirPath),
          library: 'audio',
        );
        final imported = await _runImport(dirPath, work.id!, scan: scan);
        if (imported == 0) {
          logWarn('AppState', '系列导入没有新曲目，删除空系列: ${work.name}');
          await _workDao.delete(work.id!);
          return null;
        }
        await _tagBonusDirs(dirPath);
        return work;
      }

      final work = await _workDao.create(_baseName(dirPath), library: 'audio');
      var imported = 0;
      for (final child in children) {
        final volume = await _folderDao.ensureByPath(
          child,
          name: _baseName(child),
          workId: work.id!,
          library: 'audio',
        );
        imported += await _runImport(child, work.id!);
        await _tagBonusDirs(child);
        logInfo('AppState', '系列卷导入: ${volume.name}（$child）');
      }
      if (imported == 0) {
        logWarn('AppState', '系列内没有新曲目，删除空系列: ${work.name}');
        await _workDao.delete(work.id!);
        return null;
      }
      return work;
    } catch (e) {
      importState.fail(e);
      logError('AppState', '系列导入失败', e.toString());
      return null;
    } finally {
      _endImport();
    }
  }

  /// 直接子目录里含音频的那些，按名字自然序。
  Future<List<String>> _audioChildDirs(String dirPath) async {
    final dir = Directory(dirPath);
    if (!await dir.exists()) return const <String>[];
    final hits = <String>[];
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is! Directory) continue;
      final scan = await FileScanner.scanDirectoryOffThread(entity.path);
      if (scan.audioPaths.isNotEmpty) hits.add(entity.path);
    }
    hits.sort((a, b) => naturalCompare(_baseName(a), _baseName(b)));
    return hits;
  }

  /// 批量导入：选一个父目录，每个含媒体的直接子目录各建一个作品。
  ///
  /// 音频库有「导入系列」（子目录当成同一个作品的各卷），图片/视频库以前只能
  /// 一个目录一个作品地导入；这里补上批量做法：一个子目录 = 一个作品。子目录
  /// 都没有该库媒体时退回按单目录导入。返回新建的作品数。
  Future<int> importSubdirectoriesAsWorks(
    String dirPath, {
    String? library,
  }) async {
    if (!_beginImport('importSubdirectoriesAsWorks')) return 0;
    var created = 0;
    try {
      final scan = await FileScanner.scanDirectoryOffThread(dirPath);
      final lib = library ?? _libraryForScan(scan);
      if (lib == 'audio') {
        logWarn('AppState', '音频库请用「导入系列」把子目录当成卷: $dirPath');
        return 0;
      }
      final children = await _childDirsWithMedia(dirPath);
      if (children.isEmpty) {
        logInfo('AppState', '子目录里没有 $lib 媒体，按单目录导入: $dirPath');
        final work = await _importVisualWork(dirPath, lib, scan);
        return work == null ? 0 : 1;
      }
      for (final child in children) {
        final childScan = await FileScanner.scanDirectoryOffThread(child);
        if (childScan.isEmpty) continue;
        final work = await _importVisualWork(child, lib, childScan);
        if (work != null) {
          created++;
          logInfo('AppState', '批量导入子目录: ${_baseName(child)}（$child）');
        }
      }
      logInfo('AppState', '批量导入完成：子目录 ${children.length} 个，新建作品 $created 个');
    } catch (e) {
      importState.fail(e);
      logError('AppState', '批量导入失败', e.toString());
    } finally {
      _endImport();
    }
    return created;
  }

  /// 直接子目录里含媒体（图片、视频或音频）的那些，按名字自然序。
  ///
  /// 多媒体栏的作品也收音频，所以子目录只放音频时同样算「有内容」。
  Future<List<String>> _childDirsWithMedia(String dirPath) async {
    final dir = Directory(dirPath);
    if (!await dir.exists()) return const <String>[];
    final hits = <String>[];
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is! Directory) continue;
      final scan = await FileScanner.scanDirectoryOffThread(entity.path);
      final paths = <String>[
        ...scan.imagePaths,
        ...scan.videoPaths,
        ...scan.audioPaths,
      ];
      if (paths.isNotEmpty) hits.add(entity.path);
    }
    hits.sort((a, b) => naturalCompare(_baseName(a), _baseName(b)));
    return hits;
  }

  /// 把特典子目录（特典 / SP / Bonus）里的条目打上「特典」标签（第 19.3 节）。
  ///
  /// 只在导入那一次调用；用户可以随后自己删掉标签。返回新打标的条目数。
  Future<int> _tagBonusDirs(String rootPath) async {
    final dirs = <String>[];
    final root = Directory(rootPath);
    if (!await root.exists()) return 0;
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is Directory && isBonusDirName(p.basename(entity.path))) {
        dirs.add(entity.path);
      }
    }
    if (dirs.isEmpty) return 0;

    final tag = await _ensureBonusTag();
    if (tag?.id == null) return 0;

    var tagged = 0;
    for (final dir in dirs) {
      final rows = await _mediaDao.queryByDirs([dir]);
      for (final row in rows) {
        if (row.mediaType == MediaType.subtitle) continue;
        await _tagDao.addTagToTrack(row.id!, tag!.id!);
        tagged++;
      }
    }
    if (tagged > 0) {
      logInfo('AppState', '特典目录自动打标 $tagged 条（$rootPath）');
    }
    return tagged;
  }

  /// 「特典」是普通标签，没有就先建出来。
  Future<Tag?> _ensureBonusTag() async {
    final existing = await _tagDao.getByFullName('general', bonusTagName);
    if (existing != null) return existing;
    return _tagDao.insert(const Tag(name: bonusTagName));
  }

  /// 特典标签名（第 19.3 节）
  static const String bonusTagName = '特典';

  // ═══════════════ 标签（转发到 TagState）═══════════════

  List<Tag> get allTags => tags.allTags;
  Set<int> get activeTagIds => tags.activeTagIds;
  Set<String> get collapsedNamespaces => tags.collapsedNamespaces;
  bool isNamespaceCollapsed(String namespace) =>
      tags.isNamespaceCollapsed(namespace);
  void toggleNamespaceCollapsed(String namespace) =>
      tags.toggleNamespaceCollapsed(namespace);
  void setAllNamespacesCollapsed(bool collapsed) =>
      tags.setAllNamespacesCollapsed(collapsed);
  List<String> get knownNamespaces => tags.knownNamespaces;
  Future<void> loadTags() => tags.load();
  Future<List<Tag>> getTrackTags(int trackId) => tags.getTrackTags(trackId);
  Future<List<Tag>> getImageTags(int imageId) => tags.getImageTags(imageId);
  Future<List<Tag>> getTagsForMedia(int mediaId) =>
      tags.getTagsForMedia(mediaId);
  Future<List<Tag>> getFolderTags(int folderId) => tags.getFolderTags(folderId);
  Future<({int media, int folders})> tagUsageCounts(int tagId) =>
      tags.tagUsageCounts(tagId);
  Tag? findTagByName(String name, {String? namespace}) =>
      tags.findTagByName(name, namespace: namespace);

  /// 规则标签由软件按扩展名或媒体类型自动补行，删掉下次启动还会回来。
  static bool isRuleTag(Tag tag) =>
      TagDao.ruleNamespaces.contains(tag.namespace);

  Future<void> toggleTagOnTrack(int trackId, Tag tag) =>
      tags.toggleTagOnTrack(trackId, tag);
  Future<void> toggleTagOnImage(int imageId, Tag tag) =>
      tags.toggleTagOnImage(imageId, tag);
  Future<void> addTagToFolder(int folderId, Tag tag) =>
      tags.addTagToFolder(folderId, tag);
  Future<void> addTagsToFolder(
    int folderId,
    List<Tag> list, {
    bool recursive = false,
  }) => tags.addTagsToFolder(folderId, list, recursive: recursive);
  Future<void> removeTagsFromFolder(
    int folderId,
    List<Tag> list, {
    bool recursive = false,
  }) => tags.removeTagsFromFolder(folderId, list, recursive: recursive);
  Future<Set<int>> collectFolderTrackIds(int folderId) =>
      tags.collectFolderTrackIds(folderId);
  Future<void> addTagsToTracks(Iterable<int> trackIds, List<Tag> list) =>
      tags.addTagsToTracks(trackIds, list);
  Future<void> removeTagsFromTracks(Iterable<int> trackIds, List<Tag> list) =>
      tags.removeTagsFromTracks(trackIds, list);
  Future<Set<int>> getTagIdsOnTracks(Iterable<int> trackIds) =>
      tags.getTagIdsOnTracks(trackIds);
  Future<Tag> createTag(
    String name, {
    String namespace = '',
    String color = '#cba6f7',
  }) => tags.createTag(name, namespace: namespace, color: color);
  Future<void> deleteTag(int tagId) => tags.deleteTag(tagId);
  Future<void> updateTag(
    int tagId,
    String name, {
    String? namespace,
    String? color,
  }) => tags.updateTag(tagId, name, namespace: namespace, color: color);

  // 图片与视频的批量标签：媒体行统一写 `media_tags`，接口名保留旧写法。
  Future<void> addTagsToImages(Iterable<int> mediaIds, List<Tag> list) =>
      tags.addTagsToImages(mediaIds, list);
  Future<void> removeTagsFromImages(Iterable<int> mediaIds, List<Tag> list) =>
      tags.removeTagsFromImages(mediaIds, list);
  Future<Set<int>> getTagIdsOnImages(Iterable<int> mediaIds) =>
      tags.getTagIdsOnImages(mediaIds);
  Future<void> addTagsToMedia(Iterable<int> mediaIds, List<Tag> list) =>
      tags.addTagsToImages(mediaIds, list);
  Future<void> removeTagsFromMedia(Iterable<int> mediaIds, List<Tag> list) =>
      tags.removeTagsFromImages(mediaIds, list);
  Future<Set<int>> getTagIdsOnMedia(Iterable<int> mediaIds) =>
      tags.getTagIdsOnImages(mediaIds);
  Future<void> setMediaTags(int mediaId, List<Tag> list) =>
      tags.setMediaTags(mediaId, list);

  // 标签筛选
  void toggleAndFilter(int tagId) => tags.toggleAndFilter(tagId);
  void toggleOrFilter(int tagId) => tags.toggleOrFilter(tagId);
  void toggleNotFilter(int tagId) => tags.toggleNotFilter(tagId);
  void clearTagFilters() => tags.clearTagFilters();
  Future<void> setAdvancedFilter(String expression) =>
      tags.setAdvancedFilter(expression);
  Future<void> clearAdvancedFilter() => tags.clearAdvancedFilter();

  // ═══════════════ 曲目多选 + 批量标签 ═══════════════

  void toggleTrackSelect(int id) => library.toggleSelect(id);

  void rangeTrackSelect(int id) => library.rangeSelect(id);

  /// 长按进入多选模式（移动端）；桌面 Ctrl+点击也可走此路径
  void enterSelectionMode(int id) => library.enterSelection(id);

  void clearTrackSelection() => library.clearSelection();

  /// 只开多选模式，不预先选中任何曲目（工具条的「选择」按钮走这条路）
  void enterTrackSelectionMode() => library.enterSelectionMode();

  /// 选中当前列表里的全部曲目（多选工具条的「全选」）
  void selectAllTracks() => library.selectAll();

  // ═══════════════ 播放 ═══════════════

  /// 播放当前列表从 [startIndex] 开始
  Future<void> playTracks(List<TrackItem> list, int startIndex) =>
      playback.playTracks(list, startIndex);

  Future<void> playAllCurrent() => playback.playAllCurrent();

  /// 把曲目追加进当前播放队列（作品详情的「加入队列」）。
  Future<void> addToPlayQueue(List<TrackItem> tracks) =>
      playback.enqueueTracks(tracks);

  /// 播放某个文件夹（含子文件夹）下的全部曲目
  Future<void> playFolderAll(int folderId) async {
    final paths = <String>[];
    final queue = <int>[folderId];
    while (queue.isNotEmpty) {
      final fid = queue.removeAt(0);
      for (final fp in await _folderDao.getPaths(fid)) {
        paths.add(fp.path);
      }
      for (final c in await _folderDao.listChildren(fid)) {
        if (c.id != null) queue.add(c.id!);
      }
    }
    if (paths.isEmpty) return;
    final tracks = await _trackDao.queryByDirs(paths);
    if (tracks.isEmpty) return;
    await playback.playTracks(tracks, 0);
  }

  /// 播放某个目录下的音频（多媒体栏点音频磁贴走这里）。
  ///
  /// 目录里的音频行组成本目录的专辑队列：先按音频类型取行，排成与网格一致的
  /// 顺序，再换成 TrackItem，与音频栏同源。传 [startMediaId] 就从那一首开始。
  /// 本目录里的音频，按当前排序拍成播放队列（多媒体栏的音频专辑式播放）。
  ///
  /// 图片与视频行不进来：专辑只装音频，双击视频是外链、双击图片是阅读。
  Future<List<TrackItem>> audioQueueInDir(String dirPath) async {
    final rows = await _mediaDao.queryDirectInDir(
      dirPath,
      type: MediaType.audio,
    );
    if (rows.isEmpty) return const <TrackItem>[];
    final ids = _sortImages(rows).map((m) => m.id).whereType<int>().toList();
    if (ids.isEmpty) return const <TrackItem>[];
    final byId = {
      for (final t in await _trackDao.queryByIds(ids.toSet())) t.id: t,
    };
    return <TrackItem>[
      for (final id in ids)
        if (byId[id] != null) byId[id]!,
    ];
  }

  /// [startMediaId] 在队列里的位置；不在队列里（或没指定）就从第一首开始。
  static int queueStartIndex(List<TrackItem> queue, int? startMediaId) {
    if (startMediaId == null) return 0;
    final i = queue.indexWhere((t) => t.id == startMediaId);
    return i < 0 ? 0 : i;
  }

  /// 播放本目录的音频（专辑式），[startMediaId] 指定从哪一首开始。
  Future<void> playAudioInDir(String dirPath, {int? startMediaId}) async {
    final queue = await audioQueueInDir(dirPath);
    if (queue.isEmpty) return;
    await playback.playTracks(queue, queueStartIndex(queue, startMediaId));
  }

  /// 播放某个作品全部卷下的曲目
  Future<void> playWorkAll(int workId) async {
    final paths = await _folderDao.getPathsByWork(workId);
    if (paths.isEmpty) return;
    final tracks = await _trackDao.queryByDirs(paths);
    if (tracks.isEmpty) return;
    await playback.playTracks(tracks, 0);
  }

  /// 用外部播放器播放这个卷（BUILD_GUIDE 第 24.2 节）
  ///
  /// 推哪些行按卷的归属定：音频卷推音频，多媒体卷只推视频。
  Future<LaunchResult> playFolderExternal(int folderId) async {
    final folder = await _folderDao.getById(folderId);
    final paths = await _collectFolderPaths(folderId);
    final type = _externalType(folder?.library);
    return _launchExternal(folder?.name ?? '播放列表', paths, type);
  }

  /// 用外部播放器播放这个作品下的全部卷
  Future<LaunchResult> playWorkExternal(int workId) async {
    final work = await _workDao.getById(workId);
    final paths = await _folderDao.getPathsByWork(workId);
    final type = _externalType(work?.library);
    return _launchExternal(work?.name ?? '播放列表', paths, type);
  }

  /// 外链播放列表推的行类型：音频作品推音频，其余只推视频。
  static MediaType _externalType(String? library) =>
      library == 'audio' ? MediaType.audio : MediaType.video;

  /// 收集一个卷及其全部子卷的目录路径
  Future<List<String>> _collectFolderPaths(int folderId) async {
    final paths = <String>[];
    final queue = <int>[folderId];
    while (queue.isNotEmpty) {
      final fid = queue.removeAt(0);
      for (final fp in await _folderDao.getPaths(fid)) {
        paths.add(fp.path);
      }
      for (final c in await _folderDao.listChildren(fid)) {
        if (c.id != null) queue.add(c.id!);
      }
    }
    return paths;
  }

  /// 生成 m3u8 并交给系统默认播放器。
  ///
  /// [type] 决定推哪些行：多媒体作品只推视频，音频作品推音频。图片进系统播放
  /// 器没有意义；要求的类型一行都没有时直接失败，让调用方提示用户。
  Future<LaunchResult> _launchExternal(
    String title,
    List<String> dirPaths,
    MediaType type,
  ) async {
    if (dirPaths.isEmpty) return LaunchResult.failed;
    final rows = await _mediaDao.queryByDirs(dirPaths, type: type);
    if (rows.isEmpty) return LaunchResult.failed;
    final dir = await DataDirService.instance.dataDir;
    final writer = PlaylistWriter(outputDir: p.join(dir, 'playlist'));
    final file = await writer.write(
      name: title,
      entries: [
        for (final m in rows)
          PlaylistEntry(
            path: m.path,
            title: m.title ?? m.filename,
            durationMs: m.durationMs,
          ),
      ],
    );
    return _launcher.open(file);
  }

  // ═══════════════ 收藏选段（BUILD_GUIDE 第 24.3 节）═══════════════

  /// 载入当前曲目的选段。没有曲目时清空列表。
  Future<void> reloadSegments() => playback.reloadSegments();

  /// 保存一段选区。起止按当前曲目时长收口。
  Future<MediaSegment?> addSegment({
    required int startMs,
    required int endMs,
    String? name,
  }) => playback.addSegment(startMs: startMs, endMs: endMs, name: name);

  Future<void> renameSegment(MediaSegment seg, String? name) =>
      playback.renameSegment(seg, name);

  /// 删除一段。删掉的正是当前循环段时同时关掉选区循环。
  Future<void> deleteSegment(MediaSegment seg) => playback.deleteSegment(seg);

  /// 开启或关闭选段循环。[seg] 为 null 时关闭。
  Future<void> loopSegment(MediaSegment? seg) => playback.loopSegment(seg);

  /// 跳到段首播放
  Future<void> jumpToSegment(MediaSegment seg) => playback.jumpToSegment(seg);

  Future<void> playTrackAt(int index) => playback.playTrackAt(index);

  // ═══════════════ 字幕 / 封面 ═══════════════

  /// 读一首曲目的字幕，结果按曲目路径缓存（BUILD_GUIDE 第 23.3 节）。
  ///
  /// 返回 [SubtitleDocument]：界面据 [SubtitleDocument.parsed] 判断格式是否
  /// 可解析，据 [SubtitleDocument.hasTiming] 判断要不要做逐行同步。
  SubtitleDocument subtitleFor(TrackItem track) {
    final p = track.subtitlePath;
    if (p == null || p.isEmpty) return SubtitleDocument.empty;
    return _subtitleCache.putIfAbsent(
      track.path,
      () => SubtitleParser.parseFile(p),
    );
  }

  Future<void> replaceSubtitle(int trackId, String newPath) async {
    await _trackDao.setSubtitlePath(trackId, newPath);
    _subtitleCache.clear();
    _applySubtitlePath(trackId, newPath);
    subtitleOverlay.refresh();
    notifyListeners();
  }

  Future<void> clearSubtitle(int trackId) async {
    await _trackDao.setSubtitlePath(trackId, null);
    _subtitleCache.clear();
    _applySubtitlePath(trackId, null);
    subtitleOverlay.refresh();
    notifyListeners();
  }

  /// 同步更新中间栏曲目与播放器队列里的同一个 TrackItem。
  ///
  /// 常驻字幕和字幕页都读 `player.currentTrack`；只改 `library.tracks`
  /// 时，播放中的字幕路径会一直是旧的，必须把队列里的对象也换掉。
  void _applySubtitlePath(int trackId, String? path) {
    final updated = library.tracks
        .map((t) => t.id == trackId ? t.copyWith(subtitlePath: path) : t)
        .toList();
    library.tracks = updated;
    for (final track in updated) {
      if (track.id == trackId) {
        player.replaceTrack(track);
        break;
      }
    }
  }

  // ═══════════════ 媒体行自己的缩略图 ═══════════════

  /// 给一条媒体行指定或清除它自己的缩略图。
  ///
  /// 音频单文件手选封面就写在这里（`media.cover_path`）。
  Future<void> setMediaCover(int id, String? path) async {
    // 同一路径的文件被覆盖后，FileImage 仍会命中旧解码结果；先驱逐再落库。
    if (path != null) ImageCacheGuard.invalidate(path);
    await _mediaDao.setCoverPath(id, path);
    // 在屏的磁贴读的是内存里那一行，换掉它，用户点完菜单立刻看到新封面。
    final updated = await _mediaDao.getById(id);
    if (updated == null) {
      logWarn('AppState', 'setMediaCover 后重读媒体行失败: id=$id');
    }
    _mediaRevision++;
    notifyListeners();
  }

  /// 一条媒体行显示用的封面：先看行自己的 `cover_path`，再退回当前作品的封面。
  ///
  /// 只管库里已经记下来的路径；音频内嵌封面与视频首帧由各自的取图通道负责。
  String? coverForMedia(MediaItem item) {
    final own = item.coverPath;
    if (own != null && own.isNotEmpty) return own;
    final workCover = library.currentWork?.coverPath;
    if (workCover != null && workCover.isNotEmpty) return workCover;
    return null;
  }

  /// 当前曲目封面：优先队列来源作品的封面，否则曲目自己的封面。
  String? coverForTrack(TrackItem track) => covers.coverForTrack(track);

  /// 记下这次播放队列对应的作品封面。
  void _rememberQueueCover() {
    covers.rememberQueueCover(library.currentWork?.coverPath);
  }

  /// 按当前浏览的作品记录播放队列来源封面。
  ///
  /// 播放入口在调 `player.playQueue` 之前都会先调它；测试里用它绕过原生播放器。
  @visibleForTesting
  void rememberQueueSource() => _rememberQueueCover();

  // ═══════════════ 数据目录 ═══════════════

  Future<String> getDataDir() => DataDirService.instance.dataDir;

  bool _migrating = false;

  /// 迁移数据目录到 [newDir]：关闭数据库 → 复制数据 → 重开数据库 → 刷新。
  ///
  /// 同一时刻只允许一次迁移。中途失败时把数据库重开到「指针指向的目录」，
  /// 不让应用停在「库已关闭」的状态。
  Future<void> migrateDataDir(String newDir) async {
    if (_migrating) {
      throw StateError('数据目录迁移已在进行中');
    }
    // 导入不停就关库：在途的写入与 refresh 会打在已关闭的连接上。
    if (importing) {
      throw StateError('正在导入，等导入结束再迁移数据目录');
    }
    _migrating = true;
    final oldDir = await DataDirService.instance.dataDir;
    try {
      // 关库前先前进一代：在途的 refresh 拿到结果后发现代际不匹配会主动丢弃，
      // 不会去写已经关掉的连接。
      library.invalidatePendingRefresh();
      await DatabaseManager.instance.close();
      final newD = await DataDirService.instance.migrateTo(newDir);
      // 日志跟着数据目录走，否则迁移后还往旧目录写。
      LogUtil.attachFileSink(p.join(newD, 'logs'));
      await DatabaseManager.instance.init();
      // 更新数据目录内的封面缓存路径前缀（covers/track_*.jpg、covers/work_*.jpg）
      await _rewriteCoverPaths(oldDir, newD);
      await loadSettings();
      await loadTags();
      await refresh();
      logInfo('AppState', '数据目录迁移完成: $oldDir -> $newD');
    } catch (e, st) {
      logError('AppState', '数据目录迁移失败: $e\n$st');
      // migrateTo 成功则指针已指向新目录，失败则仍指向旧目录；两种情况都按指针
      // 重开，避免数据库一直处于关闭状态。
      if (!DatabaseManager.instance.isOpen) {
        try {
          await DatabaseManager.instance.init();
        } catch (reopenErr) {
          logError('AppState', '迁移失败后重开数据库也失败: $reopenErr');
        }
      }
      rethrow;
    } finally {
      _migrating = false;
    }
  }

  /// 把指向旧数据目录的封面路径改写为新数据目录（目录外的原图路径不动）
  Future<void> _rewriteCoverPaths(String oldDir, String newDir) async {
    final tracks = await _trackDao.queryAll();
    for (final t in tracks) {
      final moved = _movedPath(t.coverPath, oldDir, newDir);
      if (moved != null) await _trackDao.setCoverPath(t.id!, moved);
    }
    final works = await _workDao.listAll();
    for (final w in works) {
      final moved = _movedPath(w.coverPath, oldDir, newDir);
      if (moved != null) await _workDao.setCover(w.id!, moved);
    }
  }

  /// [path] 在 [oldDir] 之内时返回它在新目录下的对应路径，否则返回 null。
  /// 用 p.isWithin 判断，避免 `/a/b` 误匹配 `/a/bc/...`。
  String? _movedPath(String? path, String oldDir, String newDir) {
    if (path == null) return null;
    if (!p.isWithin(oldDir, path)) return null;
    return p.join(newDir, p.relative(path, from: oldDir));
  }

  // ═══════════════ 最近播放 / 播放历史 ═══════════════

  Future<void> loadRecentTracks() => playback.loadRecent();

  Future<void> playRecentTracks(int startIndex) =>
      playback.playRecent(startIndex);

  // ═══════════════ 封面缓存管理（转发到 CoverState）═══════════════

  Future<void> loadCoverCacheLimit() => covers.loadCacheLimit();

  Future<int> getCoverCacheSizeBytes() => covers.getCacheSizeBytes();

  Future<int> clearCoverCache() => covers.clearCache();

  Future<void> setCoverCacheLimit(int mb) => covers.setCacheLimit(mb);

  Future<void> enforceCoverCacheLimit() => covers.enforceLimit();

  /// 清理封面缓存时不能删的封面：正在播放的曲目、当前浏览作品的封面
  Set<String> _protectedCoverPaths() {
    final keep = <String>{};
    final playing = player.currentTrack?.coverPath;
    if (playing != null) keep.add(playing);
    final work = library.currentWork?.coverPath;
    if (work != null) keep.add(work);
    return keep;
  }

  bool _disposed = false;

  @override
  void notifyListeners() {
    if (_disposed) return;
    super.notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    final children = <ChangeNotifier>[
      settings,
      tags,
      covers,
      dlsite,
      playback,
      library,
    ];
    for (final child in children) {
      child.removeListener(notifyListeners);
    }
    subtitleOverlay.removeListener(notifyListeners);
    subtitleOverlay.dispose();
    for (final child in children) {
      child.dispose();
    }
    player.dispose();
    super.dispose();
  }
}

/// 一次「以磁盘为准」重扫的结果。
class RescanOutcome {
  const RescanOutcome({
    this.added = 0,
    this.removed = 0,
    this.missingRoots = 0,
  });

  final int added;
  final int removed;
  final int missingRoots;

  bool get changed => added > 0 || removed > 0;

  @override
  String toString() =>
      'RescanOutcome(新增 $added, 删除 $removed, 缺目录 $missingRoots)';
}
