import 'dart:io';
import 'dart:typed_data';

import 'package:asmrshelf/services/image_size.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// 拼一个带正确签名的 PNG 头，宽高写进 IHDR。
Uint8List pngHeader(int width, int height) {
  final b = BytesBuilder();
  b.add([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  b.add([0, 0, 0, 13]);
  b.add('IHDR'.codeUnits);
  b.add([
    (width >> 24) & 0xFF,
    (width >> 16) & 0xFF,
    (width >> 8) & 0xFF,
    width & 0xFF,
    (height >> 24) & 0xFF,
    (height >> 16) & 0xFF,
    (height >> 8) & 0xFF,
    height & 0xFF,
  ]);
  b.add(List<int>.filled(5, 0));
  return b.toBytes();
}

/// 最小 BMP 头：偏移 18/22 是宽高，小端有符号。
Uint8List bmpHeader(int width, int height) {
  final b = BytesBuilder();
  b.add('BM'.codeUnits);
  b.add(List<int>.filled(16, 0));
  b.add(_le32(width));
  b.add(_le32(height));
  return b.toBytes();
}

List<int> _le32(int v) => [v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF];

void main() {
  // 用临时目录写文件，验证的是「真读文件头」，不是只看内存字节。
  late Directory tmp;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('asmrshelf_size_');
  });
  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('PNG 头能解出宽高', () async {
    final f = File(p.join(tmp.path, 'a.png'));
    await f.writeAsBytes(pngHeader(560, 420));
    expect(await readImageSize(f.path), const ImageSize(560, 420));
  });

  test('BMP 头的负高度按绝对值算', () async {
    final f = File(p.join(tmp.path, 'b.bmp'));
    await f.writeAsBytes(bmpHeader(300, -200));
    expect(await readImageSize(f.path), const ImageSize(300, 200));
  });

  test('JPEG 扫到 SOF0 才取尺寸', () async {
    final b = BytesBuilder();
    b.add([0xFF, 0xD8]);
    // APP0 段，长度 4（含长度字段本身）
    b.add([0xFF, 0xE0, 0x00, 0x04, 0x00, 0x00]);
    // SOF0：长度 17，精度 8，高 420，宽 560
    b.add([0xFF, 0xC0, 0x00, 0x11, 0x08, 0x01, 0xA4, 0x02, 0x30]);
    b.add(List<int>.filled(10, 0));
    final f = File(p.join(tmp.path, 'c.jpg'));
    await f.writeAsBytes(b.toBytes());
    expect(await readImageSize(f.path), const ImageSize(560, 420));
  });

  test('不认识的内容返回 null，不抛异常', () async {
    final f = File(p.join(tmp.path, 'd.png'));
    await f.writeAsBytes(List<int>.filled(64, 7));
    expect(await readImageSize(f.path), isNull);
    expect(await readImageSize(p.join(tmp.path, 'missing.png')), isNull);
  });
}
