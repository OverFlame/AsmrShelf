import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:asmrshelf/db/folder_dao.dart';
import 'package:asmrshelf/db/media_dao.dart';
import 'package:asmrshelf/db/tables.dart';
import 'package:asmrshelf/db/tag_dao.dart';

void main() {
  sqfliteFfiInit();

  late Directory dir;
  late Database db;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('asmrshelf_sql_batch');
    db = await databaseFactoryFfi.openDatabase(
      '${dir.path}/test.db',
      options: OpenDatabaseOptions(
        version: Tables.version,
        onCreate: (db, v) async {
          for (final s in Tables.createStatements) {
            await db.execute(s);
          }
        },
      ),
    );
  });

  tearDown(() async {
    await db.close();
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  test('按 1200 个目录查询媒体不会超过 SQLite 占位符上限', () async {
    final media = MediaDao(db);
    final rows = <Map<String, Object?>>[];
    for (var i = 0; i < 1200; i++) {
      rows.add({
        'path': '/m/vol$i/a.mp3',
        'media_type': 'audio',
        'filename': 'a.mp3',
        'added_at': 1,
      });
    }
    expect(await media.insertRows(rows), 1200);

    final dirs = [for (var i = 0; i < 1200; i++) '/m/vol$i'];
    final found = await media.queryByDirs(dirs, type: MediaType.audio);
    expect(found.length, 1200);
  });


  test('清理孤立标签不会删掉规则标签的定义行', () async {
    final tagDao = TagDao(db);
    final rule = await tagDao.insert(
      const Tag(namespace: TagDao.kindNamespace, name: 'audio'),
    );
    final orphan = await tagDao.insert(const Tag(name: '没人用'));
    expect(await tagDao.deleteOrphanTags(), 1);
    expect(await tagDao.getById(rule.id!), isNotNull);
    expect(await tagDao.getById(orphan.id!), isNull);
  });

  test('1200 个曲目的标签查询按批返回完整映射', () async {
    final media = MediaDao(db);
    final rows = <Map<String, Object?>>[
      for (var i = 0; i < 1200; i++)
        {
          'path': '/m/t$i.mp3',
          'media_type': 'audio',
          'filename': 't$i.mp3',
          'added_at': 1,
        }
    ];
    final ids = await media.insertRowsReturningIds(rows);
    final tagDao = TagDao(db);
    final tag = await tagDao.insert(const Tag(name: '批标签'));

    final batch = db.batch();
    for (final id in ids) {
      batch.insert('media_tags', {'media_id': id, 'tag_id': tag.id});
    }
    await batch.commit(noResult: true);

    final map = await tagDao.getTagsForTracks(ids);
    expect(map.length, 1200);
    expect(map[ids.first]!.single.name, '批标签');
  });

  test('删除 600 个文件夹不会超过 SQLite 占位符上限', () async {
    final batch = db.batch();
    for (var i = 0; i < 600; i++) {
      batch.insert('folders', {
        'name': '文件夹 $i',
        'library': 'audio',
        'reading_direction': 'rtl',
        'reading_fit': 'page',
      });
    }
    await batch.commit(noResult: true);
    final rows = await db.query('folders', columns: ['id']);
    final ids = rows.map((r) => r['id'] as int).toList();

    expect(await FolderDao(db).deleteMany(ids), 600);
    expect(await db.query('folders'), isEmpty);
  });
}
