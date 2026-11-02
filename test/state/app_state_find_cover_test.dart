import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:asmrshelf/db/database.dart';
import 'package:asmrshelf/db/work_dao.dart';
import 'package:asmrshelf/services/data_dir_service.dart';
import 'package:asmrshelf/state/app_state.dart';
import 'package:asmrshelf/state/player_controller.dart';
import '../support/test_env.dart';

/// 最小 PNG 头：只要能被尺寸探测读出宽高即可。
List<int> pngBytes({int width = 600, int height = 800}) => [
      ...List<int>.filled(8, 0)..[0] = 0x89, // 签名前 8 字节，占位后覆盖
      0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52,
      (width >> 24) & 0xff, (width >> 16) & 0xff, (width >> 8) & 0xff, width & 0xff,
      (height >> 24) & 0xff, (height >> 16) & 0xff, (height >> 8) & 0xff, height & 0xff,
      8, 6, 0, 0, 0,
    ]..[0] = 0x89
      ..[1] = 0x50
      ..[2] = 0x4E
      ..[3] = 0x47
      ..[4] = 0x0D
      ..[5] = 0x0A
      ..[6] = 0x1A
      ..[7] = 0x0A;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late Directory mediaRoot;
  late String workDir;
  late AppState state;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('asmrshelf_find_cover');
    mediaRoot = Directory(p.join(tmp.path, 'media'));
    workDir = p.join(mediaRoot.path, 'RJ294126 作品A');
    await Directory(p.join(workDir, '缩略图')).create(recursive: true);
    File(p.join(workDir, '01.mp3')).writeAsBytesSync(List<int>.filled(8, 0));
    File(p.join(workDir, '缩略图', '封面.png')).writeAsBytesSync(pngBytes());
    PathProviderPlatform.instance =
        FakePathProvider(p.join(tmp.path, 'support'));
    DataDirService.instance.resetCache();
    await DatabaseManager.instance.close();
    await DatabaseManager.instance.init();
    state = AppState(player: PlayerController());
    await state.init();
    await state.importWorksFromRoot(mediaRoot.path);
  });

  tearDown(() async {
    await DatabaseManager.instance.close();
    await tmp.delete(recursive: true);
  });

  test('从信号目录挑图，写成编号封面并记到 works.cover_path', () async {
    final workId = state.works.single.id!;
    // 导入阶段已经写过一次封面，这里清掉记录与文件，专门测「从文件里找」。
    await WorkDao(DatabaseManager.instance.db).setCover(workId, null);
    for (final name in ['RJ294126_cover.png', 'cover.png']) {
      final file = File(p.join(workDir, name));
      if (file.existsSync()) file.deleteSync();
    }

    expect(await state.findLocalCoverForWork(workId), isNull);

    final written = File(p.join(workDir, 'RJ294126_cover.png'));
    expect(written.existsSync(), isTrue);

    final work = await WorkDao(DatabaseManager.instance.db).getById(workId);
    expect(work!.coverPath, written.path);
  });

  test('已经有封面时不动它，返回提示', () async {
    final workId = state.works.single.id!;
    await state.findLocalCoverForWork(workId);
    final again = await state.findLocalCoverForWork(workId);
    expect(again, contains('已经有封面'));
  });

  test('目录里没有图时给提示，不写文件', () async {
    final bare = Directory(p.join(mediaRoot.path, '普通作品'))
      ..createSync(recursive: true);
    File(p.join(bare.path, '01.mp3')).writeAsBytesSync(List<int>.filled(8, 0));
    await state.importWorksFromRoot(mediaRoot.path);
    final target = state.works
        .firstWhere((w) => w.name == '普通作品')
        .id!;
    final message = await state.findLocalCoverForWork(target);
    expect(message, contains('没找到'));
    expect(File(p.join(bare.path, 'cover.png')).existsSync(), isFalse);
  });
}
