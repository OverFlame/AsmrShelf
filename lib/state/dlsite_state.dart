import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common/sqlite_api.dart';

import '../db/folder_dao.dart';
import '../db/work_dao.dart';
import '../db/work_metadata_dao.dart';
import '../services/cover_service.dart';
import '../services/dlsite/dlsite_api.dart';
import '../services/dlsite/dlsite_cover.dart';
import '../services/dlsite/dlsite_models.dart';
import '../services/dlsite/dlsite_repository.dart';
import '../services/dlsite/work_code.dart';
import '../utils/log_util.dart';

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

  /// 从已存的元数据、目录名或文件夹登记里找 RJ 号。
  ///
  /// 顺序按「越明确越优先」：手动填过或抓过的编号最可靠；其次是作品目录
  /// 及其祖先目录（`RJ 号/本編/` 这种两层结构很常见）；再退到作品名和
  /// `folder_paths` 里登记的路径。导入时没写 `works.root_path` 的作品也能
  /// 靠后两级找到编号。
  Future<String?> codeOf(int workId) async {
    final meta = await WorkMetadataDao(db()).getByWork(workId);
    final stored = meta?.rjCode;
    if (stored != null && stored.isNotEmpty) return stored;

    final work = await workDao().getById(workId);
    final rootPath = work?.rootPath;
    if (rootPath != null) {
      final fromPath = _codeInPath(rootPath);
      if (fromPath != null) return fromPath;
    }

    final fromTitle = parseWorkCode(work?.name ?? '')?.code;
    if (fromTitle != null) return fromTitle;

    for (final path in await FolderDao(db()).getPathsByWork(workId)) {
      final found = _codeInPath(path);
      if (found != null) return found;
    }
    return null;
  }

  /// 从路径本身或其任意祖先目录名里取编号。
  static String? _codeInPath(String path) {
    var current = p.normalize(path);
    while (true) {
      final found = parseWorkCode(p.basename(current))?.code;
      if (found != null) return found;
      final parent = p.dirname(current);
      if (parent == current || parent.isEmpty || parent == '.') return null;
      current = parent;
    }
  }

  /// 手动登记编号。返回规范化后的编号；格式不对返回 null。
  ///
  /// 只写 `work_metadata.rj_code`，不动其他字段；下次抓取直接用它。
  Future<String?> setManualCode(int workId, String input) async {
    var text = input.trim().toUpperCase();
    if (RegExp(r'^\d{6,8}$').hasMatch(text)) text = 'RJ$text';
    if (!isValidWorkCode(text)) return null;
    await WorkMetadataDao(db()).upsert(WorkMetadata(workId: workId, rjCode: text));
    _metadata.remove(workId);
    _works.remove(workId);
    await prefetch(workId);
    notifyListeners();
    return text;
  }

  /// 只抓不落库的标签与封面，给预览对话框用。
  Future<DlsiteFetchResult> preview(int workId) async {
    final code = await codeOf(workId);
    if (code == null) {
      return const DlsiteFetchResult(
        message: _noCodeMessage,
        missingCode: true,
      );
    }
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

  // ═══════════════ 批量抓取队列 ═══════════════

  /// 排队中的作品 id。抓完一部才取下一部，请求间隔由 [DlsiteApi] 的限速器控制。
  final List<int> _scrapeQueue = [];
  bool _scrapeRunning = false;
  bool _scrapeCancelRequested = false;
  int _scrapeTotal = 0;
  int _scrapeDone = 0;
  int _scrapeFailed = 0;

  /// 本批共排入多少部。
  int get scrapeTotal => _scrapeTotal;

  /// 本批已处理多少部（成功与失败合计）。
  int get scrapeDone => _scrapeDone;

  /// 本批失败多少部（没有 RJ 号、网络失败、解析失败都算）。
  int get scrapeFailed => _scrapeFailed;

  bool get scrapeRunning => _scrapeRunning;

  /// 把一批作品排进抓取队列。重复排入同一部会被忽略。
  ///
  /// 队列在后台跑，调用方不用 await；进度由 [scrapeTotal]/[scrapeDone] 通知。
  void enqueueScrape(Iterable<int> workIds) {
    final pending = <int>[];
    for (final id in workIds) {
      if (_scrapeQueue.contains(id) || pending.contains(id)) continue;
      pending.add(id);
    }
    if (pending.isEmpty) return;
    if (!_scrapeRunning) {
      _scrapeTotal = 0;
      _scrapeDone = 0;
      _scrapeFailed = 0;
      _scrapeCancelRequested = false;
    }
    _scrapeQueue.addAll(pending);
    _scrapeTotal += pending.length;
    notifyListeners();
    if (!_scrapeRunning) unawaited(_runScrapeQueue());
  }

  Future<void> _runScrapeQueue() async {
    _scrapeRunning = true;
    notifyListeners();
    try {
      while (_scrapeQueue.isNotEmpty && !_scrapeCancelRequested) {
        final workId = _scrapeQueue.removeAt(0);
        try {
          final result = await fetch(workId);
          if (!result.ok) {
            _scrapeFailed++;
            logWarn('DlsiteState', '批量抓取失败 work=$workId：${result.message}');
          }
        } catch (e) {
          _scrapeFailed++;
          logWarn('DlsiteState', '批量抓取异常 work=$workId', e);
        }
        _scrapeDone++;
        notifyListeners();
      }
    } finally {
      _scrapeRunning = false;
      _scrapeQueue.clear();
      _scrapeCancelRequested = false;
      notifyListeners();
    }
  }

  /// 取消剩余排队项。正在抓的那一部会跑完，结果照常落库。
  void cancelScrapeQueue() {
    if (!_scrapeRunning) return;
    _scrapeCancelRequested = true;
    _scrapeQueue.clear();
    notifyListeners();
  }

  static const String _noCodeMessage = '这部作品的目录名里没有 RJ 号，先改名或手动填编号';
}
