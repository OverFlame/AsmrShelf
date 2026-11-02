import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:sqflite/sqflite.dart';

import 'package:asmrshelf/db/database.dart';
import 'package:asmrshelf/db/folder_dao.dart';
import 'package:asmrshelf/db/track_dao.dart';
import 'package:asmrshelf/services/data_dir_service.dart';
import 'package:asmrshelf/state/app_state.dart';
import 'package:asmrshelf/state/player_controller.dart';
import 'support/test_env.dart';


/// 导入原子性回归测试（报告第 17、18 项）。
///
/// 两个用例按「旧实现必须失败」设计：
/// 旧 `_mirrorFolderTree` 是「查一次、建一次、再挂路径」三条独立语句，
/// 并发调用同一路径会建出两个文件夹；
/// 旧 `importDirectory` 先把曲目写库、之后才镜像目录树，建树失败时曲目已经落库，
/// 却没有任何 folder_paths 覆盖它们，调用方看到的是「导入完成」。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late Database db;
  late AppState state;
  late FolderDao folders;
  late TrackDao tracks;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('audioshelf_import_atomic');
    PathProviderPlatform.instance =
        FakePathProvider(p.join(tmp.path, 'support'));
    DataDirService.instance.resetCache();
    await DatabaseManager.instance.close();
    await DatabaseManager.instance.init();
    db = DatabaseManager.instance.db;
    folders = FolderDao(db);
    tracks = TrackDao(db);
    state = AppState(player: PlayerController());
    await state.init();
  });

  tearDown(() async {
    await DatabaseManager.instance.close();
    await tmp.delete(recursive: true);
  });

  Future<List<String>> allTrackPaths() async {
    final all = await tracks.queryAll();
    return all.map((t) => t.path).toList()..sort();
  }

  /// 造一个含 n 个假 mp3 的目录（内容随便，元数据读不出来会退化成空值）。
  Future<String> makeAudioDir(List<String> parts, int count) async {
    final dir = await Directory(p.joinAll([tmp.path, 'media', ...parts]))
        .create(recursive: true);
    for (var i = 1; i <= count; i++) {
      await File(p.join(dir.path, '$i.mp3')).writeAsBytes([0, 1, 2, 3]);
    }
    return dir.path;
  }

  test('并发对同一路径确保文件夹，只产生一个', () async {
    const dir = '/m/album';
    final results = await Future.wait([
      folders.ensureByPath(dir, name: 'album'),
      folders.ensureByPath(dir, name: 'album'),
    ]);

    expect(results.map((f) => f.id).toSet().length, 1,
        reason: '旧实现两个调用都查不到、都新建，会返回两个不同的 id');
    expect((await folders.listAll()).length, 1);
    final rows =
        await db.query('folder_paths', where: 'path = ?', whereArgs: [dir]);
    expect(rows.length, 1, reason: '同一路径只能挂一条映射');
  });

  test('建树失败时一条曲目都不落库，失败原因可见', () async {
    final dir = await makeAudioDir(['album'], 2);

    // workId 999999 不存在：folders.work_id 撞外键，镜像目录树必然失败。
    await state.importDirectoryIntoWork(dir, 999999);

    expect(state.importError, isNotNull,
        reason: '失败必须留下可见状态，旧实现只写一行日志');
    expect(await allTrackPaths(), isEmpty,
        reason: '旧实现先写曲目再建树，此时两条曲目已经落库却没有路径能覆盖它们');
    expect(await db.query('folder_paths'), isEmpty);
  });

  test('成功导入后 importError 为 null，曲目与路径映射都落库', () async {
    final dir = await makeAudioDir(['album'], 2);

    final work = await state.importDirectory(dir);

    expect(work, isNotNull);
    expect(state.importError, isNull);
    expect((await allTrackPaths()).length, 2);
    expect((await db.query('folder_paths')).length, 1);
  });

  test('导入嵌套目录会按层级建父子文件夹', () async {
    final dir = await makeAudioDir(['album'], 1);
    await makeAudioDir(['album', 'sub'], 1);

    final work = await state.importDirectory(dir);
    expect(work, isNotNull);

    final all = await folders.listAll();
    final parent = all.firstWhere((f) => f.name == 'album');
    final child = all.firstWhere((f) => f.name == 'sub');
    expect(child.parentId, parent.id);
    expect(child.workId, work!.id);
    expect(parent.workId, work.id);
  });
}
