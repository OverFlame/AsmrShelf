import 'dart:io';
import 'dart:typed_data';

/// 造一张纯色 PNG。
///
/// 测试里要真实可解码的图片，但为此拉一个图片库不划算：PNG 的格式足够简单，
/// 这里手写签名、IHDR、IDAT、IEND 四个块，压缩用 `dart:io` 自带的 zlib。
Uint8List solidPng(int width, int height, {int r = 255, int g = 0, int b = 0}) {
  final raw = BytesBuilder();
  for (var y = 0; y < height; y++) {
    raw.addByte(0); // 每行的过滤器字节
    for (var x = 0; x < width; x++) {
      raw
        ..addByte(r)
        ..addByte(g)
        ..addByte(b);
    }
  }
  final idat = ZLibEncoder().convert(raw.toBytes());

  final header = BytesBuilder()
    ..add(_u32(width))
    ..add(_u32(height))
    ..add([8, 2, 0, 0, 0]); // 8 位深、真彩色、无压缩标志

  return (BytesBuilder()
        ..add(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        ..add(_chunk('IHDR', header.toBytes()))
        ..add(_chunk('IDAT', idat))
        ..add(_chunk('IEND', const [])))
      .toBytes();
}

List<int> _chunk(String type, List<int> data) {
  final body = [...type.codeUnits, ...data];
  return [..._u32(data.length), ...body, ..._u32(_crc32(body))];
}

List<int> _u32(int value) => [
      (value >> 24) & 0xff,
      (value >> 16) & 0xff,
      (value >> 8) & 0xff,
      value & 0xff,
    ];

int _crc32(List<int> bytes) {
  var crc = 0xFFFFFFFF;
  for (final byte in bytes) {
    crc ^= byte;
    for (var i = 0; i < 8; i++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1;
    }
  }
  return (~crc) & 0xFFFFFFFF;
}
