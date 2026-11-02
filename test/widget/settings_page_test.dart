import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:asmrshelf/db/database.dart';
import 'package:asmrshelf/pages/about_page.dart';
import 'package:asmrshelf/pages/settings_page.dart';
import 'package:asmrshelf/services/data_dir_service.dart';
import 'package:asmrshelf/services/settings_service.dart';
import 'package:asmrshelf/services/subtitle_style.dart';
import 'package:asmrshelf/state/app_state.dart';
import 'package:asmrshelf/state/player_controller.dart';
import '../support/test_env.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late PlayerController player;
  late AppState app;
  late File settingsFile;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tmp = await Directory.systemTemp.createTemp('asmrshelf_settings_page');
    PathProviderPlatform.instance = FakePathProvider(
      p.join(tmp.path, 'support'),
    );
    DataDirService.instance.resetCache();
    SettingsService.instance.resetForTest();
    settingsFile = File(
      p.join(tmp.path, 'support', 'AsmrShelf', 'settings.json'),
    );
    await DatabaseManager.instance.close();
    await DatabaseManager.instance.init();
    player = PlayerController();
    app = AppState(player: player);
  });

  tearDown(() async {
    await DatabaseManager.instance.close();
    await tmp.delete(recursive: true);
  });

  /// 设置页比默认 800x600 高，放大视口让所有条目都在屏内，省掉滚动。
  void bigView(WidgetTester tester) {
    tester.view.physicalSize = const Size(1200, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  Future<void> pumpPage(WidgetTester tester) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<PlayerController>.value(value: player),
          ChangeNotifierProvider<AppState>.value(value: app),
        ],
        child: const MaterialApp(home: SettingsPage()),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 界面回调里的真实 I/O（settings.json 与 sqflite ffi）要交替让出事件循环。
  Future<void> settleIo(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();
  }

  /// 循环里连续点击时用的轻量版本：够了，但比 [settleIo] 快。
  Future<void> stepIo(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
  }

  /// 从磁盘读回 settings.json，证明改动真的落了盘，而不是只留在内存字段里。
  Future<Map<String, dynamic>> readSettings(WidgetTester tester) async {
    final text = await tester.runAsync(() => settingsFile.readAsString());
    return jsonDecode(text!) as Map<String, dynamic>;
  }

  testWidgets('主题：点「深色」后状态与 settings.json 都是 dark', (tester) async {
    bigView(tester);
    await pumpPage(tester);

    await tester.tap(find.byKey(const ValueKey<String>('theme-dark')));
    await settleIo(tester);

    expect(app.themeMode, ThemeMode.dark);
    expect((await readSettings(tester))['theme_mode'], 'dark');
  });

  testWidgets('网格列数：加到上限后按钮禁用，从 4 减到下限 2 并落盘', (tester) async {
    bigView(tester);
    await pumpPage(tester);

    expect(app.gridColumns, 4);

    await tester.tap(
      find.byKey(const ValueKey<String>('grid-columns-increase')),
    );
    await settleIo(tester);
    expect(app.gridColumns, 5);
    expect(
      find.byKey(const ValueKey<String>('grid-columns-value')),
      findsOneWidget,
    );
    // 数值与标题都跟着状态走，写盘 await 走完才重建，所以这里必须等 I/O。
    expect(find.text('5'), findsOneWidget);

    // 一路加到 10，再加就点不动了
    for (var i = 0; i < 10; i++) {
      final button = tester.widget<IconButton>(
        find.byKey(const ValueKey<String>('grid-columns-increase')),
      );
      if (button.onPressed == null) break;
      await tester.tap(
        find.byKey(const ValueKey<String>('grid-columns-increase')),
      );
      await stepIo(tester);
    }
    expect(app.gridColumns, 10);
    expect(
      tester
          .widget<IconButton>(
            find.byKey(const ValueKey<String>('grid-columns-increase')),
          )
          .onPressed,
      isNull,
      reason: '到上限后加号必须禁用',
    );

    for (var i = 0; i < 10; i++) {
      final button = tester.widget<IconButton>(
        find.byKey(const ValueKey<String>('grid-columns-decrease')),
      );
      if (button.onPressed == null) break;
      await tester.tap(
        find.byKey(const ValueKey<String>('grid-columns-decrease')),
      );
      await stepIo(tester);
    }
    expect(app.gridColumns, 2);
    expect(
      tester
          .widget<IconButton>(
            find.byKey(const ValueKey<String>('grid-columns-decrease')),
          )
          .onPressed,
      isNull,
      reason: '到下限后减号必须禁用',
    );

    await settleIo(tester);
    expect((await readSettings(tester))['grid_columns'], 2);
  });

  testWidgets('视图模式：点「列表」后状态与磁盘都是 list', (tester) async {
    bigView(tester);
    await pumpPage(tester);

    expect(app.viewMode, 'grid');
    await tester.tap(find.byKey(const ValueKey<String>('view-mode-list')));
    await settleIo(tester);

    expect(app.viewMode, 'list');
    expect((await readSettings(tester))['view_mode'], 'list');
  });

  testWidgets('关于入口：点进去能看到版本号与第三方声明', (tester) async {
    bigView(tester);
    await pumpPage(tester);

    await tester.dragUntilVisible(
      find.byKey(const ValueKey<String>('about-entry')),
      find.byType(ListView),
      const Offset(0, -200),
    );
    await tester.tap(find.byKey(const ValueKey<String>('about-entry')));
    await tester.pumpAndSettle();

    expect(find.byType(AboutPage), findsOneWidget);
    expect(find.text('AsmrShelf'), findsWidgets);
    expect(find.textContaining(AboutPage.appVersion), findsWidgets);
  });

  testWidgets('清理缩略图缓存：点击后弹提示并推进缩略图世代', (tester) async {
    bigView(tester);
    await pumpPage(tester);
    final before = app.thumbEpoch;

    await tester.tap(
      find.byKey(const ValueKey<String>('clear-thumbnail-cache')),
    );
    await settleIo(tester);

    expect(app.thumbEpoch, before + 1);
    expect(find.textContaining('缩略图缓存'), findsWidgets);
  });

  testWidgets('字幕透明度：默认自动，关掉开关后滑杆可调并落盘', (tester) async {
    bigView(tester);
    await pumpPage(tester);

    // 默认是自动：滑杆禁用，数值是按封面算出来的（这里没有封面，用默认值）
    expect(app.subtitleOpacityAuto, isTrue);
    expect(
      tester
          .widget<Slider>(
            find.byKey(const ValueKey<String>('subtitle-opacity-slider')),
          )
          .onChanged,
      isNull,
      reason: '自动模式下不该让用户再滑',
    );
    expect(
      find.text('${(SubtitleStyle.defaultInactiveOpacity * 100).round()}%'),
      findsOneWidget,
    );

    // 关掉自动，改成固定
    await tester.tap(
      find.byKey(const ValueKey<String>('subtitle-opacity-auto')),
    );
    await settleIo(tester);
    expect(app.subtitleOpacityAuto, isFalse);
    expect((await readSettings(tester))['subtitle_opacity_auto'], false);
    expect(
      tester
          .widget<Slider>(
            find.byKey(const ValueKey<String>('subtitle-opacity-slider')),
          )
          .onChanged,
      isNotNull,
      reason: '固定模式下必须能滑',
    );

    // 滑到最右 → 上限
    final slider = find.byKey(
      const ValueKey<String>('subtitle-opacity-slider'),
    );
    await tester.drag(slider, const Offset(600, 0));
    await settleIo(tester);
    expect(app.subtitleInactiveOpacity, SubtitleStyle.maxInactiveOpacity);
    expect(
      (await readSettings(tester))['subtitle_inactive_opacity'],
      SubtitleStyle.maxInactiveOpacity,
    );
    expect(find.text('80%'), findsOneWidget);
  });

  testWidgets('滑动后留原地的秒数：拖到下限后落盘', (tester) async {
    bigView(tester);
    await pumpPage(tester);
    expect(find.text('8 秒'), findsOneWidget);

    final slider = find.byKey(const ValueKey<String>('subtitle-resume-slider'));
    await tester.drag(slider, const Offset(-600, 0));
    await settleIo(tester);

    expect(app.subtitleResumeSeconds, SettingsService.minSubtitleResumeSeconds);
    expect(
      (await readSettings(tester))['subtitle_resume_seconds'],
      SettingsService.minSubtitleResumeSeconds,
    );
    expect(find.text('2 秒'), findsOneWidget);
  });

  testWidgets('DLsite 代理：保存后落盘，格式不对留在对话框', (tester) async {
    bigView(tester);
    await pumpPage(tester);

    await tester.tap(find.byKey(const ValueKey<String>('dlsite-proxy-tile')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('dlsite-proxy-input')),
      '127.0.0.1:7897',
    );
    await tester.tap(find.byKey(const ValueKey<String>('dlsite-proxy-save')));
    await settleIo(tester);

    expect(app.dlsiteProxy, 'http://127.0.0.1:7897');
    expect(
      (await readSettings(tester))['dlsite_proxy'],
      'http://127.0.0.1:7897',
    );
    expect(find.text('http://127.0.0.1:7897'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('dlsite-proxy-tile')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('dlsite-proxy-input')),
      'socks5://127.0.0.1:7897',
    );
    await tester.tap(find.byKey(const ValueKey<String>('dlsite-proxy-save')));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.textContaining('代理地址要像'), findsOneWidget);
    expect(app.dlsiteProxy, 'http://127.0.0.1:7897');
  });

  test('关于页写死的版本号与 pubspec.yaml 同步', () async {
    final pubspec = await File(
      p.join(Directory.current.path, 'pubspec.yaml'),
    ).readAsString();
    final line = pubspec
        .split('\n')
        .firstWhere((l) => l.startsWith('version:'), orElse: () => '');
    expect(line, isNotEmpty, reason: 'pubspec.yaml 里必须有 version 行');
    final value = line.split(':').last.trim();
    expect(
      value,
      '${AboutPage.appVersion}+${AboutPage.appBuildNumber}',
      reason: '改 pubspec.yaml 的 version 必须同步 AboutPage 的常量',
    );
  });
}
