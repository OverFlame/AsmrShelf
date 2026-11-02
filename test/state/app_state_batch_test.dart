import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:sqflite/sqflite.dart';

import 'package:asmrshelf/db/database.dart';
import 'package:asmrshelf/db/folder_dao.dart';
import 'package:asmrshelf/db/work_dao.dart';
import 'package:asmrshelf/services/data_dir_service.dart';
import 'package:asmrshelf/state/app_state.dart';
import 'package:asmrshelf/state/player_controller.dart';
import '../support/test_env.dart';

/// 作品层批量操作：删除、按作品刷新、批量打标签。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late Database db;
  late AppState state;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('asmrshelf_batch');
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

  Future<int> seedWork(String name) async {
    final work = await WorkDao(db).create(name);
    final root = Directory(p.join(tmp.path, name))..createSync(recursive: true);
    await db.update('works', {'root_path': root.path},
        where: 'id = ?', whereArgs: [work.id]);
    final folder = await FolderDao(db).create(name, workId: work.id);
    await FolderDao(db).addPath(folder.id!, root.path);
    File(p.join(root.path, '01.mp3')).writeAsBytesSync(const [0, 0, 0, 1]);
    return work.id!;
  }

  Future<int> seedLegacyNestedWork(String name, {bool withRoot = true}) async {
    final work = await WorkDao(db).create(name);
    final root = Directory(p.join(tmp.path, name))..createSync(recursive: true);
    Directory(p.join(root.path, '01_mp3')).createSync(recursive: true);
    Directory(p.join(root.path, '02_wav')).createSync(recursive: true);
    await db.update('works', {'root_path': root.path},
        where: 'id = ?', whereArgs: [work.id]);
    if (withRoot) {
      final folder = await FolderDao(db).create(name, workId: work.id);
      await FolderDao(db).addPath(folder.id!, root.path);
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.insert('media', {
      'path': p.join(root.path, '01_mp3', '01.mp3'),
      'media_type': 'audio',
      'filename': '01.mp3',
      'added_at': now,
    });
    await db.insert('media', {
      'path': p.join(root.path, '02_wav', '01.wav'),
      'media_type': 'audio',
      'filename': '01.wav',
      'added_at': now,
    });
    return work.id!;
  }

  Future<void> settleRefresh() async {
    await state.refresh();
  }

  test('进入旧版一次性导入的作品时补齐子文件夹树', () async {
    final id = await seedLegacyNestedWork('旧作品');
    await state.refresh();
    final root = (await FolderDao(db).listRootsByWork(id)).single;
    expect(await FolderDao(db).listChildren(root.id!), isEmpty);

    await state.enterWork(id);

    final children = await FolderDao(db).listChildren(root.id!);
    expect(children.map((f) => f.name), ['01_mp3', '02_wav']);

    await state.enterFolder(root.id!);
    expect(state.centerFolders.map((f) => f.name), ['01_mp3', '02_wav']);
  });

  test('作品完全没有根文件夹时也能补出整棵树', () async {
    final id = await seedLegacyNestedWork('无根作品', withRoot: false);
    await state.refresh();
    expect(await FolderDao(db).listRootsByWork(id), isEmpty);

    await state.enterWork(id);

    final root = (await FolderDao(db).listRootsByWork(id)).single;
    expect(root.name, '无根作品');
    final children = await FolderDao(db).listChildren(root.id!);
    expect(children.map((f) => f.name), ['01_mp3', '02_wav']);
  });

  test('deleteWorks 删掉多部作品并清空选中', () async {
    final a = await seedWork('作品A');
    final b = await seedWork('作品B');
    await state.rescanFromDisk();
    await settleRefresh();
    state.enterWorkSelectionMode();
    state.toggleWorkSelect(a);
    state.toggleWorkSelect(b);

    final deleted = await state.deleteWorks([a, b]);
    expect(deleted, greaterThanOrEqualTo(2));
    expect(state.works, isEmpty);
    expect(state.workSelectionMode, isFalse);
    expect(state.selectedWorkIds, isEmpty);
  });

  test('rescanWorks 只刷新指定作品，别的作品不跟着补', () async {
    final a = await seedWork('作品A');
    final b = await seedWork('作品B');
    await state.rescanFromDisk();
    // 两边各加一首，只重扫 A。
    File(p.join(tmp.path, '作品A', '02.mp3')).writeAsBytesSync(const [0, 0]);
    File(p.join(tmp.path, '作品B', '02.mp3')).writeAsBytesSync(const [0, 0]);

    final outcome = await state.rescanWorks([a]);
    expect(outcome.added, 1);

    final aRows = await state.mediaIdsUnderWork(a);
    final bRows = await state.mediaIdsUnderWork(b);
    expect(aRows, hasLength(2));
    expect(bRows, hasLength(1), reason: 'B 没被重扫，不该补进新文件');
  });

  test('addTagsToWorks 作用于选中作品下的全部媒体', () async {
    final a = await seedWork('作品A');
    final b = await seedWork('作品B');
    await state.rescanFromDisk();
    await settleRefresh();
    final tag = await state.createTag('睡眠');

    final affected = await state.addTagsToWorks([a], [tag]);
    expect(affected, 1);
    final aMedia = await state.mediaIdsUnderWork(a);
    final bMedia = await state.mediaIdsUnderWork(b);
    expect(await state.getTagIdsOnMedia(aMedia), contains(tag.id));
    expect(await state.getTagIdsOnMedia(bMedia), isEmpty);
  });
}
