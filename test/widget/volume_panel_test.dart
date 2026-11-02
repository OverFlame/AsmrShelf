import 'dart:convert';
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
import 'package:asmrshelf/db/media_dao.dart';
import 'package:asmrshelf/db/work_dao.dart';
import 'package:asmrshelf/services/data_dir_service.dart';
import 'package:asmrshelf/services/settings_service.dart';
import 'package:asmrshelf/state/app_state.dart';
import 'package:asmrshelf/state/player_controller.dart';
import 'package:asmrshelf/widgets/volume_panel.dart';
import '../support/test_env.dart';


/// 1×1 的合法 PNG，只为让 `Image.file` 有东西可解。
const String _pngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/'
    'q842iQAAAABJRU5ErkJggg==';

/// 卷面板的真实点击验收（BUILD_GUIDE 第 19.2、19.4、22.6、22.7 节）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late Database db;
  late MediaDao mediaDao;
  late PlayerController player;
  late AppState app;
  late int imageWorkId;
  late List<int> imageIds;
  late VirtualFolder volWithPaths;
  late VirtualFolder volEmpty;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tmp = await Directory.systemTemp.createTemp('asmrshelf_volume_panel');
    PathProviderPlatform.instance =
        FakePathProvider(p.join(tmp.path, 'support'));
    DataDirService.instance.resetCache();
    SettingsService.instance.resetForTest();
    await DatabaseManager.instance.close();
    await DatabaseManager.instance.init();
    db = DatabaseManager.instance.db;
    mediaDao = MediaDao(db);
    player = PlayerController();
    app = AppState(player: player);

    final dir = p.join(tmp.path, 'vol');
    await Directory(dir).create(recursive: true);
    final bytes = base64Decode(_pngBase64);
    for (final name in const ['01.png', '02.png', '03.png', 'cover.png']) {
      await File(p.join(dir, name)).writeAsBytes(bytes);
    }

    imageWorkId = (await WorkDao(db).create('图库', library: 'media')).id!;
    imageIds = <int>[];
    for (final name in const ['01.png', '02.png', '03.png']) {
      imageIds.add(await mediaDao.insertRow({
        'path': p.join(dir, name),
        'filename': name,
        'media_type': 'image',
        'ext': '.png',
        'name_lower': name.toLowerCase(),
        'added_at': 0,
      }));
    }

    // 建卷要落库，必须在 setUp 里做：测试体跑在假时钟里，真实 I/O 不会完成。
    final folderDao = FolderDao(db);
    volWithPaths = await folderDao.create('卷A',
        workId: imageWorkId, library: 'media');
    await folderDao.addPath(volWithPaths.id!, dir);
    volEmpty = await folderDao.create('空卷',
        workId: imageWorkId, library: 'media');
  });

  tearDown(() async {
    await DatabaseManager.instance.close();
    await tmp.delete(recursive: true);
  });

  /// 卷都在 setUp 里建好（测试体里的真实 I/O 走不完）。
  VirtualFolder volumeWithPaths() => volWithPaths;

  void bigView(WidgetTester tester) {
    tester.view.physicalSize = const Size(1400, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  /// 等真实 I/O 落地的同时推进动画：底面板从屏幕下方滑入，
  /// 不带时长的 `pump()` 不会推进动画，面板会停在屏幕外点不到。
  Future<void> settleIo(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pump(const Duration(milliseconds: 50));
  }

  Future<void> openPanel(WidgetTester tester, VirtualFolder folder) async {
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<PlayerController>.value(value: player),
        ChangeNotifierProvider<AppState>.value(value: app),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => Center(
              child: FilledButton(
                onPressed: () => VolumePanel.show(
                  ctx,
                  folder: folder,
                  readSize: (path) async => const Size(1, 1),
                ),
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('打开'));
    await tester.pump();
    await settleIo(tester);
  }

  testWidgets('打开后列出卷内图片、封面与阅读记录', (tester) async {
    bigView(tester);
    final folder = volumeWithPaths();
    await openPanel(tester, folder);

    expect(find.byKey(const ValueKey('volume-panel')), findsOneWidget);
    expect(find.text('卷A'), findsOneWidget);
    expect(find.text('卷封面'), findsOneWidget);
    expect(find.text('卷内图片 3 张'), findsOneWidget);
    expect(find.byKey(const ValueKey('volume-image-grid')), findsOneWidget);
    for (final id in imageIds) {
      expect(find.byKey(ValueKey('volume-image-$id')), findsOneWidget);
    }
    expect(find.text('没有阅读记录'), findsOneWidget);
    expect(find.text('还没有封面'), findsNothing, reason: 'vol 里有 cover.png');
    expect(find.byTooltip('关闭'), findsOneWidget,
        reason: '纯图标按钮要带 tooltip，不然读屏和悬停都看不出是干什么的');
  });

  testWidgets('空卷提示没有图片，点阅读不打开查看器', (tester) async {
    bigView(tester);
    final folder = volEmpty;
    await openPanel(tester, folder);

    expect(find.text('这个卷里没有图片'), findsOneWidget);
    expect(find.byKey(const ValueKey('volume-image-grid')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('volume-read')));
    await tester.pump();
    await settleIo(tester);

    expect(find.text('这个卷里没有可阅读的图片'), findsOneWidget);
    expect(app.showViewer, isFalse);
    expect(find.byKey(const ValueKey('volume-panel')), findsOneWidget,
        reason: '没打开查看器就不关面板');
  });

  testWidgets('点阅读进入阅读模式并从上次位置开始', (tester) async {
    bigView(tester);
    final folder = volumeWithPaths();
    await tester.runAsync(() => app.recordReading(folder.id!, pageIndex: 1));
    await tester.runAsync(() => app.flushReadingProgress());
    await openPanel(tester, folder);

    await tester.tap(find.byKey(const ValueKey('volume-read')));
    await tester.pump();
    await settleIo(tester);

    expect(app.showViewer, isTrue);
    expect(app.readingVolumeId, folder.id);
    expect(app.viewerImages.length, 3);
    expect(app.viewerIndex, 1, reason: '接着上次第 2 页');
    expect(find.byKey(const ValueKey('volume-panel')), findsNothing,
        reason: '进入阅读后面板关闭');
  });

  testWidgets('阅读记录显示在封面下方', (tester) async {
    bigView(tester);
    final folder = volumeWithPaths();
    await tester.runAsync(() => app.recordReading(folder.id!, pageIndex: 2));
    await tester.runAsync(() => app.flushReadingProgress());

    await openPanel(tester, folder);

    expect(find.text('看到第 3 页'), findsOneWidget);
  });

  testWidgets('标记已读完后按钮禁用并显示徽标', (tester) async {
    bigView(tester);
    final folder = volumeWithPaths();
    // 标记读完要有阅读会话，先按阅读模式打开一次。
    await tester.runAsync(() => app.openVolumeReader(folder.id!));
    await openPanel(tester, folder);

    final before = tester.widget<TextButton>(
        find.byKey(const ValueKey('volume-mark-finished')));
    expect(before.onPressed, isNotNull);

    await tester.tap(find.byKey(const ValueKey('volume-mark-finished')));
    await tester.pump();
    await settleIo(tester);

    expect(find.text('已标记读完'), findsOneWidget);
    expect(find.text('已读完'), findsOneWidget);
    final after = tester.widget<TextButton>(
        find.byKey(const ValueKey('volume-mark-finished')));
    expect(after.onPressed, isNull);

    final progress =
        await tester.runAsync(() => app.readingProgressOf(folder.id!));
    expect(progress!.finished, isTrue);
  });

  testWidgets('点卷内图片打开查看器并关面板', (tester) async {
    bigView(tester);
    final folder = volumeWithPaths();
    await openPanel(tester, folder);

    await tester.tap(find.byKey(ValueKey('volume-image-${imageIds[1]}')));
    await tester.pump();
    await settleIo(tester);

    expect(app.showViewer, isTrue);
    expect(app.viewerIndex, 1);
    expect(app.viewerImages[1].id, imageIds[1]);
    expect(find.byKey(const ValueKey('volume-panel')), findsNothing);
  });
}
