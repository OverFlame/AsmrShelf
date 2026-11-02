import 'package:sqflite_common/sqlite_api.dart';

/// 一部作品的 DLsite 元数据，对应 `work_metadata` 一行。
///
/// 只存抓回来的东西，不做合并判断：本地标题、本地封面的取舍在调用方决定
/// （`docs/需求研究与设计备忘.md` 第 10.4 节）。
class WorkMetadata {
  const WorkMetadata({
    required this.workId,
    this.rjCode,
    this.title,
    this.titleKana,
    this.circle,
    this.series,
    this.description,
    this.coverUrl,
    this.coverSource,
    this.coverFetchedAt,
    this.rawJson,
    this.fetchedAt,
    this.updatedAt,
  });

  final int workId;
  final String? rjCode;
  final String? title;
  final String? titleKana;
  final String? circle;
  final String? series;
  final String? description;
  final String? coverUrl;

  /// 封面来源：`dlsite`（远程下载）、`local`（从作品目录挑的）、`embedded`（音频内嵌）。
  final String? coverSource;
  final int? coverFetchedAt;
  final String? rawJson;
  final int? fetchedAt;
  final int? updatedAt;

  factory WorkMetadata.fromMap(Map<String, Object?> map) => WorkMetadata(
        workId: (map['work_id'] as num).toInt(),
        rjCode: map['rj_code'] as String?,
        title: map['title'] as String?,
        titleKana: map['title_kana'] as String?,
        circle: map['circle'] as String?,
        series: map['series'] as String?,
        description: map['description'] as String?,
        coverUrl: map['cover_url'] as String?,
        coverSource: map['cover_source'] as String?,
        coverFetchedAt: (map['cover_fetched_at'] as num?)?.toInt(),
        rawJson: map['raw_json'] as String?,
        fetchedAt: (map['fetched_at'] as num?)?.toInt(),
        updatedAt: (map['updated_at'] as num?)?.toInt(),
      );

  Map<String, Object?> toMap() => {
        'work_id': workId,
        'rj_code': rjCode,
        'title': title,
        'title_kana': titleKana,
        'circle': circle,
        'series': series,
        'description': description,
        'cover_url': coverUrl,
        'cover_source': coverSource,
        'cover_fetched_at': coverFetchedAt,
        'raw_json': rawJson,
        'fetched_at': fetchedAt,
        'updated_at': updatedAt,
      };
}

/// 读写 `work_metadata`。
class WorkMetadataDao {
  WorkMetadataDao(this.db);

  final Database db;

  Future<WorkMetadata?> getByWork(int workId) async {
    final rows = await db.query('work_metadata',
        where: 'work_id = ?', whereArgs: [workId], limit: 1);
    return rows.isEmpty ? null : WorkMetadata.fromMap(rows.first);
  }

  /// 全部元数据，给系列索引重建用。
  Future<List<WorkMetadata>> listAll() async {
    final rows = await db.query('work_metadata', orderBy: 'work_id ASC');
    return [for (final row in rows) WorkMetadata.fromMap(row)];
  }

  /// 按 RJ 号找作品。唯一索引保证最多一行。
  Future<WorkMetadata?> getByRjCode(String rjCode) async {
    final rows = await db.query('work_metadata',
        where: 'rj_code = ?', whereArgs: [rjCode.toUpperCase()], limit: 1);
    return rows.isEmpty ? null : WorkMetadata.fromMap(rows.first);
  }

  /// 整行写入。只覆盖传进来的字段，用同一行已有的值补空。
  ///
  /// 不用 conflictReplace：RJ 号是唯一索引，替换会把别的作品那一行顶掉，
  /// 变成「抓 A 作品顺手把 B 作品的编号抢过来」。这里显式分插入与更新，
  /// 撞唯一索引就让调用方看见错误。
  Future<void> upsert(WorkMetadata meta) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final existing = await getByWork(meta.workId);
    final merged = WorkMetadata(
      workId: meta.workId,
      rjCode: meta.rjCode ?? existing?.rjCode,
      title: meta.title ?? existing?.title,
      titleKana: meta.titleKana ?? existing?.titleKana,
      circle: meta.circle ?? existing?.circle,
      series: meta.series ?? existing?.series,
      description: meta.description ?? existing?.description,
      coverUrl: meta.coverUrl ?? existing?.coverUrl,
      coverSource: meta.coverSource ?? existing?.coverSource,
      coverFetchedAt: meta.coverFetchedAt ?? existing?.coverFetchedAt,
      rawJson: meta.rawJson ?? existing?.rawJson,
      fetchedAt: meta.fetchedAt ?? existing?.fetchedAt,
      updatedAt: now,
    );
    if (existing == null) {
      await db.insert('work_metadata', merged.toMap(),
          conflictAlgorithm: ConflictAlgorithm.abort);
    } else {
      await db.update('work_metadata', merged.toMap(),
          where: 'work_id = ?', whereArgs: [meta.workId]);
    }
  }

  /// 只写封面三列，抓封面与抓标题互不覆盖。
  Future<void> setCover(
    int workId, {
    String? url,
    String? source,
    int? fetchedAt,
  }) async {
    final values = <String, Object?>{
      'cover_url': ?url,
      'cover_source': ?source,
      'cover_fetched_at': ?fetchedAt,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    };
    // 行可能还不存在（先挑本地封面、后抓 DLsite），补一条只有 work_id 的行。
    final existing = await getByWork(workId);
    if (existing == null) {
      await db.insert('work_metadata', {'work_id': workId, ...values},
          conflictAlgorithm: ConflictAlgorithm.abort);
      return;
    }
    await db.update('work_metadata', values,
        where: 'work_id = ?', whereArgs: [workId]);
  }

  Future<void> delete(int workId) =>
      db.delete('work_metadata', where: 'work_id = ?', whereArgs: [workId]);
}
