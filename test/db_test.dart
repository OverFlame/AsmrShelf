import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:asmrshelf/db/tables.dart';
import 'package:asmrshelf/db/work_dao.dart';
import 'package:asmrshelf/db/folder_dao.dart';
import 'package:asmrshelf/db/track_dao.dart';
import 'package:asmrshelf/db/tag_dao.dart';

void main() {
  sqfliteFfiInit();

  test('DB 层核心流程：作品/文件夹/曲目/标签筛选', () async {
    final dir = await Directory.systemTemp.createTemp('audioshelf_db');
    final db = await databaseFactoryFfi.openDatabase(
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

    // 作品
    final workDao = WorkDao(db);
    final work = await workDao.create('我的作品');

    // 文件夹（镜像树：根 + mp3 子文件夹）
    final folderDao = FolderDao(db);
    final root =
        await folderDao.insert(name: '我的作品', path: '/tmp/music/x', workId: work.id);
    final sub = await folderDao.create('mp3', parentId: root.id, workId: work.id);
    await folderDao.addPath(sub.id!, '/tmp/music/x/mp3');
    expect((await folderDao.listRootsByWork(work.id!)).length, 1);

    // 曲目
    final trackDao = TrackDao(db);
    final aId = await trackDao.insert(TrackItem(
        path: '/tmp/music/x/a.mp3',
        filename: 'a.mp3',
        subtitlePath: '/tmp/music/x/a.mp3.vtt',
        addedAt: 1));
    await trackDao.insert(TrackItem(
        path: '/tmp/music/x/mp3/b.mp3', filename: 'b.mp3', addedAt: 2));

    // 直属目录查询（不含子目录）
    expect((await trackDao.queryDirectInDir('/tmp/music/x')).length, 1);
    // 递归查询（含子目录）
    expect((await trackDao.queryByDirs(['/tmp/music/x'])).length, 2);

    // 标签 + 筛选
    final tagDao = TagDao(db);
    final tag = await tagDao.insert(const Tag(name: '纯音乐'));
    await tagDao.addTagToTrack(aId, tag.id!);
    final andIds = await tagDao.getTrackIdsByTags(andTagIds: [tag.id!]);
    expect(andIds, contains(aId));
    final exprIds =
        await tagDao.getTrackIdsByExpression('纯音乐', await tagDao.getAll());
    expect(exprIds, contains(aId));

    await db.close();
    await dir.delete(recursive: true);
  });
}
