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
import 'package:asmrshelf/widgets/volume_cover_dialog.dart';
import '../support/test_env.dart';

/// 1x1 的合法 PNG，读图尺寸与预览都要真文件。
const String _tinyPngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg==';


/// 卷封面对话框的真实点击验收（BUILD_GUIDE 第 19.2、21.2、21.4 节）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late Database db;
  late PlayerController player;
  late AppState app;
  late int folderId;
  late String volDir;
  late String extraPng;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tmp = await Directory.systemTemp.createTemp('asmrshelf_cover_dialog');
    PathProviderPlatform.instance =
        FakePathProvider(p.join(tmp.path, 'support'));
    DataDirService.instance.resetCache();
    SettingsService.instance.resetForTest();
    await DatabaseManager.instance.close();
    await DatabaseManager.instance.init();
    db = DatabaseManager.instance.db;
    player = PlayerController();
    app = AppState(player: player);

    volDir = p.join(tmp.path, 'vol');
    await Directory(volDir).create(recursive: true);
    for (final name in const ['cover.png', 'b.png']) {
      await File(p.join(volDir, name)).writeAsBytes(base64Decode(_tinyPngBase64));
    }
    extraPng = p.join(tmp.path, 'extra.png');
    await File(extraPng).writeAsBytes(base64Decode(_tinyPngBase64));

    final work = await WorkDao(db).create('图库', library: 'media');
    final folder =
        await FolderDao(db).create('卷A', workId: work.id, library: 'media');
    folderId = folder.id!;
    await FolderDao(db).addPath(folderId, volDir);

    final mediaDao = MediaDao(db);
    for (final name in const ['cover.png', 'b.png']) {
      await mediaDao.insertRow(MediaItem(
        path: p.join(volDir, name),
        filename: name,
        mediaType: MediaType.image,
        addedAt: 0,
        width: 1,
        height: 1,
      ).toMap());
    }
  });

  tearDown(() async {
    await DatabaseManager.instance.close();
    await tmp.delete(recursive: true);
  });

  void bigView(WidgetTester tester) {
    tester.view.physicalSize = const Size(1400, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  /// 真 I/O（读库、读图尺寸）在假时钟里不会自己完成，交替让出事件循环。
  Future<void> settleIo(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(() => Future<void>.delayed(
          const Duration(milliseconds: 40)));
      await tester.pump();
    }
    await tester.pump();
  }

  Future<void> openDialog(
    WidgetTester tester, {
    Future<String?> Function()? pickImage,
    Size? imageSize = const Size(1, 1),
  }) async {
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
                onPressed: () async {
                  final state = ctx.read<AppState>();
                  await showDialog<void>(
                    context: ctx,
                    builder: (_) => VolumeCoverDialog(
                      state: state,
                      folderId: folderId,
                      folderName: '卷A',
                      pickImage: pickImage,
                      // 解码真图要真事件循环，假时钟下走不完：注入固定尺寸。
                      readSize: imageSize == null
                          ? (path) async => null
                          : (path) async => imageSize,
                    ),
                  );
                },
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('打开'));
    // 载入时对话框里有转圈，pumpAndSettle 会等不完，先让真 I/O 落地。
    await tester.pump();
    await settleIo(tester);
    await tester.pump();
  }

  String summary(WidgetTester tester) =>
      tester.widget<Text>(find.byKey(const ValueKey('cover-summary'))).data!;

  /// 有效封面（手动优先，其次自动）。
  Future<String?> effectiveCover(WidgetTester tester) async =>
      tester.runAsync<String?>(() => app.volumeCover(folderId));

  /// 库里存的 `folders.cover_path`：判断「手动指定」是否真落库。
  Future<String?> storedManual(WidgetTester tester) async {
    final rows = await tester.runAsync(() => db.query('folders',
        columns: const ['cover_path'],
        where: 'id = ?',
        whereArgs: [folderId]));
    return rows!.single['cover_path'] as String?;
  }

  testWidgets('打开就列出自动候选，缺省封面取卷内白名单图', (tester) async {
    bigView(tester);
    await openDialog(tester);

    expect(summary(tester), contains('自动'));
    expect(summary(tester), contains('cover.png'));
    expect(find.text('卷内封面图'), findsOneWidget, reason: '优先级①的来源标签');
    expect(find.text('卷内第一张图'), findsOneWidget, reason: '优先级②的来源标签');
    expect(find.byKey(const ValueKey('cover-candidate-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('cover-candidate-1')), findsOneWidget);
  });

  testWidgets('点候选改成手动指定并落库', (tester) async {
    bigView(tester);
    await openDialog(tester);

    await tester.tap(find.ancestor(
        of: find.text('b.png'), matching: find.byType(ListTile)));
    await tester.pumpAndSettle();
    await settleIo(tester);

    expect(summary(tester), contains('手动指定'));
    expect(summary(tester), contains('b.png'));
    expect(await storedManual(tester), p.join(volDir, 'b.png'));
    expect(await effectiveCover(tester), p.join(volDir, 'b.png'));
  });

  testWidgets('恢复自动把手动封面清掉', (tester) async {
    bigView(tester);
    await openDialog(tester);

    await tester.tap(find.ancestor(
        of: find.text('b.png'), matching: find.byType(ListTile)));
    await tester.pumpAndSettle();
    await settleIo(tester);
    expect(await storedManual(tester), isNotNull);

    await tester.tap(find.byKey(const ValueKey('cover-auto')));
    await tester.pumpAndSettle();
    await settleIo(tester);

    expect(await storedManual(tester), isNull, reason: '恢复自动要清掉手动封面');
    expect(summary(tester), contains('自动'));
    expect(summary(tester), contains('cover.png'),
        reason: '清掉手动后回到自动候选 cover.png');
  });

  testWidgets('裁剪取景后落库，恢复默认裁剪清掉', (tester) async {
    bigView(tester);
    await openDialog(tester);

    // 没裁剪时「恢复默认裁剪」不可点
    final clearBtn = tester
        .widget<TextButton>(find.byKey(const ValueKey('cover-clear-crop')));
    expect(clearBtn.onPressed, isNull);

    await tester.tap(find.byKey(const ValueKey('cover-crop')));
    await tester.pumpAndSettle();
    await settleIo(tester);
    expect(find.byKey(const ValueKey('crop-surface')), findsOneWidget);

    final corner = tester
        .getCenter(find.byKey(const ValueKey('crop-handle-bottomRight')));
    await tester.dragFrom(corner - const Offset(4, 4), const Offset(-40, -20));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('crop-confirm')));
    await tester.pumpAndSettle();
    await settleIo(tester);

    expect(summary(tester), contains('已裁剪'));
    final crop = await tester.runAsync(() => app.volumeCoverCrop(folderId));
    expect(crop, isNotNull);

    await tester.tap(find.byKey(const ValueKey('cover-clear-crop')));
    await tester.pumpAndSettle();
    await settleIo(tester);

    expect(await tester.runAsync(() => app.volumeCoverCrop(folderId)), isNull);
    expect(summary(tester), contains('未裁剪'));
  });

  testWidgets('读不出图片尺寸时给提示，不打开裁剪器', (tester) async {
    bigView(tester);
    await openDialog(tester, imageSize: null);

    expect(find.textContaining('图片尺寸未知'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('cover-crop')));
    await tester.pump();
    await settleIo(tester);

    expect(find.text('这张图读不出尺寸，无法裁剪'), findsOneWidget);
    expect(find.byKey(const ValueKey('crop-surface')), findsNothing);
  });

  testWidgets('从文件选择走注入的选择器并把结果落成手动封面', (tester) async {
    bigView(tester);
    await openDialog(tester, pickImage: () async => extraPng);

    await tester.tap(find.byKey(const ValueKey('cover-pick')));
    await tester.pumpAndSettle();
    await settleIo(tester);

    expect(summary(tester), contains('手动指定'));
    expect(summary(tester), contains('extra.png'));
    expect(await storedManual(tester), extraPng);
    expect(await effectiveCover(tester), extraPng);
  });
}
