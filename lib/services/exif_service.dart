import 'dart:io';

import 'package:exif/exif.dart';
import 'package:asmrshelf/utils/log_util.dart';
import 'package:path/path.dart' as p;

/// EXIF 元数据模型
class ExifData {
  final String? make;
  final String? model;
  final String? dateTime;
  final double? exposureTime;
  final double? fNumber;
  final int? isoSpeed;
  final double? focalLength;
  final bool? flash;
  final int? imageWidth;
  final int? imageHeight;
  final String? orientation;
  final String? software;
  final double? gpsLatitude;
  final double? gpsLongitude;
  final String? lensModel;
  final String? colorSpace;
  final int? pixelXDimension;
  final int? pixelYDimension;

  const ExifData({
    this.make,
    this.model,
    this.dateTime,
    this.exposureTime,
    this.fNumber,
    this.isoSpeed,
    this.focalLength,
    this.flash,
    this.imageWidth,
    this.imageHeight,
    this.orientation,
    this.software,
    this.gpsLatitude,
    this.gpsLongitude,
    this.lensModel,
    this.colorSpace,
    this.pixelXDimension,
    this.pixelYDimension,
  });

  bool get hasData =>
      make != null ||
      model != null ||
      dateTime != null ||
      exposureTime != null ||
      fNumber != null ||
      isoSpeed != null ||
      focalLength != null;

  String get fNumberDisplay =>
      fNumber != null ? 'f/${fNumber!.toStringAsFixed(1)}' : '—';

  String get exposureDisplay {
    if (exposureTime == null) return '—';
    if (exposureTime! >= 1) return '${exposureTime!.toStringAsFixed(1)}s';
    final denom = (1 / exposureTime!).round();
    return '1/$denom s';
  }

  String get isoDisplay => isoSpeed != null ? 'ISO $isoSpeed' : '—';

  String get focalDisplay =>
      focalLength != null ? '${focalLength!.toStringAsFixed(0)}mm' : '—';

  String get dimensionDisplay {
    final w = imageWidth ?? pixelXDimension;
    final h = imageHeight ?? pixelYDimension;
    if (w != null && h != null) return '$w \u00d7 $h';
    if (w != null) return '${w}px';
    if (h != null) return '${h}px';
    return '—';
  }

  String get gpsDisplay {
    if (gpsLatitude != null && gpsLongitude != null) {
      return '${gpsLatitude!.toStringAsFixed(4)}, ${gpsLongitude!.toStringAsFixed(4)}';
    }
    return '—';
  }
}

/// EXIF 读取服务
class ExifService {
  /// 头部探测读取的字节数，覆盖全部常见 EXIF 段还有富余
  static const int headerProbeBytes = 64 * 1024;

  /// 只读文件头部，避免为几 KB 的 EXIF 把整张图读进内存
  static Future<List<int>> _readHeader(File file) async {
    final raf = await file.open();
    try {
      final length = await raf.length();
      final count = length < headerProbeBytes ? length : headerProbeBytes;
      return await raf.read(count);
    } finally {
      await raf.close();
    }
  }

  /// 从图片文件读取 EXIF 数据
  static Future<ExifData> read(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) {
      logWarn('Exif', 'File not found: $filePath');
      return const ExifData();
    }

    final ext = p.extension(filePath).toLowerCase();
    if (ext != '.jpg' && ext != '.jpeg' && ext != '.tiff' && ext != '.tif') {
      return const ExifData();
    }

    try {
      // EXIF 段在文件头部，先只读前 64KB 就够；整文件读取一张
      // 24MP JPEG 要几十 MB 内存，而翻页时每张都会读一次。
      Map<String, IfdTag> tags;
      try {
        tags = await readExifFromBytes(await _readHeader(file));
      } catch (e) {
        // 头部截断导致 IFD 越界等情况退回整文件
        logDebug('Exif', 'Header-only EXIF parse failed, retrying full read: $e');
        tags = await readExifFromBytes(await file.readAsBytes());
      }

      double? gpsLat, gpsLon;
      try {
        gpsLat = _parseGPS(tags['GPS GPSLatitude']);
        gpsLon = _parseGPS(tags['GPS GPSLongitude']);
      } catch (_) {}

      final result = ExifData(
        make: _str(tags, 'Image Make'),
        model: _str(tags, 'Image Model'),
        dateTime:
            _str(tags, 'Image DateTime') ??
                _str(tags, 'EXIF DateTimeOriginal') ??
                _str(tags, 'EXIF DateTimeDigitized'),
        exposureTime: _rational(tags, 'EXIF ExposureTime'),
        fNumber: _rational(tags, 'EXIF FNumber'),
        isoSpeed:
            _intValue(tags, 'EXIF ISOSpeedRatings') ??
                _intValue(tags, 'EXIF PhotographicSensitivity'),
        focalLength: _rational(tags, 'EXIF FocalLength'),
        flash: _flashBool(tags),
        imageWidth:
            _intValue(tags, 'Image ImageWidth') ??
                _intValue(tags, 'EXIF ExifImageWidth'),
        imageHeight:
            _intValue(tags, 'Image ImageLength') ??
                _intValue(tags, 'EXIF ExifImageLength'),
        orientation: _orientation(tags),
        software: _str(tags, 'Image Software'),
        gpsLatitude: gpsLat,
        gpsLongitude: gpsLon,
        lensModel: _str(tags, 'EXIF LensModel'),
        colorSpace: _colorSpace(tags),
        pixelXDimension: _intValue(tags, 'EXIF PixelXDimension'),
        pixelYDimension: _intValue(tags, 'EXIF PixelYDimension'),
      );

      logDebug('Exif',
          'Read OK: ${p.basename(filePath)} (hasData=${result.hasData}, camera=${result.make ?? result.model ?? 'N/A'})');
      return result;
    } catch (e) {
      logWarn('Exif', 'Parse failed: ${p.basename(filePath)} — $e');
      return const ExifData();
    }
  }

  // ── 内部辅助 ──

  static String? _str(Map<String, IfdTag> tags, String key) {
    final t = tags[key];
    if (t == null) return null;
    try {
      final v = t.printable;
      if (v.isEmpty || v == 'null') return null;
      return v;
    } catch (_) {
      return null;
    }
  }

  static int? _intValue(Map<String, IfdTag> tags, String key) {
    final t = tags[key];
    if (t == null) return null;
    try {
      final vals = t.values;
      if (vals.length == 0) return null;
      return vals.firstAsInt();
    } catch (_) {
      return null;
    }
  }

  static double? _rational(Map<String, IfdTag> tags, String key) {
    final t = tags[key];
    if (t == null) return null;
    try {
      final vals = t.values;
      if (vals is IfdRatios && vals.ratios.isNotEmpty) {
        return vals.ratios[0].toDouble();
      }
      // fallback: try firstAsInt
      if (vals.length > 0) return vals.firstAsInt().toDouble();
      return null;
    } catch (_) {
      return null;
    }
  }

  static bool? _flashBool(Map<String, IfdTag> tags) {
    final v = _intValue(tags, 'EXIF Flash');
    if (v == null) return null;
    return (v & 1) == 1;
  }

  static String? _orientation(Map<String, IfdTag> tags) {
    final v = _intValue(tags, 'Image Orientation');
    if (v == null) return null;
    switch (v) {
      case 1: return '\u6b63\u5e38';
      case 2: return '\u6c34\u5e73\u7ffb\u8f6c';
      case 3: return '\u65cb\u8f6c 180\u00b0';
      case 4: return '\u5782\u76f4\u7ffb\u8f6c';
      case 5: return '\u987a\u65f6\u9488 90\u00b0 + \u6c34\u5e73\u7ffb\u8f6c';
      case 6: return '\u987a\u65f6\u9488 90\u00b0';
      case 7: return '\u987a\u65f6\u9488 90\u00b0 + \u5782\u76f4\u7ffb\u8f6c';
      case 8: return '\u9006\u65f6\u9488 90\u00b0';
      default: return '\u672a\u77e5 ($v)';
    }
  }

  static String? _colorSpace(Map<String, IfdTag> tags) {
    final v = _intValue(tags, 'EXIF ColorSpace');
    if (v == null) return null;
    switch (v) {
      case 1: return 'sRGB';
      case 0xFFFF: return 'Uncalibrated';
      case 2: return 'Adobe RGB';
      default: return '$v';
    }
  }

  static double? _parseGPS(IfdTag? tag) {
    if (tag == null) return null;
    try {
      final vals = tag.values;
      // GPS values: degrees, minutes, seconds as Rational
      if (vals is IfdRatios && vals.ratios.length >= 3) {
        final deg = vals.ratios[0].toDouble();
        final min = vals.ratios[1].toDouble();
        final sec = vals.ratios[2].toDouble();
        return deg + min / 60 + sec / 3600;
      }
      // fallback
      if (vals.length >= 3) {
        final deg = vals.firstAsInt().toDouble();
        // cannot properly get min/sec without more type info
        return deg;
      }
      return null;
    } catch (_) {
      return null;
    }
  }
}
