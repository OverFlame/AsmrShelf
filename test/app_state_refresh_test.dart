import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:asmrshelf/db/database.dart';
import 'package:asmrshelf/db/track_dao.dart';
import 'package:asmrshelf/services/data_dir_service.dart';
import 'package:asmrshelf/state/app_state.dart';
import 'package:asmrshelf/state/player_controller.dart';
import 'support/test_env.dart';


void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('audioshelf_refresh');
    PathProviderPlatform.instance =
        FakePathProvider(p.join(tmp.path, 'support'));
    DataDirService.instance.resetCache();
    await DatabaseManager.instance.close();
    await DatabaseManager.instance.init();

    final dao = TrackDao(DatabaseManager.instance.db);
    for (var i = 0; i < 5; i++) {
      await dao.insert(TrackItem(
          path: '/m/alpha_$i.mp3', filename: 'alpha_$i.mp3', addedAt: i));
    }
    for (var i = 0; i < 3; i++) {
      await dao.insert(TrackItem(
          path: '/m/beta_$i.mp3', filename: 'beta_$i.mp3', addedAt: i));
    }
  });

  tearDown(() async {
    await DatabaseManager.instance.close();
    await tmp.delete(recursive: true);
  });

  Future<void> settle([int ms = 800]) =>
      Future<void>.delayed(Duration(milliseconds: ms));

  test('连续换关键词：只有最后一代产生结果与重建', () async {
    final appState = AppState(player: PlayerController());
    var notifications = 0;
    appState.addListener(() => notifications++);

    // 先确认单次搜索能列出正确结果
    appState.setSearchQuery('alpha');
    await settle(500);
    expect(appState.loading, isFalse);
    expect(appState.tracks.length, 5, reason: 'alpha 应有 5 条');

    final baseline = notifications;

    // 连续换 20 次关键词，最后一次是 beta（i=19 为奇数）。
    // 旧实现里每代都会写 _tracks 并 notifyListeners，代数是 O(N) 次重建。
    for (var i = 0; i < 20; i++) {
      appState.setSearchQuery(i.isEven ? 'alpha' : 'beta');
    }
    await settle();

    final rebuilt = notifications - baseline;
    final names = appState.tracks.map((t) => t.filename).toList();

    expect(appState.loading, isFalse, reason: 'loading 应由最新一代关闭');
    expect(
      rebuilt,
      lessThan(12),
      reason: '20 次并发刷新只应产生常数级重建，实际 $rebuilt 次',
    );
    expect(appState.tracks.length, 3, reason: 'beta 应有 3 条，实际 $names');
    expect(
      names.every((n) => n.contains('beta')),
      isTrue,
      reason: '最后一次查询是 beta，不能显示旧代际的 $names',
    );
  });
}
