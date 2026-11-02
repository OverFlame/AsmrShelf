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
import 'package:asmrshelf/db/tag_dao.dart';
import 'package:asmrshelf/db/work_dao.dart';
import 'package:asmrshelf/pages/home_page.dart';
import 'package:asmrshelf/services/data_dir_service.dart';
import 'package:asmrshelf/services/settings_service.dart';
import 'package:asmrshelf/services/thumbnail_cache.dart';
import 'package:asmrshelf/state/app_state.dart';
import 'package:asmrshelf/state/player_controller.dart';
import 'package:asmrshelf/widgets/folder_panel.dart';
import 'package:asmrshelf/widgets/image_detail.dart';
import 'package:asmrshelf/widgets/image_grid.dart';
import 'package:asmrshelf/widgets/tag_panel.dart';
import 'package:asmrshelf/widgets/works_grid.dart';
import '../support/test_env.dart';


/// 目录选择打桩：一律当作用户取消，不弹真实对话框、不碰平台通道。
/// 用例只验证「按钮点得动、点了不抛异常」，不验证真的导入。
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

/// 主界面（HomePage）的库切换与音频栏 / 多媒体栏面板用例。
///
/// 全程用 `tester.tap` 点真实按钮。sqflite ffi 在独立 isolate 上跑，
/// testWidgets 里必须用 `tester.runAsync` 包住建库与造数据（见 [settleIo]）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final pngBytes = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==');

  late Directory tmp;
  late Directory albumDir;
  late Database db;
  late PlayerController player;
  late AppState app;
  late _FakeFilePicker picker;

  late int audioWorkId;
  late Directory audioDir;
  late int audioFolderId;
  late int audioId;
  late int imageWorkId;
  late int albumFolderId;
  late List<int> imageIds;
  late int videoWorkId;
  late int videoFolderId;
  late int videoId;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    SettingsService.instance.resetForTest();
    tmp = await Directory.systemTemp.createTemp('asmrshelf_home_page');
    albumDir = await Directory(p.join(tmp.path, 'media', '相册'))
        .create(recursive: true);
    PathProviderPlatform.instance = FakePathProvider(p.join(tmp.path, 'support'));
    DataDirService.instance.resetCache();
    await DatabaseManager.instance.close();
    await DatabaseManager.instance.init();
    db = DatabaseManager.instance.db;
    await ThumbnailService.instance
        .init(cacheDir: p.join(tmp.path, 'thumbs'));
    picker = _FakeFilePicker();
    FilePickerPlatform.instance = picker;

    // 音频作品 + 一个带路径的音频卷 + 一条音频媒体行。
    // 音频行现在也落在 media 表里，多媒体栏要能把它一起平铺出来。
    audioWorkId = (await WorkDao(db).create('音频库', library: 'audio')).id!;
    audioDir = await Directory(p.join(tmp.path, 'media', '曲库'))
        .create(recursive: true);
    final song = File(p.join(audioDir.path, 'song.mp3'));
    await song.writeAsBytes(const <int>[0, 0, 0, 1]);
    final audioFolder =
        await FolderDao(db).create('曲库', workId: audioWorkId, library: 'audio');
    audioFolderId = audioFolder.id!;
    await FolderDao(db).addPath(audioFolderId, audioDir.path);
    audioId = await MediaDao(db).insertRow({
      'path': song.path,
      'media_type': 'audio',
      'filename': 'song.mp3',
      'added_at': 3000,
    });

    // 视频作品 + 一个带路径的视频虚拟文件夹 + 一个真实视频文件
    videoWorkId = (await WorkDao(db).create('视频库', library: 'media')).id!;
    final filmDir = await Directory(p.join(tmp.path, 'media', '片库'))
        .create(recursive: true);
    final clip = File(p.join(filmDir.path, 'a.mp4'));
    await clip.writeAsBytes(const <int>[0, 0, 0, 24]);
    final film = await FolderDao(db)
        .create('片库', workId: videoWorkId, library: 'media');
    videoFolderId = film.id!;
    await FolderDao(db).addPath(videoFolderId, filmDir.path);
    videoId = await MediaDao(db).insertRow({
      'path': clip.path,
      'media_type': 'video',
      'filename': 'a.mp4',
      'added_at': 2000,
    });

    // 图片作品 + 一个带路径的虚拟文件夹 + 两张真实图片
    imageWorkId = (await WorkDao(db).create('图片库', library: 'media')).id!;
    final album = await FolderDao(db)
        .create('相册', workId: imageWorkId, library: 'media');
    albumFolderId = album.id!;
    await FolderDao(db).addPath(albumFolderId, albumDir.path);

    imageIds = [];
    for (final name in ['a.png', 'b.png']) {
      final f = File(p.join(albumDir.path, name));
      await f.writeAsBytes(pngBytes);
      imageIds.add(await MediaDao(db).insertRow({
        'path': f.path,
        'media_type': 'image',
        'filename': name,
        'added_at': 1000 + imageIds.length,
      }));
    }

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

  /// 点顶部库切换条
  Future<void> switchLibrary(WidgetTester tester, String lib) async {
    await tester.tap(find.byKey(ValueKey('library-tab-$lib')));
    await tester.pump();
    await settleIo(tester);
  }

  Finder tile(int id) => find.byKey(ValueKey('image-tile-$id'));

  testWidgets('切到多媒体栏：出现文件夹面板与作品网格', (tester) async {
    // 三张作品卡片要同屏可见，窗口给宽一点
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await pumpHome(tester);

    // 初始在音频库：只列音频作品
    expect(find.byType(WorksGrid), findsOneWidget);
    expect(find.byKey(ValueKey('work-card-$audioWorkId')), findsOneWidget);
    expect(find.byType(FolderPanel), findsNothing);

    await switchLibrary(tester, kMediaLibrary);

    expect(find.byType(FolderPanel), findsOneWidget);
    expect(find.text('全部媒体'), findsOneWidget);
    expect(find.byType(WorksGrid), findsOneWidget);
    // 多媒体栏 WorksGrid._libs 是 {'audio','media'}：音频作品与多媒体作品一起列出
    expect(find.byKey(ValueKey('work-card-$imageWorkId')), findsOneWidget);
    expect(find.byKey(ValueKey('work-card-$videoWorkId')), findsOneWidget);
    expect(find.byKey(ValueKey('work-card-$audioWorkId')), findsOneWidget);
  });

  testWidgets('多媒体栏：进入图片作品后网格渲染出图片磁贴', (tester) async {
    await pumpHome(tester);
    await switchLibrary(tester, kMediaLibrary);

    await tester.tap(find.byKey(ValueKey('work-card-$imageWorkId')));
    await tester.pump();
    await settleIo(tester);

    expect(find.byType(ImageGrid), findsOneWidget);
    for (final id in imageIds) {
      expect(tile(id), findsOneWidget, reason: '作品层就该看到作品里的图片');
    }
    expect(find.byKey(ValueKey('folder-tile-$albumFolderId')), findsNothing,
        reason: '作品层直接平铺媒体，入口文件夹不再多画一层同名磁贴');
  });

  testWidgets('双击磁贴后 showViewer 为真', (tester) async {
    await pumpHome(tester);
    await switchLibrary(tester, kMediaLibrary);
    await tester.tap(find.byKey(ValueKey('work-card-$imageWorkId')));
    await tester.pump();
    await settleIo(tester);

    expect(app.showViewer, isFalse);
    final id = imageIds.first;
    await tester.tap(tile(id));
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tap(tile(id));
    await tester.pump(const Duration(milliseconds: 400));

    expect(app.showViewer, isTrue);
    expect(app.viewerImage?.id, id);

    app.closeViewer();
    await tester.pumpAndSettle();
  });

  testWidgets('多媒体栏能打开单图详情面板', (tester) async {
    // 详情面板占 320 宽，窗口要给够，否则工具栏会走紧凑模式
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await pumpHome(tester);
    await switchLibrary(tester, kMediaLibrary);
    await tester.tap(find.byKey(ValueKey('work-card-$imageWorkId')));
    await tester.pump();
    await settleIo(tester);

    expect(find.byType(ImageDetail), findsNothing);
    await tester.tap(find.byKey(const ValueKey('image-toolbar-detail')));
    await tester.pump();
    // 详情里现在有真图要解码：加载态是 indeterminate 进度圈，
    // pumpAndSettle 永远等不到静止，只能让真实 I/O 跑几轮。
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await tester.pump();
    }
    expect(find.byType(ImageDetail), findsOneWidget);
    // 修好之前这里只有「选择一张图片以查看详情」占位（AppState 解析不到
    // 作品层的选中项），现在应该落到当前列表的第一张。
    expect(find.text('选择一张图片以查看详情'), findsNothing);
    expect(find.text('文件名'), findsOneWidget);
    expect(find.text('a.png'), findsWidgets);
  });

  testWidgets('切回音频库后音频作品网格仍在', (tester) async {
    await pumpHome(tester);
    await switchLibrary(tester, kMediaLibrary);
    expect(find.byKey(ValueKey('work-card-$imageWorkId')), findsOneWidget);

    await switchLibrary(tester, kAudioLibrary);

    expect(find.byType(WorksGrid), findsOneWidget);
    expect(find.byType(FolderPanel), findsNothing);
    expect(find.byKey(ValueKey('work-card-$audioWorkId')), findsOneWidget);
    // 音频栏与多媒体栏各看各的：音频栏不再混进图片、视频作品
    expect(find.byKey(ValueKey('work-card-$imageWorkId')), findsNothing);
  });

  testWidgets('多媒体栏：作品层平铺视频，进虚拟文件夹后也能列出本层视频', (tester) async {
    await pumpHome(tester);
    await switchLibrary(tester, kMediaLibrary);

    await tester.tap(find.byKey(ValueKey('work-card-$videoWorkId')));
    await tester.pump();
    await settleIo(tester);

    expect(find.byType(ImageGrid), findsOneWidget);
    expect(find.byKey(ValueKey('video-tile-$videoId')), findsOneWidget,
        reason: '作品层直接平铺作品里的视频');
    expect(find.byKey(ValueKey('folder-tile-$videoFolderId')), findsNothing,
        reason: '入口文件夹与作品同名，不再多画一层磁贴');

    // 左栏树进虚拟文件夹：多媒体栏也要按这一层的媒体行查
    await tester.tap(find.byKey(ValueKey('folder-$videoFolderId')));
    await tester.pump();
    await settleIo(tester);

    expect(app.currentFolderId, videoFolderId);
    expect(find.byKey(ValueKey('video-tile-$videoId')), findsOneWidget,
        reason: '文件夹层要能列出本层视频，而不是走曲目查询');
  });

  testWidgets('多媒体栏：工具栏给标签筛选，卡片菜单能给视频打标签', (tester) async {
    late Tag trip;
    await tester.runAsync(() async {
      trip = await TagDao(db).insert(const Tag(name: '旅行', color: '#89b4fa'));
      // setUp 里的 init 已经读过标签，这里补一次，界面才看得到新标签
      await app.loadTags();
    });
    await pumpHome(tester);
    await switchLibrary(tester, kMediaLibrary);

    // 工具栏的标签筛选入口现在只有多媒体栏有（图片与视频合并后同一套）
    await tester.tap(find.byKey(const ValueKey('media-toolbar-tags')));
    await tester.pumpAndSettle();
    expect(find.text('全部作品'), findsNothing,
        reason: '筛选对话框只给标签区，不露音频专用的导入与作品集');
    expect(find.text('搜索标签...'), findsOneWidget, reason: '筛选对话框应已打开');
    expect(find.text('选择包含音频的文件夹'), findsNothing,
        reason: '筛选对话框不露音频专用的导入段');
    expect(find.text('还没有标签'), findsNothing);

    // 命名空间为空的标签排在列表最后，懒构建下要先搜索
    await tester.enterText(find.byType(TextField).last, '旅行');
    await tester.pumpAndSettle();
    final tagRow = find.widgetWithText(InkWell, '旅行');
    expect(tagRow, findsOneWidget, reason: '搜索后标签行应可见');
    await tester.tap(tagRow);
    await tester.pumpAndSettle();
    expect(app.tagFilter.andTagIds, contains(trip.id));
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(find.text('搜索标签...'), findsNothing, reason: '筛选对话框应已关闭');

    // 视频卡片的「标签...」走同一条 media_tags 通道
    await tester.tap(find.byKey(ValueKey('work-card-$videoWorkId')));
    await tester.pump();
    await settleIo(tester);
    // 磁贴上挂着双击手势，单击要等双击判定超时（约 300ms）后才发出
    await tester.tap(find.byKey(ValueKey('video-menu-$videoId')));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('video-tags-menu-$videoId')));
    await tester.pump();
    // 打标签入口要先读一次已有标签（真实 I/O），再弹对话框
    await settleIo(tester);
    expect(find.text('为视频选择标签'), findsOneWidget);

    await tester.tap(find.text('旅行'));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '确定'));
    await settleIo(tester);

    final tags =
        await tester.runAsync(() => TagDao(db).getTagsForTrack(videoId));
    expect(tags!.map((t) => t.name).toList(), ['旅行']);
  });

  testWidgets('多媒体栏空态出现「添加文件夹」入口，点击不抛异常', (tester) async {
    // 清空作品，模拟全新的多媒体栏
    await tester.runAsync(() async {
      for (final w in await WorkDao(db).listAll()) {
        await WorkDao(db).delete(w.id!);
      }
      await app.refresh();
    });
    await pumpHome(tester);
    await switchLibrary(tester, kMediaLibrary);

    expect(find.text('还没有作品'), findsOneWidget);
    final addButtons = find.text('添加文件夹');
    expect(addButtons, findsWidgets);

    await tester.tap(find.byKey(const ValueKey('works-empty-add-folder')));
    await tester.pump();
    await settleIo(tester);

    expect(picker.directoryCalls, 1, reason: '应该真的走到目录选择入口');
    expect(tester.takeException(), isNull);
  });

  testWidgets('多媒体栏多选：长按进多选，全选后批量移除记录', (tester) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await pumpHome(tester);
    await switchLibrary(tester, kMediaLibrary);
    await tester.tap(find.byKey(ValueKey('work-card-$imageWorkId')));
    await tester.pump();
    await settleIo(tester);

    expect(app.visualSelectionMode, isFalse);
    expect(find.byKey(const ValueKey('selection-select-all')), findsNothing,
        reason: '没有选中项时不显示选择条');

    // 长按磁贴进多选
    await tester.longPress(tile(imageIds.first));
    await tester.pump(const Duration(milliseconds: 400));
    expect(app.visualSelectionMode, isTrue);
    expect(app.selectedIds, contains(imageIds.first));

    // 多选模式下单击是勾选，不打开查看器
    await tester.tap(tile(imageIds[1]));
    await tester.pump(const Duration(milliseconds: 400));
    expect(app.showViewer, isFalse);
    expect(app.selectedIds, containsAll(imageIds));

    // 作品层 AppState 的 images 是空的（媒体行由 ImageGrid 自己查），
    // 「全选」要靠界面登记的可见项，不能把已选清空。
    expect(app.images, isEmpty);
    await tester.tap(find.byKey(const ValueKey('selection-select-all')));
    await tester.pump(const Duration(milliseconds: 200));
    expect(app.selectedIds, containsAll(imageIds));

    await tester.tap(find.byKey(const ValueKey('selection-delete')));
    await settleIo(tester);
    expect(find.textContaining('从软件里移除选中的 2 项'), findsOneWidget);
    expect(find.textContaining('磁盘上的文件不会被删除'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, '移除'));
    await settleIo(tester);

    for (final id in imageIds) {
      expect(tile(id), findsNothing, reason: '移除后网格里不该留着磁贴');
    }
    expect(app.visualSelectionMode, isFalse, reason: '删空后退出多选');
    final left = await tester
        .runAsync(() => MediaDao(db).queryByDirs([albumDir.path]));
    expect(left, isEmpty, reason: '库里只剩空结果');
    for (final name in ['a.png', 'b.png']) {
      expect(File(p.join(albumDir.path, name)).existsSync(), isTrue,
          reason: '移除记录不动磁盘文件');
    }
  });

  testWidgets('多媒体栏左栏：文件夹 / 标签两个页签可切换', (tester) async {
    await pumpHome(tester);
    await switchLibrary(tester, kMediaLibrary);

    // 默认是文件夹页签
    expect(find.byType(FolderPanel), findsOneWidget);
    expect(find.byKey(const ValueKey('media-left-tab-folders')), findsOneWidget);
    expect(find.byKey(const ValueKey('media-left-tab-tags')), findsOneWidget);

    // 切到标签页签：换成标签面板，文件夹面板让位
    await tester.tap(find.byKey(const ValueKey('media-left-tab-tags')));
    await tester.pump();
    await settleIo(tester);

    expect(find.byType(TagPanel), findsOneWidget, reason: '多媒体栏也要有标签栏');
    expect(find.byType(FolderPanel), findsNothing);
    expect(find.byKey(const ValueKey('tag-expand-all')), findsOneWidget);

    // 音频库没有文件夹页签，左栏直接就是标签面板
    await switchLibrary(tester, kAudioLibrary);
    expect(find.byType(TagPanel), findsOneWidget);
    expect(find.byKey(const ValueKey('audio-left-tab-tags')), findsNothing);

    // 切回多媒体栏：按库记住上次选的标签页签
    await switchLibrary(tester, kMediaLibrary);
    expect(find.byType(TagPanel), findsOneWidget,
        reason: '回到多媒体栏时保持上次选的标签页签');
  });

  testWidgets('视觉库排序菜单：选反序后网格顺序真的跟着变', (tester) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await pumpHome(tester);
    await switchLibrary(tester, kMediaLibrary);
    await tester.tap(find.byKey(ValueKey('work-card-$imageWorkId')));
    await tester.pump();
    await settleIo(tester);

    double xOf(int id) => tester.getTopLeft(tile(id)).dx;
    expect(
      xOf(imageIds[0]),
      lessThan(xOf(imageIds[1])),
      reason: '默认自然序 a.png 在前',
    );

    // 工具栏的排序入口：四个字段 + 反序
    await tester.tap(find.byKey(const ValueKey('media-toolbar-sort')));
    await tester.pumpAndSettle();
    expect(find.text('文件名'), findsOneWidget);
    expect(find.text('修改时间'), findsOneWidget);
    expect(find.text('文件大小'), findsOneWidget);
    expect(find.text('加入时间'), findsOneWidget);

    await tester.tap(find.text('改为降序'));
    await tester.pumpAndSettle();
    await settleIo(tester);

    expect(app.visualSortDescending, isTrue);
    expect(SettingsService.instance.imageSortDescending, isTrue, reason: '要落盘');
    expect(
      xOf(imageIds[0]),
      greaterThan(xOf(imageIds[1])),
      reason: '反序后 b.png 在前',
    );
  });

  testWidgets('视觉库工具栏：窄窗口下不会 RenderFlex 溢出', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await pumpHome(tester);
    await switchLibrary(tester, kMediaLibrary);

    // 500 是工具栏收进「更多」菜单的阈值，排序按钮加进来后阈值附近最容易溢出
    for (final width in [420.0, 440.0, 500.0, 560.0, 820.0]) {
      tester.view.physicalSize = Size(width, 1000);
      await tester.pump();
      await settleIo(tester);
      expect(tester.takeException(), isNull, reason: '$width 宽下工具栏不该溢出');
    }
  });

  testWidgets('视觉库工具栏：窄窗口 + 打开详情面板也不溢出（回归：800 宽溢出 30 像素）', (tester) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await pumpHome(tester);
    await switchLibrary(tester, kMediaLibrary);
    await tester.tap(find.byKey(ValueKey('work-card-$imageWorkId')));
    await tester.pump();
    await settleIo(tester);

    // 缩到 800：宽版布局（左栏 260），工具栏还有 539 宽，此时不是紧凑态
    tester.view.physicalSize = const Size(800, 1200);
    await tester.pump();
    await settleIo(tester);
    expect(tester.takeException(), isNull, reason: '800 宽时代码路也不该溢出');
    expect(
      find.byKey(const ValueKey('image-toolbar-detail')),
      findsOneWidget,
      reason: '非紧凑态下详情按钮在工具栏上',
    );

    // 从这里打开详情面板：面板占走 320，中间列只剩 218 宽（评审复现的溢出场景）
    await tester.tap(find.byKey(const ValueKey('image-toolbar-detail')));
    await tester.pump();
    // 详情里有真图要解码，加载圈的 indeterminate 动画等不到静止
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await tester.pump();
    }
    expect(find.byType(ImageDetail), findsOneWidget);
    expect(
      find.byKey(const ValueKey('media-toolbar-more')),
      findsOneWidget,
      reason: '218 宽下工具栏要走紧凑样式',
    );
    expect(tester.takeException(), isNull, reason: '详情面板占走 320 宽后，工具栏不该再溢出');
  });

  testWidgets('极窄工具栏：连排序也收进「更多」菜单（详情面板占剩的 218 宽）', (tester) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await pumpHome(tester);
    await switchLibrary(tester, kMediaLibrary);
    await tester.tap(find.byKey(ValueKey('work-card-$imageWorkId')));
    await tester.pump();
    await settleIo(tester);

    tester.view.physicalSize = const Size(800, 1200);
    await tester.pump();
    await settleIo(tester);
    await tester.tap(find.byKey(const ValueKey('image-toolbar-detail')));
    await tester.pump();
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await tester.pump();
    }
    expect(find.byType(ImageDetail), findsOneWidget);

    // 218 宽连排序按钮都放不下，让它进菜单，而不是把工具栏挤爆
    expect(find.byKey(const ValueKey('media-toolbar-sort')), findsNothing);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byKey(const ValueKey('media-toolbar-more')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('排序'), findsOneWidget, reason: '菜单里要有排序分组');
    // 详情面板的文件信息里也有「修改时间」，要点菜单里那一项
    await tester.tap(
      find.ancestor(
        of: find.text('修改时间'),
        matching: find.byType(CheckedPopupMenuItem<String>),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    // 详情面板里的图还在解码，加载圈是 indeterminate，不能用 settleIo
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump();
    }

    expect(app.visualSortKey, 'mtime', reason: '从「更多」里选的排序要真的生效');
    expect(find.byKey(const ValueKey('media-toolbar-sort')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('手机宽度下的多选栏改成图标按钮，不再溢出', (tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await pumpHome(tester);
    await switchLibrary(tester, kMediaLibrary);
    await tester.tap(find.byKey(ValueKey('work-card-$imageWorkId')));
    await tester.pump();
    await settleIo(tester);

    // 手机宽度：磁贴只有 80 多像素见方，长按要避开右上角的 ⋮ 菜单
    tester.view.physicalSize = const Size(380, 900);
    await tester.pump();
    await settleIo(tester);
    final rect = tester.getRect(tile(imageIds.first));
    await tester.longPressAt(rect.centerLeft + const Offset(20, 0));
    await tester.pump(const Duration(milliseconds: 400));
    expect(app.visualSelectionMode, isTrue);

    // 380 宽下五个动作收成图标按钮（老版固定宽度文字按钮必溢出）
    for (final key in [
      'selection-select-all',
      'selection-add-tags',
      'selection-remove-tags',
      'selection-delete',
      'selection-clear',
    ]) {
      expect(find.byKey(ValueKey(key)), findsOneWidget, reason: '$key 要在选择条上');
    }
    expect(
      find.widgetWithText(TextButton, '全选'),
      findsNothing,
      reason: '窄屏下不再用带文字按钮',
    );
    expect(tester.takeException(), isNull, reason: '380 宽下选择条不该溢出');

    // 更要命的 260 宽（宽版布局 + 详情面板曾把它压到 218）：图标再缩一号、
    // 动作区可横向滚动，一样不许溢出
    tester.view.physicalSize = const Size(260, 900);
    await tester.pump();
    await settleIo(tester);
    expect(find.byKey(const ValueKey('selection-clear')), findsOneWidget);
    expect(tester.takeException(), isNull, reason: '260 宽下选择条不该溢出');

    // 宽窗口下仍是带文字按钮，不牺牲可读性
    tester.view.physicalSize = const Size(1600, 1200);
    await tester.pump();
    await settleIo(tester);
    expect(find.widgetWithText(TextButton, '清除选择'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('作品层一键回「作品」：面包屑上的作品按钮', (tester) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await pumpHome(tester);
    await switchLibrary(tester, kMediaLibrary);
    expect(find.byType(WorksGrid), findsOneWidget);

    await tester.tap(find.byKey(ValueKey('work-card-$imageWorkId')));
    await tester.pump();
    await settleIo(tester);
    expect(find.byType(ImageGrid), findsOneWidget);
    expect(app.currentWork, isNotNull);

    // 以前刚进作品时面包屑整条不显示，进了作品就只能绕文件夹树回去
    await tester.tap(find.byKey(const ValueKey('breadcrumb-works')));
    await tester.pump();
    await settleIo(tester);

    expect(app.currentWork, isNull);
    expect(find.byType(WorksGrid), findsOneWidget);
    expect(find.byKey(ValueKey('work-card-$imageWorkId')), findsOneWidget);
  });

  testWidgets('作品卡片菜单能添加/移除标签（作用于整个作品）', (tester) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await pumpHome(tester);
    await switchLibrary(tester, kMediaLibrary);

    final card = find.byKey(ValueKey('work-card-$imageWorkId'));
    await tester.tap(
      find.descendant(of: card, matching: find.byTooltip('作品操作')),
    );
    await tester.pumpAndSettle();

    expect(find.text('添加标签...'), findsOneWidget);
    expect(find.text('移除标签...'), findsOneWidget);
  });

  testWidgets('多媒体栏：音频作品与多媒体作品一起列出，点进音频作品也能平铺它的媒体行',
      (tester) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await pumpHome(tester);
    await switchLibrary(tester, kMediaLibrary);

    // 多媒体栏 WorksGrid._libs = {'audio','media'}：两类作品都要出现
    expect(find.byKey(ValueKey('work-card-$audioWorkId')), findsOneWidget);
    expect(find.byKey(ValueKey('work-card-$imageWorkId')), findsOneWidget);
    expect(find.byKey(ValueKey('work-card-$videoWorkId')), findsOneWidget);

    await tester.tap(find.byKey(ValueKey('work-card-$audioWorkId')));
    await tester.pump();
    await settleIo(tester);

    expect(find.byType(ImageGrid), findsOneWidget,
        reason: '多媒体栏即使进了音频作品，中心区也还是图片墙');
    expect(find.byKey(ValueKey('audio-tile-$audioId')), findsOneWidget,
        reason: '作品层平铺要包含音频行（AudioTile），不能只查图片/视频');
  });

  testWidgets('多媒体栏工具条：作品层能「添加文件夹」，进入目录后有「播放本目录的音频」',
      (tester) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await pumpHome(tester);
    await switchLibrary(tester, kMediaLibrary);

    await tester.tap(find.byKey(ValueKey('work-card-$imageWorkId')));
    await tester.pump();
    await settleIo(tester);

    // 作品层：能往本作品加文件夹；还没进任何目录，所以没有「播放本目录的音频」
    expect(find.byKey(const ValueKey('media-toolbar-add-folder')), findsOneWidget);
    expect(find.byKey(const ValueKey('media-toolbar-play-all')), findsNothing);

    // 从文件夹树进「曲库」（音频作品的根文件夹）
    await tester.tap(find.byKey(ValueKey('folder-$audioFolderId')));
    await tester.pump();
    await settleIo(tester);

    expect(app.currentFolderPath, audioDir.path);
    expect(find.byKey(const ValueKey('media-toolbar-play-all')), findsOneWidget,
        reason: '进了某个目录才出现「播放本目录的音频」');

    // 换到没有音频行的「相册」，这时点播放是安全的（空队列直接返回）
    await tester.tap(find.byKey(ValueKey('folder-$albumFolderId')));
    await tester.pump();
    await settleIo(tester);

    expect(app.currentFolderPath, albumDir.path);
    expect(find.byKey(const ValueKey('media-toolbar-play-all')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('media-toolbar-play-all')));
    await tester.pump();
    await settleIo(tester);

    expect(tester.takeException(), isNull,
        reason: '相册里没有音频行，播放动作应该什么都不做而不是抛异常');
  });

  testWidgets('作品层跟随视图切换，窄屏 10 列不溢出', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await pumpHome(tester);
    await switchLibrary(tester, kMediaLibrary);

    expect(
      find.descendant(
        of: find.byType(WorksGrid),
        matching: find.byType(GridView),
      ),
      findsOneWidget,
      reason: '默认是网格视图',
    );

    await tester.tap(find.byKey(const ValueKey('media-toolbar-viewmode')));
    await settleIo(tester);
    expect(app.viewMode, 'list');

    expect(
      find.descendant(
        of: find.byType(WorksGrid),
        matching: find.byType(ListView),
      ),
      findsOneWidget,
      reason: '作品层要消费 viewMode，不能只让作品内部切',
    );
    expect(
      find.descendant(
        of: find.byType(WorksGrid),
        matching: find.byType(GridView),
      ),
      findsNothing,
    );

    await tester.tap(find.byKey(const ValueKey('media-toolbar-viewmode')));
    await settleIo(tester);
    await tester.runAsync(() => app.setGridColumns(10));
    await settleIo(tester);

    expect(app.gridColumns, 10);
    expect(tester.takeException(), isNull,
        reason: '窄屏也严格按用户列数排，卡片不能溢出');
  });

  testWidgets('音频作品层使用多媒体工具栏，排序菜单只给作品字段', (tester) async {
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
    expect(app.worksSortDescending, isTrue, reason: '换字段不偷偷改方向，仍保持加入时间那套降序');
    expect(dx(zId), lessThan(dx(aId)), reason: '名称降序：Z卷 在前');

    await tester.tap(find.byKey(const ValueKey('audio-toolbar-sort')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(PopupMenuItem<String>, '改为升序'));
    await settleIo(tester);
    expect(app.worksSortDescending, isFalse);
    expect(dx(aId), lessThan(dx(zId)), reason: '名称升序把 A卷 排到 Z卷 前');
  });
}
