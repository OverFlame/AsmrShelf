/// 把 [ImportPlan] 落库。
///
/// 一次性导入工具的执行层：每部作品建一行 `works`、根文件夹及按媒体路径
/// 镜像出的子文件夹、一批 `media` 行，再写 `work_metadata`（RJ 号与封面来源）。
/// 重复跑不会产生重复作品：靠 `works.root_path` 判重；已存在的作品会顺手
/// 补齐旧版本遗漏的子文件夹。
library;

import 'package:sqflite_common/sqlite_api.dart';

import '../db/folder_dao.dart';
import '../db/media_dao.dart';
import '../db/work_dao.dart';
import '../db/work_metadata_dao.dart';
import 'folder_tree_mirror.dart';
import 'import_scanner.dart';

/// 一次落库的结果。
class ImportOutcome {
  const ImportOutcome({
    this.worksCreated = 0,
    this.worksSkipped = 0,
    this.tracksInserted = 0,
    this.tracksSkipped = 0,
    this.createdWorkIds = const [],
  });

  final int worksCreated;

  /// 已经导入过（`works.root_path` 相同）而跳过的作品数。
  final int worksSkipped;
  final int tracksInserted;

  /// 已存在的曲目行数（`media.path` 冲突被忽略）。
  final int tracksSkipped;

  /// 本次新建作品的 id，供「导入后自动刮削」这类后续动作使用。
  final List<int> createdWorkIds;

  @override
  String toString() => 'ImportOutcome(作品 $worksCreated 新建 / $worksSkipped 跳过, '
      '曲目 $tracksInserted 新增 / $tracksSkipped 已存在)';
}

/// 执行导入。
class PlanImporter {
  PlanImporter(this.db);

  final Database db;

  Future<ImportOutcome> apply(ImportPlan plan) async {
    final workDao = WorkDao(db);
    final folderDao = FolderDao(db);
    final mediaDao = MediaDao(db);
    final metaDao = WorkMetadataDao(db);
    final mirror = FolderTreeMirror(folderDao);

    var created = 0;
    var skipped = 0;
    var inserted = 0;
    var duplicate = 0;
    final createdIds = <int>[];

    for (final work in plan.works) {
      final existingId = await _workIdByRootPath(work.dirPath);
      if (existingId != null) {
        // 旧版本只建了根文件夹；重跑导入时顺手补齐目录树，避免旧数据永远
        // 停在「有曲目、点进去却为空」的状态。
        await mirror.ensureForPaths(
          rootPath: work.dirPath,
          rootName: work.title,
          workId: existingId,
          mediaPaths: work.tracks.map((t) => t.path),
        );
        skipped++;
        continue;
      }

      final row = await workDao.create(work.title,
          coverPath: work.coverPath, library: 'audio');
      final workId = row.id!;
      await db.update('works', {'root_path': work.dirPath},
          where: 'id = ?', whereArgs: [workId]);

      await mirror.ensureForPaths(
        rootPath: work.dirPath,
        rootName: work.title,
        workId: workId,
        mediaPaths: work.tracks.map((t) => t.path),
      );

      final addedAt = DateTime.now().millisecondsSinceEpoch;
      final rows = <Map<String, Object?>>[
        for (final track in work.tracks)
          {
            'path': track.path,
            'media_type': 'audio',
            'filename': track.fileName,
            'file_size': track.sizeBytes,
            'added_at': addedAt,
            'title': track.title,
            // media 不记 work_id 也不记 folder_id：与文件夹的关系在查询时按
            // 路径范围算（见 `lib/db/path_range.dart`），落库只认路径。
          },
      ];
      final ids = await mediaDao.insertRowsReturningIds(rows);
      inserted += ids.where((id) => id > 0).length;
      duplicate += ids.where((id) => id <= 0).length;

      if (work.code != null || work.coverPath != null) {
        await metaDao.upsert(WorkMetadata(
          workId: workId,
          rjCode: work.code,
          coverSource: work.coverPath == null ? null : 'local',
          coverFetchedAt:
              work.coverPath == null ? null : DateTime.now().millisecondsSinceEpoch,
        ));
      }
      created++;
      createdIds.add(workId);
    }

    return ImportOutcome(
      worksCreated: created,
      worksSkipped: skipped,
      tracksInserted: inserted,
      tracksSkipped: duplicate,
      createdWorkIds: List.unmodifiable(createdIds),
    );
  }

  Future<int?> _workIdByRootPath(String path) async {
    final rows = await db.query('works',
        columns: ['id'], where: 'root_path = ?', whereArgs: [path], limit: 1);
    return rows.isEmpty ? null : (rows.first['id'] as num).toInt();
  }
}
