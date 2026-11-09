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
import 'package:asmrshelf/db/work_metadata_dao.dart';
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
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
  );

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
    PathProviderPlatform.instance = FakePathProvider(
      p.join(tmp.path, 'support'),
    );
    DataDirService.instance.resetCache();
    await DatabaseManager.instance.close();
    await DatabaseManager.instance.init();
    db = DatabaseManager.instance.db;
    await ThumbnailService.instance.init(cacheDir: p.join(tmp.path, 'thumbs'));
    picker = _FakeFilePicker();
    FilePickerPlatform.instance = picker;

    // 音频作品 + 一个带路径的卷 + 一条音频媒体行。
    audioWorkId = (await WorkDao(db).create('音频库', library: 'audio')).id!;
    audioDir = await Directory(
      p.join(tmp.path, 'media', '曲库'),
    ).create(recursive: true);
    final song = File(p.join(audioDir.path, 'song.mp3'));
    await song.writeAsBytes(const <int>[0, 0, 0, 1]);
    final audioFolder = await FolderDao(
      db,
    ).create('曲库', workId: audioWorkId, library: 'audio');
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
    final albumDir = await Directory(
      p.join(tmp.path, 'media', '相册'),
    ).create(recursive: true);
    final album = await FolderDao(
      db,
    ).create('相册', workId: mediaWorkId, library: 'media');
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
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
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
    expect(
      find.byKey(ValueKey('work-card-$mediaWorkId')),
      findsNothing,
      reason: '音频栏不混进多媒体作品',
    );
    expect(find.byType(FolderBrowser), findsNothing);
  });

  testWidgets('主页自动滚到上一次打开的作品', (tester) async {
    wideScreen(tester);
    await tester.runAsync(() async {
      for (var i = 0; i < 20; i++) {
        await WorkDao(db).create('作品$i', library: 'audio');
      }
      await app.refresh();
      await SettingsService.instance.setLastOpenedWorkId(audioWorkId);
      await app.loadSettings();
    });
    await pumpHome(tester);
    await tester.pumpAndSettle();

    final scrollable = tester.state<ScrollableState>(
      find
          .descendant(
            of: find.byType(WorksGrid),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(scrollable.position.pixels, greaterThan(0),
        reason: '上次打开的作品在列表末尾，主页应自动滚过去');
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

  testWidgets('同系列的两部作品合成书套，点进去是系列页，作品返回系列', (tester) async {
    late int a;
    late int b;
    await tester.runAsync(() async {
      a = (await WorkDao(db).create('雨之一')).id!;
      b = (await WorkDao(db).create('雨之二')).id!;
      final metadata = WorkMetadataDao(db);
      for (final id in [a, b]) {
        await metadata.upsert(
          WorkMetadata(
            workId: id,
            rjCode: 'RJ0000000$id',
            rawJson: jsonEncode([
              {
                'series_id': 'SRI1',
                'series_name': '雨の日',
                'maker_name': '社团',
                'title_work_count': 3,
              },
            ]),
          ),
        );
      }
      await app.dlsite.loadSeriesIndex();
      await app.refresh();
    });
    wideScreen(tester);
    await pumpHome(tester);

    final seriesCard = find.byKey(const ValueKey('series-card-id:SRI1'));
    expect(seriesCard, findsOneWidget);
    expect(
      find.byKey(ValueKey('work-card-$a')),
      findsNothing,
      reason: '系列成员收进书套，不再平铺',
    );
    expect(find.textContaining('雨の日'), findsWidgets, reason: '侧栏也有系列入口');

    await tester.tap(seriesCard);
    await settleIo(tester);
    expect(app.currentSeries?.name, '雨の日');
    expect(find.byKey(const ValueKey('series-title')), findsOneWidget);
    expect(find.byKey(const ValueKey('series-count')), findsOneWidget);
    expect(find.byKey(ValueKey('work-card-$a')), findsOneWidget);
    expect(find.byKey(ValueKey('work-card-$b')), findsOneWidget);

    await tester.tap(find.byKey(ValueKey('work-card-$a')));
    await settleIo(tester);
    expect(app.currentWork?.id, a);
    expect(app.currentSeries?.name, '雨の日', reason: '进作品后仍记得来自哪套系列');
    expect(find.byType(FolderBrowser), findsOneWidget);

    await tester.tap(find.byTooltip('返回上一级'));
    await settleIo(tester);
    expect(app.currentWork, isNull);
    expect(app.currentSeries?.name, '雨の日');
    expect(find.byKey(const ValueKey('series-title')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('series-back')));
    await settleIo(tester);
    await tester.longPress(find.byKey(const ValueKey('series-card-id:SRI1')));
    await settleIo(tester);
    expect(app.workSelectionMode, isTrue);
    expect(app.selectedWorkIds, {a, b}, reason: '书套多选等于整组作品');

    await tester.tap(find.byKey(const ValueKey('series-card-id:SRI1')));
    await settleIo(tester);
    expect(app.selectedWorkIds, isEmpty, reason: '再点一次取消整组');
  });

  testWidgets('多选作品可以创建、重命名和解散手动系列', (tester) async {
    late int a;
    late int b;
    await tester.runAsync(() async {
      a = (await WorkDao(db).create('手动一', library: 'audio')).id!;
      b = (await WorkDao(db).create('手动二', library: 'audio')).id!;
      await app.refresh();
    });
    wideScreen(tester);
    await pumpHome(tester);

    await tester.longPress(find.byKey(ValueKey('work-card-$a')));
    await settleIo(tester);
    await tester.tap(find.byKey(ValueKey('work-card-$b')));
    await settleIo(tester);
    expect(app.selectedWorkIds, {a, b});

    await tester.tap(find.byKey(const ValueKey('work-batch-series')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('series-name-input')), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('series-name-input')),
      '我的手动系列',
    );
    await tester.tap(find.byKey(const ValueKey('series-name-confirm')));
    await settleIo(tester);

    expect(app.currentSeries?.manual, isTrue);
    expect(app.currentSeries?.name, '我的手动系列');
    expect(app.currentSeries?.workIds, [a, b]);

    await tester.tap(find.byKey(const ValueKey('series-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重命名系列'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('series-name-input')),
      '改名后的系列',
    );
    await tester.tap(find.byKey(const ValueKey('series-name-confirm')));
    await settleIo(tester);
    expect(app.currentSeries?.name, '改名后的系列');

    await tester.tap(find.byKey(const ValueKey('series-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('解散系列'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确定'));
    await settleIo(tester);
    expect(app.currentSeries, isNull);
    expect(app.seriesGroups, isEmpty);
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

  testWidgets('宽屏左栏默认 260，分隔条可以拖宽并落盘', (tester) async {
    wideScreen(tester);
    await pumpHome(tester);

    expect(app.leftWidth, 260);
    expect(find.byKey(const ValueKey('split-left-panel')), findsOneWidget);
    expect(tester.getSize(find.byType(TagPanel)).width, closeTo(260, 0.5));

    await tester.drag(
      find.byKey(const ValueKey('split-left-panel')),
      const Offset(80, 0),
    );
    await settleIo(tester);

    expect(app.leftWidth, greaterThan(260), reason: '拖动结束后才把宽度写进设置');
    expect(app.leftWidth, lessThanOrEqualTo(420));
    expect(
      tester.getSize(find.byType(TagPanel)).width,
      closeTo(app.leftWidth, 0.5),
    );
  });

  testWidgets('左栏拖不过上限 420，双击恢复默认', (tester) async {
    wideScreen(tester);
    await pumpHome(tester);

    await tester.drag(
      find.byKey(const ValueKey('split-left-panel')),
      const Offset(2000, 0),
    );
    await settleIo(tester);
    expect(app.leftWidth, 420, reason: '上限是 420，不是窗口宽');

    await tester.tap(find.byKey(const ValueKey('split-left-panel')));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.byKey(const ValueKey('split-left-panel')));
    await settleIo(tester);
    expect(app.leftWidth, 260);
  });

  testWidgets('窗口变窄时左栏只收缩显示，不回写设置', (tester) async {
    wideScreen(tester);
    await tester.runAsync(() => app.setLeftWidth(420));
    await pumpHome(tester);
    expect(tester.getSize(find.byType(TagPanel)).width, closeTo(420, 0.5));

    tester.view.physicalSize = const Size(800, 1200);
    await tester.pump();
    await settleIo(tester);

    expect(app.leftWidth, 420, reason: '窗口缩放不改用户设置');
    expect(
      tester.getSize(find.byType(TagPanel)).width,
      lessThan(420),
      reason: '中间至少留 420 像素',
    );
  });

  testWidgets('窄屏没有分隔条', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await pumpHome(tester);

    expect(find.byKey(const ValueKey('split-left-panel')), findsNothing);
    expect(find.byKey(const ValueKey('split-library-tags')), findsNothing);
  });

  testWidgets('作品集高度默认 200，可拖高且不超过上限', (tester) async {
    wideScreen(tester);
    await pumpHome(tester);
    expect(app.libraryHeight, 200);

    await tester.drag(
      find.byKey(const ValueKey('split-library-tags')),
      const Offset(0, 60),
    );
    await settleIo(tester);
    expect(app.libraryHeight, greaterThan(200));

    await tester.drag(
      find.byKey(const ValueKey('split-library-tags')),
      const Offset(0, 2000),
    );
    await settleIo(tester);
    expect(app.libraryHeight, lessThanOrEqualTo(480));
    expect(tester.takeException(), isNull, reason: '标签区不能被作品集挤没');
  });

  testWidgets('面包屑最上级是全部作品，点它回到作品网格', (tester) async {
    wideScreen(tester);
    await pumpHome(tester);
    await tester.tap(find.byKey(ValueKey('work-card-$audioWorkId')));
    await settleIo(tester);

    expect(app.currentWork?.id, audioWorkId);
    final rootCrumb = find.descendant(
      of: find.byType(FolderBrowser),
      matching: find.text('全部作品'),
    );
    expect(rootCrumb, findsOneWidget);
    expect(app.breadcrumb.first.id, -2, reason: '面包屑最上级是全部作品');

    await tester.tap(rootCrumb);
    await settleIo(tester);

    expect(app.currentWork, isNull);
    expect(find.byType(WorksGrid), findsOneWidget);
  });

  testWidgets('作品层返回键回到全部作品，不原地刷新', (tester) async {
    wideScreen(tester);
    await pumpHome(tester);
    await tester.runAsync(() => app.enterWork(audioWorkId));
    await settleIo(tester);
    expect(app.currentWork, isNotNull);

    await tester.runAsync(() => app.goUp());
    await settleIo(tester);

    expect(app.currentWork, isNull);
    expect(find.byType(WorksGrid), findsOneWidget);
  });

  testWidgets('工具条进入作品多选，点卡片是选中而不是进作品', (tester) async {
    wideScreen(tester);
    await pumpHome(tester);

    await tester.tap(find.byKey(const ValueKey('audio-toolbar-select')));
    await tester.pump();
    expect(app.workSelectionMode, isTrue);
    expect(find.byKey(const ValueKey('work-select-exit')), findsOneWidget);

    await tester.tap(find.byKey(ValueKey('work-card-$audioWorkId')));
    await tester.pump();
    expect(app.selectedWorkIds, contains(audioWorkId));
    expect(app.currentWork, isNull, reason: '多选时点卡片不进入作品');
    expect(find.byIcon(Icons.check_circle), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('work-select-exit')));
    await tester.pump();
    expect(app.workSelectionMode, isFalse);
    expect(app.selectedWorkIds, isEmpty);
  });

  testWidgets('窗口很矮时布局不溢出，标签区仍在', (tester) async {
    tester.view.physicalSize = const Size(1000, 360);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await pumpHome(tester);

    expect(
      find.byKey(const ValueKey('split-library-tags')),
      findsNothing,
      reason: '放不下就折叠作品集，先保住标签区',
    );
    expect(find.text('标签'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
