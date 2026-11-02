import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import 'package:asmrshelf/db/database.dart';
import 'package:asmrshelf/db/folder_dao.dart';
import 'package:asmrshelf/db/track_dao.dart';
import 'package:asmrshelf/db/work_dao.dart';
import 'package:asmrshelf/services/data_dir_service.dart';
import 'package:asmrshelf/state/app_state.dart';
import 'package:asmrshelf/state/player_controller.dart';
import 'package:asmrshelf/widgets/folder_browser.dart';
import '../support/test_env.dart';

/// 音频磁贴右侧的「已播时间 / 总时长」。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late Database db;
  late PlayerController player;
  late AppState app;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tmp = await Directory.systemTemp.createTemp('asmrshelf_tile_time');
    PathProviderPlatform.instance =
        FakePathProvider(p.join(tmp.path, 'support'));
    DataDirService.instance.resetCache();
    await DatabaseManager.instance.close();
    await DatabaseManager.instance.init();
    db = DatabaseManager.instance.db;
    player = PlayerController();
  });

  tearDown(() async {
    await DatabaseManager.instance.close();
    await tmp.delete(recursive: true);
  });

  Future<void> seedTracks() async {
    final workId = (await WorkDao(db).create('作品A')).id!;
    final folderId = (await FolderDao(db).create('专辑', workId: workId)).id!;
    await FolderDao(db).addPath(folderId, tmp.path);
    await TrackDao(db).insert(TrackItem(
      path: p.join(tmp.path, '听过一半.mp3'),
      filename: '听过一半.mp3',
      addedAt: 1,
      durationMs: 200000,
      playPositionMs: 83000,
    ));
    await TrackDao(db).insert(TrackItem(
      path: p.join(tmp.path, '没播过.mp3'),
      filename: '没播过.mp3',
      addedAt: 2,
      durationMs: 65000,
    ));
    app = AppState(player: player);
    await app.init();
    await app.enterFolder(folderId);
  }

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<PlayerController>.value(value: player),
          ChangeNotifierProvider<AppState>.value(value: app),
        ],
        child: const MaterialApp(home: Scaffold(body: FolderBrowser())),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('磁贴右侧同时给出已播时间与总时长', (tester) async {
    await tester.runAsync(seedTracks);
    await pump(tester);

    expect(find.text('1:23 / 3:20'), findsOneWidget,
        reason: '播过的曲目要显示听到哪里了');
    expect(find.text('0:00 / 1:05'), findsOneWidget,
        reason: '没播过的曲目也要给出总时长');
  });

  testWidgets('播放位置前进后磁贴上的已播时间当场刷新', (tester) async {
    await tester.runAsync(seedTracks);
    await pump(tester);
    expect(find.text('1:23 / 3:20'), findsOneWidget);

    // 真实引擎才有的 250 毫秒位置回报，这里直接喂给控制器
    await tester.runAsync(() async {
      final track =
          app.tracks.firstWhere((t) => t.filename == '听过一半.mp3');
      player.onPositionChanged!(track, const Duration(seconds: 100));
      await Future<void>.delayed(const Duration(milliseconds: 80));
    });
    await tester.pumpAndSettle();

    expect(find.text('1:40 / 3:20'), findsOneWidget);
    expect(find.text('1:23 / 3:20'), findsNothing);
  });
}
