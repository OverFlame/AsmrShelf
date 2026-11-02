import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../utils/file_io.dart';
import '../utils/log_util.dart';
import 'data_dir_service.dart';
import 'subtitle_style.dart';

/// 持久化设置服务（JSON 文件，位于数据目录 settings.json）。
class SettingsService {
  SettingsService._();

  static final SettingsService instance = SettingsService._();

  Map<String, dynamic> _data = {};

  Future<File> _file() async {
    return File(p.join(await DataDirService.instance.dataDir, 'settings.json'));
  }

  Future<void> init() async {
    final f = await _file();
    _data = {};
    if (f.existsSync()) {
      try {
        _data = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      } catch (e) {
        logWarn('Settings', '解析 settings.json 失败: $e');
        _data = {};
      }
    }
    logInfo('Settings', 'Initialized OK');
  }

  /// 保存串行链。两次保存交错时 writeAsString 的截断与写入会互相穿插，
  /// 留下半个 JSON；这里让保存排队，写文件本身也做成先写临时文件再改名。
  Future<void> _saveChain = Future<void>.value();

  Future<void> _save() {
    final next = _saveChain.then((_) => _writeSettingsFile());
    // 链尾只保留不会失败的 future：一次写失败不能卡住后面的保存。
    _saveChain = next.catchError((Object _) {});
    return next;
  }

  Future<void> _writeSettingsFile() async {
    final f = await _file();
    // 先写临时文件，再改名。读者要么看到完整旧内容，要么看到完整新内容。
    await writeFileAtomic(
      f,
      (tmp) => tmp.writeAsString(jsonEncode(_data), flush: true),
    );
  }

  /// 清空内存状态并重置保存链，仅供测试。
  @visibleForTesting
  void resetForTest() {
    _data = {};
    _saveChain = Future<void>.value();
  }

  // ── 主题 ──
  ThemeMode get themeMode {
    final v = _data['theme_mode'] as String? ?? 'dark';
    return switch (v) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    _data['theme_mode'] = switch (mode) {
      ThemeMode.light => 'light',
      ThemeMode.dark => 'dark',
      _ => 'system',
    };
    await _save();
  }

  // ── 默认排除的标签 ──

  /// 用户排除（NOT）的标签 id。返回 null 表示还没写过，首次启动按规则填。
  List<int>? get excludedTagIds {
    final raw = _data['excluded_tag_ids'];
    if (raw is! List) return null;
    return raw.whereType<int>().toList();
  }

  Future<void> setExcludedTagIds(List<int> ids) async {
    _data['excluded_tag_ids'] = ids;
    await _save();
  }

  // ── 标签面板折叠的命名空间 ──

  /// 收起来的命名空间。返回 null 表示用户还没动过，首次启动按规则折叠扩展名。
  List<String>? get collapsedTagNamespaces {
    final raw = _data['collapsed_namespaces'];
    if (raw is! List) return null;
    return raw.whereType<String>().toList();
  }

  Future<void> setCollapsedTagNamespaces(List<String> namespaces) async {
    _data['collapsed_namespaces'] = namespaces;
    await _save();
  }

  // ── 曲目排序 ──
  String get sortKey => (_data['sort_key'] as String?) ?? 'filename';

  Future<void> setSortKey(String key) async {
    _data['sort_key'] = key;
    await _save();
  }

  bool get sortDescending => (_data['sort_desc'] as bool?) ?? false;

  Future<void> setSortDescending(bool desc) async {
    _data['sort_desc'] = desc;
    await _save();
  }

  // ── 图片 / 视频库排序 ──
  //
  // 字段：`name`（自然序）/ `mtime` / `size` / `added`。与音频的 `sort_key`
  // 分开存：三个库的关注点不一样，改视频的顺序不该动图片的顺序。

  String get imageSortKey => (_data['image_sort_key'] as String?) ?? 'name';

  Future<void> setImageSortKey(String key) async {
    _data['image_sort_key'] = key;
    await _save();
  }

  bool get imageSortDescending => (_data['image_sort_desc'] as bool?) ?? false;

  Future<void> setImageSortDescending(bool desc) async {
    _data['image_sort_desc'] = desc;
    await _save();
  }

  String get videoSortKey => (_data['video_sort_key'] as String?) ?? 'name';

  Future<void> setVideoSortKey(String key) async {
    _data['video_sort_key'] = key;
    await _save();
  }

  bool get videoSortDescending => (_data['video_sort_desc'] as bool?) ?? false;

  Future<void> setVideoSortDescending(bool desc) async {
    _data['video_sort_desc'] = desc;
    await _save();
  }

  // 作品层排序：作品只有名称与加入时间，默认「加入时间倒序」保持新作品在前。
  String get worksSortKey => (_data['works_sort_key'] as String?) ?? 'added';

  Future<void> setWorksSortKey(String key) async {
    _data['works_sort_key'] = key;
    await _save();
  }

  bool get worksSortDescending => (_data['works_sort_desc'] as bool?) ?? true;

  Future<void> setWorksSortDescending(bool desc) async {
    _data['works_sort_desc'] = desc;
    await _save();
  }

  // ── 高级筛选表达式历史 ──
  List<String> get expressionHistory {
    final raw = _data['expr_history'];
    if (raw is List) return raw.whereType<String>().toList();
    return const [];
  }

  int get maxExprCacheCount => (_data['expr_cache_count'] as int?) ?? 10;

  Future<void> setMaxExprCacheCount(int count) async {
    _data['expr_cache_count'] = count.clamp(0, 100);
    await _save();
    final list = expressionHistory;
    final cap = _data['expr_cache_count'] as int;
    if (list.length > cap) {
      _data['expr_history'] = list.sublist(0, cap);
      await _save();
    }
  }

  Future<void> addExpression(String expression) async {
    final expr = expression.trim();
    if (expr.isEmpty) return;
    final list = expressionHistory.where((e) => e != expr).toList();
    list.insert(0, expr);
    final cap = maxExprCacheCount;
    _data['expr_history'] = cap <= 0
        ? const <String>[]
        : list.take(cap).toList();
    await _save();
  }

  Future<void> clearExpressionHistory() async {
    _data['expr_history'] = const <String>[];
    await _save();
  }

  // ── 封面缓存上限（MB，0 表示不限制）──
  int get coverCacheLimitMB => (_data['cover_cache_mb'] as int?) ?? 512;

  Future<void> setCoverCacheLimitMB(int mb) async {
    _data['cover_cache_mb'] = mb.clamp(0, 8192);
    await _save();
  }

  /// 存量多媒体作品是否已补过默认封面。只跑一次，避免每次启动都扫库。
  bool get autoCoverBackfillDone =>
      (_data['auto_cover_backfill_done'] as bool?) ?? false;

  Future<void> setAutoCoverBackfillDone(bool done) async {
    _data['auto_cover_backfill_done'] = done;
    await _save();
  }

  // ── 自动导入 ──
  /// 启动时是否自动扫描下面的根目录，把新作品导进来。
  bool get autoImportEnabled =>
      (_data['auto_import_enabled'] as bool?) ?? false;

  Future<void> setAutoImportEnabled(bool enabled) async {
    _data['auto_import_enabled'] = enabled;
    await _save();
  }

  /// 自动导入的根目录。每部作品占一个子目录，与手动「导入目录」同一套扫描。
  String? get autoImportRoot {
    final v = _data['auto_import_root'] as String?;
    if (v == null || v.trim().isEmpty) return null;
    return v;
  }

  Future<void> setAutoImportRoot(String? root) async {
    final v = root?.trim();
    if (v == null || v.isEmpty) {
      _data.remove('auto_import_root');
    } else {
      _data['auto_import_root'] = v;
    }
    await _save();
  }

  /// 上一次自动导入的时间（毫秒时间戳），没有跑过时为 null。
  int? get lastAutoImportAt => _data['last_auto_import_at'] as int?;

  Future<void> setLastAutoImportAt(int millis) async {
    _data['last_auto_import_at'] = millis;
    await _save();
  }

  // ── 图片视图 ──

  /// 网格列数，默认 4
  int get gridColumns => (_data['grid_columns'] as int?) ?? 4;

  Future<void> setGridColumns(int cols) async {
    _data['grid_columns'] = cols.clamp(2, 10);
    await _save();
  }

  // ── 界面布局 ──

  /// 左栏宽度。默认 260，允许 200 至 420。
  static const double defaultLeftWidth = 260;
  static const double minLeftWidth = 200;
  static const double maxLeftWidth = 420;

  /// 作品集列表高度。默认 200，允许 140 至 480。
  static const double defaultLibraryHeight = 200;
  static const double minLibraryHeight = 140;
  static const double maxLibraryHeight = 480;

  double get leftWidth => _clampDouble(
    _data['layout_left_width'],
    defaultLeftWidth,
    minLeftWidth,
    maxLeftWidth,
  );

  Future<void> setLeftWidth(double width) async {
    _data['layout_left_width'] = _clampDouble(
      width,
      defaultLeftWidth,
      minLeftWidth,
      maxLeftWidth,
    );
    await _save();
  }

  double get libraryHeight => _clampDouble(
    _data['layout_library_height'],
    defaultLibraryHeight,
    minLibraryHeight,
    maxLibraryHeight,
  );

  Future<void> setLibraryHeight(double height) async {
    _data['layout_library_height'] = _clampDouble(
      height,
      defaultLibraryHeight,
      minLibraryHeight,
      maxLibraryHeight,
    );
    await _save();
  }

  /// 读配置时的统一夹取：键缺失、类型不对、值越界都退回合法范围。
  double _clampDouble(Object? raw, double fallback, double min, double max) {
    final value = raw is num ? raw.toDouble() : fallback;
    if (value.isNaN) return fallback;
    return value.clamp(min, max);
  }

  /// 图片视图模式：grid / list，默认 grid
  String get viewMode => (_data['view_mode'] as String?) ?? 'grid';

  Future<void> setViewMode(String mode) async {
    _data['view_mode'] = mode == 'list' ? 'list' : 'grid';
    await _save();
  }

  // ── 播放设置 ──

  /// 循环模式名：off / all / one
  String get repeatModeName => (_data['repeat_mode'] as String?) ?? 'all';

  Future<void> setRepeatModeName(String name) async {
    _data['repeat_mode'] = switch (name) {
      'off' => 'off',
      'one' => 'one',
      _ => 'all',
    };
    await _save();
  }

  /// 随机播放开关
  bool get shuffle => (_data['shuffle'] as bool?) ?? false;

  Future<void> setShuffle(bool on) async {
    _data['shuffle'] = on;
    await _save();
  }

  /// 播放速度，钳制在 0.5 与 2.0 之间
  double get playSpeed {
    final v = _data['play_speed'];
    final d = v is num ? v.toDouble() : 1.0;
    return d.clamp(0.5, 2.0).toDouble();
  }

  Future<void> setPlaySpeed(double speed) async {
    _data['play_speed'] = speed.clamp(0.5, 2.0).toDouble();
    await _save();
  }

  // ── 字幕页 ──
  //
  // 两次间隔：非当前句的透明度（由用户固定，或按当前音轨封面的明暗自动算）
  // 与用户滑过之后不再自动回正的秒数。

  /// 非当前句的透明度是否按封面亮度自动算。默认开。
  bool get subtitleOpacityAuto =>
      (_data['subtitle_opacity_auto'] as bool?) ?? true;

  Future<void> setSubtitleOpacityAuto(bool auto) async {
    _data['subtitle_opacity_auto'] = auto;
    await _save();
  }

  /// 固定模式下非当前句的透明度。
  double get subtitleInactiveOpacity {
    final v = _data['subtitle_inactive_opacity'];
    final d = v is num ? v.toDouble() : SubtitleStyle.defaultInactiveOpacity;
    return SubtitleStyle.clampInactiveOpacity(d);
  }

  Future<void> setSubtitleInactiveOpacity(double value) async {
    _data['subtitle_inactive_opacity'] = SubtitleStyle.clampInactiveOpacity(
      value,
    );
    await _save();
  }

  /// 滑动之后留在原地的秒数：这段时间内不自动回到正在播放的那一句。
  int get subtitleResumeSeconds =>
      ((_data['subtitle_resume_seconds'] as int?) ??
              defaultSubtitleResumeSeconds)
          .clamp(minSubtitleResumeSeconds, maxSubtitleResumeSeconds);

  Future<void> setSubtitleResumeSeconds(int seconds) async {
    _data['subtitle_resume_seconds'] = seconds.clamp(
      minSubtitleResumeSeconds,
      maxSubtitleResumeSeconds,
    );
    await _save();
  }

  static const int minSubtitleResumeSeconds = 2;
  static const int maxSubtitleResumeSeconds = 60;
  static const int defaultSubtitleResumeSeconds = 8;
}
