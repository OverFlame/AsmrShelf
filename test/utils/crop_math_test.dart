import 'dart:ui' show Offset, Rect, Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:asmrshelf/utils/crop_math.dart';

/// 归一化矩形的近似断言：比较到小数点后 6 位
void expectRect(Rect actual, Rect expected, {double tolerance = 1e-6}) {
  expect(actual.left, closeTo(expected.left, tolerance), reason: 'left');
  expect(actual.top, closeTo(expected.top, tolerance), reason: 'top');
  expect(actual.right, closeTo(expected.right, tolerance), reason: 'right');
  expect(actual.bottom, closeTo(expected.bottom, tolerance), reason: 'bottom');
}

void main() {
  group('像素换算', () {
    test('归一化 → 像素 → 归一化 往返一致', () {
      const crop = Rect.fromLTRB(0.25, 0.5, 0.75, 1.0);
      const size = Size(400, 200);
      final pixels = CropMath.toPixels(crop, size);
      expectRect(pixels, const Rect.fromLTRB(100, 100, 300, 200));
      expectRect(CropMath.fromPixels(pixels, size), crop);
    });

    test('图片尺寸为 0 时不产生 NaN', () {
      final crop = CropMath.fromPixels(
          const Rect.fromLTRB(0, 0, 10, 10), Size.zero);
      expectRect(crop, CropMath.full);
      expect(crop.left.isNaN, isFalse);
    });

    test('fitRect 等比居中', () {
      // 1000x500 放进 500x500：缩放 0.5，上下各留 125
      final rect = CropMath.fitRect(const Size(1000, 500), const Size(500, 500));
      expectRect(rect, const Rect.fromLTWH(0, 125, 500, 250));
    });

    test('fitRect 遇到零尺寸容器不抛异常', () {
      final rect = CropMath.fitRect(const Size(100, 100), Size.zero);
      expect(rect.width, 0);
      expect(rect.height, 0);
    });
  });

  group('存储编解码', () {
    test('encode 去掉多余的 0，decode 读回来', () {
      final text = CropMath.encode(const Rect.fromLTRB(0.05, 0.1, 0.95, 0.6));
      expect(text, '0.05,0.1,0.95,0.6');
      expectRect(CropMath.decode(text)!, const Rect.fromLTRB(0.05, 0.1, 0.95, 0.6));
    });

    test('整幅图与 null 都编码成 null（等于不裁）', () {
      expect(CropMath.encode(CropMath.full), isNull);
      expect(CropMath.encode(const Rect.fromLTRB(-0.5, -0.5, 1.5, 1.5)), isNull);
      expect(CropMath.encode(null), isNull);
      expect(CropMath.isFull(null), isTrue);
      expect(CropMath.isFull(const Rect.fromLTRB(0, 0, 1, 1)), isTrue);
      expect(CropMath.isFull(const Rect.fromLTRB(0, 0, 1, 0.5)), isFalse);
    });

    test('空串、NULL、坏格式都解成 null', () {
      expect(CropMath.decode(null), isNull);
      expect(CropMath.decode(''), isNull);
      expect(CropMath.decode('   '), isNull);
      expect(CropMath.decode('1,2,3'), isNull);
      expect(CropMath.decode('a,b,c,d'), isNull);
      expect(CropMath.decode('0,0,1,1,2'), isNull);
    });

    test('decode 会把反向框规范化', () {
      expectRect(CropMath.decode('0.8,0.9,0.2,0.1')!,
          const Rect.fromLTRB(0.2, 0.1, 0.8, 0.9));
    });

    test('decode 会把越界框收回原图', () {
      // 高 1.25、宽 1.0 的框比整幅还大 → 收成整幅
      expectRect(CropMath.decode('-0.5,0.25,0.5,1.5')!, CropMath.full);
      // 只越左边界：尺寸保留，平移回来
      expectRect(CropMath.decode('-0.2,0.1,0.3,0.6')!,
          const Rect.fromLTRB(0.0, 0.1, 0.5, 0.6));
    });
  });

  group('边界约束', () {
    test('整体超出左边缘时向内收，尺寸不变', () {
      final result = CropMath.clampUnit(const Rect.fromLTRB(-0.2, -0.3, 0.3, 0.2));
      expectRect(result, const Rect.fromLTRB(0, 0, 0.5, 0.5));
      expect(result.width, closeTo(0.5, 1e-9));
      expect(result.height, closeTo(0.5, 1e-9));
    });

    test('整体超出右边缘时向内收', () {
      final result = CropMath.clampUnit(const Rect.fromLTRB(0.8, 0.8, 1.4, 1.4));
      expectRect(result, const Rect.fromLTRB(0.4, 0.4, 1.0, 1.0));
    });

    test('比原图还大时夹到整幅', () {
      final result = CropMath.clampUnit(const Rect.fromLTRB(-2, -2, 3, 3));
      expectRect(result, CropMath.full);
    });

    test('零尺寸框不会出现 NaN', () {
      final result = CropMath.clampUnit(const Rect.fromLTWH(0.5, 0.5, 0, 0));
      expect(result.left.isNaN, isFalse);
      expect(result.width, 0);
      expect(result.top, closeTo(0.5, 1e-9));
    });
  });

  group('整框平移', () {
    test('移动后尺寸不变', () {
      final moved = CropMath.move(
          const Rect.fromLTRB(0.1, 0.1, 0.4, 0.4), const Offset(0.2, 0.3));
      expectRect(moved, const Rect.fromLTRB(0.3, 0.4, 0.6, 0.7));
    });

    test('撞到边缘即停，尺寸不缩水', () {
      final moved = CropMath.move(
          const Rect.fromLTRB(0.1, 0.1, 0.4, 0.4), const Offset(-5, 5));
      expectRect(moved, const Rect.fromLTRB(0.0, 0.7, 0.3, 1.0));
      expect(moved.width, closeTo(0.3, 1e-9));
      expect(moved.height, closeTo(0.3, 1e-9));
    });
  });

  group('锁比例扩框', () {
    test('取能覆盖原框的最小该比例矩形，中心不变', () {
      final result =
          CropMath.expandToAspect(const Rect.fromLTRB(0.2, 0.2, 0.6, 0.6), 2);
      expectRect(result, const Rect.fromLTRB(0.0, 0.2, 0.8, 0.6));
      expect(result.center.dx, closeTo(0.4, 1e-9));
      expect(result.center.dy, closeTo(0.4, 1e-9));
      expect(result.width / result.height, closeTo(2, 1e-9));
    });

    test('超出原图向内收，仍保持比例', () {
      final result =
          CropMath.expandToAspect(const Rect.fromLTRB(0.9, 0.9, 1.0, 1.0), 3);
      expectRect(result, const Rect.fromLTRB(0.7, 0.9, 1.0, 1.0));
      expect(result.width / result.height, closeTo(3, 1e-9));
    });

    test('比例放不进单位方块时等比缩小到刚好容纳', () {
      final result = CropMath.expandToAspect(CropMath.full, 4);
      expectRect(result, const Rect.fromLTRB(0, 0.375, 1, 0.625));
      expect(result.width / result.height, closeTo(4, 1e-9));
    });

    test('非法比例退回原框', () {
      final result =
          CropMath.expandToAspect(const Rect.fromLTRB(0.1, 0.1, 0.5, 0.5), 0);
      expectRect(result, const Rect.fromLTRB(0.1, 0.1, 0.5, 0.5));
    });

    test('零面积框给出居中的最大该比例框', () {
      final result =
          CropMath.expandToAspect(const Rect.fromLTWH(0.5, 0.5, 0, 0), 1);
      expect(result.width, closeTo(1, 1e-9));
      expect(result.height, closeTo(1, 1e-9));
      expectRect(result, CropMath.full);
    });
  });

  group('手柄缩放', () {
    test('拖右边把框拉大', () {
      final result = CropMath.resize(
        const Rect.fromLTRB(0.1, 0.2, 0.5, 0.6),
        CropHandle.right,
        const Offset(0.2, 0),
        minWidth: 0.05,
        minHeight: 0.05,
      );
      expectRect(result, const Rect.fromLTRB(0.1, 0.2, 0.7, 0.6));
    });

    test('最小尺寸：拖过头也留得住', () {
      final result = CropMath.resize(
        const Rect.fromLTRB(0.1, 0.2, 0.5, 0.6),
        CropHandle.right,
        const Offset(-100, 0),
        minWidth: 0.1,
        minHeight: 0.05,
      );
      expect(result.width, closeTo(0.1, 1e-9));
      expect(result.left, closeTo(0.1, 1e-9));
      expect(result.right, closeTo(0.2, 1e-9));
    });

    test('扩框上限生效', () {
      final result = CropMath.resize(
        const Rect.fromLTRB(0.1, 0.2, 0.2, 0.6),
        CropHandle.right,
        const Offset(100, 0),
        maxWidth: 0.5,
      );
      expect(result.width, closeTo(0.5, 1e-9));
      expect(result.right, closeTo(0.6, 1e-9));
    });

    test('拖到哪里都不会越界', () {
      final result = CropMath.resize(
        CropMath.full,
        CropHandle.topLeft,
        const Offset(-3, -3),
        minWidth: 0.05,
        minHeight: 0.05,
      );
      expect(result.left, greaterThanOrEqualTo(-1e-9));
      expect(result.top, greaterThanOrEqualTo(-1e-9));
      expect(result.right, lessThanOrEqualTo(1 + 1e-9));
      expect(result.bottom, lessThanOrEqualTo(1 + 1e-9));
    });

    test('锁比例缩放：对角拖动时宽高比不变，锚点在对角', () {
      final result = CropMath.resize(
        const Rect.fromLTRB(0.1, 0.2, 0.3, 0.4),
        CropHandle.bottomRight,
        const Offset(0.1, 0),
        aspect: 1,
      );
      expect(result.left, closeTo(0.1, 1e-9));
      expect(result.top, closeTo(0.2, 1e-9));
      expect(result.width / result.height, closeTo(1, 1e-9));
      expect(result.width, closeTo(0.3, 1e-9));
    });

    test('锁比例缩放：只拖右边时高度以中心为轴对称变化', () {
      final result = CropMath.resize(
        const Rect.fromLTRB(0.1, 0.2, 0.4, 0.6),
        CropHandle.right,
        const Offset(0.2, 0),
        aspect: 2,
      );
      expect(result.left, closeTo(0.1, 1e-9));
      expect(result.width / result.height, closeTo(2, 1e-9));
      expect(result.center.dy, closeTo(0.4, 1e-9));
    });

    test('零尺寸起始框能继续拖，且不出现 NaN', () {
      final result = CropMath.resize(
        const Rect.fromLTWH(0.5, 0.5, 0, 0),
        CropHandle.right,
        Offset.zero,
        minWidth: 0.1,
        minHeight: 0.1,
      );
      expect(result.left.isNaN, isFalse);
      expect(result.width, greaterThanOrEqualTo(0.1 - 1e-9));
      expect(result.height, greaterThanOrEqualTo(0.1 - 1e-9));
    });

    test('move 手柄等价于整框平移', () {
      final result = CropMath.resize(
        const Rect.fromLTRB(0.1, 0.1, 0.4, 0.4),
        CropHandle.move,
        const Offset(0.1, 0),
        minWidth: 0.9,
        minHeight: 0.9,
      );
      expectRect(result, const Rect.fromLTRB(0.2, 0.1, 0.5, 0.4));
    });
  });

  group('一次拖动（屏幕像素 → 归一化）', () {
    test('非整数缩放下逐像素换算正确', () {
      // 1000x500 显示在 500x500 里 → 缩放 0.5，显示区 500x250
      final result = CropMath.applyDrag(
        imageSize: const Size(1000, 500),
        viewSize: const Size(500, 500),
        crop: const Rect.fromLTRB(0.1, 0.2, 0.5, 0.6),
        handle: CropHandle.bottomRight,
        delta: const Offset(50, 25),
        minSidePx: 24,
      );
      expectRect(result, const Rect.fromLTRB(0.1, 0.2, 0.6, 0.7), tolerance: 1e-9);
    });

    test('最小边按屏幕像素换算到两个方向', () {
      // 显示区 500x250：minSidePx=24 → 宽 0.048、高 0.096
      final result = CropMath.applyDrag(
        imageSize: const Size(1000, 500),
        viewSize: const Size(500, 500),
        crop: const Rect.fromLTRB(0.2, 0.2, 0.6, 0.6),
        handle: CropHandle.bottomRight,
        delta: const Offset(-1000, -1000),
        minSidePx: 24,
      );
      expect(result.width, closeTo(0.048, 1e-9));
      expect(result.height, closeTo(0.096, 1e-9));
      // 锚点在对角不动
      expect(result.left, closeTo(0.2, 1e-9));
      expect(result.top, closeTo(0.2, 1e-9));
    });

    test('显示区为零时原样返回', () {
      const crop = Rect.fromLTRB(0.1, 0.1, 0.5, 0.5);
      final result = CropMath.applyDrag(
        imageSize: const Size(1000, 500),
        viewSize: Size.zero,
        crop: crop,
        handle: CropHandle.right,
        delta: const Offset(100, 0),
      );
      expectRect(result, crop);
    });

    test('可以用 displayedRect 覆盖 contain 假设', () {
      // 图片本来被画成 100x100 的方形区域，拖 10px → 归一化 0.1
      final result = CropMath.applyDrag(
        imageSize: const Size(1000, 500),
        viewSize: const Size(500, 500),
        displayedRect: const Rect.fromLTWH(0, 0, 100, 100),
        crop: const Rect.fromLTRB(0.2, 0.2, 0.6, 0.6),
        handle: CropHandle.right,
        delta: const Offset(10, 0),
        minSidePx: 1,
      );
      expect(result.right, closeTo(0.7, 1e-9));
    });
  });

  test('aspectOf', () {
    expect(CropMath.aspectOf(const Size(200, 100)), closeTo(2, 1e-9));
    expect(CropMath.aspectOf(const Size(0, 100)), 0);
  });
}
