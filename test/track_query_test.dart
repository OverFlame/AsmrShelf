import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:sqflite/sqflite.dart';

import 'package:asmrshelf/db/database.dart';
import 'package:asmrshelf/db/track_dao.dart';
import 'package:asmrshelf/services/data_dir_service.dart';
import 'support/test_env.dart';


/// 查询层回归测试（报告第 23、24、27 项）。
///
/// 前三个用例针对 LIKE 通配符未转义：旧实现里搜索框输入 `%` 会命中全部曲目，
/// 目录名里的 `_` 会让「直属曲目」的边界判断穿透到相邻目录。
/// 中间两个用例针对占位符数量无上限：目录/id 集合按 500 分批，
/// 跨批次重复命中的曲目要去重。
/// 最后一个用例针对播放历史：插入与裁剪放进同一个事务。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late Database db;
  late TrackDao dao;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('audioshelf_query');
    PathProviderPlatform.instance =
        FakePathProvider(p.join(tmp.path, 'support'));
    DataDirService.instance.resetCache();
    await DatabaseManager.instance.close();
    await DatabaseManager.instance.init();
    db = DatabaseManager.instance.db;
    dao = TrackDao(db);
  });

  tearDown(() async {
    await DatabaseManager.instance.close();
    await tmp.delete(recursive: true);
  });

  Future<int> add(String path, {String? filename}) => dao.insert(
        TrackItem(
          path: path,
          // Linux 上 p.basename 不认 `\`，Windows 路径用例要显式给文件名。
          filename: filename ?? p.basename(path),
          addedAt: 1,
        ),
      );

  Future<int> countHistory() async {
    final rows = await db.rawQuery('SELECT COUNT(*) AS n FROM play_history');
    return rows.first['n']! as int;
  }

  test('搜索里的 % 不再命中全部曲目', () async {
    await add('/m/a/1.mp3');
    await add('/m/a/2.mp3');

    expect(await dao.searchByName('%'), isEmpty);
    expect(await dao.searchByName('1'), hasLength(1));
  });

  test('搜索里的 _ 不再匹配任意单字符', () async {
    await add('/m/a_b.mp3');
    await add('/m/axb.mp3');

    final hits = await dao.searchByName('a_b');
    expect(hits.map((t) => t.filename), ['a_b.mp3']);
  });

  test('目录名里的下划线不再穿透直属曲目的边界', () async {
    await add('/m/my_music/1.mp3');
    await add('/m/my_music/sub/2.mp3');
    await add('/m/myAmusic/3.mp3');

    final direct = await dao.queryDirectInDir('/m/my_music');
    expect(direct.map((t) => t.filename), ['1.mp3']);
  });

  test('根目录下只返回第一层曲目', () async {
    await add('/a.mp3');
    await add('/sub/b.mp3');

    final direct = await dao.queryDirectInDir('/');
    expect(direct.map((t) => t.filename), ['a.mp3']);
  });

  test('Windows 盘符根目录同样只返回第一层', () async {
    await add('C:\\a.mp3', filename: 'a.mp3');
    await add('C:\\sub\\b.mp3', filename: 'b.mp3');

    expect((await dao.queryDirectInDir('C:\\')).map((t) => t.filename), ['a.mp3']);
    expect((await dao.queryDirectInDir('C:')).map((t) => t.filename), ['a.mp3']);
  });

  test('目录前缀不命中同名前缀的相邻目录', () async {
    await add('/m/vol/1.mp3');
    await add('/m/vol/extra/2.mp3');
    await add('/m/vol2/3.mp3');

    final found = await dao.queryByDirs(['/m/vol']);
    expect(found.map((t) => t.filename).toSet(), {'1.mp3', '2.mp3'});
  });

  test('目录区间查询走 path 的 NOCASE 索引', () async {
    await add('/m/vol/1.mp3');
    final rows = await db.rawQuery(
      'EXPLAIN QUERY PLAN SELECT * FROM tracks '
      'WHERE path COLLATE NOCASE >= ? AND path COLLATE NOCASE < ?',
      ['/m/vol/', '/m/vol0'],
    );
    final plan = rows.map((r) => r['detail']).join(' ');
    expect(plan, contains('idx_media_type_path_nocase'));
  });

  test('目录数超过一批时仍然查得到，并按文件名排序', () async {
    final dirs = List.generate(600, (i) => '/m/d$i');
    await add('/m/d0/z.mp3');
    await add('/m/d599/a.mp3');

    final found = await dao.queryByDirs(dirs);
    expect(found.map((t) => t.filename), ['a.mp3', 'z.mp3']);
  });

  test('互相包含的目录跨批次命中时，同一条曲目只返回一次', () async {
    final dirs = List.generate(600, (i) => '/m/d$i');
    dirs[0] = '/m/a';
    dirs[550] = '/m/a/b';
    await add('/m/a/b/x.mp3');

    final found = await dao.queryByDirs(dirs);
    expect(found.map((t) => t.filename), ['x.mp3']);
  });

  test('id 集合超过一批时也能查全路径', () async {
    final ids = <int>{};
    for (int i = 0; i < 600; i++) {
      ids.add(await add('/m/x/$i.mp3'));
    }

    expect(await dao.pathsByIds(ids), hasLength(600));
  });

  test('裁剪被拒绝时插入要一起回滚', () async {
    final id = await add('/m/a/1.mp3');
    for (int i = 0; i < 201; i++) {
      await db.insert('play_history', {'media_id': id, 'played_at': 1000 + i});
    }
    // 让裁剪语句必然失败：旧实现先提交插入再执行裁剪，会多出一条历史
    await db.execute('CREATE TRIGGER no_prune BEFORE DELETE ON play_history '
        "BEGIN SELECT RAISE(ABORT, '禁止裁剪'); END");
    final before = await countHistory();

    await expectLater(dao.recordPlay(id, 9999), throwsA(anything));

    expect(await countHistory(), before);
  });

  test('连续记录播放时按最旧裁剪，条数不超过 200', () async {
    final id = await add('/m/a/1.mp3');
    for (int i = 0; i < 250; i++) {
      await dao.recordPlay(id, 1000 + i);
    }

    expect(await countHistory(), 200);
  });
}
