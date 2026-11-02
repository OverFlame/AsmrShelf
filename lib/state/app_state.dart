import 'dart:async';
import 'dart:collection';
import 'dart:io';

// RepeatMode 与 Flutter 的同名枚举冲突，隐藏框架那个
import 'package:flutter/material.dart' hide RepeatMode;
import 'package:path/path.dart' as p;

import '../db/database.dart';
import '../db/folder_dao.dart';
import '../db/media_dao.dart';
import '../db/tag_dao.dart';
import '../db/track_dao.dart';
import '../db/work_dao.dart';
import '../services/cover_service.dart';
import '../services/data_dir_service.dart';
import '../services/file_scanner.dart';
import '../services/import_scanner.dart';
import '../services/import_service.dart';
import '../services/plan_importer.dart';
import '../services/play_position.dart';
import '../services/playlist_writer.dart';
import '../services/segment_service.dart';
import '../services/settings_service.dart';
import '../services/subtitle_parser.dart';
import '../services/subtitle_style.dart';
import '../services/subtitle_service.dart';
import '../services/thumbnail_cache.dart';
import '../services/video_launcher.dart';
import '../services/volume_cover_service.dart';
import '../utils/filter_expression.dart';
import '../utils/image_cache_util.dart';
import '../utils/log_util.dart';
import '../utils/progress_throttle.dart';
import 'player_controller.dart';

/// 标签筛选规则
class TagFilter {
  final List<int> andTagIds;
  final List<int> orTagIds;
  final List<int> notTagIds;

  const TagFilter({
    this.andTagIds = const [],
    this.orTagIds = const [],
    this.notTagIds = const [],
  });

  bool get active =>
      andTagIds.isNotEmpty || orTagIds.isNotEmpty || notTagIds.isNotEmpty;
}

/// 应用状态 — 作品集 / 文件夹导航 / 曲目 / 标签 / 导入 / 播放
class AppState extends ChangeNotifier {
  final PlayerController player;

  /// 外链播放器。用例注入假实现，界面用例才能断言交给系统的命令
  final VideoLauncher _launcher;

  // ── 作品集 ──
  List<Work> _works = [];
  List<Work> get works => _works;
  Work? _currentWork;
  Work? get currentWork => _currentWork;
  List<VirtualFolder> _unassignedFolders = [];
  List<VirtualFolder> get unassignedFolders => _unassignedFolders;

  // ── 文件夹导航 ──
  int? _currentFolderId;
  int? get currentFolderId => _currentFolderId;
  VirtualFolder? _currentFolder;
  VirtualFolder? get currentFolder => _currentFolder;
  String? _currentFolderPath;
  String? get currentFolderPath => _currentFolderPath;
  List<VirtualFolder> _breadcrumb = [];
  List<VirtualFolder> get breadcrumb => _breadcrumb;
  int _folderVersion = 0;
  int get folderVersion => _folderVersion;

  // ── 中间栏内容 ──
  List<VirtualFolder> _centerFolders = [];
  List<VirtualFolder> get centerFolders => _centerFolders;
  /// 播放位置落盘的节流（见 lib/services/play_position.dart）
  final PlayPositionThrottle _positionThrottle = PlayPositionThrottle();

  List<TrackItem> _tracks = [];
  List<TrackItem> get tracks => _tracks;

  /// 媒体行增删的代数，界面据此知道该重查。
  int _mediaRevision = 0;
  int get mediaRevision => _mediaRevision;


  bool _loading = false;
  bool get loading => _loading;

  // ── 搜索 ──
  String _searchQuery = '';
  String get searchQuery => _searchQuery;

  // ── 标签 ──
  List<Tag> _allTags = [];
  List<Tag> get allTags => _allTags;
  final Map<int, List<Tag>> _trackTags = {};
  final Map<int, List<Tag>> _imageTags = {};
  /// 每个曲目的标签切换排队串行执行，见 [toggleTagOnTrack]。
  final Map<int, Future<void>> _tagToggleChains = {};
  // ── 曲目多选 ──
  final Set<int> _selectedTrackIds = {};
  /// 只读视图：调用方拿不到内部集合，改不到选中状态。
  Set<int> get selectedTrackIds => UnmodifiableSetView(_selectedTrackIds);
  int? _anchorTrackId;
  bool _selectionMode = false;
  bool get selectionMode => _selectionMode;
  bool isTrackSelected(int id) => _selectedTrackIds.contains(id);
  TagFilter _tagFilter = const TagFilter();
  TagFilter get tagFilter => _tagFilter;
  String _advancedFilter = '';
  String get advancedFilter => _advancedFilter;
  bool get hasAdvancedFilter => _advancedFilter.trim().isNotEmpty;


  // ── 图片视图设置 ──
  int _gridColumns = 4;
  int get gridColumns => _gridColumns;

  /// 缩略图缓存上限（MB）。复用封面缓存设置键，见 [setCacheSizeMB]。
  int get cacheSizeMB => _coverCacheLimitMB;

  String _viewMode = 'grid';
  String get viewMode => _viewMode;

  // ── 字幕页外观 ──
  bool _subtitleOpacityAuto = true;

  /// 非当前句的透明度是否按封面明暗自动算。
  bool get subtitleOpacityAuto => _subtitleOpacityAuto;

  double _subtitleInactiveOpacity = SubtitleStyle.defaultInactiveOpacity;

  /// 固定模式下非当前句的透明度。
  double get subtitleInactiveOpacity => _subtitleInactiveOpacity;

  int _subtitleResumeSeconds = SettingsService.defaultSubtitleResumeSeconds;

  /// 滑动之后留在原地的秒数。
  int get subtitleResumeSeconds => _subtitleResumeSeconds;

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
  bool _importing = false;
  bool get importing => _importing;
  double _importProgress = 0;
  double get importProgress => _importProgress;

  /// 最近一次导入的失败原因；null 表示上次导入没有出错。
  ///
  /// 导入的调用方是按钮回调，没有错误边界，所以不往上抛异常；改成把这个字段
  /// 交给界面，让失败可见，而不是只写一行日志当没事发生。
  String? _importError;
  String? get importError => _importError;

  // ── 最近播放 ──
  List<TrackItem> _recentTracks = [];
  List<TrackItem> get recentTracks => _recentTracks;
  /// [loadRecentTracks] 的代际：快速切歌会并发触发多次重载，只有最后一次能写回。
  int _recentLoadGeneration = 0;

  // ── 播放队列来源作品的封面 ──
  String? _playingWorkCover;
  /// 当前播放队列来源作品的封面。队列建立时记录，与「当前浏览的作品」解耦。
  String? get playingWorkCover => _playingWorkCover;

  // ── 封面缓存上限（MB，0 表示不限制）──
  int _coverCacheLimitMB = 512;
  int get coverCacheLimitMB => _coverCacheLimitMB;

  // ── 当前曲目的收藏选段（BUILD_GUIDE 第 24.3 节）──
  List<MediaSegment> _segments = [];
  List<MediaSegment> get segments => List.unmodifiable(_segments);

  // ── 设置 ──
  ThemeMode _themeMode = ThemeMode.dark;
  ThemeMode get themeMode => _themeMode;
  String _sortKey = 'filename';
  String get sortKey => _sortKey;
  bool _sortDescending = false;
  bool get sortDescending => _sortDescending;

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

  String _imageSortKey = 'name';
  bool _imageSortDesc = false;

  /// 多媒体库的排序字段。图片与视频合并成一个库之后只剩这一套设置。
  String get visualSortKey => _imageSortKey;

  /// 多媒体库是否降序。
  bool get visualSortDescending => _imageSortDesc;

  /// 作品层可用的排序字段。作品没有文件大小与修改时间，只留名称与加入时间。
  static const Map<String, String> worksSortLabels = {
    'name': '文件名',
    'added': '加入时间',
  };

  /// 作品层排序独立于文件层：默认按加入时间倒序，与列表原有的「新作品在前」一致。
  String _worksSortKey = 'added';
  bool _worksSortDesc = true;

  String get worksSortKey =>
      worksSortLabels.containsKey(_worksSortKey) ? _worksSortKey : 'added';

  bool get worksSortDescending => _worksSortDesc;

  Future<void> setWorksSortKey(String key) async {
    if (!worksSortLabels.containsKey(key)) return;
    _worksSortKey = key;
    await SettingsService.instance.setWorksSortKey(key);
    notifyListeners();
  }

  Future<void> setWorksSortDescending(bool desc) async {
    _worksSortDesc = desc;
    await SettingsService.instance.setWorksSortDescending(desc);
    notifyListeners();
  }

  /// 作品层排序比较器。同值时按加入时间、id 兜底，降序整体取负。
  int Function(Work, Work) get worksComparator {
    final key = worksSortKey;
    final desc = worksSortDescending;
    return (a, b) {
      int cmp;
      if (key == 'added') {
        cmp = a.createdAt.compareTo(b.createdAt);
      } else {
        cmp = naturalCompare(a.name, b.name);
      }
      if (cmp == 0) cmp = a.createdAt.compareTo(b.createdAt);
      if (cmp == 0) cmp = (a.id ?? 0).compareTo(b.id ?? 0);
      return desc ? -cmp : cmp;
    };
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
    final ss = SettingsService.instance;
    _imageSortKey = key;
    await ss.setImageSortKey(key);
    await _afterVisualSortChanged();
  }

  Future<void> setVisualSortDescending(bool desc) async {
    final ss = SettingsService.instance;
    _imageSortDesc = desc;
    await ss.setImageSortDescending(desc);
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
  })  : _launcher = videoLauncher ?? VideoLauncher();

  Future<void> init() async {
    logInfo('AppState', 'Initializing...');
    // 缩略图服务必须在这里初始化：界面一建卡片就会调 thumbPath()，
    // 漏掉这一步时缩略图一张都生成不出来（网格只剩占位图标）。
    await ThumbnailService.instance.init();
    player.onTrackStarted = _onTrackStarted;
    player.resumeFrom = _resumePositionOf;
    player.onPositionChanged = _onPlayPosition;
    player.onTrackCompleted = _onTrackCompleted;
    player.onRepeatModeChanged = _persistRepeatMode;
    player.onShuffleChanged = _persistShuffle;
    player.onSpeedChanged = _persistSpeed;
    await loadSettings();
    // 规则标签只放定义行，筛选时翻成列条件（BUILD_GUIDE 第 18.4 节）。
    await _tagDao.ensureRuleTags(extNames: _ruleTagExtensions);
    await loadTags();
    await _initNotTagIds();
    await _initCollapsedNamespaces();
    await loadRecentTracks();
    await loadCoverCacheLimit();
    await refresh();
    // 存量老库没有默认封面：后台补一次，不挡首屏。
    unawaited(backfillAutoCovers());
    logInfo('AppState', 'Initialized OK');
  }

  /// 默认排除「字幕」这类规则标签，并把排除集持久化（BUILD_GUIDE 第 18.5 节）。
  ///
  /// 字幕照常入库，只是默认不进列表；用户改过排除集就不再套用默认值。
  Future<void> _initNotTagIds() async {
    final settings = SettingsService.instance;
    final stored = settings.excludedTagIds;
    if (stored != null) {
      if (stored.isNotEmpty) {
        _tagFilter = TagFilter(notTagIds: stored);
      }
      return;
    }
    final kindIds = _allTags
        .where((t) =>
            t.namespace == TagDao.kindNamespace &&
            t.name == MediaType.subtitle.value)
        .map((t) => t.id)
        .whereType<int>()
        .toList();
    await settings.setExcludedTagIds(kindIds);
    if (kindIds.isNotEmpty) {
      _tagFilter = TagFilter(notTagIds: kindIds);
    }
  }

  /// 排除集每次变动都落盘，重启后保持。
  void _persistNotTagIds() {
    unawaited(
        SettingsService.instance.setExcludedTagIds(_tagFilter.notTagIds));
  }

  // ── 标签面板折叠的命名空间 ──

  final Set<String> _collapsedNamespaces = {};

  /// 折叠起来的命名空间（标签面板据此只画标题行）。
  Set<String> get collapsedNamespaces =>
      UnmodifiableSetView(_collapsedNamespaces);

  bool isNamespaceCollapsed(String namespace) =>
      _collapsedNamespaces.contains(namespace);

  /// 首次启动折叠扩展名那一组：那是按文件后缀自动生成的规则标签，几十个，
  /// 不折叠会盖住用户自己打的标签。用户改过就按用户存的来。
  Future<void> _initCollapsedNamespaces() async {
    final stored = SettingsService.instance.collapsedTagNamespaces;
    if (stored != null) {
      _collapsedNamespaces
        ..clear()
        ..addAll(stored);
      return;
    }
    _collapsedNamespaces.add(TagDao.extNamespace);
    await SettingsService.instance
        .setCollapsedTagNamespaces(_collapsedNamespaces.toList());
  }

  void toggleNamespaceCollapsed(String namespace) {
    if (!_collapsedNamespaces.remove(namespace)) {
      _collapsedNamespaces.add(namespace);
    }
    unawaited(SettingsService.instance
        .setCollapsedTagNamespaces(_collapsedNamespaces.toList()));
    notifyListeners();
  }

  /// 展开或折叠当前已有的全部命名空间（标签面板的「全部折叠/展开」）。
  void setAllNamespacesCollapsed(bool collapsed) {
    final all = _allTags.map((t) => t.namespace).toSet();
    if (collapsed) {
      _collapsedNamespaces.addAll(all);
    } else {
      _collapsedNamespaces.removeAll(all);
    }
    unawaited(SettingsService.instance
        .setCollapsedTagNamespaces(_collapsedNamespaces.toList()));
    notifyListeners();
  }

  // ═══════════════ 设置 ═══════════════

  /// 载入设置期间不回写，避免把刚读到的值又原样写一遍
  bool _loadingSettings = false;

  Future<void> loadSettings() async {
    final ss = SettingsService.instance;
    _loadingSettings = true;
    try {
      _themeMode = ss.themeMode;
      _sortKey = ss.sortKey;
      _sortDescending = ss.sortDescending;
      _imageSortKey = ss.imageSortKey;
      _imageSortDesc = ss.imageSortDescending;
      _worksSortKey = ss.worksSortKey;
      _worksSortDesc = ss.worksSortDescending;
      _gridColumns = ss.gridColumns;
      _viewMode = ss.viewMode;
      _subtitleOpacityAuto = ss.subtitleOpacityAuto;
      _subtitleInactiveOpacity = ss.subtitleInactiveOpacity;
      _subtitleResumeSeconds = ss.subtitleResumeSeconds;
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
    _themeMode = mode;
    await SettingsService.instance.setThemeMode(mode);
    notifyListeners();
  }

  Future<void> setSortKey(String key) async {
    _sortKey = key;
    await SettingsService.instance.setSortKey(key);
    await refresh();
  }

  Future<void> setSortDescending(bool desc) async {
    _sortDescending = desc;
    await SettingsService.instance.setSortDescending(desc);
    await refresh();
  }

  // ── 图片视图设置 ──

  Future<void> setGridColumns(int cols) async {
    _gridColumns = cols.clamp(2, 10);
    await SettingsService.instance.setGridColumns(_gridColumns);
    notifyListeners();
  }

  /// 缩略图缓存上限。与封面缓存上限共用 `cover_cache_mb` 设置键，
  /// 落到 [setCoverCacheLimit] 上，避免同一份配额存两遍。
  Future<void> setCacheSizeMB(int mb) => setCoverCacheLimit(mb);

  // ── 字幕页外观 ──

  Future<void> setSubtitleOpacityAuto(bool auto) async {
    _subtitleOpacityAuto = auto;
    await SettingsService.instance.setSubtitleOpacityAuto(auto);
    notifyListeners();
  }

  Future<void> setSubtitleInactiveOpacity(double value) async {
    _subtitleInactiveOpacity = SubtitleStyle.clampInactiveOpacity(value);
    await SettingsService.instance
        .setSubtitleInactiveOpacity(_subtitleInactiveOpacity);
    notifyListeners();
  }

  Future<void> setSubtitleResumeSeconds(int seconds) async {
    _subtitleResumeSeconds = seconds.clamp(
        SettingsService.minSubtitleResumeSeconds,
        SettingsService.maxSubtitleResumeSeconds);
    await SettingsService.instance
        .setSubtitleResumeSeconds(_subtitleResumeSeconds);
    notifyListeners();
  }

  Future<void> setViewMode(String mode) async {
    _viewMode = mode == 'list' ? 'list' : 'grid';
    await SettingsService.instance.setViewMode(_viewMode);
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
      _currentWork?.library ?? _currentFolder?.library;



  /// 批量「从软件移除」：只删库里的媒体行，磁盘文件不动。
  ///
  /// 返回真正删掉的行数。关联的标签行由外键级联清掉。
  Future<int> deleteMediaByIds(Iterable<int> ids) async {
    final list = ids.toSet().toList();
    if (list.isEmpty) return 0;
    final deleted = await _mediaDao.deleteByIds(list);
    for (final id in list) {
      _trackTags.remove(id);
      _imageTags.remove(id);
      _selectedTrackIds.remove(id);
    }
    if (_selectedTrackIds.isEmpty) _selectionMode = false;
    if (_anchorTrackId != null && !_selectedTrackIds.contains(_anchorTrackId)) {
      _anchorTrackId = null;
    }
    _mediaRevision++;
    await refresh();
    logInfo('AppState', '批量移除媒体 $deleted 条（请求 ${list.length} 条）');
    return deleted;
  }


  // ═══════════════ 刷新 / 中间栏加载 ═══════════════

  /// 每次 refresh 递增。用于丢弃「先发起但后完成」的旧结果。
  int _refreshGeneration = 0;

  Future<void> refresh() async {
    final gen = ++_refreshGeneration;
    logInfo('AppState', 'refresh() gen=$gen');
    _subtitleCache.clear();
    final works = await _workDao.listAll();
    final unassigned = await _folderDao.listUnassignedRoots();
    if (gen != _refreshGeneration) {
      logInfo('AppState', 'refresh() gen=$gen 已被新一代取代，丢弃结果');
      return;
    }
    _works = works;
    _unassignedFolders = unassigned;
    notifyListeners();
    await _loadCenter(gen);
  }

  /// 加载中间栏。[gen] 是发起时的 [refresh] 代际。
  ///
  /// 应用只剩音频库，中间栏只填曲目与文件夹。
  Future<void> _loadCenter(int gen) async {
    _loading = true;
    notifyListeners();
    try {
      final search = _searchQuery.trim();
      final filterActive = hasAdvancedFilter || _tagFilter.active;

      List<VirtualFolder> folders;
      List<TrackItem> tracks;

      if (search.isNotEmpty) {
        folders = const [];
        var list = await _trackDao.searchByName(search);
        if (filterActive) {
          final ids = await _computeMatchingIds(MediaType.audio);
          list = list.where((t) => ids.contains(t.id)).toList();
        }
        tracks = list;
      } else {
        if (_currentWork != null && _currentFolderId != null) {
          folders = await _folderDao.listChildren(_currentFolderId!);
          tracks = _currentFolderPath == null
              ? <TrackItem>[]
              : await _trackDao.queryDirectInDir(_currentFolderPath!);
        } else if (_currentWork != null) {
          // 作品层保留入口文件夹，它是进入专辑/歌单的入口。
          folders = await _folderDao.listRootsByWork(_currentWork!.id!);
          tracks = const [];
        } else {
          folders = const [];
          tracks = const [];
        }

        if (filterActive) {
          final ids = await _computeMatchingIds(MediaType.audio);
          tracks = tracks.where((t) => ids.contains(t.id)).toList();
          folders =
              await _filterFolders(folders, ids, MediaType.audio);
        }
      }

      // 等待期间又有新的 refresh 发起，本次结果作废，不覆盖更新的状态。
      if (gen != _refreshGeneration) {
        logInfo('AppState', 'Center load gen=$gen 已被取代，丢弃结果');
        return;
      }
      _centerFolders = _sortFolders(folders);
      _tracks = _sortTracks(tracks);
      // 选中集合只保留当前可见的条目。切到别的作品或文件夹之后，
      // 「批量打标签」「移动」不会落到看不见的条目上。
      final visibleTrackIds = _tracks.map((t) => t.id).whereType<int>().toSet();
      final selectedBefore = _selectedTrackIds.length;
      _selectedTrackIds.retainAll(visibleTrackIds);
      if (_anchorTrackId != null && !visibleTrackIds.contains(_anchorTrackId)) {
        _anchorTrackId = null;
      }
      if (_selectedTrackIds.isEmpty) _selectionMode = false;
      if (selectedBefore != _selectedTrackIds.length) {
        logInfo('AppState',
            '选中集合随上下文收窄: $selectedBefore -> ${_selectedTrackIds.length}');
      }

      logInfo('AppState',
          'Center loaded: ${_centerFolders.length} folders, ${_tracks.length} tracks');
    } finally {
      // 只有最新一代有资格清 loading，否则会提前关掉新一轮的转圈。
      if (gen == _refreshGeneration) {
        _loading = false;
        notifyListeners();
      }
    }
  }

  /// 当前筛选下命中的媒体 id 集合。[type] 是当前库的媒体类型：音频库用
  /// `MediaType.audio`，多媒体库传 null（不限类型）。
  Future<Set<int>> _computeMatchingIds(MediaType? type) async {
    if (hasAdvancedFilter) {
      return _tagDao.getIdsByExpression(type, _advancedFilter, _allTags);
    }
    return _tagDao.getIdsByTags(
      type,
      andTagIds: _tagFilter.andTagIds,
      orTagIds: _tagFilter.orTagIds,
      notTagIds: _tagFilter.notTagIds,
    );
  }

  Future<List<VirtualFolder>> _filterFolders(
      List<VirtualFolder> folders, Set<int> matchingIds, MediaType? type) async {
    if (folders.isEmpty) return [];
    final matchingPaths = matchingIds.isEmpty
        ? <String>[]
        : type == MediaType.audio
            ? await _trackDao.pathsByIds(matchingIds)
            : await _mediaDao.pathsByIds(matchingIds, type: type);

    Map<int, List<Tag>> folderTags = {};
    if (!hasAdvancedFilter && _tagFilter.active) {
      folderTags =
          await _tagDao.getTagsForFolders(folders.map((f) => f.id!).toList());
    }

    // 一次取全部目录路径，再把命中路径排好序做二分查找。
    // 旧实现每个文件夹查一次库，再对每个匹配路径做 O(F×M) 的 any。
    final allPaths = await _folderDao.getAllPaths();
    final matchingLower = matchingPaths.map((p) => p.toLowerCase()).toList()
      ..sort();

    final result = <VirtualFolder>[];
    for (final f in folders) {
      final paths = allPaths[f.id!] ?? const <FolderPath>[];
      final containsTrack =
          paths.any((p) => _hasPathUnder(matchingLower, p.path));
      if (containsTrack) {
        result.add(f);
        continue;
      }
      if (!hasAdvancedFilter && _tagFilter.active) {
        final tags = folderTags[f.id] ?? const <Tag>[];
        if (_folderTagsMatch(tags)) result.add(f);
      }
    }
    return result;
  }

  bool _folderTagsMatch(List<Tag> tags) {
    final ids = tags.map((t) => t.id).whereType<int>().toSet();
    if (_tagFilter.andTagIds.any((id) => !ids.contains(id))) return false;
    if (_tagFilter.orTagIds.isNotEmpty &&
        !_tagFilter.orTagIds.any((id) => ids.contains(id))) {
      return false;
    }
    if (_tagFilter.notTagIds.any((id) => ids.contains(id))) return false;
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

  List<VirtualFolder> _sortFolders(List<VirtualFolder> list) {
    // 先复制：入参可能是 const []（不可变），直接 sort 会抛 Unsupported operation
    final sorted = List<VirtualFolder>.from(list);
    // 自然序：第 2 卷排在第 10 卷前面（BUILD_GUIDE 第 20.2 节）
    sorted.sort((a, b) => naturalCompare(a.name, b.name));
    return sorted;
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
    final dir = _sortDescending ? -1 : 1;
    sorted.sort((a, b) {
      int cmp;
      switch (_sortKey) {
        case 'title':
          cmp = a.displayTitle.toLowerCase().compareTo(b.displayTitle.toLowerCase());
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
    _searchQuery = q;
    refresh();
  }

  // ═══════════════ 导航 ═══════════════

  Future<void> goHome() async {
    _currentWork = null;
    _currentFolderId = null;
    _currentFolder = null;
    _currentFolderPath = null;
    _breadcrumb = [];
    await refresh();
  }

  Future<void> enterWork(int workId) async {
    final work = await _workDao.getById(workId);
    if (work == null) return;
    _currentWork = work;
    _currentFolderId = null;
    _currentFolder = null;
    _currentFolderPath = null;
    _breadcrumb = [VirtualFolder(id: -1, name: work.name, workId: work.id)];
    // 自动封面指向的原图可能被删了，进来时顺手改选当前第一张。
    await _autoAssignWorkCover(workId);
    _currentWork = await _workDao.getById(workId) ?? work;
    await refresh();
  }

  Future<void> enterFolder(int folderId) async {
    final folder = await _folderDao.getById(folderId);
    if (folder == null) return;
    _currentFolderId = folderId;
    _currentFolder = folder;
    final paths = await _folderDao.getPaths(folderId);
    _currentFolderPath = paths.isEmpty ? null : paths.first.path;
    // 若文件夹属于某作品，确保 currentWork 一致
    if (folder.workId != null && _currentWork?.id != folder.workId) {
      final w = await _workDao.getById(folder.workId!);
      if (w != null) _currentWork = w;
    }
    _breadcrumb = await _buildBreadcrumb();
    await refresh();
  }

  Future<void> goUp() async {
    if (_currentFolderId == null) {
      await enterWorkOrHome();
      return;
    }
    final parent = _currentFolder?.parentId;
    if (parent == null) {
      // 回到作品层
      if (_currentWork != null) {
        await enterWork(_currentWork!.id!);
      } else {
        await goHome();
      }
      return;
    }
    await enterFolder(parent);
  }

  Future<void> enterWorkOrHome() async {
    if (_currentWork != null) {
      await enterWork(_currentWork!.id!);
    } else {
      await goHome();
    }
  }

  Future<List<VirtualFolder>> _buildBreadcrumb() async {
    final work = _currentWork;
    final chain = <VirtualFolder>[];
    var cur = _currentFolder;
    while (cur != null) {
      chain.insert(0, cur);
      if (cur.parentId == null) break;
      cur = await _folderDao.getById(cur.parentId!);
    }
    // work 作为首层标记
    if (work != null) {
      chain.insert(
          0,
          VirtualFolder(
              id: -1, name: work.name, parentId: null, workId: work.id));
    }
    return chain;
  }

  // ═══════════════ 作品集操作 ═══════════════

  Future<Work> createWork(String name) async {
    final work = await _workDao.create(name);
    await refresh();
    return work;
  }

  Future<void> renameWork(int id, String name) async {
    await _workDao.rename(id, name);
    if (_currentWork?.id == id) {
      _currentWork = Work(
          id: id,
          name: name,
          coverPath: _currentWork!.coverPath,
          createdAt: _currentWork!.createdAt);
    }
    await refresh();
  }

  Future<void> deleteWork(int id) async {
    // WorkDao.delete 内部用事务完成「摘归属 + 删作品」。
    await _workDao.delete(id);
    if (_currentWork?.id == id) {
      await goHome();
    } else {
      await refresh();
    }
  }

  Future<void> setWorkCover(int id, String? coverPath) async {
    await _workDao.setCover(id, coverPath);
    if (_currentWork?.id == id) {
      _currentWork = Work(
          id: id,
          name: _currentWork!.name,
          coverPath: coverPath,
          createdAt: _currentWork!.createdAt);
    }
    notifyListeners();
    await refresh();
  }

  // ═══════════════ 文件夹操作 ═══════════════

  Future<void> renameFolder(int id, String newName) async {
    await _folderDao.rename(id, newName);
    _folderVersion++;
    await refresh();
  }

  Future<void> deleteFolder(int id) async {
    // 先记下这个文件夹自己挂在哪几条路径上：删完之后 folder_paths 会被 CASCADE 清掉，
    // 再想问「哪些曲目本来是靠它才可见的」就没有依据了。
    final removedPaths =
        (await _folderDao.getPaths(id)).map((fp) => fp.path).toList();
    await _folderDao.delete(id);
    await _pruneTracksLeftBehind(removedPaths);
    _folderVersion++;
    if (_currentFolderId == id) {
      _currentFolderId = null;
      _currentFolder = null;
      _currentFolderPath = null;
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
    _trackTags.clear();
    if (deleted > 0) _mediaRevision++;
    logInfo('AppState',
        '删除文件夹后清理失联曲目 ${orphan.length} 条（实删 $deleted 行）');
    return deleted;
  }

  /// 深度删除文件夹：连子文件夹与其中所有媒体记录一起从软件里移除。
  ///
  /// 与 [deleteFolder] 的区别是这个方法把「目录里的东西」也一起清掉；两者都只动
  /// 数据库，不碰磁盘文件，用户之后重新导入就能拿回来。返回移除的媒体行数。
  Future<int> deleteFolderDeep(int id) async {
    final ids = await _expandFoldersDeep(<int>{id});
    final deleted = await _deleteFoldersDeep(ids);
    _folderVersion++;
    if (_currentFolderId != null && ids.contains(_currentFolderId)) {
      _currentFolderId = null;
      _currentFolder = null;
      _currentFolderPath = null;
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
        owned.map((f) => f.id).whereType<int>().toSet());
    final deleted = await _deleteFoldersDeep(ids);
    // 文件夹已删，这里只剩摘掉已不存在的归属并删除作品行。
    await _workDao.delete(workId);
    _folderVersion++;
    if (_currentWork?.id == workId) {
      await goHome();
    } else {
      await refresh();
    }
    return deleted;
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
          await for (final entity in Directory(root)
              .list(recursive: true, followLinks: false)) {
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
        owned.map((f) => f.id).whereType<int>().toSet());
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
            (fp) => removed.any((r) => fp.path == r || p.isWithin(r, fp.path)));
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
    _trackTags.clear();
    // 媒体行被删了就要推进代数：作品层的 ImageGrid 缓存着查过的列表，
    // 只靠 folderVersion 它不知道该重查，删掉的磁贴会留在界面上。
    if (deleted > 0) _mediaRevision++;
    logInfo('AppState',
        '深度删除后清理媒体 ${victims.length} 条（实删 $deleted 行）');
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
    _folderVersion++;
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
        // 失败原因留在 _importError 里给界面显示。
        final why = _importError ?? '没有新曲目落库';
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
  static List<String> _visualPaths(ScanResult scan) =>
      <String>[...scan.imagePaths, ...scan.videoPaths];

  /// 新建一个多媒体作品，把扫描到的图片、视频与音频一起落库并挂上虚拟文件夹。
  ///
  /// 图片与视频直接写 media 表；音频交给 [ImportService]，这样时长、内嵌封面、
  /// 字幕配对与音频栏一致。同一个目录两条链都跑，作品与文件夹共用一份。
  Future<Work?> _importVisualWork(
      String dirPath, String library, ScanResult scan) async {
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
      imported += await _runVisualImport(dirPath, work.id!, library, visualPaths);
    }
    if (scan.audioPaths.isNotEmpty) {
      imported +=
          await _runImport(dirPath, work.id!, scan: scan, library: library);
    }
    if (imported == 0) {
      final why = _importError ?? '没有新条目落库';
      logWarn('AppState', '导入没有落库（$why），删除空作品: ${work.name}');
      await _workDao.delete(work.id!);
      return null;
    }
    return work;
  }

  /// 把图片与视频写进 media 表，并在目标库下建/复用虚拟文件夹。
  Future<int> _runVisualImport(
      String dirPath, int workId, String library, List<String> paths) async {
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
      await _folderDao.ensureByPath(dirPath,
          name: _baseName(dirPath), workId: workId, library: library);
      if (imported > 0) await _autoAssignWorkCover(workId);
      logInfo('AppState',
          '$library 导入落库 $imported 条（扫描 ${paths.length} 条）: $dirPath');
    } catch (e) {
      _importError = e.toString();
      logError('AppState', '$library 导入失败', e.toString());
    } finally {
      _importProgress = imported > 0 ? 1.0 : 0.0;
      _folderVersion++;
      await refresh();
    }
    // README 承诺「缩略图进库时后台补齐」：这里接着补，不占导入的关键路径。
    if (imported > 0 && freshPaths.isNotEmpty) {
      unawaited(backfillThumbnails(freshPaths));
    }
    return imported;
  }

  /// 补齐存量作品的默认封面。导入当时没写封面的老库，启动后台跑一次。
  ///
  /// 标记写在设置里：跑完就不再扫，之后新增的作品由导入链负责。失败不写标记，
  /// 下次启动还会再试。
  Future<void> backfillAutoCovers() async {
    final settings = SettingsService.instance;
    if (settings.autoCoverBackfillDone) return;
    try {
      final works = await _workDao.listAll(library: 'media');
      var changed = 0;
      for (final work in works) {
        if (work.id == null) continue;
        if (await _autoAssignWorkCover(work.id!)) changed++;
      }
      await settings.setAutoCoverBackfillDone(true);
      // 这里不能 refresh()：启动补齐是后台任务，refresh 会按当时的分区状态
      // 重写列表，和用户立刻发起的导航抢写。只把作品列表的封面换掉。
      if (changed > 0) {
        _works = await _workDao.listAll();
        notifyListeners();
      }
      logInfo('AppState', '存量作品默认封面补齐完成（${works.length} 个）');
    } catch (e) {
      logWarn('AppState', '存量作品默认封面补齐失败: $e');
    }
  }

  /// 当前排序下作品里的第一张图片。没有图片（纯视频作品）返回 null。
  ///
  /// [mustExist] 为 true 时跳过已经不在磁盘上的行：媒体行要等下次刷新才会
  /// 消失，选封面时不能把已删文件又选回来。
  Future<String?> _firstImageUnderWork(int workId,
      {bool mustExist = false}) async {
    final dirs = await _folderDao.getPathsByWork(workId);
    if (dirs.isEmpty) return null;
    final images = await _mediaDao.queryByDirs(dirs, type: MediaType.image);
    if (images.isEmpty) return null;
    images.sort(visualSortComparator);
    for (final image in images) {
      if (!mustExist || await File(image.path).exists()) return image.path;
    }
    return null;
  }

  /// 只给没有封面的多媒体作品补默认封面，不覆盖用户手动设置的封面。
  ///
  /// 默认封面存原图路径，导入时按当时的排序取第一张，之后不跟着排序变化。
  /// 自动封面指向的原图被删掉时，这里会改选当前第一张；`covers/` 下的手动
  /// 封面即使文件没了也不动，留给用户自己重设。
  Future<bool> _autoAssignWorkCover(int workId) async {
    final work = await _workDao.getById(workId);
    if (work == null || work.library == 'audio') return false;
    final current = work.coverPath;
    var coverMissing = false;
    if (current != null && current.isNotEmpty) {
      if (await File(current).exists()) return false;
      coverMissing = true;
      final coversDir = await CoverService.coversDir();
      if (p.isWithin(coversDir, current)) return false;
    }
    final first =
        await _firstImageUnderWork(workId, mustExist: coverMissing);
    if (first == null || first == current) return false;
    await _workDao.setCover(workId, first);
    logInfo('AppState', '作品 $workId 默认封面 → $first');
    return true;
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
      final outcome =
          await PlanImporter(DatabaseManager.instance.db).apply(plan);
      logInfo('AppState',
          '一次性导入：作品 ${outcome.worksCreated} 新建 / ${outcome.worksSkipped} 跳过，'
          '曲目 ${outcome.tracksInserted} 新增 / ${outcome.tracksSkipped} 已存在');
      await refresh();
      return outcome;
    } finally {
      _endImport();
    }
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
    if (_importing) {
      logWarn('AppState', '$caller: 已有导入进行中，忽略本次请求');
      return false;
    }
    _importing = true;
    _importProgress = 0;
    _importError = null;
    notifyListeners();
    return true;
  }

  void _endImport() {
    _importing = false;
    _importProgress = 0;
    notifyListeners();
  }

  /// 真正干活的部分。调用方负责用 [_beginImport] / [_endImport] 圈住导入期。
  /// 返回处理过的新曲目数，0 表示这次导入没有新增内容。
  Future<int> _runImport(String dirPath, int workId,
      {ScanResult? scan, String library = 'audio'}) async {
    var imported = 0;
    try {
      final importService = ImportService.fromDB();
      final stream = importService.importDirectory(dirPath,
          workId: workId, scan: scan, library: library);
      // 导入流按文件吐进度。逐条 notifyListeners 会让整页重建上千次，
      // 进度条却看不出差别，所以按 1% 粒度通知。
      final throttle = ProgressThrottle();
      await for (final p in stream) {
        imported++;
        _importProgress = p.percent;
        if (throttle.shouldNotify(p.percent)) notifyListeners();
      }
    } catch (e) {
      _importError = e.toString();
      logError('AppState', '导入失败', e.toString());
    } finally {
      _importProgress = 0;
      notifyListeners();
      _folderVersion++;
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

  // ═══════════════ 卷封面与卷内图片（BUILD_GUIDE 第 19、21 节）═══════════════

  VolumeCoverService get _coverService =>
      VolumeCoverService(DatabaseManager.instance.db);

  /// 卷封面或裁剪改动后自增，界面据此重新读取封面。
  int _coverVersion = 0;
  int get coverVersion => _coverVersion;

  /// 自动候选按第 19.2 节的四级顺序返回，第一个就是自动选中的那张。
  Future<List<VolumeCoverCandidate>> volumeCoverCandidates(int folderId) =>
      _coverService.listCandidates(folderId);

  /// 当前生效的封面：手动指定的优先，其次是自动候选。
  Future<String?> volumeCover(int folderId) =>
      _coverService.effectiveCover(folderId);

  /// 手动指定封面。传 null 表示恢复自动候选。
  Future<void> setVolumeCover(int folderId, String? path) async {
    await _coverService.setCover(folderId, path);
    _coverVersion++;
    notifyListeners();
  }

  Future<Rect?> volumeCoverCrop(int folderId) => _coverService.cropOf(folderId);

  /// 存裁剪框。传 null 表示恢复默认（清空 `cover_crop`）。
  Future<void> setVolumeCoverCrop(int folderId, Rect? crop) async {
    await _coverService.setCrop(folderId, crop);
    _coverVersion++;
    notifyListeners();
  }

  /// 指定封面与裁剪一次写完，避免界面连点两次。
  Future<void> setVolumeCoverWithCrop(
      int folderId, String? path, Rect? crop) async {
    await _coverService.setCoverWithCrop(folderId, path, crop);
    _coverVersion++;
    notifyListeners();
  }

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
        final work = await _workDao.create(_baseName(dirPath), library: 'audio');
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
        final volume = await _folderDao.ensureByPath(child,
            name: _baseName(child), workId: work.id!, library: 'audio');
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
      _importError = e.toString();
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
      _importError = e.toString();
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

  // ═══════════════ 标签 ═══════════════

  Future<void> loadTags() async {
    _allTags = await _tagDao.getAll();
    notifyListeners();
  }

  Future<List<Tag>> getTrackTags(int trackId) async {
    final cached = _trackTags[trackId];
    if (cached != null) return List<Tag>.unmodifiable(cached);
    final tags = await _tagDao.getTagsForTrack(trackId);
    _trackTags[trackId] = List<Tag>.of(tags);
    return List<Tag>.unmodifiable(_trackTags[trackId]!);
  }

  Future<List<Tag>> getImageTags(int imageId) async {
    final cached = _imageTags[imageId];
    if (cached != null) return List<Tag>.unmodifiable(cached);
    final tags = await _tagDao.getTagsForImage(imageId);
    _imageTags[imageId] = List<Tag>.of(tags);
    return List<Tag>.unmodifiable(_imageTags[imageId]!);
  }

  /// 图片与视频通用：读单个媒体已绑定的标签（视频卡片菜单用）。
  Future<List<Tag>> getTagsForMedia(int mediaId) async {
    final cached = _imageTags[mediaId];
    if (cached != null) return List<Tag>.unmodifiable(cached);
    final tags = await _tagDao.getTagsForTrack(mediaId);
    _imageTags[mediaId] = List<Tag>.of(tags);
    return List<Tag>.unmodifiable(_imageTags[mediaId]!);
  }

  /// 切换曲目标签。同一曲目的多次调用按顺序串行执行。
  ///
  /// 连点两次同一个标签时，第二次必须在第一次写库并更新缓存之后才读当前状态；
  /// 否则两次都读到「未打标签」，双击「关标签」会变成打开。
  Future<void> toggleTagOnTrack(int trackId, Tag tag) =>
      _queueTagToggle(trackId, image: false, tag: tag);

  /// 切换图片标签。串行语义与 [toggleTagOnTrack] 相同。
  Future<void> toggleTagOnImage(int imageId, Tag tag) =>
      _queueTagToggle(imageId, image: true, tag: tag);

  Future<void> _queueTagToggle(int mediaId,
      {required bool image, required Tag tag}) {
    final previous = _tagToggleChains[mediaId] ?? Future<void>.value();
    final chain =
        previous.then((_) => _applyTagToggle(mediaId, tag, image: image));
    // 链尾只保留不会失败的 future：前一次出错不能卡住后面的点击。
    final tail = chain.catchError((Object _) {});
    _tagToggleChains[mediaId] = tail;
    unawaited(tail.whenComplete(() {
      if (identical(_tagToggleChains[mediaId], tail)) {
        _tagToggleChains.remove(mediaId);
      }
    }));
    return chain;
  }

  /// media_tags 以 media.id 为键，曲目与图片共用；只有内存缓存分两份。
  Future<void> _applyTagToggle(int mediaId, Tag tag,
      {required bool image}) async {
    final cache = image ? _imageTags : _trackTags;
    // 改副本，缓存里的 List 不被就地修改；调用方拿到的也是不可变视图。
    final current = List<Tag>.of(cache[mediaId] ??
        (image
            ? await _tagDao.getTagsForImage(mediaId)
            : await _tagDao.getTagsForTrack(mediaId)));
    final has = current.any((t) => t.id == tag.id);
    if (has) {
      if (image) {
        await _tagDao.removeTagFromImage(mediaId, tag.id!);
      } else {
        await _tagDao.removeTagFromTrack(mediaId, tag.id!);
      }
      current.removeWhere((t) => t.id == tag.id);
    } else {
      if (image) {
        await _tagDao.addTagToImage(mediaId, tag.id!);
      } else {
        await _tagDao.addTagToTrack(mediaId, tag.id!);
      }
      current.add(tag);
    }
    cache[mediaId] = current;
    notifyListeners();
  }

  Future<void> addTagToFolder(int folderId, Tag tag) async {
    await addTagsToFolder(folderId, [tag]);
  }

  /// 为文件夹批量添加标签；[recursive] 为真时递归同步到其所有子文件夹曲目。
  Future<void> addTagsToFolder(int folderId, List<Tag> tags,
      {bool recursive = false}) async {
    for (final tag in tags) {
      await _tagDao.addTagToFolder(folderId, tag.id!);
    }
    if (recursive) {
      final trackIds = await _collectFolderTrackIds(folderId);
      await _tagDao.addTagsToTracks(trackIds, tags.map((t) => t.id!));
    }
    _folderVersion++;
    notifyListeners();
  }

  Future<void> removeTagsFromFolder(int folderId, List<Tag> tags,
      {bool recursive = false}) async {
    if (recursive) {
      final trackIds = await _collectFolderTrackIds(folderId);
      await _tagDao.removeTagsFromTracks(trackIds, tags.map((t) => t.id!));
    }
    for (final tag in tags) {
      await _tagDao.removeTagFromFolder(folderId, tag.id!);
    }
    _folderVersion++;
    notifyListeners();
  }

  /// 收集文件夹及其所有子文件夹下的曲目 id（按路径前缀）
  Future<Set<int>> _collectFolderTrackIds(int folderId) async {
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
    if (paths.isEmpty) return {};
    final tracks = await _trackDao.queryByDirs(paths);
    return tracks.map((t) => t.id).whereType<int>().toSet();
  }

  Future<List<Tag>> getFolderTags(int folderId) =>
      _tagDao.getTagsForFolder(folderId);

  /// 规则标签由软件按扩展名或媒体类型自动补行，删掉下次启动还会回来。
  static bool isRuleTag(Tag tag) => TagDao.ruleNamespaces.contains(tag.namespace);

  /// 按名字找标签。给了命名空间就精确匹配，没给就跨命名空间找第一个。
  Tag? findTagByName(String name, {String? namespace}) {
    final target = name.trim().toLowerCase();
    if (target.isEmpty) return null;
    for (final t in _allTags) {
      if (t.name.toLowerCase() != target) continue;
      if (namespace == null || t.namespace == namespace) return t;
    }
    return null;
  }

  /// 标签被多少条媒体、多少个文件夹引用（删除前提示用）。
  Future<({int media, int folders})> tagUsageCounts(int tagId) =>
      _tagDao.countUsage(tagId);

  /// 标签库里出现过的命名空间（新建标签时给输入框做联想）。
  List<String> get knownNamespaces {
    final names = _allTags.map((t) => t.namespace).toSet().toList()..sort();
    return names;
  }

  Future<Tag> createTag(String name,
      {String namespace = '', String color = '#cba6f7'}) async {
    final ns = namespace.isEmpty ? 'general' : namespace;
    final match = _allTags.where((t) =>
        t.name.toLowerCase() == name.toLowerCase() && t.namespace == ns);
    if (match.isNotEmpty) return match.first;
    final tag = await _tagDao.insert(Tag(name: name, namespace: ns, color: color));
    await loadTags();
    return tag;
  }

  Future<void> deleteTag(int tagId) async {
    await _tagDao.delete(tagId);
    _trackTags.clear();
    _imageTags.clear();
    _removeFromFilter(tagId);
    await loadTags();
    await refresh();
  }

  /// 更新标签（重命名 / 改命名空间 / 改色）
  Future<void> updateTag(int tagId, String name,
      {String? namespace, String? color}) async {
    final existing = await _tagDao.getById(tagId);
    if (existing == null) return;
    await _tagDao.update(Tag(
      id: tagId,
      namespace: namespace ?? existing.namespace,
      name: name,
      color: color ?? existing.color,
    ));
    _trackTags.clear();
    _imageTags.clear();
    await loadTags();
    await refresh();
  }

  // ═══════════════ 曲目多选 + 批量标签 ═══════════════

  void toggleTrackSelect(int id) {
    if (_selectedTrackIds.contains(id)) {
      _selectedTrackIds.remove(id);
    } else {
      _selectedTrackIds.add(id);
    }
    _anchorTrackId = id;
    notifyListeners();
  }

  void rangeTrackSelect(int id) {
    final list = _tracks;
    final anchorIdx = _anchorTrackId == null
        ? -1
        : list.indexWhere((t) => t.id == _anchorTrackId);
    final curIdx = list.indexWhere((t) => t.id == id);
    if (anchorIdx < 0 || curIdx < 0) {
      toggleTrackSelect(id);
      return;
    }
    final lo = anchorIdx < curIdx ? anchorIdx : curIdx;
    final hi = anchorIdx < curIdx ? curIdx : anchorIdx;
    for (final t in list.sublist(lo, hi + 1)) {
      if (t.id != null) _selectedTrackIds.add(t.id!);
    }
    _anchorTrackId = id;
    notifyListeners();
  }

  /// 长按进入多选模式（移动端）；桌面 Ctrl+点击也可走此路径
  void enterSelectionMode(int id) {
    _selectionMode = true;
    _selectedTrackIds.add(id);
    _anchorTrackId = id;
    notifyListeners();
  }

  void clearTrackSelection() {
    _selectionMode = false;
    _selectedTrackIds.clear();
    _anchorTrackId = null;
    notifyListeners();
  }

  /// 只开多选模式，不预先选中任何曲目（工具条的「选择」按钮走这条路）
  void enterTrackSelectionMode() {
    _selectionMode = true;
    notifyListeners();
  }

  /// 选中当前列表里的全部曲目（多选工具条的「全选」）
  void selectAllTracks() {
    _selectionMode = true;
    _selectedTrackIds
      ..clear()
      ..addAll(_tracks.map((t) => t.id).whereType<int>());
    _anchorTrackId = _tracks.isEmpty ? null : _tracks.first.id;
    notifyListeners();
  }

  Future<void> addTagsToTracks(Iterable<int> trackIds, List<Tag> tags) async {
    await _tagDao.addTagsToTracks(trackIds, tags.map((t) => t.id!));
    _trackTags.clear();
    notifyListeners();
  }

  Future<void> removeTagsFromTracks(
      Iterable<int> trackIds, List<Tag> tags) async {
    await _tagDao.removeTagsFromTracks(trackIds, tags.map((t) => t.id!));
    _trackTags.clear();
    notifyListeners();
  }

  /// 返回这批曲目上已绑定的标签 id 集合（用于「移除标签」时过滤可选项）
  Future<Set<int>> getTagIdsOnTracks(Iterable<int> trackIds) async {
    final ids = trackIds.toList();
    if (ids.isEmpty) return {};
    final map = await _tagDao.getTagsForTracks(ids);
    final result = <int>{};
    for (final tags in map.values) {
      for (final t in tags) {
        if (t.id != null) result.add(t.id!);
      }
    }
    return result;
  }

  // ── 图片批量标签 ──

  Future<void> addTagsToImages(Iterable<int> imageIds, List<Tag> tags) async {
    for (final t in tags) {
      await _tagDao.addTagsToTracks(imageIds, [t.id!]);
    }
    _imageTags.clear();
    notifyListeners();
  }

  Future<void> removeTagsFromImages(
      Iterable<int> imageIds, List<Tag> tags) async {
    for (final t in tags) {
      await _tagDao.removeTagsFromTracks(imageIds, [t.id!]);
    }
    _imageTags.clear();
    notifyListeners();
  }

  /// 返回这批图片上已绑定的标签 id 集合（用于「移除标签」时过滤可选项）
  Future<Set<int>> getTagIdsOnImages(Iterable<int> imageIds) async {
    final ids = imageIds.toList();
    if (ids.isEmpty) return {};
    final map = await _tagDao.getTagsForImages(ids);
    final result = <int>{};
    for (final tags in map.values) {
      for (final t in tags) {
        if (t.id != null) result.add(t.id!);
      }
    }
    return result;
  }

  /// 覆盖设置单个媒体的标签集（视频卡片菜单用）。
  ///
  /// 媒体行不分类型，图片与视频都存 `media_tags`，所以这里复用曲目的写入口。
  Future<void> setMediaTags(int mediaId, List<Tag> tags) async {
    await _tagDao.setTrackTags(mediaId, [
      for (final t in tags)
        if (t.id != null) t.id!,
    ]);
    _imageTags.clear();
    if (_tagFilter.active || hasAdvancedFilter) {
      await refresh();
    } else {
      notifyListeners();
    }
  }

  /// 图片与视频通用的批量标签入口，媒体行统一存 `media_tags`。
  Future<void> addTagsToMedia(Iterable<int> mediaIds, List<Tag> tags) =>
      addTagsToImages(mediaIds, tags);

  Future<void> removeTagsFromMedia(Iterable<int> mediaIds, List<Tag> tags) =>
      removeTagsFromImages(mediaIds, tags);

  Future<Set<int>> getTagIdsOnMedia(Iterable<int> mediaIds) =>
      getTagIdsOnImages(mediaIds);

  /// 当前标签筛选（AND ∪ OR ∪ NOT）里出现的全部标签 id。
  Set<int> get activeTagIds => {
        ..._tagFilter.andTagIds,
        ..._tagFilter.orTagIds,
        ..._tagFilter.notTagIds,
      };

  void _removeFromFilter(int tagId) {
    _tagFilter = TagFilter(
      andTagIds: _tagFilter.andTagIds.where((id) => id != tagId).toList(),
      orTagIds: _tagFilter.orTagIds.where((id) => id != tagId).toList(),
      notTagIds: _tagFilter.notTagIds.where((id) => id != tagId).toList(),
    );
    _persistNotTagIds();
  }

  // 标签筛选
  void toggleAndFilter(int tagId) {
    _advancedFilter = '';
    final list = List<int>.from(_tagFilter.andTagIds);
    list.contains(tagId) ? list.remove(tagId) : list.add(tagId);
    _tagFilter = TagFilter(
      andTagIds: list,
      orTagIds: _tagFilter.orTagIds.where((id) => id != tagId).toList(),
      notTagIds: _tagFilter.notTagIds.where((id) => id != tagId).toList(),
    );
    refresh();
  }

  void toggleOrFilter(int tagId) {
    _advancedFilter = '';
    final list = List<int>.from(_tagFilter.orTagIds);
    list.contains(tagId) ? list.remove(tagId) : list.add(tagId);
    _tagFilter = TagFilter(
      andTagIds: _tagFilter.andTagIds.where((id) => id != tagId).toList(),
      orTagIds: list,
      notTagIds: _tagFilter.notTagIds.where((id) => id != tagId).toList(),
    );
    _persistNotTagIds();
    refresh();
  }

  void toggleNotFilter(int tagId) {
    _advancedFilter = '';
    final list = List<int>.from(_tagFilter.notTagIds);
    list.contains(tagId) ? list.remove(tagId) : list.add(tagId);
    _tagFilter = TagFilter(
      andTagIds: _tagFilter.andTagIds.where((id) => id != tagId).toList(),
      orTagIds: _tagFilter.orTagIds.where((id) => id != tagId).toList(),
      notTagIds: list,
    );
    _persistNotTagIds();
    refresh();
  }

  void clearTagFilters() {
    _tagFilter = const TagFilter();
    _persistNotTagIds();
    refresh();
  }

  Future<void> setAdvancedFilter(String expression) async {
    final expr = expression.trim();
    if (expr.isEmpty) {
      await clearAdvancedFilter();
      return;
    }
    FilterExpressionParser.parse(expr);
    _advancedFilter = expr;
    _tagFilter = const TagFilter();
    await SettingsService.instance.addExpression(expr);
    await refresh();
  }

  Future<void> clearAdvancedFilter() async {
    if (!hasAdvancedFilter) return;
    _advancedFilter = '';
    await refresh();
  }

  // ═══════════════ 播放 ═══════════════

  /// 播放当前列表从 [startIndex] 开始
  Future<void> playTracks(List<TrackItem> list, int startIndex) async {
    _rememberQueueCover();
    await player.playQueue(list, startIndex: startIndex);
  }

  Future<void> playAllCurrent() async {
    if (_tracks.isEmpty) return;
    _rememberQueueCover();
    await player.playQueue(_tracks, startIndex: 0);
  }

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
    await playTracks(tracks, 0);
  }

  /// 播放某个目录下的音频（多媒体栏点音频磁贴走这里）。
  ///
  /// 目录里的音频行组成本目录的专辑队列：先按音频类型取行，排成与网格一致的
  /// 顺序，再换成 TrackItem，与音频栏同源。传 [startMediaId] 就从那一首开始。
  /// 本目录里的音频，按当前排序拍成播放队列（多媒体栏的音频专辑式播放）。
  ///
  /// 图片与视频行不进来：专辑只装音频，双击视频是外链、双击图片是阅读。
  Future<List<TrackItem>> audioQueueInDir(String dirPath) async {
    final rows =
        await _mediaDao.queryDirectInDir(dirPath, type: MediaType.audio);
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
    await playTracks(queue, queueStartIndex(queue, startMediaId));
  }

  /// 播放某个作品全部卷下的曲目
  Future<void> playWorkAll(int workId) async {
    final paths = await _folderDao.getPathsByWork(workId);
    if (paths.isEmpty) return;
    final tracks = await _trackDao.queryByDirs(paths);
    if (tracks.isEmpty) return;
    await playTracks(tracks, 0);
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
      String title, List<String> dirPaths, MediaType type) async {
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
              path: m.path, title: m.title ?? m.filename, durationMs: m.durationMs),
      ],
    );
    return _launcher.open(file);
  }

  // ═══════════════ 收藏选段（BUILD_GUIDE 第 24.3 节）═══════════════

  /// 载入当前曲目的选段。没有曲目时清空列表。
  Future<void> reloadSegments() async {
    final id = player.currentTrack?.id;
    if (id == null) {
      _assignSegments(const []);
      return;
    }
    await _reloadSegments(id);
  }

  Future<void> _reloadSegments(int mediaId) async {
    _assignSegments(await _segmentService.listByMedia(mediaId));
  }

  /// 列表真的变了才通知：切歌时顺带载入选段，不该多出无谓的重建。
  void _assignSegments(List<MediaSegment> list) {
    if (_sameSegments(_segments, list)) return;
    _segments = list;
    notifyListeners();
  }

  static bool _sameSegments(List<MediaSegment> a, List<MediaSegment> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// 保存一段选区。起止按当前曲目时长收口。
  Future<MediaSegment?> addSegment({
    required int startMs,
    required int endMs,
    String? name,
  }) async {
    final id = player.currentTrack?.id;
    if (id == null) return null;
    final seg = await _segmentService.add(
      mediaId: id,
      startMs: startMs,
      endMs: endMs,
      durationMs: player.duration.inMilliseconds,
      name: name,
    );
    await _reloadSegments(id);
    return seg;
  }

  Future<void> renameSegment(MediaSegment seg, String? name) async {
    final id = seg.id;
    if (id == null) return;
    await _segmentService.rename(id, name);
    await reloadSegments();
  }

  /// 删除一段。删掉的正是当前循环段时同时关掉选区循环。
  Future<void> deleteSegment(MediaSegment seg) async {
    final id = seg.id;
    if (id == null) return;
    final looping = player.loopSegment;
    if (looping != null && looping.id == id) {
      await player.setLoopSegment(null);
    }
    await _segmentService.remove(id);
    await reloadSegments();
  }

  /// 开启或关闭选段循环。[seg] 为 null 时关闭。
  Future<void> loopSegment(MediaSegment? seg) => player.setLoopSegment(seg);

  /// 跳到段首播放
  Future<void> jumpToSegment(MediaSegment seg) =>
      player.seek(Duration(milliseconds: seg.startMs));

  Future<void> playTrackAt(int index) async {
    if (index < 0 || index >= _tracks.length) return;
    _rememberQueueCover();
    await player.playQueue(_tracks, startIndex: index);
  }

  // ═══════════════ 字幕 / 封面 ═══════════════

  /// 读一首曲目的字幕，结果按曲目路径缓存（BUILD_GUIDE 第 23.3 节）。
  ///
  /// 返回 [SubtitleDocument]：界面据 [SubtitleDocument.parsed] 判断格式是否
  /// 可解析，据 [SubtitleDocument.hasTiming] 判断要不要做逐行同步。
  SubtitleDocument subtitleFor(TrackItem track) {
    final p = track.subtitlePath;
    if (p == null || p.isEmpty) return SubtitleDocument.empty;
    return _subtitleCache.putIfAbsent(
        track.path, () => SubtitleParser.parseFile(p));
  }

  Future<void> replaceSubtitle(int trackId, String newPath) async {
    await _trackDao.setSubtitlePath(trackId, newPath);
    _subtitleCache.clear();
    // 更新内存中的曲目
    _tracks = _tracks
        .map((t) => t.id == trackId
            ? t.copyWith(subtitlePath: newPath)
            : t)
        .toList();
    notifyListeners();
  }

  Future<void> clearSubtitle(int trackId) async {
    await _trackDao.setSubtitlePath(trackId, null);
    _subtitleCache.clear();
    _tracks = _tracks
        .map((t) => t.id == trackId ? t.copyWith(subtitlePath: null) : t)
        .toList();
    notifyListeners();
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
    final workCover = _currentWork?.coverPath;
    if (workCover != null && workCover.isNotEmpty) return workCover;
    return null;
  }

  /// 当前曲目封面：优先队列来源作品的封面，否则曲目内嵌封面。
  ///
  /// 用播放队列建立时记下的作品封面，而不是「当前浏览的作品」，
  /// 播放中切换浏览对象不会把播放栏与通知栏的封面换掉。
  String? coverForTrack(TrackItem track) {
    final wc = _playingWorkCover;
    if (wc != null && wc.isNotEmpty) return wc;
    final own = track.coverPath;
    return own != null && own.isNotEmpty ? own : null;
  }

  /// 记下这次播放队列对应的作品封面。
  void _rememberQueueCover() {
    _playingWorkCover = _currentWork?.coverPath;
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
    if (_importing) {
      throw StateError('正在导入，等导入结束再迁移数据目录');
    }
    _migrating = true;
    final oldDir = await DataDirService.instance.dataDir;
    try {
      // 关库前先前进一代：在途的 refresh 拿到结果后发现代际不匹配会主动丢弃，
      // 不会去写已经关掉的连接。
      _refreshGeneration++;
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

  void _onTrackStarted(TrackItem track) {
    final id = track.id;
    if (id == null) return;
    unawaited(_reloadSegments(id));
    final gen = ++_recentLoadGeneration;
    unawaited(_trackDao
        .recordPlay(id, DateTime.now().millisecondsSinceEpoch)
        .then((_) => _reloadRecentTracks(gen))
        .catchError((Object e) {
      logError('AppState', 'recordPlay 失败: $e');
    }));
  }

  /// 续播位置：太靠前、或快听完的位置都从头开始（见 PlayPositionRules）。
  Duration _resumePositionOf(TrackItem track) =>
      PlayPositionRules.resumeOf(track.playPositionMs, track.durationMs);

  /// 播放中每 250 毫秒报一次位置，按前进量节流后才写库。
  void _onPlayPosition(TrackItem track, Duration position) {
    final id = track.id;
    if (id == null) return;
    if (!_positionThrottle.shouldSave(position)) return;
    _savePlayPosition(id, position.inMilliseconds);
  }

  /// 一首播到结尾：位置清零，下次从头播。
  void _onTrackCompleted(TrackItem track) {
    final id = track.id;
    if (id == null) return;
    _positionThrottle.reset();
    _savePlayPosition(id, 0);
  }

  void _savePlayPosition(int mediaId, int positionMs) {
    unawaited(_mediaDao.setPlayPosition(mediaId, positionMs).then((_) {
      // 磁贴右侧的「已播时间」跟着刷新
      _applyPlayPosition(mediaId, positionMs);
    }).catchError((Object e) {
      logError('AppState', '播放位置落盘失败: $e');
    }));
  }

  /// 把新位置同步进内存里的曲目列表（不重新查库）。
  void _applyPlayPosition(int mediaId, int positionMs) {
    var changed = false;
    final next = <TrackItem>[];
    for (final track in _tracks) {
      if (track.id == mediaId && track.playPositionMs != positionMs) {
        changed = true;
        next.add(track.copyWith(playPositionMs: positionMs));
      } else {
        next.add(track);
      }
    }
    if (!changed) return;
    _tracks = next;
    notifyListeners();
  }

  Future<void> loadRecentTracks() => _reloadRecentTracks(_recentLoadGeneration);

  /// 只有最后一次触发的重载能写回结果。
  ///
  /// 快速切歌会并发触发多次 recordPlay 与多次重载，先发起的那次可能后完成。
  Future<void> _reloadRecentTracks(int gen) async {
    final list = await _trackDao.recentPlayedTracks();
    if (gen != _recentLoadGeneration) {
      logInfo('AppState', 'recent gen=$gen 已被取代，丢弃结果');
      return;
    }
    _recentTracks = list;
    notifyListeners();
  }

  Future<void> playRecentTracks(int startIndex) async {
    if (_recentTracks.isEmpty) return;
    // 最近播放跨作品，没有单一来源封面，回退到每首曲目自己的封面。
    _playingWorkCover = null;
    await player.playQueue(_recentTracks, startIndex: startIndex);
  }

  // ═══════════════ 封面缓存管理 ═══════════════

  Future<void> loadCoverCacheLimit() async {
    _coverCacheLimitMB = SettingsService.instance.coverCacheLimitMB;
  }

  Future<int> getCoverCacheSizeBytes() =>
      CoverService.embeddedCacheSizeBytes();

  Future<int> clearCoverCache() async {
    final freed = await CoverService.clearEmbeddedCache();
    notifyListeners();
    return freed;
  }

  Future<void> setCoverCacheLimit(int mb) async {
    _coverCacheLimitMB = mb.clamp(0, 8192);
    await SettingsService.instance.setCoverCacheLimitMB(_coverCacheLimitMB);
    if (_coverCacheLimitMB > 0) {
      await CoverService.enforceLimit(_coverCacheLimitMB * 1024 * 1024,
          keep: _protectedCoverPaths());
    }
    notifyListeners();
  }

  Future<void> enforceCoverCacheLimit() async {
    if (_coverCacheLimitMB <= 0) return;
    await CoverService.enforceLimit(_coverCacheLimitMB * 1024 * 1024,
        keep: _protectedCoverPaths());
  }

  /// 清理封面缓存时不能删的封面：正在播放的曲目、当前浏览作品的封面
  Set<String> _protectedCoverPaths() {
    final keep = <String>{};
    final playing = player.currentTrack?.coverPath;
    if (playing != null) keep.add(playing);
    final work = _currentWork?.coverPath;
    if (work != null) keep.add(work);
    return keep;
  }
}
