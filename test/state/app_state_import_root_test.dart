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

/// 一次性导入根目录：扫描预览、落库、再跑一次要全部跳过。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late Directory mediaRoot;
  late AppState state;

  Future<File> touch(String relative, {int bytes = 64}) async {
    final file = File(p.join(mediaRoot.path, relative));
    await file.parent.create(recursive: true);
    await file.writeAsBytes(List<int>.filled(bytes, 0));
    return file;
  }

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('asmrshelf_import_root');
    mediaRoot = Directory(p.join(tmp.path, 'media'));
    await mediaRoot.create(recursive: true);
    PathProviderPlatform.instance =
        FakePathProvider(p.join(tmp.path, 'support'));
    DataDirService.instance.resetCache();
    await DatabaseManager.instance.close();
    await DatabaseManager.instance.init();
    state = AppState(player: PlayerController());
    await state.init();
  });

  tearDown(() async {
    await DatabaseManager.instance.close();
    await tmp.delete(recursive: true);
  });

  test('扫描根目录得到每部作品与曲目数', () async {
    await touch('RJ294126 作品A/01 第一首.mp3');
    await touch('RJ294126 作品A/02 第二首.mp3');
    await touch('普通作品/01 只有一首.flac');
    await touch('空目录/说明.txt');

    final plan = await state.scanWorksRoot(mediaRoot.path);
    expect(plan.works.length, 2);
    expect(plan.works.first.code, 'RJ294126');
    expect(plan.works.first.tracks.length, 2);
    expect(plan.works.last.code, isNull);
    expect(plan.skipped, anyElement(endsWith('空目录')));
  });

  test('导入后作品进列表、曲目进库，再跑一次全跳过', () async {
    await touch('RJ294126 作品A/01 第一首.mp3');
    await touch('RJ294126 作品A/02 第二首.mp3');
    await touch('普通作品/01 只有一首.flac');

    final first = await state.importWorksFromRoot(mediaRoot.path);
    expect(first, isNotNull);
    expect(first!.worksCreated, 2);
    expect(first.tracksInserted, 3);
    expect(state.works.length, 2);
    expect(state.works.every((w) => w.library == 'audio'), isTrue);
    expect(state.works.map((w) => w.name), containsAll(['作品A', '普通作品']));

    final second = await state.importWorksFromRoot(mediaRoot.path);
    expect(second!.worksCreated, 0);
    expect(second.worksSkipped, 2);
    expect(await WorkDao(DatabaseManager.instance.db).listAll(), hasLength(2));
  });

  test('根目录里没有作品时不建任何行', () async {
    await touch('散装文件.mp3');
    final outcome = await state.importWorksFromRoot(mediaRoot.path);
    expect(outcome!.worksCreated, 0);
    expect(state.works, isEmpty);
  });
}
