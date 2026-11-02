import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asmrshelf/db/database.dart';
import 'package:asmrshelf/db/media_dao.dart';
import 'package:asmrshelf/services/data_dir_service.dart';
import 'package:asmrshelf/state/app_state.dart';
import 'package:asmrshelf/state/player_controller.dart';
import 'package:asmrshelf/widgets/image_viewer.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import '../support/test_env.dart';

/// 1×1 的合法 PNG。文件必须真的存在，否则查看器的 `_checkFileExists`
/// 会把画面换成「文件不存在」占位卡，树里就没有 `Image` 可断言了。
const List<int> _png1x1 = <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, //
  0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41, 0x54,
  0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00, 0x05,
  0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, //
  0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44,
  0xAE, 0x42, 0x60, 0x82,
];


void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late Directory imageDir;
  late Database db;
  late PlayerController player;
  late AppState app;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tmp = await Directory.systemTemp.createTemp('asmrshelf_viewer');
    imageDir = await Directory(
      p.join(tmp.path, 'images'),
    ).create(recursive: true);
    PathProviderPlatform.instance = FakePathProvider(
      p.join(tmp.path, 'support'),
    );
    DataDirService.instance.resetCache();
    await DatabaseManager.instance.close();
    await DatabaseManager.instance.init();
    db = DatabaseManager.instance.db;
    player = PlayerController();
    app = AppState(player: player);
    await app.init();
  });

  tearDown(() async {
    await DatabaseManager.instance.close();
    await tmp.delete(recursive: true);
  });

  /// sqflite ffi 走独立 isolate，属真实 I/O，在 testWidgets 的假时钟里
  /// 永不完成。必须 runAsync 与 pump 交替推进。
  Future<void> settleIo(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();
  }

  /// 造 [count] 张真实存在的图片行，文件名就是页码。
  Future<List<MediaItem>> seedImages(int count) async {
    final out = <MediaItem>[];
    for (var i = 0; i < count; i++) {
      final name = 'page_$i.png';
      final file = File(p.join(imageDir.path, name));
      await file.writeAsBytes(_png1x1);
      final id = await db.insert('media', {
        'path': file.path,
        'media_type': 'image',
        'filename': name,
        'added_at': i + 1,
        'width': 1,
        'height': 1,
      });
      out.add(
        MediaItem(
          id: id,
          path: file.path,
          mediaType: MediaType.image,
          filename: name,
          addedAt: i + 1,
          width: 1,
          height: 1,
        ),
      );
    }
    return out;
  }

  Future<void> pumpViewer(
    WidgetTester tester, {
    ReadingDirection? direction,
    ReadingFit? fit,
  }) async {
    // 顶部工具栏按钮多，用宽窗口避免 Row overflow。
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<PlayerController>.value(value: player),
          ChangeNotifierProvider<AppState>.value(value: app),
        ],
        child: MaterialApp(
          home: ImageViewer(
            state: app,
            initialDirection: direction,
            initialFit: fit,
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> sendKey(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyEvent(key);
    await tester.pumpAndSettle();
  }

  Image imageWidget(WidgetTester tester) =>
      tester.widget<Image>(find.byType(Image));

  testWidgets('ltr：右方向键前进，末张不越界', (tester) async {
    final items = (await tester.runAsync(() => seedImages(3)))!;
    app.openViewer(items, 0);

    await pumpViewer(tester, direction: ReadingDirection.ltr);
    await settleIo(tester);

    expect(app.viewerIndex, 0, reason: '起点是第 1 张');

    await sendKey(tester, LogicalKeyboardKey.arrowRight);
    expect(app.viewerIndex, 1, reason: 'ltr 下右键前进');

    await sendKey(tester, LogicalKeyboardKey.arrowRight);
    expect(app.viewerIndex, 2, reason: 'ltr 下右键再前进');

    await sendKey(tester, LogicalKeyboardKey.arrowRight);
    expect(app.viewerIndex, 2, reason: '到末张再前进不越界');

    await sendKey(tester, LogicalKeyboardKey.arrowLeft);
    expect(app.viewerIndex, 1, reason: 'ltr 下左键后退');
  });

  testWidgets('rtl：左方向键前进、右方向键后退，底栏左键是「下一张」', (tester) async {
    final items = (await tester.runAsync(() => seedImages(3)))!;
    app.openViewer(items, 1);

    // 不注入方向：默认 rtl（BUILD_GUIDE 22.2 的列默认值）。
    await pumpViewer(tester);
    await settleIo(tester);

    expect(find.byTooltip('下一张 (←)'), findsOneWidget, reason: 'rtl 下底栏左侧按钮是前进');
    expect(find.byTooltip('上一张 (→)'), findsOneWidget, reason: 'rtl 下底栏右侧按钮是后退');

    await sendKey(tester, LogicalKeyboardKey.arrowLeft);
    expect(app.viewerIndex, 2, reason: 'rtl 下左键前进');

    await sendKey(tester, LogicalKeyboardKey.arrowRight);
    expect(app.viewerIndex, 1, reason: 'rtl 下右键后退');

    await tester.tap(find.byKey(const ValueKey('viewer-right-button')));
    await tester.pumpAndSettle();
    expect(app.viewerIndex, 0, reason: 'rtl 下底栏右键按钮是后退');
  });

  testWidgets('S 键与工具栏按钮循环适应模式，Image 的 BoxFit 跟着变', (tester) async {
    final items = (await tester.runAsync(() => seedImages(2)))!;
    app.openViewer(items, 0);

    await pumpViewer(tester, fit: ReadingFit.page);
    await settleIo(tester);

    expect(imageWidget(tester).fit, BoxFit.contain, reason: 'page = 整页可见');

    await sendKey(tester, LogicalKeyboardKey.keyS);
    expect(imageWidget(tester).fit, BoxFit.fitHeight, reason: 'height = 铺满高度');

    await sendKey(tester, LogicalKeyboardKey.keyS);
    expect(imageWidget(tester).fit, BoxFit.fitWidth, reason: 'width = 铺满宽度');

    await sendKey(tester, LogicalKeyboardKey.keyS);
    expect(imageWidget(tester).fit, BoxFit.contain, reason: '循环回整页');

    await tester.tap(find.byKey(const ValueKey('viewer-fit-button')));
    await tester.pumpAndSettle();
    expect(imageWidget(tester).fit, BoxFit.fitHeight, reason: '工具栏按钮走同一套循环');
  });

  testWidgets('点画面切控件显隐，静止 3 秒后自动隐藏', (tester) async {
    final items = (await tester.runAsync(() => seedImages(1)))!;
    app.openViewer(items, 0);

    await pumpViewer(tester);
    await settleIo(tester);

    final topBar = find.byKey(const ValueKey('viewer-top-bar'));
    final bottomBar = find.byKey(const ValueKey('viewer-bottom-bar'));

    expect(topBar, findsOneWidget, reason: '进入时控件显示');
    expect(bottomBar, findsOneWidget, reason: '进入时底栏显示');

    await tester.tap(find.byKey(const ValueKey('viewer-image-area')));
    await tester.pumpAndSettle();
    expect(topBar, findsNothing, reason: '点画面隐藏控件');
    expect(bottomBar, findsNothing, reason: '点画面同时隐藏底栏');

    await tester.tap(find.byKey(const ValueKey('viewer-image-area')));
    await tester.pumpAndSettle();
    expect(topBar, findsOneWidget, reason: '再点一次恢复显示');

    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(topBar, findsNothing, reason: '静止 3 秒后自动隐藏');
    expect(bottomBar, findsNothing, reason: '底栏一起自动隐藏');
  });

  testWidgets('Esc 与关闭按钮都把 showViewer 置假', (tester) async {
    final items = (await tester.runAsync(() => seedImages(2)))!;
    app.openViewer(items, 0);

    await pumpViewer(tester);
    await settleIo(tester);
    expect(app.showViewer, isTrue);

    await sendKey(tester, LogicalKeyboardKey.escape);
    expect(app.showViewer, isFalse, reason: 'Esc 退出阅读模式');

    app.openViewer(items, 0);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('viewer-close-button')));
    await tester.pumpAndSettle();
    expect(app.showViewer, isFalse, reason: '关闭按钮同样退出阅读模式');
  });

  testWidgets('触控滑动翻页：rtl 向左滑是后退', (tester) async {
    final items = (await tester.runAsync(() => seedImages(3)))!;
    app.openViewer(items, 1);

    await pumpViewer(tester, direction: ReadingDirection.rtl);
    await settleIo(tester);

    final area = find.byKey(const ValueKey('viewer-image-area'));

    // rtl：手指向左滑（负速度）＝后退
    await tester.fling(area, const Offset(-300, 0), 1200);
    await tester.pumpAndSettle();
    expect(app.viewerIndex, 0, reason: 'rtl 向左滑是后退');

    // rtl：手指向右滑（正速度）＝前进
    await tester.fling(area, const Offset(300, 0), 1200);
    await tester.pumpAndSettle();
    expect(app.viewerIndex, 1, reason: 'rtl 向右滑是前进');
  });

  testWidgets('触控滑动翻页：ltr 方向相反', (tester) async {
    final items = (await tester.runAsync(() => seedImages(3)))!;
    app.openViewer(items, 1);

    await pumpViewer(tester, direction: ReadingDirection.ltr);
    await settleIo(tester);

    final area = find.byKey(const ValueKey('viewer-image-area'));

    await tester.fling(area, const Offset(300, 0), 1200);
    await tester.pumpAndSettle();
    expect(app.viewerIndex, 0, reason: 'ltr 向右滑是后退');

    await tester.fling(area, const Offset(-300, 0), 1200);
    await tester.pumpAndSettle();
    expect(app.viewerIndex, 1, reason: 'ltr 向左滑是前进');
  });

  testWidgets('触控滑动翻页：慢慢拖够距离也算，画面不会被拖出视口', (tester) async {
    final items = (await tester.runAsync(() => seedImages(3)))!;
    app.openViewer(items, 0);

    await pumpViewer(tester);
    await settleIo(tester);

    // 适应窗口时图与视口同大：无限边界会让每次滑动都把画面推走并留在那儿。
    final viewer = tester.widget<InteractiveViewer>(
      find.byType(InteractiveViewer),
    );
    expect(viewer.boundaryMargin, EdgeInsets.zero);
    expect(viewer.minScale, 1.0, reason: '下限就是适应窗口，不该缩得比视口还小');
    expect(viewer.maxScale, 20.0);

    // 慢速拖动（速度接近 0）过去只看甩动速度，什么都不发生。
    final area = find.byKey(const ValueKey('viewer-image-area'));
    await tester.timedDrag(
      area,
      const Offset(400, 0),
      const Duration(milliseconds: 800),
    );
    await tester.pumpAndSettle();
    expect(app.viewerIndex, 1, reason: 'rtl 下慢拖向右足够远应前进');
  });

  testWidgets('系统栏留白：顶栏让开状态栏、底栏让开导航条', (tester) async {
    final items = (await tester.runAsync(() => seedImages(2)))!;
    app.openViewer(items, 0);

    tester.view.devicePixelRatio = 1.0;
    tester.view.viewPadding = const FakeViewPadding(top: 24, bottom: 48);
    await pumpViewer(tester);
    await settleIo(tester);

    expect(
      tester.getSize(find.byKey(const ValueKey('viewer-top-bar'))).height,
      52 + 24,
      reason: '顶栏要给状态栏让出高度，否则按钮被盖住点不到',
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('viewer-bottom-bar'))).height,
      52 + 48,
      reason: '底栏要给系统导航条让出高度',
    );

    // 关闭按钮真的落在状态栏下方，能点到
    final close = tester.getCenter(
      find.byKey(const ValueKey('viewer-close-button')),
    );
    expect(close.dy, greaterThanOrEqualTo(24));
  });
}
