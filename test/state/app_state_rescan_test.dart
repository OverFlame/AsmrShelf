import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:sqflite/sqflite.dart';

import 'package:asmrshelf/db/database.dart';
import 'package:asmrshelf/db/media_dao.dart';
import 'package:asmrshelf/db/work_dao.dart';
import 'package:asmrshelf/services/data_dir_service.dart';
import 'package:asmrshelf/state/app_state.dart';
import 'package:asmrshelf/state/player_controller.dart';
import '../support/test_env.dart';

/// 刷新按钮的「以磁盘为准」：新文件补进来，删掉的文件连行一起清掉。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late Database db;
  late AppState state;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('asmrshelf_rescan');
    PathProviderPlatform.instance =
        FakePathProvider(p.join(tmp.path, 'support'));
    DataDirService.instance.resetCache();
    await DatabaseManager.instance.close();
    await DatabaseManager.instance.init();
    db = DatabaseManager.instance.db;
    state = AppState(player: PlayerController());
    await state.init();
  });

  tearDown(() async {
    await DatabaseManager.instance.close();
    await tmp.delete(recursive: true);
  });

  Future<String> seedWorkDir() async {
    final work = await WorkDao(db).create('作品A');
    final root = Directory(p.join(tmp.path, '作品A'))..createSync(recursive: true);
    await db.update('works', {'root_path': root.path},
        where: 'id = ?', whereArgs: [work.id]);
    return root.path;
  }

  Future<List<String>> audioPaths() async {
    final rows = await db.query('media',
        where: 'media_type = ?', whereArgs: ['audio']);
    return [for (final row in rows) row['path'] as String]..sort();
  }

  test('新出现在磁盘上的音频会被补进库', () async {
    final root = await seedWorkDir();
    final file = File(p.join(root, '01.mp3'))..writeAsBytesSync([0, 1, 2]);
    final outcome = await state.rescanFromDisk();
    expect(outcome.added, 1);
    expect(outcome.removed, 0);
    expect(await audioPaths(), [file.path]);
  });

  test('磁盘上已经删掉的音频连行一起清掉', () async {
    final root = await seedWorkDir();
    final gone = File(p.join(root, '02.mp3'))..writeAsBytesSync([0]);
    await MediaDao(db).insertRow({
      'path': gone.path,
      'media_type': 'audio',
      'filename': '02.mp3',
      'added_at': 1,
    });
    gone.deleteSync();

    final outcome = await state.rescanFromDisk();
    expect(outcome.removed, 1);
    expect(outcome.added, 0);
    expect(await audioPaths(), isEmpty);
  });

  test('目录已经不在了就跳过，不抛错也不删行', () async {
    final root = await seedWorkDir();
    final file = File(p.join(root, '03.mp3'))..writeAsBytesSync([0]);
    await MediaDao(db).insertRow({
      'path': file.path,
      'media_type': 'audio',
      'filename': '03.mp3',
      'added_at': 1,
    });
    Directory(root).deleteSync(recursive: true);

    final outcome = await state.rescanFromDisk();
    expect(outcome.missingRoots, 1);
    expect(outcome.removed, 0);
    expect(await audioPaths(), [file.path], reason: '目录不在时不该动已有的行');
  });

  test('非音频文件与图片都不会进音频库', () async {
    final root = await seedWorkDir();
    File(p.join(root, 'cover.jpg')).writeAsBytesSync([0]);
    File(p.join(root, '04.flac')).writeAsBytesSync([0]);
    final outcome = await state.rescanFromDisk();
    expect(outcome.added, 1);
    expect(await audioPaths(), [p.join(root, '04.flac')]);
  });

  test('重复刷新不会产生重复行', () async {
    final root = await seedWorkDir();
    File(p.join(root, '05.mp3')).writeAsBytesSync([0]);
    await state.rescanFromDisk();
    final second = await state.rescanFromDisk();
    expect(second.added, 0);
    expect(second.changed, isFalse);
    expect(await audioPaths(), hasLength(1));
  });
}
