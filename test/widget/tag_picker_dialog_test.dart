import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:asmrshelf/db/database.dart';
import 'package:asmrshelf/db/tag_dao.dart';
import 'package:asmrshelf/services/data_dir_service.dart';
import 'package:asmrshelf/services/settings_service.dart';
import 'package:asmrshelf/state/app_state.dart';
import 'package:asmrshelf/state/player_controller.dart';
import 'package:asmrshelf/theme/app_theme.dart';
import 'package:asmrshelf/widgets/tag_picker_dialog.dart';
import '../support/test_env.dart';


/// 标签选择对话框：按命名空间分组、标题可收起、搜索时忽略折叠、已选计数。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late AppState app;
  late PlayerController player;
  late TagDao tags;
  late Tag styleA;
  late Tag styleB;
  late Tag plain;
  List<Tag>? returned;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tmp = await Directory.systemTemp.createTemp('asmrshelf_tag_picker');
    PathProviderPlatform.instance =
        FakePathProvider(p.join(tmp.path, 'support'));
    DataDirService.instance.resetCache();
    SettingsService.instance.resetForTest();
    await DatabaseManager.instance.close();
    await DatabaseManager.instance.init();
    await SettingsService.instance.init();
    tags = TagDao(DatabaseManager.instance.db);
    player = PlayerController();
    app = AppState(player: player);
    await app.init();

    // 真实 I/O 全部放在 setUp：widget 测试体在假时钟里等真实数据库会卡住。
    styleA = await app.createTag('风景', namespace: '风格');
    styleB = await app.createTag('人像', namespace: '风格');
    plain = await app.createTag('猫咪');
    // createTag 会把空命名空间归成 'general'，所以真正的「无命名空间」直接落库。
    await tags.insert(Tag(name: '散标签', namespace: '', color: '#89b4fa'));
    await app.loadTags();
    returned = null;
  });

  tearDown(() async {
    await DatabaseManager.instance.close();
    await tmp.delete(recursive: true);
  });

  /// 打开对话框：真点按钮调 showTagPickerDialog，跟用户操作一致。
  Future<void> openPicker(WidgetTester tester, {Set<int>? selected}) async {
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: app,
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (ctx) => Center(
                child: ElevatedButton(
                  key: const ValueKey('open-picker'),
                  onPressed: () async {
                    returned = await showTagPickerDialog(ctx,
                        selectedTagIds: selected);
                  },
                  child: const Text('打开'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('open-picker')));
    await tester.pumpAndSettle();
  }

  Finder tagRow(Tag t) => find.byKey(ValueKey('picker-tag-${t.id}'));

  testWidgets('按命名空间分组，点标题收起、再点展开', (tester) async {
    await openPicker(tester);

    expect(find.byKey(const ValueKey('picker-ns-header-风格')), findsOneWidget);
    expect(find.byKey(const ValueKey('picker-ns-header-')), findsOneWidget,
        reason: '没有命名空间的标签归到空串这一组');
    expect(find.text('散标签'), findsOneWidget);
    expect(find.text('风格'), findsOneWidget);
    expect(find.text('类型'), findsNothing, reason: '规则标签不进选择对话框');
    expect(tagRow(styleA), findsOneWidget);
    expect(tagRow(plain), findsOneWidget);

    // 收起「风格」这一组：只影响这一组，无命名空间组照旧
    await tester.tap(find.byKey(const ValueKey('picker-ns-header-风格')));
    await tester.pumpAndSettle();

    expect(tagRow(styleA), findsNothing);
    expect(tagRow(styleB), findsNothing);
    expect(tagRow(plain), findsOneWidget);
    expect(app.isNamespaceCollapsed('风格'), isTrue,
        reason: '折叠状态与左侧标签栏共用一份');

    // 再点一次展开
    await tester.tap(find.byKey(const ValueKey('picker-ns-header-风格')));
    await tester.pumpAndSettle();
    expect(tagRow(styleA), findsOneWidget);
    expect(tagRow(styleB), findsOneWidget);
  });

  testWidgets('搜索时忽略折叠状态，命中的标签一定看得见', (tester) async {
    await openPicker(tester);

    await tester.tap(find.byKey(const ValueKey('picker-ns-header-风格')));
    await tester.pumpAndSettle();
    expect(tagRow(styleA), findsNothing);

    await tester.enterText(find.byType(TextField), '风景');
    await tester.pumpAndSettle();

    expect(tagRow(styleA), findsOneWidget, reason: '搜到的一定要露出来');
    expect(tagRow(plain), findsNothing, reason: '没命中的不显示');
    expect(find.byKey(const ValueKey('picker-ns-header-风格')), findsOneWidget);

    // 搜索状态下标题不再响应点击（免得手滑把结果收起来）
    await tester.tap(find.byKey(const ValueKey('picker-ns-header-风格')),
        warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(tagRow(styleA), findsOneWidget);
  });

  testWidgets('已选计数与确定返回', (tester) async {
    await openPicker(tester, selected: {styleA.id!});

    expect(find.text('已选 1'), findsOneWidget);
    expect(tagRow(styleA), findsOneWidget);

    await tester.tap(tagRow(plain));
    await tester.pumpAndSettle();
    expect(find.text('已选 2'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, '确定'));
    await tester.pumpAndSettle();

    expect(returned, isNotNull);
    expect(returned!.map((t) => t.id).toSet(), {styleA.id, plain.id});
  });

  testWidgets('取消返回 null，浅色主题下对话框不是深色面板', (tester) async {
    await openPicker(tester);

    final dialog = tester.widget<AlertDialog>(find.byType(AlertDialog));
    expect(dialog.backgroundColor, AppColors.panelLight,
        reason: '浅色主题下对话框底色要走 panelOf');

    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();
    expect(returned, isNull);
  });
}
