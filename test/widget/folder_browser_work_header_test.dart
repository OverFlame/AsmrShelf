import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import 'package:asmrshelf/db/database.dart';
import 'package:asmrshelf/db/work_dao.dart';
import 'package:asmrshelf/db/work_metadata_dao.dart';
import 'package:asmrshelf/services/data_dir_service.dart';
import 'package:asmrshelf/state/app_state.dart';
import 'package:asmrshelf/state/player_controller.dart';
import 'package:asmrshelf/widgets/folder_browser.dart';
import '../support/test_env.dart';

/// 作品详情头：抓过 DLsite 的作品显示社团、系列、编号、简介。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late Database db;
  late PlayerController player;
  late AppState app;
  late int workId;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tmp = await Directory.systemTemp.createTemp('asmrshelf_work_header');
    PathProviderPlatform.instance =
        FakePathProvider(p.join(tmp.path, 'support'));
    DataDirService.instance.resetCache();
    await DatabaseManager.instance.close();
    await DatabaseManager.instance.init();
    db = DatabaseManager.instance.db;
    player = PlayerController();
    workId = (await WorkDao(db).create('作品A')).id!;
  });

  tearDown(() async {
    await DatabaseManager.instance.close();
    await tmp.delete(recursive: true);
  });

  Future<void> pump(WidgetTester tester) async {
    // testWidgets 里是 FakeAsync 区，sqflite 的真实 I/O 必须放 runAsync。
    await tester.runAsync(() async {
      app = AppState(player: player);
      await app.init();
      await app.enterWork(workId);
    });
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<PlayerController>.value(value: player),
          ChangeNotifierProvider<AppState>.value(value: app),
        ],
        child: const MaterialApp(home: Scaffold(body: FolderBrowser())),
      ),
    );
    await tester.pump();
    // 详情头的查询也是真实 I/O，给它一个微任务的窗口再画一帧。
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
  }

  testWidgets('没抓过元数据时只有作品名与提示', (tester) async {
    await pump(tester);
    expect(find.byKey(const ValueKey('work-header')), findsOneWidget);
    expect(find.text('作品A'), findsWidgets);
    expect(find.textContaining('点 DLsite 可以补全'), findsOneWidget);
  });

  testWidgets('抓过之后显示社团、系列、编号与简介', (tester) async {
    await tester.runAsync(() => WorkMetadataDao(db).upsert(WorkMetadata(
      workId: workId,
      rjCode: 'RJ294126',
      circle: '社团A',
      series: '系列B',
      description: '这是远程简介',
      rawJson: '{"workno":"RJ294126","regist_date":"2024-05-01 00:00:00",'
          '"rate_average_star":48}',
      fetchedAt: DateTime.now().millisecondsSinceEpoch,
    )));
    await pump(tester);

    expect(find.textContaining('社团A'), findsOneWidget);
    expect(find.textContaining('系列·系列B'), findsOneWidget);
    expect(find.textContaining('RJ294126'), findsOneWidget);
    expect(find.textContaining('2024-05-01'), findsOneWidget);
    expect(find.textContaining('4.8'), findsOneWidget);
    expect(find.textContaining('这是远程简介'), findsOneWidget);
  });

  testWidgets('点简介弹出全文', (tester) async {
    final long = '简介${'很长' * 40}';
    await tester.runAsync(() => WorkMetadataDao(db).upsert(WorkMetadata(
      workId: workId,
      description: long,
      fetchedAt: DateTime.now().millisecondsSinceEpoch,
    )));
    await pump(tester);
    await tester.tap(find.textContaining('简介很长'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    // 详情头本身也显示这段文字，弹窗打开后是两处。
    expect(find.text(long), findsNWidgets(2));
    await tester.tap(find.text('关闭'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text(long), findsOneWidget);
  });
}
