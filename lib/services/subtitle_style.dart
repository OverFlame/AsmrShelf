import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

/// 字幕页里非当前句的透明度：既能由用户固定，也能按当前音轨封面的明暗自动算。
///
/// 背景是「封面加模糊滤镜，再压一层不透明度 [backgroundDim] 的黑」。白字以
/// 透明度 α 盖在亮度为 b 的背景上，与背景的亮度差是 α(1 - b)。取定一个目标
/// 亮度差 [targetContrast]，就能从封面的平均亮度反推 α：封面越亮，白字越要实。
class SubtitleStyle {
  SubtitleStyle._();

  /// 黑色遮罩的不透明度，与 lib/pages/subtitle_page.dart 的背景保持一致。
  static const double backgroundDim = 0.55;

  /// 目标亮度差。低于这个值，非当前句在亮封面上会糊成一片。
  static const double targetContrast = 0.30;

  static const double minInactiveOpacity = 0.10;
  static const double maxInactiveOpacity = 0.80;

  /// 读不到封面（没有封面或解码失败）时用的透明度。
  static const double defaultInactiveOpacity = 0.30;

  /// 按封面原图的平均亮度 [averageLuminance]（0 到 1）算非当前句的透明度。
  ///
  /// [averageLuminance] 为 null 表示拿不到封面，直接回落到
  /// [defaultInactiveOpacity]。
  static double autoInactiveOpacity(double? averageLuminance) {
    if (averageLuminance == null || !averageLuminance.isFinite) {
      return defaultInactiveOpacity;
    }
    final background = averageLuminance.clamp(0.0, 1.0) * (1 - backgroundDim);
    // 背景越接近纯白，需要的透明度越高；1 - background 不会到 0（遮罩留了 0.45），
    // 这里再兜一个下限，免得极端输入把结果推到无穷。
    final alpha = targetContrast / math.max(1 - background, 0.05);
    return alpha.clamp(minInactiveOpacity, maxInactiveOpacity).toDouble();
  }

  /// 把用户设的固定透明度钳进可用区间。
  static double clampInactiveOpacity(num value) => value
      .toDouble()
      .clamp(minInactiveOpacity, maxInactiveOpacity)
      .toDouble();

  /// 一串 RGBA 像素的平均相对亮度（0 到 1）。
  ///
  /// 半透明像素按「底下是本页的深色底」折算，避免 PNG 的透明区域把封面当成黑的。
  static double luminanceOfRgba(Uint8List rgba) {
    if (rgba.length < 4) return 0;
    var sum = 0.0;
    var count = 0;
    for (var i = 0; i + 3 < rgba.length; i += 4) {
      final alpha = rgba[i + 3] / 255.0;
      final luma = (0.2126 * rgba[i] +
              0.7152 * rgba[i + 1] +
              0.0722 * rgba[i + 2]) /
          255.0;
      sum += luma * alpha;
      count++;
    }
    return count == 0 ? 0 : sum / count;
  }

  /// 读一张图的平均亮度。文件不在、格式不认识、解码失败都返回 null。
  static Future<double?> luminanceOfFile(String path) async {
    ui.Codec? codec;
    ui.Image? image;
    try {
      final bytes = await File(path).readAsBytes();
      // 只看明暗，缩到 16×16 足够，也不必占大块内存。
      codec = await ui.instantiateImageCodec(bytes,
          targetWidth: 16, targetHeight: 16);
      final frame = await codec.getNextFrame();
      image = frame.image;
      final data =
          await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (data == null) return null;
      return luminanceOfRgba(data.buffer.asUint8List());
    } catch (e) {
      debugPrint('SubtitleStyle: 读封面亮度失败 $path: $e');
      return null;
    } finally {
      image?.dispose();
      codec?.dispose();
    }
  }

  /// 按封面路径缓存亮度。同一张封面反复进字幕页只解码一次。
  static final Map<String, double> _luminanceCache = {};

  /// 正在解码的封面。同一次解码期间再来要，直接复用这条 future。
  static final Map<String, Future<double?>> _pending = {};

  static Future<double?> luminanceOfCover(String path) {
    if (path.isEmpty) return Future<double?>.value();
    final hit = _luminanceCache[path];
    if (hit != null) return Future<double?>.value(hit);
    return _pending[path] ??= luminanceOfFile(path).then((value) {
      _pending.remove(path);
      if (value == null) return null;
      // 封面数量级不大，但换个库可能几千张，超了先清空重来，不做 LRU。
      if (_luminanceCache.length > 512) _luminanceCache.clear();
      _luminanceCache[path] = value;
      return value;
    });
  }

  @visibleForTesting
  static void clearLuminanceCache() {
    _luminanceCache.clear();
    _pending.clear();
  }
}
