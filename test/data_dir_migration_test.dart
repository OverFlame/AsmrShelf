import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:asmrshelf/services/data_dir_service.dart';
import 'support/test_env.dart';


void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late String supportRoot;
  late String defaultDir;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('audioshelf_datadir');
    supportRoot = p.join(tmp.path, 'support');
    defaultDir = p.join(supportRoot, 'AsmrShelf');
    PathProviderPlatform.instance = FakePathProvider(supportRoot);
    DataDirService.instance.resetCache();
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  Future<void> seed(String dir) async {
    await Directory(p.join(dir, 'covers')).create(recursive: true);
    await File(p.join(dir, 'asmr_shelf.db')).writeAsString('DB-CONTENT');
    await File(p.join(dir, 'settings.json')).writeAsString('{"theme":"dark"}');
    await File(p.join(dir, 'covers', 'track_1.jpg')).writeAsString('IMG');
  }

  String pointerPath() => p.join(defaultDir, '.datadir');

  test('迁移成功：文件到位、指针指向新目录、缓存同步', () async {
    await seed(defaultDir);
    final newD = p.join(tmp.path, 'new');

    final result = await DataDirService.instance.migrateTo(newD);

    expect(result, p.normalize(newD));
    expect((await DataDirService.instance.dataDir), p.normalize(newD));
    expect(File(pointerPath()).readAsStringSync().trim(), p.normalize(newD));

    expect(File(p.join(newD, 'asmr_shelf.db')).readAsStringSync(), 'DB-CONTENT');
    expect(File(p.join(newD, 'settings.json')).readAsStringSync(),
        '{"theme":"dark"}');
    expect(File(p.join(newD, 'covers', 'track_1.jpg')).readAsStringSync(), 'IMG');
    expect(File('${pointerPath()}.tmp').existsSync(), isFalse,
        reason: '临时指针文件不该留下');
  });

  test('升级备份跟着搬走，换盘后还能找回旧库', () async {
    await seed(defaultDir);
    await Directory(p.join(defaultDir, 'backup')).create(recursive: true);
    await File(p.join(defaultDir, 'backup', 'db-v9-20260101-000000-000.db'))
        .writeAsString('OLD-DB');
    final newD = p.join(tmp.path, 'with-backup');

    await DataDirService.instance.migrateTo(newD);

    expect(
      File(p.join(newD, 'backup', 'db-v9-20260101-000000-000.db'))
          .readAsStringSync(),
      'OLD-DB',
    );
  });

  test('目标已有不同内容的库：抛异常，且不写指针、不改缓存', () async {
    await seed(defaultDir);
    final newD = p.join(tmp.path, 'occupied');
    await Directory(newD).create(recursive: true);
    await File(p.join(newD, 'asmr_shelf.db')).writeAsString('OTHER-DB');

    await expectLater(
      DataDirService.instance.migrateTo(newD),
      throwsA(isA<StateError>()),
    );

    expect(File(pointerPath()).existsSync(), isFalse,
        reason: '失败时不能留下指针文件');
    expect(await DataDirService.instance.dataDir, p.normalize(defaultDir),
        reason: '失败后仍应使用旧目录');
    expect(File(p.join(newD, 'asmr_shelf.db')).readAsStringSync(), 'OTHER-DB',
        reason: '已有数据不能被覆盖');
  });

  test('重复迁到同一目录：内容一致则幂等', () async {
    await seed(defaultDir);
    final newD = p.join(tmp.path, 'again');

    await DataDirService.instance.migrateTo(newD);
    // 清缓存后再迁一次，模拟重启后重跑
    DataDirService.instance.resetCache();
    final second = await DataDirService.instance.migrateTo(newD);

    expect(second, p.normalize(newD));
    expect(File(p.join(newD, 'asmr_shelf.db')).readAsStringSync(), 'DB-CONTENT');
  });

  test('跨多个 64KB 块的同一个文件仍然判定一致', () async {
    // 300KB：比较要跨过好几块，只看第一块或只比长度的实现会漏掉后面的差异。
    await seed(defaultDir);
    final big = List<int>.filled(300 * 1024, 0x41);
    await File(p.join(defaultDir, 'asmr_shelf.db')).writeAsBytes(big);
    final newD = p.join(tmp.path, 'copied');
    await Directory(newD).create(recursive: true);
    await File(p.join(newD, 'asmr_shelf.db')).writeAsBytes(big);

    await DataDirService.instance.migrateTo(newD);

    expect(File(p.join(newD, 'asmr_shelf.db')).lengthSync(), big.length);
  });

  test('差异出现在第一块之后也能查出来', () async {
    await seed(defaultDir);
    final big = List<int>.filled(300 * 1024, 0x41);
    await File(p.join(defaultDir, 'asmr_shelf.db')).writeAsBytes(big);
    final other = List<int>.of(big)..[200 * 1024] = 0x42;
    final newD = p.join(tmp.path, 'occupied2');
    await Directory(newD).create(recursive: true);
    await File(p.join(newD, 'asmr_shelf.db')).writeAsBytes(other);

    await expectLater(
      DataDirService.instance.migrateTo(newD),
      throwsA(isA<StateError>()),
      reason: '第 4 块里有一个字节不同，不能被当成一致而跳过',
    );
  });

  test('迁移连外链播放写出的 playlist 目录一起搬', () async {
    await seed(defaultDir);
    await Directory(p.join(defaultDir, 'playlist')).create(recursive: true);
    await File(p.join(defaultDir, 'playlist', '专辑.m3u8')).writeAsString('#EXTM3U');
    final newD = p.join(tmp.path, 'withlist');

    await DataDirService.instance.migrateTo(newD);

    expect(File(p.join(newD, 'playlist', '专辑.m3u8')).readAsStringSync(),
        '#EXTM3U');
  });

  test('目标即当前目录：直接返回，不做复制', () async {
    await seed(defaultDir);

    final result =
        await DataDirService.instance.migrateTo(defaultDir);

    expect(result, p.normalize(defaultDir));
    expect(File(pointerPath()).existsSync(), isFalse);
  });
}
