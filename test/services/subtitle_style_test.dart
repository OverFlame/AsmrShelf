import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:asmrshelf/services/subtitle_style.dart';

/// 字幕页的透明度：用户能固定，也能按封面的明暗自动算。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('封面亮度', () {
    test('纯白是 1，纯黑是 0，中灰在中间', () {
      expect(SubtitleStyle.luminanceOfRgba(_pixels([0xFF, 0xFF, 0xFF, 0xFF])),
          closeTo(1.0, 1e-6));
      expect(SubtitleStyle.luminanceOfRgba(_pixels([0, 0, 0, 0xFF])), 0.0);
      expect(SubtitleStyle.luminanceOfRgba(_pixels([128, 128, 128, 0xFF])),
          closeTo(0.502, 0.002));
    });

    test('透明像素按本页的深色底折半，不把它当成亮色', () {
      // 全透明白：底下是深色底，对亮度的贡献是 0
      expect(SubtitleStyle.luminanceOfRgba(_pixels([0xFF, 0xFF, 0xFF, 0x00])),
          0.0);
      // 半透明白：算一半
      expect(SubtitleStyle.luminanceOfRgba(_pixels([0xFF, 0xFF, 0xFF, 0x80])),
          closeTo(0.502, 0.002));
    });

    test('凑不满一个像素的字节按 0 算', () {
      expect(SubtitleStyle.luminanceOfRgba(Uint8List.fromList([1, 2, 3])), 0.0);
      expect(SubtitleStyle.luminanceOfRgba(Uint8List(0)), 0.0);
    });
  });

  group('自动透明度', () {
    test('封面越亮，非当前句越实，整条曲线单调', () {
      final darkest = SubtitleStyle.autoInactiveOpacity(0);
      final middle = SubtitleStyle.autoInactiveOpacity(0.5);
      final brightest = SubtitleStyle.autoInactiveOpacity(1);
      expect(darkest, closeTo(SubtitleStyle.defaultInactiveOpacity, 1e-6),
          reason: '全黑封面就是本页原来的默认值');
      expect(middle, greaterThan(darkest));
      expect(brightest, greaterThan(middle));

      var last = -1.0;
      for (var i = 0; i <= 100; i++) {
        final v = SubtitleStyle.autoInactiveOpacity(i / 100);
        expect(v, greaterThanOrEqualTo(last), reason: '亮度 $i 处出现回落');
        last = v;
      }
    });

    test('背景被黑色遮罩压过，所以亮封面要的透明度明显更高', () {
      // α = 目标亮度差 / (1 - 亮度)，亮度 = 封面亮度 × (1 - 遮罩)
      final expected = SubtitleStyle.targetContrast /
          (1 - 1.0 * (1 - SubtitleStyle.backgroundDim));
      expect(SubtitleStyle.autoInactiveOpacity(1.0), closeTo(expected, 1e-6));
    });

    test('没有封面或者输入不成数时回落到默认值', () {
      expect(SubtitleStyle.autoInactiveOpacity(null),
          SubtitleStyle.defaultInactiveOpacity);
      expect(SubtitleStyle.autoInactiveOpacity(double.nan),
          SubtitleStyle.defaultInactiveOpacity);
      expect(SubtitleStyle.autoInactiveOpacity(double.infinity),
          SubtitleStyle.defaultInactiveOpacity);
    });

    test('结果永远落在可用区间里，越界的输入也不例外', () {
      for (final v in [-1.0, 0.0, 0.25, 0.5, 1.0, 2.0]) {
        final a = SubtitleStyle.autoInactiveOpacity(v);
        expect(a, greaterThanOrEqualTo(SubtitleStyle.minInactiveOpacity));
        expect(a, lessThanOrEqualTo(SubtitleStyle.maxInactiveOpacity));
      }
    });

    test('用户设的固定值会被钳进同一区间', () {
      expect(SubtitleStyle.clampInactiveOpacity(0.5), 0.5);
      expect(SubtitleStyle.clampInactiveOpacity(0.0),
          SubtitleStyle.minInactiveOpacity);
      expect(SubtitleStyle.clampInactiveOpacity(9.0),
          SubtitleStyle.maxInactiveOpacity);
    });
  });

  group('读封面文件', () {
    late Directory tmp;

    setUp(() async {
      SubtitleStyle.clearLuminanceCache();
      tmp = await Directory.systemTemp.createTemp('asmrshelf_style');
    });

    tearDown(() async {
      await tmp.delete(recursive: true);
    });

    test('白图接近 1，黑图接近 0，中灰在中间', () async {
      final white = await _solidPng('${tmp.path}/white.png', 0xFFFFFFFF);
      final black = await _solidPng('${tmp.path}/black.png', 0xFF000000);
      final gray = await _solidPng('${tmp.path}/gray.png', 0xFF808080);
      expect(await SubtitleStyle.luminanceOfFile(white.path),
          closeTo(1.0, 0.02));
      expect(await SubtitleStyle.luminanceOfFile(black.path), closeTo(0.0, 0.02));
      expect(await SubtitleStyle.luminanceOfFile(gray.path),
          closeTo(0.502, 0.02));
    });

    test('文件不在、或者根本不是图片，都返回 null', () async {
      expect(await SubtitleStyle.luminanceOfFile('${tmp.path}/nope.png'),
          isNull);
      final bad = await File('${tmp.path}/bad.png').writeAsString('not an image');
      expect(await SubtitleStyle.luminanceOfFile(bad.path), isNull);
    });

    test('同一张封面只解码一次：原文件删掉之后还拿得到值', () async {
      final f = await _solidPng('${tmp.path}/cached.png', 0xFFFFFFFF);
      final first = await SubtitleStyle.luminanceOfCover(f.path);
      expect(first, isNotNull);
      await f.delete();
      expect(await SubtitleStyle.luminanceOfCover(f.path), first);
    });

    test('空路径直接回 null，不去碰文件系统', () async {
      expect(await SubtitleStyle.luminanceOfCover(''), isNull);
    });
  });
}

Uint8List _pixels(List<int> rgba) => Uint8List.fromList(rgba);

/// 画一张纯色 PNG 写到磁盘，用来验证解码那一段。
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
