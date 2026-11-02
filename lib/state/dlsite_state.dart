import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common/sqlite_api.dart';

import '../db/work_dao.dart';
import '../db/work_metadata_dao.dart';
import '../services/cover_service.dart';
import '../services/dlsite/dlsite_api.dart';
import '../services/dlsite/dlsite_cover.dart';
import '../services/dlsite/dlsite_models.dart';
import '../services/dlsite/dlsite_repository.dart';
import '../services/dlsite/work_code.dart';

/// DLsite 元数据状态：从作品目录名认出编号、抓取、预览、应用。
///
/// 拆分自 [AppState]。按剥离指南的依赖方向，这里可以用服务与 DAO，
/// 但不改别的状态对象；「应用之后界面要重画」由 [onRefresh] 回调通知。
class DlsiteState extends ChangeNotifier {
  DlsiteState({
    required this.db,
    required this.workDao,
    this.api,
    DlsiteCoverDownloader? downloader,
    this.onRefresh,
  }) : _downloader = downloader ?? DlsiteCoverDownloader();

  /// 库连接用工厂传入：`AppState.init` 才打开库。
  final Database Function() db;
  final WorkDao Function() workDao;
  final DlsiteApi? api;
  final DlsiteCoverDownloader _downloader;

  /// 元数据落库后让作品库重查（简介、封面可能变了）。
  final Future<void> Function()? onRefresh;

  /// 按作品 id 缓存一次读取结果；[invalidate] 清掉。
  final Map<int, WorkMetadata?> _metadata = {};

  /// 反解过的完整作品信息，跟 `_metadata` 一起失效。
  final Map<int, DlsiteWork?> _works = {};

  /// 进作品时先把元数据装进内存，详情头就能同步读，不会先闪一下「没抓过」。
  Future<void> prefetch(int workId) async {
    final meta = await metadataOf(workId);
    final raw = meta?.rawJson;
    _works[workId] = raw == null ? null : parseProductJson(raw);
  }

  /// 同步读已预取的元数据；没预取过就是 null。
  WorkMetadata? metadataSync(int workId) => _metadata[workId];

  /// 同步读已反解的完整信息；没预取或没抓过就是 null。
  DlsiteWork? workSync(int workId) => _works[workId];

  /// 从目录名或已存的元数据里找 RJ 号。
  Future<String?> codeOf(int workId) async {
    final work = await workDao().getById(workId);
    final rootPath = work?.rootPath;
    final fromDir =
        rootPath == null ? null : parseWorkCode(p.basename(rootPath).trim());
    if (fromDir != null) return fromDir.code;
    final meta = await WorkMetadataDao(db()).getByWork(workId);
    return meta?.rjCode;
  }

  /// 只抓不落库的标签与封面，给预览对话框用。
  Future<DlsiteFetchResult> preview(int workId) async {
    final code = await codeOf(workId);
    if (code == null) return const DlsiteFetchResult(message: _noCodeMessage);
    final result = await DlsiteRepository(db(), api: api).preview(workId, code);
    if (result.ok) {
      // 预览已经把元数据落进库，缓存里那份（进作品时预取的）要重读，
      // 否则详情头还停留在「没抓过」。
      _metadata.remove(workId);
      _works.remove(workId);
      await prefetch(workId);
      notifyListeners();
    }
    return result;
  }

  /// 抓取并直接落库（标签、简介、可选封面）。
  Future<DlsiteFetchResult> fetch(int workId, {bool applyCover = false}) async {
    final code = await codeOf(workId);
    if (code == null) return const DlsiteFetchResult(message: _noCodeMessage);
    final result = await DlsiteRepository(db(), api: api)
        .fetchForWork(workId, code, applyCover: applyCover);
    if (result.ok) {
      _metadata.remove(workId);
      _works.remove(workId);
      notifyListeners();
      await onRefresh?.call();
    }
    return result;
  }

  /// 用户确认预览之后应用：写元数据与标签，可选把封面也换掉。
  Future<DlsiteFetchResult> apply(
    int workId,
    DlsiteWork work, {
    bool applyCover = false,
  }) async {
    final granted =
        await DlsiteRepository(db(), api: api).apply(workId, work, applyCover: applyCover);
    _metadata.remove(workId);
    _works.remove(workId);
    notifyListeners();
    await onRefresh?.call();
    return DlsiteFetchResult(work: work, grantedTags: granted);
  }

  /// 下载远程封面并设为作品封面，返回本地路径。
  Future<String> downloadCover(int workId, String url) async {
    final bytes = await _downloader.download(url);
    final path = await CoverService.writeWorkCover(workId, bytes);
    if (path == null) throw const DlsiteImageException('封面写不进本地缓存目录');
    await workDao().setCover(workId, path);
    _metadata.remove(workId);
    _works.remove(workId);
    notifyListeners();
    await onRefresh?.call();
    return path;
  }

  /// 从缓存的 raw_json 反解出完整作品信息（发售日、评分这些没进表）。
  /// 不联网：没抓过就是 null。
  Future<DlsiteWork?> cachedWork(int workId) async {
    final meta = await metadataOf(workId);
    final raw = meta?.rawJson;
    return raw == null ? null : parseProductJson(raw);
  }

  /// 读作品的元数据（简介、社团、系列、发售日），带进程内缓存。
  Future<WorkMetadata?> metadataOf(int workId) async {
    if (_metadata.containsKey(workId)) return _metadata[workId];
    final meta = await WorkMetadataDao(db()).getByWork(workId);
    // 空结果不缓存：预取时还没抓过，抓完再读必须能读到新行。
    if (meta != null) _metadata[workId] = meta;
    return meta;
  }

  void invalidate() {
    _metadata.clear();
    _works.clear();
    notifyListeners();
  }

  static const String _noCodeMessage = '这部作品的目录名里没有 RJ 号，先改名或手动填编号';
}
