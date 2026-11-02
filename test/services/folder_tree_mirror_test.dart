import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:asmrshelf/db/folder_dao.dart';
import 'package:asmrshelf/db/tables.dart';
import 'package:asmrshelf/db/work_dao.dart';
import 'package:asmrshelf/services/folder_tree_mirror.dart';

void main() {
  sqfliteFfiInit();

  late Directory dbDir;
  late Database db;

  setUp(() async {
    dbDir = await Directory.systemTemp.createTemp('asmrshelf_mirror_db_');
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
  });

  tearDown(() async {
    await db.close();
    if (await dbDir.exists()) await dbDir.delete(recursive: true);
  });

  test('Windows 反斜杠路径也能建出父子文件夹', () async {
    final work = await WorkDao(db).create('作品A');
    final folders = FolderDao(db);
    const root = r'D:\ASMR\RJ294126 作品A';

    await FolderTreeMirror(folders).ensureForPaths(
      rootPath: root,
      rootName: '作品A',
      workId: work.id!,
      mediaPaths: const [
        r'D:\ASMR\RJ294126 作品A\01_mp3\01.mp3',
        r'D:\ASMR\RJ294126 作品A\02_wav\01.wav',
      ],
    );

    final roots = await folders.listRootsByWork(work.id!);
    expect(roots.single.name, '作品A');
    final children = await folders.listChildren(roots.single.id!);
    expect(children.map((f) => f.name), ['01_mp3', '02_wav']);
    for (final child in children) {
      expect(child.parentId, roots.single.id);
      expect(child.workId, work.id);
    }
    expect((await db.query('folder_paths')).length, 3);
  });
}
