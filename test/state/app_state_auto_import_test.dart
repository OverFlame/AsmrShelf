import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import 'package:asmrshelf/db/database.dart';
import 'package:asmrshelf/services/data_dir_service.dart';
import 'package:asmrshelf/services/auto_import_scanner.dart';
import 'package:asmrshelf/services/settings_service.dart';
import 'package:asmrshelf/state/app_state.dart';
import 'package:asmrshelf/state/player_controller.dart';
import '../support/test_env.dart';

/// 自动导入：开关、根目录、启动时扫描一次、重复扫描不重复建。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late Database db;
  late AppState state;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    SettingsService.instance.resetForTest();
    tmp = await Directory.systemTemp.createTemp('asmrshelf_auto_import');
    PathProviderPlatform.instance = FakePathProvider(
      p.join(tmp.path, 'support'),
    );
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

  /// 根目录下每个子目录一部作品，子目录里放一首音频。
  Future<Directory> seedRoot() async {
    final root = Directory(p.join(tmp.path, '曲库'))..createSync(recursive: true);
    final workDir = Directory(p.join(root.path, '作品A'))
      ..createSync(recursive: true);
    File(p.join(workDir.path, '01.mp3')).writeAsBytesSync(const [0, 1, 2]);
    return root;
  }

  Future<int> workCount() async {
    final rows = await db.query(
      'works',
      where: 'library = ?',
      whereArgs: ['audio'],
    );
    return rows.length;
  }

  test('开关关着时启动不扫描', () async {
    final root = await seedRoot();
    await state.setAutoImportRoot(root.path);
    expect(state.autoImportEnabled, isFalse);

    final outcome = await state.autoImportOnStartup();
    expect(outcome, isNull);
    expect(await workCount(), 0);
  });

  test('开启后按根目录导入子目录作品，并记下时间', () async {
    final root = await seedRoot();
    await state.setAutoImportRoot(root.path);
    await state.setAutoImportEnabled(true);
    expect(state.lastAutoImportAt, isNull);

    final outcome = await state.autoImportOnStartup();
    expect(outcome, isNotNull);
    expect(outcome!.worksCreated, 1);
    expect(await workCount(), 1);
    expect(state.works.map((w) => w.name), contains('作品A'));
    expect(state.lastAutoImportAt, isNotNull);
  });

  test('同一目录再扫一次不会重复建作品', () async {
    final root = await seedRoot();
    await state.setAutoImportRoot(root.path);
    await state.autoImportFromRoot();
    final again = await state.autoImportFromRoot();

    expect(again, isNotNull);
    expect(again!.worksCreated, 0);
    expect(await workCount(), 1);
  });

  test('根目录不存在时不落库，也不写导入时间', () async {
    await state.setAutoImportRoot(p.join(tmp.path, '不存在'));

    final outcome = await state.autoImportFromRoot();
    expect(outcome, isNull);
    expect(await workCount(), 0);
    expect(state.lastAutoImportAt, isNull);
  });

  test('没选根目录时立即扫描返回 null', () async {
    expect(state.autoImportRoot, isNull);
    expect(await state.autoImportFromRoot(), isNull);
  });

  test('根目录设置会持久化到设置服务', () async {
    final root = await seedRoot();
    await state.setAutoImportRoot(root.path);
    await state.setAutoImportEnabled(true);

    expect(SettingsService.instance.autoImportRoot, root.path);
    expect(SettingsService.instance.autoImportEnabled, isTrue);

    await state.setAutoImportRoot(null);
    expect(SettingsService.instance.autoImportRoot, isNull);
  });

  test('多个根目录一起导，每个根目录下的作品都进库', () async {
    final r1 = Directory(p.join(tmp.path, '库一'))..createSync();
    final r2 = Directory(p.join(tmp.path, '库二'))..createSync();
    File(p.join((Directory(p.join(r1.path, '作品A'))..createSync()).path,
            '01.mp3'))
        .writeAsBytesSync(const [0, 1]);
    File(p.join((Directory(p.join(r2.path, '作品B'))..createSync()).path,
            '01.mp3'))
        .writeAsBytesSync(const [0, 1]);
    await state.addAutoImportRoot(r1.path);
    await state.addAutoImportRoot(r2.path);

    final outcome = await state.autoImportFromRoot();
    expect(outcome!.worksCreated, 2);
    expect(state.autoImportRoots, [r1.path, r2.path]);
    expect(await workCount(), 2);
  });

  test('扫描候选：新建、无变化，落库后变无变化；忽略的目录标出来', () async {
    final root = await seedRoot();
    await state.setAutoImportRoot(root.path);
    final dir = p.join(root.path, '作品A');

    var list = await state.scanAutoImportCandidates();
    expect(list.single.state, AutoImportState.newWork);

    final outcome = await state.applyAutoImportCandidates(list);
    expect(outcome!.worksCreated, 1);
    expect(await workCount(), 1);
    expect(state.lastAutoImportAt, isNotNull);

    list = await state.scanAutoImportCandidates();
    expect(list.single.state, AutoImportState.unchanged);

    await state.setAutoImportIgnored([dir]);
    list = await state.scanAutoImportCandidates();
    expect(list.single.state, AutoImportState.ignored);
    expect(SettingsService.instance.autoImportIgnored, [dir]);
  });
}
