import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:asmrshelf/db/tables.dart';
import 'package:asmrshelf/db/work_dao.dart';
import 'package:asmrshelf/db/work_metadata_dao.dart';

void main() {
  sqfliteFfiInit();

  late Directory dir;
  late Database db;
  late WorkMetadataDao dao;
  late int workId;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('asmrshelf_meta');
    db = await databaseFactoryFfi.openDatabase(
      '${dir.path}/test.db',
      options: OpenDatabaseOptions(
        version: Tables.version,
        onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
        onCreate: (db, v) async {
          for (final s in Tables.createStatements) {
            await db.execute(s);
          }
        },
      ),
    );
    dao = WorkMetadataDao(db);
    workId = (await WorkDao(db).create('作品')).id!;
  });

  tearDown(() async {
    await db.close();
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  test('第一次写入就落行，按 work_id 与 RJ 号都能读回来', () async {
    expect(await dao.getByWork(workId), isNull);

    await dao.upsert(WorkMetadata(
      workId: workId,
      rjCode: 'RJ294126',
      title: '作品名',
      circle: '社团',
      rawJson: '{"workno":"RJ294126"}',
      fetchedAt: 1700000000000,
    ));

    final row = await dao.getByWork(workId);
    expect(row, isNotNull);
    expect(row!.rjCode, 'RJ294126');
    expect(row.title, '作品名');
    expect(row.fetchedAt, 1700000000000);
    expect(row.updatedAt, isNotNull);

    // RJ 号查询不区分大小写，落库统一大写。
    expect((await dao.getByRjCode('rj294126'))?.workId, workId);
  });

  test('第二次写入只换传进来的字段，没传的保留旧值', () async {
    await dao.upsert(WorkMetadata(
      workId: workId,
      rjCode: 'RJ294126',
      title: '旧标题',
      circle: '社团',
    ));
    await dao.upsert(WorkMetadata(workId: workId, title: '新标题'));

    final row = (await dao.getByWork(workId))!;
    expect(row.title, '新标题');
    expect(row.rjCode, 'RJ294126', reason: '没传 RJ 号不能把已有的清掉');
    expect(row.circle, '社团');
  });

  test('setCover 在行不存在时补一行，只动封面三列', () async {
    await dao.setCover(workId,
        url: 'https://example.invalid/main.jpg',
        source: 'dlsite',
        fetchedAt: 1700000000000);

    var row = await dao.getByWork(workId);
    expect(row, isNotNull);
    expect(row!.coverUrl, 'https://example.invalid/main.jpg');
    expect(row.coverSource, 'dlsite');
    expect(row.rjCode, isNull);

    await dao.upsert(WorkMetadata(workId: workId, title: '作品名'));
    await dao.setCover(workId, source: 'local');
    row = await dao.getByWork(workId);
    expect(row!.title, '作品名');
    expect(row.coverSource, 'local');
    expect(row.coverUrl, 'https://example.invalid/main.jpg',
        reason: '没传 url 时不能把已有 url 清掉');
  });

  test('删作品时元数据跟着删', () async {
    await dao.upsert(WorkMetadata(workId: workId, rjCode: 'RJ294126'));
    await WorkDao(db).delete(workId);
    expect(await dao.getByWork(workId), isNull);
  });

  test('两个作品不能抢同一个 RJ 号', () async {
    final other = (await WorkDao(db).create('另一个作品')).id!;
    await dao.upsert(WorkMetadata(workId: workId, rjCode: 'RJ294126'));
    expect(
      () => dao.upsert(WorkMetadata(workId: other, rjCode: 'RJ294126')),
      throwsA(isA<DatabaseException>()),
    );
  });
}
