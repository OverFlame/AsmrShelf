import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:sqflite/sqflite.dart';

import 'package:asmrshelf/db/database.dart';
import 'package:asmrshelf/db/media_dao.dart';
import 'package:asmrshelf/db/work_dao.dart';
import 'package:asmrshelf/services/auto_import_scanner.dart';
import 'package:asmrshelf/services/data_dir_service.dart';
import '../support/test_env.dart';

/// 扫描清单：五态判定、忽略列表、读不了的目录。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late Database db;
  late AutoImportScanner scanner;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('asmrshelf_auto_scan');
    PathProviderPlatform.instance =
        FakePathProvider(p.join(tmp.path, 'support'));
    DataDirService.instance.resetCache();
    await DatabaseManager.instance.close();
    await DatabaseManager.instance.init();
    db = DatabaseManager.instance.db;
    scanner = AutoImportScanner(db);
  });

  tearDown(() async {
    await DatabaseManager.instance.close();
    await tmp.delete(recursive: true);
  });

  Directory seedWork(String root, String name) {
    final dir = Directory(p.join(tmp.path, root, name))
      ..createSync(recursive: true);
    File(p.join(dir.path, '01.mp3')).writeAsBytesSync(const [0, 1]);
    return dir;
  }

  test('新目录是新建作品，导入后变无变化，加文件后有新增', () async {
    final root = Directory(p.join(tmp.path, '曲库'))..createSync();
    final dir = seedWork('曲库', 'RJ123456 作品A');
    final work = await WorkDao(db).create('作品A');
    await db.update('works', {'root_path': dir.path},
        where: 'id = ?', whereArgs: [work.id]);
    await MediaDao(db).insertRows([
      {
        'path': p.join(dir.path, '01.mp3'),
        'media_type': MediaType.audio.value,
        'filename': '01.mp3',
        'added_at': 1,
      }
    ]);

    var list = await scanner.scan(roots: [root.path]);
    expect(list, hasLength(1));
    expect(list.single.state, AutoImportState.unchanged);
    expect(list.single.code, 'RJ123456');

    File(p.join(dir.path, '02.mp3')).writeAsBytesSync(const [0, 1]);
    list = await scanner.scan(roots: [root.path]);
    expect(list.single.state, AutoImportState.newTracks);
    expect(list.single.newCount, 1);
    expect(list.single.audioCount, 2);

    final dir2 = seedWork('曲库', '作品B');
    list = await scanner.scan(roots: [root.path]);
    final b = list.firstWhere((c) => c.dirPath == dir2.path);
    expect(b.state, AutoImportState.newWork);
    expect(b.newCount, 1);
  });

  test('忽略的目录标为已忽略，不读它的内容', () async {
    final root = Directory(p.join(tmp.path, '曲库'))..createSync();
    final dir = seedWork('曲库', '作品A');

    final list = await scanner.scan(
      roots: [root.path],
      ignored: [dir.path],
    );
    expect(list.single.state, AutoImportState.ignored);
    expect(list.single.audioCount, 0);
  });

  test('没有音频的子目录不进清单，读不了的目录标出来', () async {
    final root = Directory(p.join(tmp.path, '曲库'))..createSync();
    Directory(p.join(root.path, '空目录')).createSync();
    final locked = Directory(p.join(root.path, '打不开'))..createSync();
    File(p.join(locked.path, '01.mp3')).writeAsBytesSync(const [0, 1]);
    // 目录权限归零，list 会抛异常。
    Process.runSync('chmod', ['000', locked.path]);

    try {
      final list = await scanner.scan(roots: [root.path]);
      expect(list.any((c) => c.name == '空目录'), isFalse);
      final bad = list.firstWhere((c) => c.name == '打不开');
      expect(bad.state, AutoImportState.unreadable);
    } finally {
      Process.runSync('chmod', ['755', locked.path]);
    }
  });

  test('多个根目录按顺序合并，不存在的根目录跳过', () async {
    final r1 = Directory(p.join(tmp.path, '库一'))..createSync();
    final r2 = Directory(p.join(tmp.path, '库二'))..createSync();
    seedWork('库一', '作品A');
    seedWork('库二', '作品B');

    final list = await scanner.scan(
      roots: [r1.path, p.join(tmp.path, '不存在'), r2.path],
    );
    expect(list.map((c) => c.name), ['作品A', '作品B']);
  });
}
