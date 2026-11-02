/// 把 DLsite 抓回来的元数据落进本地库。
///
/// 合并口径见 `docs/需求研究与设计备忘.md`：本地作品名保留，远程标题只进
/// `work_metadata`；远程封面默认不覆盖本地封面；分类进 `dlsite` 命名空间、
/// 声优进 `voice` 命名空间；简介只写 `work_metadata.description`。
library;

import 'package:sqflite_common/sqlite_api.dart';

import '../../db/tag_dao.dart';
import '../../db/work_metadata_dao.dart';
import '../../utils/log_util.dart';
import 'dlsite_api.dart';
import 'dlsite_models.dart';

/// 一次抓取的结果。
class DlsiteFetchResult {
  const DlsiteFetchResult({
    this.work,
    this.fromCache = false,
    this.message = '',
    this.grantedTags = 0,
  });

  final DlsiteWork? work;

  /// 是否命中了本地缓存，没发请求。
  final bool fromCache;

  /// 给用户看的说明，失败时非空。
  final String message;

  /// 这次新挂上的标签数。
  final int grantedTags;

  bool get ok => work != null;
}

/// 抓元数据并合并进库。
class DlsiteRepository {
  DlsiteRepository(
    this._db, {
    DlsiteApi? api,
    this.cacheTtl = const Duration(days: 7),
    DateTime Function()? now,
  })  : _api = api ?? DlsiteApi(),
        _now = now ?? DateTime.now;

  final Database _db;
  final DlsiteApi _api;
  final Duration cacheTtl;
  final DateTime Function() _now;

  /// 给一部作品抓元数据并入库。
  ///
  /// [applyCover] 默认 false：本地已经有封面时不要被远程图顶掉，等用户在预览
  /// 里勾选再写。抓不到时返回带 [DlsiteFetchResult.message] 的结果，不抛异常，
  /// 免得界面每个调用点都包一层。
  Future<DlsiteFetchResult> fetchForWork(
    int workId,
    String code, {
    bool applyCover = false,
  }) async {
    final normalized = code.trim().toUpperCase();
    final metaDao = WorkMetadataDao(_db);
    final existing = await metaDao.getByWork(workId);
    if (existing != null &&
        existing.rjCode == normalized &&
        existing.fetchedAt != null &&
        _isFresh(existing.fetchedAt!)) {
      return DlsiteFetchResult(
          work: existing.rawJson == null ? null : _reparse(existing.rawJson!),
          fromCache: true);
    }

    DlsiteWork? work;
    try {
      work = await _api.fetchWork(normalized);
    } on DlsiteException catch (e) {
      return DlsiteFetchResult(message: _messageFor(e));
    }
    if (work == null) {
      return const DlsiteFetchResult(message: '这个编号在 DLsite 上没有对应的作品');
    }

    final stamp = _now().millisecondsSinceEpoch;
    await metaDao.upsert(WorkMetadata(
      workId: workId,
      rjCode: work.workNo,
      title: work.title,
      titleKana: work.titleKana,
      circle: work.makerName,
      series: work.seriesName,
      description: work.description,
      coverUrl: work.cover?.url,
      coverSource: applyCover ? 'dlsite' : existing?.coverSource,
      coverFetchedAt: applyCover ? stamp : existing?.coverFetchedAt,
      rawJson: work.rawJson,
      fetchedAt: stamp,
      updatedAt: stamp,
    ));

    final granted = await _applyTags(workId, work);
    logInfo('DlsiteRepository',
        '作品 $workId 抓到 ${work.workNo}，新挂标签 $granted 个');
    return DlsiteFetchResult(work: work, grantedTags: granted);
  }

  bool _isFresh(int fetchedAt) {
    final fetched = DateTime.fromMillisecondsSinceEpoch(fetchedAt);
    return _now().difference(fetched) < cacheTtl;
  }

  DlsiteWork? _reparse(String rawJson) => parseProductJson(rawJson);

  /// 分类挂到 `dlsite` 命名空间，声优挂到 `voice`；已存在的不重复挂。
  Future<int> _applyTags(int workId, DlsiteWork work) async {
    final dao = TagDao(_db);
    final attached = {
      for (final tag in await dao.tagsForWork(workId)) '${tag.namespace}:${tag.name}',
    };
    var added = 0;
    Future<void> attach(String namespace, String name) async {
      if (name.trim().isEmpty) return;
      final key = '$namespace:${name.trim()}';
      if (attached.contains(key)) return;
      final row = await dao.insert(Tag(namespace: namespace, name: name.trim()));
      if (row.id == null) return;
      await dao.attachToWork(workId, row.id!);
      attached.add(key);
      added++;
    }

    for (final genre in work.genres) {
      await attach('dlsite', genre.name);
    }
    for (final voice in work.voiceActors) {
      await attach('voice', voice.name);
    }
    return added;
  }

  String _messageFor(DlsiteException e) => switch (e.status) {
        403 => 'DLsite 拒绝了这次请求（403），可能被临时限制，过一阵再试',
        429 || 503 => 'DLsite 现在很忙（HTTP ${e.status}），重试也没成功，过会儿再试',
        null => '连不上 DLsite，检查网络后重试',
        _ => e.message,
      };
}
