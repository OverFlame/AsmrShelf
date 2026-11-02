import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:asmrshelf/db/database.dart';
import 'package:asmrshelf/db/folder_dao.dart';
import 'package:asmrshelf/db/media_dao.dart';
import 'package:asmrshelf/db/tag_dao.dart';
import 'package:asmrshelf/services/data_dir_service.dart';
import 'package:asmrshelf/services/settings_service.dart';
import 'package:asmrshelf/state/app_state.dart';
import 'package:asmrshelf/state/player_controller.dart';
import 'package:asmrshelf/widgets/tag_panel.dart';
import '../support/test_env.dart';


/// 标签面板：命名空间折叠、规则标签保护、新建标签的联想与重名提醒。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late AppState app;
  late PlayerController player;
  late TagDao tags;
  late MediaDao media;
  late FolderDao folders;
  late Tag styleTag;
  late VirtualFolder folder;
  late int mediaId;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tmp = await Directory.systemTemp.createTemp('asmrshelf_tag_panel');
    PathProviderPlatform.instance =
        FakePathProvider(p.join(tmp.path, 'support'));
    DataDirService.instance.resetCache();
    SettingsService.instance.resetForTest();
    await DatabaseManager.instance.close();
    await DatabaseManager.instance.init();
    await SettingsService.instance.init();
    final db = DatabaseManager.instance.db;
    tags = TagDao(db);
    media = MediaDao(db);
    folders = FolderDao(db);
    player = PlayerController();
    app = AppState(player: player);
    await app.init();

    // 真实 I/O 全部放在 setUp：widget 测试体在假时钟里等真实数据库会卡住。
    styleTag = await app.createTag('风景', namespace: '风格');
    folder = await folders.create('相册');
    mediaId = await media.insertRow({
      'path': p.join(tmp.path, 'a.mp3'),
      'media_type': 'audio',
      'filename': 'a.mp3',
      'added_at': 0,
    });
    await app.addTagsToMedia([mediaId], [styleTag]);
    await tags.addTagToFolder(folder.id!, styleTag.id!);
  });

  tearDown(() async {
    await DatabaseManager.instance.close();
    await tmp.delete(recursive: true);
  });

  Future<void> settleIo(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump();
    }
    await tester.pumpAndSettle();
  }

  Future<void> pumpPanel(WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: app,
        child: const MaterialApp(
          home: Scaffold(
            body: SizedBox(width: 320, child: TagPanel(filterOnly: true)),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 找某个标签条目里的「筛选选项」按钮。
  Finder tagMenu(int tagId) => find.descendant(
      of: find.byKey(ValueKey('tag-item-$tagId')),
      matching: find.byTooltip('筛选选项'));

  testWidgets('扩展名命名空间默认折叠，点标题能展开', (tester) async {
    await pumpPanel(tester);

    final extTag = app.allTags.firstWhere(
        (t) => t.namespace == TagDao.extNamespace && t.id != null);
    expect(find.byKey(const ValueKey('ns-header-ext')), findsOneWidget);
    expect(find.text('扩展名'), findsOneWidget,
        reason: '规则命名空间要显示中文名，不能直接写 ext');
    expect(find.byKey(ValueKey('tag-item-${extTag.id}')), findsNothing,
        reason: '几十个扩展名标签默认收起来');

    await tester.tap(find.byKey(const ValueKey('ns-header-ext')));
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('tag-item-${extTag.id}')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('ns-header-ext')));
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('tag-item-${extTag.id}')), findsNothing);
  });

  testWidgets('折叠全部与展开全部一次覆盖所有命名空间', (tester) async {
    await pumpPanel(tester);

    final kindTag = app.allTags.firstWhere(
        (t) => t.namespace == TagDao.kindNamespace && t.id != null);
    final extTag = app.allTags.firstWhere(
        (t) => t.namespace == TagDao.extNamespace && t.id != null);
    // 扩展名收着的时候，后面的命名空间都在视野里
    expect(find.byKey(ValueKey('tag-item-${kindTag.id}')), findsOneWidget);
    expect(find.byKey(ValueKey('tag-item-${styleTag.id}')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('tag-collapse-all')));
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('tag-item-${kindTag.id}')), findsNothing);
    expect(find.byKey(ValueKey('tag-item-${styleTag.id}')), findsNothing);
    expect(find.byKey(const ValueKey('ns-header-风格')), findsOneWidget,
        reason: '折叠只是收起条目，命名空间标题还在');
    expect(find.byKey(const ValueKey('ns-header-ext')), findsOneWidget);

    // 展开后扩展名（排序在最前）铺开几十条，后面的组会排到视野外，
    // 所以这里只看最前面那一组。
    await tester.tap(find.byKey(const ValueKey('tag-expand-all')));
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('tag-item-${extTag.id}')), findsOneWidget);
  });

  testWidgets('新建标签：命名空间给联想，同名同空间时禁用创建', (tester) async {
    await pumpPanel(tester);

    await tester.tap(find.byTooltip('新建标签'));
    await tester.pumpAndSettle();

    // 联想：库里已有的普通命名空间
    expect(find.byKey(const ValueKey('ns-suggestion-风格')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('ns-suggestion-风格')));
    await tester.pumpAndSettle();
    final nsField = tester
        .widget<TextField>(find.byKey(const ValueKey('create-tag-ns')))
        .controller!;
    expect(nsField.text, '风格');

    // 同名同命名空间 → 提示 + 创建按钮不可点
    await tester.enterText(
        find.byKey(const ValueKey('create-tag-name')), '风景');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('create-tag-warning')), findsOneWidget);
    expect(find.textContaining('已经存在'), findsOneWidget);
    expect(
        tester
            .widget<TextButton>(find.byKey(const ValueKey('create-tag-submit')))
            .onPressed,
        isNull);
  });

  testWidgets('新建标签：同名但在别的命名空间只提醒，仍可创建', (tester) async {
    await pumpPanel(tester);

    await tester.tap(find.byTooltip('新建标签'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('create-tag-name')), '风景');
    await tester.enterText(
        find.byKey(const ValueKey('create-tag-ns')), '场景');
    await tester.pumpAndSettle();

    expect(find.textContaining('别的命名空间'), findsOneWidget);
    expect(
        tester
            .widget<TextButton>(find.byKey(const ValueKey('create-tag-submit')))
            .onPressed,
        isNotNull);

    await tester.tap(find.byKey(const ValueKey('create-tag-submit')));
    await settleIo(tester);
    expect(app.findTagByName('风景', namespace: '场景'), isNotNull);
  });

  testWidgets('规则标签的菜单不给改名和删除，普通标签给', (tester) async {
    await pumpPanel(tester);

    final kindTag = app.allTags.firstWhere(
        (t) => t.namespace == TagDao.kindNamespace && t.id != null);
    await tester.tap(tagMenu(kindTag.id!));
    await tester.pumpAndSettle();
    expect(find.text('折叠此命名空间'), findsOneWidget);
    expect(find.text('删除标签'), findsNothing);
    expect(find.textContaining('不能改名或删除'), findsOneWidget);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();

    await tester.tap(tagMenu(styleTag.id!));
    await tester.pumpAndSettle();
    expect(find.text('删除标签'), findsOneWidget);
    expect(find.text('重命名/改色'), findsOneWidget);
  });

  testWidgets('删除确认框先问关联条数，并说明磁盘文件不动', (tester) async {
    await pumpPanel(tester);
    await tester.tap(tagMenu(styleTag.id!));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除标签'));
    await settleIo(tester);

    expect(find.textContaining('将解除 1 个媒体、1 个文件夹的关联'), findsOneWidget);
    expect(find.textContaining('磁盘上的文件不会被删除'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, '删除'));
    await settleIo(tester);
    expect(app.allTags.any((t) => t.id == styleTag.id), isFalse);
  });

  testWidgets('标签搜索框的清空按钮有 tooltip，点了能清空', (tester) async {
    await pumpPanel(tester);
    final search = find.byWidgetPredicate((w) =>
        w is TextField && w.decoration?.hintText == '搜索标签...');
    expect(search, findsOneWidget);
    expect(find.byTooltip('清空搜索'), findsNothing, reason: '没输入时不显示清空按钮');

    await tester.enterText(search, '风景');
    await tester.pumpAndSettle();
    expect(find.byTooltip('清空搜索'), findsOneWidget);

    await tester.tap(find.byTooltip('清空搜索'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(search).controller?.text, '');
  });

  testWidgets('滚动标签列表时表头与搜索框不跟着移动', (tester) async {
    await pumpPanel(tester);

    // 展开扩展名这一大组，再把窗口压矮，列表才长到能滚
    await tester.tap(find.byKey(const ValueKey('ns-header-ext')));
    await tester.pumpAndSettle();
    tester.view.physicalSize = const Size(900, 700);
    await tester.pumpAndSettle();

    final header = find.byKey(const ValueKey('tag-expand-all'));
    final search = find.byType(TextField);
    final extHeader = find.byKey(const ValueKey('ns-header-ext'));
    final pos = tester
        .state<ScrollableState>(find.descendant(
            of: find.byType(ListView), matching: find.byType(Scrollable)))
        .position;

    final headerBefore = tester.getTopLeft(header);
    final searchBefore = tester.getTopLeft(search);
    final extBefore = tester.getTopLeft(extHeader);

    // 直接挪滚动位置，比手势更确定；600 之内扩展名组还在视野里
    pos.jumpTo(600);
    await tester.pumpAndSettle();

    expect(pos.pixels, 600, reason: '列表确实滚了');
    expect(tester.getTopLeft(extHeader).dy, lessThan(extBefore.dy + 1),
        reason: '列表内容整体上移');
    expect(tester.getTopLeft(header), headerBefore, reason: '筛选/添加栏固定在顶上');
    expect(tester.getTopLeft(search), searchBefore, reason: '搜索框也不跟着滚');
  });

  testWidgets('面板被压到几十像素高时退回整体滚动，不溢出', (tester) async {
    // 800x600 的窗口里音频左栏只剩 ~86 高，固定表头会顶出溢出条。
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: app,
        child: const MaterialApp(
          home: Scaffold(
            body: Column(
              children: [SizedBox(height: 86, child: TagPanel(filterOnly: true))],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    // 矮窗口里表头与搜索框仍在，只是跟着列表一起滚
    expect(find.byKey(const ValueKey('tag-expand-all')), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
  });
}
