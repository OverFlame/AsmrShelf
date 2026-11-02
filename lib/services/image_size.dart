/// 只读文件头取图片尺寸。
///
/// 剥离后不再依赖 `image` 包，封面打分要判「横版样图还是竖版封面」时
/// 只能自己读。每种格式只看到能拿到宽高的那一段，最多读前 64 KB。
library;

import 'dart:io';
import 'dart:typed_data';

/// 一张图的像素尺寸。
class ImageSize {
  const ImageSize(this.width, this.height);

  final int width;
  final int height;

  @override
  String toString() => '${width}x$height';

  @override
  bool operator ==(Object other) =>
      other is ImageSize && other.width == width && other.height == height;

  @override
  int get hashCode => Object.hash(width, height);
}

const int _headerLimit = 64 * 1024;

/// 读一张图的宽高，读不出来返回 null。
///
/// 只支持封面白名单里的五种扩展名：jpg、jpeg、png、webp、bmp。
Future<ImageSize?> readImageSize(String path) async {
  final file = File(path);
  RandomAccessFile? raf;
  try {
    raf = await file.open();
    final length = await file.length();
    final take = length < _headerLimit ? length : _headerLimit;
    final bytes = await raf.read(take);
    return decodeImageSize(bytes);
  } catch (_) {
    return null;
  } finally {
    await raf?.close();
  }
}

/// 从字节里解出宽高。前缀不足或格式不认识时返回 null。
ImageSize? decodeImageSize(Uint8List bytes) {
  final png = _png(bytes);
  if (png != null) return png;
  final gif = _gif(bytes);
  if (gif != null) return gif;
  final bmp = _bmp(bytes);
  if (bmp != null) return bmp;
  final webp = _webp(bytes);
  if (webp != null) return webp;
  return _jpeg(bytes);
}

ImageSize? _png(Uint8List b) {
  // 89 50 4E 47 0D 0A 1A 0A，IHDR 里的宽高是大端 32 位。
  if (b.length < 24) return null;
  const sig = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
  for (var i = 0; i < sig.length; i++) {
    if (b[i] != sig[i]) return null;
  }
  final w = _be32(b, 16);
  final h = _be32(b, 20);
  return w == null || h == null ? null : ImageSize(w, h);
}

ImageSize? _gif(Uint8List b) {
  if (b.length < 10) return null;
  if (b[0] != 0x47 || b[1] != 0x49 || b[2] != 0x46) return null;
  final w = b[6] | (b[7] << 8);
  final h = b[8] | (b[9] << 8);
  return ImageSize(w, h);
}

ImageSize? _bmp(Uint8List b) {
  if (b.length < 26) return null;
  if (b[0] != 0x42 || b[1] != 0x4D) return null;
  final w = _le32(b, 18);
  final raw = _le32(b, 22);
  if (w == null || raw == null) return null;
  // 高度是有符号的：负值表示自上而下存的行，画出来的高度是绝对值。
  final h = raw >= 0x80000000 ? raw - 0x100000000 : raw;
  return w == 0 || h == 0 ? null : ImageSize(w, h.abs());
}

ImageSize? _webp(Uint8List b) {
  if (b.length < 30) return null;
  const riff = [0x52, 0x49, 0x46, 0x46];
  const webp = [0x57, 0x45, 0x42, 0x50];
  for (var i = 0; i < 4; i++) {
    if (b[i] != riff[i] || b[8 + i] != webp[i]) return null;
  }
  final chunk = String.fromCharCodes(b.sublist(12, 16));
  if (chunk == 'VP8X') {
    final w = _le24(b, 24) + 1;
    final h = _le24(b, 27) + 1;
    return ImageSize(w, h);
  }
  if (chunk == 'VP8L' && b.length >= 30 && b[20] == 0x2F) {
    final bits = b[21] | (b[22] << 8) | (b[23] << 16) | (b[24] << 24);
    final w = (bits & 0x3FFF) + 1;
    final h = ((bits >> 14) & 0x3FFF) + 1;
    return ImageSize(w, h);
  }
  if (chunk == 'VP8 ') {
    // 关键帧头：3 字节起始码 + 2 字节宽度 + 2 字节高度，各 14 位有效。
    final w = (b[26] | (b[27] << 8)) & 0x3FFF;
    final h = (b[28] | (b[29] << 8)) & 0x3FFF;
    return w == 0 || h == 0 ? null : ImageSize(w, h);
  }
  return null;
}

ImageSize? _jpeg(Uint8List b) {
  if (b.length < 4 || b[0] != 0xFF || b[1] != 0xD8) return null;
  var i = 2;
  while (i + 9 < b.length) {
    if (b[i] != 0xFF) {
      i++;
      continue;
    }
    final marker = b[i + 1];
    // 填充字节
    if (marker == 0xFF) {
      i++;
      continue;
    }
    // 无长度字段的标记
    if (marker == 0xD8 || marker == 0xD9 || (marker >= 0xD0 && marker <= 0xD7)) {
      i += 2;
      continue;
    }
    final len = (b[i + 2] << 8) | b[i + 3];
    if (len < 2) return null;
    final isSof = marker >= 0xC0 &&
        marker <= 0xCF &&
        marker != 0xC4 &&
        marker != 0xC8 &&
        marker != 0xCC;
    if (isSof) {
      final h = (b[i + 5] << 8) | b[i + 6];
      final w = (b[i + 7] << 8) | b[i + 8];
      return w == 0 || h == 0 ? null : ImageSize(w, h);
    }
    i += 2 + len;
  }
  return null;
}

int? _be32(Uint8List b, int at) {
  if (at + 4 > b.length) return null;
  return (b[at] << 24) | (b[at + 1] << 16) | (b[at + 2] << 8) | b[at + 3];
}

int? _le32(Uint8List b, int at) {
  if (at + 4 > b.length) return null;
  return b[at] | (b[at + 1] << 8) | (b[at + 2] << 16) | (b[at + 3] << 24);
}

int _le24(Uint8List b, int at) =>
    b[at] | (b[at + 1] << 8) | (b[at + 2] << 16);
