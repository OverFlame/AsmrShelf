import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:asmrshelf/utils/crop_math.dart';
import 'package:asmrshelf/widgets/cover_crop_editor.dart';

/// 1x1 的合法 PNG，只为让 `Image.file` 有东西可解。
const String _tinyPngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg==';

/// 裁剪编辑器的真实手势验收（BUILD_GUIDE 第 21.3、21.4 节）。
///
/// 全程抓真手柄拖动，断言归一化结果，而不是直接调 [CropMath]。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late String imagePath;
  late Rect? captured;
  late bool closed;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('asmrshelf_crop');
    imagePath = p.join(tmp.path, 'cover.png');
    await File(imagePath).writeAsBytes(base64Decode(_tinyPngBase64));
    captured = null;
    closed = false;
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  /// 打开编辑器，把返回值记在闭包里。
  Future<void> open(
    WidgetTester tester, {
    Rect? initialCrop,
    Size imageSize = const Size(200, 100),
  }) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () async {
                captured = await CoverCropEditor.show(
                  context,
                  imagePath: imagePath,
                  imageSize: imageSize,
                  initialCrop: initialCrop,
                );
                closed = true;
              },
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
  }

  String numbers(WidgetTester tester) =>
      tester.widget<Text>(find.byKey(const ValueKey('crop-numbers'))).data!;

  testWidgets('打开时是整幅，确定后返回整幅', (tester) async {
    await open(tester);
    expect(numbers(tester), contains('整幅'));

    await tester.tap(find.byKey(const ValueKey('crop-confirm')));
    await tester.pumpAndSettle();

    expect(closed, isTrue);
    expect(captured, isNotNull);
    expect(CropMath.isFull(captured!), isTrue, reason: '整幅即「不裁」');
    expect(CropMath.encode(captured!), isNull);
  });

  testWidgets('拖右下角手柄把框改小，确定后写回小框', (tester) async {
    await open(tester);
    expect(find.byKey(const ValueKey('crop-handle-bottomRight')), findsOneWidget);

    final corner =
        tester.getCenter(find.byKey(const ValueKey('crop-handle-bottomRight')));
    await tester.dragFrom(corner - const Offset(4, 4), const Offset(-120, -60));
    await tester.pumpAndSettle();

    expect(numbers(tester), isNot(contains('整幅')), reason: '拖动后不再是整幅');

    await tester.tap(find.byKey(const ValueKey('crop-confirm')));
    await tester.pumpAndSettle();

    expect(captured, isNotNull);
    expect(captured!.right, lessThan(1.0));
    expect(captured!.bottom, lessThan(1.0));
    expect(captured!.left, 0.0);
    expect(captured!.top, 0.0);
  });

  testWidgets('框内拖动只平移，尺寸不变', (tester) async {
    await open(tester, initialCrop: const Rect.fromLTRB(0.2, 0.2, 0.8, 0.8));
    expect(numbers(tester), contains('0.2,0.2,0.8,0.8'));

    await tester.drag(
        find.byKey(const ValueKey('crop-surface')), const Offset(20, 10));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('crop-confirm')));
    await tester.pumpAndSettle();

    expect(captured, isNotNull);
    expect(captured!.width, closeTo(0.6, 0.001), reason: '平移不改尺寸');
    expect(captured!.height, closeTo(0.6, 0.001));
    expect(captured!.left, greaterThan(0.2), reason: '框向右下移动了');
  });

  testWidgets('恢复默认把框还原成整幅', (tester) async {
    await open(tester, initialCrop: const Rect.fromLTRB(0.1, 0.1, 0.5, 0.5));
    expect(numbers(tester), contains('0.1,0.1,0.5,0.5'));

    await tester.tap(find.byKey(const ValueKey('crop-reset')));
    await tester.pumpAndSettle();

    expect(numbers(tester), contains('整幅'));
  });

  testWidgets('取消返回 null', (tester) async {
    await open(tester, initialCrop: const Rect.fromLTRB(0.1, 0.1, 0.5, 0.5));

    await tester.tap(find.byKey(const ValueKey('crop-cancel')));
    await tester.pumpAndSettle();

    expect(closed, isTrue);
    expect(captured, isNull);
  });
}
