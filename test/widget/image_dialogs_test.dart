import 'dart:async';
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
import 'package:asmrshelf/db/tag_dao.dart';
import 'package:asmrshelf/db/work_dao.dart';
import 'package:asmrshelf/services/cover_service.dart';
import 'package:asmrshelf/services/data_dir_service.dart';
import 'package:asmrshelf/services/settings_service.dart';
import 'package:asmrshelf/state/app_state.dart';
import 'package:asmrshelf/state/player_controller.dart';
import 'package:asmrshelf/widgets/color_picker_dialog.dart';
import 'package:asmrshelf/widgets/dialogs.dart';
import 'package:asmrshelf/widgets/filter_dialog.dart';
import 'package:asmrshelf/widgets/move_folder_dialog.dart';
import 'package:asmrshelf/widgets/tag_picker_dialog.dart';
import '../support/test_env.dart';


/// 测试用的宿主：一个按钮打开被测对话框，把返回值交回测试闭包。
///
/// 对话框本身只返回结果（不落库），落库动作由调用方决定，所以这里让测试
/// 自己传 [open] 回调，把「打开 + 落库」这一整条链路包进真实点击里。
class _Host<T> extends StatefulWidget {
  const _Host({required this.open, required this.onResult});

  final Future<T?> Function(BuildContext context) open;
  final void Function(T? result) onResult;

  @override
  State<_Host<T>> createState() => _HostState<T>();
}

class _HostState<T> extends State<_Host<T>> {
  bool _done = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            FilledButton(
              onPressed: () async {
                final r = await widget.open(context);
                widget.onResult(r);
                if (mounted) setState(() => _done = true);
              },
              child: const Text('打开'),
            ),
            if (_done) const Text('已关闭'),
          ],
        ),
      ),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late Database db;
  late PlayerController player;
  late AppState app;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tmp = await Directory.systemTemp.createTemp('asmrshelf_img_dialogs');
    PathProviderPlatform.instance = FakePathProvider(p.join(tmp.path, 'support'));
    DataDirService.instance.resetCache();
    SettingsService.instance.resetForTest();
    await DatabaseManager.instance.close();
    await DatabaseManager.instance.init();
    db = DatabaseManager.instance.db;
    player = PlayerController();
    app = AppState(player: player);
  });

  tearDown(() async {
    await DatabaseManager.instance.close();
    await tmp.delete(recursive: true);
  });

  /// 对话框内容比默认 800x600 高，放大视口避免 RenderFlex 溢出打断用例。
  void bigView(WidgetTester tester) {
    tester.view.physicalSize = const Size(1400, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  Future<void> pumpHost<T>(
    WidgetTester tester,
    Future<T?> Function(BuildContext context) open,
    void Function(T?) onResult,
  ) {
    return tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<PlayerController>.value(value: player),
          ChangeNotifierProvider<AppState>.value(value: app),
        ],
        child: MaterialApp(home: _Host<T>(open: open, onResult: onResult)),
      ),
    );
  }

  /// 界面回调里的真实 I/O（sqflite ffi 走独立 isolate）要交替让出事件循环：
  /// runAsync 让真实 I/O 跑完，pump 让假时钟里的回调接着往下走。
  Future<void> settleIo(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump();
    }
    await tester.pumpAndSettle();
  }

  testWidgets('颜色选择对话框：点预设色块后确定，回调拿到该颜色', (tester) async {
    bigView(tester);
    String? picked;

    await pumpHost<String>(
      tester,
      (ctx) => ColorPickerDialog.show(ctx, initialHex: '#CBA6F7'),
      (r) => picked = r,
    );
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, '打开'));
    await tester.pumpAndSettle();
    expect(find.text('选择颜色'), findsOneWidget);

    // 真实点中 16 个预设里的绿色块（加 key 只为定位，不改行为）
    await tester.tap(find.byKey(const ValueKey<String>('color-preset-#a6e3a1')));
    await tester.pump();

    await tester.tap(find.widgetWithText(FilledButton, '确定'));
    await tester.pumpAndSettle();

    expect(picked, '#A6E3A1');
    expect(find.byType(AlertDialog), findsNothing, reason: '确定后应关闭对话框');
  });

  testWidgets('移动文件夹对话框：点目标文件夹后确认，落库父级变更', (tester) async {
    bigView(tester);
    late VirtualFolder source;
    late VirtualFolder target;
    late VirtualFolder child;

    await tester.runAsync(() async {
      final dao = FolderDao(db);
      source = await dao.create('源夹');
      target = await dao.create('目标夹');
      child = await dao.create('子夹', parentId: source.id);
    });

    int? returned;
    await pumpHost<int>(
      tester,
      (ctx) async {
        final pickedParent = await showMoveFolderDialog(
          ctx,
          source: source,
          allFolders: [source, target, child],
        );
        if (pickedParent != null) {
          await FolderDao(db)
              .move(source.id!, pickedParent == kMoveToRoot ? null : pickedParent);
        }
        return pickedParent;
      },
      (r) => returned = r,
    );
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, '打开'));
    await tester.pumpAndSettle();
    expect(find.text('移动「源夹」到'), findsOneWidget);
    // 自身与后代不能作为目标，否则会形成循环层级
    expect(find.text('源夹'), findsNothing);
    expect(find.text('子夹'), findsNothing);
    expect(find.text('目标夹'), findsOneWidget);

    await tester.tap(find.text('目标夹'));
    await tester.pump();
    await tester.tap(find.widgetWithText(TextButton, '移动'));
    await tester.pump();
    await settleIo(tester);

    expect(returned, target.id);
    final row = await tester.runAsync(
        () => db.query('folders', where: 'id = ?', whereArgs: [source.id]));
    expect(row!.single['parent'], target.id, reason: '落库后父级应是目标文件夹');
  });

  testWidgets('移动文件夹对话框：选根级后确认，落库父级为空', (tester) async {
    bigView(tester);
    late VirtualFolder source;
    late VirtualFolder root;

    await tester.runAsync(() async {
      final dao = FolderDao(db);
      root = await dao.create('顶层夹');
      source = await dao.create('源夹', parentId: root.id);
    });

    int? returned;
    await pumpHost<int>(
      tester,
      (ctx) async {
        final pickedParent = await showMoveFolderDialog(
          ctx,
          source: source,
          allFolders: [source, root],
        );
        if (pickedParent != null) {
          await FolderDao(db)
              .move(source.id!, pickedParent == kMoveToRoot ? null : pickedParent);
        }
        return pickedParent;
      },
      (r) => returned = r,
    );
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, '打开'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('根级（顶层）'));
    await tester.pump();
    await tester.tap(find.widgetWithText(TextButton, '移动'));
    await tester.pump();
    await settleIo(tester);

    expect(returned, kMoveToRoot);
    final row = await tester.runAsync(
        () => db.query('folders', where: 'id = ?', whereArgs: [source.id]));
    expect(row!.single['parent'], isNull, reason: '落库后应回到根级');
  });

  testWidgets('标签选择对话框：勾两个标签后确定，回调含这两个标签', (tester) async {
    bigView(tester);
    late Tag a;
    late Tag b;

    await tester.runAsync(() async {
      final dao = TagDao(db);
      a = await dao.insert(const Tag(name: '风景', color: '#a6e3a1'));
      b = await dao.insert(const Tag(name: '人像', color: '#f38ba8'));
      await dao.insert(const Tag(name: '私密', color: '#f9e2af'));
      await app.init();
    });

    List<Tag>? picked;
    await pumpHost<List<Tag>>(
      tester,
      (ctx) => showTagPickerDialog(ctx),
      (r) => picked = r,
    );
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, '打开'));
    await tester.pumpAndSettle();
    expect(find.byType(CheckboxListTile), findsNWidgets(3));

    await tester.tap(find.text('风景'));
    await tester.pump();
    await tester.tap(find.text('人像'));
    await tester.pump();

    await tester.tap(find.widgetWithText(FilledButton, '确定'));
    await tester.pumpAndSettle();

    expect(picked, isNotNull);
    expect(picked!.map((t) => t.id).toSet(), {a.id, b.id});
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('筛选对话框：点标签插入后应用，AppState 高级筛选随之改变', (tester) async {
    bigView(tester);

    await tester.runAsync(() async {
      await TagDao(db).insert(const Tag(name: '风景', color: '#a6e3a1'));
      await app.init();
    });

    await pumpHost<String>(
      tester,
      (ctx) async {
        await AdvancedFilterDialog.show(ctx);
        return null;
      },
      (_) {},
    );
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, '打开'));
    await tester.pumpAndSettle();
    expect(find.text('高级筛选'), findsOneWidget);

    // 点「可用标签」里的 chip，把标签引用插进表达式输入框
    await tester.tap(find.text('风景'));
    await tester.pump();
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, '风景');

    await tester.tap(find.widgetWithText(FilledButton, '应用'));
    await tester.pump();
    await settleIo(tester);

    expect(app.advancedFilter, '风景');
    expect(app.hasAdvancedFilter, isTrue);
    expect(find.byType(AlertDialog), findsNothing, reason: '应用成功后应关闭对话框');
  });

  testWidgets('音频作品换封面：候选来自目录，固定路径的旧解码缓存被驱逐', (tester) async {
    bigView(tester);
    late Work work;
    late String srcPath;
    late String destPath;

    await tester.runAsync(() async {
      work = await WorkDao(db).create('音声', library: 'audio');
      final folder = await FolderDao(db)
          .create('音声', workId: work.id, library: 'audio');
      final voiceDir = Directory(p.join(tmp.path, 'voice'))
        ..createSync(recursive: true);
      srcPath = p.join(voiceDir.path, '封面.png');
      File(srcPath).writeAsBytesSync([1, 2, 3]);
      await FolderDao(db).addPath(folder.id!, voiceDir.path);
      destPath = p.join(await CoverService.coversDir(), 'work_${work.id}.png');
    });

    // 模拟界面已经显示过这个固定路径的旧封面。不需要真解码一张图：
    // 挂一个永不完成的 completer 就足够占住这个缓存键。
    final destImage = FileImage(File(destPath));
    imageCache.putIfAbsent(
      destImage,
      () => OneFrameImageStreamCompleter(Completer<ImageInfo>().future),
    );
    addTearDown(() {
      imageCache.clear();
      imageCache.clearLiveImages();
    });
    expect(imageCache.containsKey(destImage), isTrue);

    await pumpHost<void>(
      tester,
      (ctx) => showImportCoverDialog(ctx, work.id!),
      (_) {},
    );
    await tester.tap(find.widgetWithText(FilledButton, '打开'));
    await settleIo(tester);

    expect(find.byKey(const ValueKey('cover-pick-grid')), findsOneWidget,
        reason: '音频作品没有图片行时，也要把目录里的图列出来');
    await tester.tap(find.byKey(const ValueKey('cover-pick-0')));
    await settleIo(tester);

    final saved = await tester.runAsync(() => WorkDao(db).getById(work.id!));
    expect(saved!.coverPath, destPath);
    expect(imageCache.containsKey(destImage), isFalse,
        reason: '同一路径覆盖写后必须驱逐旧解码结果，否则卡片还是老封面');
  });
}
