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
import 'package:asmrshelf/state/app_state.dart';
import 'package:asmrshelf/state/player_controller.dart';
import 'package:asmrshelf/widgets/folder_browser.dart';
import '../support/test_env.dart';

/// 音频多选工具条：手机上「批量移除标签」的入口曾经被挤出屏幕，退出多选也不明显。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late Database db;
  late PlayerController player;
  late AppState app;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tmp = await Directory.systemTemp.createTemp('asmrshelf_selection_bar');
    PathProviderPlatform.instance = FakePathProvider(p.join(tmp.path, 'support'));
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

  Future<void> seedWork() async {
    final workId = (await WorkDao(db).create('作品A')).id!;
    await FolderDao(db).create('专辑', workId: workId);
    app = AppState(player: player);
    await app.init();
    await app.enterWork(workId);
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

  void useScreen(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  testWidgets('手机窄屏：多选工具条不裁掉入口', (tester) async {
    useScreen(tester, const Size(360, 800));
    await tester.runAsync(seedWork);
    await pump(tester);

    app.enterSelectionMode(1);
    await tester.pumpAndSettle();
    expect(find.text('已选 1 首'), findsOneWidget);

    // 固定高度的 Row 在 360 宽下装不下这一长串，右侧按钮会被裁掉
    expect(tester.takeException(), isNull);

    final removeTags = find.byKey(const ValueKey('track-batch-remove-tags'));
    expect(removeTags, findsOneWidget);
    // 窄屏上每个入口都要落在屏幕里，任何一个被挤出去都算这一类缺陷复发
    for (final key in const [
      ValueKey('track-toolbar-select'),
      ValueKey('track-select-all'),
      ValueKey('track-batch-add-tags'),
      ValueKey('track-batch-remove-tags'),
      ValueKey('track-remove-records'),
    ]) {
      final finder = find.byKey(key);
      expect(finder, findsOneWidget, reason: '$key 这个入口不见了');
      final rect = tester.getRect(finder);
      expect(rect.left, greaterThanOrEqualTo(0.0), reason: '$key 被挤出屏幕左边');
      expect(rect.right, lessThanOrEqualTo(360.0), reason: '$key 被挤出屏幕右边');
    }
  });

  testWidgets('手机窄屏：退出多选有明确出口，点一下就退出', (tester) async {
    useScreen(tester, const Size(360, 800));
    await tester.runAsync(seedWork);
    await pump(tester);

    app.enterSelectionMode(1);
    await tester.pumpAndSettle();

    // 退出写成带文字的按钮（窄屏退化成图标 + 提示气泡），不再是一个勾选框图标
    expect(find.byTooltip('退出多选'), findsOneWidget);
    await tester.tap(find.byTooltip('退出多选'));
    await tester.pumpAndSettle();

    expect(find.text('已选 1 首'), findsNothing);
    expect(find.byTooltip('多选'), findsOneWidget);
    expect(app.selectionMode, isFalse);
  });

  testWidgets('手机窄屏：返回键先退出多选，不离开这一页', (tester) async {
    useScreen(tester, const Size(360, 800));
    await tester.runAsync(seedWork);
    await pump(tester);

    app.enterSelectionMode(1);
    await tester.pumpAndSettle();

    // maybePop 返回 true 表示这次返回被这一页消费掉了（PopScope 拦住，没有真的退出）。
    final handled =
        await Navigator.maybePop(tester.element(find.byType(FolderBrowser)));
    await tester.pumpAndSettle();

    expect(handled, isTrue);
    expect(app.selectionMode, isFalse, reason: '返回键先退出多选');
    expect(find.byType(FolderBrowser), findsOneWidget);
  });

  testWidgets('宽屏：多选动作仍然是带文字的按钮', (tester) async {
    useScreen(tester, const Size(1200, 800));
    await tester.runAsync(seedWork);
    await pump(tester);

    app.enterSelectionMode(1);
    await tester.pumpAndSettle();

    expect(find.text('退出多选'), findsOneWidget);
    expect(find.text('全选'), findsOneWidget);
    expect(find.text('批量加标签'), findsOneWidget);
    expect(find.text('批量移除标签'), findsOneWidget);
    expect(find.text('移除记录'), findsOneWidget);
  });
}
