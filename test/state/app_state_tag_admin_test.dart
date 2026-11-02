import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:asmrshelf/db/database.dart';
import 'package:asmrshelf/db/folder_dao.dart';
import 'package:asmrshelf/db/media_dao.dart';
import 'package:asmrshelf/db/tag_dao.dart';
import 'package:asmrshelf/services/data_dir_service.dart';
import 'package:asmrshelf/services/settings_service.dart';
import 'package:asmrshelf/state/app_state.dart';
import 'package:asmrshelf/state/player_controller.dart';
import '../support/test_env.dart';


/// 标签管理的四件事：折叠态持久化、删除标签与关联、批量移除记录、重名查询。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late AppState state;
  late MediaDao media;
  late TagDao tags;
  late FolderDao folders;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('asmrshelf_tag_admin');
    PathProviderPlatform.instance =
        FakePathProvider(p.join(tmp.path, 'support'));
    DataDirService.instance.resetCache();
    SettingsService.instance.resetForTest();
    await DatabaseManager.instance.close();
    await DatabaseManager.instance.init();
    await SettingsService.instance.init();
    final db = DatabaseManager.instance.db;
    media = MediaDao(db);
    tags = TagDao(db);
    folders = FolderDao(db);
    state = AppState(player: PlayerController());
    await state.init();
  });

  tearDown(() async {
    await DatabaseManager.instance.close();
    await tmp.delete(recursive: true);
  });

  Future<int> addMedia(String path, MediaType type) async {
    final item = MediaItem(
      path: path,
      mediaType: type,
      ext: p.extension(path),
      nameLower: p.basename(path).toLowerCase(),
      filename: p.basename(path),
      addedAt: DateTime.now().millisecondsSinceEpoch,
    );
    return media.insertRow(item.toMap());
  }

  Future<Map<String, dynamic>> storedSettings() async {
    final f = File(p.join(
        await DataDirService.instance.dataDir, 'settings.json'));
    if (!f.existsSync()) return {};
    return jsonDecode(await f.readAsString()) as Map<String, dynamic>;
  }

  Future<int> relationCount(String table, int tagId) async {
    final rows = await DatabaseManager.instance.db.rawQuery(
        'SELECT COUNT(*) AS c FROM $table WHERE tag_id = ?', [tagId]);
    return (rows.first['c'] as int?) ?? 0;
  }

  test('扩展名命名空间默认折叠并落盘，改过之后不再被默认值覆盖', () async {
    expect(state.isNamespaceCollapsed(TagDao.extNamespace), isTrue,
        reason: '扩展名标签默认收起来，面板才不会被几十个扩展名占满');
    expect(state.isNamespaceCollapsed(TagDao.kindNamespace), isFalse);
    final raw = (await storedSettings())['collapsed_namespaces'];
    expect(raw, isA<List<dynamic>>());
    expect((raw as List).cast<String>(), contains(TagDao.extNamespace));

    state.toggleNamespaceCollapsed(TagDao.extNamespace);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(state.isNamespaceCollapsed(TagDao.extNamespace), isFalse);

    // 重启：设置里已经有了用户的选择，默认值不能再把它折叠回去
    await SettingsService.instance.init();
    final app2 = AppState(player: PlayerController());
    await app2.init();
    expect(app2.isNamespaceCollapsed(TagDao.extNamespace), isFalse);
  });

  test('折叠全部与展开全部覆盖库里出现过的命名空间', () async {
    await state.createTag('风景', namespace: '风格');

    state.setAllNamespacesCollapsed(true);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(state.isNamespaceCollapsed(TagDao.extNamespace), isTrue);
    expect(state.isNamespaceCollapsed('风格'), isTrue);
    expect(state.collapsedNamespaces, contains('风格'));

    state.setAllNamespacesCollapsed(false);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(state.isNamespaceCollapsed(TagDao.extNamespace), isFalse);
    expect(state.isNamespaceCollapsed('风格'), isFalse);
  });

  test('删除标签解除媒体与文件夹关联，计数在删之前问得到', () async {
    final tag = await state.createTag('风景', namespace: '风格');
    final folder = await folders.create('相册');
    final a = await addMedia(p.join(tmp.path, 'a.mp3'), MediaType.audio);
    final b = await addMedia(p.join(tmp.path, 'b.mp3'), MediaType.audio);
    await state.addTagsToMedia([a, b], [tag]);
    await tags.addTagToFolder(folder.id!, tag.id!);

    final counts = await state.tagUsageCounts(tag.id!);
    expect(counts.media, 2);
    expect(counts.folders, 1);

    await state.deleteTag(tag.id!);

    expect(state.allTags.any((t) => t.id == tag.id), isFalse);
    expect(await relationCount('media_tags', tag.id!), 0,
        reason: '外键级联要把媒体关联清掉');
    expect(await relationCount('folder_tags', tag.id!), 0);
    expect(await tags.getByFullName('风格', '风景'), isNull);
  });

  test('规则标签删了下次启动还会回来，所以界面只给折叠', () async {
    final extTag = (await tags.getAll())
        .firstWhere((t) => t.namespace == TagDao.extNamespace);
    expect(AppState.isRuleTag(extTag), isTrue);
    expect(AppState.isRuleTag(await state.createTag('风景')), isFalse);

    await state.deleteTag(extTag.id!);
    expect(state.allTags.any((t) => t.id == extTag.id), isFalse);

    final app2 = AppState(player: PlayerController());
    await app2.init();
    expect(
        app2.allTags.any((t) =>
            t.namespace == TagDao.extNamespace && t.name == extTag.name),
        isTrue,
        reason: 'ensureRuleTags 会在每次启动时补回来');
  });

  test('按名字找标签：同命名空间算重名，跨命名空间能找到另一个', () async {
    final style = await state.createTag('风景', namespace: '风格');
    await state.createTag('风景', namespace: '场景');

    final same = state.findTagByName('风景', namespace: '风格');
    expect(same?.id, style.id);
    final other = state.findTagByName('风景');
    expect(other, isNotNull, reason: '没给命名空间时跨命名空间取第一个');
    expect(state.findTagByName(' 风景 '.trim(), namespace: '风格')?.id, style.id);
    expect(state.findTagByName('不存在'), isNull);
    expect(state.knownNamespaces, containsAll(<String>['风格', '场景']));
  });

  test('批量移除记录只删数据库行，磁盘文件原样留着', () async {
    final a = File(p.join(tmp.path, 'a.mp3'))..writeAsStringSync('a');
    final b = File(p.join(tmp.path, 'b.mp3'))..writeAsStringSync('b');
    final ida = await addMedia(a.path, MediaType.audio);
    final idb = await addMedia(b.path, MediaType.audio);
    final tag = await state.createTag('风景');
    await state.addTagsToMedia([ida, idb], [tag]);

    expect(await state.deleteMediaByIds([ida]), 1);

    expect(a.existsSync() && b.existsSync(), isTrue,
        reason: '删除是「从软件里移除」，磁盘文件必须原样留着');
    expect((await media.queryByDirs([tmp.path])).map((m) => m.id).toList(),
        [idb]);
    expect(await relationCount('media_tags', tag.id!), 1,
        reason: '被删那条的关联一起走，剩下那条还在');
  });

  test('批量移除记录删空之后关掉多选与锚点', () async {
    final f = File(p.join(tmp.path, 'a.mp3'))..writeAsStringSync('a');
    final id = await addMedia(f.path, MediaType.audio);
    state.enterSelectionMode(id);

    expect(await state.deleteMediaByIds([id]), 1);

    expect(state.selectionMode, isFalse);
    expect(state.selectedTrackIds, isEmpty);
    expect(f.existsSync(), isTrue);
  });
}
