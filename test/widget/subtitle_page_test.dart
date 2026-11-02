import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asmrshelf/db/track_dao.dart';
import 'package:asmrshelf/pages/subtitle_page.dart';
import 'package:asmrshelf/services/data_dir_service.dart';
import 'package:asmrshelf/services/settings_service.dart';
import 'package:asmrshelf/services/subtitle_style.dart';
import 'package:asmrshelf/state/app_state.dart';
import 'package:asmrshelf/state/player_controller.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';

import '../support/test_env.dart';

/// 字幕页的几件事：当前句停在视口正中、不在本句的更透明（用户固定或者按封面算）、
/// 用户滑动之后先留住视线再恢复跟随。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late PlayerController player;
  late AppState app;
  late TrackItem track;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('asmrshelf_subtitle_page');
    PathProviderPlatform.instance =
        FakePathProvider(p.join(tmp.path, 'support'));
    DataDirService.instance.resetCache();
    SettingsService.instance.resetForTest();
    SubtitleStyle.clearLuminanceCache();
    // 8 句，每句 4 秒：第 n 句从 (n-1)*4 秒开始
    final srt = StringBuffer();
    for (var i = 1; i <= 8; i++) {
      srt.writeln('$i\n${_ts((i - 1) * 4)} --> ${_ts(i * 4)}\n第 $i 句\n');
    }
    final file = await File('${tmp.path}/a.srt').writeAsString(srt.toString());
    track = TrackItem(
      id: 1,
      path: '${tmp.path}/a.mp3',
      filename: 'a.mp3',
      subtitlePath: file.path,
      addedAt: 1,
    );
    player = PlayerController();
    app = AppState(player: player);
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  Future<void> pumpPage(WidgetTester tester, Duration position) async {
    player.debugSeedQueue([track]);
    player.debugSetPosition(position);
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<PlayerController>.value(value: player),
        ChangeNotifierProvider<AppState>.value(value: app),
      ],
      child: const MaterialApp(home: SubtitlePage()),
    ));
    await tester.pumpAndSettle();
  }

  double offsetOf(WidgetTester tester) =>
      tester.widget<ListView>(find.byType(ListView)).controller!.offset;

  testWidgets('正在播放的这一句停在视口正中', (tester) async {
    // 第 6 句（20 秒起）：旧实现把它停在视口底部
    await pumpPage(tester, const Duration(seconds: 20));
    final viewport = tester.getRect(find.byType(ListView));
    final active = tester.getRect(find.text('第 6 句'));
    expect(active.center.dy, closeTo(viewport.center.dy, 1.0));
  });

  testWidgets('不在本句的字幕更透明', (tester) async {
    await pumpPage(tester, const Duration(seconds: 20));
    final active = tester.widget<Text>(find.text('第 6 句')).style!;
    final other = tester.widget<Text>(find.text('第 5 句')).style!;
    expect(active.color!.a, 1.0);
    expect(other.color!.a, closeTo(SubtitleStyle.defaultInactiveOpacity, 1e-6),
        reason: '没有封面时用默认透明度');
  });

  testWidgets('固定模式下用用户自己设的透明度', (tester) async {
    await pumpPage(tester, const Duration(seconds: 20));
    // 设置项的写入要走真实 IO，得让出事件循环
    await tester.runAsync(() async {
      await app.setSubtitleInactiveOpacity(0.55);
      await app.setSubtitleOpacityAuto(false);
    });
    await tester.pumpAndSettle();

    final other = tester.widget<Text>(find.text('第 5 句')).style!;
    expect(other.color!.a, closeTo(0.55, 1e-6));
  });

  testWidgets('自动模式按封面明暗算：亮封面下非当前句更实', (tester) async {
    final cover = (await tester
        .runAsync(() => _solidPng('${tmp.path}/cover.png', 0xFFFFFFFF)))!;
    track = track.copyWith(coverPath: cover.path);
    // 先把亮度读进缓存，页面第一帧就能拿到值
    await tester.runAsync(() => SubtitleStyle.luminanceOfCover(cover.path));
    await pumpPage(tester, const Duration(seconds: 20));
    await tester.pump();

    final expected = SubtitleStyle.autoInactiveOpacity(1.0);
    expect(expected, greaterThan(SubtitleStyle.defaultInactiveOpacity),
        reason: '不然这条用例证明不了自动值真的比默认值实');
    final other = tester.widget<Text>(find.text('第 5 句')).style!;
    expect(other.color!.a, closeTo(expected, 0.02));
  });

  testWidgets('滑动之后先留住用户的视线，过了保留时间再把当前句拉回中间',
      (tester) async {
    await pumpPage(tester, const Duration(seconds: 20));
    final viewport = tester.getRect(find.byType(ListView));

    // 用户往上拖：内容下移，回头看更早的句子
    await tester.drag(find.byType(ListView), const Offset(0, 200));
    await tester.pumpAndSettle();
    final dragged = offsetOf(tester);

    // 当前句换了一句，但保留时间内不能自己跑回去（旧实现 3 秒就恢复跟随）
    player.debugSetPosition(const Duration(seconds: 24));
    await tester.pump(const Duration(seconds: 5));
    await _settleScroll(tester);
    expect(offsetOf(tester), closeTo(dragged, 0.5),
        reason: '保留时间内不该自动滚走');

    // 过了保留时间：当前句回到视口正中
    await tester.pump(const Duration(seconds: 4));
    await _settleScroll(tester);
    expect(tester.getRect(find.text('第 7 句')).center.dy,
        closeTo(viewport.center.dy, 1.0));
  });

  testWidgets('保留时间可以在设置里调小：3 秒就恢复跟随', (tester) async {
    await pumpPage(tester, const Duration(seconds: 20));
    await tester.runAsync(() => app.setSubtitleResumeSeconds(3));
    await tester.pumpAndSettle();
    final viewport = tester.getRect(find.byType(ListView));

    await tester.drag(find.byType(ListView), const Offset(0, 200));
    await tester.pumpAndSettle();
    final dragged = offsetOf(tester);

    player.debugSetPosition(const Duration(seconds: 24));
    await tester.pump(const Duration(seconds: 2));
    await _settleScroll(tester);
    expect(offsetOf(tester), closeTo(dragged, 0.5), reason: '还没到 3 秒');

    await tester.pump(const Duration(seconds: 2));
    await _settleScroll(tester);
    expect(tester.getRect(find.text('第 7 句')).center.dy,
        closeTo(viewport.center.dy, 1.0));
  });
}

/// 画一张纯色 PNG 写到磁盘，用来当封面。
Future<File> _solidPng(String path, int argb) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawRect(
    const ui.Rect.fromLTWH(0, 0, 16, 16),
    ui.Paint()..color = ui.Color(argb),
  );
  final image = await recorder.endRecording().toImage(16, 16);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return File(path).writeAsBytes(data!.buffer.asUint8List());
}

/// 让自动滚动的那段动画跑完（动画的第一帧只是起点，得再来一帧）。
Future<void> _settleScroll(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
}

String _ts(int seconds) {
  final h = (seconds ~/ 3600).toString().padLeft(2, '0');
  final m = ((seconds % 3600) ~/ 60).toString().padLeft(2, '0');
  final s = (seconds % 60).toString().padLeft(2, '0');
  return '$h:$m:$s,000';
}
