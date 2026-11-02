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
import 'package:asmrshelf/db/work_dao.dart';
import 'package:asmrshelf/services/data_dir_service.dart';
import 'package:asmrshelf/services/video_launcher.dart';
import 'package:asmrshelf/state/app_state.dart';
import 'package:asmrshelf/state/player_controller.dart';
import 'package:asmrshelf/widgets/folder_browser.dart';
import 'package:asmrshelf/widgets/works_grid.dart';
import '../support/test_env.dart';


/// 只为了占住 Process 的位置。exitCode 必须给 0：
/// VideoLauncher 现在会看退出码，非 0 或抛异常都算「外链播放失败」。
class _FakeProcess implements Process {
  @override
  Future<int> get exitCode => Future<int>.value(0);

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

/// 外链播放的界面用例（BUILD_GUIDE 第 24.2 节）。
///
/// 从菜单点到生成 m3u8 再点到系统命令，全程走真实点击。播放器换成交付命令的
/// 假实现，只为看住命令与参数，不真的拉起外部程序。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late Directory media;
  late Database db;
  late List<List<String>> calls;
  late PlayerController player;
  late AppState app;

  VideoLauncher fakeLauncher() => VideoLauncher(
        os: 'linux',
        start: (String exe, List<String> args) async {
          calls.add([exe, ...args]);
          return _FakeProcess();
        },
      );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tmp = await Directory.systemTemp.createTemp('audioshelf_ext_play');
    media = await Directory(p.join(tmp.path, 'media')).create(recursive: true);
    PathProviderPlatform.instance =
        FakePathProvider(p.join(tmp.path, 'support'));
    DataDirService.instance.resetCache();
    await DatabaseManager.instance.close();
    await DatabaseManager.instance.init();
    db = DatabaseManager.instance.db;
    calls = [];
    player = PlayerController();
  });

  tearDown(() async {
    await DatabaseManager.instance.close();
    await tmp.delete(recursive: true);
  });

  Future<void> pump(WidgetTester tester, Widget child) {
    return tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<PlayerController>.value(value: player),
          ChangeNotifierProvider<AppState>.value(value: app),
        ],
        child: MaterialApp(home: Scaffold(body: child)),
      ),
    );
  }

  /// 界面回调里的真实 I/O 要交替让出事件循环：runAsync 让真实 I/O 跑完，
  /// pump 让假时钟里的回调接着往下走。一次不够，链路上有好几跳。
  Future<void> settleIo(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump();
    }
    await tester.pumpAndSettle();
  }

  Future<void> drainSnackBar(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
  }

  /// 造一个音频作品，里面放 [video] 时塞一首歌，返回卷的名字。
  ///
  /// 这个文件测的是音频栏（FolderBrowser / WorksGrid 的音频页）那条外链通路，
  /// 所以作品与卷都归 'audio' 库，外链播放按库归属挑音频行。
  Future<String> seedFolder(String name, {required bool video}) async {
    final workId = (await WorkDao(db).create('作品A')).id!;
    final dir = await Directory(p.join(media.path, name)).create();
    final folder = await FolderDao(db).create(name, workId: workId);
    await FolderDao(db).addPath(folder.id!, dir.path);
    if (video) {
      await db.insert('media', {
        'path': p.join(dir.path, '01.mp3'),
        'media_type': 'audio',
        'filename': '01.mp3',
        'added_at': 1,
        'duration_ms': 1454999,
      });
    }
    app = AppState(player: player, videoLauncher: fakeLauncher());
    await app.init();
    await app.enterWork(workId);
    return name;
  }

  testWidgets('文件夹菜单：点「用外部播放器播放」写出 m3u8 并交给系统', (tester) async {
    await tester.runAsync(() => seedFolder('剧集', video: true));

    await pump(tester, const FolderBrowser());
    await tester.pumpAndSettle();
    expect(find.text('剧集'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.more_vert).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('用外部播放器播放'));
    await tester.pump();
    await settleIo(tester);

    expect(calls.length, 1, reason: '应把播放列表交给系统一次');
    expect(calls.single.first, 'xdg-open');
    final listPath = calls.single[1];
    expect(listPath, endsWith('剧集.m3u8'));

    final written = await tester.runAsync(() => File(listPath).readAsString());
    expect(written, startsWith('#EXTM3U\n'));
    expect(written, contains('#EXTINF:1455,01.mp3'));
    expect(written, contains('01.mp3'));

    expect(find.text('已交给系统默认播放器'), findsOneWidget);
    await drainSnackBar(tester);
  });

  testWidgets('文件夹菜单：卷里没有媒体时提示失败', (tester) async {
    await tester.runAsync(() => seedFolder('空卷', video: false));

    await pump(tester, const FolderBrowser());
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.more_vert).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('用外部播放器播放'));
    await tester.pump();
    await settleIo(tester);

    expect(calls, isEmpty, reason: '没有媒体就不该拉播放器');
    expect(find.text('外链播放失败，详情见 logs 目录'), findsOneWidget);
    await drainSnackBar(tester);
  });

  testWidgets('作品卡片菜单：同样能点外链播放', (tester) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.runAsync(() => seedFolder('剧集', video: true));

    await pump(tester, const WorksGrid());
    await tester.pumpAndSettle();
    expect(find.text('作品A'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.more_vert).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('用外部播放器播放'));
    await tester.pump();
    await settleIo(tester);

    expect(calls.length, 1);
    expect(calls.single.first, 'xdg-open');
    expect(calls.single[1], endsWith('作品A.m3u8'));

    final written = await tester.runAsync(
        () => File(calls.single[1]).readAsString());
    expect(written, contains('01.mp3'));
    await drainSnackBar(tester);
  });
}
