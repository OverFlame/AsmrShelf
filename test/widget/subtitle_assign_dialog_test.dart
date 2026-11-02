import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import 'package:asmrshelf/db/database.dart';
import 'package:asmrshelf/db/media_dao.dart';
import 'package:asmrshelf/services/data_dir_service.dart';
import 'package:asmrshelf/services/settings_service.dart';
import 'package:asmrshelf/state/app_state.dart';
import 'package:asmrshelf/state/player_controller.dart';
import 'package:asmrshelf/widgets/subtitle_assign_dialog.dart';
import '../support/test_env.dart';

/// 一个可变标志，用来观察对话框是否已经关闭。
class _Flag {
  bool value = false;
}


/// 字幕归属对话框的真实点击验收（BUILD_GUIDE 第 23.6 节）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late Database db;
  late MediaDao mediaDao;
  late PlayerController player;
  late AppState app;
  late int audioId;
  late int subA;
  late int subB;
  late int subFree1;
  late int subFree2;

  Future<int> addRow(Map<String, Object?> row) => mediaDao.insertRow(row);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tmp = await Directory.systemTemp.createTemp('asmrshelf_subtitle_dialog');
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

    audioId = await addRow({
      'path': p.join(dir, 'a.mp3'),
      'filename': 'a.mp3',
      'media_type': 'audio',
      'ext': '.mp3',
      'name_lower': 'a.mp3',
      'added_at': 0,
    });

    Future<int> subtitle(String name,
        {int? audio, bool isDefault = false}) async {
      return addRow({
        'path': p.join(dir, name),
        'filename': name,
        'media_type': 'subtitle',
        'ext': p.extension(name),
        'name_lower': name.toLowerCase(),
        'added_at': 0,
        'subtitle_of': ?audio,
        'is_default_subtitle': isDefault ? 1 : 0,
      });
    }

    subA = await subtitle('a.zh.srt', audio: audioId, isDefault: true);
    subB = await subtitle('a.jp.srt', audio: audioId);
    subFree1 = await subtitle('b.zh.srt');
    subFree2 = await subtitle('b.jp.srt');
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

  Future<void> settleIo(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump();
    }
    await tester.pump();
  }

  Future<void> openDialog(WidgetTester tester, _Flag closed) async {
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
                  await SubtitleAssignDialog.show(
                    ctx,
                    state: app,
                    audioId: audioId,
                    audioLabel: 'a.mp3',
                  );
                  closed.value = true;
                },
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

  Future<int?> storedAudioOf(WidgetTester tester, int subtitleId) async {
    final rows = await tester.runAsync(() => db.query('media',
        columns: const ['subtitle_of'],
        where: 'id = ?',
        whereArgs: [subtitleId]));
    return rows!.single['subtitle_of'] as int?;
  }

  testWidgets('打开列出本曲名下的字幕与未归属字幕', (tester) async {
    bigView(tester);
    await openDialog(tester, _Flag());

    expect(find.byKey(const ValueKey('subtitle-attached-list')), findsOneWidget);
    expect(find.byKey(ValueKey('subtitle-row-$subA')), findsOneWidget);
    expect(find.byKey(ValueKey('subtitle-row-$subB')), findsOneWidget);
    expect(
        find.byKey(const ValueKey('subtitle-unassigned-list')), findsOneWidget);
    expect(find.byKey(ValueKey('subtitle-unassigned-$subFree1')), findsOneWidget);
    expect(find.byKey(ValueKey('subtitle-unassigned-$subFree2')), findsOneWidget);
    expect(find.text('2 条'), findsNWidgets(2), reason: '两边各两条');
  });

  testWidgets('设为默认后落库，按钮随之禁用', (tester) async {
    bigView(tester);
    await openDialog(tester, _Flag());

    // 已经是默认的那条，按钮不可点
    final before = tester
        .widget<TextButton>(find.byKey(ValueKey('subtitle-default-$subA')));
    expect(before.onPressed, isNull);

    await tester.tap(find.byKey(ValueKey('subtitle-default-$subB')));
    await tester.pump();
    await settleIo(tester);

    final def = await tester
        .runAsync(() => app.defaultSubtitleFor(audioId));
    expect(def!.id, subB);

    final after = tester
        .widget<TextButton>(find.byKey(ValueKey('subtitle-default-$subB')));
    expect(after.onPressed, isNull, reason: '已默认就不再重复点');

    final old = tester
        .widget<TextButton>(find.byKey(ValueKey('subtitle-default-$subA')));
    expect(old.onPressed, isNotNull, reason: '原默认项恢复可点');
  });

  testWidgets('未归属字幕点归属后挪到本曲名下', (tester) async {
    bigView(tester);
    await openDialog(tester, _Flag());

    await tester.tap(find.byKey(ValueKey('subtitle-attach-$subFree1')));
    await tester.pump();
    await settleIo(tester);

    expect(await storedAudioOf(tester, subFree1), audioId);
    expect(find.byKey(ValueKey('subtitle-row-$subFree1')), findsOneWidget);
    expect(find.byKey(ValueKey('subtitle-unassigned-$subFree1')), findsNothing);
    expect(find.byKey(ValueKey('subtitle-unassigned-$subFree2')), findsOneWidget);
  });

  testWidgets('解除归属后回到未归属列表', (tester) async {
    bigView(tester);
    await openDialog(tester, _Flag());

    await tester.tap(find.byKey(ValueKey('subtitle-detach-$subB')));
    await tester.pump();
    await settleIo(tester);

    expect(await storedAudioOf(tester, subB), isNull);
    expect(find.byKey(ValueKey('subtitle-row-$subB')), findsNothing);
    expect(find.byKey(ValueKey('subtitle-unassigned-$subB')), findsOneWidget);
  });

  testWidgets('关闭按钮关掉对话框', (tester) async {
    bigView(tester);
    final closed = _Flag();
    await openDialog(tester, closed);

    await tester.tap(find.byKey(const ValueKey('subtitle-close')));
    await tester.pumpAndSettle();

    expect(closed.value, isTrue);
    expect(find.byType(AlertDialog), findsNothing);
  });
}
