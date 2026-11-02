import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart';
import 'package:sqflite_common/sqlite_api.dart';

import '../db/media_dao.dart';
import '../db/track_dao.dart';
import '../services/cover_service.dart';
import '../services/settings_service.dart';
import '../services/volume_cover_service.dart';

/// 封面相关状态：卷封面与裁剪、播放队列来源封面、封面缓存上限与驱逐。
///
/// 拆分自 [AppState]。这里不 import 别的状态对象；判断「哪些封面不能删」
/// 需要知道正在播放的曲目和当前作品，所以由 AppState 注入
/// [protectedPaths] 回调，而不是反向依赖播放与作品库。
class CoverState extends ChangeNotifier {
  CoverState({
    required this.db,
    Set<String> Function()? protectedPaths,
  }) : _protectedPaths = protectedPaths ?? (() => const {});

  /// 库连接用工厂传入：`AppState.init` 才打开库。
  final Database Function() db;

  /// 驱逐缓存时不能删的封面路径。没接线时视为没有保护项。
  final Set<String> Function() _protectedPaths;

  VolumeCoverService get _volumeCovers => VolumeCoverService(db());

  // ── 卷封面与裁剪 ──

  /// 卷封面或裁剪改动后自增，界面据此重新读取封面。
  int _coverVersion = 0;
  int get coverVersion => _coverVersion;

  void bumpVersion() {
    _coverVersion++;
    notifyListeners();
  }

  /// 自动候选按第 19.2 节的四级顺序返回，第一个就是自动选中的那张。
  Future<List<VolumeCoverCandidate>> volumeCoverCandidates(int folderId) =>
      _volumeCovers.listCandidates(folderId);

  /// 当前生效的封面：手动指定的优先，其次是自动候选。
  Future<String?> volumeCover(int folderId) =>
      _volumeCovers.effectiveCover(folderId);

  Future<Rect?> volumeCoverCrop(int folderId) =>
      _volumeCovers.cropOf(folderId);

  /// 手动指定封面。传 null 表示恢复自动候选。
  Future<void> setVolumeCover(int folderId, String? path) async {
    await _volumeCovers.setCover(folderId, path);
    bumpVersion();
  }

  /// 存裁剪框。传 null 表示恢复默认（清空 `cover_crop`）。
  Future<void> setVolumeCoverCrop(int folderId, Rect? crop) async {
    await _volumeCovers.setCrop(folderId, crop);
    bumpVersion();
  }

  /// 指定封面与裁剪一次写完，避免界面连点两次。
  Future<void> setVolumeCoverWithCrop(
      int folderId, String? path, Rect? crop) async {
    await _volumeCovers.setCoverWithCrop(folderId, path, crop);
    bumpVersion();
  }

  // ── 播放队列来源封面 ──

  String? _playingWorkCover;

  /// 当前播放队列来源作品的封面。队列建立时记录，与「当前浏览的作品」解耦。
  String? get playingWorkCover => _playingWorkCover;

  /// 记下这次播放队列对应的作品封面。
  void rememberQueueCover(String? workCover) {
    _playingWorkCover = workCover;
    notifyListeners();
  }

  /// 当前曲目封面：优先队列来源作品的封面，否则曲目自己的封面。
  ///
  /// 用播放队列建立时记下的作品封面，而不是「当前浏览的作品」，
  /// 播放中切换浏览对象不会把播放栏与通知栏的封面换掉。
  String? coverForTrack(TrackItem track) {
    final wc = _playingWorkCover;
    if (wc != null && wc.isNotEmpty) return wc;
    final own = track.coverPath;
    return own != null && own.isNotEmpty ? own : null;
  }

  // ── 缓存上限与驱逐 ──

  int _cacheLimitMB = 512;

  /// 封面缓存上限（MB，0 表示不限制）。
  int get cacheLimitMB => _cacheLimitMB;

  Future<void> loadCacheLimit() async {
    _cacheLimitMB = SettingsService.instance.coverCacheLimitMB;
    notifyListeners();
  }

  Future<int> getCacheSizeBytes() => CoverService.embeddedCacheSizeBytes();

  Future<int> clearCache() async {
    final freed = await CoverService.clearEmbeddedCache();
    notifyListeners();
    return freed;
  }

  Future<void> setCacheLimit(int mb) async {
    _cacheLimitMB = mb.clamp(0, 8192);
    await SettingsService.instance.setCoverCacheLimitMB(_cacheLimitMB);
    if (_cacheLimitMB > 0) {
      await CoverService.enforceLimit(
          _cacheLimitMB * 1024 * 1024,
          keep: _protectedPaths());
    }
    notifyListeners();
  }

  Future<void> enforceLimit() async {
    if (_cacheLimitMB <= 0) return;
    await CoverService.enforceLimit(_cacheLimitMB * 1024 * 1024,
        keep: _protectedPaths());
  }

  /// 给一条媒体行指定或清除它自己的封面（`media.cover_path`）。
  ///
  /// 需要在文件被覆盖后丢掉旧解码结果，所以由 [AppState] 在调用前清
  /// `ImageCache`；这里只管落库。
  Future<void> setMediaCoverPath(int mediaId, String? path) async {
    await MediaDao(db()).setCoverPath(mediaId, path);
  }
}
