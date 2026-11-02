import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:sqflite/sqflite.dart';

import 'package:asmrshelf/db/database.dart';
import 'package:asmrshelf/db/work_dao.dart';
import 'package:asmrshelf/db/work_metadata_dao.dart';
import 'package:asmrshelf/services/data_dir_service.dart';
import 'package:asmrshelf/state/app_state.dart';
import 'package:asmrshelf/state/player_controller.dart';
import '../support/test_env.dart';

/// 作品层的 RJ 号排序：按数字、无编号永远最后。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late Database db;
  late AppState state;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('asmrshelf_sort');
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

  test('RJ 号按数字排序，无编号无论升降序都排最后', () async {
    final low = await WorkDao(db).create('低编号');
    final high = await WorkDao(db).create('高编号');
    final none = await WorkDao(db).create('没编号');
    await WorkMetadataDao(db).upsert(
      WorkMetadata(workId: low.id!, rjCode: 'RJ00100000'),
    );
    await WorkMetadataDao(db).upsert(
      WorkMetadata(workId: high.id!, rjCode: 'RJ00200000'),
    );
    await state.dlsite.loadCodes();
    await state.refresh();

    await state.setWorksSortKey('code');
    await state.setWorksSortDescending(false);
    expect(
      [low, high, none]..sort(state.worksComparator),
      [low, high, none],
    );

    await state.setWorksSortDescending(true);
    expect(
      [low, high, none]..sort(state.worksComparator),
      [high, low, none],
    );
  });

  test('新导入的作品还没进缓存时，从作品名兜底取编号', () async {
    final fresh = await WorkDao(db).create('RJ00050000 新作品');
    await state.refresh();
    // 刷新本身不再重扫全部编号；缓存里没有这一部。
    expect(state.dlsite.codeSync(fresh.id!), isNull);
    expect(state.dlsite.codeForWork(fresh), 'RJ00050000');
  });
}
