import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import 'package:asmrshelf/db/database.dart';
import 'package:asmrshelf/db/folder_dao.dart';
import 'package:asmrshelf/db/media_dao.dart';
import 'package:asmrshelf/db/work_dao.dart';
import 'package:asmrshelf/pages/home_page.dart';
import 'package:asmrshelf/services/data_dir_service.dart';
import 'package:asmrshelf/services/settings_service.dart';
import 'package:asmrshelf/services/thumbnail_cache.dart';
import 'package:asmrshelf/state/app_state.dart';
import 'package:asmrshelf/state/player_controller.dart';
import 'package:asmrshelf/widgets/folder_browser.dart';
import 'package:asmrshelf/widgets/tag_panel.dart';
import 'package:asmrshelf/widgets/works_grid.dart';
import '../support/test_env.dart';

/// 目录选择打桩：一律当作用户取消，不弹真实对话框、不碰平台通道。
class _FakeFilePicker extends FilePickerPlatform {
  int directoryCalls = 0;

  @override
  Future<String?> getDirectoryPath({
    String? dialogTitle,
    String? initialDirectory,
    AndroidOptions androidOptions = const AndroidOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    directoryCalls++;
    return null;
  }
}

/// 主界面（HomePage）的音频栏用例。
///
/// 全程用 `tester.tap` 点真实按钮。sqflite ffi 在独立 isolate 上跑，
/// testWidgets 里必须用 `tester.runAsync` 包住建库与造数据（见 [settleIo]）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final pngBytes = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==');

  late Directory tmp;
  late Database db;
  late PlayerController player;
  late AppState app;
  late _FakeFilePicker picker;

  late int audioWorkId;
  late Directory audioDir;
  late int audioFolderId;
  late int mediaWorkId;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    SettingsService.instance.resetForTest();
    tmp = await Directory.systemTemp.createTemp('asmrshelf_home_page');
    PathProviderPlatform.instance = FakePathProvider(p.join(tmp.path, 'support'));
    DataDirService.instance.resetCache();
    await DatabaseManager.instance.close();
    await DatabaseManager.instance.init();
    db = DatabaseManager.instance.db;
    await ThumbnailService.instance.init(cacheDir: p.join(tmp.path, 'thumbs'));
    picker = _FakeFilePicker();
    FilePickerPlatform.instance = picker;

    // 音频作品 + 一个带路径的卷 + 一条音频媒体行。
    audioWorkId = (await WorkDao(db).create('音频库', library: 'audio')).id!;
    audioDir =
        await Directory(p.join(tmp.path, 'media', '曲库')).create(recursive: true);
    final song = File(p.join(audioDir.path, 'song.mp3'));
    await song.writeAsBytes(const <int>[0, 0, 0, 1]);
    final audioFolder =
        await FolderDao(db).create('曲库', workId: audioWorkId, library: 'audio');
    audioFolderId = audioFolder.id!;
    await FolderDao(db).addPath(audioFolderId, audioDir.path);
    await MediaDao(db).insertRow({
      'path': song.path,
      'media_type': 'audio',
      'filename': 'song.mp3',
      'added_at': 3000,
    });

    // 多媒体作品：音频栏不该列出它。
    mediaWorkId = (await WorkDao(db).create('图片库', library: 'media')).id!;
    final albumDir =
        await Directory(p.join(tmp.path, 'media', '相册')).create(recursive: true);
    final album =
        await FolderDao(db).create('相册', workId: mediaWorkId, library: 'media');
    await FolderDao(db).addPath(album.id!, albumDir.path);
    final pic = File(p.join(albumDir.path, 'a.png'));
    await pic.writeAsBytes(pngBytes);
    await MediaDao(db).insertRow({
      'path': pic.path,
      'media_type': 'image',
      'filename': 'a.png',
      'added_at': 1000,
    });

    player = PlayerController();
    app = AppState(player: player);
    await app.init();
  });

  tearDown(() async {
    await DatabaseManager.instance.close();
    await tmp.delete(recursive: true);
  });

  /// 界面回调里的真实 I/O 要交替让出事件循环：runAsync 让真实 I/O 跑完，
  /// pump 让假时钟里的回调接着往下走。
  Future<void> settleIo(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump();
    }
    await tester.pumpAndSettle();
  }

  Future<void> pumpHome(WidgetTester tester) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<PlayerController>.value(value: player),
          ChangeNotifierProvider<AppState>.value(value: app),
        ],
        child: const MaterialApp(home: HomePage()),
      ),
    );
    await settleIo(tester);
  }

  void wideScreen(WidgetTester tester) {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  testWidgets('首页只列音频作品，左侧是标签面板', (tester) async {
    wideScreen(tester);
    await pumpHome(tester);

    expect(find.byType(WorksGrid), findsOneWidget);
    expect(find.byType(TagPanel), findsOneWidget);
    expect(find.byKey(ValueKey('work-card-$audioWorkId')), findsOneWidget);
    expect(find.byKey(ValueKey('work-card-$mediaWorkId')), findsNothing,
        reason: '音频栏不混进多媒体作品');
    expect(find.byType(FolderBrowser), findsNothing);
  });

  testWidgets('点作品卡片进入作品，文件夹浏览接管中心区', (tester) async {
    wideScreen(tester);
    await pumpHome(tester);

    await tester.tap(find.byKey(ValueKey('work-card-$audioWorkId')));
    await tester.pump();
    await settleIo(tester);

    expect(app.currentWork?.id, audioWorkId);
    expect(find.byType(FolderBrowser), findsOneWidget);
    expect(app.currentFolderPath, isNull, reason: '进作品先落在卷层');

    // 卷层点「曲库」才下钻到真实目录
    await tester.tap(find.text('曲库').first);
    await settleIo(tester);
    expect(app.currentFolderPath, audioDir.path);
  });

  testWidgets('作品卡片菜单能添加/移除标签（作用于整个作品）', (tester) async {
    wideScreen(tester);
    await pumpHome(tester);

    final card = find.byKey(ValueKey('work-card-$audioWorkId'));
    await tester.tap(
      find.descendant(of: card, matching: find.byTooltip('作品操作')),
    );
    await tester.pumpAndSettle();

    expect(find.text('添加标签...'), findsOneWidget);
    expect(find.text('移除标签...'), findsOneWidget);
  });

  testWidgets('窄屏 10 列不溢出，视图模式跟随工具栏切换', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await pumpHome(tester);

    await tester.tap(find.byKey(const ValueKey('audio-toolbar-viewmode')));
    await settleIo(tester);
    expect(app.viewMode, 'list');

    expect(
      find.descendant(
        of: find.byType(WorksGrid),
        matching: find.byType(ListView),
      ),
      findsOneWidget,
      reason: '作品层要消费 viewMode',
    );

    await tester.tap(find.byKey(const ValueKey('audio-toolbar-viewmode')));
    await settleIo(tester);
    await tester.runAsync(() => app.setGridColumns(10));
    await settleIo(tester);

    expect(app.gridColumns, 10);
    expect(tester.takeException(), isNull, reason: '窄屏也严格按用户列数排，卡片不能溢出');
  });

  testWidgets('音频作品层工具条：排序菜单只给作品字段', (tester) async {
    late int aId;
    late int zId;
    await tester.runAsync(() async {
      aId = (await WorkDao(db).create('A卷', library: 'audio')).id!;
      zId = (await WorkDao(db).create('Z卷', library: 'audio')).id!;
      await app.refresh();
    });
    await pumpHome(tester);

    expect(find.byKey(const ValueKey('audio-toolbar-columns')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('audio-toolbar-viewmode')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('audio-toolbar-sort')), findsOneWidget);

    double dx(int id) =>
        tester.getTopLeft(find.byKey(ValueKey('work-card-$id'))).dx;

    // 默认加入时间倒序：后建的 Z卷 在前
    expect(dx(zId), lessThan(dx(aId)));

    await tester.tap(find.byKey(const ValueKey('audio-toolbar-sort')));
    await tester.pumpAndSettle();
    expect(find.text('文件名'), findsOneWidget);
    expect(find.text('加入时间'), findsOneWidget);
    expect(find.text('修改时间'), findsNothing, reason: '作品没有文件修改时间，菜单不该给这个选项');
    expect(find.text('文件大小'), findsNothing);

    await tester.tap(find.widgetWithText(CheckedPopupMenuItem<String>, '文件名'));
    await settleIo(tester);
    expect(app.worksSortKey, 'name');
    expect(app.worksSortDescending, isTrue, reason: '换字段不偷偷改方向');
    expect(dx(zId), lessThan(dx(aId)), reason: '名称降序：Z卷 在前');

    await tester.tap(find.byKey(const ValueKey('audio-toolbar-sort')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(PopupMenuItem<String>, '改为升序'));
    await settleIo(tester);
    expect(app.worksSortDescending, isFalse);
    expect(dx(aId), lessThan(dx(zId)), reason: '名称升序把 A卷 排到 Z卷 前');
  });
}
