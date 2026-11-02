import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import 'package:asmrshelf/db/database.dart';
import 'package:asmrshelf/db/track_dao.dart';
import 'package:asmrshelf/services/data_dir_service.dart';
import 'package:asmrshelf/state/app_state.dart';
import 'package:asmrshelf/state/player_controller.dart';
import 'package:asmrshelf/widgets/player_bar.dart';
import 'package:asmrshelf/widgets/segment_panel.dart';
import '../support/test_env.dart';


/// 收藏选段面板的界面交互测试（BUILD_GUIDE 第 24.3 节）。
///
/// 全部走真实按钮与手势。落库走 sqflite 的隔离区，属于真实 I/O，在 widget
/// 测试的假时钟里不会自己完成，所以每次写库后用 [settleIo] 让出事件循环。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late Database db;
  late PlayerController player;
  late AppState app;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tmp = await Directory.systemTemp.createTemp('audioshelf_segment_ui');
    PathProviderPlatform.instance =
        FakePathProvider(p.join(tmp.path, 'support'));
    DataDirService.instance.resetCache();
    await DatabaseManager.instance.close();
    await DatabaseManager.instance.init();
    db = DatabaseManager.instance.db;
    await db.insert('media', {
      'id': 1,
      'path': '/m/a.mp3',
      'media_type': 'audio',
      'filename': 'a.mp3',
      'added_at': 1,
      'duration_ms': 10000,
    });
    player = PlayerController();
    player.debugSeedQueue(
      [TrackItem(id: 1, path: '/m/a.mp3', filename: 'a.mp3', addedAt: 0)],
      duration: const Duration(seconds: 10),
    );
    app = AppState(player: player);
    await app.init();
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

  /// 让真实 I/O（sqflite 隔离区）在假时钟下有机会完成，再把帧推上去
  Future<void> settleIo(WidgetTester tester) async {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pumpAndSettle();
  }

  /// 清掉 SnackBar 的定时器，避免用例结束时留下待处理的定时器
  Future<void> drainSnackBar(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
  }

  testWidgets('保存选段：点按钮、填名字、写库并自动循环这一段', (tester) async {
    await pump(tester, const SegmentPanel());
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('segment-range')), findsOneWidget);
    expect(find.text('这首曲目还没有选段'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('segment-save')));
    await tester.pumpAndSettle();
    expect(find.text('选段名称'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '副歌');
    await tester.tap(find.byKey(const ValueKey('segment-name-ok')));
    await tester.pump();
    await settleIo(tester);

    expect(app.segments.length, 1);
    expect(app.segments.single.name, '副歌');
    expect(app.segments.single.startMs, 0);
    expect(app.segments.single.endMs, 10000);
    expect(find.text('副歌'), findsOneWidget);
    expect(player.loopSegment, isNotNull, reason: '保存后直接循环这一段');

    // 库里也真的写进去了
    final rows = await tester.runAsync(() => db.query('media_segments'));
    expect(rows!.length, 1);
    expect(rows.single['name'], '副歌');

    await drainSnackBar(tester);
  });

  testWidgets('拖手柄过程中播放器不动，松手才把选区交给播放器', (tester) async {
    await pump(tester, const SegmentPanel());
    await tester.pumpAndSettle();

    tester
        .widget<RangeSlider>(find.byKey(const ValueKey('segment-range')))
        .onChanged!(const RangeValues(3000, 6000));
    await tester.pump();
    expect(player.loopSegment, isNull, reason: '拖动过程中只动手柄');

    tester
        .widget<RangeSlider>(find.byKey(const ValueKey('segment-range')))
        .onChangeEnd!(const RangeValues(2000, 5000));
    await tester.pump();
    expect(player.loopSegment!.startMs, 2000);
    expect(player.loopSegment!.endMs, 5000);
    expect(player.segmentLoopEnabled, isTrue);
  });

  testWidgets('在滑轨上真实点击也能定出选区', (tester) async {
    await pump(tester, const SegmentPanel());
    await tester.pumpAndSettle();

    await tester.tapAt(
        tester.getCenter(find.byKey(const ValueKey('segment-range'))));
    await tester.pump();

    final seg = player.loopSegment;
    expect(seg, isNotNull, reason: '手势松手即生效');
    expect(seg!.startMs > 0 || seg.endMs < 10000, isTrue,
        reason: '点击把靠近的手柄挪到了中间');
  });

  testWidgets('段列表：循环、跳转、重命名、删除都能点', (tester) async {
    final saved = await tester.runAsync(
        () => app.addSegment(startMs: 0, endMs: 4000, name: '甲'));
    final id = saved!.id!;

    await pump(tester, const SegmentPanel());
    await tester.pumpAndSettle();
    expect(find.text('甲'), findsOneWidget);

    await tester.tap(find.byKey(ValueKey('segment-loop-$id')));
    await tester.pump();
    expect(player.loopSegment!.id, id);

    await tester.tap(find.byKey(ValueKey('segment-loop-$id')));
    await tester.pump();
    expect(player.loopSegment, isNull);

    await tester.tap(find.byKey(ValueKey('segment-jump-$id')));
    await tester.pump();

    await tester.tap(find.byKey(ValueKey('segment-rename-$id')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '乙');
    await tester.tap(find.byKey(const ValueKey('segment-name-ok')));
    await tester.pump();
    await settleIo(tester);
    expect(app.segments.single.name, '乙');

    await tester.tap(find.byKey(ValueKey('segment-delete-$id')));
    await tester.pump();
    await settleIo(tester);
    expect(app.segments, isEmpty);
    expect(find.text('这首曲目还没有选段'), findsOneWidget);
  });

  testWidgets('清除选区按钮把循环关掉', (tester) async {
    final saved = await tester
        .runAsync(() => app.addSegment(startMs: 0, endMs: 4000, name: '甲'));
    await app.loopSegment(saved);
    expect(player.segmentLoopEnabled, isTrue);

    await pump(tester, const SegmentPanel());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('segment-clear')));
    await tester.pump();
    expect(player.segmentLoopEnabled, isFalse);
  });

  testWidgets('播放条上的选区按钮打开面板', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await pump(tester, const PlayerBar());
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('player-segment-button')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('player-segment-button')));
    await tester.pumpAndSettle();

    expect(find.byType(SegmentPanel), findsOneWidget);
    expect(find.text('收藏选段'), findsOneWidget);
  });
}
