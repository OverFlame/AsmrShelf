import 'dart:math' as math;
import 'dart:ui' show Offset, Rect, Size;

/// 裁剪框上可以抓住的手柄。
///
/// [move] 不是手柄，是「拖动整框」这一种交互，放进同一个枚举是为了让
/// [CropMath.applyDrag] 只有一个入口。
enum CropHandle {
  topLeft,
  top,
  topRight,
  right,
  bottomRight,
  bottom,
  bottomLeft,
  left,

  /// 拖动整框，尺寸不变
  move;

  /// 角手柄：横竖两条边同时动
  bool get isCorner =>
      this == topLeft ||
      this == topRight ||
      this == bottomRight ||
      this == bottomLeft;

  /// 是否拖动左边
  bool get movesLeft => this == topLeft || this == left || this == bottomLeft;

  /// 是否拖动右边
  bool get movesRight =>
      this == topRight || this == right || this == bottomRight;

  /// 是否拖动上边
  bool get movesTop => this == topLeft || this == top || this == topRight;

  /// 是否拖动下边
  bool get movesBottom =>
      this == bottomLeft || this == bottom || this == bottomRight;
}

/// 封面裁剪的纯计算（BUILD_GUIDE 第 21.3 节）。
///
/// 坐标口径统一为**归一化坐标**：`(0,0)` 是原图左上角，`(1,1)` 是右下角。
/// 只有 [toPixels] / [fromPixels] 与 [CropMath.fitRect] 会跟像素打交道，
/// 它们也按「原图像素尺寸」这个入参换算，不做任何 I/O。
///
/// 算法口径（第 21.3 节原文）：
/// - 中心取裁剪框中心；
/// - 面积取满足目标比例的最小矩形（即覆盖当前框的最小该比例矩形）；
/// - 超出原图的部分向内收（平移回单位方块，而不是改变比例）；
/// - 比例本身放不进单位方块时，才等比缩小到刚好容纳。
class CropMath {
  CropMath._();

  /// 全图，等价于「不裁」
  static const Rect full = Rect.fromLTRB(0, 0, 1, 1);

  /// 归一化裁剪框的存储精度。四位小数已经到原图万分之一的精度，
  /// 够用且写进 `cover_crop` 的文本短。
  static const int storageDecimals = 4;

  static const double _eps = 1e-6;

  // ═══ 归一化 ↔ 像素 ═══

  /// 归一化框 → 原图像素框
  static Rect toPixels(Rect crop, Size imageSize) {
    final c = clampUnit(crop);
    return Rect.fromLTRB(
      c.left * imageSize.width,
      c.top * imageSize.height,
      c.right * imageSize.width,
      c.bottom * imageSize.height,
    );
  }

  /// 原图像素框 → 归一化框
  ///
  /// 图片尺寸为 0 时没有可换算的基准，返回 [full]，避免出现 NaN。
  static Rect fromPixels(Rect pixels, Size imageSize) {
    if (imageSize.width <= 0 || imageSize.height <= 0) return full;
    return clampUnit(Rect.fromLTRB(
      pixels.left / imageSize.width,
      pixels.top / imageSize.height,
      pixels.right / imageSize.width,
      pixels.bottom / imageSize.height,
    ));
  }

  /// `contain` 布局：把 [content] 等比放进 [box]，居中，返回实际显示区。
  ///
  /// 显示区是屏幕像素与「拖动位移」之间的换算基准，见 [applyDrag]。
  static Rect fitRect(Size content, Size box) {
    if (content.width <= 0 ||
        content.height <= 0 ||
        box.width <= 0 ||
        box.height <= 0) {
      return Rect.fromLTWH(0, 0, math.max(0, box.width), math.max(0, box.height));
    }
    final scale =
        math.min(box.width / content.width, box.height / content.height);
    final w = content.width * scale;
    final h = content.height * scale;
    return Rect.fromLTWH((box.width - w) / 2, (box.height - h) / 2, w, h);
  }

  // ═══ 约束 ═══

  /// 把框收进单位方块：先按中心夹住尺寸，再平移贴边。
  ///
  /// 平移而不是缩小：拖动整框撞到边缘时，用户期望框「停住」而不是变形。
  static Rect clampUnit(Rect crop) {
    var l = math.min(crop.left, crop.right);
    var r = math.max(crop.left, crop.right);
    var t = math.min(crop.top, crop.bottom);
    var b = math.max(crop.top, crop.bottom);

    var w = (r - l).clamp(0.0, 1.0);
    var h = (b - t).clamp(0.0, 1.0);
    if (w.isNaN) w = 0;
    if (h.isNaN) h = 0;

    final cx = (l + r) / 2;
    final cy = (t + b) / 2;
    l = cx - w / 2;
    t = cy - h / 2;
    r = l + w;
    b = t + h;

    if (l < 0) {
      r -= l;
      l = 0;
    }
    if (t < 0) {
      b -= t;
      t = 0;
    }
    if (r > 1) {
      l -= r - 1;
      r = 1;
    }
    if (b > 1) {
      t -= b - 1;
      b = 1;
    }
    return Rect.fromLTRB(
      l.clamp(0.0, 1.0),
      t.clamp(0.0, 1.0),
      r.clamp(0.0, 1.0),
      b.clamp(0.0, 1.0),
    );
  }

  /// 平移整框，尺寸不变，撞边即停
  static Rect move(Rect crop, Offset delta) {
    final c = clampUnit(crop);
    return _placeInside(Rect.fromLTWH(
      c.left + delta.dx,
      c.top + delta.dy,
      c.width,
      c.height,
    ));
  }

  /// 按目标宽高比把裁剪框扩成能覆盖它的最小矩形（中心不变）。
  ///
  /// 第 21.3 节的三条都在这里：中心取原框中心、面积取最小覆盖矩形、
  /// 超出原图向内收。比例本身放不进单位方块时等比缩小。
  static Rect expandToAspect(Rect crop, double aspect) {
    if (!aspect.isFinite || aspect <= 0) return clampUnit(crop);
    final base = clampUnit(crop);

    var w = base.width;
    var h = base.height;
    if (w <= _eps || h <= _eps) {
      // 零面积框没有可扩的方向，退化成居中的最大该比例框。
      w = aspect >= 1 ? 1.0 : aspect;
      h = w / aspect;
      if (h > 1) {
        h = 1.0;
        w = h * aspect;
      }
      return Rect.fromLTWH((1 - w) / 2, (1 - h) / 2, w, h);
    }

    // 最小覆盖矩形：哪个方向不够就补哪个
    if (w / h < aspect) {
      w = h * aspect;
    } else {
      h = w / aspect;
    }
    // 比例超过单位方块时只能缩小，否则永远放不进去
    if (w > 1) {
      w = 1.0;
      h = w / aspect;
    }
    if (h > 1) {
      h = 1.0;
      w = h * aspect;
    }
    return _placeInside(
      Rect.fromLTWH(base.center.dx - w / 2, base.center.dy - h / 2, w, h),
    );
  }

  /// 拖手柄缩放。
  ///
  /// [delta] 是归一化位移。约束：
  /// - 结果永远落在单位方块内；
  /// - 宽高分别不小于 [minWidth] / [minHeight]；
  /// - 宽高分别不大于 [maxWidth] / [maxHeight]（扩框上限）；
  /// - [aspect] 非空时锁比例，按固定锚点（对侧边/角）反推另一维。
  static Rect resize(
    Rect crop,
    CropHandle handle,
    Offset delta, {
    double minWidth = 0,
    double minHeight = 0,
    double maxWidth = 1,
    double maxHeight = 1,
    double? aspect,
  }) {
    if (handle == CropHandle.move) return move(crop, delta);

    final mw = minWidth.clamp(0.0, 1.0);
    final mh = minHeight.clamp(0.0, 1.0);
    final xw = maxWidth.clamp(mw, 1.0);
    final xh = maxHeight.clamp(mh, 1.0);

    var c = clampUnit(crop);
    if (c.width <= _eps || c.height <= _eps) {
      // 零尺寸框给一个能继续拖的最小起点，否则下面所有上下界都会互相打架。
      c = _placeInside(Rect.fromCenter(
        center: c.center,
        width: math.max(mw, _eps),
        height: math.max(mh, _eps),
      ));
    }

    var l = c.left;
    var t = c.top;
    var r = c.right;
    var b = c.bottom;

    if (aspect == null || !aspect.isFinite || aspect <= 0) {
      if (handle.movesLeft) {
        l = (l + delta.dx).clamp(math.max(0.0, r - xw),
            math.min(1.0, math.min(r - mw, r)));
      }
      if (handle.movesRight) {
        r = (r + delta.dx).clamp(math.min(1.0, l + mw),
            math.min(1.0, math.min(l + xw, 1.0)));
      }
      if (handle.movesTop) {
        t = (t + delta.dy).clamp(math.max(0.0, b - xh),
            math.min(1.0, math.min(b - mh, b)));
      }
      if (handle.movesBottom) {
        b = (b + delta.dy).clamp(math.min(1.0, t + mh),
            math.min(1.0, math.min(t + xh, 1.0)));
      }
      // 上下界可能同时被夹到同一个值（例如框已经贴着边），再收一次尺寸
      if (r - l > xw) r = l + xw;
      if (b - t > xh) b = t + xh;
      if (r - l < mw) r = math.min(1.0, l + mw);
      if (b - t < mh) b = math.min(1.0, t + mh);
      return _placeInside(Rect.fromLTRB(
        math.min(l, r),
        math.min(t, b),
        math.max(l, r),
        math.max(t, b),
      ));
    }

    // ── 锁比例 ──
    // 先按拖动的那个方向算出想要的尺寸，再由比例反推另一维。
    final wantW = _axisExtent(handle.movesLeft, handle.movesRight, l, r, delta.dx,
        c.width);
    final wantH = _axisExtent(
        handle.movesTop, handle.movesBottom, t, b, delta.dy, c.height);

    double w;
    double h;
    if (handle.isCorner) {
      // 角：两轴都能动，取「更外扩」的那一维作主，避免框缩成一条线
      final byWidth = wantW;
      final byHeight = wantH * aspect;
      w = math.max(byWidth, byHeight);
      h = w / aspect;
    } else if (handle.movesLeft || handle.movesRight) {
      w = wantW;
      h = w / aspect;
    } else {
      h = wantH;
      w = h * aspect;
    }

    // 约束同时压在两个维度上：先按宽/高上限缩，再按下限放
    if (w > xw) {
      w = xw;
      h = w / aspect;
    }
    if (h > xh) {
      h = xh;
      w = h * aspect;
    }
    if (w < mw) {
      w = mw;
      h = w / aspect;
    }
    if (h < mh) {
      h = mh;
      w = h * aspect;
    }
    if (w > 1) {
      w = 1.0;
      h = w / aspect;
    }
    if (h > 1) {
      h = 1.0;
      w = h * aspect;
    }

    // 锚点：对侧边/角不动
    double nl;
    double nt;
    if (handle.movesLeft) {
      nl = r - w;
    } else if (handle.movesRight) {
      nl = l;
    } else {
      // 只动上下边时，宽以中心为轴对称缩放
      nl = c.center.dx - w / 2;
    }
    if (handle.movesTop) {
      nt = b - h;
    } else if (handle.movesBottom) {
      nt = t;
    } else {
      nt = c.center.dy - h / 2;
    }
    return _placeInside(Rect.fromLTWH(nl, nt, w, h));
  }

  /// 一次拖动（屏幕像素）→ 新的归一化裁剪框。
  ///
  /// [imageSize] 原图像素尺寸，[viewSize] 显示区尺寸；默认按 `contain`
  /// 显示，也可以用 [displayedRect] 直接给出图片在屏幕上的实际矩形
  /// （`cover` 布局、已缩放或已平移时用这个）。
  ///
  /// [minSidePx] 最小边，单位是**屏幕像素**，转换时按显示区的宽高分别换算，
  /// 所以在长图上「最小边」在横竖两个方向看起来一样长。
  /// [maxSide] 最大边长，单位是归一化量（1.0 = 整幅原图）。
  static Rect applyDrag({
    required Size imageSize,
    required Size viewSize,
    required Rect crop,
    required CropHandle handle,
    required Offset delta,
    double minSidePx = 24,
    double maxSide = 1,
    double? aspect,
    Rect? displayedRect,
  }) {
    final displayed = displayedRect ?? fitRect(imageSize, viewSize);
    final base = clampUnit(crop);
    if (displayed.width <= 0 || displayed.height <= 0) return base;

    final d = Offset(
      delta.dx / displayed.width,
      delta.dy / displayed.height,
    );
    final minW = (minSidePx / displayed.width).clamp(0.0, 1.0);
    final minH = (minSidePx / displayed.height).clamp(0.0, 1.0);
    final max = maxSide.clamp(0.0, 1.0);
    return resize(
      base,
      handle,
      d,
      minWidth: minW,
      minHeight: minH,
      maxWidth: max,
      maxHeight: max,
      aspect: aspect,
    );
  }

  // ═══ 存储 ═══

  /// 归一化框 → `cover_crop` 文本（`左,上,右,下`）。
  ///
  /// 全图（0,0,1,1）与 null 一样表示「不裁」，两种都返回 null，
  /// 免得库里存一堆 `0.0000,0.0000,1.0000,1.0000`。
  static String? encode(Rect? crop) {
    if (crop == null) return null;
    final c = clampUnit(crop);
    if (isFull(c)) return null;
    return '${_fmt(c.left)},${_fmt(c.top)},${_fmt(c.right)},${_fmt(c.bottom)}';
  }

  /// `cover_crop` 文本 → 归一化框；空串、NULL、坏格式都返回 null
  static Rect? decode(String? raw) {
    if (raw == null) return null;
    final text = raw.trim();
    if (text.isEmpty) return null;
    final parts = text.split(',');
    if (parts.length != 4) return null;
    final values = <double>[];
    for (final part in parts) {
      final v = double.tryParse(part.trim());
      if (v == null || v.isNaN) return null;
      values.add(v);
    }
    return clampUnit(
        Rect.fromLTRB(values[0], values[1], values[2], values[3]));
  }

  /// 是否等于整幅原图（差一个 [_eps] 以内都算）
  static bool isFull(Rect? crop) {
    if (crop == null) return true;
    return crop.left <= _eps &&
        crop.top <= _eps &&
        crop.right >= 1 - _eps &&
        crop.bottom >= 1 - _eps;
  }

  /// 目标宽高比 = 宽 / 高
  static double aspectOf(Size size) =>
      size.height <= 0 ? 0 : size.width / size.height;

  // ═══ 内部 ═══

  /// 平移回单位方块内。假定尺寸已经不大于 1。
  static Rect _placeInside(Rect r) {
    var l = r.left;
    var t = r.top;
    final w = r.width.clamp(0.0, 1.0);
    final h = r.height.clamp(0.0, 1.0);
    if (w.isNaN || h.isNaN) return full;
    if (l + w > 1) l = 1 - w;
    if (t + h > 1) t = 1 - h;
    if (l < 0) l = 0;
    if (t < 0) t = 0;
    return Rect.fromLTWH(l, t, w, h);
  }

  /// 某一维拖后的期望长度；该维没被拖动时返回原长度
  static double _axisExtent(bool movesLow, bool movesHigh, double low,
      double high, double delta, double fallback) {
    if (movesLow) return (high - (low + delta)).clamp(0.0, 1.0);
    if (movesHigh) return ((high + delta) - low).clamp(0.0, 1.0);
    return fallback;
  }

  static String _fmt(double v) {
    var s = v.toStringAsFixed(storageDecimals);
    if (s.contains('.')) {
      s = s.replaceFirst(RegExp(r'0+$'), '');
      if (s.endsWith('.')) s = s.substring(0, s.length - 1);
    }
    return s.isEmpty ? '0' : s;
  }
}
