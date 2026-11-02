import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:sqflite/sqflite.dart';

import 'package:asmrshelf/db/database.dart';
import 'package:asmrshelf/db/work_dao.dart';
import 'package:asmrshelf/services/data_dir_service.dart';
import 'package:asmrshelf/services/import_service.dart';
import 'package:asmrshelf/state/app_state.dart';
import 'package:asmrshelf/state/player_controller.dart';
import 'support/test_env.dart';


/// 导入守卫的回归测试（报告第 7、8 项）。
///
/// 这些用例都按「旧实现必须失败」设计：
/// 旧代码每次导入都新建 ImportService，实例字段守卫拦不住并发；
/// 旧代码先建作品再导入，目录里没有音频就留下空作品。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late Database db;
  late AppState state;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('audioshelf_import');
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

  /// 造一个目录，写入 [names] 指定的文件（内容随意，元数据读不出来不影响导入）。
  Future<Directory> makeDir(String name, List<String> files) async {
    final dir = await Directory(p.join(tmp.path, name)).create(recursive: true);
    for (final f in files) {
      final file = File(p.join(dir.path, f));
      await file.parent.create(recursive: true);
      await file.writeAsBytes([0, 1, 2, 3]);
    }
    return dir;
  }

  Future<int> folderPathCount() async {
    final rows = await db.query('folder_paths', columns: ['path']);
    return rows.length;
  }

  Future<int> distinctFolderPathCount() async {
    final rows = await db.rawQuery(
        'SELECT COUNT(DISTINCT path) AS n FROM folder_paths');
    return rows.first['n'] as int;
  }

  test('目录内没有可导入的媒体时不创建作品', () async {
    // 阶段 4 起判定口径变成「音频 > 图片 > 视频」推断库归属（BUILD_GUIDE 第 18.2 节）：
    // 只有一张封面图也算图片库，所以要真的没有任何白名单媒体才不建作品。
    final dir = await makeDir('nothing', ['readme.txt', 'notes.md']);

    final work = await state.importDirectory(dir.path);

    expect(work, isNull, reason: '没有可导入的媒体就不该有作品');
    expect(await WorkDao(db).listAll(), isEmpty);
    expect(state.importing, isFalse);
  });

  test('只有封面图的目录按图片库建作品', () async {
    final dir = await makeDir('coveronly', ['readme.txt', 'cover.png']);

    final work = await state.importDirectory(dir.path);

    expect(work, isNotNull, reason: '封面图是图片，目录该进图片库');
    expect(work!.library, 'media');
    final rows = await db.query('media', where: 'media_type = ?', whereArgs: ['image']);
    expect(rows, hasLength(1));
    expect(state.importing, isFalse);
  });

  test('同时发起两次目录导入，只跑起来一个', () async {
    final a = await makeDir('dirA', ['a1.mp3']);
    final b = await makeDir('dirB', ['b1.mp3']);

    // 两次调用都不 await：第二次必须在第一个 await 之前就被守卫挡住。
    final first = state.importDirectory(a.path);
    final second = state.importDirectory(b.path);
    final results = await Future.wait([first, second]);

    expect(results.where((w) => w != null).length, 1,
        reason: '并发的第二次导入应被拒绝');
    expect((await WorkDao(db).listAll()).length, 1);
    final tracks = await db.query('tracks');
    expect(tracks.length, 1, reason: '另一个目录的曲目不该被导入');
    expect(state.importing, isFalse);
  });

  test('同一个目录导入两次，第二次不建作品、不重复镜像目录', () async {
    final dir = await makeDir('dup', ['sub/1.mp3', 'sub/2.mp3']);

    final first = await state.importDirectory(dir.path);
    expect(first, isNotNull);
    final pathsAfterFirst = await folderPathCount();
    expect(pathsAfterFirst, greaterThan(0));

    final second = await state.importDirectory(dir.path);

    expect(second, isNull, reason: '曲目都已入库，不该再建一个作品');
    expect((await WorkDao(db).listAll()).length, 1);
    expect(await folderPathCount(), pathsAfterFirst,
        reason: '不该重复镜像目录树');
    expect(await distinctFolderPathCount(), pathsAfterFirst,
        reason: 'folder_paths 里不该出现重复路径');
  });

  test('导入进行中再调 importDirectoryIntoWork 会被拒绝', () async {
    final dir = await makeDir('busy', ['1.mp3']);
    final work = await WorkDao(db).create('已有作品');

    final first = state.importDirectory(dir.path);
    final rejected = state.importDirectoryIntoWork(dir.path, work.id!);
    await Future.wait([first, rejected]);

    expect(state.importing, isFalse);
    expect((await WorkDao(db).listAll()).length, 2,
        reason: '只应有「已有作品」和本次导入新建的作品各一个');
    expect((await db.query('tracks')).length, 1,
        reason: '被拒绝的那次不该插入曲目');
  });

  test('ImportService 的导入标志是跨实例共享的静态字段', () async {
    final dir = await makeDir('static', ['1.mp3']);
    final work = await WorkDao(db).create('静态守卫');

    final s1 = ImportService.fromDB();
    final s2 = ImportService.fromDB();

    // 只订阅第一个流：生成器体在第一个 await 之前就会把标志置位。
    final sub =
        s1.importDirectory(dir.path, workId: work.id!).listen((_) {});
    await Future<void>.delayed(Duration.zero);

    expect(s1.isImporting, isTrue);
    expect(s2.isImporting, isTrue,
        reason: '实例字段的话这里会是 false，第二次导入就拦不住');

    await sub.asFuture<void>().catchError((Object _) {});
  });

  test('绕过 AppState 的第二次导入收到 StateError，而不是静默成功', () async {
    final dir = await makeDir('reject', ['1.mp3']);
    final work = await WorkDao(db).create('显式拒绝');

    final s1 = ImportService.fromDB();
    final s2 = ImportService.fromDB();

    final sub = s1.importDirectory(dir.path, workId: work.id!).listen((_) {});
    await Future<void>.delayed(Duration.zero);

    await expectLater(
      s2.importDirectory(dir.path, workId: work.id!).toList(),
      throwsStateError,
    );

    await sub.asFuture<void>().catchError((Object _) {});
  });
}
