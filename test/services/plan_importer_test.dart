import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:asmrshelf/db/media_dao.dart';
import 'package:asmrshelf/db/tables.dart';
import 'package:asmrshelf/db/work_metadata_dao.dart';
import 'package:asmrshelf/services/import_scanner.dart';
import 'package:asmrshelf/services/plan_importer.dart';

Future<File> touch(Directory root, String relative, {int bytes = 32}) async {
  final file = File(p.join(root.path, relative));
  await file.parent.create(recursive: true);
  await file.writeAsBytes(List<int>.filled(bytes, 0));
  return file;
}

void main() {
  sqfliteFfiInit();

  late Directory root;
  late Directory dbDir;
  late Database db;
  late PlanImporter importer;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('asmrshelf_apply_');
    dbDir = await Directory.systemTemp.createTemp('asmrshelf_apply_db_');
    db = await databaseFactoryFfi.openDatabase(
      p.join(dbDir.path, 'test.db'),
      options: OpenDatabaseOptions(
        version: Tables.version,
        onCreate: (db, v) async {
          for (final s in Tables.createStatements) {
            await db.execute(s);
          }
        },
      ),
    );
    importer = PlanImporter(db);
  });

  tearDown(() async {
    await db.close();
    if (await root.exists()) await root.delete(recursive: true);
    if (await dbDir.exists()) await dbDir.delete(recursive: true);
  });

  test('一部作品落成作品、文件夹、曲目三样，编号进元数据', () async {
    await touch(root, 'RJ294126 作品A/01. 導入.mp3');
    await touch(root, 'RJ294126 作品A/02. 本編.mp3');
    final plan = await scanImportTree(root.path, writeCover: false);

    final outcome = await importer.apply(plan);
    expect(outcome.worksCreated, 1);
    expect(outcome.tracksInserted, 2);

    final works = await db.query('works');
    expect(works.single['name'], '作品A');
    expect(works.single['library'], 'audio');
    expect(works.single['root_path'], p.join(root.path, 'RJ294126 作品A'));

    final folders = await db.query('folders');
    expect(folders.single['name'], '作品A');
    expect(folders.single['work_id'], works.single['id']);

    final paths = await db.query('folder_paths');
    expect(paths.single['path'], p.join(root.path, 'RJ294126 作品A'));

    final media = await MediaDao(db).queryAll(type: MediaType.audio);
    expect(media.map((m) => m.title), ['導入', '本編']);

    final meta = await WorkMetadataDao(db).getByWork(works.single['id'] as int);
    expect(meta!.rjCode, 'RJ294126');
    expect(meta.coverSource, isNull);
  });

  test('作品内嵌套 01_mp3 / 02_wav 时镜像出完整文件夹树', () async {
    final mp3 = await touch(root, 'RJ294126 作品A/01_mp3/01.mp3');
    final wav = await touch(root, 'RJ294126 作品A/02_wav/01.wav');
    final workDir = p.join(root.path, 'RJ294126 作品A');
    final plan = ImportPlan(rootPath: root.path, works: [
      ImportWork(
        dirPath: workDir,
        title: '作品A',
        code: 'RJ294126',
        tracks: [
          ImportTrack(
              path: mp3.path,
              fileName: '01.mp3',
              title: '01',
              sizeBytes: 32),
          ImportTrack(
              path: wav.path,
              fileName: '01.wav',
              title: '01',
              sizeBytes: 32),
        ],
      ),
    ]);

    await importer.apply(plan);

    final work = (await db.query('works')).single;
    final folders = await db.query('folders');
    expect(folders.length, 3);
    final byName = {for (final f in folders) f['name'] as String: f};
    final rootFolder = byName['作品A']!;
    expect(rootFolder['parent'], isNull);
    expect(rootFolder['work_id'], work['id']);
    for (final name in ['01_mp3', '02_wav']) {
      final child = byName[name]!;
      expect(child['parent'], rootFolder['id']);
      expect(child['work_id'], work['id']);
    }
    final paths = await db.query('folder_paths');
    expect(paths.length, 3);
  });

  test('重跑导入会补齐旧数据缺失的子文件夹', () async {
    final mp3 = await touch(root, 'RJ294126 作品A/01_mp3/01.mp3');
    final wav = await touch(root, 'RJ294126 作品A/02_wav/01.wav');
    final workDir = p.join(root.path, 'RJ294126 作品A');
    final plan = ImportPlan(rootPath: root.path, works: [
      ImportWork(
        dirPath: workDir,
        title: '作品A',
        code: 'RJ294126',
        tracks: [
          ImportTrack(
              path: mp3.path,
              fileName: '01.mp3',
              title: '01',
              sizeBytes: 32),
          ImportTrack(
              path: wav.path,
              fileName: '01.wav',
              title: '01',
              sizeBytes: 32),
        ],
      ),
    ]);
    await importer.apply(plan);

    // 模拟旧版一次性导入：只剩根文件夹与根路径映射。
    await db.delete('folder_paths',
        where: 'folder_id IN (SELECT id FROM folders WHERE parent IS NOT NULL)');
    await db.delete('folders', where: 'parent IS NOT NULL');
    expect((await db.query('folders')).length, 1);

    final second = await importer.apply(plan);

    expect(second.worksCreated, 0);
    expect(second.worksSkipped, 1);
    expect((await db.query('works')).length, 1);
    expect((await db.query('folders')).length, 3);
    expect((await db.query('folder_paths')).length, 3);
  });

  test('一次性导入写入同名字幕，重跑补旧数据', () async {
    await touch(root, 'RJ294126 作品A/01_mp3/01.mp3');
    await touch(root, 'RJ294126 作品A/01_mp3/01.lrc');
    final plan = await scanImportTree(root.path, writeCover: false);

    await importer.apply(plan);
    var audio = (await db.query('media',
            where: "media_type = 'audio'"))
        .single;
    final subtitlePath = audio['subtitle_path'] as String;
    expect(p.basename(subtitlePath), '01.lrc');

    // 模拟旧版一次性导入：音频行在，subtitle_path 为空。
    await db.update('media', {'subtitle_path': null});
    final second = await importer.apply(plan);
    expect(second.worksSkipped, 1);
    audio = (await db.query('media', where: "media_type = 'audio'")).single;
    expect(audio['subtitle_path'], subtitlePath);
  });

  test('有封面时作品封面与元数据一起记下来', () async {
    await touch(root, 'RJ300001 作品/01.mp3');
    await touch(root, 'RJ300001 作品/cover.jpg');
    final plan = await scanImportTree(root.path);
    final cover = plan.works.single.coverPath!;

    await importer.apply(plan);
    final work = (await db.query('works')).single;
    expect(work['cover_path'], cover);
    final meta = await WorkMetadataDao(db).getByWork(work['id'] as int);
    expect(meta!.coverSource, 'local');
    expect(meta.coverFetchedAt, isNotNull);
  });

  test('同一棵树跑第二次不再新建，曲目也不重复', () async {
    await touch(root, 'RJ294126 作品A/01.mp3');
    await touch(root, 'RJ294126 作品A/02.mp3');
    final plan = await scanImportTree(root.path, writeCover: false);

    final first = await importer.apply(plan);
    final second = await importer.apply(plan);

    expect(first.worksCreated, 1);
    expect(second.worksCreated, 0);
    expect(second.worksSkipped, 1);
    expect((await db.query('works')).length, 1);
    expect((await db.query('media')).length, 2);
  });

  test('没编号的作品照样落库，元数据行不建', () async {
    await touch(root, '普通作品/01.mp3');
    final plan = await scanImportTree(root.path, writeCover: false);
    final outcome = await importer.apply(plan);
    expect(outcome.worksCreated, 1);
    expect(await db.query('work_metadata'), isEmpty);
  });

  test('一次导入多部作品，各自的曲目挂在自己的工作下', () async {
    await touch(root, 'RJ294126 A/01.mp3');
    await touch(root, 'RJ294126 A/02.mp3');
    await touch(root, 'RJ300002 B/01.mp3');
    final plan = await scanImportTree(root.path, writeCover: false);
    final outcome = await importer.apply(plan);

    expect(outcome.worksCreated, 2);
    expect(outcome.tracksInserted, 3);
    final works = await db.query('works', orderBy: 'name');
    for (final work in works) {
      final folders = await db.query('folder_paths',
          where: 'folder_id IN (SELECT id FROM folders WHERE work_id = ?)',
          whereArgs: [work['id']]);
      final dir = folders.single['path'] as String;
      final rows = await db.query('media',
          where: 'path LIKE ?', whereArgs: ['$dir%']);
      expect(rows, isNotEmpty);
    }
  });
}
