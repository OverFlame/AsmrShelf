import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:asmrshelf/db/database.dart';
import 'package:asmrshelf/db/media_dao.dart';
import 'package:asmrshelf/db/tag_dao.dart';
import 'package:asmrshelf/services/data_dir_service.dart';
import 'package:asmrshelf/services/settings_service.dart';
import 'package:asmrshelf/state/app_state.dart';
import 'package:asmrshelf/state/player_controller.dart';
import '../support/test_env.dart';


/// 「字幕标签默认排除并持久化」的验收（BUILD_GUIDE 第 18.5、11 节阶段 6）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('asmrshelf_not_tags');
    PathProviderPlatform.instance =
        FakePathProvider(p.join(tmp.path, 'support'));
    DataDirService.instance.resetCache();
    SettingsService.instance.resetForTest();
    await DatabaseManager.instance.close();
    await DatabaseManager.instance.init();
    await SettingsService.instance.init();
  });

  tearDown(() async {
    await DatabaseManager.instance.close();
    await tmp.delete(recursive: true);
  });

  /// 读 settings.json 里落盘的排除集。
  Future<List<int>?> storedExcluded() async {
    final f = File(p.join(
        await DataDirService.instance.dataDir, 'settings.json'));
    if (!f.existsSync()) return null;
    final map = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
    final raw = map['excluded_tag_ids'];
    if (raw is! List) return null;
    return raw.whereType<int>().toList();
  }

  Future<int> subtitleKindTagId() async {
    final tags = await TagDao(DatabaseManager.instance.db).getAll();
    return tags
        .firstWhere((t) =>
            t.namespace == TagDao.kindNamespace &&
            t.name == MediaType.subtitle.value)
        .id!;
  }

  test('首次启动把「字幕」放进排除集并落盘', () async {
    final app = AppState(player: PlayerController());
    await app.init();

    final id = await subtitleKindTagId();
    expect(app.activeTagIds, contains(id), reason: '默认排除字幕');
    expect(await storedExcluded(), [id]);
  });

  test('用户取消排除后重启保持取消', () async {
    final app = AppState(player: PlayerController());
    await app.init();
    final id = await subtitleKindTagId();

    app.toggleNotFilter(id);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(app.activeTagIds, isNot(contains(id)));
    expect(await storedExcluded(), isEmpty);

    // 重启：重新读设置，默认值不再套用
    final ss = SettingsService.instance;
    await ss.init();
    final app2 = AppState(player: PlayerController());
    await app2.init();
    expect(app2.activeTagIds, isNot(contains(id)),
        reason: '用户删掉的排除项不能被默认值加回来');
  });

  test('用户排除别的标签后重启保持', () async {
    final app = AppState(player: PlayerController());
    await app.init();

    final tagDao = TagDao(DatabaseManager.instance.db);
    final tag = await tagDao.insert(const Tag(name: '风景'));
    app.toggleNotFilter(tag.id!);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final ss = SettingsService.instance;
    await ss.init();
    final app2 = AppState(player: PlayerController());
    await app2.init();
    expect(app2.activeTagIds, contains(tag.id));
  });
}
