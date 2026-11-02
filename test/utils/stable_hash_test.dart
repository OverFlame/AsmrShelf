import 'package:flutter_test/flutter_test.dart';

import 'package:asmrshelf/utils/stable_hash.dart';

void main() {
  test('同样输入永远得到同样结果', () {
    expect(stableHashHex('/music/a.mp3'), stableHashHex('/music/a.mp3'));
  });

  test('输出是 16 位十六进制', () {
    final hash = stableHashHex('/music/a.mp3');
    expect(hash.length, 16);
    expect(RegExp(r'^[0-9a-f]{16}$').hasMatch(hash), isTrue);
  });

  test('只在高位码元上不同的路径不撞车', () {
    // 这两个字符的 UTF-16 码元高位不同、低 8 位相同，按低位截断会撞到一起。
    final a = stableHashHex('路径\u0100');
    final b = stableHashHex('路径\u0001');
    expect(a, isNot(b));
  });

  test('常见路径集合没有明显碰撞', () {
    final seen = <String>{};
    for (var i = 0; i < 500; i++) {
      seen.add(stableHashHex('/media/作品 $i/track ${i * 7}.flac'));
    }
    expect(seen.length, 500);
  });
}
