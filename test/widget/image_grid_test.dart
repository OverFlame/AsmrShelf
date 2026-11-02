import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import 'package:asmrshelf/services/data_dir_service.dart';
import 'package:asmrshelf/services/thumbnail_cache.dart';
import 'package:asmrshelf/services/video_cover_service.dart';
import 'package:asmrshelf/state/app_state.dart';
import 'package:asmrshelf/state/player_controller.dart';
import 'package:asmrshelf/theme/app_theme.dart';
import 'package:asmrshelf/widgets/image_grid.dart';
import '../support/test_env.dart';


/// 1×1 的合法 PNG，给缩略图生成器一张能真解码的原图。
final _pngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

/// 测试用的 `PlatformFile`：界面只用 `path`，所以只实现这几个成员。
///
/// `xFile` 的返回类型写成 `Never`（它是所有类型的子类型，覆写合法），这样就
/// 不用为了一个假件把间接依赖 cross_file 引进测试。
final class _FakePlatformFile extends PlatformFile {
  _FakePlatformFile(this._path);

  final String _path;

  @override
  String get name => p.basename(_path);

  @override
  Uri get uri => Uri.file(_path);

  @override
  Never get xFile => throw UnimplementedError('测试里只用 path');

  @override
  Future<int> length() => File(_path).length();

  @override
  int lengthSync() => File(_path).lengthSync();

  @override
  Future<Uint8List> readAsBytes() => File(_path).readAsBytes();

  @override
  Stream<Uint8List> readAsByteStream() =>
      File(_path).openRead().map(Uint8List.fromList);
}

/// 假的文件选择器：记下调用参数，按构造时的 [result] 返回一个文件或取消。
///
/// 真实实现走平台通道，在 flutter test 里会缺插件；换成替身才能验证「菜单 →
/// 选图 → 写库 → 磁贴换封面」整条链。
class _FakeFilePicker extends FilePickerPlatform {
  _FakeFilePicker({this.result});

  final String? result;
  int calls = 0;
  String? lastDialogTitle;
  FileType? lastType;

  @override
  Future<PlatformFile?> pickFile({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    calls++;
    lastDialogTitle = dialogTitle;
    lastType = type;
    final picked = result;
    return picked == null ? null : _FakePlatformFile(picked);
  }
}

/// 不初始化原生引擎的播放器。
///
/// flutter test 里没有 `libflutter_soloud_plugin.so`，`init()` 会抛
/// `ArgumentError: Failed to load dynamic library`。覆写掉 init 之后
/// `playQueue` 照常写队列与下标，再走「未初始化」分支同步状态（见
/// player_controller.dart 里 `_loadAndPlay` 的注释），所以能对着
/// `currentTrack` / `queueLength` 断言真实入队的曲目。
class _NoEnginePlayer extends PlayerController {
  @override
  Future<void> init() async {}
}

/// 图片网格的界面交互测试。
///
/// 全部走真实手势。落库与缩略图生成走 sqflite/文件系统的真实 I/O，在 widget
/// 测试的假时钟里不会自己完成，所以写完库后用 [settleIo] 交替让出事件循环。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late Directory albumDir;
  late Database db;
  late PlayerController player;
  late AppState app;
  late int albumId;

  /// 相册里三张图：1、2 没有别名，3 有别名「封面丙」。
  late List<int> imageIds;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tmp = await Directory.systemTemp.createTemp('asmrshelf_image_grid');
    albumDir = await Directory(p.join(tmp.path, 'media', '相册')).create(recursive: true);
    PathProviderPlatform.instance =
        FakePathProvider(p.join(tmp.path, 'support'));
    DataDirService.instance.resetCache();
    await DatabaseManager.instance.close();
    await DatabaseManager.instance.init();
    db = DatabaseManager.instance.db;
    // thumbPath() 在 init() 之前会抛 LateInitializationError
    await ThumbnailService.instance
        .init(cacheDir: p.join(tmp.path, 'thumbs'));

    // 图片栏与视频栏合并成多媒体栏之后，库归属只剩 audio 与 media
    final work = await WorkDao(db).create('图片库', library: 'media');
    final album = await FolderDao(db)
        .create('相册', workId: work.id, library: 'media');
    albumId = album.id!;
    await FolderDao(db).addPath(albumId, albumDir.path);

    imageIds = [];
    final names = ['a.png', 'b.png', 'c.png'];
    for (var i = 0; i < names.length; i++) {
      final file = File(p.join(albumDir.path, names[i]));
      await file.writeAsBytes(_pngBytes);
      final id = await MediaDao(db).insertRow({
        'path': file.path,
        'media_type': 'image',
        'filename': names[i],
        'added_at': 1000 + i,
        'alias': i == 2 ? '封面丙' : null,
      });
      imageIds.add(id);
    }

    player = PlayerController();
    // 视频封面走三级取图，最后一级会起 ffmpeg 探测进程并挂一个 20 秒超时
    // （见 VideoCoverService._fromFirstFrame），在假时钟的 widget 测试里会变成
    // 「A Timer is still pending」。这里注入一个各级都取不到的桩：`os: 'windows'`
    // 让首帧那一级直接短路，正好也覆盖「没有封面就画 Icons.movie」的分支。
    app = AppState(
      player: player,
      videoCovers: VideoCoverService(
        os: 'windows',
        systemCover: (_) async => null,
        embeddedCover: (_) async => null,
      ),
    );
    await app.init();
  });

  tearDown(() async {
    await DatabaseManager.instance.close();
    await tmp.delete(recursive: true);
  });

  Future<void> pumpGrid(WidgetTester tester) {
    return tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<PlayerController>.value(value: player),
          ChangeNotifierProvider<AppState>.value(value: app),
        ],
        child: const MaterialApp(home: Scaffold(body: ImageGrid())),
      ),
    );
  }

  /// runAsync 让真实 I/O 跑完，pump 让假时钟里的回调接着走。一次不够。
  Future<void> settleIo(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump();
    }
    await tester.pumpAndSettle();
  }

  /// 进入相册（走真实 AppState 导航，属真实 I/O）
  Future<void> enterAlbum(WidgetTester tester) async {
    await tester.runAsync(() => app.enterFolder(albumId));
  }

  Finder tile(int id) => find.byKey(ValueKey('image-tile-$id'));
  Finder videoTile(int id) => find.byKey(ValueKey('video-tile-$id'));
  Finder audioTile(int id) => find.byKey(ValueKey('audio-tile-$id'));

  /// 在相册目录里插一条媒体行（音频/视频），返回行 id。
  ///
  /// 真 I/O：在用例里必须包进 [WidgetTester.runAsync]（setUp 不在假时钟里，可以
  /// 直接 await）。
  Future<int> insertMedia({
    required String name,
    required String type,
    int addedAt = 2000,
    String? title,
    String? artist,
    String? album,
    int? durationMs,
  }) async {
    final file = File(p.join(albumDir.path, name));
    await file.writeAsBytes(_pngBytes);
    return MediaDao(db).insertRow({
      'path': file.path,
      'media_type': type,
      'filename': name,
      'added_at': addedAt,
      'title': title,
      'artist': artist,
      'album': album,
      'duration_ms': durationMs,
    });
  }

  /// 双击一个磁贴（磁贴同时挂了 onTap/onDoubleTap，第二次点完要 pump 过双击判定）
  Future<void> doubleTap(WidgetTester tester, Finder target) async {
    await tester.tap(target);
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tap(target);
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// 点开磁贴上的 ⋮ 菜单。
  ///
  /// 磁贴整体挂着双击手势，同一次点按要等双击判定超时（约 300ms）才落到按钮上，
  /// 所以必须显式推进时钟（没有待画帧时 pumpAndSettle 不会自己走时间）。
  Future<void> openTileMenu(WidgetTester tester, Finder button) async {
    await tester.tap(button);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
  }

  testWidgets('网格按 app.images 渲染磁贴，标题别名优先', (tester) async {
    await enterAlbum(tester);
    await pumpGrid(tester);
    await settleIo(tester);

    expect(app.images.length, 3);
    for (final id in imageIds) {
      expect(tile(id), findsOneWidget);
    }
    // 无别名 → 显示文件名
    expect(find.text('a.png'), findsOneWidget);
    expect(find.text('b.png'), findsOneWidget);
    // 有别名 → 只显示别名，不再显示文件名
    expect(find.text('封面丙'), findsOneWidget);
    expect(find.text('c.png'), findsNothing);
  });

  testWidgets('单击单选，Ctrl 加选，Shift 区间选', (tester) async {
    await enterAlbum(tester);
    await pumpGrid(tester);
    await settleIo(tester);

    // 磁贴同时挂了 onTap/onDoubleTap，单击要等双击判定超时才会派发
    Future<void> click(int id) async {
      await tester.tap(tile(id));
      await tester.pump(const Duration(milliseconds: 350));
    }

    // 单击第一张 → 单选
    await click(imageIds[0]);
    expect(app.selectedId, imageIds[0]);
    expect(app.selectedIds, {imageIds[0]});

    // Ctrl+单击第二张 → 加选
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await click(imageIds[1]);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    expect(app.selectedIds, {imageIds[0], imageIds[1]});

    // Shift+单击第三张 → 从锚点(第二张)到第三张的区间
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await click(imageIds[2]);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    expect(app.selectedIds, {imageIds[0], imageIds[1], imageIds[2]});
  });

  testWidgets('双击磁贴调用 openViewer 并把起始索引设为该图', (tester) async {
    await enterAlbum(tester);
    await pumpGrid(tester);
    await settleIo(tester);

    expect(app.showViewer, isFalse);

    await tester.tap(tile(imageIds[1]));
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tap(tile(imageIds[1]));
    // 第二次按下会起一个双击判定定时器，pump 过去免得测试结束时报 pending timer
    await tester.pump(const Duration(milliseconds: 400));

    expect(app.showViewer, isTrue);
    expect(app.viewerIndex, 1);
    expect(app.viewerImages.length, 3);
  });

  testWidgets('空列表显示空态文案，不抛异常', (tester) async {
    // 不进入任何文件夹：中间栏既没有文件夹也没有图片
    await pumpGrid(tester);
    await settleIo(tester);

    expect(tester.takeException(), isNull);
    expect(find.text('这里还没有内容'), findsOneWidget);
    expect(find.text('点下面的按钮添加文件夹（图片、视频或音频）'), findsOneWidget);
  });

  Future<void> pumpGridWithTheme(WidgetTester tester, ThemeData theme) {
    return tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<PlayerController>.value(value: player),
          ChangeNotifierProvider<AppState>.value(value: app),
        ],
        child: MaterialApp(
          theme: theme,
          home: const Scaffold(body: ImageGrid()),
        ),
      ),
    );
  }

  testWidgets('卡片底色跟着主题走：浅色下不再用深色 surface', (tester) async {
    await enterAlbum(tester);
    await pumpGridWithTheme(tester, AppColors.lightThemeData);
    await settleIo(tester);

    Color cardColor(int id) => ((tester.widget<Container>(find
                .descendant(of: tile(id), matching: find.byType(Container))
                .first))
            .decoration as BoxDecoration)
        .color!;

    expect(cardColor(imageIds[0]), AppColors.surfaceLight,
        reason: '浅色主题下卡片不能还是硬编码的深色 surface');

    await pumpGridWithTheme(tester, AppColors.darkThemeData);
    await settleIo(tester);
    expect(cardColor(imageIds[0]), AppColors.surface,
        reason: '深色主题保持原样');
  });

  testWidgets('同一目录里的图片/视频/音频在同一网格里各画各的磁贴', (tester) async {
    final videoId = (await tester.runAsync(
        () => insertMedia(name: 'v.mp4', type: 'video', addedAt: 2000)))!;
    final audioId = (await tester.runAsync(() => insertMedia(
          name: 's.mp3',
          type: 'audio',
          addedAt: 2001,
          title: '曲目一',
          artist: '艺人',
          durationMs: 65000,
        )))!;

    await enterAlbum(tester);
    await pumpGrid(tester);
    await settleIo(tester);

    expect(app.images.length, 5);
    for (final id in imageIds) {
      expect(tile(id), findsOneWidget);
    }
    expect(videoTile(videoId), findsOneWidget);
    expect(audioTile(audioId), findsOneWidget);
    // 视频三级取图都空手而归时退回电影图标（夹具注入了取不到封面的桩）
    expect(
        find.descendant(
            of: videoTile(videoId), matching: find.byIcon(Icons.movie)),
        findsOneWidget);

    // 音频磁贴：标题优先用 title，时长按 m:ss 画
    expect(
        find.descendant(of: audioTile(audioId), matching: find.text('曲目一')),
        findsOneWidget);
    expect(find.descendant(of: audioTile(audioId), matching: find.text('1:05')),
        findsOneWidget);
    // 没有封面时退回音乐图标占位（图行才画 Image）
    expect(
        find.descendant(of: audioTile(audioId), matching: find.byType(Image)),
        findsNothing);
  });

  testWidgets('双击音频磁贴把本目录音频排成专辑队列，并从这条开始播', (tester) async {
    final names = ['a1.mp3', 'a2.mp3'];
    final ids = <int>[];
    for (var i = 0; i < names.length; i++) {
      ids.add((await tester.runAsync(() => insertMedia(
            name: names[i],
            type: 'audio',
            addedAt: 2000 + i,
            title: '第${i + 1}首',
          )))!);
    }

    // 真实播放器一 init 就去找原生库，换成不初始化引擎的替身
    final noEngine = _NoEnginePlayer();
    player = noEngine;
    app = AppState(player: noEngine);
    await tester.runAsync(() => app.init());

    await enterAlbum(tester);
    await pumpGrid(tester);
    await settleIo(tester);

    expect(noEngine.queueLength, 0);

    await doubleTap(tester, audioTile(ids[1]));
    await settleIo(tester);

    expect(noEngine.queueLength, 2, reason: '本目录的两条音频都进队列');
    expect(noEngine.queue.map((t) => t.path).toList(),
        [p.join(albumDir.path, 'a1.mp3'), p.join(albumDir.path, 'a2.mp3')]);
    expect(noEngine.currentTrack?.path, p.join(albumDir.path, 'a2.mp3'),
        reason: '双击哪一首就从哪一首开始（startMediaId）');
    expect(noEngine.index, 1);
  });

  testWidgets('双击图片时查看器只收图片，索引按图片子集重算', (tester) async {
    final videoId = (await tester.runAsync(
        () => insertMedia(name: 'v.mp4', type: 'video', addedAt: 2000)))!;
    final audioId = (await tester.runAsync(() => insertMedia(
          name: 's.mp3',
          type: 'audio',
          addedAt: 2001,
          durationMs: 30000,
        )))!;

    await enterAlbum(tester);
    await pumpGrid(tester);
    await settleIo(tester);
    expect(app.images.length, 5);

    await doubleTap(tester, tile(imageIds[2]));

    expect(app.showViewer, isTrue);
    expect(app.viewerImages.length, 3, reason: '视频/音频不能塞进漫画查看器');
    expect(app.viewerImages.every((m) => m.mediaType == MediaType.image), isTrue);
    expect(app.viewerImages.map((m) => m.id), isNot(contains(videoId)));
    expect(app.viewerImages.map((m) => m.id), isNot(contains(audioId)));
    expect(app.viewerImages[app.viewerIndex].id, imageIds[2]);
  });

  testWidgets('音频菜单能设置与清除缩略图，磁贴跟着换', (tester) async {
    final audioId = (await tester.runAsync(() => insertMedia(
          name: 's.mp3',
          type: 'audio',
          addedAt: 2000,
          title: '曲目一',
        )))!;
    final cover = File(p.join(tmp.path, 'cover.png'));
    await tester.runAsync(() => cover.writeAsBytes(_pngBytes));

    final original = FilePickerPlatform.instance;
    final picker = _FakeFilePicker(result: cover.path);
    FilePickerPlatform.instance = picker;
    addTearDown(() => FilePickerPlatform.instance = original);

    await enterAlbum(tester);
    await pumpGrid(tester);
    await settleIo(tester);

    Finder coverImage() =>
        find.descendant(of: audioTile(audioId), matching: find.byType(Image));
    MediaItem audioRow() =>
        app.images.firstWhere((m) => m.id == audioId);

    expect(coverImage(), findsNothing);

    await openTileMenu(tester, find.byKey(ValueKey('audio-menu-$audioId')));
    await tester.tap(find.byKey(ValueKey('audio-tile-set-cover-$audioId')));
    await settleIo(tester);

    expect(picker.calls, 1);
    expect(picker.lastType, FileType.image);
    expect(picker.lastDialogTitle, '选择缩略图');
    expect(app.coverForMedia(audioRow()), cover.path);
    expect(coverImage(), findsOneWidget, reason: '设完封面磁贴要立刻换图');

    await openTileMenu(tester, find.byKey(ValueKey('audio-menu-$audioId')));
    await tester.tap(find.byKey(ValueKey('audio-tile-clear-cover-$audioId')));
    await settleIo(tester);

    expect(app.coverForMedia(audioRow()), isNull);
    expect(coverImage(), findsNothing);
  });
}
